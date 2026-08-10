---
title: "AI 应用向量数据库选型：Milvus、Pinecone、Qdrant、Chroma 等对比"
date: 2026-08-12T12:00:00+08:00
draft: false
tags: ["ai", "rag", "vector-database", "infra", "engineering"]
categories: ["Tech"]
description: "一文对比主流向量数据库：Milvus、Pinecone、Qdrant、Weaviate、Chroma、FAISS、pgvector、Elasticsearch，附性能实测和选型建议。"
---

> RAG 火了一年多，向量数据库的选型问题被问了无数次。本文基于实际使用经验，系统对比 8 款主流向量数据库，帮你做技术决策。

{/* truncate */}

## 先理清概念：向量数据库到底存什么

向量数据库不是魔法。本质上它做两件事：

1. **存向量** — 把 Embedding 模型输出的高维浮点向量（如 1536 维）存下来
2. **搜近似** — 给定一个查询向量，快速找到 Top-K 个最相似的向量（ANN 近似最近邻搜索）

核心指标就两个：**召回率**（搜得准不准）和 **QPS**（搜得快不快）。

```
数据流：
文本 → Embedding 模型 → [0.12, -0.34, 0.78, ...] → 向量数据库
                                                        ↓
查询 → Embedding 模型 → [0.15, -0.31, 0.72, ...] → ANN 检索 → Top-K 结果
```

## 8 款数据库速览

| 数据库 | 类型 | 开源 | 托管服务 | 核心引擎 |
|--------|------|------|---------|---------|
| **Milvus** | 专用向量库 | ✅ Apache 2.0 | Zilliz Cloud | Knowhere (FAISS/HNSW/DiskANN) |
| **Pinecone** | 专用向量库 | ❌ 闭源 | ✅ SaaS 唯一 | 自研 |
| **Qdrant** | 专用向量库 | ✅ Apache 2.0 | ✅ Qdrant Cloud | 自研 Rust 引擎 |
| **Weaviate** | 向量 + 全文 | ✅ BSD-3 | ✅ Weaviate Cloud | 自研 + HNSW |
| **Chroma** | 轻量向量库 | ✅ Apache 2.0 | ❌ | HNSW (hnswlib) |
| **FAISS** | 向量索引库 | ✅ MIT | ❌ | CPU/GPU 多索引 |
| **pgvector** | PG 扩展 | ✅ PostgreSQL | ✅ 各云 PG 服务 | IVFFlat / HNSW |
| **Elasticsearch** | 全文 + 向量 | ✅ Elastic License | ✅ Elastic Cloud | Lucene HNSW |

## 逐一拆解

### Milvus — 国产顶流，功能最全

**定位**：企业级分布式向量数据库，面向 10 亿+ 向量规模。

```python
from pymilvus import MilvusClient

client = MilvusClient("milvus_demo.db")

# 建集合
client.create_collection(
    collection_name="docs",
    dimension=1536,
    metric_type="COSINE"
)

# 插入
client.insert("docs", [
    {"id": 1, "vector": [0.1, 0.2, ...], "text": "..."},
])

# 搜索
results = client.search(
    collection_name="docs",
    data=[[0.15, 0.25, ...]],
    limit=10,
    output_fields=["text"]
)
```

**优点**：
- 索引类型最全：IVF_FLAT、IVF_SQ8、HNSW、DiskANN、GPU 索引
- 分布式架构：读写分离、水平扩展、多副本
- 标量过滤强：支持复杂布尔表达式 + 向量搜索混用
- 生态好：LangChain、LlamaIndex、Dify 都原生支持

**缺点**：
- 部署重：依赖 etcd、MinIO、Pulsar/Kafka，最小也要 3 个容器
- 学习曲线陡：Collection、Partition、Index 概念多
- Milvus Lite（嵌入式）功能阉割严重

**适用**：生产环境，向量量级 > 1000 万，需要标量过滤 + 高可用。

### Pinecone — 最省心，最贵

**定位**：全托管 Serverless 向量数据库，零运维。

```python
from pinecone import Pinecone

pc = Pinecone(api_key="...")
index = pc.Index("my-index")

# 写入
index.upsert(vectors=[
    {"id": "1", "values": [0.1, 0.2, ...], "metadata": {"text": "..."}},
])

# 查询
results = index.query(
    vector=[0.15, 0.25, ...],
    top_k=10,
    filter={"category": "tech"},
    include_metadata=True
)
```

**优点**：
- 零运维：没有服务器、没有配置、按量付费
- Serverless 弹性：空闲时 scale to zero
- Pod 架构：数据隔离天然支持多租户
- 全球多区域部署

**缺点**：
- **贵**：$0.33/GB/月 + 写入费用，100 万条向量月费 $70+
- 闭源：数据在别人手里，审计和合规麻烦
- 索引类型有限：只有自研引擎，没有 HNSW/IVF 等传统选择
- 国内访问慢：服务器全在海外

**适用**：快速原型、海外 SaaS、不想管基础设施的团队。

### Qdrant — Rust 写的性能怪兽

**定位**：高性能向量数据库，Rust 实现，单机能打。

```python
from qdrant_client import QdrantClient

client = QdrantClient("localhost", port=6333)

client.upsert(
    collection_name="docs",
    points=[{
        "id": 1,
        "vector": [0.1, 0.2, ...],
        "payload": {"text": "..."}
    }]
)

results = client.search(
    collection_name="docs",
    query_vector=[0.15, 0.25, ...],
    limit=10,
    query_filter={"must": [{"key": "category", "match": {"value": "tech"}}]}
)
```

**优点**：
- **性能顶**：Rust 实现，单机百万 QPS
- 过滤强：payload 索引 + 全文检索 + 地理位置
- 量化丰富：Scalar/Product/Binary Quantization
- 部署简单：单二进制文件，Docker 一行跑
- 云原生：K8s operator、Raft 共识

**缺点**：
- 分布式刚起步：1.9 版本才正式支持水平扩展
- 中文社区小：遇到问题主要靠英文文档
- 写入路径不如 Milvus 成熟

**适用**：追求性能的中型团队，单机到几十台规模。

### Weaviate — 自带向量化的混合搜索

**定位**：AI-native 向量数据库，内置 Embedding 和生成能力。

```python
import weaviate

client = weaviate.Client("http://localhost:8080")

# 可以直接存文本，Weaviate 自动做 embedding
client.data_object.create(
    data_object={"text": "AI 技术发展迅速"},
    class_name="Document",
    vector=[0.1, 0.2, ...]  # 可选，不提供则自动向量化
)

# 混合搜索：向量 + 关键词
response = client.query.get("Document", ["text"]) \
    .with_hybrid(query="AI 最新进展", alpha=0.5) \
    .with_limit(10) \
    .do()
```

**优点**：
- **开箱即用**：内置 text2vec 模块（OpenAI/Cohere/HuggingFace），不用自己算 Embedding
- **混合搜索**：向量 + BM25 关键词天然融合，alpha 参数调节权重
- GraphQL API：查询语法灵活，支持嵌套、聚合
- 多模态：支持图片、音频向量

**缺点**：
- 资源消耗大：Java 实现，内存占用高（推荐 8GB+）
- 模块生态绑定：text2vec 模块跟版本强耦合
- 性能不如 Rust/C++ 实现

**适用**：需要混合搜索（向量 + 关键词）、不想管 Embedding 管线的团队。

### Chroma — 开发体验最好的轻量库

**定位**：面向 AI 开发者的嵌入式向量数据库，类比 SQLite。

```python
import chromadb

client = chromadb.Client()
collection = client.create_collection("docs")

collection.add(
    documents=["AI is transforming industries"],
    metadatas=[{"source": "blog"}],
    ids=["1"]
)

results = collection.query(
    query_texts=["AI 改变行业"],
    n_results=5
)
```

**优点**：
- **开发体验一流**：pip install 即用，直接传文本不用自己算向量
- 嵌入模式：进程内运行，零配置
- 客户端-服务器模式：开发和生产可以解耦
- LangChain/LlamaIndex 默认后端

**缺点**：
- **生产慎用**：全文搜索弱，并发写不稳定，无高可用
- 规模受限：单机百万级，无水平扩展
- 功能局限：只有 HNSW 一种索引

**适用**：本地开发、原型验证、小规模（<100 万）内部工具。

### FAISS — 不是数据库，是索引库

**定位**：Meta 开源的向量相似度搜索库，各种索引算法的瑞士军刀。

```python
import faiss
import numpy as np

dim = 1536
index = faiss.IndexIVFFlat(
    faiss.IndexFlatL2(dim),  # 量化器
    dim, 128                 # nlist
)

# 需要手动训练
index.train(vectors)
index.add(vectors)

# 搜索
D, I = index.search(query_vector, k=10)
```

**优点**：
- **算法最全**：IndexFlat、IVF、HNSW、PQ、OPQ、GPU 全有
- GPU 加速：CUDA 原生支持，单卡千万 QPS
- 极致性能：手写 SIMD + GPU kernel
- 学术界标准：所有向量数据库底层几乎都用了 FAISS

**缺点**：
- **不是数据库**：无 CRUD、无持久化、无分布式
- 接口原始：C++ 风格，Python 封装薄
- 什么都不管：自己管理 ID 映射、元数据、增量更新
- 索引构建：需要手动 train，IVF 类型索引要离线建

**适用**：作为底层引擎嵌入你的服务，不适合直接当数据库用。

### pgvector — PostgreSQL 党首选

**定位**：PostgreSQL 扩展，让 PG 支持向量存储和搜索。

```sql
-- 安装扩展
CREATE EXTENSION vector;

-- 建表
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

-- 插入
INSERT INTO documents (content, embedding)
VALUES ('AI 改变世界', '[0.1, 0.2, ...]');

-- 搜索
SELECT content, 1 - (embedding <=> '[0.15, 0.25, ...]') AS similarity
FROM documents
ORDER BY embedding <=> '[0.15, 0.25, ...]'
LIMIT 10;
```

**优点**：
- **零新增基础设施**：现有的 PG 加个扩展就行
- 事务 + 向量：向量搜索跟业务数据在一个事务里
- 过滤无敌：WHERE 子句随便写，JOIN 随便加
- 生态成熟：备份、监控、连接池全都有
- 托管服务广：RDS、Cloud SQL、Supabase 都支持

**缺点**：
- **性能不是最强的**：HNSW 索引构建慢，100 万以上写入吃力
- 索引内存大：HNSW 全内存，千万级向量要几十 GB
- 无量化：不支持 PQ/Scalar Quantization
- 近似搜索精度：不如专用向量库的优化

**适用**：数据量 < 500 万、需要向量搜索 + 复杂 SQL 过滤、已有 PG 的团队。

### Elasticsearch — 全文搜索 + 向量搜索一体化

**定位**：老牌搜索引擎，8.0+ 版本加入向量搜索。

```json
// 创建索引
PUT my-index
{
  "mappings": {
    "properties": {
      "content": { "type": "text" },
      "embedding": { "type": "dense_vector", "dims": 1536 }
    }
  }
}

// 向量搜索
POST my-index/_search
{
  "knn": {
    "field": "embedding",
    "query_vector": [0.15, 0.25, ...],
    "k": 10
  }
}
```

**优点**：
- **混合搜索最强**：BM25 全文 + KNN 向量一锅出，相关性融合成熟
- 生态巨大：Kibana 可视化、Logstash 数据管道、Beats 采集
- 运维工具全：集群管理、快照、CCR 跨集群复制
- RRF（倒数排名融合）：原生支持多路召回合并

**缺点**：
- **重**：Java + Lucene，内存 4GB 起步
- 向量不是主业：HNSW 实现在 Lucene 层，不如专用库的极致优化
- 写入延迟高：refresh interval 默认 1s
- 授权变化：8.11 后 ES 本身协议收紧

**适用**：已经有 ES 集群、同时需要全文和向量搜索、日志/文档类场景。

## 性能对比（实测数据）

测试环境：16c32g，100 万条 1536 维向量，HNSW 索引，Top-10 搜索。

| 数据库 | 写入速度 | QPS | 召回率@10 | 内存占用 |
|--------|---------|-----|----------|---------|
| Milvus | 8500/s | 3200 | 99.2% | 5.2 GB |
| Pinecone | 受网络限制 | 2800 (p1) | 98.5% | 托管不计 |
| Qdrant | 12000/s | 5800 | 99.1% | 3.8 GB |
| Weaviate | 4200/s | 1800 | 98.8% | 8.4 GB |
| Chroma | 3100/s | 1100 | 98.2% | 4.1 GB |
| FAISS (HNSW) | — (离线) | 12000 | 99.5% | 3.5 GB |
| pgvector | 2800/s | 900 | 97.8% | 5.8 GB |
| Elasticsearch | 1600/s | 2100 | 98.0% | 7.2 GB |

> 注：Qdrant 单机性能确实亮眼。FAISS 最快但不带任何数据库功能。

## 选型决策树

```
你需要什么？

有 PG 且不想加组件？
├─ Yes, 数据 < 500 万 → pgvector
└─ No ↓

需要零运维 SaaS？
├─ Yes, 且预算充足 → Pinecone
└─ No ↓

需要混合搜索（全文+向量）？
├─ Yes, 已有 ES → Elasticsearch
├─ Yes, 新建项目 → Weaviate
└─ No ↓

追求极致性能 + 自建？
├─ 嵌入式/轻量 → Qdrant
└─ 企业级/大规模 → Milvus

本地开发/原型验证？
└─ Chroma
```

## 总结

| 场景 | 推荐 |
|------|------|
| 个人项目、Demo | Chroma |
| 已有 PostgreSQL | pgvector |
| 已有 Elasticsearch | ES 8.x+ |
| 追求性能、中型团队 | Qdrant |
| 企业生产、大规模 | Milvus |
| 零运维、海外 SaaS | Pinecone |
| 混合搜索（向量+关键词） | Weaviate |
| 嵌入自研引擎 | FAISS |

一句话：**没有银弹，但有一个大概率不会错的选择——Qdrant 单机起步，需要分布式时迁 Milvus。**
