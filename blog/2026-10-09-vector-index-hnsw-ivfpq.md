---
title: "向量索引内幕：HNSW 与 IVF-PQ 的召回、延迟、内存三方账本"
date: 2026-10-09T20:00:00+08:00
draft: false
tags: ["ai", "llm", "vector-database", "embedding", "performance", "engineering"]
categories: ["Tech"]
description: "向量检索的性能不是调出来的，是算出来的：HNSW 的 M/efConstruction/efSearch 各值多少召回、IVF-PQ 用多少内存换掉多少精度、过滤检索为什么会召回塌方、墓碑删除为什么不释放内存。附可运行的 hnswlib/FAISS 自测脚本与选型账本。"
---

向量检索上线后最常见的两类问题，一类是「延迟一高就加机器」，另一类是「召回不够就把 efSearch 往上调两倍」——两种都治不了根，因为向量索引不存在「更好的参数」，只存在**召回、延迟、内存三角里你愿意让出哪条边**。基础链路见 [RAG 全链路解析](/blog/2026/08/26/rag-interview)，召回与重排的工程取舍见 [RAG 进阶实战](/blog/2026/08/30/rag-advanced-retrieval)，这篇下沉一层，讲索引本身：HNSW 的图怎么长、IVF-PQ 的码本怎么省内存、过滤检索为什么会塌方、删除为什么永远不还内存。

{/* truncate */}

## 一、先算内存，再谈算法

任何向量检索选型都该从一行内存账开始，而不是从「大家都用 HNSW」开始。设维度 `d`、条数 `n`：

| 存储形态 | 单条开销 | d=768, n=1 亿 |
|---|---|---|
| FP32 原始向量 | `d × 4` = 3072 B | ≈ 286 GB |
| HNSW 图结构（M=16） | 约 `M×2×4` = 128 B | ≈ 13 GB |
| HNSW 图结构（M=32） | 约 256 B | ≈ 26 GB |
| PQ 压缩码（m=96，8bit） | 96 B + id 8 B | ≈ 10 GB |
| SQ8（int8 标量量化） | `d × 1` = 768 B | ≈ 77 GB |

结论直接摆在这：**1 亿条 768 维向量，纯 FP32 + HNSW 要 300 GB 内存，单机放不下**。所以规模化场景只有三条路——PQ/SQ 压缩、按业务维度分片、或者把原始向量放磁盘只把索引放内存。HNSW 的图开销相对向量本身其实很小（约 4%），真正吃内存的永远是向量本体。

顺带一个常被忽略的数：**HNSW 的图开销与维度无关，只与 M 有关**。M 从 16 拉到 32，召回涨几个点，内存翻倍——这笔账在小规模数据上无所谓，在上亿条上就是几十 GB。

## 二、HNSW：一张有层次的跳表图

HNSW 的本质是「跳表思想 + 近邻图」：上层稀疏做高速导航，下层稠密做精确定位。

```text
layer 2        ●────────●                    ← 入口点，最稀疏
layer 1     ●──●────●────●──●
layer 0  ●─●─●─●─●─●─●─●─●─●─●              ← 全量节点，最密

查询：从 layer 2 贪心下降 → 逐层逼近 → layer 0 用 ef 宽的候选堆收敛
```

三个参数各自的职责要分清，这是最常被混淆的地方：

- **M**（每层出边上限）：决定图的连通度 → 影响**召回上限**和内存。太低（M=8）图会断，贪心走进死胡同；常用 16~48。
- **efConstruction**：建索引时的候选池宽度 → 影响**建索引耗时**和图质量。200 是常见起点，拉到 500 收益开始饱和，建索引时间近似线性涨。
- **efSearch**：查询时的候选池宽度 → 影响**延迟与召回**，且是**唯一能在线上实时调的**。

关键性质：`efSearch >= k`，且 efSearch 调大时召回**单调不降但有饱和点**，延迟近似线性上升。所以调参动作永远是「找到召回拐点，然后停在拐点前一点」，而不是无脑拉满。

下面这段可直接跑，自带暴力基线对照，输出召回/延迟曲线：

```python
# hnsw_sweep.py —— 用暴力检索做 ground truth，扫 efSearch 曲线
import time
import numpy as np
import hnswlib

rng = np.random.default_rng(42)
d, n, nq, k = 768, 200_000, 2_000, 10

xb = rng.standard_normal((n, d), dtype=np.float32)
xq = rng.standard_normal((nq, d), dtype=np.float32)
# cosine 空间必须先归一化，否则内积 != 余弦
xb /= np.linalg.norm(xb, axis=1, keepdims=True)
xq /= np.linalg.norm(xq, axis=1, keepdims=True)

# ground truth：全量精确检索
t0 = time.perf_counter()
gt = np.argsort(-(xq @ xb.T), axis=1)[:, :k]
print(f"brute force: {(time.perf_counter() - t0):.2f}s for {nq} queries")

idx = hnswlib.Index(space="cosine", dim=d)
idx.init_index(max_elements=n, ef_construction=200, M=16)
t0 = time.perf_counter()
idx.add_items(xb, np.arange(n), num_threads=8)
print(f"build: {(time.perf_counter() - t0):.2f}s")

def recall_at_k(pred, truth):
    return np.mean([len(set(p) & set(t)) / k for p, t in zip(pred, truth)])

for ef in (16, 32, 64, 128, 256):
    idx.set_ef(ef)                       # ef 是查询期参数，可热改
    t0 = time.perf_counter()
    labels, _ = idx.knn_query(xq, k=k, num_threads=8)
    dt = time.perf_counter() - t0
    print(f"ef={ef:4d}  recall@10={recall_at_k(labels, gt):.3f}  "
          f"qps={nq / dt:8.0f}  p50-latency≈{dt / nq * 1e6:.0f}us")
```

公开基准（ANN-Benchmarks 的 SIFT1M、FAISS 官方实验）上常见的量级是：M=16 / efConstruction=200 配 efSearch≈64~128 时，recall@10 落在 0.95 附近，QPS 在万级。**这些数字只用来建立直觉**——中文语料、你的模型、你的数据分布会让曲线整体平移，必须用上面的脚本在自己数据上重测一遍再定参数。

## 三、IVF-PQ：用 30 倍压缩换 20 个点召回

IVF-PQ 是两种技术叠加：

1. **IVF（倒排文件）**：用 k-means 把空间切成 `nlist` 个簇，查询时只扫 `nprobe` 个最近的簇 → 省**计算**，不减内存。
2. **PQ（乘积量化）**：把 `d` 维切成 `m` 段，每段独立训一个 256 质心的码本，每段只存 1 字节的簇号 → 省**内存**，代价是精度。

省内存的效果是实打实的：d=768、m=96 时单条 96 字节，相对 FP32 的 3072 字节是 **32 倍压缩**。代价是 PQ 的量化误差不可逆——它压根不保留原始向量，距离是查表近似出来的。

```python
# ivfpq_build.py —— FAISS IVF-PQ 建索引 + nprobe 扫描
import faiss
import numpy as np

d, nlist, m, nbits = 768, 4096, 96, 8
assert d % m == 0, "PQ 要求维度能被 m 整除"

rng = np.random.default_rng(0)
xb = rng.standard_normal((2_000_000, d), dtype=np.float32)
xb /= np.linalg.norm(xb, axis=1, keepdims=True)
xq = xb[:500].copy()

# 归一化 + 内积 = 余弦；用 L2 就得自己保证归一化等价性
quantizer = faiss.IndexFlatIP(d)
index = faiss.IndexIVFPQ(quantizer, d, nlist, m, nbits)

# 训练样本必须充足，否则 k-means 质心质量差，FAISS 会告警
# 经验下限：nlist 个簇至少要有 39×256 个训练点兜底
assert len(xb[:200_000]) >= 39 * 256
index.train(xb[:200_000])
index.add(xb)

for nprobe in (4, 16, 64, 256):
    index.nprobe = nprobe
    D, I = index.search(xq, 10)
    # 生产上要拿暴力结果算 recall@10，而不是靠直觉
    print(f"nprobe={nprobe:4d}  top1_dist={D[0][0]:.4f}")
```

**踩坑清单（这几条都是实际炸过的）**：

- **训练样本不足 → 静默降级**。FAISS 只会打印 `WARNING clustering ... points to ... centroids`，索引照样能建，但召回会莫名低十几个点。IVF-PQ 的训练集建议不少于 10 万条，且必须是真实分布，别拿随机数训。
- **`nprobe` 是这个索引里最危险的参数**。给太低（nprobe=1）时只扫 1/4096 的空间，召回塌到 0.3 以下都不奇怪；它和 HNSW 的 efSearch 一样是「召回拐点」型参数，必须扫曲线。
- **PQ 只适合「粗排」**。工程上的正确分层是：IVF-PQ 出 100~500 个候选 → 有原始向量的话再用 FP32 精排（re-rank）→ cross-encoder 重排。直接拿 PQ 的距离当最终相关性打分，是很多召回质量事故的根因。
- **同一条数据用不同 embedding 模型是不兼容的**。维度一样也不能混，向量空间完全不同，查出来的是「碰巧近」。

## 四、过滤检索：ANN 索引最大的坑

这是纯 ANN 索引（HNSW/IVF）线上翻车最集中的地方，也是「向量数据库」和「向量索引库」的分水岭。

需求很常见：只检索某租户、某时间段、`status=published` 的文档。朴素做法有两种，都有问题：

- **post-filter（先检索后过滤）**：`knn_query(k=10)` 再过滤 → 命中数远低于 10，因为索引在**全局空间**里挑的 10 个邻居可能全部被过滤掉。想补回来只能把 k 放大到几百再过滤，延迟涨、还不保证够。
- **pre-filter（先过滤后检索）**：把满足条件的子集交给索引搜 → 如果过滤后只剩几千条，HNSW 的图结构被破坏（原本的邻居可能都不在子集里），贪心搜索退化成随机游走，召回同样崩。

正确解法按优先级：

1. **把过滤维度做成物理分区**。多租户场景就按 tenant 分索引/分 collection，查询只打自己那一份——这是唯一不损失召回的做法，代价是索引数量上升、跨租户查询要做归并。
2. **用支持过滤的索引实现**。FAISS 走 `IDSelector`，HNSW 系有 filtered-DiskANN、ACORN 这类把过滤下推到图遍历里的算法（关键点：允许跨越不满足过滤条件的节点继续导航，只把满足条件的节点收进结果集）。
3. **over-fetch + 重排**兜底：`k=200` 取回后过滤，取满 `k` 条；同时在监控里盯 `实际命中数 / 请求数`，这个比值掉下来就是召回在无声劣化。

```python
# filtered_search.py —— FAISS IDSelector 演示（第 2 条路线的 API 形态）
import faiss
import numpy as np

index = faiss.read_index("ivfpq.index")     # 已 add 过
allowed = np.array([1, 5, 9, 42, 10086], dtype=np.int64)

sel = faiss.IDSelectorBatch(allowed)        # 只在这些 id 里搜
params = faiss.SearchParametersIVF(sel=sel, nprobe=64)
D, I = index.search(xq[:1], k=5, params=params)
print(I)                                    # 返回的一定是 allowed 的子集
```

跨租户共用一个索引时，无论用上面哪种办法，**都要把「过滤后候选不足」当成一个需要告警的线上事件**，而不是一个静默返回空列表的边界情况。

## 五、删除与更新：墓碑、内存不还、重建窗口

- **HNSW 的删除是标记（tombstone），不是摘除节点。** `hnswlib` 的 `mark_deleted(label)` 只是把节点标记为不可见，图结构不动、内存不释放。大量删除后，搜索会在「死节点」上浪费候选预算，召回和延迟同时劣化。实践阈值：删除量超过总条数的 10~20%，就该考虑重建索引（`init_index` 重来，或者在新索引上增量补齐后原子切换别名）。
- **IVF-PQ 删了也不好受**：FAISS 的 `IndexIVFPQ` 用 `remove_ids` 移除后倒排链会留下空洞，长期只增不减的日志型数据必然需要周期性重建。
- **更新 = 删 + 加**，别指望 in-place 改向量。HNSW 里改一条向量等于改了所有邻居的边，代价接近重建一小片图。
- **冷启动延迟**：用 mmap 或者从磁盘加载的索引，首次查询会触发大量缺页，P99 会有个尖刺。上线前做一次预热查询（把入口点所在的上层节点和常用簇先拉进 page cache），别把第一波真实流量当预热。

## 六、选型账本

| 场景 | 推荐 | 理由 |
|---|---|---|
| 千万级以内、内存充足、要低延迟 | HNSW / FP32 | 召回最高，调参空间大，M=16~32 起步 |
| 上亿条、内存是瓶颈 | IVF-PQ（+ 精排） | 压缩 30 倍，用两级检索把精度补回来 |
| 强过滤（多租户/时间范围） | 物理分区 + 分区内 HNSW | 唯一不损失召回的做法 |
| 增删频繁 | 日志型数据配定期重建 + 别名切换 | 墓碑累积是慢性病 |
| 召回要求极致、QPS 要求不高 | 暴力 Flat（或 DiskANN 上盘） | 别为了 ANN 丢掉 1.0 的召回 |

一句话总结这篇的立场：**向量检索的性能是算出来的，不是调出来的**。先把内存账算清楚，再决定用哪种索引；确定了索引，再用召回拐点定参数；有了过滤需求，先问能不能做物理分区。顺序反过来——先选 HNSW 再想办法瘦身——通常就是推倒重来的开始。
