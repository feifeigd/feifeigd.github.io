---
title: "过滤条件吃掉向量检索的召回：post-filter、over-fetch 与原生过滤的实测对比"
date: 2026-11-19T18:00:00+08:00
draft: false
tags: ["ai", "rag", "embedding", "vector-database", "qdrant"]
categories: ["Tech"]
description: "ANN 索引是为无约束 top-k 设计的。一旦加上 tenant_id 或时间范围过滤，post-filter 的召回会在选择性跌破 k/M 时瞬间崩塌——而且延迟不变、不报错。用一份可跑的 IVF-FLAT 复现实验量化四种策略，给出阈值路由公式和一个最危险的失败模式：自适应探测的静默降质。"
---

线上最容易被忽视的一次召回事故是这样的：向量检索上线时 recall@10 测出来 0.94，跑得很好；半年后加了多租户，`WHERE tenant_id = ?`，压测延迟没变、错误率没变、P99 还在 20ms 内，于是没人再看质量。直到某天客服反馈"搜不到自己上传的文档"，才有人去查——真实召回只有 0.19。

这篇文章把这件事量化。所有数字来自一份可运行的 IVF-FLAT 复现实验（文中有完整代码），跑在本机 8 核上，100k 条 64 维、聚类结构的合成向量，IVF 的 `nprobe` 先标定到无过滤 recall@10 等于 0.953，然后再看加了过滤条件之后会发生什么。

{/* truncate */}

## 一、召回崩塌的临界点是一个除法

ANN 索引的目标函数是"在没有约束的全集里找最相近的 k 个"。过滤条件在语义上是另一个正交的约束，但大多数索引没法在检索时就利用它——只能先按向量找，找到之后再丢。

设过滤选择性为 p（允许集占全集的比），索引一次取 M 个候选再过滤，那么期望返回条数近似是 `M × p`。要凑够 k 条，需要 `M ≥ k / p`。p 等于 1 时 M 就等于 k；p 等于 0.01、k 等于 10 时，M 得给到 1000。

低于这个量级不是"少返回几条"，是**真值本身掉出了候选窗**：你取回的 200 个候选里如果只剩 2 条满足过滤，那 top-10 里有 8 个位置是空的，召回自然只有 0.2 左右。实验里 k=10、M=200 的临界点正好落在 p=0.05（10/200），实测 p=0.05 时平均只返回 8.73 条、recall 开始下滑，p=0.01 时直接掉到 0.186。理论和实测对得上。

## 二、四种策略的实测对比

实验设置：N=100,000，d=64，1024 个聚类中心加 0.11 噪声（模拟真实 embedding 的聚类结构），L2 归一化，NLIST=128，nprobe=24，100 条 query（取真实数据点加小扰动，保证有真邻居）。Ground truth 一律是**在允许集上**做精确暴力搜索得到的 top-10——这一点很关键，后面会作为踩坑单独说。

第一组：过滤条件与向量分布**无关**（随机抽取 p 比例的点，模拟按时间戳过滤、按随机 ID 过滤）。

| 选择性 p | post-200 recall | 平均返回条数 | over-fetch(1/p) recall | 扫描量 | IVF 固定 nprobe | IVF 自适应探测 |
|---|---|---|---|---|---|---|
| 1.0 | 1.000 | 10.0 | 1.000 | 10 | 0.953 | 0.953 |
| 0.5 | 1.000 | 10.0 | 0.905 | 20 | 0.948 | 0.948 |
| 0.2 | 1.000 | 10.0 | 0.894 | 50 | 0.921 | 0.921 |
| 0.05 | 0.873 | 8.73 | 0.854 | 200 | 0.812 | 0.812 |
| 0.01 | **0.186** | 1.86 | 0.839 | 1000 | 0.647 | 0.647 |
| 0.002 | **0.046** | 0.46 | 0.840 | 5000 | 0.494 | 0.494 |

第二组：过滤条件与向量分布**强相关**（允许集正好是若干完整聚类，模拟"按租户过滤而每个租户文档主题集中"）。

| 选择性 p | post-200 recall（命中率） | over-fetch(1/p) recall（返回条数） | IVF 固定 | IVF 自适应 |
|---|---|---|---|---|
| 0.501 | 1.000 | **0.491**（4.91 条） | 0.858 | 0.858 |
| 0.195 | 0.982 | **0.118**（1.25 条） | 0.769 | 0.769 |
| 0.049 | 0.435 | 0.428 | 0.632 | 0.632 |
| 0.0076 | 0.077 | 0.524 | 0.439 | 0.439 |
| 0.0018 | 0.012 | 0.422 | 0.364 | 0.464（扫 29 个 cell） |

四个可以直接拿来用的结论：

**1. post-filter 在 p 高于 k/M 时几乎无损，低于就断崖。** 这条阈值可以直接写进监控告警：把每次查询的 `允许集大小 / k` 和实际 over-fetch 倍数打点，比值不足 1 的查询比超过一个百分点就说明有租户在踩线。

**2. over-fetch 的 `1/p` 系数只在"被排除的点与查询邻域独立"时成立。** 第二组里 p=0.5 时 over-fetch 只取回 4.91 条、召回 0.491——不是凑不满，是**取回的 20 个候选里大部分属于被排除的聚类**。查询最近的那几个聚类恰好被过滤掉了，候选窗被"错误"的点占满。这时候系数不是 1/p，而是 1/(p × 邻域内允许密度)，可以用 1/p 的安全系数 3 到 5 起步，或者干脆走下面的原生过滤。

**3. 图/簇索引在低选择性下的退化是结构性的。** 固定 nprobe 从 0.953 掉到 0.494，因为真邻居集中在某几个 cell，而那些 cell 被过滤条件排空了，剩下的 cell 只是"碰巧有允许的点"。对 HNSW 而言这更糟：过滤会剪断图上的边，最近邻可能整条路径不可达——业界叫 needle in a haystack。ACORN（SIGMOD 2024）和 filtered-DiskANN（WWW 2023）就是专门做这件事的：前者做谓词无关的邻居扩展，后者在构图时就考虑过滤谓词的分布。

**4. 最危险的失败模式是"自适应探测"的静默降质。** 我给 IVF 加了一个 pgvector 0.8 迭代扫描式的逻辑：探测队列按距离顺序推进，凑够 k 条允许候选就提前停。结果延迟几乎不变（扫 24 到 29 个 cell），召回也没救回来（0.494）。也就是说这个策略在低选择性下**既不报错、也不变慢、也不返回空**，它只是安静地返回一批次优结果。线上没有任何指标能看出来，只有拿过滤后的 ground truth 去测才会暴露。这比直接超时难查一百倍。

## 三、复现实验的最小代码

下面是核心部分，跑一遍大约 40 秒，可以直接改常量复现上面的表。

````python
import numpy as np

RNG = np.random.default_rng(7)
N, D, K, NQ, NLIST = 100_000, 64, 10, 100, 128

# 聚类结构的合成 embedding（真实 embedding 空间也是聚的）
n_clusters = 1024
C0 = RNG.normal(size=(n_clusters, D))
C0 /= np.linalg.norm(C0, axis=1, keepdims=True)
cluster_of = RNG.integers(0, n_clusters, N)
X = C0[cluster_of] + 0.11 * RNG.normal(size=(N, D))
X /= np.linalg.norm(X, axis=1, keepdims=True)
X = X.astype(np.float32)

pts = RNG.choice(N, NQ, replace=False)
Q = X[pts] + 0.05 * RNG.normal(size=(NQ, D)).astype(np.float32)
Q /= np.linalg.norm(Q, axis=1, keepdims=True)

# 建 IVF：kmeans 8 轮足够
C = X[RNG.choice(N, NLIST, replace=False)].copy()
for _ in range(8):
    a = np.argmax(X @ C.T, axis=1)
    for j in range(NLIST):
        m = a == j
        if m.any():
            C[j] = X[m].mean(axis=0)
    C /= np.linalg.norm(C, axis=1, keepdims=True)
assign = np.argmax(X @ C.T, axis=1)
lists = [np.where(assign == j)[0] for j in range(NLIST)]
CELL_ORDER = np.argsort(-(C @ Q.T), axis=0)

def gt_topk(mask):
    """必须在允许集上算 ground truth"""
    idx = np.where(mask)[0]
    S = X[idx] @ Q.T
    return [set(idx[np.argpartition(-S[:, q], K)[:K]].tolist()) for q in range(NQ)]

def ivf(q, nprobe, mask=None, adaptive=False, cap_factor=8):
    got, cells = [], 0
    for j in CELL_ORDER[:, q][: nprobe if not adaptive else NLIST]:
        cells += 1
        cand = lists[j]
        if mask is not None:
            cand = cand[mask[cand]]
        if cand.size:
            got.append(cand)
        if adaptive and cells >= nprobe and sum(g.size for g in got) >= K:
            break          # 凑够就停：这就是静默降质的来源
        if adaptive and cells >= nprobe * cap_factor:
            break
    if not got:
        return set(), cells
    pool = np.concatenate(got)
    s = X[pool] @ Q[q]
    top = pool[np.argpartition(-s, min(K, pool.size) - 1)[: min(K, pool.size)]]
    return set(top.tolist()), cells

def run(mask, nprobe=24):
    gt = gt_topk(mask)
    res, cells = [], 0
    for q in range(NQ):
        r, c = ivf(q, nprobe, mask, adaptive=True)
        res.append(r); cells += c
    rec = sum(len(r & g) / K for r, g in zip(res, gt)) / NQ
    return round(rec, 3), round(cells / NQ, 1)

for s in (1.0, 0.5, 0.2, 0.05, 0.01, 0.002):
    mask = RNG.random(N) < s
    print(s, "recall@10 / cells:", run(mask))
````

## 四、工程上怎么选：按选择性路由

把上面的实验翻译成决策逻辑，就是一条基于选择性的路由。先估算 p，再决定走哪条路：

````python
from dataclasses import dataclass

@dataclass
class Route:
    mode: str          # "exact" | "iterative" | "overfetch"
    ef_search: int | None
    max_scan: int | None
    overfetch: int | None

K = 10
EXACT_MAX = 5_000      # 允许集小于这个数，暴力扫描就是最优解
ITER_START = 0.02      # 选择性低于 2% 走迭代扫描
DEFAULT_EF = 64

def plan(p: float, allowed_n: int) -> Route:
    if allowed_n <= EXACT_MAX:
        # 小于 5k 条允许集：精确扫描实测 0.15 到 0.35ms，比任何索引都快且无损
        return Route("exact", None, None, None)
    if p < ITER_START:
        # 低选择性：让索引继续扫，直到凑够 k 条（有上限，防止长尾拖垮 p99）
        ef = min(4096, max(256, int(DEFAULT_EF / p)))
        return Route("iterative", ef, max_scan=int(allowed_n * 0.4), overfetch=None)
    # 中高选择性：over-fetch 就够，系数按"邻域相关度"给 1 到 3 倍安全边际
    return Route("overfetch", DEFAULT_EF, None, overfetch=int(K / p * 2))
````

对应的 pgvector SQL（0.8 及以上才有迭代扫描）：

````sql
-- 低选择性：迭代索引扫描，扫不完就放弃顺序保证
SET LOCAL hnsw.iterative_scan = relaxed_order;
SET LOCAL hnsw.max_scan_tuples = 20000;
SET LOCAL hnsw.ef_search = 512;

SELECT id, content, embedding <=> $1 AS dist
FROM   docs
WHERE  tenant_id = $2
ORDER  BY embedding <=> $1
LIMIT  10;
````

`relaxed_order` 和 `strict_order` 的区别值得记住：前者允许"扫到上限就返回当前最好的"，p99 可控但结果顺序不严格；后者保证顺序但可能扫满上限。生产上按接口的 SLO 选，别默认用 strict 然后被 p99 打。

三个参数的实际含义：`ef_search` 决定**图遍历宽度**，`max_scan_tuples` 决定**最多扫多少行**，`iterative_scan` 决定**扫不够时要不要继续**。只调大 `ef_search` 是不够的——它加宽的是"每一跳看几个邻居"，而当允许集在某一片区域整体为空时，跳得再宽也是空的。

## 五、低于五千条时，索引本身就是负担

路由里 `EXACT_MAX = 5000` 不是拍脑袋。同一份实验里我顺手测了"允许集上直接精确打分"的耗时（单线程 numpy，100 维以下的 L2/IP）：

| 允许集大小 | 精确扫描/查询 | 召回 | 对比：IVF 扫 24 个 cell |
|---|---|---|---|
| 206 | 0.15 到 0.35 ms | 1.000 | 0.494 |
| 987 | 0.15 ms | 1.000 | 0.647 |
| 4,969 | 0.45 ms | 1.000 | 0.812 |
| 100,000 | 30 到 60 ms | 1.000 | 0.953 |

结论很直白：允许集在五千条以内，精确扫描比走索引**又快又准**，因为它既没有图遍历的固定开销，也没有任何召回损失。这也是为什么成熟引擎里都有这种内部启发式（Milvus 的 filter ratio 判断、pgvector 在 `WHERE` 选择性极高时优化器会直接选 seq scan），只是它们的阈值不对外暴露，你得自己测自己数据的拐点。

如果过滤条件本身还能预计算，把允许集维护成 Roaring Bitmap，查询时做位图交集再批量打分，是最省的一条路——一次 `AND` 是微秒级，比在 SQL 里对每一行求值划算得多。前提是过滤维度本身稳定（租户、状态位这类），时间范围这种连续量老老实实用 B-tree。

## 六、踩坑清单

**过滤字段没建索引是最常见的性能事故。** 向量库里的 metadata 过滤不是免费的：Qdrant 要对 `tenant_id` 建 payload index（并用 `is_tenant` 标记成租户键，走租户专用路径），Milvus 要建标量索引，pgvector 就是普通 B-tree 加对 `WHERE` 的选择性估算。没建索引时，过滤会退化成"先全取再逐条判断"，p=0.001 时等于每次扫全表。

**用租户当过滤维度会把索引切成碎片。** 十万条分给一千个租户，每个租户一百条——这种分布下无论什么 ANN 都退化成线性扫描，因为图/簇的邻域密度在每个租户里都太稀。正确做法是物理隔离：大租户一个 collection 或 partition，小租户共享一个池并接受偶尔的过滤扫描；三档阈值（大租户独立、中租户共享加过滤、极小租户走精确扫描）比单纯调 `ef_search` 有效得多。

**统计信息不准会让路由完全走错。** 上面 `plan()` 依赖 p 和 allowed_n，而优化器的估算经常差一个数量级（尤其是 `tenant_id` 分布倾斜的表）。稳妥做法是把允许集大小做成带 TTL 的计数缓存，或者用 `EXPLAIN` 验证一次实际行数，别直接信估算值。

**召回评估必须用过滤后的 ground truth。** 这是本文实验里我特意坚持的一点。多数团队的评测集是"全库检索 top-k"，一旦线上加了租户过滤，评测集和线上就不是同一个分布了——评测集里的真邻居可能根本不属于该租户。结果是评测分数漂亮、线上召回 0.19。评测脚本里那句 `WHERE` 加上去，分数会立刻塌下来，那个塌下来的数字才是真实质量。

**HNSW 的删除会让召回慢慢漂移。** 标记删除的节点留在图里当跳板，图结构逐渐"不诚实"，即使 `ef_search` 不变召回也会缓降。周期性重建（或 pgvector 的 `REINDEX`）应该进运维日历，不能等出问题再查。

**最后是诊断顺序。** 怀疑召回问题时按这个顺序查：先看允许集大小（是否低于 k/M 的临界线），再看返回条数是否等于 k，再看过滤字段有没有索引，最后才去调 `ef_search`。多数人反着来，先调参数，调了一周发现是选择性不够。

## 结语

一句话总结：**过滤不是给检索加条件，是给候选窗除一个数**。当 `允许集 / (k × over-fetch)` 小于 1 时，任何后置过滤都会崩；崩的方式有两种——明显的那种返回条数骤降，隐蔽的那种（自适应扫描）延迟平稳、结果次优。前者看监控能发现，后者只能靠带过滤条件的评测集发现。

代码和实验都在文里，改两个常量就能复现你自己集群的临界点。这个临界点值不值得写进告警，取决于你的租户分布有多倾斜——但至少，先算一次。
