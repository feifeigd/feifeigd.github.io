---
title: "KV Cache 优化实战：长上下文推理的内存、量化与驱逐"
date: 2026-08-05T10:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "vllm", "engineering"]
categories: ["Tech"]
description: "KV Cache 为什么吃掉 40GB 显存？从 GQA、PagedAttention 讲到 FP8 量化与 SnapKV 驱逐，给出长上下文推理的可落地优化路线"
---

长上下文是 2026 年推理成本的主战场。模型权重是「一次性」成本——加载一次、人人共享；KV Cache 却是「每次请求」成本——随并发数与上下文长度线性增长。以 Llama-3-70B 为例：fp16 权重约 140GB，而单路 128K 上下文的 KV Cache 在 GQA-8 配置下就要 40GiB，若是 MHA-64 架构则高达 320GiB。权重只装一次，KV 却要为每个并发请求各存一份。这就是为什么「上下文 128K 免费」的口号背后，钱都花在 KV 上。

本文按「架构 → 工程 → 量化 → 驱逐」四层拆解 KV Cache 优化：先算清账，再讲 GQA/MLA 如何从模型侧减量，PagedAttention 与前缀缓存如何复用，FP8/KIVI 如何压缩，最后是 StreamingLLM/H2O/SnapKV 这类「不保留全部」的驱逐方案。数字来自公开论文与可复现的计算，工程建议以 vLLM 为例给出可直接落地的配置。

{/* truncate */}

## 一、先算账：KV Cache 占多少显存

每生成 1 个 token，模型需要为每一层保存该 token 的 Key 与 Value，供后续 token 做 attention。单位 token 的显存占用：

```
per-token bytes = num_layers × num_kv_heads × head_dim × 2(K+V) × bytes_per_elem
```

| 配置 | KV heads | 每 token | 32K 上下文 | 128K 上下文 |
|---|---|---|---|---|
| 7B 级（32 层，GQA-8，head_dim 128，fp16） | 8 | 128 KiB | 4 GiB | 16 GiB |
| Llama-3-70B（80 层，MHA-64，fp16） | 64 | 2560 KiB | 80 GiB | 320 GiB |
| Llama-3-70B（80 层，GQA-8，fp16） | 8 | 320 KiB | 10 GiB | 40 GiB |
| 同上，FP8 KV Cache | 8 | 160 KiB | 5 GiB | 20 GiB |

（算例：7B 级 32×8×128×2×2 = 131,072 B = 128 KiB；70B MHA 80×64×128×2×2 = 2,621,440 B = 2560 KiB；GQA-8 直接除以 8。）

两个结论。其一，KV 与权重性质完全不同：权重是静态的，KV 是动态的——并发 32 路 × 128K 上下文，GQA-8 模型也要 32 × 40GiB = 1.25TB，单机 8×H100（80GB）装不下。其二，架构决定上限：MHA 的 KV 比 GQA 大一个数量级，选型时 KV 头数与层数比参数量更值得关注。

## 二、架构层：GQA 与 MLA 从源头减量

**GQA（Grouped-Query Attention，Ainslie et al. 2023）**把 Query 分组共享 KV head。论文在 T5 上的实验表明：KV 显存降 4–8 倍，多数任务质量损失可忽略（约 0.1–0.5%）。2024 年后发布的主流模型几乎全部采用 GQA 或更低 KV 设计，这不是巧合——长上下文成本倒逼的。

**MLA（Multi-head Latent Attention，DeepSeek-V2 2024）**更进一步：把 K/V 压缩到低秩潜在向量，推理时只需缓存 latent，KV 占用再降 90% 以上。DeepSeek 系模型能以极低 KV 成本支撑 128K+ 上下文，MLA 是核心原因之一（详见 [DeepSeek V4 Flash 技术分析](/blog/2026/08/01/deepseek-v4-flash-analysis)）。

工程含义：对已有模型，架构不可改；但选型时必须看 KV 配置——同样 70B，MHA 与 GQA-8 的长上下文成本差 8 倍，这比几个百分点的基准分重要得多。

## 三、工程层：让 KV 复用而不是重建

**PagedAttention 与块管理。** vLLM 的核心贡献是把 KV 切成固定大小的 block，按需分配，消除连续显存分配的内部碎片，还支持并行采样等场景的 KV 共享。它不减少 KV 总量，但能把可用显存利用率从 60–70% 提到 95%+，详见 [vLLM 架构详解](/blog/2026/07/26/vllm-architecture-deep-dive)。

**前缀缓存（Prefix Caching）。** 对共享的 system prompt、few-shot 示例、RAG 检索结果，命中前缀后 prefill 直接跳过，只算新内容。这是零成本、收益最大的一步：长 system prompt + 短用户输入的场景，prefill 计算可省 70–90%。vLLM 中开 `--enable-prefix-caching` 即可，命中率从 engine metrics 里看。

**Chunked Prefill。** 一个 128K 的 prefill 如果整体执行，会把同批 decode 请求全部堵死（长尾延迟爆炸）。把 prefill 切成 2048 的块与 decode 交错执行，以轻微增加单请求 TTFT 为代价，换取整体吞吐与 p99 延迟的稳定。生产环境几乎必开。

一个可落地的 vLLM 启动配置：

```bash
vllm serve Qwen/Qwen2.5-72B-Instruct \
  --max-model-len 131072 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --chunked-prefill-size 2048 \
  --max-num-seqs 128 \
  --gpu-memory-utilization 0.92
```

`gpu-memory-utilization` 决定权重之外留给 KV 池的显存比例；`max-num-seqs` 与 `max-model-len` 共同决定 KV 池的并发上限——显存不够时优先降 `max-num-seqs`，而不是砍上下文。

## 四、量化层：FP8 与更低位的 KV

KV 量化是典型的「显存换带宽」：KV 变小 → 同显存可缓存更多 token/请求 → 吞吐上升，代价是精度损失。主流方案：

- **FP8 KV Cache**：NVIDIA Hopper/Ada 硬件原生支持，KV 占用直接减半。vLLM 的官方实现报告多数任务相对 fp16 差异 <0.5%，长上下文场景建议配合回归评测使用。
- **KIVI（2-bit K / 4-bit V，2024）**：对 K 做 per-channel 量化、V 做 per-token 量化，并保留少量高精度 outlier 通道。70B 模型在 4-bit KV 下质量接近 fp16，KV 占用降到约 1/4。
- **KVQuant（3/4-bit 非均匀，2024）**：per-channel K + per-token V，配合非均匀量化与 dense-sparse 结构，针对长上下文做了专门校准，论文报告单卡吞吐可提升 3–5 倍。

KIVI 的核心思路实现上并不神秘——离线算 per-channel 缩放，推理时只做整数量化：

```python
# 伪代码：per-channel 量化 K 缓存（4-bit）
def quantize_kv(k, bits=4, group=128):
    k = k.view(-1, group)
    scale = k.abs().amax(dim=-1) / (2 ** (bits - 1) - 1)
    k_q = (k / scale.unsqueeze(-1)).round().clamp_(-128, 127).to(torch.int8)
    return k_q, scale   # 反量化：k_q.float() * scale.unsqueeze(-1)
```

量化不是免费的：需要离线校准集，且必须在长序列上验证误差是否累积。这正是「评测即门禁」的用武之地——KV 量化上线前必须跑一遍回归集（见 [LLM 评测的工程化](/blog/2026/08/04/llm-eval-llm-as-judge)）。

## 五、驱逐层：不保留全部 KV

如果连量化后的 KV 都放不下，最后的手段是「不全留」。三类代表性工作：

- **StreamingLLM（2023）**：保留前 4 个 attention sink token + 滑动窗口，解决「文本超长后注意力崩溃」，代价是中间信息不可见——适合流式对话，不适合文档理解。
- **H2O（Heavy-Hitter Oracle，2023）**：按 token 的累计 attention 分数判断重要性，流式驱逐「轻量」token。论文显示保留 20% KV 时多数任务不掉分。
- **SnapKV（2024）**：针对 prompt 压缩——只保留 attention 峰值位置的 KV，压缩比约 3.2×，长上下文 QA 质量稳定。对「超长文档 + 一次问答」非常实用。

组合实践：

| 场景 | 手段组合 |
|---|---|
| RAG / 长 system prompt | 前缀缓存 + SnapKV 压缩 prompt 侧 KV |
| 多轮对话 | 滑动窗口 + H2O 驱逐 + FP8 |
| 文档理解（单次长上下文问答） | 全量 KV + FP8 / KIVI 量化 |
| 视频/多图理解 | 前缀缓存 + 严格帧采样（见[多模态一文](/blog/2026/08/05/multimodal-vlm-engineering-guide)） |

## 六、落地顺序与度量

优化收益递减、成本递增，建议按此顺序：

1. **前缀缓存**——一行配置，命中即省 70%+ prefill；
2. **FP8 KV**——一行配置，KV 减半；
3. **调度参数**（chunked prefill、max-num-seqs）——压 p99 延迟；
4. **量化/驱逐**——需要离线校准与回归评测，收益最大但成本最高；
5. **换 GQA/MLA 模型**——只在选型时有机会。

度量比优化更重要：vLLM 的 Prometheus metrics 重点盯 `vllm:cache_hit_rate`（前缀缓存命中率）与 KV 池使用率；压测用官方 benchmark，对比开关各项优化前后的吞吐与 TTFT：

```bash
python -m vllm.bench.benchmark_throughput \
  --model Qwen/Qwen2.5-72B-Instruct \
  --input-len 8192 --output-len 1024 --num-prompts 64
```

## 结论

KV Cache 是长上下文推理成本的核心变量，优化路径清晰：**架构定上限（GQA/MLA），工程提复用（前缀缓存、分块 prefill），量化降单位成本（FP8/KIVI），驱逐保下限（窗口 + 重要 token 保留）**。四层叠加，同样的硬件可以把有效上下文吞吐提高一个数量级。关键原则是每一层都要可度量、可回滚——KV 量化与驱逐直接影响质量，必须用回归评测守门。

**相关阅读**
- [vLLM 架构详解：PagedAttention、Continuous Batching 与生产级推理优化](/blog/2026/07/26/vllm-architecture-deep-dive)
- [LLM 推理中的存储 I/O 优化：从 HDD 到 CXL 的演进](/blog/2026/07/27/llm-inference-storage-io-optimization)
- [LLM 量化技术实战指南：从 FP8 到 INT4 的生产级优化](/blog/2026/07/30/llm-quantization-production-guide)
- [LLM 评测的工程化：从基准分数到 LLM-as-a-Judge 的生产实践](/blog/2026/08/04/llm-eval-llm-as-judge)
- [大模型分布式训练的并行策略：从数据并行到 3D 并行与专家并行](/blog/2026/08/04/distributed-training-parallelism)

**参考来源**
- Ainslie et al.: [GQA: Training Generalized Multi-Query Transformer Models from Multi-Head Checkpoints](https://arxiv.org/abs/2305.13245)
- DeepSeek-AI: [DeepSeek-V2: A Strong, Economical, and Efficient Mixture-of-Experts Language Model](https://arxiv.org/abs/2405.04434)
- Kwon et al.: [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180)
- Liu et al.: [KIVI: A Tuning-Free Asymmetric 2bit Quantization for KV Cache](https://arxiv.org/abs/2402.02750)
- Coleman et al.: [KVQuant: Towards 10 Million Context Length LLM Inference with KV Cache Quantization](https://arxiv.org/abs/2401.18079)
- Xiao et al.: [Efficient Streaming Language Models with Attention Sinks](https://arxiv.org/abs/2309.17453)
- Zhang et al.: [H2O: Heavy-Hitter Oracle for Efficient Generative Inference of Large Language Models](https://arxiv.org/abs/2306.14048)
- Li et al.: [SnapKV: LLM Knows What You are Looking for Before Generation](https://arxiv.org/abs/2404.14469)
- vLLM: [FP8 KV Cache 官方博客](https://blog.vllm.ai/2024/07/23/fp8-kv-cache.html)
