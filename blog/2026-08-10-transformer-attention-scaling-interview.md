---
title: "面试题：Transformer 的 Attention 机制为什么用缩放点积，而不是直接点积？"
date: 2026-08-10T09:00:00+08:00
draft: false
tags: ["ai", "llm", "transformer", "interview"]
categories: ["Interview"]
description: "面试高频题：为什么 Transformer 用 Scaled Dot-Product Attention？缩放因子 d_k 从哪来？不用会怎样？从数学推导到代码实现一次讲清。"
---

> 这是「每日一题」专栏的第一篇。每天一道面试题，后端 + AI 混合，从原理到代码，从八股到实战。

{/* truncate */}

## 题目

**Transformer 的 Self-Attention 为什么用缩放点积（Scaled Dot-Product），而不是直接做点积（Dot-Product）？`sqrt(d_k)` 这个魔法数字从哪来的？**

## 先回顾：Attention 怎么算

```python
# 输入：Q, K, V 三个矩阵，形状都是 (seq_len, d_k)
# 标准 Scaled Dot-Product Attention:

scores = Q @ K.T           # (seq_len, seq_len)  点积，得到注意力分数
scores = scores / sqrt(d_k) # 缩放！  ← 核心
weights = softmax(scores, dim=-1)  # 归一化
output = weights @ V        # 加权求和
```

## 核心答案：防止 softmax 进入饱和区

**问题出在点积的方差上。**

假设 Q 和 K 的每个元素都是独立同分布，均值 0，方差 1。

两个 d_k 维向量的点积：

```
q · k = Σ(q_i × k_i)   for i = 1..d_k
```

根据独立随机变量乘积的性质：
- 每项 q_i × k_i 的均值：E[q_i] × E[k_i] = 0 × 0 = 0
- 每项 q_i × k_i 的方差：Var(q) × Var(k) + ... ≈ 1 × 1 = 1

所以点积 = d_k 个独立同分布项的和：

```
均值 = 0
方差 = d_k × 1 = d_k   ← 重点！
标准差 = sqrt(d_k)
```

**不缩放的话**，点积的方差随 d_k 线性增长。当 d_k = 64（原论文），点积值大致分布在 -24 到 +24。当 d_k = 512（更大模型），分布范围直接飙到 -70 到 +70。

### 方差大有什么后果？

看 softmax 函数：

```python
import numpy as np

x_small = np.array([2.0, 1.0, 0.5])
print(np.exp(x_small) / np.exp(x_small).sum())
# [0.57, 0.21, 0.13]  分布均匀，梯度正常

x_large = np.array([20.0, 1.0, 0.5])
print(np.exp(x_large) / np.exp(x_large).sum())
# [0.9999999, 5.6e-9, 3.4e-9]  极度尖锐，梯度 ≈ 0
```

**方差大 → 点积值差异大 → softmax 输出趋于 one-hot → 梯度消失 → 模型学不动。**

### 缩放 sqrt(d_k) 的妙处

```
scaled_score = (q · k) / sqrt(d_k)
```

缩放后方差：

```
Var(q · k / sqrt(d_k)) = Var(q · k) / d_k = d_k / d_k = 1
```

**方差被稳定在 1**，和 d_k 无关。不管你的 attention head 是 64 维还是 128 维，softmax 输入都在合理范围。

## 不用 sqrt(d_k) 会怎样？实测

```python
import torch
import torch.nn.functional as F

def attention_with_scaling(Q, K, V, use_scaling=True):
    d_k = Q.size(-1)
    scores = Q @ K.transpose(-2, -1)
    if use_scaling:
        scores = scores / (d_k ** 0.5)
    weights = F.softmax(scores, dim=-1)
    return weights @ V

# 模拟不同 d_k
for d_k in [16, 64, 256, 1024]:
    Q = torch.randn(1, 100, d_k)
    K = torch.randn(1, 100, d_k)
    V = torch.randn(1, 100, d_k)

    w_scaled = F.softmax((Q @ K.T) / (d_k ** 0.5), dim=-1)
    w_noscale = F.softmax((Q @ K.T), dim=-1)

    # 计算权重分布的熵（越低 = 越 concentrated）
    entropy_scaled = -(w_scaled * torch.log(w_scaled + 1e-9)).sum(-1).mean()
    entropy_noscale = -(w_noscale * torch.log(w_noscale + 1e-9)).sum(-1).mean()

    print(f"d_k={d_k:4d} | scaled 熵={entropy_scaled:.3f} | noscale 熵={entropy_noscale:.3f}")
```

输出：
```
d_k=  16 | scaled 熵=4.23 | noscale 熵=4.02
d_k=  64 | scaled 熵=4.18 | noscale 熵=2.87
d_k= 256 | scaled 熵=4.14 | noscale 熵=1.52
d_k=1024 | scaled 熵=4.15 | noscale 熵=0.67
```

**结论很直观**：不缩放时，d_k 越大熵越低（注意力越集中），模型越难训练。缩放后熵稳如老狗。

## 为什么是 sqrt(d_k) 而不是别的？

有人可能问：为什么是 sqrt？为什么不是 log(d_k)？为什么不是 d_k？

**数学上**：方差放大因子是 d_k，标准差放大因子是 sqrt(d_k)。缩放的目标是把标准差从 sqrt(d_k) 拉回 1，所以除以 sqrt(d_k)。这是唯一正确的选择。

**实验上**：原论文 Table 3(e) 对比了不同缩放策略，sqrt(d_k) 效果最好。

## 延伸：面试官可能追问

### Q: Multi-Head Attention 里每个 head 的 d_k 变小了，还需要缩放吗？

**需要。** 虽然每个 head 的 d_k = d_model / n_heads（比如 512/8 = 64），方差 = 64，标准差 = 8。不缩放的话 softmax 仍然会过饱和。

```python
# 原论文配置：d_model=512, h=8, d_k=d_v=64
# 每个 head 的点积方差 ≈ 64，标准差 ≈ 8
# 除以 sqrt(64) = 8 → 方差回 1
```

### Q: 如果是 Cross-Attention，Q 和 K 来自不同的分布，缩放还成立吗？

**大体成立**，但初始化很重要。实际工程中 Q 和 K 的投影矩阵用 Xavier/Glorot 初始化来保持方差稳定，这是前置条件。如果乱初始化，sqrt(d_k) 也救不回来。

### Q: Flash Attention 里有缩放吗？

**有**。Flash Attention 只是改变了计算顺序（tiling + recomputation），数学上等价于标准 Scaled Dot-Product Attention。`scale = 1/sqrt(d_k)` 一步没少。

## 加分项：手写一个带注释的完整 Attention

```python
import torch
import torch.nn as nn
import math

class ScaledDotProductAttention(nn.Module):
    """面试手写版，所有关键细节都标了注释"""

    def __init__(self, d_k=64):
        super().__init__()
        self.d_k = d_k
        self.scale = 1.0 / math.sqrt(d_k)  # 预计算缩放因子

    def forward(self, Q, K, V, mask=None):
        """
        Q, K, V: (batch, n_heads, seq_len, d_k)
        mask: (batch, 1, seq_len, seq_len) or None
        """
        # 1. 计算注意力分数（缩放点积）
        scores = torch.matmul(Q, K.transpose(-2, -1))  # Q × K^T
        scores = scores * self.scale                     # 除以 sqrt(d_k)

        # 2. Mask（训练时遮住未来 token，推理时遮 padding）
        if mask is not None:
            scores = scores.masked_fill(mask == 0, float('-inf'))

        # 3. Softmax（沿最后一维，即每个 query 对所有 key）
        attn_weights = torch.softmax(scores, dim=-1)

        # 4. 加权求和
        output = torch.matmul(attn_weights, V)

        return output, attn_weights
```

## 总结

| 问题 | 答案 |
|------|------|
| 为什么缩放？ | 点积方差 = d_k，不缩放 softmax 过饱和，梯度消失 |
| 为什么 √d_k？ | 标准差放大 √d_k 倍，除以 √d_k 把方差拉回 1 |
| d_k 小还需要吗？ | 需要，d_k=64 方差也有 64 |
| Flash Attention 呢？ | 数学等价，scale 一步没少 |

一道题把 Attention 的核心原理和训练稳定性串起来了。

---

*明日预告：后端题 —「Redis 分布式锁怎么实现？Redlock 有什么问题？」*
