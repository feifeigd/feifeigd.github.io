---
title: "面试题：推理服务的 KV cache 到底该怎么管？为什么按最大长度预留显存会浪费 83%、block 表怎么把逻辑 token 和物理页解耦、prefix cache 的哈希少了父节点为什么会 100% 误命中、抢占该重算还是换出、以及 decode 水位为什么必须按秒算而不是按百分比？"
date: 2026-11-24T09:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "interview"]
categories: ["Interview"]
description: "推理服务 KV cache 管理题，不画架构图，只算账。三种分配策略的实测对比：按 8192 最大长度预留，7.6GiB 只能装 7 路、浪费 82.8%，分页分配能装 50 路、浪费 1.35%，差 7 倍并发。block 大小从 4 扫到 256（浪费从 0.116% 到 9.95%，块表从 648 万条到 111 万条），答案是 16。prefix cache 在 200 个 system prompt 的负载上命中 82.21%、省掉 81.84% 的 prefill token；但 32 位哈希在 100 万个 block 上撞 114 次，而少了父哈希的链式 key 在 59,988 次命中里 100% 是误命中——这类 bug 不报错，只输出错答案。抢占的账：重算与换出的盈亏平衡带宽是 6.55GB/s，短前缀下换出在纯成本上赢 4 倍，但到 128k 上下文重算要 31 秒、换出 1.37 秒，差 23 倍。最后是 decode 水位：43 路并发下 KV 以 268.8MiB/s 增长，10% 的余量只够烧 2.9 秒；过载 9% 时三种防线分别退化成 7.7% 请求被中止、p99 从 40.9 秒涨到 112.7 秒且白干 170 倍 prefill、以及吞吐掉到 38%（六个随机种子的均值）。"
---

> 这是「每日一题」专栏的第三十篇。上一篇是 [十亿级搜索自动补全怎么设计](/blog/2026/11/19/typeahead-autocomplete-system-interview)，文末预告的正是这一题（AI → 后端 → 系统设计 轮换，今天回到 AI/LLM 方向）。
>
> 这道题最容易被答成背论文：「用 PagedAttention，块大小 16，能省 60% 到 80% 的碎片」。面试官接着问「为什么是 16 不是 8」「prefix cache 的 key 里放什么」「抢占的时候重算还是换出」，三问就到底了。
>
> 今天不背结论。今天把每一个数字算出来，包括那些让人不舒服的：swap 在纯成本上其实比重算便宜，pause 一下就知道为什么生产系统还是默认重算；以及为什么「预留最大长度」这个看起来保守的做法，实际把并发从 50 路砍到 7 路。
>
> 先说清数字来源：① 纯 Python 的分配、哈希与排队模拟器（文末完整可复现，单核 4 分钟，无第三方依赖）；② 解析模型（FLOPs、字节数、带宽）。**没有 GPU 实测**——凡是依赖硬件假设的地方（35% MFU、PCIe 25GB/s、HBM 时钟），我在表里明确标了出来，你换成自己机器的数字重算即可，结论的形状不会变。

{/* truncate */}

## 一、先把需求压成数字

面试第一句别说架构，先说这台机器上有多少 token 可以花。

**单位成本。** 7B 级模型（32 层、GQA-8、head_dim 128、fp16）：

```
每 token KV = 32 层 × 8 个 KV head × 128 维 × 2（K 和 V）× 2 字节 = 131,072 B = 128 KiB
```

32k 上下文 = 4 GiB，128k = 16 GiB。**这是单个请求的账**，不是全机的账。

**显存预算。** 24GB 卡，权重 14 GiB（fp16），利用率 0.9：

```
KV 可用 = 24 × 0.9 − 14 = 7.6 GiB → 7.6GiB / 128KiB = 62,259 token
80GB 卡 = (80 × 0.9 − 14) / 128KiB = 475,136 token
```

**负载形状。** 2 万条请求，prompt 中位数 600、输出中位数 250（对数正态，σ 分别 0.9 和 1.0）：

| 指标 | 值 |
| --- | --- |
| 平均总长 | 1,294.9 token（prompt 904.8 + 输出 390.2）|
| p50 / p90 / p99 / max | 998 / 2,476 / 5,618 / 17,801 |

注意 p50 是 998，而 `max_model_len` 往往配成 8192：**99% 的请求用不到 5,618，最长的那 1% 却决定了你怎么分配显存。** 这就是整道题的引信。

**延迟 SLO。** TTFT p99 1s，ITL p99 50ms。一条 390 token 的回答，纯 decode 时间就是 390 × 20ms ≈ 7.8s（下文模拟器用一步 20ms）。

**吞吐。** 单卡峰值 6 QPS，6 × 390 ≈ 2,340 输出 token/s——这正好是 7B 在一张 H100 上跑 decode 的量级，所以下面的模拟是有意义的，不是随便取的数。

## 二、PagedAttention：预留到底浪费在哪

最朴素的做法是「每个请求按最大长度预留一块连续显存」。听着保守，实测一下：

| 策略 | 能装几路 | 有用 token | 占用 token | 浪费 | 显存利用率 |
| --- | --- | --- | --- | --- | --- |
| 按 8192 预留 | **7** | 9,865 | 57,344 | **82.8%** | 15.9% |
| 按实际长度预留（上帝视角） | 51 | 62,031 | 62,031 | 0% | 99.6% |
| 分页分配，block=16 | **50** | 59,915 | 60,736 | **1.35%** | 96.2% |

三个数字，三句话：

1. **预留最大长度 = 并发 7 路。** 7.6GiB 里只有 9,865 个 token 是真的在被使用，其余 47,479 个 token 的显存正躺在那儿等一个「万一用户输入很长」的可能。82.8% 的显存是沉默成本。
2. **「按实际长度预留」是好，但它需要上帝视角。** 你得在请求进来时就知道它会生成多少个 token——这个信息不存在（谁先停机谁说了算）。
3. **分页分配不需要预知未来。** 用多少块拿多少块，浪费只剩「每条序列最后一块的空位」，平均半块 = 8 个 token，占 1,294 个 token 的 0.6%，实测 1.35%。

**7 路和 50 路，是 7 倍并发。** 这就是 PagedAttention 的全部价值——它不是让 KV 变小，而是让「已分配的显存里有多少在干活」从 16% 变成 96%。

### block 表：一次解耦，三个副作用

分页之后，每条序列的逻辑 token 位置和显存里的物理块不再一一对应，中间靠一张 `block_table`：

```
逻辑块 0 → 物理块 4711
逻辑块 1 → 物理块 83
逻辑块 2 → 物理块 9021
```

这张表很便宜：block=16 时平均每条请求 81.4 个块，2 万条请求 163 万个表项，每项 8 字节 = 13 MB。物理块总共只有 60,736 / 16 = 3,796 个，也能算清。

**这张表本身是次要的，它带来的三个能力才是重点：**

- **物理上不需要连续。** 序列可以一段长在显存低地址、一段长在高地址，于是「剩余显存」从「要找到一块连续的 8192 token 空档」变成「只要有 16 个 token 的空块」。碎片问题从外部碎片（重）变成内部碎片（轻，1.35%）。
- **共享变成改指针。** 同一条 prompt 的 50 个候选回答，逻辑块表不同、物理块相同，只读共享，写时才复制（copy-on-write）。并行采样（n 大于 1）时显存不乘 n，只乘「分叉之后的部分」。
- **驱逐变成按块回收。** prefix cache 要淘汰旧内容时，回收粒度是块，不用重排整块连续内存。这一条直接决定了第四节的实现难度。

## 三、block 大小：16 是怎么来的

block 越小，内部碎片越小；但块表条目数（以及每次 attention 要 gather 的段数）随块变小而线性变多。实测扫描：

| block | 浪费 | 每条请求块数 | 2 万请求总块数 |
| --- | --- | --- | --- |
| 4 | 0.116% | 324.1 | 648 万 |
| 8 | 0.270% | 162.3 | 325 万 |
| **16** | **0.575%** | **81.4** | **163 万** |
| 32 | 1.191% | 41.0 | 81.9 万 |
| 64 | 2.427% | 20.7 | 41.5 万 |
| 128 | 4.925% | 10.6 | 21.2 万 |
| 256 | 9.950% | 5.6 | 11.1 万 |

读这张表要看的是**边际收益**：从 32 降到 16，浪费从 1.19% 降到 0.58%，省 0.6 个百分点；从 16 降到 8，只省 0.3 个百分点；从 8 降到 4，省 0.15。而块表条目翻倍、翻四倍。

反方向：从 16 加到 64，浪费从 0.58% 涨到 2.43%，多花 1.85 个百分点的显存，换回来的是块表小 4 倍。

**结论不是「16 最优」这么简单，而是：当序列平均长度在 1,000 token 量级时，16 恰好落在「浪费已经无害（0.6%）、块表还很小（13 MB）」的拐点上。** 换个负载结论会变：如果你的业务全是 100 token 的短问答，16 就太粗了（浪费 8%），要么降到 8，要么按块大小分池。这个回答比背论文强得多。

还有一个常在面试里被追问的点：**block 太小时 attention kernel 变慢**。它要按块表 gather 出 K/V，块越小段数越多、访存越碎。这条我没有 GPU 无法给数字，但它和上面的浪费曲线方向相反，所以 16 是两条曲线的交点——这句话说出来，面试官知道你不是只看了论文第一页。

## 四、prefix cache：命中率、哈希、以及那个不报错的 bug

前缀缓存是推理服务里性价比最高的一件事：200 个共享 system prompt（各 1,500 token）+ 每条请求 300 token 的独有内容，2 万条请求：

| 指标 | 值 |
| --- | --- |
| 请求的块总数 | 2,240,000 |
| 去重后的块数 | 398,600 |
| 块命中率 | **82.21%** |
| 省掉的 prefill token | 29,462,400（占全量 3,600 万的 **81.84%**）|

**八成以上的 prefill 计算是重复的。** 这也解释了为什么线上 prefix 命中率从 60% 掉到 30% 时，TTFT 会立刻恶化——不是模型变慢，是你开始重算了。

### 哈希必须带父节点，否则 100% 误命中

实现上，块的 key 有两种写法：

**错的写法：** `key = hash(这 16 个 token)`。

**对的写法：** `key = hash(父块的 key, 这 16 个 token)`。

差别看起来只有一行，实测（5,000 条请求，每条是「独有的 1,000 token 文档 + 完全相同的 200 token 模板」）：

| 写法 | 命中次数 | 其中误命中 | 误命中率 |
| --- | --- | --- | --- |
| 只哈希块内容 | 59,988 | **59,988** | **100%** |
| 哈希（父 key, 块内容） | 0 | 0 | 0% |

不带父链时，那 12 个模板块在每一条请求里都被判成「见过」，于是第二条请求开始，attention 直接去读第一条请求的文档末尾的 KV——**内容完全对不上，但系统不会报错，只是安静地输出错答案**。这是 prefix cache 最危险的一类 bug：没有异常、没有 5xx、只有用户投诉「今天答得不对劲」。

带父链之后，模板块虽然内容相同、父哈希不同，正确地判成不命中。**代价是共享率下降**（本可以共享的块被拒绝），**换来的是永远不会错**。这个取舍在工程上从来没有第二种选择。

### 32 位哈希不够用

100 万个 block，两种位宽：

| 位宽 | 碰撞数 | 理论期望 |
| --- | --- | --- |
| 64 位 | **0** | 0.00003 |
| 32 位 | **114** | 116.4 |

32 位在 100 万块的规模上必撞，而且碰撞意味着「两个不同前缀被判成同一个块」——又一次静默的错答案。64 位在 1 亿块量级仍然安全（期望 0.27 次）。这就是为什么所有正经实现都用 64 位整数 key：**不是性能考虑，是正确性考虑**。

### key 里除了 token 还必须放什么

这是最容易被追问穿的一层。至少这五个字段，缺一个就是一种线上事故：

- **模型标识 + 版本**。同机多模型、热更新权重时，旧块不能给新权重用。
- **tokenizer / chat template 版本**。模板一改，同样的对话历史 tokenize 出来的序列就变了，但块哈希看起来可能「合理」。
- **LoRA id 与权重版本**。多租户微调场景下，基座相同、适配器不同，KV 完全不同。
- **多模态输入的 hash**。图像/音频编码结果变了，文本 token 却没变。
- **采样参数里影响 KV 的部分**。温度不影响 KV，但张量并行度（TP）会——TP=2 和 TP=4 的 KV 分片方式不同，块不能跨配置复用。

**一句话：key 必须唯一确定「这段 KV 是哪份权重、在什么配置下、对哪段输入算出来的」。** 少一个字段，就是一次无法复现的错误。

## 五、抢占：重算还是换出

显存满了，要么把某条序列的 KV 扔掉等会儿重算（recompute），要么挪到 CPU 内存再挪回来（swap）。直觉上「短前缀重算、长前缀换出」，但先算账。

重算成本 ≈ 2 × 参数量 × token 数（前馈部分）+ 二次项（注意力部分：每层 QK^T 和 AV 各 2·L²·d·H）。换出成本 = 2 × L × 128KiB（去一趟再回来）。

**重算按 35% MFU（350 TFLOPS），换出按三种链路带宽：**

| 前缀长度 | 重算（350T） | 换出（PCIe 25GB/s） | 换出（55GB/s） | 换出（NVLink 900GB/s） |
| --- | --- | --- | --- | --- |
| 512 | 20.9ms | 5.4ms | 2.4ms | 0.1ms |
| 2,048 | 88.2ms | 21.5ms | 9.8ms | 0.6ms |
| 4,096 | 189.0ms | 42.9ms | 19.5ms | 1.2ms |
| 8,192 | 428.2ms | 85.9ms | 39.0ms | 2.4ms |
| 32,768 | 2,919ms | 343.6ms | 156.2ms | 9.5ms |
| 131,072 | **30,978ms** | 1,374ms | 625ms | 38.2ms |

先看短前缀那几行：**换出在纯成本上一直比重算便宜约 4 倍**，而且这个比例与长度无关。把两个公式相除就得到盈亏平衡带宽：

```
PT × F_eff / P = 131,072 B × 350e12 / 7e9 ≈ 6.55 GB/s
```

**只要你的换出带宽超过 6.55 GB/s，换出就比重算便宜。** 任何 PCIe 3.0 以上的链路都满足，所以「短前缀应该重算」这条经验法则，在成本模型里站不住。

那为什么生产系统（比如 vLLM 的 V1 引擎）反而把 swap 删掉了、只留重算？三条工程原因，比成本表更重要：

1. **重算偷的是算力，换出抢的是带宽，而两者对别人的伤害不同。** decode 阶段 GPU 算力大量闲置（按本文 20ms 一步算，43 路 decode 只用到 30 TFLOPS，是 H100 fp16 峰值的 3%），重算可以塞进空闲的 SM 里，同时只影响「这条序列自己」的 TTFT；换出占的是 PCIe 和 pinned 内存，一条序列换出时，同时刻所有在换的序列一起排队，p99 抖动不可控。
2. **pinned 内存的账单很硬。** 最坏情况要按整个 KV 预算准备 host 侧内存，7.6GiB 一台卡、8 卡机就是 60GiB，还要 page-locked（不可换页）。
3. **换出的粒度是块，但成本是 token。** 4k token = 250 个块，每次 DMA 的固定开销几百微秒，250 次乘上去就是几十毫秒的额外损耗，把 4 倍优势吃掉一部分。

所以正确的答法是两段：**先算清 6.55 GB/s 这个盈亏点，再说清为什么工程上仍然默认重算，最后指出真正的分水岭在长上下文**——第 6 行，128k 时重算 31 秒、换出 1.37 秒，差 23 倍，因为重算里注意力二次项占了 83%。**长上下文抢占必须换出，短上下文重算更简单；这个结论是对的，但理由不是「长度」，是二次项。**

### 抢占风暴：64 条一起被抢

如果同一时刻 64 条 4k 前缀的序列被抢占：

```
换出量 = 64 × 2 × 4,096 × 128KiB = 64 GiB → PCIe 25GB/s 需要 2.75 秒
重算量 = 64 × 189ms = 12.09 秒（即使按批处理算，也是十秒级）
```

两个数字都很难看，但性质不同：**换出的 2.75 秒是纯带宽占用，可以后台慢慢做、期间序列挂着；重算的 12 秒是 front-of-queue 的同步阻塞，期间所有 decode 的 ITL 都被拉长。** 所以抢占的正解不是「选重算还是换出」，是**别让它发生**——这引出第六节。

## 六、水位：按秒算，不按百分比算

先算增长速率。43 路并发、每路 50 token/s、每 token 128KiB：

```
增长 = 43 × 50 × 128KiB = 268.8 MiB/s
```

7.6GiB 的 10% 余量是 778MiB，**只够烧 2.9 秒**。也就是说，如果你把「水位到 90% 就报警」写进配置，报警响起到真正 OOM 之间只有 2.9 秒——而一次调度决策的周期就是几十毫秒到几秒。**百分比水位在 decode 阶段几乎没有预警价值，必须换算成秒，再和你的调度周期比。**

### 过载 10% 时，三种防线各自怎么烂

模拟器：Poisson 到达，λ=6/s（10 分钟 3,600 条请求，需求 2,340 token/s，比这台机器的稳态吞吐 2,150 token/s 高约 9%），一步 20ms，容量 62,259 token。**下表每个数字是 6 个随机种子的均值**——单次运行的 p99 标准差有 10% 到 25%，拿一次运行下结论会被随机性打脸（我第一版就是单种子，结论直接反了）。

| 策略 | 完成 | 中止 | 抢占次数 | 重算/生成 | 平均并发 | p50 | p99 | 吞吐 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 不设防线 | 3,258 | **276（7.7%）** | 0 | — | 42.6 | 5.0s | 40.9s | 2,135 |
| 只靠抢占（92/88） | 2,936 | 0 | **18,345** | **170×** | 38.6 | 46.8s | 112.7s | 1,937 |
| 只靠抢占（97/93） | 3,070 | 0 | 15,068 | 112× | 40.4 | 38.9s | 95.8s | 2,025 |
| 准入预留 512 | 2,261 | 0 | 577 | 6.6× | 29.5 | 110.7s | 218.6s | 1,481 |
| 准入预留 1,024 | 1,755 | 0 | 358 | 5.5× | 22.8 | 151.9s | 300.9s | 1,145 |
| 准入预留 2,048 | 1,224 | 0 | 171 | 3.7× | 16.0 | 187.2s | 387.7s | 803 |

这张表是整篇文章最值得背下来的部分，因为它给出了三种**完全不同**的降级形态：

1. **不设防线 → 打掉请求。** 7.7% 的请求被中止，但活下来的体验最好（p50 5.0s、p99 40.9s，几乎没有排队）。这是「牺牲一小部分保大部分」——而且注意它的吞吐反而是最高的，因为中止掉了就不再占显存。
2. **只靠抢占 → 抖动。** 零中止，但抢占 18,345 次、重算的 prefill 量是实际生成量的 170 倍，p99 从 40.9s 涨到 112.7s。序列被抢、重排、再抢，每抢一次都要把更长的前缀重算一遍，于是越抢越久。**抢占不是免费的保护，它把 OOM 换成了抖动和算力空转。** 水位从 92% 抬到 97% 之后，换个说法是「少抢几次、每次多腾一点」，各项指标都好一档（15,068 次、112 倍、p99 95.8s），但量级没变——抢占是兜底手段，不能当容量管理用。
3. **只靠准入 → 吞吐崩塌。** 零中止、零抖动，但按 `max_tokens` 预留把并发从 43 路压到 16 路，吞吐从 2,135 掉到 803 token/s，只剩基线的 38%。**用 2.7 倍的容量换 0 错误，代价太高。**

**正确的组合是「按分位数预留 + 高水位抢占兜底」**：预留量取输出长度的 p95（本例约 800，而不是 max 的 2,048），把并发损失控制在 10% 到 20%；水位设在 97%，只在极端时刻抢占；再叠加客户端侧的超时与重试上限。这三件事缺一件，前面五节的所有优化都会被排队抵消。

补两组对照。λ=8（需求超容量 60%）时，不设防线的中止率从 7.7% 涨到 19%，说明「打掉请求」这个策略在压力上升时会迅速变成灾难。λ=4（需求 1,560 token/s，低于容量）时，抢占策略只抢了 2,327 次、重算 24 倍、完成 2,352 / 2,400、p99 40.9s。**同一套策略，不饱和时优雅，饱和 9% 就崩**——所以面试里一定要问清楚「这个系统的设计负载上限是多少」，答案里带上这个数，说明你知道 KV 管理的本质是排队系统。

## 七、追问清单

**追问一：为什么不把 `max_model_len` 直接调小？**
因为 p99 是 5,618、max 是 17,801。调到 8192 会让 1% 的长请求直接失败，而长文档恰好是高价值请求。正确做法是「长度分池」：常规池 8k、长文池 64k（并发低、按需扩），而不是全员降配。

**追问二：GQA / MLA 能把这 128KiB 降到多少？**
上面这个 128KiB 就是 GQA-8（32 个 Q head 共享 8 个 KV head）；换成 MQA（1 个 KV head）是 16KiB，容量直接翻 8 倍；介于两者之间的 GQA-4 是 64KiB。KV head 越少，容量按比例翻，质量损失通常在 0.5% 以内——但这个数必须用自己的评测集验，别信别人的。MLA 把 K/V 压到低秩潜向量，DeepSeek 官方报告的是 KV cache 降低 93% 这类量级，代价是 attention kernel 更复杂、prefix cache 的块语义也变了（缓存的是 latent，不是 K/V）。**选型时先看 KV 配置再看参数量**，这是 2026 年的常识。

**追问三：FP8 KV 值得开吗？**
128KiB 降到 64KiB，容量翻倍，代价是精度。经验是 K 的 outlier 通道比 V 敏感，长上下文时尤其明显，所以要么 per-channel 量化 K、要么只量 V。面试里说清「省的是显存、赌的是长文质量」，再给一个验证方法：拿自己的长文评测集对比 FP8 与 fp16 的答案一致率。

**追问四：prefix cache 怎么淘汰？**
按块的引用计数 + LRU：被共享的块 ref_count 大于 1，不能淘汰；ref_count 归零后进 LRU 队列，按时间淘汰。注意两个坑：驱逐粒度是块，所以一条序列的中间块被淘汰后，它后面的块全部失效（父链断裂）——这要求淘汰必须从尾部往前；多实例共享前缀时，还要处理跨实例的版本一致性。

**追问五：chunked prefill 和 KV 水位什么关系？**
chunk 大小决定了一步里能塞多少 prefill token，也就决定了 KV 的增长速率上限。chunk 调大 → 单步 KV 增长快、TTFT 好、但水位更容易打穿；chunk 调小 → 平滑，但长 prompt 的 TTFT 变差。**这两个参数必须一起调**，单独调任何一个都会在压力下翻车（这一条我在[上一篇 batching 调参](/blog/2026/11/18/continuous-batching-chunked-prefill-scheduler-tuning)里用实测数字讲过）。

**追问六：怎么衡量这套系统做得好不好？**
五个指标，缺一个就会误判：**KV 利用率**（已用/预算，健康值 85% 到 95%）、**抢占率**（每秒抢占次数，超过 1 次就要看是不是负载超限）、**prefix 命中率**、**每请求 KV 峰值 p99**（决定你要不要分池）、**TTFT / ITL 的 p99**。前四个是「资源视角」，最后一个是「用户视角」，只看资源会做出吞吐很漂亮但用户很难受的系统。

**追问七：多卡 TP 之后这些账怎么变？**
每卡各存 1/TP 的 KV，所以单卡容量账要除以 TP，而并发路数不变（一条序列横跨 TP 张卡）。这意味着 TP 越大，单卡能装的路数越少，但每路的算力越多——**TP 和并发的乘积存在最优点**，不是越大越好。

## 八、收尾

这道题的三条线：

- **空间线**：预留最大长度把 96% 的显存变成沉默成本；分页把浪费压到 1.35%，代价是块表和 kernel 复杂度。block 大小是「碎片 vs 表大小 vs kernel 效率」的三方权衡，16 只在特定长度分布下是拐点。
- **复用线**：prefix cache 能省掉八成 prefill，但哈希必须带父链、必须 64 位、key 必须包含所有影响 KV 的配置——这三条任缺一条都是静默的错答案，比慢十倍可怕。
- **调度线**：抢占的盈亏平衡在 6.55 GB/s 带宽，工程上默认重算的真正理由是「偷算力不抢带宽」+ pinned 内存成本；水位要按秒算（43 路并发下 10% 余量只够 2.9 秒）；过载时的三种降级形态里，只有「分位数预留 + 高水位兜底」能同时保住吞吐和 p99。

如果面试官继续压，还能往这几个方向走：**PD 分离下的 KV 传输**（prefill 和 decode 不在同一张卡时，KV 怎么按层流水线搬、带宽怎么算）、**磁盘 KV 缓存**（LMCache 这类方案，命中率与延迟的取舍）、**前缀缓存的跨请求公平性**（热门 system prompt 的块被长期占用，怎么防止小租户饿死）、以及**投机解码对 KV 的影响**（草稿 token 被拒时要回滚哪些块）。

*明日预告：按轮换转到后端/分布式方向——「一次 RPC 的超时到底该设多少？重试放大怎么算、连接池和超时预算怎么联动、为什么加了重试反而让 p99 更糟、以及『超时时间必须小于上游剩余预算』这条铁律在微服务链路里怎么落地」。*

---

**文末附：本文所有数字的复现脚本（Python 3.11，单核，无第三方依赖）**

前半段：容量、分配策略、block 扫描、prefix cache、哈希、抢占成本。

```python
import random, math, hashlib, struct
from collections import Counter

rnd = random.Random(20261124)

# 0. 单位成本：7B 级模型（32 层，GQA-8，head_dim 128，fp16）
LAYERS, KV_HEADS, HEAD_DIM, BYTES = 32, 8, 128, 2
Q_HEADS = 32
PER_TOKEN = LAYERS * KV_HEADS * HEAD_DIM * 2 * BYTES
GIB = 1024 ** 3
print("[0] per_token_KiB", PER_TOKEN / 1024,
      "| 32k_GiB", round(32768 * PER_TOKEN / GIB, 2),
      "| 128k_GiB", round(131072 * PER_TOKEN / GIB, 2))
CAPACITY_TOK = int((24 * 0.9 - 14) * GIB / PER_TOKEN)
print("[0] 24G卡容量 tokens", CAPACITY_TOK,
      "| 80G卡", int((80 * 0.9 - 14) * GIB / PER_TOKEN))

# 1. 负载：2 万条请求
def lognorm(median, sigma):
    return median * math.exp(rnd.gauss(0, sigma))

reqs = []
for _ in range(20000):
    p = int(min(max(lognorm(600, 0.9), 32), 16000))
    o = int(min(max(lognorm(250, 1.0), 16), 2048))
    reqs.append((p, o))
tot = sorted(p + o for p, o in reqs)
q = lambda f: tot[int(len(tot) * f)]
print("[1] avg_len", round(sum(tot) / len(tot), 1), "p50", q(.5), "p90", q(.9),
      "p99", q(.99), "max", tot[-1])

# 2. 三种分配策略
def fill(strategy, max_len=8192, bs=16, budget=CAPACITY_TOK):
    used = reserved = n = 0
    for p, o in reqs:
        need = (max_len if strategy == "reserve_max"
                else p + o if strategy == "reserve_exact"
                else (math.ceil(p / bs) + math.ceil(o / bs)) * bs)
        if (reserved + need) * PER_TOKEN > budget * PER_TOKEN:
            break
        reserved += need; used += p + o; n += 1
    return n, used, reserved

for s in ("reserve_max", "reserve_exact", "paged"):
    n, used, reserved = fill(s)
    print("[2]", s, "concurrency", n, "useful", used, "slots", reserved,
          "waste_pct", round(100 * (1 - used / reserved), 2))

# 3. block 大小扫描
for bs in (4, 8, 16, 32, 64, 128, 256):
    slack = sum((bs - t % bs) % bs for t in tot)
    entries = sum(math.ceil(t / bs) for t in tot)
    print("[3]", bs, round(100 * slack / sum(tot), 3),
          round(entries / len(tot), 2), round(entries / 1000, 1))

# 4. prefix cache：200 个 system prompt × 2 万请求
VOCAB, BS = 50000, 16
base = random.Random(7)
system_prompts = [[base.randrange(VOCAB) for _ in range(1500)] for _ in range(200)]
seen, saved, requested = set(), 0, 0
crnd = random.Random(11)
weights = [1.0 / (i + 1) ** 0.8 for i in range(200)]
for _ in range(20000):
    sysp = system_prompts[crnd.choices(range(200), weights=weights, k=1)[0]]
    user = [crnd.randrange(VOCAB) for _ in range(300)]
    seq = sysp + user
    for i in range(0, len(seq) - BS + 1, BS):
        b = tuple(seq[i:i + BS])
        requested += 1
        if b in seen:
            saved += 1
        else:
            seen.add(b)
print("[4] hit_pct", round(100 * saved / requested, 2),
      "saved_tokens", saved * BS,
      "saved_pct", round(100 * saved * BS / (20000 * 1800), 2))

# 5a. 哈希位宽：100 万个 block
h64 = lambda x: int.from_bytes(hashlib.blake2b(x, digest_size=8).digest(), "big")
h32 = lambda x: int.from_bytes(hashlib.blake2b(x, digest_size=4).digest(), "big")
M = 1000000
r2 = random.Random(13)
raws = [b"".join(struct.pack("<H", r2.randrange(VOCAB)) for _ in range(16)) for _ in range(M)]
for name, fn, bits in (("64bit", h64, 64), ("32bit", h32, 32)):
    c = Counter(fn(b) for b in raws)
    print("[5a]", name, "collisions", sum(v - 1 for v in c.values() if v > 1),
          "expected", round(M * M / 2 / 2 ** bits, 3))

# 5b. 带不带父哈希：同一段模板挂在不同文档后面
docs = [[base.randrange(VOCAB) for _ in range(1000)] for _ in range(5000)]
template = [base.randrange(VOCAB) for _ in range(200)]
flat, chain = {}, set()
flat_hits = false_share = chain_hits = 0
for doc in docs:
    parent = h64(b"root")
    seq = doc + template
    for i in range(0, len(seq) - BS + 1, BS):
        raw = b"".join(struct.pack("<H", t) for t in seq[i:i + BS])
        k_flat, k_chain = h64(raw), h64(struct.pack("<Q", parent) + raw)
        if k_flat in flat:
            flat_hits += 1
            false_share += flat[k_flat] != parent
        else:
            flat[k_flat] = parent
        if k_chain in chain:
            chain_hits += 1
        else:
            chain.add(k_chain)
        parent = k_chain
print("[5b] flat_hits", flat_hits, "false_share", false_share,
      "chain_hits", chain_hits)

# 6. 抢占：recompute vs swap
P = 7e9
def recompute_ms(L, tflops=350):
    linear = 2 * P * L
    attn = 4 * L * L * HEAD_DIM * Q_HEADS * LAYERS
    return (linear + attn) / (tflops * 1e12) * 1e3

def swap_ms(L, gbps):
    return 2 * L * PER_TOKEN / (gbps * 1e9) * 1e3

for L in (512, 2048, 4096, 8192, 32768, 131072):
    print("[6]", L, round(recompute_ms(L), 1), round(swap_ms(L, 25), 1),
          round(swap_ms(L, 55), 1), round(swap_ms(L, 900), 1))
print("[6b] breakeven_gbps", round(PER_TOKEN * 350e12 / P / 1e9, 2))
seqs, L = 64, 4096
print("[6c] swap_GiB", round(seqs * 2 * L * PER_TOKEN / GIB, 1),
      "swap_s_25G", round(seqs * swap_ms(L, 25) / 1e3, 2),
      "recompute_s_350T", round(seqs * recompute_ms(L) / 1e3, 2))
```

实测输出（关键几行）：

```
[0] per_token_KiB 128.0 | 32k_GiB 4.0 | 128k_GiB 16.0
[0] 24G卡容量 tokens 62259 | 80G卡 475136
[1] avg_len 1294.9 p50 998 p90 2476 p99 5618 max 17801
[2] reserve_max concurrency 7 useful 9865 slots 57344 waste_pct 82.8
[2] reserve_exact concurrency 51 useful 62031 slots 62031 waste_pct 0.0
[2] paged concurrency 50 useful 59915 slots 60736 waste_pct 1.35
[3] 8 0.27 162.3 3246.1
[3] 16 0.575 81.4 1628.0
[3] 32 1.191 40.95 819.0
[4] hit_pct 82.21 saved_tokens 29462400 saved_pct 81.84
[5a] 64bit collisions 0 expected 0.0
[5a] 32bit collisions 114 expected 116.415
[5b] flat_hits 59988 false_share 59988 chain_hits 0
[6] 4096 189.0 42.9 19.5 1.2
[6] 131072 30977.7 1374.4 624.7 38.2
[6b] breakeven_gbps 6.55
[6c] swap_GiB 64.0 swap_s_25G 2.75 recompute_s_350T 12.09
```

后半段：decode 水位 / 过载降级形态。

```python
import random, math, statistics
LAYERS, KV_HEADS, HEAD_DIM, BYTES = 32, 8, 128, 2
PER_TOKEN = LAYERS * KV_HEADS * HEAD_DIM * 2 * BYTES
GIB = 1024 ** 3
CAPACITY_TOK = int((24 * 0.9 - 14) * GIB / PER_TOKEN)
CAP = CAPACITY_TOK * PER_TOKEN
DT, STEP = 0.02, 1

def simulate(rnd, mode="none", lam=6.0, horizon=600.0, max_seqs=256,
             reserve_new=0, hi=0.92, lo=0.88):
    def lognorm(median, sigma):
        return median * math.exp(rnd.gauss(0, sigma))
    t = 0.0
    next_arr = rnd.expovariate(lam)
    active, queue = [], []
    used = aborts = preempts = wasted = done = 0
    gen, lat, conc_sum, steps = 0, [], 0.0, 0
    while t < horizon:
        while next_arr <= t:
            p = int(min(max(lognorm(600, 0.9), 32), 16000))
            o = int(min(max(lognorm(250, 1.0), 16), 2048))
            queue.append([p, o, t])
            next_arr += rnd.expovariate(lam)
        while queue and len(active) < max_seqs:
            p, o, ta = queue[0]
            need = p + reserve_new
            if used + need * PER_TOKEN > CAP:
                break
            queue.pop(0)
            used += need * PER_TOKEN
            active.append({"held": need, "left": o, "ta": ta})
        if mode == "watermark":
            while used > CAP * hi and len(active) > 1:
                v = max(active, key=lambda a: a["held"])
                active.remove(v)
                v["dead"] = True
                used -= v["held"] * PER_TOKEN
                preempts += 1
                wasted += v["held"]
                queue.insert(0, [v["held"], v["left"], v["ta"]])
        for a in list(active):
            if a.get("dead"):
                continue
            if used + STEP * PER_TOKEN > CAP:
                if mode == "none":
                    aborts += 1
                    a["dead"] = True
                    active.remove(a)
                    used -= a["held"] * PER_TOKEN
                    continue
                cand = [x for x in active if x is not a]
                if not cand:
                    continue
                v = max(cand, key=lambda x: x["held"])
                v["dead"] = True
                active.remove(v)
                used -= v["held"] * PER_TOKEN
                preempts += 1
                wasted += v["held"]
                queue.insert(0, [v["held"], v["left"], v["ta"]])
                if used + STEP * PER_TOKEN > CAP:
                    continue
            used += STEP * PER_TOKEN
            a["held"] += STEP
            a["left"] -= 1
            gen += 1
            if a["left"] <= 0:
                active.remove(a)
                used -= a["held"] * PER_TOKEN
                done += 1
                lat.append(t - a["ta"])
        conc_sum += len(active)
        steps += 1
        t += DT
    lat.sort()
    return dict(done=done, aborts=aborts, preempts=preempts,
                waste_ratio=wasted / max(gen, 1),
                conc=conc_sum / steps, tp=gen / horizon,
                p50=lat[len(lat) // 2] if lat else 0,
                p99=lat[int(len(lat) * 0.99)] if lat else 0)

CFG = [("不设防线", dict(mode="none")),
       ("不设防线 λ=8", dict(mode="none", lam=8.0)),
       ("抢占 92/88", dict(mode="watermark")),
       ("抢占 97/93", dict(mode="watermark", hi=0.97, lo=0.93)),
       ("抢占 92/88 λ=4", dict(mode="watermark", lam=4.0)),
       ("准入 512", dict(mode="reserve", reserve_new=512)),
       ("准入 1024", dict(mode="reserve", reserve_new=1024)),
       ("准入 2048", dict(mode="reserve", reserve_new=2048))]

SEEDS = range(1, 7)
print("label | done | aborts | preempts | waste_x | conc | tok_s | p50 | p99   (6 seeds mean)")
for label, kw in CFG:
    rows = [simulate(random.Random(s), **kw) for s in SEEDS]
    m = lambda k: statistics.mean(r[k] for r in rows)
    s = lambda k: statistics.pstdev(r[k] for r in rows)
    print("[M]", label, round(m("done")), round(m("aborts")),
          round(m("preempts")), round(m("waste_ratio"), 1),
          round(m("conc"), 1), round(m("tp")),
          round(m("p50"), 1), round(m("p99"), 1),
          "| sd_p99", round(s("p99"), 1), "sd_waste", round(s("waste_ratio"), 1))
```

实测输出（6 个种子，每行是均值与标准差）：

```
label | done | aborts | preempts | waste_x | conc | tok_s | p50 | p99   (6 seeds mean)
[M] 不设防线 3258 276 0 0.0 42.6 2135 5.0 40.9 | sd_p99 0.0 sd_waste 0.0
[M] 不设防线 λ=8 3788 914 0 0.0 49.1 2459 5.6 34.6 | sd_p99 1.9 sd_waste 0.0
[M] 抢占 92/88 2936 0 18345 170.3 38.6 1937 46.8 112.7 | sd_p99 24.3 sd_waste 35.3
[M] 抢占 97/93 3070 0 15068 112.1 40.4 2025 38.9 95.8 | sd_p99 26.9 sd_waste 30.7
[M] 抢占 92/88 λ=4 2352 0 2327 23.8 30.6 1534 5.2 40.9 | sd_p99 0.0 sd_waste 16.7
[M] 准入 512 2261 0 577 6.6 29.5 1481 110.7 218.6 | sd_p99 15.1 sd_waste 0.8
[M] 准入 1024 1755 0 358 5.5 22.8 1145 151.9 300.9 | sd_p99 14.1 sd_waste 0.7
[M] 准入 2048 1224 0 171 3.7 16.0 803 187.2 387.7 | sd_p99 12.5 sd_waste 0.4
```

---

**相关阅读**

- [十亿级搜索自动补全怎么设计](/blog/2026/11/19/typeahead-autocomplete-system-interview)
- [LLM 服务的三个旋钮：token budget、chunk 与并发数](/blog/2026/11/18/continuous-batching-chunked-prefill-scheduler-tuning)
- [KV Cache 优化实战：长上下文推理的内存、量化与驱逐](/blog/2026/08/05/kv-cache-optimization-guide)
- [vLLM 架构详解](/blog/2026/07/26/vllm-architecture-deep-dive)
