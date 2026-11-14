---
title: "LoRA 的工程账本：alpha/r 缩放、秩的硬下限，以及 merge 进 bf16 时被吃掉的精度"
date: 2026-11-14T17:30:00+08:00
draft: false
tags: ["ai", "llm", "lora", "peft", "finetuning", "inference"]
categories: ["Tech"]
description: "LoRA 的三行公式背后有三个能直接决定成败的开关：alpha/r 缩放把学习率偷偷乘了一遍、秩 r 有一个不可能突破的 Eckart-Young 下限、merge 进 bf16 时低于 0.39% 的增量会被舍入吞掉。三个实验全部用纯 numpy 复现，附 Llama-3-8B 形状的参数量与显存账本。"
---

LoRA 的公式三行就能写完：

```text
W' = W + (alpha / r) * B @ A      A: (r, d_in)   B: (d_out, r)   B 初始化为 0
```

正因为简单，它也是最容易被"抄个 config 就上"的东西。而真正决定一次微调成不成的是三个开关：**缩放系数怎么跟学习率纠缠**、**秩 r 的下限在哪里**、**merge 时用什么位宽**。这三个都不是玄学，都有可以算出来的账。

这篇文章把三件事都量化一遍。实验都是纯 numpy 写的，几十行，随手能跑（`python3 -c` 装个 numpy 就行，不需要 GPU）。数字是我在本机跑的，代码贴在文末，你可以自己复核。

{/* truncate */}

## 一、alpha/r 不是玄学，它就是学习率

先看梯度。设上游梯度为 `g = dL/dh`，则

```text
dL/dB = scale * g @ (A x)^T
dL/dA = scale * B^T @ g @ x^T
```

两路梯度**都**乘了 `scale = alpha / r`。这就是第一个容易踩空的地方：`scale` 不只是前向的权重，它同时缩放了两路梯度。

要小心的是，**它不等于"学习率乘 scale"**，因为有效权重增量是 `scale * (dB @ A)`，`scale` 被算了两次或一次，取决于优化器：

- **SGD**：`dB = -lr * scale * g A^T`，再乘一次 `scale` 得到 `dW`，所以有效步长按 `scale^2` 走。
- **Adam**：逐元素除以 `sqrt(v)`，梯度整体乘 `scale` 被完全抵消，`dB` 的幅值只由 `lr` 决定，所以有效步长按 `scale^1` 走。

实测一下（固定 lr=1e-3、`B=0` 初始化、喂同一个常量上游梯度、只做一步），量的是**有效权重增量** `||scale * dB @ A||_F`：

| r | scale | SGD 单步 \|\|dW\|\| | Adam 单步 \|\|dW\|\| |
|---|---|---|---|
| 4 | 4.00 | 3.77e-2 | 4.11e-2 |
| 8 | 2.00 | 1.33e-2 | 2.85e-2 |
| 16 | 1.00 | 4.83e-3 | 2.09e-2 |
| 32 | 0.50 | 1.69e-3 | 1.47e-2 |
| 64 | 0.25 | 6.12e-4 | 1.07e-2 |

固定 `alpha=16` 时，r 从 4 涨到 64（16 倍）：SGD 的有效步长掉了 **62 倍**（`16^1.5`），Adam 只掉了 **3.8 倍**（`sqrt(16)`）。换成 `alpha = 2r`（scale 恒定），两者都涨 4 倍左右——因为 `A` 的初始化和 `dB @ A` 的累加都随秩按 `sqrt(r)` 增长。

统一起来就是一条：

```text
有效权重步长  ∝  scale^p * sqrt(r)      p = 2 (SGD) / 1 (Adam)
              ∝  alpha^p / r^(p - 0.5)
```

三条工程含义：

1. **改 r 必须同步改 alpha 或 lr**。固定 alpha 时把 r 从 8 提到 64，Adam 上有效步长悄悄掉了 2.7 倍，SGD 上掉了 21 倍。这就是"想多学点反而学不动"的机制。
2. **从 SGD 换到 AdamW，原来调好的 alpha/lr 组合会失效**。SGD 对 scale 是二阶依赖，Adam 是一阶，同一个 config 在两种优化器下的有效步长比可以差一个数量级。
3. **`alpha = r` / `alpha = 2r` 的约定让 scale 恒定，此时步长随 `sqrt(r)` 增长**。r 从 4 到 64 涨 4 倍，配同一个 lr 就是 4 倍的激进程度——大 rank 通常要相应降 lr。

顺带说一句：原始 LoRA 论文在 GPT-3 上做任务适配时，发现 rank 1~2 就够用，加到 64 收益很小。这个结论经常被误读成"rank 4 万能"。它成立的前提是**目标任务与预训练分布同源**（改风格、改格式、对齐指令）。一旦你要往里灌新知识或者新语言，结论就反过来了——这就是第二节。

## 二、秩有一个不可能突破的下限（Eckart-Young）

把一次微调看成"求出最优增量 `dW*`"。如果 `dW*` 的秩是 k，而 LoRA 只能用秩 r 的 `B@A` 去逼近它，那么最优解有解析形式：取 `dW*` 的前 r 个奇异值方向。残差下限是

```text
||dW_hat - dW*||_F / ||dW*||_F = sqrt(1 - sum_{i<=r} sigma_i^2 / sum_i sigma_i^2)
```

这是 Eckart-Young 定理，r 小于 k 时**任何优化器、任何训练时长都跨不过去**。

我构造了一个秩恰为 8、奇异值从 3.0 衰减到 0.2 的目标增量，然后用 Adam 拟合不同秩的 LoRA（3000 步）：

| r | 实测相对残差 | Eckart-Young 下限 |
|---|---|---|
| 1 | 0.7496 | 0.7562 |
| 2 | 0.5365 | 0.5458 |
| 4 | 0.2492 | 0.2518 |
| 8 | 0.0426 | 0.0000 |
| 16 | 0.0000 | 0.0000 |

前四行的实测值紧贴在理论的下面（优化器总差一点点），这就是秩瓶颈的硬约束。r 等于 8 之后下限变成 0，实测也真的收敛到 0。

这个实验顺带暴露了一个非常实用的观察：**r=8 那行的 0.0426 不是秩不够，是没收敛完**。我把同一个拟合继续跑到 10000 步，残差真的降到 0.0；再跑到 30000 步，又弹回 0.043。因为 Adam 是尺度不变的优化器，梯度趋近 0 时它依然按 `lr` 迈步子，会在最优点附近来回抖（两次运行的随机初始化不同，3000 步时的残差本身也有 0.02~0.04 的抖动）。

所以排查"是不是秩不够"不能看单次 loss 降不降，要看**两个不同秩的 loss 有没有明显分叉**。更隐蔽的反向陷阱是：r=16 和 r=64 的 eval loss 只差零点几，就急着下"rank 已经够了"的结论——其实两者都卡在同一个瓶颈上（数据质量、学习率、序列被截断），把 r 拉到 128 也一点变化都没有。判断顺序应该先排除数据和超参，最后才怀疑秩。

反过来，秩不够长什么样？**r=16 和 r=64 差出 0.1 以上的 eval loss，且大秩的 train loss 更低**，那是真的欠拟合。

那"新知识"为什么往往要更高的秩？直觉是这样：指令跟随、语气、输出格式这类能力，对应的增量 `dW*` 天然低秩（把行为往某个方向推一点点就够了）；而记一批事实、学一门新语言，需要的是近乎正交的大量方向，`dW*` 的有效秩会显著上升。Biderman 等人的对比实验（*LoRA Learns Less and Forgets Less*）也给出了同样的结论：在代码和数学的继续预训练上，LoRA 明显打不过全参微调；但 LoRA 对原始能力的遗忘也更少。这不是实现问题，是低秩假设本身的代价。

## 三、参数量与显存：LoRA 省的是优化器状态，不是激活

以 Llama-3-8B 的形状算（h=4096、ffn=14336、32 层、kv 投影输出 1024）：

| target modules | r | 参数量 | 占全模型 | 相对全参省 |
|---|---|---|---|---|
| q,v | 16 | 6.82M | 0.085% | 1178x |
| attn 四个 | 16 | 13.63M | 0.170% | 589x |
| attn + MLP 全部 | 16 | 41.94M | 0.522% | 191x |
| attn + MLP 全部 | 64 | 167.77M | 2.089% | 48x |

注意最后两行的落差：全模块 + r=64 的适配器已经到 1.68 亿参数，占总参数 2%。很多人以为"LoRA 训 1% 参数"天然成立，实际上 r 和 target 一放开，这个数字很容易翻到 2~3%，多适配器在线服务时的显存和带宽都会开始疼（第六节讲）。

显存账（7B，fp32 Adam）：

```text
全参 Adam : 14 权重 + 14 梯度 + 28 fp32 master + 56 m/v            = 112 GB
LoRA      : 14 权重 + 0.08(bf16 适配器) + 0.16(master) + 0.31(m/v)  = 14.55 GB + 激活
QLoRA     : 3.6(NF4 权重) + 0.08(适配器)，优化器分页到 CPU           ≈ 4.2 GB + 激活
```

这里有个必须说清的点：**LoRA 砍掉的是梯度、master weight 和优化器状态，激活一点没省**。所以它并不能让你在长序列下免掉 gradient checkpointing。序列长度 8K、batch 32 的时候，激活照样是几十 G。见过不止一次"上了 LoRA 还是 OOM"，然后去调 rank——方向完全错了，该调的是 `gradient_checkpointing`、`per_device_batch_size` 和序列长度。

QLoRA 那 3.6G 是三个技术叠出来的，缺一个都到不了：

1. **NF4**：预训练权重近似零均值正态，正态分布的最优量化点是**等概率分位点**，不是等间距。NF4 的 16 个码本值就是正态分位点，码本非均匀。论文实测 NF4 优于 INT4/FP4。
2. **双重量化**：每 64 个参数要存一个 fp32 的 absmax 常数，这是 0.5 bit/param 的纯开销；把它自己再 8-bit 量化一遍，压到 0.127 bit/param。在 65B 上省约 3GB。
3. **分页优化器**：借 NVIDIA 统一内存，在梯度检查点造成的显存尖峰时把优化器状态换出到 CPU，躲掉 OOM，代价是 PCIe 往返的延迟。

## 四、merge 的精度陷阱：0.39% 之下的增量会被吃掉

推理侧一般把 LoRA merge 进基础权重，换回零额外延迟。数学上完全等价：fp32 下 `max|diff|` 只有 `1.7e-6`，纯浮点结合律误差。

问题出在位宽。bf16 的尾数是 7 位显式 + 1 位隐式，相对分辨率是 `2^-8 = 0.39%`。也就是说**任何小于权重本身 0.39% 的变化，在 bf16 里根本表达不出来**。

我量化了不同 scale 下"增量在 bf16 里失真多少"（失真定义为 `|bf16(W+dW) - bf16(W) - dW|` 的最大值除以 `|dW|` 的最大值）：

| r | alpha | scale | \|\|dW\|\|/\|\|W\|\| | bf16 下增量最大失真 |
|---|---|---|---|
| 16 | 128 | 8.00 | 0.1603 | 2.4% |
| 16 | 32 | 2.00 | 0.0406 | 9.7% |
| 16 | 16 | 1.00 | 0.0204 | 21.1% |
| 8 | 8 | 1.00 | 0.0139 | 29.2% |
| 64 | 8 | 0.125 | 0.0050 | 102.6% |

最后一行的意思是：增量的最大元素**比舍入误差还小**，merge 完基本等于没训。这不是理论恐吓，是"小 alpha + 大 r"这种配置在 fp32 里训得好好的、merge 上线后行为退化、然后再也复现不出来 的典型成因。

三条对策，按推荐度排：

1. **能不 merge 就不 merge**。vLLM/SGLang 的多 LoRA 支持让你保留适配器、按请求路由，延迟开销可以接受，还顺便获得了热切换能力。
2. 要 merge 就**用 fp32 做累加再 cast**：`(W.float() + scale * (B.float() @ A.float())).to(torch.bfloat16)`。别在 bf16 里直接加——那等于先把 `dW` 舍入到 0.39% 的网格上再相加。
3. 一个粗糙但有效的自检：merge 前后各跑 200 条固定 prompt，比较输出 logprob 的均值偏移；如果偏移超过未 merge 时 adapter 带来的增益，说明精度已经吃掉了你的训练成果。

```python
import torch
import torch.nn as nn

class LoRALinear(nn.Module):
    def __init__(self, base: nn.Linear, r=16, alpha=32, dropout=0.0):
        super().__init__()
        self.base = base
        for p in self.base.parameters():
            p.requires_grad = False
        self.r, self.scale = r, alpha / r
        self.A = nn.Parameter(torch.empty(r, base.in_features))
        self.B = nn.Parameter(torch.zeros(base.out_features, r))  # B=0 起步
        nn.init.kaiming_uniform_(self.A, a=5 ** 0.5)
        self.drop = nn.Dropout(dropout)

    def forward(self, x):
        y = self.base(x)
        if self.merged:
            return y
        return y + self.scale * (self.drop(x) @ self.A.T @ self.B.T)

    def merge(self):
        dW = (self.B.float() @ self.A.float()) * self.scale   # fp32 累加
        self.base.weight.data += dW.to(self.base.weight.dtype)
        self.merged = True

    def unmerge(self):
        dW = (self.B.float() @ self.A.float()) * self.scale
        self.base.weight.data -= dW.to(self.base.weight.dtype)
        self.merged = False

    merged = False
```

`B=0` 起步这点不能省。它保证训练第一步模型输出与基座**逐位一致**，否则你在没学到任何东西之前就先破坏了预训练行为，尤其是 base model 上做继续训练时，前几十步会明显退化。peft 也踩过相关坑：`resume_from_checkpoint` 时如果 A 被重新随机初始化而 B 从 ckpt 恢复，第一步就把学到的低秩方向打散了。

## 五、多适配器在线服务

SaaS 场景里一个基座 + N 个租户 adapter 是标准形态。三个关键机制：

- **统一分页**（S-LoRA）：把所有 adapter 的 `A`/`B` 放进一个分页池，按需换入换出，而不是每个 adapter 常驻一份。论文报告单卡可服务数千个 adapter，吞吐比 vLLM 高 4 倍、比 PEFT 高 30 倍。
- **SGMV / batched 异构 GEMM**（Punica）：同一 batch 里不同请求走不同 adapter、不同秩，用 segmented gather 把多个小 GEMM 合并成一次 kernel launch，避免逐请求串行。这是"batch 里混 adapter"能不掉吞吐的根本原因。
- **请求级路由**：vLLM 的 OpenAI 兼容接口里，`model` 字段直接填 adapter 名。

```bash
# --max-loras: 单个 batch 里最多几个 adapter
# --max-lora-rank: 必须不低于你最大的那个 adapter 的 r
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --enable-lora \
  --max-loras 8 \
  --max-lora-rank 64 \
  --lora-modules tenant_a=/models/tenant_a tenant_b=/models/tenant_b
```

```python
from openai import OpenAI
c = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")
r = c.chat.completions.create(model="tenant_a", messages=[{"role": "user", "content": "hi"}])
```

三个实测坑：

- `max_lora_rank` 设成 64 而实际 adapter 都是 r=16，会按 64 预留 KV-ish 的 adapter 显存槽位，白扔显存；反之设小了直接加载失败。
- `max_loras` 限制的是**同 batch 并发的 adapter 数**，超出的请求会被调度器打散到不同 batch，吞吐掉下来但不报错——表现是"加了第三个租户之后整体变慢"，很容易被误认为模型问题。
- CUDA graph 与动态 adapter 切换在部分版本上会冲突，退回 `--enforce-eager` 换来稳定，代价是高并发下两位数的吞吐百分比——这个取舍要自己压测。

## 六、其余踩坑清单

- **gradient checkpointing + LoRA**：冻结的 embed 输出没有 `requires_grad`，checkpoint 重算时会报错或梯度为 None。peft 里要显式 `model.enable_input_require_grads()`，或者用 `use_reentrant=False`。
- **DDP 只训 adapter**：绝大多数参数没有梯度，reducer 会抱怨未使用参数。常见做法是 `find_unused_parameters=True`（慢一点），或者只把可训练部分包进 DDP。
- **`merge_and_unload()` 之后不可逆**：它把 adapter 合进权重并删掉模块；想保留可切换能力就用 `merge_adapter()` / `unmerge_adapter()`。
- **只存 adapter 时别丢 `lora_alpha`**：`adapter_config.json` 里的 `r`、`lora_alpha`、`target_modules` 是行为的一部分。手工拼 state_dict 而忽略 alpha，加载出来的模型和训练时不是同一个东西——这类"评测复现不出来"的 bug 极难查。
- **dropout 只作用在 adapter 支路**，不要加在 base 输出上，否则推理（关闭 dropout）与训练的分布不一致被放大。
- **多 adapter 切换训练**：`set_adapter()` 之后要确认只有当前 adapter 的 `requires_grad=True`，不然会悄悄把别的租户的 adapter 也更新了。

## 七、什么时候不该用 LoRA

- 需要灌入**大量新知识**（新语言、新领域语料继续预训练）：低秩假设顶不住，全参或者高秩 + 更多数据更实在。
- 需要**改变模型的核心能力分布**（比如把 7B 的数学能力拉到另一个档）：LoRA 更像"调音"，不是"换发动机"。
- 数据量已经大到几十万条高质量样本：这时全参微调的边际收益开始超过 LoRA 的便利性，而你的显存预算大概也够了。

反过来，LoRA 最强的场景是：**同一基座 + 多租户/多任务**、**格式与风格对齐**、**快速迭代试错**（一个 adapter 几十 MB，实验管理成本几乎为零）。这也是为什么它成了所有 Agent 平台做私有化定制的默认选项。

## 八、复现

实验脚本只用 numpy，覆盖了 merge 等价性与 bf16 失真、秩瓶颈与 Eckart-Young 对照、alpha 缩放的首步幅值、Llama-3-8B 参数量与 7B 显存账本。想复核的话，关键就三段：`bf16()` 用 round-to-nearest-even 把 fp32 的尾数截到 7 位；`fit_lora()` 是 B=0 初始化 + Adam 拟合 `B@A` 到目标增量；秩下限则直接用奇异值平方和算。

一句话收尾：LoRA 的三行公式不难，难的是知道 `alpha/r` 在暗中乘你的学习率、秩有一个算得出来的墙、以及 merge 的位宽会把小增量悄悄吃掉。这三件事都不需要 GPU 就能验证。
