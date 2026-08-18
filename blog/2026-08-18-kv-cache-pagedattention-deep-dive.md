---
title: "KV Cache 深度解析：显存黑洞、PagedAttention 与三路省内存方案"
date: 2026-08-18T18:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "vllm", "performance"]
categories: ["Tech"]
description: "KV Cache 的显存账本、PagedAttention 分页机制、GQA/MLA/量化三路省内存方案，以及 prefix caching 与生产踩坑实录。"
---

很多后端工程师第一次接触 LLM 推理都会困惑：为什么 prefill 快如闪电，decode 却一个字一个字地蹦？为什么 8B 模型的 fp16 权重才 16GB，vLLM 却要求 40GB 以上显存？答案都指向同一个东西：**KV Cache**。它既是 decode 速度的根基，也是推理服务显存和带宽的最大开销。这篇文章从显存账本算起，讲清楚 KV Cache 为什么是推理性能的隐形瓶颈，PagedAttention 如何用「虚拟内存」的思路解决碎片化，以及 GQA、MLA、量化、prefix caching 各自省掉了什么、代价是什么。文末附一个可运行的 numpy 最小实现和生产环境踩坑清单。

{/* truncate */}

## 一、KV Cache 是什么：一次 prefill，N 次 decode

Decoder-only 模型的生成分两个阶段：

- **prefill**：输入整个 prompt，并行计算所有位置的 attention，算出每层的 K/V 投影
- **decode**：逐 token 生成，每步只输入上一个 token 的 embedding

Attention 公式 `softmax(Q·K^T/√d)·V` 里，生成第 t 个 token 时需要 attend 到前 t-1 个 token。如果每步都重新计算历史 token 的 K/V，网络前向的复杂度是 O(T²)——上下文 4096 时，平均每个 token 要重算约 2000 次投影，大部分算力浪费在重复计算上。

KV Cache 的思路朴素到近乎白给：**prefill 阶段把每层每头的 K/V 存下来，decode 阶段只算当前 token 的 K/V，直接复用历史**。为什么不缓存 Q？因为 Q 只属于当前 token，用完即弃；K/V 是所有后续 token 都要 attend 的对象。

```
┌─ prefill ────────────────────────────────┐
│ prompt 全部 token 并行计算 attention      │
│ 每层每头的 K/V 投影 → 写入 KV Cache       │
└───────────────────────────────────────────┘
              ↓ 每个生成步
┌─ decode（第 t 步）───────────────────────┐
│ 只输入 token t 的 embedding               │
│ 计算 Q；K/V 直接从 cache 读取（前 t-1 个）│
│ 输出 token t+1 → 追加进 cache             │
└───────────────────────────────────────────┘
```

## 二、显存账本：KV Cache 可能比权重还大

KV Cache 的大小有一个固定的公式：

```
KV bytes = 2 × layers × kv_heads × head_dim × seq_len × batch × bytes_per_elem
```

以 Llama-3-8B 为例（32 层、GQA 8 个 KV head、head_dim 128、fp16）：

| 粒度 | 计算 | 大小 |
|------|------|------|
| 每 token 每层 | 2 × 8 × 128 × 2B | 4 KB |
| 每 token 全模型 | × 32 层 | 128 KB |
| 单序列 4K 上下文 | × 4096 | 512 MB |
| batch 32 × 4K | × 32 | **16 GB** |

16GB 是什么概念？Llama-3-8B 的 fp16 权重也才约 16GB。而且**权重是只读的、所有请求共享一份；KV Cache 是每个并发序列各一份**。batch 64 时 KV Cache 直接到 32GB，比权重翻倍。这就是为什么推理服务显存消耗远超模型大小——vLLM 的 `gpu_memory_utilization` 默认 0.9，其中大半分给了 KV 块池。

这也解释了为什么 decode 是 **memory-bound**：生成第 t 个 token 要读取全部 t × 128KB 的 cache，4K 上下文时每步搬 512MB。GPU 算力再高，也被显存带宽卡死。KV Cache 的优化本质就是两条线：**省容量**（塞进更少的显存）和**省带宽**（每步少搬数据）。

## 三、PagedAttention：像操作系统一样管理显存

朴素实现（HF Transformers 风格）的 KV Cache 有两个致命浪费：

1. **预分配**：按 `max_seq_len` 一次性分配连续显存，实际序列长度远小于上限，平均利用率只有三四成
2. **碎片化**：各序列长度不同，动态分配导致内部碎片和外部碎片，显存明明还有余量却分配不出连续块

PagedAttention（vLLM，arXiv:2309.06180）的解法是**把 KV Cache 切成固定大小的 block（默认 16 token），用 block table 记录每个序列的逻辑块到物理块的映射**——逻辑连续、物理离散，这就是操作系统的分页机制照搬进显存管理。序列增长时按需分配新块，最多浪费一个块；多序列还能共享同一个物理块（比如 beam search 的分支、前缀相同的请求），进一步省显存。

论文数据（LLaMA-13B / A100 实测）：

- 同延迟下吞吐提升 **2 到 4 倍**，显存浪费减少 **60% 以上**
- 相比 HF Transformers 基线快 **14 到 24 倍**（后者是每步重分配连续缓存 + 无块管理）
- 相比 FasterTransformer 高 2.2 倍、Orca 2.4 倍、TGI 2.2 倍

PagedAttention 之后，显存利用率从「按最大长度赌」变成「按需分配」，vLLM 才敢把 `max_model_len` 设得很高而不用担心碎片。

## 四、架构级省内存：GQA、MLA、KV 量化

工程调度只能解决「放不放得下」，架构层面直接决定「要放多少」。

**MHA → GQA → MQA**：原始 Transformer 是每层 N 个 query head 配 N 个 KV head（MHA）。GQA 让多个 query head 共享少数 KV head：

- MHA：32 query heads + 32 KV heads，KV 每 token 每层 8KB
- GQA：32 query heads + 8 KV heads，KV 直接除以 4（Llama-3 系标配）
- MQA：1 个 KV head，极端压缩，质量损失明显

GQA 论文（arXiv:2305.13245）的实验结论：推理速度接近 MQA（约 MHA 的 3 倍），质量接近 MHA——白捡的收益，所以 2023 年后的开源模型几乎全员 GQA。

**MLA（Multi-head Latent Attention）**：DeepSeek-V2 的思路更激进——把 K/V 先压缩成低秩 latent 向量（512 维）存进 cache，attention 时再解压回完整维度。KV Cache 减少 **93.3%**，吞吐提升 **5.76 倍**（arXiv:2405.04434）。代价是 kernel 实现复杂：解压发生在计算时而非存储时，需要专门的 fused kernel；MLA 的特殊 cache 结构也让投机解码、连续批处理等下游优化适配滞后，这是很多开源推理引擎对 DeepSeek 系模型支持慢半拍的原因。

**KV Cache 量化**：fp16 → fp8（E4M3）尾数从 10 bit 降到 3 bit，KV 容量直接减半。Attention 分数对低精度相对宽容——softmax 有归一化，绝对误差会被摊薄，用 per-channel / per-token scale 压住 outlier 后，fp8 KV 在多数模型上质量损失可忽略。但长上下文下误差会累积，敏感模型建议 K 保持 fp16、只量化 V，或用 per-head scale。这块和模型权重量化的坑高度重叠，可以参考之前的[量化文章](/blog/2026/08/14/llm-quantization-deep-dive)。

## 五、工程级优化：prefix caching 与 chunked prefill

**Prefix caching**：相同前缀的 KV 直接复用，不重复计算也不重复存储。vLLM 用 hash 匹配前缀块，SGLang 的 RadixAttention 用字典树管理共享前缀。对 Agent 场景收益最大：固定 system prompt + 工具定义 + 长历史的多轮对话，前缀命中后 prefill 几乎免费，首 token 延迟（TTFT）从秒级降到毫秒级。

**Chunked prefill**：长 prompt 的 prefill 切成 chunk，与 decode 交错执行（continuous batching 的迭代级调度），避免一个 32K 的长 prefill 把整批 decode 阻塞成「一卡拖全队」，同时缓解 prefill 阶段瞬时显存峰值。

**Cache eviction（有损）**：H2O（arXiv:2306.14048）发现 attention 分数高度集中在少数「heavy hitter」token 上，只保留 20% 的 KV 就能保住 90% 以上的效果；SnapKV 把 prompt 压缩 3.2 倍、KV Cache 降到 1/3.6，同时保持约 99% 的效果。适合长上下文 + 显存吃紧的有损场景，精度敏感场景慎用。

## 六、最小实现：一个可运行的 KV Cache

用 numpy 写一个单头的最小实现，体会 prefill 与 decode 的差异：

```python
import numpy as np

class KVCacheAttention:
    """单头 attention 的最小 KV Cache 实现（numpy，可运行）。"""

    def __init__(self, head_dim: int):
        self.head_dim = head_dim
        self.k_cache: np.ndarray | None = None   # [seq, head_dim]
        self.v_cache: np.ndarray | None = None

    def step(self, q, k, v):
        """输入单个 token 的 q/k/v，返回该 token 的 attention 输出。"""
        if self.k_cache is None:                 # 第一个 token：初始化 cache
            self.k_cache = k[None, :]
            self.v_cache = v[None, :]
        else:                                    # 后续 token：追加到 cache
            self.k_cache = np.concatenate([self.k_cache, k[None, :]], axis=0)
            self.v_cache = np.concatenate([self.v_cache, v[None, :]], axis=0)
        scores = (q @ self.k_cache.T) / np.sqrt(self.head_dim)   # [seq]
        scores -= scores.max()                   # 数值稳定 softmax
        attn = np.exp(scores) / np.exp(scores).sum()
        return attn @ self.v_cache               # [head_dim]

# prefill：把 prompt 每个位置依次喂入，cache 建好
# decode：每步只喂新 token，K/V 从 cache 读，不再重算历史投影
```

对比一下复杂度：无 cache 时第 t 步要重算前 t 个 token 的 K/V 投影（每步 O(t·d²)），全序列 O(T²·d²)；有 cache 后每步只算当前 token 的投影（O(d²)），attention 的 score 计算 O(t·d) 是下限省不掉。**省掉的是重复的 K/V 投影计算，省不掉的是每步读全部 KV 的带宽**——所以 decode 的优化重心永远是内存，不是算力。

## 七、生产踩坑实录

1. **GQA 参数漏配导致 KV 内存翻 4 倍**：用 transformers 自建模型或改 config 时忘了 `num_key_value_heads=8`，会静默退化成 MHA，KV Cache 从 16GB 变 64GB。加载 Llama-3 用官方 config 没事，自己拼模型必踩。
2. **`max_model_len` 拍脑袋设大**：vLLM 的 KV 块池按上限预留，设 128K 上限却只有 8K 负载，块池被无关容量占满，高并发时请求排队甚至 OOM。按真实负载设上限，用 `gpu_memory_utilization` 和观测到的 KV 块使用率校准。
3. **Prefix caching 隐形失效**：system prompt 末尾多一个空格、或塞了时间戳等动态内容，整条前缀 hash 全 miss，缓存命中率一夜归零。动态内容放 message 尾部；vLLM 老版本还要显式 `enable_prefix_caching=True`。
4. **长 prefill OOM**：chunked prefill 的 chunk 默认 2048，prefill 超长 prompt 时瞬时 KV 峰值超预算。调小 chunk 或加大 `max_num_batched_tokens`，让 prefill 与 decode 真正交错。
5. **KV Cache CPU offload 的带宽陷阱**：PCIe 4.0 x16 约 32GB/s，4K 上下文时每 token 要读 512MB cache，光搬运就约 16ms/token，比 GPU 计算本身还慢。offload 只适合「显存不够但能忍受慢」的场景，别指望它提速。

## 总结

KV Cache 是 LLM 推理优化的总杠杆：算清显存账本，才知道瓶颈在容量还是带宽；PagedAttention 解决碎片，GQA/MLA/量化解决容量，prefix caching 解决重复计算。后端工程师做推理服务，把这几个点串起来，基本就是 vLLM 调参的全部理论依据——剩下的只是对着指标调数字。
