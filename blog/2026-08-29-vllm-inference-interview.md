---
title: "面试题：为什么 vLLM 是当前最快的 LLM 推理框架？Continuous Batching 和 PagedAttention 各自解决了什么问题、显存占用怎么降下来的？"
date: 2026-08-29T09:00:00+08:00
draft: false
tags: ["ai", "llm", "vllm", "inference", "interview"]
categories: ["Interview"]
description: "LLM 推理高频面试题：为什么同样的 GPU，vLLM 的吞吐比朴素的批处理框架高几倍？Continuous Batching 怎么把调度粒度从请求级降到迭代级、消灭排队气泡？PagedAttention 怎么用操作系统的分页思想把 KV Cache 显存浪费从六七成压到接近零？从原理到数字一次讲清。"
---

> 这是「每日一题」专栏的第十六篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇讲了 [实时协作文档系统](/blog/2026/08/28/collaborative-editing-interview)，今天按轮换回到 AI/LLM 方向，聊上一篇预告的题：为什么 vLLM 最快？Continuous Batching 和 PagedAttention 各自解决了什么？

{/* truncate */}

## 一、问题的本质：decode 阶段的 GPU 在摸鱼

面试官问「为什么 vLLM 快」，前提是你先讲清楚「慢在哪」。LLM 推理分两个阶段：

| 阶段 | 做什么 | 计算特征 |
|------|--------|---------|
| Prefill（预填充） | 一次性处理整个输入 prompt | 计算密集，矩阵维度大，GPU 利用率高 |
| Decode（解码） | 逐 token 生成 | **访存密集**：每次只算一个 token，但要把全部历史 KV Cache 读一遍 |

关键认知：**decode 阶段 GPU 是「吃不饱」的**。矩阵乘法从一个 batch 变成长度为 1，算力用不上，瓶颈在显存带宽——每生成一个 token 都要把越来越长的 KV Cache 从头到尾读一遍。所以 LLM 推理优化，本质上是两件事：**让 GPU 每一轮多塞几个请求（提高吞吐），让 KV Cache 少占显存、多放几个并发**。vLLM 的两板斧正好各打一个。

## 二、方案一：Continuous Batching（连续批处理）

### 传统框架为什么慢：请求级调度

朴素的静态批处理（static batching）：GPU 一次吃一批请求，**必须等这一批全部生成完（包括最长的那个）才整体释放**，换下一批。

```
请求 A  ████████████████░░░░░░░░   ← 早就生成完了，干等
请求 B  ████████████████████████   ← 最长，全批等它
请求 C  ████████████████░░░░░░░░   ← 干等
         └─────── 一批 ────────┘
         GPU 在 ░░ 区间完全空转，这就是「排队气泡」
```

两个浪费：① 短请求陪跑长请求，生成了也占着位置；② 批与批之间有调度空隙。生成长度方差越大（真实流量里 prompt 和回答长度差异巨大），浪费越严重。

### Continuous Batching：迭代级调度

核心思想来自 2022 年的 Orca 论文：**把调度粒度从「请求级」降到「迭代级」（iteration-level scheduling）**。

所谓一次迭代，就是 GPU 做一次 forward、每个参与请求各生成一个 token。Continuous Batching 在**每一次迭代结束后重新调度**：

1. 生成完的请求（达到 max_tokens 或遇到 EOS）**立刻移出 batch**，让出显存；
2. 排队的新请求**立刻补进来**，从 prefill 开始参与下一轮；
3. 每个请求按自己的节奏推进，互不等待。

```
迭代 1   A B C D         迭代 2   A B C E(新进)
迭代 3   A B F(新进)     迭代 4   B G(新进)      ← A 完成离开，空位马上补
```

效果：GPU 每轮都满载，吞吐提升明显。Orca 论文在模拟和真实工作负载下测出比静态批处理高一个数量级的吞吐；vLLM 论文中 continuous batching 也是相对传统方案吞吐提升的主要来源之一。工程上实现它不难，难在**每个序列要独立管理自己的 KV Cache、位置索引和状态**——这就引出 PagedAttention。

## 三、方案二：PagedAttention（KV Cache 分页）

### KV Cache 有多大：算一笔账

KV Cache = 每个 token 每层每头各一份 K 向量和 V 向量。公式：

```
每 token KV Cache = 2 × 层数 × 每层 KV 头数 × 头维度 × 数据类型字节数
```

以 Llama-2-7B 为例（32 层、32 头、head_dim 128、FP16）：

```
2 × 32 × 32 × 128 × 2 字节 ≈ 512 KB / token
```

一个 token 就要 512KB！2048 token 的上下文就是 **1GB**，4K 上下文 2GB——一张 24GB 的卡，光 KV Cache 就只够十几个并发请求。所以「KV Cache 怎么分配」直接决定你能同时服务多少人，是推理框架的核心战场。

### 朴素分配的三个浪费

早期框架怎么管理 KV Cache？**按最大长度预分配一段连续显存**。三个致命浪费：

| 浪费类型 | 成因 | 量级 |
|---------|------|------|
| 超额预留 | 按 max_tokens（如 2048）预留，实际只生成了 50 token | 常常浪费六到七成显存 |
| 内部碎片 | 同一批请求长度不一，预留都是按最长对齐 | 同上，雪上加霜 |
| 外部碎片 | 动态分配释放后，显存出现无法利用的缝隙 | 并发越高越严重 |

### PagedAttention：把操作系统搬进 GPU

vLLM 的解法（2023 年论文）直接借用了 **OS 虚拟内存的分页思想**：

- KV Cache 不再按「一个请求一段连续内存」分配，而是切成**固定大小的 block**（默认 16 个 token 一个 block，约 16KB 量级）；
- 逻辑上每个序列的 KV 是连续的，物理上散落在不同的 block 里，靠一张 **block table** 映射（相当于页表）；
- 分配粒度从「整个请求」变成「按需一页一页」：生成了多少 token 就占几个 block，**超额预留直接消失**。

```python
# PagedAttention 的核心数据结构（示意）
class Sequence:
    logical_blocks: list[int]   # 逻辑 block 序列（逻辑连续）
    # block table: 逻辑块号 -> 物理块号
    #   logical_blocks[i] 指向物理 block 表中的某个位置

class BlockTable:
    mapping: dict[int, int]     # {逻辑块号: 物理块号}，物理块可散落各处

class KVBlock:                  # 一个物理 block，默认 16 个 token 槽位
    k: tensor   # [num_heads, head_dim, 16]
    v: tensor   # [num_heads, head_dim, 16]
    ref_count: int              # 引用计数，用于前缀共享的 copy-on-write
```

好处还不止消灭碎片：

1. **按需分配**：显存用多少分多少，同样的卡能同时跑的并发请求多好几倍；
2. **前缀共享**：多个请求共享同一段 system prompt / few-shot 前缀时，KV block 可以**共用**（block table 里指向同一批物理块，引用计数 +1）；共享部分要做修改时用 **copy-on-write** 复制新块，不污染其他请求——这就是长上下文、多轮对话场景吞吐提升的关键；
3. **配合 continuous batching 的抢占**：被挤出的请求可以整体把 block 表 swap 到 CPU 内存，回来时按表重建，无需重算。

vLLM 论文的实测：**PagedAttention 让显存利用率接近理论下限，吞吐相对 Orca / FasterTransformer 提升约 2 到 4 倍**（其中分页本身贡献约两成多，大头来自连续批处理与显存释放带来的并发度提升）。两者叠加，就是「vLLM 为什么最快」的答案。

## 四、为什么是 vLLM 最快（而不是某个单一优化）

面试官追问「那 vLLM 和 TensorRT-LLM / SGLang 比呢？」时，别把 vLLM 神话化，讲清楚组合拳和生态：

1. **调度层**：Continuous Batching + 抢占（swap/recompute），吞吐的基石；
2. **内存层**：PagedAttention 分页 + 前缀共享，并发度上限的来源；
3. **内核层**：CUDA graph 消除 kernel 启动开销、chunked prefill 把长 prefill 切成块和 decode 交错执行、FP8/量化算子、与 FlashAttention 深度集成；
4. **生态层**：算子库、量化格式（AWQ/GPTQ）、多模态、LoRA 适配器支持最全，社区迭代最快。

诚实话术：「纯吞吐上 vLLM / SGLang / TensorRT-LLM 是同级别的选手，差距在 2 到 3 倍以内且互相追赶；**vLLM 赢在工程生态和易用性**——这也是面试官想听的分寸感，知道技术边界比背数字值钱。」另外注意：SGLang 的 RadixAttention 在前缀共享上做得比 vLLM 更激进（树状前缀缓存），这是它某些长上下文场景更快的来源。

## 五、两道高频追问

**追问 1：Continuous Batching 下，短请求会不会饿死长请求？抢占怎么处理？**

会，所以要有调度策略兜底：默认 FCFS（先到先服务）保证公平，超长请求占着 batch 时触发抢占（preemption）。被抢占的请求两种处理：**swap**——KV block 表整体搬去 CPU 内存，等资源释放再搬回来（保状态，但 CPU 带宽有瓶颈）；**recompute**——丢进度重算（省内存但费算力）。vLLM 默认走 swap，可配置；面试答出「swap vs recompute 是带宽换显存 vs 算力换显存」就到位了。

**追问 2：都说长上下文是 PagedAttention 的软肋，为什么？怎么办？**

上下文越长，每 token 的 KV 越大，block 内的尾部浪费和前缀命中率问题越突出，且长上下文意味着 KV 总量爆炸。所以 DeepSeek-V2/V3 引入 **MLA（Multi-head Latent Attention）**：把 K/V 压缩进低秩潜空间，KV Cache 缩到约十六分之一，同样的显存能撑 128K 上下文；再配合分页和前缀缓存，长上下文才跑得动。趋势很明确：**长上下文的解法是「KV 压缩 + 前缀共享 + 稀疏注意力」，分页只是地基**。

## 六、收尾

vLLM 这道题考的不是背参数，而是三层理解：**decode 是访存瓶颈（为什么优化空间在这）、调度粒度要降到迭代级（Continuous Batching）、显存要按页分配而不是整段预留（PagedAttention）**。能把「静态批处理为什么浪费 → 迭代调度怎么消除气泡 → 分页怎么消灭显存碎片 → 前缀共享怎么再提一档」这条线讲顺，再补上 MLA 这类新趋势，这道题就是送分题。

---

*明日预告：后端/分布式方向 ——「分布式限流怎么做？令牌桶和滑动窗口各自适用什么场景，单机限流怎么平滑演进到集群限流，Redis + Lua 为什么是标准答案？」*
