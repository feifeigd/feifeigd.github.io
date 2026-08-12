---
slug: /blog/2026/08/13/graph-rag-deep-dive
title: "Graph RAG 深度解析：当知识图谱遇上 RAG"
tags: [ai, llm, rag, architecture, engineering]
---

把一份 50 页的技术报告丢给 RAG 系统，问它 "这份报告的核心结论是什么？"——传统的 chunk-embed-retrieve-generate 链路直接跪了。不是检索不准，是**这个问题本身就无法被任何单个 chunk 回答**。

这是 2024 年 Microsoft Research 提出 Graph RAG 的出发点。一年过去，这个方向已经从论文变成了实际可跑的工程方案。本文从架构层面拆解它到底在做什么、怎么做的、以及什么时候该用。

---

## 问题：Vector RAG 的盲区

标准 RAG 流程的前提假设是：**答案分布在少数几个 chunk 中**。所以策略是 embed → top-k 检索 → 塞进 context → 生成。

一旦问题变成全局性的（"总结全文"、"对比三个方案的优劣"、"找出贯穿始终的主题"），top-k 检索就失效了。一个直觉的做法是**先把全文喂给 LLM**——但 50 页报告远超 context window。就算模型支持 1M token，"大海捞针"的准确率也随 context 增长而骤降。

Graph RAG 的解法：**先离线建图，再在线查询**。把文档转化成知识图谱，用图算法提取结构，把全局问题转化成对图结构的查询。

---

## 架构总览

Microsoft 的 Graph RAG 分两个阶段：

### 离线索引（Indexing）

```
文档 → 切分 chunk → 实体/关系抽取 → 知识图谱 → 社区检测 → 社区摘要
```

每个步骤都跑 LLM，完全离线，不占查询延迟。

### 在线查询（Query）

查询分两种模式：

- **Local Search**：从图中提取与查询相关的实体邻居子图，适合事实型问题
- **Global Search**：用社区摘要做 map-reduce，适合全局总结型问题

Global Search 是 Graph RAG 的核心差异化能力。下面重点拆它。

---

## 离线阶段：从文本到图谱

### Step 1：实体与关系抽取

对每个 chunk 调 LLM，提取 `(subject, predicate, object)` 三元组：

```python
# 伪代码：Graph RAG 的实体抽取 prompt 模式
EXTRACT_PROMPT = """从文本中提取所有实体和关系，返回 JSON：

{
  "entities": [
    {"name": "Microsoft", "type": "ORGANIZATION", "desc": "科技公司"}
  ],
  "relationships": [
    {"source": "Microsoft", "target": "Graph RAG", "desc": "提出者"}
  ]
}

文本：
{chunk_text}
"""
```

这一步是整个 pipeline 最贵的环节。一篇 100 页文档，按 300 token/chunk 切，会产生几百次 LLM 调用。Microsoft 的做法是并行跑，用 `gpt-4o-mini` 压低成本。

关键细节：**同一个实体会在不同 chunk 中被提取多次**（"Microsoft"、"MSFT"、"微软"），所以下一步要做实体消歧。

### Step 2：实体消歧（Entity Resolution）

Graph RAG 没有用复杂的 entity linking，而是再调一次 LLM：

```python
def resolve_entities(entity_groups: list[list[dict]]) -> dict:
    """同一类型的候选实体分组后，让 LLM 判断哪些是同一实体"""
    prompt = f"""
    以下实体中，哪些指向同一个真实世界实体？
    返回分组结果。

    候选实体：
    {json.dumps(entity_groups, ensure_ascii=False)}
    """
    # 返回合并后的实体映射
```

为什么用 LLM 而不是传统的字符串匹配？因为 "GPT-4" 和 "GPT4"、"gpt-4-turbo" 需要语义理解，简单的编辑距离不够。

消歧后，图里约 5-15% 的节点被合并，边也相应聚合。

### Step 3：社区检测（Community Detection）

这是 Graph RAG 最巧妙的一步。构建好实体-关系图后，用 **Leiden 算法**做社区发现：

```python
import networkx as nx
import leidenalg
import igraph as ig

def detect_communities(G: nx.Graph) -> list[set[str]]:
    """Leiden 社区检测，返回多层社区结构"""
    g_ig = ig.Graph.from_networkx(G)

    # 多层社区检测——这是精髓
    partition = leidenalg.find_partition(
        g_ig,
        leidenalg.ModularityVertexPartition,
        n_iterations=-1  # 跑到收敛
    )

    # Leiden 天然支持层次化社区
    # Level 0: 最细粒度的社区（几十个实体）
    # Level 1: 合并后的中等社区
    # Level 2: 最粗粒度的大主题社区
    return partition
```

Leiden 优于 Louvain 的地方是它**保证连通性**——每个社区内部是连通的，不会出现碎片化社区。对于知识图谱这种天然聚团的结构，Leiden 跑出来的社区往往对应真实世界的主题：比如"模型架构"社区包含 Transformer、Attention、MLP 等实体，"训练方法"社区包含 SGD、AdamW、Learning Rate 等。

### Step 4：社区摘要（Community Summarization）

对每个社区，把其成员实体和关系序列化成文本，让 LLM 生成摘要：

```python
def summarize_community(
    community: list[str],
    entities: dict,
    relationships: list
) -> str:
    """为一个社区生成摘要"""
    # 收集社区内的实体和关系
    community_entities = [entities[e] for e in community]
    community_rels = [
        r for r in relationships
        if r.source in community and r.target in community
    ]

    prompt = f"""
    以下是一个知识图谱社区的信息。请生成一个简洁的摘要，
    描述这个社区的核心主题、关键实体和它们之间的关系。

    社区实体：
    {format_entities(community_entities)}

    社区关系：
    {format_relationships(community_rels)}

    摘要：
    """
    return call_llm(prompt)
```

这个摘要会在 Global Search 时被用到。摘要的质量直接决定最终回答的质量——摘要太泛，查询结果就是废话；摘要太细，又回到了 chunk-level 的问题。

---

## 在线查询：Map-Reduce 模式

### Global Search

当用户问 "这份文档主要讨论了哪些技术方向？"，Graph RAG 的 Global Search 流程：

```
1. 把用户 query 嵌入向量
2. 对所有社区摘要做向量检索，选出 top-K 个相关社区
3. 对每个社区的摘要，让 LLM 生成一个"局部答案"（map）
4. 把所有局部答案汇总，让 LLM 生成最终回答（reduce）
```

```python
async def global_search(query: str, community_summaries: list[str]) -> str:
    # Step 1: 检索相关社区
    query_emb = embed(query)
    relevant = top_k_by_similarity(query_emb, community_summaries, k=10)

    # Step 2: Map — 每个社区生成局部答案
    map_tasks = [
        map_prompt(query, summary)
        for summary in relevant
    ]
    partial_answers = await asyncio.gather(*[call_llm(t) for t in map_tasks])

    # Step 3: Reduce — 汇总成最终答案
    final_answer = call_llm(reduce_prompt(query, partial_answers))
    return final_answer
```

这和传统的 map-reduce summarization 思路一样，区别在于：输入不是随机采样的 chunk，而是**按语义聚类好的社区摘要**。每个社区摘要本身已经是一个凝练的信息单元，所以 map 阶段产生的噪音远小于直接对 chunk 做 map。

### Local Search

对于事实型问题（"GPT-4 的 context window 是多少？"），走 Local Search：

```
1. 用 query 找到相关实体
2. 提取这些实体的邻居子图（1-2 hop）
3. 把子图信息 + 实体的原始文本属性 + 关系描述塞进 context
4. 生成回答
```

Local Search 的召回率显著高于纯向量检索，因为它利用了图的**结构信息**——"GPT-4" 和 "context window" 之间有一条 `has_context_window` 边，即使它们的文本描述中从来没有出现在同一个 chunk 里。

---

## 性能数据

Microsoft 的论文在两个数据集上做了评测：

| 指标 | Naive RAG | Graph RAG (Global) | 提升 |
|------|-----------|-------------------|------|
| Comprehensiveness | 2.87 | 3.97 | +38% |
| Diversity | 2.53 | 3.54 | +40% |
| Directness | 2.95 | 3.76 | +27% |
| LLM 调用次数 | 1 | ~12 (10 map + 1 reduce + 1 embed) | — |

数据来源：Microsoft Research, "From Local to Global: A Graph RAG Approach to Query-Focused Summarization", 2024

**代价也很明显**：

- 索引成本：一篇 100 页文档，约 $4-8（gpt-4o-mini），$50-100（gpt-4o）
- 索引时间：串行跑需要 30-60 分钟，并行可以压到 5-10 分钟
- 查询延迟：Global Search 需要 10+ 次 LLM 调用，单次查询 10-30 秒

**什么时候该用 Graph RAG？**

- ✅ 需要对大文档集做全局总结、主题分析、趋势发现
- ✅ 文档之间有密集的实体关联（科研文献、法律文书、技术报告）
- ✅ 索引可以离线跑，查询延迟可以接受 10-30 秒
- ❌ 简单的 FAQ 或事实型问答——标准 RAG 更快更便宜
- ❌ 需要毫秒级响应的实时场景
- ❌ 文档实体关系稀疏（小说、散文）

---

## 工程落地要点

### 1. 实体抽取的 Prompt 设计

实体类型的定义直接影响图的质量。太少，图就稀疏；太多，消歧压力大。建议：

```python
# 实际可用的实体类型（不是越多越好）
ENTITY_TYPES = [
    "PERSON",         # 人物
    "ORGANIZATION",   # 组织/公司
    "TECHNOLOGY",     # 技术/框架/模型
    "CONCEPT",        # 抽象概念
    "METRIC",         # 指标/数值
    "EVENT",          # 事件
]
```

控制在 5-8 个类型，每个类型有明确的边界定义。

### 2. Chunk 大小不是越小越好

实体抽取需要一个 chunk 内包含足够的上下文才能准确识别关系。Graph RAG 的推荐是 **600-1200 token/chunk**，比传统 RAG 的 256-512 更大。

### 3. 增量更新是个坑

图结构让增量更新变得复杂——新增一个实体可能改变社区结构，导致需要重新计算社区检测和摘要。目前 Graph RAG 的设计假设是"全量重建"，对于频繁更新的文档集不友好。一个折中方案是分区索引（按文档或时间段分区），只重建变更的分区。

### 4. 社区层级的选择

Leiden 产出的是多层社区结构。Global Search 用哪一层？
- 层级太高（Level 0）：摘要太多，map-reduce 成本高
- 层级太低（Level 2/3）：摘要太粗糙，信息丢失

经验法则是选 **实体数中位数在 20-100 的那一层**。太小没聚合效果，太大每个摘要就失去主题聚焦性了。

---

## 与 LightRAG 等变体的对比

2024 年底出现了几个 Graph RAG 的变体，最值得注意的是 **LightRAG**：

| | Graph RAG (Microsoft) | LightRAG |
|---|---|---|
| 社区检测 | Leiden（层级化） | 不显式做，用图遍历替代 |
| 查询模式 | Global + Local | Naive / Local / Global / Hybrid 四种 |
| 索引时间 | 慢（多次 LLM 调社区摘要） | 快（跳过社区摘要） |
| 实体消歧 | LLM-based | 向量相似度 + LLM 辅助 |
| 适用场景 | 大规模静态文档集 | 快速迭代、中小规模 |

LightRAG 本质上是用检索时的图遍历（BFS/DFS）替代了离线社区摘要，牺牲了一些全局理解能力换来了更高的索引速度。

---

## 总结

Graph RAG 解决的不是检索精度问题，而是**检索范式问题**——从 "找到包含答案的 chunk" 变成 "理解文档的全局结构"。这个思路的价值远超 RAG 本身：它证明了 **LLM + 图结构** 是一种比 LLM + 向量更丰富的知识表示方式。

对于后端工程师来说，Graph RAG 的技术栈其实很熟悉：图数据库（Neo4j/Neptune）、图算法（Leiden/Louvain）、Map-Reduce 模式——加上 LLM 作为"智能提取器"。你需要关注的不是这些组件本身，而是它们组合后产生的协同效应。

**下一步可以深挖的方向**：
- 用 Graph RAG 做代码库理解（实体 = 函数/类/模块，关系 = 调用/继承/依赖）
- 多跳推理：不只查 1-2 hop 邻居，而是让 LLM 沿图做多步推理
- 图 + 向量双索引：局部事实走图，语义相似走向量，路由分发

---

## 参考

- Edge, D., et al. "From Local to Global: A Graph RAG Approach to Query-Focused Summarization." arXiv:2404.16130, 2024.
- Traag, V.A., et al. "From Louvain to Leiden: guaranteeing well-connected communities." Scientific Reports, 2019.
- LightRAG: https://github.com/HKUDS/LightRAG
