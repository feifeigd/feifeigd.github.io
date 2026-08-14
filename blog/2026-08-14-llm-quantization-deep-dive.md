---
title: "LLM 量化深度拆解：4-bit 省 75% 显存，GPTQ / AWQ / GGUF / NF4 怎么选"
date: 2026-08-14T22:20:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "engineering", "quantization"]
categories: ["AI"]
description: "为什么 Llama-2-70B 从 140 GB 压到 35 GB，perplexity 只掉 0.1？从对称/非对称、per-tensor/per-channel/per-group 的数学底座，到 GPTQ（误差补偿）、AWQ（激活感知）、GGUF k-quants（混合精度）、NF4+双量化（QLoRA 微调）四条路线的原理、可运行代码与选型决策表，附生产踩坑记录。"
---

先摆一个反差数字：**Llama-2-70B 的 FP16 权重约 140 GB，量化到 4-bit 后约 35 GB，压缩 75%**，而它在 WikiText2 上的 perplexity 只上升 0.1~0.3。这意味着原本要两台 A100-80G 才装得下的模型，量化后一台就够，decode 速度反而更快——因为权重小到能塞进更大的显存余量里，KV cache 也能放得更长。

为什么「省显存」和「不掉精度」能同时成立？答案藏在 LLM 推理的真实瓶颈里。这篇拆四条主流量化路线（GPTQ / AWQ / GGUF / NF4）的原理、可运行代码和选型，写给要在生产里真刀真枪跑量化的人。

{/* truncate */}

## 一、量化为什么能同时省显存又加速

自回归 decode 是典型的 **memory-bound** 场景：每生成一个 token，都要把全部权重从 HBM 显存读一遍。以 A100 为例，FP16 算力是 312 TFLOPS，但显存带宽只有约 2 TB/s——算一个 7B 模型的单 token 前向，真正的矩阵乘算不了几微秒，绝大部分时间花在「把权重从显存搬进寄存器」上。

于是关键结论浮出来：**decode 速度 ≈ 权重字节数 ÷ 显存带宽**。权重从 16-bit 降到 4-bit，每次前向要搬运的字节数砍掉 4 倍，在带宽瓶颈不变的情况下，吞吐提升接近线性。这就是为什么 INT4 推理在 memory-bound 场景下能快 2~3 倍——不是因为「4-bit 算得快」，而是因为「搬得少」。

反过来说，prefill（首 token，一次性处理整段 prompt）是 compute-bound，量化在那里几乎不加速，反而可能因为反量化开销略慢。所以量化收益的大小，取决于你的业务是长文本首字延迟敏感（prefill 重）还是高并发流式输出（decode 重）。这是选型时的第一条分水岭，后面决策表会再用到。

## 二、量化的数学底座：对称 / 非对称、per-tensor / per-channel / per-group

量化的本质是把浮点张量映射到一个低 bit 整数域，用一个 scale（和可选的 zero-point）记下映射关系：

```
# 对称量化（zero-point 固定为 0）
q = round(x / scale)          # scale = max|x| / (2^(b-1) - 1)
x_hat = q * scale

# 非对称量化（有 zero-point，适配非对称分布）
q = round(x / scale) + zp     # scale = (xmax - xmin) / (2^b - 1)
x_hat = (q - zp) * scale
```

对称量化的好处是反量化时不用做减法，kernel 更快；代价是假设了分布关于 0 对称。LLM 权重大致是零均值的高斯分布，所以对称量化在权重上通常够用；激活值（尤其是经过 ReLU/GELU 后的）往往偏向正值，非对称量化更合适。

真正决定精度的是 **scale 的粒度**。同一套「多少元素共用一个 scale」的分法，从粗到细有三种：

```python
import torch

# 1. per-tensor：整张权重矩阵一个 scale，粒度最粗
def per_tensor_quantize(w: torch.Tensor, bits: int = 8):
    qmax = 2 ** (bits - 1) - 1
    scale = w.abs().max() / qmax
    q = torch.clamp(torch.round(w / scale), -qmax, qmax)
    return q.to(torch.int8), float(scale)

# 2. per-channel：每个输出通道（矩阵的一行）单独一个 scale
def per_channel_quantize(w: torch.Tensor, bits: int = 8):
    qmax = 2 ** (bits - 1) - 1
    scales = w.abs().max(dim=1, keepdim=True).values / qmax   # [out, 1]
    q = torch.clamp(torch.round(w / scales), -qmax, qmax)
    return q.to(torch.int8), scales

# 3. group-wise：每 group_size 个元素一组一个 scale，GPTQ/AWQ 默认 128
def group_quantize(w: torch.Tensor, group_size: int = 128, bits: int = 4):
    assert w.numel() % group_size == 0
    w = w.view(-1, group_size)
    qmax = 2 ** (bits - 1) - 1
    scales = w.abs().max(dim=1, keepdim=True).values / qmax   # [groups, 1]
    q = torch.clamp(torch.round(w / scales), -qmax, qmax)
    return q.to(torch.int8), scales
```

直觉上很好理解：粒度越细，每组内数值范围越一致，scale 越「贴」，量化误差越小；代价是 scale 本身也要占显存。一个 4-bit group_size=128 的权重，每 128 个 int4（64 字节）额外带一个 FP16 scale（2 字节），开销约 3%，可以忽略——这就是 group-wise 成为事实标准的原因。

## 三、naive 量化为什么会崩：离群值问题

如果只做 per-tensor 的 INT8 量化，大模型普遍会崩——精度掉得离谱。根源是 **离群值（outlier）**：权重里极少数值特别大的元素会把 scale 撑得很大，导致其余 99.9% 的正常值被量化到极少的几个 bin 里，信息几乎丢光。

Dettmers 在 **LLM.int8()**（2022）里把这个现象讲透了：真正的问题出在**激活值**上——约 0.1% 的隐藏层特征（feature）幅度比中位数大几十倍，且这些离群特征在每一层都出现在相同的通道位置。对这些离群通道，LLM.int8() 用 FP16 单独算，其余用 INT8 算，用极少量的混合精度开销换回了几乎无损的精度。这篇论文也顺带证明了一件重要的事：**量化损失主要不是权重本身的问题，而是「权重 × 激活」的相互作用被破坏了**——这直接启发了后面的 AWQ。

对纯权重量化来说，离群值的解法就是第二节的 per-channel / group-wise 粒度：把离群值限制在它自己那组里，不让它污染整行/整张的 scale。

## 四、四条主流路线

### 1. GPTQ：误差补偿，逐列量化

**GPTQ**（Frantar et al., 2023）是 LLM 4-bit 量化的开山之作。它的思想继承自 90 年代的 Optimal Brain Surgeon：量化某一列权重带来的误差，可以通过调整**尚未量化的其他列**来部分抵消，而不是把误差直接扔掉。

具体做法是：用一小批校准数据算权重 Hessian 矩阵的逆（近似二阶曲率），然后**逐列**做「量化 → 算出误差 → 把误差按 Hessian 逆分摊到后面的列」。核心伪代码：

```python
# GPTQ 核心（简化）：逐列量化 + 二阶误差补偿
def gptq_quantize(W, H_inv, bits=4):
    # W: [out, in]，H_inv: 校准集上 X^T X 的逆（近似二阶信息）
    W, Q = W.clone(), torch.zeros_like(W)
    for col in range(W.shape[1]):
        Q[:, col], scale = quantize_col(W[:, col], bits)
        err = W[:, col] - dequantize(Q[:, col], scale)
        # 关键：把这一列的量化误差，补偿到尚未处理的后续列
        W[:, col+1:] -= (err.unsqueeze(1)
                         * (H_inv[col, col+1:] / H_inv[col, col]).unsqueeze(0))
    return Q
```

效果是惊艳的：论文报告用单张 A100 约 4 个 GPU 小时，就把 350 GB 的 OPT-175B 压到 4-bit 的约 105 GB，3-bit 的 WikiText2 perplexity 与 FP16 差距在 0.3 以内。GPTQ 的局限在于它是**纯权重量化**，量化过程不感知激活，且需要校准数据；对「激活里有离群值」的模型，精度会略逊于后面的 AWQ。

### 2. AWQ：激活感知，保护重要通道

**AWQ**（Lin et al., 2023）提出一个关键洞察：**权重的重要性，由激活值的大小决定**。一个通道的激活值越大，它对最终输出贡献越大，量化这个通道的权重造成的损失也越大。

AWQ 的做法不是给重要通道更高的 bit（那样 kernel 复杂度爆炸），而是**在量化前按激活幅度对权重做缩放**，等效于「放大重要通道、缩小不重要通道」，再用统一 4-bit 量化。核心就一行：

```python
# AWQ 核心：按激活均值给权重做 per-channel 缩放，再统一量化
s = x.abs().mean(dim=0).pow(alpha)        # alpha ≈ 0.5，x 是校准激活
W_scaled = W * s                           # 激活大的通道权重被放大 → 量化后相对误差更小
Q_w = quantize(W_scaled, bits=4)           # 统一 4-bit
# 推理时把 scale 折叠进上一层的 LayerNorm，Y = (X / s) @ dequantize(Q_w)
```

因为 scale 被折叠进已有的归一化层，推理时几乎零额外开销。论文显示 4-bit AWQ 的效果反超 8-bit 的 RTN（round-to-nearest）基线——用一半的 bit 拿到了更好的精度，配合 TinyChat 内核能拿到 3.2~3.3 倍的加速。这条「激活感知、权重缩放」的思路，现在被 vLLM、TensorRT-LLM 等主流引擎普遍采用。

### 3. GGUF k-quants：混合精度，CPU 边跑边量化

**GGUF** 是 llama.cpp 的模型格式，它的量化思路和上面两条完全不同：**混合精度**。不是全模型一个 bit，而是给不同张量、甚至同一张量内部不同 block 分配不同 bit 数。

以社区公认甜点的 `Q4_K_M` 为例：attention 的 Q/K 和 feed-forward 的关键层用 6-bit，普通权重用 4-bit，scale 再单独用 16-bit 存；每个 256 元素的 super-block 独立量化。最终等效精度约 4.85 bpw（bit per weight），比纯 4-bit 略高一点点，但精度明显更好。命令流是这样：

```bash
# 1. 把 HF 权重转成 FP16 的 GGUF（也可以在模型库里直接下现成的 .gguf）
python convert_hf_to_gguf.py /path/to/model --outfile model-f16.gguf --outtype f16

# 2. 量化到 Q4_K_M
./llama-quantize model-f16.gguf model-q4_k_m.gguf Q4_K_M

# 3. 直接跑（纯 CPU / Metal / CUDA 都行）
./llama-cli -m model-q4_k_m.gguf -p "写一个快排" -n 128
```

GGUF 的最大价值在**端侧和 CPU**：不需要 GPU、不需要校准数据，一条命令就能量化，且格式统一、生态里几乎所有工具都认。代价是它的量化是「离线一次成型」的，没有 GPTQ/AWQ 那种基于校准集的最优补偿，极致精度略逊，但胜在普适和方便。

### 4. NF4 + 双量化：为微调而生的 bitsandbytes

**NF4（4-bit NormalFloat）**是 QLoRA（Dettmers et al., 2023）论文引入的量化格式，属于信息论意义上的最优解：既然权重大致服从零均值正态分布，那量化点就不该等距，而应该放在正态分布的**分位数**上，让每个 bin 被命中的概率相等。

QLoRA 的三个组件缺一不可：**NF4 基座**（4-bit 量化冻住的基座模型）、**双量化**（double quantization，把每组的 scale 本身再用 8-bit 量化一次，进一步省显存）、**paged optimizer**（把 optimizer 状态换页到 CPU 内存，防 OOM）。加载代码：

```python
import torch
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model

bnb = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",            # NormalFloat4
    bnb_4bit_use_double_quant=True,       # 双量化，scale 也压缩
    bnb_4bit_compute_dtype=torch.bfloat16,
)
model = AutoModelForCausalLM.from_pretrained(
    "meta-llama/Llama-2-7b-hf", quantization_config=bnb, device_map="auto")
model = get_peft_model(model, LoraConfig(r=16, lora_alpha=32, target_modules=["q_proj", "v_proj"]))
```

论文最震撼的结果是：**65B 的模型在单张 48 GB 的 GPU 上完成了微调，且在 Vicuna benchmark 上追平了 16-bit 全参微调**。QLoRA 的定位和前面三条不一样——它不是为了推理服务，而是为了「用消费级显存做微调」，量化是省显存的工具，微调才是目的。

## 五、Benchmark 与选型决策表

把几条路线的关键数据摆在一起（数字来自各自论文/社区基准）：

| 路线 | bit | 显存（70B 权重） | 精度损失 | 是否需要校准集 | 典型用途 |
|------|-----|------------------|----------|----------------|----------|
| FP16 | 16 | 约 140 GB | 基准 | — | 全精度基线 |
| GPTQ | 4 | 约 35 GB | 很小 | 需要 | GPU 推理服务 |
| AWQ | 4 | 约 35 GB | 很小（优于 8-bit RTN） | 需要 | vLLM/TensorRT 部署 |
| GGUF Q4_K_M | 约 4.85 | 约 40 GB | 小 | 不需要 | 端侧 / CPU / 本地跑 |
| NF4（QLoRA） | 4 | 约 35 GB + adapter | 小 | 微调场景 | LoRA 微调 |

选型决策树，按你的场景对号入座：

1. **GPU 上做推理服务** → AWQ 或 GPTQ 的 4-bit，配 vLLM。AWQ 精度通常略优，GPTQ 生态更老更全。两者都吃校准集，量化一次只需几十到几百条样本。
2. **CPU / 边缘设备 / 本地折腾** → GGUF Q4_K_M，一条命令搞定，不需要 GPU。
3. **要微调但显存不够** → QLoRA（NF4 + 双量化 + LoRA），4-bit 基座 + 可训练 adapter。
4. **极致精度敏感（医疗、金融合规）** → 别碰 4-bit，上 INT8 per-channel 或干脆 FP16，把省出来的显存花在 KV cache 上。

## 六、生产踩坑记录

真跑过量化的人都会踩到这几个坑，提前记下：

1. **校准集的分布必须贴近线上**。GPTQ/AWQ 的量化质量高度依赖校准数据。拿英文维基校准出来的量化模型，跑中文客服场景精度会明显变差。校准集要用你真实业务的代表性样本。

2. **`desc_act`（激活排序）会改变模型行为**。GPTQ 的 `desc_act=True` 能提升精度，但会引入非标准的执行顺序，导致某些推理框架（尤其是不支持它的内核）直接报错或结果不对。部署前确认推理引擎支持，否则老老实实关掉。

3. **量化后不能只看 perplexity**。perplexity 是平均意义上的指标，掩盖了长尾退化：量化后模型在少数 token 上的概率可能被严重扭曲，导致「某个词反复生成」或「特定数字串出错」。上线前一定跑你的业务评测集（任务完成率、关键字段准确率），而不是只看 ppl。

4. **KV cache 和权重一起算显存**。量化只压缩了权重，KV cache 还是 FP16 的。4-bit 权重省下的显存若全被更长上下文吃回去，端到端收益就没那么好看。预算显存时要按「量化权重 + 满长度 KV cache + 激活」一起估。

5. **换量化格式 = 重新评估**。GGUF 的 Q4_K_M、GPTQ 4-bit、AWQ 4-bit 名义上都是「4-bit」，但数值完全不是一回事。A 格式上的结论不能直接搬到 B 格式，每个都要重新过一遍评测。

## 总结

量化的收益来自一个反直觉的事实：**LLM 推理的瓶颈是显存带宽，不是算力**，所以把权重从 16-bit 压到 4-bit，等于把带宽需求砍到四分之一——省显存和加速是同一件事的两个侧面。

四条路线的分工很清晰：**GPTQ** 用二阶误差补偿把 4-bit 精度做到接近无损，**AWQ** 用激活感知进一步保护重要通道（更适合部署），**GGUF** 用混合精度换来了免 GPU、免校准的普适性（端侧首选），**NF4+双量化** 则是把量化当成微调的省显存手段（QLoRA）。选哪条，取决于你要的是「服务吞吐」「本地能跑」还是「低成本微调」——想清楚这个，剩下的就是跑校准、过评测、盯长尾。

一句话收尾：**量化不是把精度打折卖，而是把「冗余的表示」还给「真正的瓶颈」。** 搞清楚你省的到底是带宽还是显存，量化就成功了一半。
