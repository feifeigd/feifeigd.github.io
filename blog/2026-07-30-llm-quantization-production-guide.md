---
title: "LLM 量化技术实战指南：从 FP8 到 INT4 的生产级优化"
date: 2026-07-30T10:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "gpu", "engineering"]
categories: ["Tech"]
description: "从 FP8 到 INT4，详解 LLM 量化技术的原理、工程实践与性能权衡"
---

# LLM 量化技术实战指南：从 FP8 到 INT4 的生产级优化

> 本文是推理优化系列的第二篇。前篇《[vLLM 架构深度解析](/blog/2026/07/26/vllm-architecture-deep-dive)》从推理引擎层面探讨了性能优化，本篇聚焦另一个关键维度——**模型量化**。

2025-2026 年，量化技术从「部署技巧」演变为「训练流程的一等公民」。FP8 被 Blackwell GPU 原生支持，INT4 通过 AWQ/GPTQ 等算法几乎追平 FP16 的准确率，而 KV-cache 量化更是成为长上下文推理的标配。

本文从工程实现角度，系统梳理 LLM 量化的核心概念、主流方案的生产级对比，以及关键陷阱。

{/* truncate */}

## 一、为什么需要量化？

量化的本质很简单：用更少的比特数表示模型参数，换取推理速度、显存消耗和带宽效率的提升。

| 数据类型 | 比特数 | 显存占用（70B 模型） | 相对 FP16 速度 | 典型应用场景 |
|----------|--------|---------------------|----------------|-------------|
| FP32     | 32     | 280 GB              | 1× (baseline)  | 训练（极少推理用） |
| FP16/BF16 | 16    | 140 GB              | 1-1.2×         | 训练、高精度推理 |
| FP8      | 8      | 70 GB               | 1.5-2×         | 推理、训练回放 |
| INT4     | 4      | 35 GB               | 2-3×           | 推理部署 |
| INT2     | 2      | 17.5 GB             | 3-4×           | 实验阶段 |

由于 LLM 推理是内存带宽绑定的（memory-bandwidth bound），**权重每减少一半比特数，理论上吞吐翻倍**。这在大规模部署时意味着显著的 TCO 优势。

## 二、量化技术谱系

### 2.1 训练后量化（PTQ）

PTQ 是最成熟的路径：权重训练完成后，用少量校准数据计算量化参数。

**GPTQ**（2023）：基于 Optimal Brain Quantization 框架，逐层（layer-wise）求解最小化量化误差的最优权重舍入方案。在 Llama-2 70B 上，4-bit GPTQ 的 perplexity 退化小于 0.5。

**AWQ**（2024）：观察到权重中只有约 1% 的「salient channels」对量化敏感，通过逐通道缩放因子保护这些通道。同等比特率下，AWQ 的困惑度比 GPTQ 低 0.1-0.3，且校准速度快 5-10×。

**SmoothQuant**（2023）：针对激活值量化，通过数学变换将激活分布的 outliers 从难量化维度转移到权重上，使得 INT8 激活量化首次在 LLM 上可行。

### 2.2 量化感知训练（QAT）

QAT 将量化伪操作（fake quantization）插入训练过程，使模型学会适应量化噪声。虽然训练成本高，但通常是精度损失最小的方案。

2025 年两个重要进展：

1. **FP8 QAT 成为标准**：Blackwell B200 的原生 FP8 Tensor Core 让 FP8 QAT 从「可选优化」变为「推荐路径」。NVIDIA 的报告显示，FP8 QAT 训练的 Llama-3 在 MMLU 上仅损失 0.1-0.2%。

2. **INT4 QAT 实用化**：LLM-QAT 框架将蒸馏与 QAT 结合，用 FP16 teacher 指导 INT4 student。2026 年 Q1，MIT 团队的 QLoRA+ 论文表明，4-bit 量化的指令微调模型在 HumanEval 上达到了 FP16 的 98.7%。

### 2.3 FP8 训练

2025-2026 年最关键的行业变化是 FP8 从推理扩展到训练链路。

```python
# FP8 训练的关键伪代码（以 PyTorch 2.5+ 为例）
import torch
from torch.fp8 import fp8_autocast, DelayedScaling

# 配置 FP8 延迟缩放
ds_config = DelayedScaling(
    margin=0,               # 防止溢出
    interval=1,             # 每步更新缩放因子
    fp8_format="E4M3",      # 权重和激活用 E4M3
    amax_history_len=16,    # 历史最大值滑动窗口
    amax_compute_algo="max" # 取窗口内最大值
)

with fp8_autocast(enabled=True, dtype=torch.float8_e4m3fn):
    # FP8 前向传播：W8A8
    output = linear_layer(input)
    # 梯度计算仍保持 FP16/BF16 精度
    loss.backward()
```

实际部署中，FP8 训练通常遇到两个工程挑战：

- **缩放因子抖动**：当 batch 中出现极端激活值时，缩放因子过小导致下溢。解决方案是分层缩放（per-tensor 而非 per-token）。
- **梯度累积精度**：在 FSDP（Fully Sharded Data Parallel）场景下，梯度 all-reduce 用 FP8 通信会损失大梯度。常见做法是 FP16 梯度同步，本地步进用 FP8。

## 三、生产级量化方案对比

下表对比了当前主流量化框架（2026 年 Q2 状态）：

| 特性 | vLLM (AWQ) | TensorRT-LLM | llama.cpp (GGUF) | ExLlamaV2 |
|------|-----------|--------------|-------------------|-----------|
| 支持比特率 | W4A16, W8A16, FP8 | W4A16, FP8, INT8 | 2-8 bit 任意 | 4-bit, 5-bit, 6-bit, 8-bit |
| 量化算法 | AWQ, GPTQ | SmoothQuant, FP8 QAT | K-quants | EXL2 (自研) |
| GPU 架构 | Ampere+ | Ampere+ (FP8 需 Ada+) | 任意 | CUDA only |
| 批处理 | 连续批处理（最优） | 静态批处理 | 共享内存批处理 | 动态批处理 |
| 内存效率 | PagedAttention | 预分配 | mmap 按需加载 | 预分配 |
| 峰值吞吐 | ★★★★★ | ★★★★ | ★★ | ★★★ |

### 3.1 实战选择指南

**场景 A：高并发在线服务（RPS > 100）**

推荐：vLLM + AWQ INT4

理由：vLLM 的 PagedAttention + 连续批处理在 4-bit 下配合 FP16 KV-cache 可实现 8× 的 Llama-70B 服务密度。AWQ 在 INT4 下保持 99%+ 的 FP16 准确率。

```bash
# vLLM + AWQ 启动命令
python -m vllm.entrypoints.openai.api_server \
    --model meta-llama/Llama-3.1-70B \
    --quantization awq \
    --dtype auto \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.9 \
    --max-num-seqs 64
```

**场景 B：单 GPU 部署（24GB VRAM）**

推荐：llama.cpp + Q4_K_M GGUF

理由：当显存受限时，llama.cpp 的 K-quant 方案（如 Q4_K_M）在压缩比与质量之间取得了最佳平衡。可以使用 mmap 将部分权重存储在 CPU 内存中，实现 13B 模型在单卡运行。

```bash
# 使用 llama.cpp 量化并运行
./llama-quantize \
    --model model.gguf \
    --output model-q4_k_m.gguf \
    --quantize q4_k_m

./llama-server \
    --model model-q4_k_m.gguf \
    --ctx-size 4096 \
    --n-gpu-layers 32
```

## 四、KV-Cache 量化：长上下文的隐藏瓶颈

当上下文长度超过 32K tokens 时，KV-cache 的显存占用超过权重，成为推理瓶颈。以 70B 模型、batch=1 为例：

| 上下文长度 | KV-cache (FP16) | KV-cache (FP8) | KV-cache (INT4) |
|-----------|-----------------|----------------|-----------------|
| 32K       | 8 GB            | 4 GB           | 2 GB            |
| 128K      | 32 GB           | 16 GB          | 8 GB            |
| 1M        | 256 GB          | 128 GB          | 64 GB           |

KVCache 量化有两大主流方案：

**KIVI**（2024）：per-channel 的 key cache 保持 FP16，per-token 的 value cache 量化为 INT4。KIVI 在 4-bit KV-cache 下维持了 99.9% 的原始准确率。

**FP8 KV-cache**（2025+）：Hopper GPU 通过 `cuda:8` 支持 FP8 的张量核心运算，vLLM 的 FP8 KV-cache 实现无需在校准集上跑额外步骤，开箱即用。

```python
# vLLM 启用 FP8 KV-cache
from vllm import LLM, SamplingParams

llm = LLM(
    model="meta-llama/Llama-3.1-8B-Instruct",
    kv_cache_dtype="fp8",          # FP8 KV-cache
    quantization="fp8",            # FP8 权重
    max_model_len=131072,          # 128K 上下文
    gpu_memory_utilization=0.95,
)

# 在 2×A100 80GB 上可运行 128K 上下文的 Llama-70B
```

## 五、量化陷阱与诊断

### 陷阱 1：Perplexity 不降，但下游任务崩了

Perplexity 是 token-level 的聚合指标，对局部异常不敏感。一个权重 outlier 被截断可能导致特定序列的准确率断崖下跌。

**诊断方案**：在评估 pipeline 中加入「per-sequence 的 logprob 标准差」监控。如果某些序列的 logprob 相对于 FP16 reference 剧烈下降（>3σ），应调高这些序列对应层的量化比特率（混合精度量化）。

### 陷阱 2：INT4 下组大小（Group Size）的微妙影响

AWQ/GPTQ 中的 `group_size`（通常 128 或 64）决定了量化粒度和存储开销的权衡。

| Group Size | 存储开销 | 量化质量 | 典型场景 |
|-----------|---------|---------|---------|
| 128       | 低      | 良好    | 默认推荐 |
| 64        | 中等    | 优秀    | 对精度敏感的小模型 |
| 32        | 高      | 极好    | 关键层混合精度 |

### 陷阱 3：FP8 E4M3 与 E5M2 的选择

FP8 有两种格式：
- **E4M3**（4-bit 指数，3-bit 尾数）：适用于权重和激活的前向传播
- **E5M2**（5-bit 指数，2-bit 尾数）：适用于梯度（需要更大的动态范围）

混用两者的混合精度方案已成为事实标准，但要注意硬件支持差异：H100 从 SM90 开始原生支持 E4M3，而 A100 需要软件模拟（慢 2-3×）。

## 六、前沿方向

### 6.1 量化感知训练 + 蒸馏（QAT+D）

2026 年 Q1，Anthropic 公开了他们的 QAT+D 方案：在 RLHF 阶段直接使用 INT4 前向传播计算 reward，使偏好对齐过程本身就「习惯」量化噪声。最终模型的 INT4 版本在 Claude 3.5 级别的基准测试中仅损失 0.3%。

### 6.2 动态精度推理（DAP）

MIT-IBM Watson 联合团队提出的 DAP 方案，在推理时根据每层输入数据的特征动态选择比特率。通过一个轻量级 predictor（~10M 参数）预测每层的最优精度，平均实现 3.5-bit 等效推理，且不损失准确率。

### 6.3 存内计算（CIM）专精量化

随着三星、台积电的存内计算芯片量产（2026 年），量化方案需要适配 CIM 的模数转换（ADC）精度限制。4-bit 及以下量化将成为 CIM 芯片的标准推理格式。

## 相关阅读

- [vLLM 架构深度解析](/blog/2026/07/26/vllm-architecture-deep-dive) — 推理引擎层面的性能优化
- [LLM 推理中的存储 I/O 优化](/blog/2026/07/27/llm-inference-storage-io-optimization) — 从存储角度谈推理性能
- [Kimi-K3 深度解析：2.8T 开源 MoE 模型的架构创新](/blog/2026/07/29/kimi-k3-architecture-analysis)
