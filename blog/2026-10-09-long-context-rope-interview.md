---
title: "面试题：长上下文到底是怎么做到的？RoPE 为什么不能直接外推、PI/NTK/YaRN 各在插什么、32K 训练的模型凭什么撑到 128K，长上下文和 RAG 又该怎么选？"
date: 2026-10-09T09:00:00+08:00
draft: false
tags: ["ai", "llm", "transformer", "inference", "kv-cache", "interview"]
categories: ["Interview"]
description: "LLM 高频面试题：模型训练时只有 32K，却对外标称 128K，中间这 4 倍是怎么补上的？为什么纯自注意力离不开位置编码、RoPE 的旋转到底编码了什么、高频维度和低频维度为什么会分别失败？位置插值 PI、NTK-aware 改 base、YaRN 分维度 ramp 加注意力温度，四代方案各在改什么、到底要不要微调？为什么插值后还会退化（Lost in the Middle / Context Rot）、KV Cache 在 128K 下的显存账怎么算、长上下文和 RAG 到底怎么分工——从数学推导到工程落地一次讲透。"
---

> 这是「每日一题」专栏的第二十一篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇是 [分库分表之后的在线扩容](/blog/2026/10/03/online-sharding-expansion-interview)，今天按轮换回到 AI/LLM 方向，兑现上一篇的预告：**长上下文与 RoPE 长度外推**。这道题的分水岭很清楚——背过的人能说出「位置插值」四个字，真做过的人能讲清楚「为什么高频维度和低频维度的失败方式完全相反，所以一刀切必错」。

{/* truncate */}

## 一、题目与考点拆解

面试官的原话通常是这样：

> 你们模型标称 128K 上下文，但训练的时候序列长度只有 32K。这中间 4 倍的差距是怎么补上的？RoPE 不是天然能编码位置吗，为什么不能直接外推？位置插值 PI、NTK、YaRN 这几个名词到底在改什么？改完为什么还要微调？还有——长上下文能塞下整本书了，那还要 RAG 干什么？

这一题真正考的是四层，缺一层都算没答透：

1. **位置编码的必要性与 RoPE 的数学本质**：旋转、相对性、频率分配。
2. **为什么 OOD**：训练和推理的位置分布不一致，具体是哪一部分崩、怎么崩。
3. **三类外推方案的取舍**：整体压缩（PI）vs 非均匀改 base（NTK）vs 分维度 ramp + 温度修正（YaRN），以及各自的失效边界。
4. **系统工程与选型**：KV Cache 显存、注意力复杂度、有效上下文退化，以及长上下文与 RAG 的分工。

## 二、为什么自注意力离不开位置编码

先把最基本的一层讲清楚，很多人跳过这步直接背 RoPE 公式，一追问就露馅。

缩放点积注意力的定义是：

```text
Attention(Q, K, V) = softmax(Q · Kᵀ / sqrt(d_k)) · V
```

每个位置的输出是**所有位置 V 的加权和**，权重只取决于 query 和 key 的内容相似度。把输入的 token 顺序随便打乱，每个输出向量只是跟着一起重排，数值本身不变。也就是说，**纯注意力对顺序是置换等价（permutation equivariant）的**——在它眼里「猫追狗」和「狗追猫」是同一堆 token，只是输出顺序不同。

位置编码的三大流派：

- **绝对位置编码**：原始 Transformer 的正弦编码、BERT/GPT-2 的可学习位置 embedding。本质是告诉模型「我站在第几格」，无法直接表达「我们俩隔多远」。
- **相对位置编码**：T5 的 relative position bias、Shaw 的 relative embedding、ALiBi（给注意力加一个随距离线性衰减的偏置）。表达的是「我们差几格」，外推性通常更好。
- **旋转位置编码（RoPE）**：不额外加向量，而是把位置信息**旋转进 q/k 本身**，让点积天然携带相对距离。LLaMA / Qwen / DeepSeek / Mistral / GPT-NeoX 几乎清一色用它。

RoPE 之所以成为现代 LLM 的事实标准，就两点：**无额外参数，且注意力分数只依赖相对距离**——后者是「有可能外推」的前提（注意是可能，不是一定）。

## 三、RoPE 到底在转什么

把 head_dim 的向量**两两配对**，切出 d/2 个二维平面。位置 m 的那一对向量，绕原点逆时针旋转 m · θ_i 角度，其中

```text
θ_i = base ^ (-2i / d),   i = 0, 1, ..., d/2 - 1
```

`base` 通常取 10000（Qwen 等长上下文模型会直接取 1000000）。写成分块矩阵，对第 i 对分量（即第 2i 与第 2i+1 两个维度）：

```text
[ x'_{2i}   ]   [ cos(m·θ_i)   -sin(m·θ_i) ] [ x_{2i}   ]
[ x'_{2i+1} ] = [ sin(m·θ_i)    cos(m·θ_i) ] [ x_{2i+1} ]
```

用复数写更干净：第 i 个维度的位置编码，就是把它乘上 e 的 i·m·θ_i 次幂（一个纯相位旋转因子）。

**关键性质**：query 在位置 m、key 在位置 n，点积为

```text
Re[ Σ_i (q_i · e^{i·m·θ_i}) · conj(k_i · e^{i·n·θ_i}) ]
  = Re[ Σ_i q_i · k_i* · e^{i·(m-n)·θ_i} ]
```

指数上只剩 **m - n**（相对位置），绝对位置被消掉了。这就是 RoPE「天生相对」的来源，也是外推讨论的起点。

**频率分配才是重点**。第 i 个维度对应的波长是

```text
λ_i = 2π / θ_i = 2π · base ^ (2i / d)
```

- i 小 → θ 大 → 波长**短**（高频）→ 转得快 → 负责编码**局部、相邻**的位置差异；
- i 大 → θ 小 → 波长**长**（低频）→ 转得慢 → 负责编码**全局、远距离**的位置差异。

以 d = 128、base = 10000 为例：最短波长约 6.28（负责区分相邻几个 token），最长波长约 6.3 万（要几万个 token 才转完一圈）。一组维度从「像素级」到「全景级」分工明确——**这就是后面所有外推方案都要「分维度对待」的根本原因**。

## 四、为什么 RoPE 不能直接外推：两种方向相反的失败

训练时位置 m、n 都在 [0, 32768)。推理突然来了 100000，就出现了训练中**从未见过的旋转角**。YaRN 论文把崩溃拆成两种，而且方向正好相反：

1. **低频维度没见过这么大的角度**。波长很长的那些维度，在 32K 范围内可能连一圈都没转完；到了 128K，角度远远超出训练分布，attention logits 的分布整体漂移——要么变成噪声，要么注意力熵暴涨、变得极其弥散（softmax 趋于均匀）。表现就是：困惑度从个位数飙到几十上百，生成开始胡言乱语。
2. **高频维度怕被压缩**。如果为了塞进训练范围，把所有维度一律等比「压扁」（下面要讲的 PI），那些本来负责区分「相邻 1 个 token」的高频维度就被压没了分辨率，局部次序分辨能力下降。

一句话总结：**高频维度怕压缩，低频维度怕外推。所以任何「对所有维度一刀切」的方案都先天缺陷。**

这也解释了为什么很多「把 base 直接调大」的土办法只解决了一半问题：调大 base 相当于整体拉长波长，低频维度舒服了，但原本精细的高频结构也被搅动。

## 五、长度外推四代方案

### 5.1 位置插值 PI（Position Interpolation，Linear Scaling）

最简单的一招：不碰模型参数，只把推理时的位置**整体线性压缩**回训练范围。

```text
pos' = pos / s,    s = L_target / L_train
```

比如 32K 训练的模型要跑 128K，就让位置 100000 实际按 25000 参与旋转。

- 优点：改动极小（几行代码），几乎不碰架构；Meta 的论文显示，只需约 1000 步微调就能把 LLaMA 从 2K 扩到 8K/32K，甚至少量场景免训练也能「不崩」地跑起来。
- 缺点：**uniform 压缩，高频维度分辨率一起丢**；纯外推（不微调）时短序列能力也会退化——因为所有位置都被压扁了。

### 5.2 NTK-aware：改 base，而不是改位置

换个思路：位置不动，动频率基准。把 base 放大：

```text
base' = base · s ^ (d / (d - 2))
```

效果上等价于**按维度非均匀缩放**：高频维度（i 小）几乎不受影响，低频维度（i 大）被拉伸得更多。理论依据来自 NTK（神经正切核）视角——不同维度看到的「有效频率」不同，必须分别对待。它免训练就能在中等倍率下工作，配上微调效果更好。

### 5.3 NTK-by-parts / YaRN：分维度 ramp + 注意力温度

YaRN 把「高频不插值、低频插值」从直觉变成显式的分段函数。判定依据是每个维度的波长：

- 波长**明显短于**训练长度的高频维度 → **完全不插值**，保持原样（保住局部分辨率）；
- 波长**明显长于**目标长度的低频维度 → **完整 PI 插值**（避免看到没见过的角度）；
- 夹在中间的维度 → 按波长做一个**线性 ramp（渐变）**，平滑过渡。

再补一个容易被忽略的修正：插值之后注意力会被「摊平」（熵上升、变弥散），于是引入一个跟缩放倍率挂钩的**注意力温度系数**，把 logits 整体放大，让注意力重新聚焦：

```text
mscale = 0.1 · ln(s) + 1
```

实践上，YaRN 一般会配几百步长文本继续训练，是当前 Qwen2.5、DeepSeek、Llama-3.1 等开源模型长上下文的标配之一。

### 5.4 动态与更激进的一代

- **Dynamic NTK**：推理时按**当前序列长度**实时计算 s（长度没超训练窗口就不缩放），免训练，代价是短文本场景也要付出一点质量。
- **LongRoPE**：对每个维度做进化搜索，找最优缩放组合，宣称做到 200 万上下文。
- **ABF（Adjusted Base Frequency）**：干脆在预训练时就用大 base（10000 → 500000），让频率分布一开始就适配长上下文，Qwen 系列常用。
- **LongLoRA（S²-Attn）**：训练侧省显存，用移位短注意力 + LoRA 微调长上下文。
- **StreamingLLM / attention sink**：滑窗 + 保留开头几个 token 当「锚点」，处理无限流式输入。

一张速查表：

| 方案 | 改什么 | 要微调吗 | 典型场景 |
| --- | --- | --- | --- |
| PI（Linear） | 整体压缩位置 | 要（少量） | 快速小倍率扩展 |
| NTK-aware | 改 base | 免训练或少量 | 中等倍率、无训练预算 |
| YaRN | 分维度 ramp + 温度 | 要（几百步） | 生产级 4 倍以上 |
| Dynamic NTK | 运行时算 base | 免训练 | 变长推理、不确定输入长度 |
| ABF | 预训练就换大 base | 重训 | 从零设计长上下文模型 |

## 六、32K 撑到 128K：到底要不要微调

几个必须背下来的结论：

1. **纯外推 vs 微调是两件事**。不微调，PI/YaRN 能让 4 倍外推「不崩」（不再胡言乱语），但质量明显下降——长文本检索通过率下滑、困惑度上升。要拿回质量，需要**长文本数据的继续训练 / SFT**，哪怕只有几百步。
2. **训练数据的长度分布决定外推起点**。如果预训练语料里绝大多数是短文本，低频维度的角度分布就极窄，可外推的空间自然小。这也是为什么「同样的模型，有的能扩 4 倍，有的扩 2 倍就崩」。
3. **4 倍左右通常是「免微调」的甜蜜点上限**，再往上（8 倍、16 倍）基本必须重训/继续预训练 + 位置方案一起上。
4. 厂商标称的 128K，往往是**外推方案 + 长文本继续预训练 + 长文本 SFT** 三者叠加的结果，不是靠单一技巧「点石成金」。

还要分清一个概念——**有效上下文 ≠ 标称上下文**：

- Needle-in-a-Haystack 单针全绿，不代表多针、多跳、跨段落聚合也 OK；
- RULER、LongBench、∞Bench 这类更严格的基准反复揭示：不少模型标 128K，实际有效上下文只有 16K 到 32K；
- **Lost in the Middle**：关键信息放在开头或结尾时召回最好，放中间最差，性能呈 U 形分布；
- **Context Rot**：即使没超窗口，塞进去的内容越多，模型对任意单条信息的召回也越差。

所以「支持 128K」这句话，一定要在面试里补一句「标称不等于有效，要看 RULER 这类多任务长文本基准」。

## 七、外推只是第一步：工程侧的三座大山

位置编码解决了「看不看得懂远距离」，但工程上还有三件事拦路。

**1）KV Cache 显存**。每个 token 的 KV 占用是：

```text
bytes_per_token = 2 × num_layers × num_kv_heads × head_dim × dtype_bytes
```

以 LLaMA-2 7B（32 层、32 个 KV 头、head_dim 128、fp16）为例：

```text
2 × 32 × 32 × 128 × 2 = 524288 bytes ≈ 512 KiB / token
128K token → 512 KiB × 131072 ≈ 64 GiB
```

单条 128K 请求就要 64 GiB 显存，A100 80G 都只够塞一条。优化路径：

- **GQA / MQA** 把 KV 头从 32 降到 8 → 每 token 128 KiB → 128K 降到 16 GiB；
- **KV 量化**到 4-bit → 再降到 4 GiB 量级；
- **PagedAttention** 消除碎片浪费，**prefix cache** 复用公共前缀（多轮对话、共享 system prompt）。

**2）注意力复杂度 O(L²)**。128K 下 attention 的计算量是 32K 的 16 倍，且中间矩阵巨大。要上 **FlashAttention**（IO-aware，不落盘中间矩阵）、**滑动窗口 + 全局层混合**（如 Mistral 的 SWA 交替全注意力层）、以及各类稀疏/线性注意力。

**3）位置方案要和推理框架对齐**。vLLM / TGI / llama.cpp 里 `rope_scaling` 的类型、factor、`original_max_position_embeddings` 必须和训练时**完全一致**，否则会出现「能跑、不报错，但答不对」——这是线上最坑的一类 bug，因为日志一切正常。

## 八、长上下文 vs RAG：不是二选一，是分工

先破一个误区：这两者**不是替代关系**，而是在四个维度上分工——成本、规模、时效、可审计。

**长上下文适合**：

- 一次性、需要跨文档做**全局推理**的任务（总结、对比、多跳）；
- 文档总量不大（几百页以内）、更新不频繁；
- 你希望模型**自己去找证据**，而不是检索器先替你筛掉一半。

**RAG 适合**：

- 语料库巨大（百万级文档）且持续更新；
- 要求**引用可溯源**（要给出具体段落或链接）；
- 延迟和成本敏感——每 token 都计费，长上下文很贵。

真正的工程答案通常是**混合**：

1. 用 RAG 把候选从百万文档缩到几万 token，**再**用长上下文让模型在候选里推理。这样既省 token 又保留全局推理能力。
2. **Context Engineering**：关键信息放开头/结尾（避开中间低谷）、压缩历史、按需重排。
3. 成本账：长上下文 ≈ O(L²) 注意力算力 + O(L) KV 显存 + 按输入 token 计费；RAG 的检索链路是相对固定的小成本，但引入召回率这个新变量。

一个面试加分点：**长上下文不是 RAG 的替代品，而是它的高级形态**。当检索粒度从 chunk 变成整篇、甚至整库时，两者就融合了——比如「把整个代码仓库塞进窗口做 repo-level 问答」，检索退化成粗定位，剩下全交给模型的全局注意力。

## 九、代码：从零实现 RoPE 与三种缩放

先实现最朴素的 RoPE：

```python
import torch

def build_inv_freq(dim, base=10000.0, device="cpu"):
    i = torch.arange(0, dim, 2, device=device).float()
    return base ** (-i / dim)          # theta_i, 形状 [dim/2]

def rope_cache(seq_len, dim, base=10000.0, device="cpu"):
    inv_freq = build_inv_freq(dim, base, device)
    t = torch.arange(seq_len, device=device).float()   # 位置 m
    freqs = torch.outer(t, inv_freq)                   # [seq_len, dim/2]
    return torch.cos(freqs), torch.sin(freqs)

def rotate_half(x):
    # (x0, x1, x2, x3, ...) -> (-x1, x0, -x3, x2, ...)
    x1, x2 = x[..., ::2], x[..., 1::2]
    return torch.stack((-x2, x1), dim=-1).flatten(-2)

def apply_rope(x, cos, sin):
    # x: [B, H, L, D]; cos/sin: [L, D/2]
    cos = cos.repeat_interleave(2, dim=-1)[None, None]
    sin = sin.repeat_interleave(2, dim=-1)[None, None]
    return x * cos + rotate_half(x) * sin
```

三种缩放，核心都是**换一个 inv_freq**：

```python
def inv_freq_linear(dim, base, s, device="cpu"):
    # PI: 位置整体除以 s，等价于把频率整体缩小 s 倍
    return build_inv_freq(dim, base, device) / s

def inv_freq_ntk(dim, base, s, device="cpu"):
    # NTK-aware: 不压位置，改 base（等效于按维度非均匀缩放）
    new_base = base * (s ** (dim / (dim - 2)))
    return build_inv_freq(dim, new_base, device)

def inv_freq_yarn(dim, base, s, train_len,
                  beta_fast=32.0, beta_slow=1.0, device="cpu"):
    """分维度 ramp：
       ramp ~ 1  (高频、波长短) -> 不插值，保留局部分辨率
       ramp ~ 0  (低频、波长长) -> 完整 PI 插值，避开未见过的角度
    """
    inv = build_inv_freq(dim, base, device)
    wavelen = 2 * torch.pi / inv                       # 每个维度的波长
    ratio = train_len / wavelen
    ramp = ((ratio - beta_slow) / (beta_fast - beta_slow)).clamp(0.0, 1.0)
    return inv * ramp + inv / s * (1.0 - ramp)
```

再补上 YaRN 的注意力温度修正：

```python
import math

def yarn_mscale(s):
    # 插值后注意力变弥散，用 >1 的温度系数把 logits 放大、让注意力重新聚焦
    return 0.1 * math.log(s) + 1.0

def scaled_dot_product(q, k, v, mscale=1.0):
    d = q.shape[-1]
    logits = (q @ k.transpose(-2, -1)) * (mscale / math.sqrt(d))
    return logits.softmax(-1) @ v
```

有了 `inv_freq_*` 三个函数，只要在 `rope_cache` 里把 `build_inv_freq` 换掉，就完成了 PI / NTK / YaRN 的切换——这也是主流框架（vLLM、HF、llama.cpp）里 rope scaling 的实现套路。

## 十、收尾

一句话总结这题：**长上下文的本质，是让模型在训练时没见过的距离上依然保持注意力分布稳定；RoPE 的外推问题说到底是频率分配的再平衡问题——高频维度保局部、低频维度管全局，一刀切必崩，只有「分维度缩放 + 注意力温度修正 + 长文本微调」三件套才能既扩得动又保得住质量。**

面试里能拿满分的三个追问，最好自己主动讲出来：

1. **为什么不直接把 base 调到很大？** —— 那是「训练时就按长上下文设计频率」（ABF）的思路；事后硬调只照顾了低频维度，还会破坏原有的短距离分辨，必须配合微调。
2. **为什么插值之后还要微调？** —— 外推本质是分布校正，几百步长文本继续训练就能把质量拉回来；纯外推只是「不崩」，不等于「好用」。
3. **标称 128K 就能放心用吗？** —— 不能。有效上下文远小于标称，NIAH 单针全绿不代表多跳任务可用，Lost in the Middle 与 Context Rot 才是真实水位。

顺带把选型的直觉带走：**要全局推理、文档不大 → 直接长上下文；语料巨大、要更新、要引用 → RAG；两者都要 → 先用检索缩小候选，再用长窗口做推理。**

---

*明日预告：按轮换回到后端/分布式方向 ——「MySQL 为什么用 B+ 树而不是 B 树或跳表？联合索引的最左前缀到底怎么生效、回表与覆盖索引的代价怎么算、`limit 100000, 20` 这种深分页为什么慢、怎么优化到 O(1) 定位？」*

---

**相关阅读**

- [分库分表之后的在线扩容](/blog/2026/10/03/online-sharding-expansion-interview)
- [KV Cache 显存与长上下文推理](/blog/2026/08/19/kv-cache-interview)
- [为什么 vLLM 是当前最快的 LLM 推理框架](/blog/2026/08/29/vllm-inference-interview)
- [MoE 混合专家：稀疏激活、专家路由与推理显存墙](/blog/2026/10/02/moe-mixture-of-experts-interview)
