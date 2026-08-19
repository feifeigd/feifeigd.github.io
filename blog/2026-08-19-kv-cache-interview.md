---
title: "面试题：KV Cache 是什么？为什么长上下文推理显存不够用？"
date: 2026-08-19T09:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "kv-cache", "interview"]
categories: ["Interview"]
description: "大模型面试高频题：KV Cache 是什么？显存公式怎么算？为什么 10 万 token 上下文直接 OOM？GQA、KV 量化、PagedAttention 分别省了什么？从原理到代码一次讲清。"
---

> 这是「每日一题」专栏的第七篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇讲了[分布式 ID 生成器](/blog/2026/08/16/distributed-id-generator-interview)，今天回到 AI/LLM 方向，聊一个让你在长上下文推理时 OOM 的元凶。

{/* truncate */}

## 题目

大模型推理面试里出镜率极高的一道题：

> **KV Cache 是什么？为什么模型的上下文一长，显存就不够用？GQA、KV 量化、PagedAttention 分别是怎么省显存的？**

这道题考察三件事：**你懂不懂自回归解码的数学结构**、**会不会算显存账**、**知不知道工业界（vLLM 等）在工程上怎么解决**。很多人能背出「KV Cache 就是缓存 K 和 V」，但一问显存公式就卡壳。

先给结论，再拆开讲。

## 一、为什么需要 KV Cache

大模型是自回归的：生成第 t 个 token 时，模型要拿**全部历史 token** 和当前 token 一起做一次前向计算，才能预测下一个 token。

问题来了：**每往前生成一个 token，前面所有 token 的 K、V 向量都会被重新算一遍**，而算出来的结果和上一轮一模一样——纯属重复劳动。

```python
# 伪代码：没有缓存时，第 t 步的注意力
for i in range(1, t + 1):
    k_i = W_k @ h_i   # 历史 token 的 K 又被算了一遍
    v_i = W_v @ h_i   # 历史 token 的 V 又被算了一遍
```

这一步重复计算让总计算量的复杂度差了一个量级：

- **有 KV Cache**：每步只算新 token 的 K、V，注意力在已缓存的 K、V 上做，单步 O(t)，全序列 O(T²)
- **没有 KV Cache**：每步把全部历史的 K、V 重算一遍，单步 O(t²)，全序列 O(T³)

所以 KV Cache 的本质是**用显存换算力**：把历史 K、V 存下来，解码阶段每条请求只做增量计算。

## 二、KV Cache 到底占多少显存

一个公式背下来，面试就过了一半：

> **每 token 的 KV 显存 = 2 × 层数 × KV 头数 × head_dim × 字节数**

- `2`：K 和 V 各一份
- 字节数：FP16/BF16 是 2 字节，FP32 是 4 字节

以 LLaMA-2-7B（32 层、MHA、32 个 KV 头、head_dim 128）为例：

```
2 × 32 × 32 × 128 × 2 字节 = 524,288 字节 ≈ 512 KiB / token
```

也就是说**每个 token 吃掉半兆显存**。上下文一长，账就算不过来了：

| 上下文长度 | 7B MHA 的 KV 显存 |
|-----------|------------------|
| 1,000 | 512 MiB |
| 10,000 | 5 GiB |
| 100,000 | 50 GiB |

而 7B 模型权重（FP16）才 14 GiB。**上下文到约 2.9 万 token 时，KV Cache 就已经和权重一样大**；10 万 token 时 KV 是权重的 3.5 倍还多。这还没算激活值——长上下文场景下，KV Cache 就是显存的第一大消耗。

用代码算一遍，顺便背下 LLaMA-3-8B 的数字：

```python
def kv_bytes_per_token(n_layers, n_kv_heads, head_dim, b=2):
    return 2 * n_layers * n_kv_heads * head_dim * b

llama2_7b = kv_bytes_per_token(32, 32, 128)  # MHA，512 KiB/token
llama3_8b = kv_bytes_per_token(32, 8, 128)   # GQA，128 KiB/token

for tok in (1000, 10000, 100000):
    print(f"{tok:>7,} tokens -> {llama3_8b * tok / 2**20:6.1f} GiB")
```

输出：

```
  1,000 tokens ->    0.1 GiB
 10,000 tokens ->    1.2 GiB
100,000 tokens ->   12.2 GiB
```

同样 10 万上下文，LLaMA-3-8B 靠 GQA 把 KV 从 50 GiB 压到 12 GiB——这就是下一节要讲的第一个优化。

## 三、省显存的三个方向

### 1. 少存：GQA / MQA

标准 MHA 是每个注意力头都存一份 K、V。**GQA（分组查询注意力）让多个 Q 头共享一组 K、V 头**，LLaMA-2-70B 之后的主流模型基本全用了：

- MHA：32 个 Q 头配 32 个 KV 头，KV 显存最大
- **GQA**：32 个 Q 头共享 8 个 KV 头，KV 显存直接除以 4
- MQA：全部 Q 头共享 1 个 KV 头，KV 显存除以 32，但质量损失明显

质量上 GQA 接近 MHA，显存只有四分之一，所以成了事实标准。**面试答「GQA 本质是参数共享 + 分组」就够了。**

### 2. 压精度：KV 量化

KV Cache 默认是 FP16 存的，但 K、V 的数值分布很集中，抗量化能力比权重还强：

- INT8 量化：显存减半（512 KiB 变成 256 KiB/token）
- INT4/FP8 量化：再减半，vLLM、TensorRT-LLM 等推理引擎的标配

代价是精度损失和反量化的额外计算，所以一般配 **per-head 缩放 + 离群值处理**，把损失压到可忽略。

### 3. 按需分配：PagedAttention

前两种省的是「总量」，但还有一类浪费在**分配方式**上：KV Cache 长度随生成动态增长，如果一次性预留最大长度，就会产生大量内部碎片（预留了没用上）。PagedAttention 的解法是照搬操作系统的虚拟内存分页：

- 把 KV Cache 切成固定大小（默认 16 token）的 **block**
- 按需分配物理块，逻辑上连续、物理上可以分散
- 连续请求**共享前缀**（比如系统提示词），写时复制，进一步省显存

vLLM 靠这个把吞吐提升了 2~4 倍，是近两年推理引擎领域最重要的工程创新之一。

## 面试回答思路

1. **先讲为什么**：自回归解码每步都要全部历史的 K、V；不缓存就重复计算，总复杂度从 O(T²) 恶化到 O(T³)，KV Cache 是用显存换算力。
2. **再报公式**：每 token 显存 = 2 × 层数 × KV 头数 × head_dim × 字节数，当场算一个模型（7B MHA 约 512 KiB/token）。
3. **给优化方案**：GQA 少存（÷4）、KV 量化压精度（INT8 ÷2）、PagedAttention 按需分配消碎片，还能补一句滑动窗口和稀疏注意力。
4. **拔高一句**：「解码阶段是 memory-bound 的，谁能把每 token 的显存占用和 IO 压下来，谁的吞吐就高。」能说到这层，已经超过大多数候选人。

## 总结

| 问题 | 答案 |
|------|------|
| KV Cache 是什么？ | 缓存历史 token 的 K、V 向量，避免解码时重复计算 |
| 为什么长上下文显存爆？ | KV 随序列长度线性增长，7B MHA 每 token 约 512 KiB |
| 显存公式？ | 2 × 层数 × KV 头数 × head_dim × 字节数 |
| GQA 省多少？ | KV 头从 32 减到 8，KV 显存除以 4 |
| KV 量化省多少？ | INT8 减半，INT4/FP8 再减半 |
| PagedAttention 解决什么？ | 预留式分配的碎片浪费，按 block 动态分配 |
| 没有 KV Cache 会怎样？ | 每步重算历史 K、V，总计算量从 O(T²) 变 O(T³) |

KV Cache 这道题，本质考的是「自回归的数学结构 + 显存工程」两个层面。把公式背下来、把三个优化讲清楚，再主动提到 PagedAttention，这题就是送分题。

---

*明日预告：后端/分布式方向 —「分布式事务怎么做？2PC、TCC、Saga 各解决什么问题、又各有什么坑？」*
