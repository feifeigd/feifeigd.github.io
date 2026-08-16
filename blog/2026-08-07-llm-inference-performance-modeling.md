---
title: "LLM 推理性能建模：用 Roofline 模型回答『需要多少张卡』"
date: 2026-08-07T10:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "engineering", "infra"]
categories: ["Tech"]
description: "从算力-带宽第一性原理推导 LLM 推理吞吐与延迟模型：Roofline、算术强度、批量效应与容量规划实例"
---

「一个 70B 模型、每天 10 万请求、p95 TTFT 小于 1 秒，需要多少张 H100？」如果你问云厂商销售，答案取决于他的季度指标；如果你问架构师，答案应该取决于一张纸上的数学。LLM 推理的性能不是靠 benchmark 榜单「测」出来的，而是可以被两条硬件参数——峰值算力和内存带宽——从第一性原理「算」出来的。

本文沿用 Roofline 模型的分析框架（参考 Sid Babu 2026 年 5 月的同名长文），把 prefill 与 decode 两个阶段的吞吐、延迟写成可计算的代数式，再用 70B 模型在 H100/B200 上的具体数字验证，最后给出一个完整的容量规划实例。看完你会理解三件事：为什么 decode 阶段「大 batch 包治百病」是错的、为什么长上下文是推理成本的真正杀手、以及为什么 FLOPs 越高不代表推理越快。

{/* truncate */}

## 一、两条硬件参数决定一切

任何 GPU 的推理能力都可以压缩成两个数：

| 参数 | 含义 | H100 SXM | B200 | H20 |
|---|---|---|---|---|
| π（峰值算力） | BF16 稠密张量算力 | 989 TFLOPS | 2250 TFLOPS | 148 TFLOPS |
| β（内存带宽） | HBM 带宽 | 3.35 TB/s | 8.0 TB/s | 4.0 TB/s |
| ridge point（π/β） | 算术强度分界点 | 295 FLOP/byte | 281 FLOP/byte | 37 FLOP/byte |

（注：NVIDIA 官方宣传的 1979 TFLOPS 是 2:4 结构化稀疏算力，稠密场景下要除以 2。H20 是「带宽强、算力弱」的典型，它的 ridge point 只有 37，意味着一丁点算术强度就能喂饱算力单元。）

**Roofline 模型**把任何工作负载的实际性能写成一个 min 表达式：

```
Performance = min(π, β × Arithmetic Intensity)
```

其中算术强度（Arithmetic Intensity）= 每加载 1 字节数据能做的浮点运算数。如果负载的算术强度低于 ridge point，性能被内存带宽卡住（memory-bound），提高算力毫无意义；高于 ridge point 才是算力受限（compute-bound）。LLM 推理的两个阶段恰好分处两侧——这就是它和传统高密度计算最本质的区别。

## 二、decode 的算术强度：为什么单流只有 24 tok/s

先给模型定义一个标准推导（以下用 BF16、batch 为 B、序列长度为 S、单次前向解码 λ 个 token）：

- 权重矩阵乘 FLOPs：`2PBλ`（P 为参数量）
- Attention FLOPs：`4BLSdλ`（L 为层数，d 为隐藏维度，d = H × d_h）
- 加载字节数：`2P`（权重）+ `4BSL·H_kv·d_h`（KV Cache）+ 激活（通常可忽略）

于是 decode 的算术强度为：

```
AI_decode = (2PBλ + 4BLSdλ) / (2P + 4BSL·H_kv·d_h)
```

两个极限分析比完整公式更有洞察力：

- **短上下文（S→0）**：`AI ≈ Bλ`。算术强度与 batch 成正比——**batch 越大，每加载一次权重做的工作越多**，这就是「批量提升吞吐」的原理。
- **长上下文（S→∞）**：`AI ≈ λ·H/H_kv`。batch 项消失了！**在 KV 主导读带宽的场景下，加大 batch 不再提升算术强度**——算术强度只取决于 GQA 比例（H/H_kv）和投机解码的 λ。

用具体数字验证。Llama-3-8B（32 层、GQA-8、head_dim 128）BF16 权重约 16GB，每 token 的 KV 为 `4×32×8×128 = 131,072 B = 128 KiB`。**权重与 KV 读取量相等的交叉点**：16GB ÷ 128KiB ≈ 12.2 万 token。batch 为 128 时，每序列只需要约 953 个 token，KV 读取就超过权重——进入长上下文记忆受限区。

再看 70B 模型（80 层、GQA-8）：权重 140GB、每 token KV 320 KiB，交叉点在 batch=1 时约 43.7 万 token，batch=128 时每序列仅约 3337 token。**Agent 场景里动辄 1 万 token 以上的 system prompt + 工具结果，几乎必然落在记忆受限区**——这就是「上下文越长越贵」的数学根源。

## 三、延迟模型：单流 tok/s 的硬天花板

单流 decode（B=1、短上下文）每步必须把全部权重从 HBM 搬到计算单元：时间 ≈ 权重字节 / 带宽。

| 模型与精度 | 权重体积 | H100 | B200 | H20 |
|---|---|---|---|---|
| 7B BF16 | 14 GB | 239 tok/s | 571 tok/s | 286 tok/s |
| 70B BF16 | 140 GB | 24 tok/s | 57 tok/s | 29 tok/s |
| 70B FP8 | 70 GB | 48 tok/s | 114 tok/s | 57 tok/s |
| 405B FP8 | 405 GB | 8 tok/s | 20 tok/s | 10 tok/s |

（表中 B200 单流 70B 约 57 tok/s，而 H20 因为带宽尚可反而比 H100 单流更快——**单流 decode 只认带宽，不认 FLOPs**。）

这就是为什么量化的第一受益者是单流延迟：FP8 把权重减半，单流 tok/s 直接翻倍。推理卡的选型逻辑也因此反直觉——**面向交互式单流延迟，带宽比算力重要；面向批量吞吐，两者都要看**。

## 四、吞吐模型：batch 与 KV 的拉锯战

多流共享权重后，每步时间 ≈ `(2P + B×S×kv_per_token) / β`，聚合吞吐 = B ÷ 每步时间。70B GQA-8 BF16 在 H100 上的模拟（S=1K 上下文）：

| batch | 每步 KV 读取 | 每步总字节 | 每步时间 | 聚合吞吐 | 每流 tok/s |
|---|---|---|---|---|---|
| 1 | 0.3 GB | 140 GB | 41.8 ms | 24 | 24 |
| 32 | 11 GB | 151 GB | 45.0 ms | 711 | 22 |
| 128 | 43 GB | 183 GB | 54.6 ms | 2344 | 18 |
| 512 | 172 GB | 312 GB | 93.1 ms | 5500 | 11 |
| 2048 | 687 GB | 827 GB | 247 ms | 8293 | 4 |

两个结论。其一，**吞吐随 batch 上升但边际递减**：从 128 到 2048 翻了 16 倍 batch，吞吐只涨 3.5 倍——KV 读取逐渐压倒权重加载。其二，**每流 tok/s 随 batch 下降**：这就是「吞吐与延迟不可兼得」的数学表达，batch 越大，单用户越慢。

长上下文则直接放大 KV 项。同样 B=32，把上下文从 1K 拉到 32K：KV 读取从 11GB 涨到 344GB，每步时间从 45ms 涨到 144ms，聚合吞吐从 711 掉到 222 tok/s，每流只剩约 7 tok/s。**如果你在做一个每轮塞 30K token 上下文的 Agent，单流生成速度就是这么难看**——这也是前缀缓存、KV 量化、上下文裁剪（见文末相关阅读）价值最大的场景。

## 五、prefill 是算力问题：TTFT 的公式

与 decode 相反，prefill 阶段算力密集：一次性处理 S 个 token，FLOPs = 2PS，时间 ≈ `2PS / (π × MFU)`。70B 模型在不同 MFU 下的 TTFT 估算：

| 输入长度 | FLOPs | 50% MFU | 60% MFU |
|---|---|---|---|
| 1K tokens | 1.4e14 | 0.28 s | 0.24 s |
| 8K tokens | 1.1e15 | 2.26 s | 1.89 s |
| 32K tokens | 4.5e15 | 9.06 s | 7.55 s |

真实世界的 MFU 经验值：prefill（长序列）可达 40–60%，decode 视 batch 从个位数到 30%+——差异的根源就是算术强度差了两个数量级。**TTFT 的优化杠杆是算力与算法（并行、chunked prefill），TPOT 的杠杆是带宽与数据体积（量化、KV 压缩）**，两者不要混为一谈。

## 六、容量规划实例：100 RPM 的 70B 服务要几张卡

假设：Llama-70B GQA-8 BF16，平均每请求 2K 输入 / 1K 输出，H100，目标 100 RPM（requests per minute），TTFT p95 小于 1 秒。

**解码吞吐需求**：100 RPM × 1000 输出 token = 10 万 token/min ≈ 1667 tok/s。

**单卡供给**（S=2K、batch=128）：KV 读取 = 128 × 2048 × 320 KiB = 82 GB，每步总字节 222 GB，每步 66 ms，聚合吞吐 ≈ 1939 tok/s。理论上一张卡就够——但注意这是「满载」状态，TTFT 还背着排队与 prefill 成本：2K prefill 在 50% MFU 下约 0.56 秒，batch 128 下排队延迟轻松超过 p95 预算。

**工程结论**：起步 2 张卡（一张扛不住峰值，另一张留余量）；若上下文从 2K 提到 32K，单卡 batch 64 时 KV 读取已达 687 GB……不对，重算：64 × 32K × 320 KiB = 640 GB，加权重 140 GB 共 780 GB，每步 233 ms，聚合吞吐仅 275 tok/s——**同样的 100 RPM 需求直接变成 6–8 张卡**。这就是为什么「支持 128K 上下文」的模型，在实际容量规划里常常只能给用户开 8K。优化杠杆按性价比排序：前缀缓存（免费）→ FP8 权重（吞吐 ×2）→ KV 量化（长上下文显存减半）→ 投机解码（λ 提升算术强度，见相关阅读）。

## 结论

LLM 推理性能不需要玄学：**decode 是带宽问题，prefill 是算力问题，batch 拉高吞吐但牺牲单流延迟，长上下文把 decode 拖进 KV 记忆受限区**。用 Roofline 模型和三四个乘法，采购前就能算出需要的卡数、量化收益和上下文预算。下次销售说「这张卡 FLOPs 翻倍所以快两倍」时，你可以礼貌地请他先算一下算术强度。

**相关阅读**
- [vLLM 架构详解：PagedAttention、Continuous Batching 与生产级推理优化](/blog/2026/07/26/vllm-architecture-deep-dive)
- [KV Cache 优化实战：长上下文推理的内存、量化与驱逐](/blog/2026/08/05/kv-cache-optimization-guide)
- [LLM 量化技术实战指南：从 FP8 到 INT4 的生产级优化](/blog/2026/07/30/llm-quantization-production-guide)
- [投机解码深度解析：草稿模型如何把推理吞吐提升 2-3 倍](/blog/2026/08/06/speculative-decoding-deep-dive)
- [LLM 推理中的存储 I/O 优化：从 HDD 到 CXL 的演进](/blog/2026/07/27/llm-inference-storage-io-optimization)

**参考来源**
- Sid Babu: [Modeling LLM Performance from First Principles](https://sidbabu.com/posts/llm-perf-modeling)
- Aleksa Gordić: [Inside vLLM: Anatomy of a High-Throughput LLM Inference System](https://www.aleksagordic.com/blog/vllm)
- Kwon et al.: [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180)
- NVIDIA: [H100 数据中心 GPU 规格](https://www.nvidia.com/en-us/data-center/h100/)
