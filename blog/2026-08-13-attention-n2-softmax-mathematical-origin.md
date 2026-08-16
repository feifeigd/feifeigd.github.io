---
title: "为什么标准 Attention 的 O(n²) 绕不开？softmax 全局归一化才是数学根源"
date: 2026-08-13T12:00:00+08:00
draft: false
tags: ["ai", "llm", "transformer", "inference"]
categories: ["AI"]
description: "标准注意力的 n² 从哪来？答案不只是「矩阵乘法就是 n²」——矩阵乘法有结合律，本来可以调顺序省掉 n²。真正把 n² 焊死的，是 softmax 的非线性与全局归一化。这篇从数学上拆清楚为什么换不掉 softmax 就绕不开 n²，以及绕开的唯一出路。"
---

> 很多人能脱口而出「Attention 是 O(n²)」，但少有人追问：这个 n² 到底卡在哪一步？为什么优化不掉？
>
> 答案不是「矩阵乘法天生就是 n²」这么简单——矩阵乘法有**结合律**，本来可以调顺序把 n² 甩掉。真正把 n² 焊死的，是 **softmax 的全局归一化**。这篇把它从数学上拆开。

{/* truncate */}

## 一、n² 的直接来源：QKᵀ 让每个 token 给每个 token 打分

标准缩放点积注意力：

```python
attn(Q, K, V) = softmax(QKᵀ / √d) · V
```

其中 Q、K、V 都是 `[n, d]`（n = 序列长度，d = 每个 head 的维度）。第一步 `QKᵀ`：

```
QKᵀ :  [n, d] × [d, n]  →  [n, n]
```

这个 n×n 矩阵 S 的第 (i, j) 个元素是 `S[i][j] = qᵢ · kⱼ`，也就是「第 i 个 token 对第 j 个 token 的相关性打分」。

**n 个 token 两两打分，就是 n² 个分数**。这是 n² 的第一个来源：注意力矩阵本身就装着 n² 个元素。

拆开算复杂度：

| 步骤 | 形状 | 复杂度 |
|------|------|--------|
| QKᵀ | [n,d] × [d,n] → [n,n] | O(n²d) |
| softmax | 对 [n,n] 逐行归一化 | O(n²) |
| ×V | [n,n] × [n,d] → [n,d] | O(n²d) |

## 二、光有 QKᵀ 还焊不死 n²：结合律本来能救你

这里藏着一个大多数人没意识到的关键点。如果注意力**只有 QKᵀV、没有 softmax**，那矩阵乘法有结合律：

```
(QKᵀ) · V  =  Q · (KᵀV)
```

左边先算 `QKᵀ = [n, n]`，O(n²d)；右边先算 `KᵀV = [d, n] × [n, d] = [d, d]`，O(nd²)。

当 n 远大于 d 时（长序列正是这个场景），右边便宜得多：

```
左边：O(n²d)    右边：O(nd²)    →  省掉了整个 n² 因子
```

也就是说，**矩阵乘法本身并不强制 n²**——是结合律给了你「先算哪边」的自由。真按纯线性 `QKᵀV` 来，完全可以选 d 小的一边，把复杂度压到 O(nd²)。

## 三、softmax 是怎么把 n² 焊死的：非线性 + 全局归一化

问题全出在夹在中间的 softmax：

```
softmax(QKᵀ) · V
```

softmax 拆开写：

```
softmax(qᵢ·kⱼ) = exp(qᵢ·kⱼ) / Σⱼ exp(qᵢ·kⱼ)
```

这一行藏着两个「焊死 n²」的致命点：

**1. 非线性，破坏了结合律。**

softmax 是逐元素的非线性函数，作用在完整的 `[n, n]` 矩阵上。它不接受 `[d, d]` 的输入——你没法「先把 KᵀV 算成 d×d，再套 softmax」。`Q(KᵀV)` 那套省 n² 的打法在 softmax 面前**直接失效**，因为 softmax 必须先看到完整的 QKᵀ 才能逐元素归一化。

**2. 全局归一化，强迫两两交互。**

分母 `Σⱼ exp(qᵢ·kⱼ)` 是对**所有 j**（所有 key）求和。这意味着第 i 个 token 的注意力权重，依赖它和**每一个** token 的相似度。要让归一化成立，第 i 个 query 必须和全部 n 个 key 都算一遍打分——**少一个都不行**。

所以结论很硬：

> **softmax 的「全局」二字，就是 n² 的数学根源。** 它要求每个 query 看到所有 key，等价于强制做 n² 次两两打分。除非换掉 softmax，否则这一步在数学上绕不开。

### 补一个容易混淆的点：计算量和显存是两回事

有人会拿 FlashAttention 反驳：「它不就绕开了 n² 吗？」——没有。FlashAttention 省的是 **n² 的显存**（分块计算，不把 n×n 矩阵物化进 HBM），但**省不掉 n² 的计算量**：softmax 里每一对 (i, j) 的点积 `qᵢ·kⱼ` 都是必须算的，该做 n² 次还是 n² 次。

想真正把「计算量」从 n² 降下来，只有一条路，往下看。

## 四、唯一的出路：换掉 softmax

既然 n² 是 softmax 全局归一化的数学必然，那「绕开 n²」的本质就变成了「绕开 softmax」。所有真正降复杂度的方案，无一例外都在这一步动手：

| 路线 | 做法 | 复杂度 | 代价 |
|------|------|--------|------|
| 标准 Attention | softmax 全局归一化 | O(n²d) | 长序列爆炸 |
| Linear Attention | 核函数 φ(q)ᵀφ(k) 替代 softmax | O(nd²) | 丢掉概率解释、表达力下降 |
| Sparse Attention | 只让部分 token 互相打分 | O(n·k) | 丢失长程依赖 |
| Mamba / SSM | 直接换掉注意力，用状态空间 | O(n) | 架构重写 |

Linear Attention 的思路最能说明「换 softmax 才能恢复结合律」。把 softmax 换成可分解的核函数 `sim(q,k) = φ(q)ᵀφ(k)`：

```
Σⱼ φ(qᵢ)ᵀ φ(kⱼ) · vⱼ  =  φ(qᵢ)ᵀ · ( Σⱼ φ(kⱼ) vⱼᵀ )
```

右边括号里 `Σⱼ φ(kⱼ)vⱼᵀ` 是一个 **d×d 矩阵，和 n 无关**，可以先一次性算出来，再和每个 query 相乘。复杂度从 O(n²d) 降到 O(nd²)——**这正是「换掉 softmax 才绕得开 n²」的具体落地**。

```python
def linear_attention(Q, K, V, eps=1e-6):
    # φ：特征映射，保证非负即可，常用 elu(x)+1
    Q = torch.nn.functional.elu(Q) + 1
    K = torch.nn.functional.elu(K) + 1

    # 先聚合 key 侧，绕开 [n, n] 注意力矩阵（O(n·d²) 的关键）
    KV = K.transpose(-2, -1) @ V        # [b, d, d]
    K_sum = K.sum(dim=-2, keepdim=True) # [b, 1, d] 归一化分母

    num = Q @ KV                         # [b, n, d]
    den = Q @ K_sum.transpose(-2, -1)    # [b, n, 1]
    return num / (den + eps)
```

代价也很直白：softmax 换掉后，注意力不再是「全局归一化的概率分布」，表达力下降、训练更不稳定。代表工作：Transformer 原班人马的 **Performer**（随机特征映射近似 softmax）、**Linformer**（低秩投影），以及 **RWKV / RetNet / Mamba** 这条线性注意力与状态空间模型路线。

## 五、n² 是「全局建模」的代价，不是 bug

最后拔高一层。softmax 的全局归一化，恰恰是 transformer 表达力的来源——每个 token 能直接看到所有 token、动态加权，这种**全局依赖**是 transformer 干掉 RNN 的核心武器。

所以 n² 不是实现失误，而是「全局注意力」这项能力的标价。想绕开 n²，本质是想「不付全局建模的价，又想要全局建模的能力」——Linear Attention、Sparse、Mamba 全都在这个 trade-off 上做文章：用精度或表达力，去换复杂度。

## 总结

| 问题 | 答案 |
|------|------|
| n² 的直接来源 | QKᵀ 两两打分，产生 n×n 注意力矩阵 |
| 为什么绕不开 | softmax 非线性 + 全局归一化（分母 Σⱼ），破坏结合律、强制两两交互 |
| FlashAttention 能绕开吗 | 只能省 n² 的显存，省不掉 n² 的计算量 |
| 真正的出路 | 换掉 softmax（Linear / 核函数），或换掉注意力机制（SSM / Mamba） |

一句话收尾：**矩阵乘法没逼你付 n²，是 softmax 的全局归一化逼的；想不付，就先换掉 softmax。**
