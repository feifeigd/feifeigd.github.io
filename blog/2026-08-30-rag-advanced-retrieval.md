---
title: "RAG 进阶实战：切块策略、混合检索与 Re-ranking 的量化收益与工程取舍"
date: 2026-08-30T20:00:00+08:00
draft: false
tags: ["ai", "llm", "rag", "vector-database", "embedding", "engineering", "performance"]
categories: ["Tech"]
description: "RAG 上线容易、效果好难：切块大小怎么定、为什么混合检索是及格线不是加分项、cross-encoder 重排值不值那几十毫秒、Graph RAG 什么时候才值得上。附三份可运行的 Python 代码与一张效果/成本对照表。"
---

RAG 的链路谁都能搭：文档切块、embedding 进库、相似度召回、拼 prompt。但同一套链路，有人线上答对率八成，有人五成——差距不在「会不会搭」，而在「每一步的效果账算没算清」。基础链路见 [RAG 全链路解析](/blog/2026/08/26/rag-interview)，这篇讲进阶：切块、混合检索、Re-ranking 各值多少分、花多少钱，Graph RAG 什么时候才值得上。

{/* truncate */}

## 一、切块：先定评估，再调参数

切块是整条链路里性价比最高的一环：不动模型、不加延迟，纯靠把检索单元切对，召回质量就能拉开档次。但切块没有全局最优解，只有「对齐答案粒度」的局部最优：

| 块大小 | 效果特征 | 典型翻车方式 |
|--------|----------|--------------|
| 128 token 左右 | 召回精度高、上下文完整 | 答案跨块，LLM 只看到一半 |
| 256-512 token | 语义完整与噪声的甜点 | 无 |
| 1024+ token | 上下文最完整 | 向量被稀释，相似度普遍偏低 |

社区反复验证的经验结论：**从 512 附近起步，按文档类型和评测数据调**，而不是照抄某个默认值。「切块大小」和「检索精度」不是单调关系——块越小向量越聚焦，但答案被切碎的风险越大；块越大上下文越全，但噪声越多。用你的真实数据测，别信默认参数。

实操里最常见的错误是把「句子」和「块」混为一谈。句子是语法单元，块是检索单元，两者边界不一致时应该在句子边界处断开。语义切块就是干这个的：相邻句子的向量相似度出现拐点时断开：

```python
# semantic_chunk.py —— 相邻句相似度低于阈值处断开，min_chunk 防止碎块
import numpy as np
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("BAAI/bge-m3")  # 多语言模型，中文友好

def semantic_chunk(sentences: list[str], threshold: float = 0.72, min_chunk: int = 3):
    vecs = model.encode(sentences, normalize_embeddings=True)
    chunks, cur = [], []
    for i, s in enumerate(sentences):
        cur.append(s)
        if len(cur) >= min_chunk and i + 1 < len(sentences):
            if float(vecs[i] @ vecs[i + 1]) < threshold:  # 与下一句出现语义拐点
                chunks.append("\n".join(cur))
                cur = []
    if cur:
        chunks.append("\n".join(cur))
    return chunks
```

两个中文场景的坑：**一是句子切分要按中文标点（。！？）做硬边界**，英文句号在中文文本里不可靠；**二是别用英文专用 embedding 切中文**，token 效率差近一半，语义边界也会漂。bge-m3、multilingual-e5 这类多语言模型是中文默认选择。

## 二、召回：混合检索是及格线，不是加分项

纯向量检索有两个经典失败模式：**精确匹配失败**（查「CVE-2024-1234」「A100-80G」这类专有名词，语义相近但向量距离远）和**语义漂移失败**（查「上季度营收」，dense 能懂，BM25 只能匹配字面）。BEIR 系列基准上反复验证的结论：**BM25 与 dense 互补，混合检索在多数数据集上比单路高 2-5 个点 nDCG@10**——这不是优化项，是及格线。

融合方式首选 **RRF（Reciprocal Rank Fusion）**：不看分数看排名，把两路的排名倒数相加。它最大的工程优势是**免标定**——BM25 的分数和向量余弦相似度量纲完全不同，加权求和得反复调权重，RRF 不需要：

```python
# hybrid_retrieval.py —— BM25 + 向量召回，RRF 融合
import numpy as np
import jieba  # 中文必须先分词，BM25 按词匹配
from rank_bm25 import BM25Okapi
from sentence_transformers import SentenceTransformer

dense = SentenceTransformer("BAAI/bge-m3")

def tokenize(t: str) -> list[str]:
    return jieba.lcut(t)

class HybridRetriever:
    def __init__(self, docs: list[str]):
        self.docs = docs
        self.bm25 = BM25Okapi([tokenize(d) for d in docs])
        self.dvecs = dense.encode(docs, normalize_embeddings=True)

    def search(self, query: str, top_n: int = 10, k: int = 60):
        bm_hits = self.bm25.get_top_n(tokenize(query), self.docs, n=k)
        qv = dense.encode([query], normalize_embeddings=True)[0]
        dense_hits = [self.docs[i] for i in np.argsort(-(self.dvecs @ qv))[:k]]
        scores: dict[str, float] = {}
        for rank, doc in enumerate(bm_hits + dense_hits):
            scores[doc] = scores.get(doc, 0.0) + 1.0 / (k + rank + 1)  # RRF
        return sorted(scores.items(), key=lambda x: -x[1])[:top_n]
```

两个细节：**RRF 的平滑常数 k 取 60 是社区默认**，含义是排名 60 开外基本不给分，两路都命中的文档排名叠加、天然去重；**中文必须分词**——rank_bm25 默认按空格切词，中文不预先 jieba 分词，BM25 这一路等于废的，这是最容易踩的坑。

混合检索之上还有一层 query 改写：**HyDE**（让 LLM 先写一段假设答案，拿假设答案去检索）和 **multi-query**（一个问题拆成多个子查询）。收益真实，但代价是每次检索多 1 次 LLM 调用、延迟加几百毫秒。工程判断：**recall 够用就别加**，只有线上评估发现「答案在库里但召不回」才上。

## 三、Re-ranking：花几十毫秒，买 3-10 个点

召回阶段用 bi-encoder：query 和 doc 各自编码成向量做点积，快，但精度有限——编码时两边互相看不到对方。**cross-encoder 把 query 和 doc 拼成一对做全交叉注意力，精度高一个档次，但慢一到两个数量级**。所以正确姿势永远是两级流水线：bi-encoder 召回 top-50，cross-encoder 重排取 top-5：

```python
# rerank.py —— cross-encoder 对召回结果重排
import numpy as np
from sentence_transformers import CrossEncoder

reranker = CrossEncoder("BAAI/bge-reranker-v2-m3")  # 多语言，中文可用

def rerank(query: str, docs: list[str], top_n: int = 5):
    scores = reranker.predict([(query, d) for d in docs])  # 逐对打分
    order = np.argsort(-scores)[:top_n]
    return [(docs[i], float(scores[i])) for i in order]
```

值不值？BEIR 系列和 Cohere Rerank 报告的共识：**重排通常带来 3-10 个点 nDCG@10 的提升，对「召回多但排序差」的场景收益最大**——典型情况是相关文档排在 15-20 名，向量相似度已经拉不开差距，cross-encoder 能把它捞回前 5。

代价要算清：cross-encoder 逐对推理，**top_k 越大延迟线性增长**。GPU 上 bge-reranker 处理 50 对大约几十毫秒，CPU 上直奔几百毫秒，QPS 一高就是事故。工程约束：top_k 从 50 起步、按延迟预算调；**重排结果按 query 缓存**（同一问题短期重复出现是常态）；GPU 扛不住就降级为只对 top-20 重排，收益打折但保命。

## 四、Graph RAG：全局问题的解药，别当万能药

naive RAG 有个结构性盲区：**需要跨文档聚合的全局性问题**。「过去一年所有安全审计结论是什么」「哪些部门的权限变更涉及同一批系统」——答案分散在几十个文档里，向量检索召回的是碎片，LLM 拼不出全局。微软 GraphRAG 的路线：离线用 LLM 抽取实体-关系图，做 Leiden 社区检测，给每个社区生成分层摘要，全局搜索走 map-reduce 汇总。论文用 LLM-as-judge 评测，在全局问题的完备性、多样性、可操作性三个维度比 naive RAG 高约七成、六成、七成（单数据集量级参考，别当普适结论）。

但代价真实：**索引阶段要跑 LLM 抽取实体和摘要，构建成本是 naive RAG 的几十倍**；局部事实问答（「XX 接口的参数是什么」）它未必比向量检索强。工程结论是分场景双轨：

| 通道 | 适用问题 | 成本 |
|------|----------|------|
| 向量 RAG + 重排 | 局部事实、单文档细节 | 低，检索毫秒级 |
| Graph RAG 全局搜索 | 跨文档聚合、关系问答 | 高，索引贵、推理慢 |

先看线上 query 分布：全局性问题占比低（通常不足一成）就只做向量通道，把 Graph 当离线分析工具用，别为小概率问题背上全量索引成本。

## 五、踩坑清单

- **换 embedding 模型必须全量重建索引**。不同模型的向量空间不可比，混着索引等于随机召回。把模型名和版本写进索引元数据，发布按版本隔离——这是线上召回断崖的头号原因。
- **元数据过滤先于向量检索**。按租户、文档集、时间范围做 pre-filter 再跑 ANN，能砍掉九成无效向量计算；post-filter 是召回率杀手。
- **中文 embedding 别用英文专用模型**。英文模型对中文 token 效率差、语义粒度粗，检索质量断档式下降。
- **没有 golden set 就没有优化**。抽 100-200 条真实 query 人工标注，跑 nDCG@10 回归，每次动切块/召回/重排参数都要过一遍。不上回归的「优化」都是玄学，每个上线版本都得回答「比上个版本好多少」。

## 六、效果账总结

| 环节 | 收益 | 成本 | 优先级 |
|------|------|------|--------|
| 切块调优 | 高（召回质量分档） | 免费，纯离线 | 1 |
| 混合检索（RRF） | 2-5 个点 nDCG@10 | 一个 BM25 索引，零延迟 | 2 |
| Cross-encoder 重排 | 3-10 个点 nDCG@10 | 每请求几十毫秒 GPU | 3 |
| Graph RAG | 全局问题质变 | 索引成本几十倍 | 4（按需） |

RAG 的效果从来不是某一环的功劳，而是「切块对齐答案粒度、混合召回保底、重排拉精度」的叠加。先把前三环做扎实，再谈 Graph 和 query 改写——顺序反了，钱花了，效果还是上不去。
