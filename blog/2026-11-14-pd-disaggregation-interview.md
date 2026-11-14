---
title: "面试题：LLM 推理的 PD 分离为什么能提速？prefill 算力密集、decode 带宽密集的账怎么算，KV Cache 跨机搬运要多少带宽，P:D 比例又该怎么定？"
date: 2026-11-14T09:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "kv-cache", "vllm", "interview"]
categories: ["Interview"]
description: "LLM 推理系统高频面试题：为什么同一个模型、同一批 GPU，把 prefill 和 decode 拆到不同机器上反而更快？用 roofline 把两个阶段的算术强度算出来——prefill 的算术强度约等于 prompt 长度、decode 的算术强度约等于 batch size，一个在拐点左边一个在右边，混部就是让两种最优解互相将就。再往下是工程账：KV Cache 每 token 多大、搬 640 MiB 在不同互联上要几毫秒、什么时候搬运比重算更亏、layer-wise 流水怎么把传输藏进计算、prefix 感知路由与二次调度怎么做、P:D 比例为什么随输出长度从 1.9:1 摆到 1:8.5、chunked prefill 这条更简单的路线为什么也能吃掉大半收益。"
---

> 这是「每日一题」专栏的第二十四篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇是 [IM 即时通讯系统](/blog/2026/11/13/im-messaging-system-interview)，今天按轮换回到 AI/LLM 方向，兑现上一篇的预告：**PD 分离（Prefill / Decode Disaggregation）**。
>
> 这题的分水岭特别清楚。背过论文的人会说「prefill 是算力密集、decode 是显存带宽密集，所以要拆开」——这句话本身没错，但它只是结论，不是答案。面试官往下问一句「那拆开之后 KV Cache 怎么搬、搬一次多少毫秒、P 和 D 的比例怎么定」，就只剩沉默。今天把从 roofline 到网络带宽到调度比例的四层账全部算一遍，所有数字都能用一段几十行的脚本复现。

{/* truncate */}

## 一、题目与考点拆解

面试官的原话通常是：

> 你们线上推理集群，同一批 A100/H100，把 prefill 和 decode 拆到不同机器上部署，为什么反而吞吐更高、延迟更稳？拆开之后 KV Cache 要从 prefill 机器搬到 decode 机器，这个搬运的开销怎么算？什么时候搬还不如重算？prefill 节点和 decode 节点按什么比例配？这个比例会漂吗？

这道题真正在考四层，缺任何一层都是「看过文章」而不是「做过系统」：

1. **两个阶段的硬件画像**：用 roofline 模型说清楚 prefill 和 decode 分别落在拐点哪一侧，而不是背「一个算力密集一个带宽密集」。
2. **混部的具体伤害**：不是抽象的「互相干扰」，而是 TTFT 抖动、显存竞争、并行策略冲突这三条可量化的路径。
3. **分离后的新成本**：KV Cache 的体积、跨机传输带宽、传输与重算的权衡、流水化隐藏延迟。
4. **调度与运维**：二次调度、prefix 感知路由、P:D 比例的动态性、什么规模下根本不值得拆。

## 二、把两个阶段钉在 roofline 上

### 2.1 算术强度：一个等于 prompt 长度，一个等于 batch size

Roofline 模型的判断标准只有一条：**算术强度（FLOP/byte）是否越过了「峰值算力 / 峰值带宽」这个拐点**。

H100 SXM 的数字：BF16 dense 约 989 TFLOPS，HBM3 带宽 3.35 TB/s。拐点：

```text
knee = 989e12 / 3.35e12 ≈ 295 FLOP/byte
```

意思是：每从显存读 1 字节，如果能配套做 295 次浮点运算，你就在算力受限区；做不到，就在带宽受限区，算力再高也用不上。

**Prefill 的算术强度。** 一个 N 参数的 transformer，处理 T 个 token 的前向计算量约 `2·N·T` FLOP（每个参数每个 token 一次乘加），需要从显存读的权重是 `2·N` 字节（BF16）。所以：

```text
AI_prefill ≈ (2·N·T) / (2·N) = T
```

算术强度**就等于 prompt 长度**。2048 token 的 prompt → 2048 FLOP/byte，是拐点的 7 倍，稳稳的算力受限。这也是为什么长 prompt 的 prefill 能把 GPU 打满、MFU 能到 40%~50%。

**Decode 的算术强度。** decode 每个 step 只处理 B 个 token（B = 当前 batch 里的请求数），但**每个 step 都要把整个模型的权重从 HBM 完整读一遍**——这是自回归解码最反直觉的一点：算一个 token 和算一百个 token，权重读取量是一样的。

```text
AI_decode ≈ (2·N·B) / (2·N) = B
```

算术强度**就等于 batch size**。batch 64 的时候算术强度只有 64，是拐点的五分之一。要让 70B 模型在 H100 BF16 上变成算力受限，batch 得开到 295 以上；换成 FP8 权重（1979 TFLOPS / 3.35 TB/s），拐点抬到 590，这辈子都开不到。

**一句话总结这一节**：prefill 的算术强度是「上下文有多长」，decode 的算术强度是「并发有多高」。这两个量在真实业务里差一两个数量级，而 GPU 只有一个固定的拐点——所以**同一套并行配置、同一个 batch 策略，不可能同时把两边都喂到最优**。这就是 PD 分离的第一性理由，比任何工程细节都硬。

### 2.2 顺带把「为什么 decode 慢」的账算清

70B 模型 FP8 权重 70 GB，一张 H100 的 HBM 是 80 GB。单卡放不下，TP=8 切开，每卡 8.75 GB。decode 一个 step，每张卡要读 8.75 GB 权重——按 3.35 TB/s 理论值，2.6 ms 一个 step；实测有效带宽打七折，再加上 80 层 all-reduce 的通信开销，真实 TPOT 落在 12~20 ms 这个区间。

这解释了两件常被问的事：

1. **为什么 decode 的 batch 越大越划算**：权重读取量不随 batch 变，batch 翻倍几乎不增加时间，吞吐线性涨。所以 decode 的第一优化目标永远是「把 batch 做大」，而做大的瓶颈是 KV Cache 显存。
2. **为什么 TP 开太大对 decode 不划算**：TP 增大时每卡权重变小，但每层都要多一次 all-reduce，通信开销随 TP 线性增长，而计算量已经被带宽限制住了，加卡换不来等比例的吞吐。decode 爱「小 TP + 大 batch」，prefill 爱「大 TP + 短 TTFT」，这个矛盾下一节会展开。

## 三、混部到底怎么互相拖累

「混部有干扰」是句废话，面试要答的是**干扰的三条具体路径和各自的量级**。

### 3.1 调度层面的零和：TTFT 与 TPOT 抢同一个 iteration

现在主流引擎（vLLM、SGLang、TensorRT-LLM）都是 iteration-level scheduling：每个 step 决定这一批里放哪些请求。一批里既有正在 decode 的老请求，也有刚到的新请求，调度器必须二选一：

- 优先 decode：新请求排在后面，TTFT 被拉长（长 prompt 排队时能从几百毫秒涨到几秒）。
- 优先 prefill：一个 4K prompt 的 prefill 要占满 SM 几十上百毫秒（2.2 节算过，70B 单卡 2048 token 是 725 ms，TP=8 也要 91 ms），这期间同批 decode 请求一个 token 都出不来，TPOT 直接打出尖峰。

注意这两个 SLO 是**同一个物理资源上的零和**，不是调参能同时优化的。DistServe 论文的核心论点就在这：把 TTFT 和 TPOT 当成两个独立的优化目标，混部下的最优解一定劣于分开优化的最优解。

### 3.2 显存层面的正反馈

prefill 和 decode 共用一块 HBM，两头都在抢：

- decode 的 KV Cache 是**常驻且单调增长**的（每个 step 多一个 token 的 KV，直到请求结束）。
- prefill 需要**瞬时的大块 workspace**（attention 的中间激活、大 chunk 的输出 buffer）。

峰值叠加的直接后果是可用 KV block 变少 → 能塞的并发变小 → batch 变小 → 单 token 成本上升、TPOT 变差 → 为了压 TPOT 又得压 batch。这是个正反馈，混部机型的「有效 batch」往往比理论值低 30% 以上。

### 3.3 并行策略不可调和

| 维度 | prefill 想怎么配 | decode 想怎么配 |
| --- | --- | --- |
| TP 度 | 大（切分计算，压低 TTFT） | 小（减少 all-reduce，换更大 batch） |
| 主要瓶颈 | 算力（SM 占用） | HBM 带宽 + KV 容量 |
| 最优 batch | 小 batch 大 chunk（凑满算力即可） | 尽可能大（权重读取被摊薄） |
| 量化偏好 | BF16/FP8 都行，精度敏感 | FP8 权重收益最大（直接省一半读带宽） |
| 扩缩容信号 | 入队请求的 prompt 长度分布 | KV 显存水位 + TPOT p99 |

混部只能取交集，交集就是「哪边都不最优」。PD 分离最大的红利其实不是「分开跑更快」，而是**两个阶段可以各自用完全不同的并行配置**——DeepSeek-V3 的生产部署就是这个思路：prefill 用最小 4 节点 32 卡的单元，decode 用 EP320 的大规模专家并行，两套配置差了一个数量级。

### 3.4 那 chunked prefill 呢？

必须主动提，否则显得只知道一种解法。chunked prefill（Sarathi-Serve 的 stall-free batching）把长 prompt 切成小块，和 decode token 拼进同一个 iteration 一起前向：

- **好处**：同一 iteration 里权重只读一次，prefill chunk 白蹭了 decode 已经付过的权重读取成本，算术强度反而上升；TTFT 被摊平，不再有几十毫秒的空窗。
- **代价**：iteration 时间被 chunk 撑长，TPOT 抖动上限由 chunk size 决定；prefill 的 chunk 和 decode 的 token 共享同一份 SM 和带宽，仍然互相挤；两个阶段还是只能共用一套并行度。
- **量级**：原论文报告同等延迟约束下容量提升约 2.6 倍——这个数字说明它吃掉了一大半收益，所以「先上 chunked prefill，压不出去了再上 PD 分离」是非常务实的路线。

面试里把这条路线讲出来，再讲清它和 PD 分离的边界（分离换来的是**资源隔离 + 独立并行策略**，chunked prefill 换来的是**零传输成本**），比单方面吹 PD 分离可信得多。

## 四、拆开之后：KV Cache 怎么搬

### 4.1 先算体积

每 token 的 KV 大小（BF16，K 和 V 各一份）：

```text
KV_bytes_per_token = 2 × layers × kv_heads × head_dim × 2
```

GQA 是关键：Llama-3-70B 有 64 个 query head 但只有 8 个 KV head，所以 KV 只有 attention 维度的八分之一。

| 模型 | layers | KV heads × dim | 每 token KV | 128K 上下文单请求 |
| --- | --- | --- | --- | --- |
| Llama-3-8B | 32 | 8 × 128 | 128 KiB | 16 GiB |
| Llama-3-70B | 80 | 8 × 128 | 320 KiB | 40 GiB |
| DeepSeek-V3（MLA） | 61 | latent 512 + rope 64 | 68.6 KiB | 8.6 GiB |

MLA 那一行值得单独讲：它不再为每个 head 存 K 和 V，而是每层每 token 只缓存一份压缩 latent（512 维）加一份解耦的 RoPE 分量（64 维），KV 直接压到 GQA 的五分之一。**PD 分离能在 DeepSeek 这套上跑得动，MLA 是前提条件之一**——同样的分离架构套在 KV 大五倍的模型上，网络会先炸。

### 4.2 再算搬运时间

70B 模型、2048 token 的 prompt，产出的 KV 是 640 MiB。搬这 640 MiB 要多久，完全取决于互联：

| 互联 | 有效带宽 | 传输 640 MiB | 相对 prefill（91 ms）的额外开销 |
| --- | --- | --- | --- |
| 同机 NVLink | 900 GB/s | 0.7 ms | +1% |
| IB 400 Gb/s（RDMA） | 50 GB/s | 13.4 ms | +15% |
| PCIe 5.0 x16 | 约 50 GB/s | 13.4 ms | +15% |
| 100 GbE | 12.5 GB/s | 53.7 ms | +59% |
| 25 GbE | 3.1 GB/s | 216 ms | +239% |

**结论非常硬**：PD 分离能不能成立，取决于你有没有 RDMA 级别的互联。25 GbE 这种普通以太网，光搬 KV 就比 prefill 本身还慢两倍多，做分离是纯亏。这是很多团队照抄论文架构然后性能倒退的根本原因——论文里的数字是建立在 400 Gb/s RDMA + NVLink 域上的。

### 4.3 传输 vs 重算：什么时候搬不如重算

这是最容易被忽略、也最能体现工程判断的一点。decode 侧如果没有 KV，还有个选项：**自己把这个 prompt 重新 prefill 一遍**。成本对比：

```text
搬运成本 = KV_bytes / 网络带宽
重算成本 = 2·N·T / (峰值算力 × MFU)
```

对 70B、2048 token：KV 是 640 MiB，TP=8 重算要 91 ms。让搬运打平重算的带宽只有 **7.4 GB/s**——这个门槛低到几乎任何机房都能过。所以在 70B 这个量级上，**搬运永远比重算便宜**，尤其当 decode 侧 TP 度更小（重算更慢）时差距更大。

但这个结论不是普适的，反例很清楚：

- **短 prompt**：512 token 的 KV 只有 160 MiB，重算只要 23 ms。如果一个请求的 prefix 已经在 decode 侧的 prefix cache 里命中（多轮对话的常见情况），重算的增量成本接近零，搬反而多此一举。
- **强算力弱网络**（比如跨可用区、跨云）：带宽掉到 1 GB/s 级别，重算立刻反超。
- **MLA 这类小 KV 模型**：KV 只有 GQA 的五分之一，搬运门槛降到 1.5 GB/s 左右，连普通以太网都能接受——所以模型架构会反过来改变系统架构的选择。

工程上的做法不是二选一，而是**让调度器按请求特征决策**：prefix 命中就本地复用、长 prompt 走传输、短 prompt 直接本地重算。

### 4.4 把传输藏进计算：layer-wise 流水

13.4 ms 的传输看着不多，但它卡在 TTFT 的关键路径上（prefill 完 → 传完 → 才能出第一个 token），而且网络抖动会直接打穿 p99。生产实现基本都用两个手段把这段延迟藏起来：

1. **按层流水**：prefill 侧算完第 0 层就把第 0 层的 KV 推出去，不用等 80 层全算完。decode 侧收到第 0 层就能开始算第 0 层。传输时间被计算时间覆盖，**有效额外延迟接近「最后一层的传输时间」**，大约 13.4/80 ≈ 0.2 ms 量级。
2. **按 block 传**：PagedAttention 的 KV 本来就是 16 token 一块的定长 block，天然适合 RDMA write 的粒度；接收端按 block 索引挂到 block table 上，零拷贝、无需重排。这也是为什么 PD 分离方案几乎都长在 PagedAttention 之上。

伪代码长这样（生产实现是 C++/CUDA + RDMA verbs，这里只表达控制流）：

```python
def prefill_with_streaming(request, layers, kv_sender):
    kv_handle = kv_pool.alloc(request.num_blocks)
    for layer in range(len(layers)):
        kv = layers[layer].forward(request.tokens)      # 这段是算力密集的
        kv_sender.send_async(kv_handle, layer, kv)      # 异步推，不阻塞下一层
    kv_sender.flush()                                   # 等最后几层落地
    return kv_handle                                     # 把句柄交给 router


def decode_with_streaming(kv_handle, kv_receiver, layers):
    first = True
    for layer in range(len(layers)):
        kv_receiver.wait_layer(kv_handle, layer)        # 第 0 层到了就往下走
        out = layers[layer].forward(last_token, kv=kv_handle.layer(layer))
    ...
```

注意这里有个容易答错的细节：**prefill 侧不能提前释放 KV**，必须等 decode 侧确认收到（或者等 TTL 过期）才能回收。P 侧崩了但 KV 还在、D 侧崩了 KV 变成孤儿，这两种不一致都要靠「KV 生命周期归 router/池管理，不归任何一方 GPU 管」来兜底。

## 五、架构形态与调度

### 5.1 三种形态，成本差一个数量级

| 形态 | 互联 | 传输开销 | 适用 |
| --- | --- | --- | --- |
| 同机异构（4 卡 P + 4 卡 D） | NVLink | 0.7 ms，几乎免费 | 单机部署、想先验证收益 |
| 跨机 P 池 + D 池 | RDMA / IB | 13 ms 级，可流水化隐藏 | 中大规模生产的主流 |
| KV 池化（Mooncake 式） | RDMA + DRAM/SSD 分层 | 命中时接近本地 | 多轮对话、prefix 复用率高 |

同机异构是最容易被忽略的甜点：**NVLink 上搬 KV 只要 0.7 ms，等于免费**。如果你的 8 卡机本来就跑不满，先把卡按角色切开（Splitwise 早期的 phase splitting 就是这个思路），几乎不用改网络架构就能拿到收益。缺点是显存静态切分，workload 一变就一边闲一边堵。

### 5.2 二次调度：请求要被调度两次

PD 分离引入了一个混部没有的环节：

```text
请求 → router → (1) 选一个 P 节点做 prefill → 拿到 KV 句柄
              → (2) 选一个 D 节点做 decode（按队列长度、显存水位、prefix 亲和）
```

第二跳的选点策略直接决定收益：

- **看队列长度**：只按最短队列选，会把同一 prompt 的请求打散，prefix cache 全失效。
- **看 prefix 亲和**：同一个 system prompt / 同一轮多轮对话的请求尽量落到同一个 D，命中已有 prefix 就省掉一次传输。
- **看显存水位**：D 的 KV 快满了还往里塞，会触发抢占（preemption）和重算，比排队更糟。

**prefix 感知路由是 PD 分离里性价比最高的一个优化**：真实业务里 system prompt 动辄上千 token，多轮对话的 prefix 复用率经常超过 50%，这部分直接省掉 prefill 和传输，等于白捡吞吐。

### 5.3 P:D 比例是算出来的，而且是会漂的

比例不能拍脑袋，要把两边的**稳态吞吐**都算出来再取倒数比。用 70B FP8、TP=8、decode batch 64、TPOT 约 12 ms 这组参数（脚本输出，见第九节）：

| 平均输出长度 | prefill 吞吐 | decode 吞吐 | P:D |
| --- | --- | --- | --- |
| 256 token | 11.0 req/s | 20.8 req/s | 约 1.9 : 1（P 是瓶颈） |
| 1024 token | 11.0 req/s | 5.2 req/s | 约 1 : 2.1 |
| 4096 token | 11.0 req/s | 1.3 req/s | 约 1 : 8.5 |

同一套硬件，只因为平均输出长度从 256 变到 4096，P:D 从 1.9:1 摆到 1:8.5——**跨了 16 倍**。所以任何写死比例的部署方案，在 workload 漂移时必然一边排队一边闲置。工程上的解法只有三条：

1. **弹性伸缩**：按各自队列的等待时间独立扩缩（P 看 TTFT p99，D 看 TPOT p99 和 KV 水位），K8s HPA + 自定义指标。
2. **统一资源池 + 动态角色**：同一批卡，进程起来后按需切换 prefill/decode 角色，比例实时可调。代价是切换要重载权重和 KV 布局，切换粒度粗（分钟级）。
3. **分层拆分**：小模型混部（8B 以下混部干扰本来就小），大模型才拆——不同模型规模用不同架构，这是最省心的做法。

## 六、分离带来的新问题

面试官问「拆开有什么坏处」，答不出三条以上说明只在纸上做过。真实清单：

1. **KV 传输带宽成为新瓶颈**：聚合看，70B、prompt 2048、QPS 30 的场景，KV 流量是 **20 GB/s**——已经吃掉半条 400 Gb/s IB 链路。QPS 60 就顶到 40 GB/s，网络先于 GPU 饱和。混部时代不用关心的跨机流量，分离后成了第一约束。
2. **网络变成延迟故障域**：KV 传输在 TTFT 的关键路径上，交换机抖一下直接打穿 p99。流水化和重传机制能缓解均值，缓解不了尾延迟。
3. **显存碎片与预留**：D 侧要为即将到来的 KV 预留 block，预留少了会抢占，预留多了浪费并发；不同长度请求混合时碎片率很高。
4. **两套扩缩容 + KV 元数据一致性**：P 和 D 是两套副本、两套指标、两套发布流程；KV 句柄的归属、TTL、失败回收全靠 router 兜，实现不好就是显存泄漏。
5. **固定开销在小规模下吃掉收益**：8B 以下模型、短 prompt 短输出、低 QPS 时，传输 + 调度 + 两套进程常驻的开销，比混部那点干扰大得多。**分解架构有最小经济规模**，这个判断力比会画架构图值钱。

## 七、工业实践对照

| 系统 | 核心主张 | 公开量级 |
| --- | --- | --- |
| DistServe | 把 TTFT 和 TPOT 当两个独立 SLO，按 goodput 做资源分配 | 同等 SLO 下可服务约 7.4 倍请求，或把 SLO 收紧 12.6 倍 |
| Splitwise | 机器级 phase splitting，prefill 池和 decode 池分开 | 约 1.4 倍吞吐、20% 成本下降 |
| Mooncake | KVCache 中心化，DRAM/SSD 分层池 + 全局调度 | 多轮场景 prefix 命中率高，等效扩大并发 |
| DeepSeek-V3 | 生产级 PD 分离 + 两阶段不同并行度（prefill 32 卡单元 / decode EP320） | 公开发布的成本结构里 decode 占主导 |
| vLLM / SGLang | 引擎内置分离支持：vLLM 用 kv-transfer-config + KVConnector（NIXL / LMCache / Mooncake），SGLang 用 disaggregation-mode prefill/decode + 传输后端 | flag 名随版本变，概念一致 |

一个诚实的提醒：这些论文数字都是在「400 Gb/s RDMA + 同代 GPU + 特定 workload」下测的。照抄架构但网络跟不上，收益会变成负数——第四节那张表就是判据。

## 八、什么时候不该拆

给面试官一个「知道边界」的印象，比会讲收益更稀缺：

- **模型小（8B 以下）**：prefill 只要几十毫秒、KV 每 token 才 128 KiB，混部干扰小，拆开纯增开销。
- **prompt 极短 + 输出极短**：KV 体积小、重算便宜，传输和二次调度的固定成本占比高。
- **没有 RDMA 级互联**：25 GbE 上搬 KV 要 200 ms 以上，收益直接为负。
- **QPS 低（单机就能吃下）**：没有排队就没有干扰，分离解决的是「资源竞争」问题，不解决「单请求太慢」。
- **延迟不敏感但成本敏感**：离线批处理用大 batch + chunked prefill 更划算，分离带来的调度复杂度不值。

## 九、代码：把四层账一次算完

下面这段脚本能复现文中所有数字，改参数就能算你自己的模型和网络：

```python
GB, GIB = 1e9, 1024**3
BW, FLOPS = 3.35e12, 989e12          # H100 SXM: HBM3 带宽 B/s, BF16 dense FLOPs

def kv_per_token(layers, kv_heads, head_dim, bpe=2):
    return 2 * layers * kv_heads * head_dim * bpe      # K 和 V 各一份

def mla_kv_per_token(layers, kv_lora_rank=512, rope_dim=64, bpe=2):
    return layers * (kv_lora_rank + rope_dim) * bpe    # 只存一份 latent + rope

def prefill_seconds(params, tokens, tp, mfu=0.40):
    return 2 * params * tokens / (FLOPS * tp * mfu)

print("roofline knee:", FLOPS / BW)
for name, params, kv in [
    ("Llama-3-8B", 8e9, kv_per_token(32, 8, 128)),
    ("Llama-3-70B", 70e9, kv_per_token(80, 8, 128)),
    ("DS-V3(MLA)", 671e9, mla_kv_per_token(61)),
]:
    print(name, "kv/token = %.1f KiB" % (kv / 1024),
          "128K -> %.1f GiB" % (kv * 131072 / GIB))

params, kv, T = 70e9, kv_per_token(80, 8, 128), 2048
t_p = prefill_seconds(params, T, tp=8)
kv_bytes = T * kv
print("prefill TP=8: %.0f ms, KV=%.0f MiB" % (t_p * 1000, kv_bytes / GIB * 1024))

for name, bw in [("NVLink", 900e9), ("IB400G", 50e9), ("PCIe5", 50e9),
                 ("100GbE", 12.5e9), ("25GbE", 3.1e9)]:
    tt = kv_bytes / bw
    print("%-8s %7.1f ms (+%.0f%%)" % (name, tt * 1000, tt / t_p * 100))

print("break-even bw vs recompute:", round(kv_bytes / t_p / 1e9, 2), "GB/s")
for qps in (5, 10, 30, 60):
    print("QPS", qps, "->", round(qps * kv_bytes / 1e9, 1), "GB/s")
```

真实输出（H100 参数、MFU 取 0.40、decode 有效带宽取峰值的 35%）：

```text
roofline knee: 295.2
Llama-3-8B  kv/token = 128.0 KiB 128K -> 16.0 GiB
Llama-3-70B kv/token = 320.0 KiB 128K -> 40.0 GiB
DS-V3(MLA)  kv/token = 68.6 KiB 128K -> 8.6 GiB
prefill TP=8: 91 ms, KV=640 MiB
NVLink      0.7 ms (+1%)
IB400G     13.4 ms (+15%)
PCIe5      13.4 ms (+15%)
100GbE     53.7 ms (+59%)
25GbE     216.5 ms (+239%)
break-even bw vs recompute: 7.41 GB/s
QPS 5 -> 3.4 GB/s
QPS 10 -> 6.7 GB/s
QPS 30 -> 20.1 GB/s
QPS 60 -> 40.3 GB/s
```

P:D 比例那部分（decode 侧按 `每 step 读取字节 / 有效带宽` 逐项累加：每卡权重 + 本卡 KV）：

```python
def decode_step_ms(params, batch, ctx, kv, tp=8, fp8=True, eff=0.35):
    per_gpu = params * (1 if fp8 else 2) / tp + batch * ctx * kv / tp
    return per_gpu / (BW * eff) * 1000

for out_len in (256, 1024, 4096):
    step = decode_step_ms(params, 64, 2048, kv)
    dec_rps = 64 / (step / 1000) / out_len
    pre_rps = 1 / t_p
    print("out=%4d  TPOT=%.1f ms  P:D = 1:%.1f" % (out_len, step, pre_rps / dec_rps))
```

```text
out= 256  TPOT= 12.0 ms  P:D = 1:0.5   (即 1.9:1，P 侧更紧)
out=1024  TPOT= 12.0 ms  P:D = 1:2.1
out=4096  TPOT= 12.0 ms  P:D = 1:8.5
```

## 十、面试追问清单

能主动把这几条讲出来，基本就是「做过」的口径：

1. **为什么 decode 不能靠加算力加速？** —— 算术强度等于 batch size，batch 64 时离拐点还差五倍，SM 一半在等 HBM。加卡不改变单卡读权重的字节数。
2. **为什么 TP 越大 decode 不一定越快？** —— 每层 all-reduce 的开销随 TP 线性增加，而计算量已经被带宽锁死，通信占比反过来吃掉收益。
3. **KV 传输和重算怎么选？** —— 算 break-even 带宽（70B 约 7.4 GB/s）；prefix 已命中或 prompt 很短时重算更便宜。
4. **传输的延迟怎么藏？** —— 按层流水 + 按 block 传，把 13 ms 压成「最后一层的传输时间」；剩下的靠 prefix 复用摊薄。
5. **P:D 比例为什么不能写死？** —— 它由「prefill 吞吐」和「decode 吞吐」的倒数比决定，而 decode 吞吐反比于平均输出长度，随业务漂移几十倍。
6. **chunked prefill 和 PD 分离冲突吗？** —— 不冲突但边界清楚：前者零传输成本、仍共用并行度；后者资源隔离、可各自最优。规模小时前者就够。
7. **分离后最大的新瓶颈是什么？** —— 跨机 KV 流量（QPS 30 就到 20 GB/s）和网络尾延迟，不再是 GPU 本身。
8. **什么规模不该拆？** —— 8B 以下、短 prompt 短输出、没有 RDMA、QPS 低到单机吃下。

最后收一句方法论：**PD 分离不是一个「更先进的架构」，它是一次用网络带宽和运维复杂度去换 GPU 利用率的交易。** 交易划算的前提是网络够快、KV 够小（MLA/GQA）、workload 够重。这三条里缺一条，混部 + chunked prefill 往往才是正确答案。

---

*明日预告：按轮换回到后端/分布式方向 ——「InnoDB 的四种隔离级别到底隔离了什么？MVCC 的快照读为什么在可重复读下也看不见别人提交的数据、undo 版本链和 Read View 怎么配合、当前读为什么必须加锁、间隙锁和 next-key lock 又是怎么在等值查询里凭空锁住一片区间、线上死锁该怎么从 `SHOW ENGINE INNODB STATUS` 里读出来？」*

---

**相关阅读**

- [IM 即时通讯系统：百万长连接怎么撑住](/blog/2026/11/13/im-messaging-system-interview)
- [为什么 vLLM 是当前最快的 LLM 推理框架](/blog/2026/08/29/vllm-inference-interview)
- [KV Cache 是什么？为什么长上下文推理显存不够用](/blog/2026/08/19/kv-cache-interview)
- [长上下文与 RoPE 长度外推](/blog/2026/10/09/long-context-rope-interview)
- [MoE 混合专家：稀疏激活、专家路由与推理显存墙](/blog/2026/10/02/moe-mixture-of-experts-interview)
