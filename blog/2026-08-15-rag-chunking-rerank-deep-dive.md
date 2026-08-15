---
title: "RAG 检索优化深度拆解：分块策略到 Cross-Encoder 重排序，召回率提升的完整链路"
date: 2026-08-15T21:30:00+08:00
draft: false
tags: ["ai", "llm", "rag", "vector-database", "performance", "engineering"]
categories: ["AI"]
description: "RAG 的精度天花板在检索不在生成。从五种分块策略（固定/递归/语义/Late Chunking/父子）到 Hybrid Search + RRF 融合，再到 Cross-Encoder 两段式重排序，一条完整可运行的检索优化链路，附 recall 提升量级、成本延迟权衡与生产踩坑记录。"
---

先抛一个反直觉的结论：**RAG 效果不好的时候，九成问题出在检索，而不是生成**。生成模型再强，检索漏掉的 chunk 永远不会出现在 context 里——"垃圾进，垃圾出"在 RAG 里是一条铁律。业界普遍共识是「检索质量决定 RAG 上限」：生成只能在上限之内修修补补，把答案写得通顺，但补不回没检索到的事实。

本文不聊"如何搭一个 hello-world RAG"，而是拆解检索链路里真正决定召回率的三个环节——**分块（Chunking）、检索融合（Hybrid Search）、重排序（Re-ranking）**——每一环给出可运行代码、性能量级和生产踩坑记录。这是我在多个生产 RAG 系统里反复调过的地方。

{/* truncate */}

## 一、先看清瓶颈在哪：Recall 才是第一指标

RAG 的检索阶段和搜索引擎一样，核心指标是 **Recall@k**（前 k 个结果里有多少个真正相关的）和 **nDCG@k**（排序质量）。生成阶段用的是 LLM，它只看得到你喂进去的那 k 个 chunk，所以：

> 最终答案质量 ≤ 检索质量 × 生成质量

而生成质量对现代 LLM 来说已经很高、很稳定，于是决定性的变量只剩检索。一个经典的工程实践是：先测 **Recall@10**，如果召回都没到位，调 prompt、换生成模型都是白费力气。

这引出一个贯穿全文的两段式范式：**先追求高召回（宁可多召回、不放过），再用重排序把精度拉回来（把相关项排到前面）**。粗排负责"全"，精排负责"准"，这是从传统搜索引擎继承下来、在 RAG 里依然成立的基本盘。

## 二、分块策略：切得好，成功一半

分块决定了检索的基本单元。切太碎，语义被割裂，embedding 失去上下文；切太大，检索粒度粗、噪音多，还容易撑爆 context。五种策略各有适用场景。

### 2.1 固定大小 + 滑动窗口

最简单，也最常用。按固定 token 数切，相邻块之间留 overlap 防止语义在边界被切断。

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=512,      # 目标块大小（token）
    chunk_overlap=64,    # 相邻块重叠，防止边界截断语义
    separators=["\n\n", "\n", "。", "！", "？", " ", ""],
)
chunks = splitter.split_text(document)
```

关键在于 `separators`：它从"段落 → 换行 → 句号 → 空格"逐级降级切分，优先在**自然的语义边界**断开，而不是粗暴地在第 512 个 token 处砍一刀。这是 LangChain 递归切分的精髓——"递归"指的不是算法递归，而是分隔符的优先级降级。

### 2.2 语义分块（Semantic Chunking）

固定大小的问题是：它不理解语义。一个完整的论点可能刚好跨越两个块的边界。语义分块的思路是**让 embedding 相似度来决定边界**——相邻句子的语义相似度骤降处，就是天然的切分点。

```python
import numpy as np

def semantic_chunk(sentences, embeddings, threshold=0.6):
    chunks, buf = [], [sentences[0]]
    for i in range(1, len(sentences)):
        a, b = embeddings[i - 1], embeddings[i]
        sim = float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))
        if sim < threshold:          # 语义断裂点 → 切分
            chunks.append("".join(buf))
            buf = [sentences[i]]
        else:
            buf.append(sentences[i])
    chunks.append("".join(buf))
    return chunks
```

`threshold` 是要调的：调低 → 块更大、更少；调高 → 块更碎。语义分块在**结构松散的文档**（会议纪要、论坛帖、访谈）上明显优于固定切分，因为它按内容本身的逻辑断点走。代价是慢——每个句子都要过一次 embedding，离线建索引还好，但别在请求路径上做。

### 2.3 Late Chunking（Jina 提出）

这是最近两年的一个漂亮改进，解决了一个隐蔽的问题：**长文档的 embedding 失真**。传统做法是先切块再分别 embed，每个块只看得到自己那点上下文；Late Chunking 反其道而行——**先对整段文档过一遍 encoder，拿到每个 token 的上下文感知表征，再按块边界做池化**。

```python
# 概念示意：先整段编码，再按 chunk 边界池化
# token_embeddings: (seq_len, dim)，来自整个文档的一次前向
def late_chunk_pool(token_embeddings, chunk_boundaries):
    chunks = []
    for start, end in chunk_boundaries:
        # 对属于该 chunk 的 token 做 mean pooling
        chunks.append(token_embeddings[start:end].mean(axis=0))
    return chunks
```

Jina 的官方 benchmark 显示，在长文档检索任务上，Late Chunking 相比先切后 embed 的 baseline 有明显 nDCG 提升（不同数据集量级不一，但方向一致且稳定）。它特别适合**法律合同、学术论文**这类"一个概念跨越多个自然段"的文本。实现门槛在于：需要访问 encoder 的 token 级输出，很多托管 embedding API 只返回句子级向量，只有用本地/开源 encoder（如 Jina 的 jina-embeddings-v3）才能做。

### 2.4 Parent-Child 父子分块

一个非常实用、几乎零成本提升的工程技巧：**用小 chunk 检索，用大 chunk 喂给 LLM**。小 chunk 更精准，但语义不完整；大 chunk 完整，但检索噪音大。父子分块把两者结合——检索命中"子块"，但把包含它的"父块"（更大的上下文窗口）一起放进 prompt。

```python
# 建索引：父块是段落，子块是句子
# 检索：命中子块 sentence_3 → 返回其父块 paragraph_2
parent_of = {
    "sentence_1": "paragraph_1",
    "sentence_2": "paragraph_1",
    "sentence_3": "paragraph_2",   # 命中这个，返回 paragraph_2 全文
}
```

LangChain 的 `ParentDocumentRetriever` 就是这个模式的开箱实现。它的收益立竿见影：检索精度没变，但生成时每个命中项携带的上下文从一两句变成了完整段落，答案的连贯性和引用完整性显著提升。

### 分块大小的经验值

没有银弹，但有量级经验：**256–512 token 是大多数场景的甜点区**，overlap 取 10%–20%。块太小（128 以下）会拆散语义、稀释 embedding 质量；块太大（1024 以上）检索粒度粗、命中噪音多，且多块拼接时更容易超 context。代码文档可以更碎（函数级），法律/学术文本宜更大。**先在你的领域数据上扫一遍 chunk_size 做 Recall@10 曲线，比任何论文结论都靠谱。**

## 三、检索融合：Hybrid Search 与 RRF

### 3.1 稀疏与稠密为什么互补

稠密检索（embedding 余弦相似度）擅长**语义匹配**——"怎么修漏水的水龙头"和"水龙头坏了怎么办"能对上。但它在**精确术语匹配**上会翻车：查 "EKS-2025-0047 这个 CVE"，embedding 很可能把编号当成无意义的 token 忽略掉。

稀疏检索（BM25）恰好相反：对术语、ID、专有名词的精确匹配极强，但完全不懂语义。两者互补，于是 **Hybrid Search = BM25 + Dense** 成了事实标准。在 BEIR 多领域基准上，混合检索相比纯稠密平均 Recall@100 提升约 10%（量级，具体幅度随领域波动，代码、医疗等术语密集领域提升更明显）。

```python
from rank_bm25 import BM25Okapi

def hybrid_search(query, docs, dense_embeddings, query_embedding, top_k=50):
    # 1) 稀疏：BM25 打分
    bm25 = BM25Okapi([d.split() for d in docs])
    sparse_scores = bm25.get_scores(query.split())

    # 2) 稠密：余弦相似度
    q = query_embedding / np.linalg.norm(query_embedding)
    dense_scores = [float(np.dot(q, e) / np.linalg.norm(e)) for e in dense_embeddings]
    return sparse_scores, dense_scores
```

### 3.2 RRF 融合

两个检索源各自打分，分数尺度不同（BM25 无上界，余弦相似度在 -1 到 1 之间），**直接相加没有意义**。标准解法是 **RRF（Reciprocal Rank Fusion）**——只看排名不看分数：

```python
def rrf_fuse(rank_lists, k=60):
    """rank_lists: 多个排序后的 doc_id 列表（按相关性降序）"""
    scores = {}
    for ranks in rank_lists:
        for rank, doc_id in enumerate(ranks):
            scores[doc_id] = scores.get(doc_id, 0) + 1.0 / (k + rank + 1)
    return sorted(scores.items(), key=lambda x: -x[1])
```

`k=60` 是经验常数，几乎不用调。RRF 的妙处在于**完全无参、对分数分布不敏感**，比加权求和（要手调 BM25 和 dense 的权重系数）鲁棒得多。加权求和也可以，但权重成了新的超参数，跨领域迁移时又要重调。

### 3.3 Query 改写与 HyDE

检索前还有一个便宜又有效的步骤：**改写 query**。用户问"这玩意儿怎么装不上"，改写后的 query 是"安装失败 报错 troubleshooting"。两个思路：

- **Query Rewriting**：用 LLM 把口语化、含糊的 query 扩展成多个检索友好的子查询（multi-query）。
- **HyDE（Hypothetical Document Embeddings）**：让 LLM 先"假设"一个理想答案，用这个假设答案的 embedding 去检索，而不是用原 query 的 embedding。因为"答案"和"文档"的语义空间更接近。

这两招对**短 query、口语 query** 提升明显，代价是多一次 LLM 调用（几十到几百 ms）。适合在检索质量长期不达标的场景做针对性优化，不建议无脑加。

## 四、重排序：Cross-Encoder 的降维打击

### 4.1 Bi-Encoder vs Cross-Encoder

前面所有检索都基于 **Bi-Encoder**：query 和 document 各自独立编码成向量，再用点积/余弦算相似度。这是唯一可行的方案，因为 document 的 embedding 可以**离线预计算、存进向量库**，在线只需算一次 query embedding。

**Cross-Encoder** 则把 query 和 document **拼在一起**送进模型，让它们的 token 做交叉注意力，输出一个相关性分数：

```python
from sentence_transformers import CrossEncoder

model = CrossEncoder("BAAI/bge-reranker-v2-m3")

def rerank(query, candidates, top_n=10):
    pairs = [[query, doc] for doc in candidates]
    scores = model.predict(pairs)   # 每个 (query, doc) 对的相关性分
    ranked = sorted(zip(scores, candidates), key=lambda x: -x[0])
    return [doc for _, doc in ranked[:top_n]]
```

为什么 Cross-Encoder 更准？因为它能看到 query 和 doc 的**交互**——"苹果"是水果还是公司，取决于 doc 里同时出现的"iPhone"还是"富士"。Bi-Encoder 把两边独立压成向量，这种交互信息在池化那一刻就丢了。代价是：**每个 query-doc 对都要完整前向一遍**，无法预计算，所以只能用在候选集已经缩小的精排阶段。

### 4.2 两段式检索范式

这引出了生产 RAG 的标准架构：

```
粗排（Bi-Encoder，离线 embedding + 向量库）→ 取 top-50~100 → 精排（Cross-Encoder）→ 取 top-5~10 → 喂 LLM
```

关键结论：**粗排多取一点，精排重新排序**，比"粗排直接取 top-10 喂 LLM"效果好得多。因为 Bi-Encoder 的 top-10 里往往混着假阳性，而 Cross-Encoder 有能力把它们挑出来。实测上，把候选从 10 扩到 100 再 rerank 回 10，nDCG@10 通常有 5–15 个百分点的提升（量级，具体看数据和 reranker 型号）——这是 RAG 里**性价比最高的单点优化之一**。

### 4.3 成本与延迟的权衡

Cross-Encoder 不是免费的。以 bge-reranker-v2-m3 为例，在 A10 上 rerank 100 个候选大约几十到一百多 ms（batch 后摊薄）。所以：

- **候选别取太多**：50–100 是甜点，取 500 个 rerank 纯粹浪费算力，还增加尾延迟。
- **用 batch 推理**：`model.predict` 默认 batch，别一个个循环调。
- **考虑轻量 reranker**：bge-reranker-base 比 v2-m3 小得多、快得多，精度略降。对延迟敏感的场景，base 版往往够用。
- **领域匹配**：通用 reranker 在垂直领域（医疗、法律、金融）可能失效，这时需要微调一个领域 reranker，或者用 LLM 直接做 listwise 重排（把候选列表丢给 LLM 排序）。

## 五、端到端：一个完整的两段式检索管线

把上面所有环节串起来，就是一个生产可用的最小检索服务：

```python
import numpy as np
from rank_bm25 import BM25Okapi
from sentence_transformers import CrossEncoder

class TwoStageRetriever:
    def __init__(self, docs, doc_embeddings, reranker_name="BAAI/bge-reranker-v2-m3"):
        self.docs = docs
        self.doc_embeddings = doc_embeddings          # 离线预计算好的 (n, dim)
        self.bm25 = BM25Okapi([d.split() for d in docs])
        self.reranker = CrossEncoder(reranker_name)

    def retrieve(self, query, query_embedding, coarse_k=100, final_k=8):
        # 1) 粗排：Hybrid Search（BM25 + Dense）+ RRF 融合
        sparse = self.bm25.get_scores(query.split())
        q = query_embedding / np.linalg.norm(query_embedding)
        dense = np.array([float(np.dot(q, e) / np.linalg.norm(e))
                          for e in self.doc_embeddings])
        sparse_rank = np.argsort(-sparse)[:coarse_k]
        dense_rank = np.argsort(-dense)[:coarse_k]
        fused = dict(self._rrf(sparse_rank, dense_rank))

        # 2) 精排：Cross-Encoder 重排序
        candidates = [self.docs[i] for i in fused[:coarse_k]]
        scores = self.reranker.predict([[query, d] for d in candidates])
        ranked = sorted(zip(scores, candidates), key=lambda x: -x[0])
        return [d for _, d in ranked[:final_k]]

    @staticmethod
    def _rrf(rank_lists, k=60):
        out = {}
        for ranks in rank_lists:
            for rank, idx in enumerate(ranks):
                out[idx] = out.get(idx, 0) + 1.0 / (k + rank + 1)
        return sorted(out.items(), key=lambda x: -x[1])
```

这个管线跑通后，你的 RAG 已经从"能出结果"升级到"检索质量真正够用"。剩下的是围绕它做工程化：缓存、并发、降级。

## 六、生产踩坑记录

这些是我在真实系统里踩过、值得提前避开的坑：

1. **chunk 重叠没对齐到句子边界**：固定 overlap 在中文里尤其坑，因为中文没有空格分词，overlap 常把一个词拦腰截断。解法是 overlap 也按标点/句子对齐，或者干脆用语义分块。
2. **reranker 的 token 上限**：多数 Cross-Encoder 最大 512 token。候选 chunk 超过 512 token 会被静默截断，分数失真。**rerank 前先截断/压缩候选**，别让超长 chunk 直接进 reranker。
3. **向量库只存了 embedding 没存原文**：rerank 阶段需要原文文本做交叉注意力，只有向量是不够的。建索引时务必**同时持久化 chunk 文本**。
4. **hybrid 权重盲调**：前面说了，用 RRF 别用加权求和。如果一定要加权，用一个小验证集网格搜索，别拍脑袋定系数。
5. **query 和 doc 用了不同的 embedding 模型**：Hybrid 里 BM25 无所谓，但 dense 检索必须保证 query 和 doc 用**同一个 encoder**（或对称设计的模型），否则向量不在同一语义空间，检索结果随机化。
6. **rerank 后的 top-k 喂 LLM 时没排序**：Cross-Encoder 给的是相关性分数，务必按分数降序喂给 LLM。LLM 对位置敏感，越相关越靠前，答案质量越好。

## 七、选型决策表

| 场景 | 分块 | 检索 | 是否 rerank |
|---|---|---|---|
| 代码库问答 | 函数级，小 chunk | BM25 为主 + dense | 可选，术语多 |
| 长文档 QA（合同/论文） | Late Chunking 或父子 | Hybrid + RRF | 强烈建议 |
| 短 query 客服机器人 | 固定 + 语义改写 | HyDE + dense | 建议 |
| 高并发低延迟（流式） | 固定小 chunk | 纯 dense | 用轻量 reranker 或跳过 |
| 垂直领域（医疗/法律） | 语义分块 | Hybrid | 用领域微调 reranker |

---

**一句话总结**：RAG 检索优化的正确姿势是「**切块按语义、粗排靠融合、精排上 Cross-Encoder**」——先保证 Recall，再用 rerank 拉回精度，两个阶段各司其职，比在 prompt 上雕花有用得多。
