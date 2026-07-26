---
title: "vLLM 架构详解：PagedAttention、Continuous Batching 与生产级推理优化"
date: 2026-07-26T14:00:00+08:00
draft: false
tags: ["ai", "llm", "vllm", "inference", "architecture", "engineering"]
categories: ["Tech"]
description: "深入剖析 vLLM 的核心技术——PagedAttention 与 Continuous Batching 的设计哲学与实现细节"
---

> 本文是 AI Infra 系列的实战篇，前篇《[AI Infra 到底是什么](/blog/2026/07/07/ai-infra-what-is-it)》梳理了 AI 基础设施的四层架构，本文聚焦推理层最核心的开源项目——vLLM。

## 前言：为什么 vLLM 是推理引擎的标杆

大模型推理引擎有很多：TGI（HuggingFace）、TensorRT-LLM（NVIDIA）、SGLang、CTranslate2……但在开源社区中，**vLLM 是目前最流行、生态最好的通用推理引擎**。

它解决了 LLM 推理中三个核心痛点：

1. **显存浪费**：传统方案 KV Cache 需要预分配最大序列长度，实际序列通常短得多，造成高达 60-80% 的显存浪费
2. **吞吐量低**：静态批处理无法动态管理请求，GPU 利用率难以提高
3. **调度僵化**：不支持抢占、不可用请求灵活排队

vLLM 凭借 PagedAttention 和 Continuous Batching 两项核心技术，在上述三个维度都实现了数量级的提升。

{/* truncate */}

## 一、PagedAttention：操作系统的虚拟内存，用在 Transformer 上

### 背景：KV Cache 的内存问题

在 Transformer 的自回归解码过程中，每个生成的 token 都会与之前所有 token 的 Key（K）和 Value（V）向量计算注意力。为了不重复计算，这些 K/V 向量会被缓存下来，这就是 **KV Cache**。

KV Cache 的大小与序列长度呈线性增长：

```
KV Cache 大小 = 2 × num_layers × num_heads × d_head × seq_len × dtype_size
```

对于一个 70B 模型（L=80, H=64, d=128, FP16）单条序列：

```
单 token KV Cache ≈ 2 × 80 × 64 × 128 × 2 = 2.6 MB
4K 序列 KV Cache ≈ 2.6 MB × 4096 ≈ 10.6 GB
```

单条 4K 序列就要吃掉 10GB+ 显存。在传统实现中，这是**一次性预分配**的——即使序列只生成了 100 个 token，也要预留 4K 的位置。批次越大，浪费越严重。

### 核心思想：从「连续分配」到「分页」

PagedAttention 的核心洞察很简单：**像操作系统管理物理内存一样管理 KV Cache**。

| 概念 | 操作系统虚拟内存 | PagedAttention |
|------|-----------------|----------------|
| 基本单元 | 内存页（4KB） | KV Block（固定大小） |
| 地址空间 | 虚拟地址 → 物理地址 | 逻辑块号 → 物理块号 |
| 分配方式 | 按需分配（demand paging） | 按需分配 KV Block |
| 映射表 | 页表（Page Table） | Block Table |
| 共享机制 | 写时复制（Copy-on-Write） | Copy-on-Write KV Block |

```text
传统方式（连续分配）：
┌─────────────────────────────────────────────────────┐
| Seq A (max_len=4096):  # 一次性占满                 |
| [K|V][K|V][K|V]...[empty][empty][empty]             |
|  ▲ 前100个token ▲          ▲ 3996个空位（浪费）     |
└─────────────────────────────────────────────────────┘

PagedAttention（分页分配）：
┌─────────────────────────────────────────────────────┐
| Block Table:       物理 KV Block 池:                 |
| Logical 0 → Phys 12 ├────────┤├────────┤├────────┤  |
| Logical 1 → Phys 05 │B05(KV) ││B12(KV) ││B03(KV) │  |
| Logical 2 → Phys 03 ├────────┤├────────┤├────────┤  |
| Logical 3 → Phys 09 │B09(KV) ││B07(KV) ││...     │  |
|                     ├────────┤├────────┤           |
| Seq A 只占 4 Block  │ 按需分配，无浪费              |
| 而非预分配的 32 Block└─────────────────────────────┘
```

### Block Table 实现

vLLM 中的 Block Table 是一个关键数据结构：

```python
# 简化版的 Block Table 实现
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Block:
    """物理 KV Block"""
    block_id: int
    k_cache: list  # [num_layers, num_heads, block_size, d_head]
    v_cache: list
    ref_count: int = 1  # 引用计数，支持共享


class BlockTable:
    """逻辑块 → 物理块的映射表"""

    def __init__(self, block_size: int = 16):
        self.block_size = block_size  # 每个 Block 容纳的 token 数
        self.blocks: list[Optional[Block]] = []
        self.physical_to_logical: dict[int, int] = {}

    def allocate(self, num_tokens: int, allocator) -> None:
        """为 num_tokens 分配物理 Block（按需）"""
        num_blocks = (num_tokens + self.block_size - 1) // self.block_size
        while len(self.blocks) < num_blocks:
            physical_block = allocator.alloc()
            self.blocks.append(physical_block)
            self.physical_to_logical[physical_block.block_id] = len(self.blocks) - 1

    def append_token(self, token_kv, allocator) -> None:
        """追加一个 token 的 KV 到最后一个 Block，不够时自动分配"""
        if not self.blocks:
            self.allocate(self.block_size, allocator)

        last_block = self.blocks[-1]
        pos_in_block = (self._total_tokens() % self.block_size)

        if pos_in_block == 0 and self._total_tokens() > 0:
            # 当前 Block 已满，分配新 Block
            new_block = allocator.alloc()
            self.blocks.append(new_block)
            last_block = new_block

        # 将 KV 写入对应位置
        self._write_kv(last_block, pos_in_block, token_kv)

    def get_physical_blocks(self) -> list[int]:
        """返回物理 block id 列表，用于 GPU kernel"""
        return [b.block_id for b in self.blocks if b is not None]

    def _total_tokens(self) -> int:
        return len(self.blocks) * self.block_size  # 近似值
```

### 性能收益

PagedAttention 带来的核心收益：

| 指标 | 传统实现 | vLLM (PagedAttention) | 提升 |
|------|---------|----------------------|------|
| 显存利用率 | 20-40% | 90-95% | 2-4× |
| 最大并发序列 | 基线 | 2-5× | 2-5× |
| 首次 token 延迟 | 基线 | 相当 | ~1× |
| 解码吞吐量 | 基线 | 1.5-3× | 1.5-3× |

**实际案例**：在 4×A100 (80GB) 上运行 Llama-3-70B，传统方案最多处理 8 条并发序列（4K 长度），vLLM 可以处理 32-40 条——这意味着 **4-5 倍的吞吐量提升**。

### 共享前缀的 Block 复用

PagedAttention 还有一个「意外之喜」：支持 **Copy-on-Write 的 Block 共享**。

当多个请求共享相同的前缀（如 System Prompt、Few-shot 示例），它们的 KV Cache 块可以共用：

```text
Block Table A:  [B0]→[B1]→[B2]→[B3]→[B4]  (完整序列)
Block Table B:  [B0]→[B1]→[B2]→[B3]→[B5]  (共享前4块)
                └──── 共享 ────┘   └ 不同 ┘

物理块池：
B0: ref=2  B1: ref=2  B2: ref=2  B3: ref=2  B4: ref=1  B5: ref=1
```

这在 RAG、Chat 模板等场景中效果显著：

```python
# vLLM 的自动前缀缓存（Automatic Prefix Caching, APC）
from vllm import LLM, SamplingParams

llm = LLM(
    model="Qwen/Qwen2.5-72B-Instruct",
    enable_prefix_caching=True,  # 启用自动前缀缓存
)

# 共享 System Prompt 的请求会自动复用 KV Cache
requests = [
    "你是一个AI助手...用户提问1",
    "你是一个AI助手...用户提问2",  # 前缀 "你是一个AI助手..." 的 KV 块被复用
    "你是一个AI助手...用户提问3",
]

for req in requests:
    llm.generate(req, SamplingParams(temperature=0.7))
```

启用 APC 后，共享前缀的请求**首次 token 延迟（TTFT）可以降低 30-60%**。

## 二、Continuous Batching：从「等待」到「流水线」

### 静态 Batching 的局限

传统推理引擎使用**静态批处理**：

1. 收集 N 个请求组成一个 batch
2. 所有请求的 `max_tokens` 都设置为批次中的最大值
3. 所有请求必须一起开始、一起结束

这导致：
- **短请求等长请求**：生成了 20 个 token 的请求必须等生成了 512 个 token 的请求完成后才能返回
- **GPU 利用率先高后低**：随着序列陆续结束，有效计算的序列越来越少
- **无法动态调整**：新请求必须等当前批次完成才能加入

### Continuous Batching 如何工作

Continuous Batching（也叫 In-flight Batching）将解码过程拆分成更小的粒度：

```python
# 连续批处理的调度策略
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Sequence:
    seq_id: int
    prompt_tokens: List[int]
    generated_tokens: List[int] = None
    max_tokens: int = 2048
    finished: bool = False

    def __post_init__(self):
        if self.generated_tokens is None:
            self.generated_tokens = []

    def num_tokens(self) -> int:
        return len(self.prompt_tokens) + len(self.generated_tokens)

    def can_prefill(self) -> bool:
        """是否仍处于预填充阶段"""
        return len(self.generated_tokens) == 0

    def can_decode(self) -> bool:
        return not self.finished and not self.can_prefill()


class ContinuousScheduler:
    """
    连续批处理调度器

    每步调度决策：
    1. 如果有处于预填充阶段的序列，调度 1 个进行预填充
    2. 从解码阶段的序列中选择可加入批次的
    3. 检查是否有空位，加入新请求
    """

    def __init__(self, max_num_seqs: int = 256, max_num_batched_tokens: int = 4096):
        self.waiting: List[Sequence] = []
        self.running: List[Sequence] = []
        self.max_num_seqs = max_num_seqs
        self.max_num_batched_tokens = max_num_batched_tokens

    def add_request(self, seq: Sequence):
        """新请求加入等待队列"""
        self.waiting.append(seq)

    def schedule(self) -> dict:
        """
        生成下一步的调度决策
        返回当前批次应该包含哪些序列
        """
        # 第一步：检查是否有序列需要预填充（Prefill Phase）
        prefill_seqs = [s for s in self.running if s.can_prefill()]
        decode_seqs = [s for s in self.running if s.can_decode()]

        # 第二步：确定预填充位置（一次只处理一个预填充）
        scheduled = {
            "prefill": None,
            "decode": [],
            "new_requests": [],
        }

        if prefill_seqs:
            # 选择一个进行预填充
            scheduled["prefill"] = prefill_seqs[0]

        # 第三步：解码阶段序列尽量打包
        available_tokens = self.max_num_batched_tokens
        if scheduled["prefill"]:
            available_tokens -= scheduled["prefill"].num_tokens()

        for seq in decode_seqs:
            if len(scheduled["decode"]) >= self.max_num_seqs:
                break
            if len(scheduled["decode"]) + 1 <= available_tokens // 1:  # 每个解码 step 1 token
                scheduled["decode"].append(seq)
                available_tokens -= 1

        # 第四步：补入新请求
        while (len(scheduled["decode"]) + len(scheduled["new_requests"])) < self.max_num_seqs:
            if not self.waiting:
                break
            new_seq = self.waiting.pop(0)
            self.running.append(new_seq)
            scheduled["new_requests"].append(new_seq)

        return scheduled

    def on_step_complete(self, results: dict):
        """每个解码步完成后更新状态"""
        finished_seqs = []
        for seq in self.running:
            if seq.finished:
                finished_seqs.append(seq)

        for seq in finished_seqs:
            self.running.remove(seq)
```

### 吞吐量对比

| 场景 | 静态 Batching | Continuous Batching | 提升 |
|------|--------------|-------------------|------|
| 短请求混合 (50-100 tokens) | ~200 req/s | ~600 req/s | **3×** |
| 中等长度 (256-512 tokens) | ~80 req/s | ~200 req/s | **2.5×** |
| 长请求混合 (512-2048 tokens) | ~25 req/s | ~60 req/s | **2.4×** |
| GPU 利用率 | 40-60% | 85-95% | **1.6-2×** |

数据基于 Llama-3-8B + 4×A100 实测。

### 调度策略的工程挑战

Continuous Batching 的调度器需要解决几个棘手问题：

**问题 1：预填充（Prefill）与解码（Decode）的冲突**

预填充阶段是 compute-bound（计算密集型），解码阶段是 memory-bound（显存访问密集型）。把它们混在一个 batch 里，预填充会拖慢所有解码请求的延迟。

vLLM 的解决策略：**分时复用**——每个调度周期要么做预填充（一个序列），要么做解码（多个序列），不混合。

```text
时间线：
Step 1: [Prefill Seq A]          ← A 进入预填充
Step 2: [Decode A | Decode B]    ← A 开始解码，B 继续解码
Step 3: [Prefill Seq C]          ← C 预填充
Step 4: [Decode A | Decode B | Decode C]
...
```

**问题 2：请求优先级**

不是所有请求都同等重要。vLLM 支持多种调度策略：

```python
from vllm import LLM

# 策略 1：FCFS（先来先服务，默认）
llm = LLM(model="...")

# 策略 2：基于 SLO 的调度（v0.6+）
llm = LLM(
    model="...",
    scheduling_policy="priority",  # 需要请求携带 priority 字段
)

# 策略 3：在 API Server 层做优先级队列
# 通过 vLLM 的异步引擎 + 自定义调度器实现
```

## 三、vLLM 的生产级部署配置

### 关键参数调优

```bash
# 推理引擎参数
python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-72B-Instruct \
    --tensor-parallel-size 4 \          # TP 并行度，4卡
    --pipeline-parallel-size 1 \         # PP 并行度
    --max-num-seqs 256 \                 # 最大并发序列数
    --max-model-len 8192 \               # 最大序列长度
    --gpu-memory-utilization 0.95 \      # GPU 显存利用率
    --block-size 16 \                    # KV Block 大小（影响内存利用率）
    --enable-prefix-caching \            # 启用前缀缓存
    --use-v2-block-manager \             # v2 Block Manager（性能更好）
    --enforce-eager False \              # 使用 CUDA graph 优化
    --max-num-batched-tokens 8192 \      # 最大 batched token 数
    --kv-cache-dtype auto \              # KV Cache 数据类型
    --quantization fp8 \                 # FP8 量化（H100/B200）
    --seed 42
```

### 各参数的实际影响

| 参数 | 推荐值 | 对性能的影响 |
|------|--------|------------|
| `gpu-memory-utilization` | 0.85-0.95 | 越高可容纳越多 KV Cache，但留空间给模型权重 |
| `block-size` | 16（推荐）/ 32 | 小值提高内存利用率但增加管理开销 |
| `max-num-seqs` | 128-512 | 越大吞吐越高，但增加调度延迟 |
| `enable-prefix-caching` | True | 共享前缀场景下 TTFT 降低 30-60% |
| `kv-cache-dtype` | auto / fp8 | FP8 可减少 50% KV Cache 显存，略有精度损失 |

### 在线服务架构

一个生产级的 vLLM 部署通常包含以下组件：

```text
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  客户端      │────▶│ API Gateway  │────▶│ vLLM Server  │
│  (App/Web)   │     │ (限流/路由)  │     │ (GPU节点)     │
└─────────────┘     └─────────────┘     └──────────────┘
                           │                     │
                           ▼                     ▼
                    ┌─────────────┐     ┌──────────────┐
                    │ 负载均衡     │     │  Prometheus   │
                    │ (K8s Service)│     │  + Grafana    │
                    └─────────────┘     └──────────────┘
```

```yaml
# docker-compose.yml 示例
version: "3.8"

services:
  vllm-server:
    image: vllm/vllm-openai:latest
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=0,1,2,3
    command:
      - "--model"
      - "Qwen/Qwen2.5-72B-Instruct"
      - "--tensor-parallel-size"
      - "4"
      - "--max-num-seqs"
      - "256"
      - "--gpu-memory-utilization"
      - "0.95"
      - "--enable-prefix-caching"
      - "--port"
      - "8000"
    ports:
      - "8000:8000"
    volumes:
      - ~/.cache/huggingface:/root/.cache/huggingface
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 4
              capabilities: [gpu]

  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml

  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
```

### 关键监控指标

```promql
# GPU 利用率
rate(nvidia_smi_utilization_gpu[1m])

# 请求延迟 P50/P99
histogram_quantile(0.50, sum(rate(vllm:request_latency_seconds_bucket[5m])) by (le))
histogram_quantile(0.99, sum(rate(vllm:request_latency_seconds_bucket[5m])) by (le))

# KV Cache 使用率
vllm:gpu_cache_usage

# 每秒生成 token 数（吞吐）
rate(vllm:num_generation_tokens_total[1m])

# 运行中请求数
vllm:num_requests_running

# 等待队列长度
vllm:num_requests_waiting
```

## 四、vLLM 与其他推理引擎的对比

| 维度 | vLLM | TensorRT-LLM | TGI | SGLang |
|------|------|-------------|-----|--------|
| 架构灵活性 | ★★★★★ | ★★★ | ★★★★ | ★★★★★ |
| 推理吞吐 | ★★★★ | ★★★★★ | ★★★★ | ★★★★ |
| 首次 Token 延迟 | ★★★★ | ★★★★★ | ★★★ | ★★★★★ |
| 模型兼容性 | ★★★★★ | ★★★ | ★★★★ | ★★★★ |
| 部署易用性 | ★★★★★ | ★★★ | ★★★★ | ★★★★ |
| 社区生态 | ★★★★★ | ★★★ | ★★★★ | ★★★ |
| 量化支持 | FP8/INT4/INT8 | FP8/INT4/INT8/INT4-FP8 | FP8/INT4 | FP8/INT4 |

**选型建议**：
- 快速的通用部署 → **vLLM**
- 极致推理性能（特定模型） → **TensorRT-LLM**
- HuggingFace 生态深度集成 → **TGI**
- 需要定制 attention kernel → **SGLang**

## 五、vLLM 的演进方向

vLLM 在当前及未来的版本中正朝着以下方向演进：

1. **多模态支持**：vLLM 0.6+ 开始原生支持 LLaVA、Qwen-VL 等视觉语言模型
2. ** speculative decoding（推测解码）**：通过 Draft Model 加速解码，可提升 1.5-2× 吞吐
3. ** Disaggregated Serving**：将 Prefill 和 Decode 分离到不同 GPU 上，针对各自特性优化
4. ** Prefix Caching 跨请求持久化**：将 KV Cache 持久化到内存/SSD，跨重启复用
5. **多 LoRA 推理**：一个基座模型同时服务多个 LoRA adapter，无需重新加载

## 总结

vLLM 的成功不是偶然。它将操作系统的虚拟内存管理思想引入深度学习推理，解决了困扰业界多年的显存碎片化问题。PagedAttention 和 Continuous Batching 的配合，使得 LLM 推理从「静态、低效」走向「动态、高效」。

核心时间线：
- **2023 年**：vLLM 论文发表，PagedAttention 概念提出
- **2024 年**：vLLM 成为主流推理引擎，社区贡献者超过 500 人
- **2025 年**：vLLM 0.6 发布，支持多模态、FP8、Prefix Caching
- **2026 年**：vLLM 定位为 LLM Serving 的事实标准，生态持续扩展

对于高级工程师来说，理解 vLLM 的内部机制不仅能帮你配置出更高效的服务，更能让你在设计自己的系统时，借鉴这些被验证过的工程思想。

**相关阅读：**
- [AI Infra 到底是什么](/blog/2026/07/07/ai-infra-what-is-it)
- [GB200 NVL72 成本拆解分析](/blog/2026/07/14/gb200-nvl72-cost-breakdown)
