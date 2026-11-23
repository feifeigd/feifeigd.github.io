---
title: "GPU 集群调度：拓扑、Gang 与碎片的三层账本"
date: 2026-11-24T01:40:00+08:00
draft: false
tags: ["ai", "infra", "gpu", "kubernetes", "benchmark"]
categories: ["Tech"]
description: "64 卡集群里 20 张空闲卡却排不进一个 8 卡任务。原因是 K8s 把 GPU 当成标量整数，而真实资源是三维的：卡数、拓扑域、时间。本文用离散事件模拟器跑 900 个任务，量化 pod 级调度、严格 gang FIFO 与保守回填三种策略的等待时间、利用率与半启动浪费，并给出 DRA、Kueue TAS、Volcano PodGroup 的落地判据。"
---

`kubectl describe node` 说集群还有 20 张空闲 GPU，8 卡任务在队列里 Pending 了 3 小时。

这 20 张卡分布在 6 台机器上：3、3、4、4、4、2。没有一台剩 8 张。任务要的是"一台机器上的 8 张"，集群有的是"总共 20 张"。这两句话在 `nvidia.com/gpu` 这个字段里长得一模一样。

GPU 调度真正难的地方不在算法，在**记账**：这是三种不同维度的资源被压在一个标量里。

| 维度 | 现实约束 | K8s 默认调度器 |
|---|---|---|
| 卡数（标量） | allocatable 剩余多少 | 认 |
| 拓扑域（向量） | 8 卡是否在同一 NVLink 域、跨机是否同 leaf switch | 不看 |
| 时间（gang） | 16 卡任务的两个 pod 必须同时起来 | 逐 pod 决策 |

只算第一层，就是上面那个 3 小时的 Pending。本文把三层拆开，用模拟器量化每一层的成本，再给出对应的机制。

## 第一层：device plugin 上报的是计数，不是属性

`nvidia.com/gpu: 8` 的语义只有一句：某个节点上有 8 张空闲的、不可共享的 GPU。至于这 8 张是 A100 还是 H100、是否共享一个 NVLink 域、是不是 MIG 切片，调度器一概不知。

三个直接后果：

1. **混卡池里卡型不可区分**。同一个 `gpu` 资源名下，A100 和 H100 等价。训练任务被切到 H100 节点还是 A100 节点全看运气，而同一次 DDP 里最慢的卡决定 step time。
2. **MIG 必须单独上报**。切片只能以 `nvidia.com/mig-3g.40gb` 这类独立资源名暴露，否则整卡和切片无法区分计价与配额；两套上报如果同时挂在一个节点上，聚合 quota 会把一个切片当整卡算，超卖之后就是 CUDA OOM。
3. **拓扑不可见**。8 卡单机任务还能靠"节点内资源够"蒙对，2 机 16 卡任务的两个 pod 完全可能落到跨 spine 的两台机器上——功能正常，带宽砍半。

**Topology Manager 救不了这个。** 它对齐的是容器内 CPU、内存与设备的 NUMA 亲和（scope 是 container 或 pod，policy 是 none、best-effort、restricted、single-numa-node），解决的是"GPU 和它的 PCIe 上游 CPU 在同一 NUMA 节点"的问题。NVLink 域、机间互联、机柜拓扑，它属于另一层。

正确的落点是 DRA：Kubernetes 1.34 起 `resource.k8s.io/v1` GA 并默认开启，GPU 从整数变成带属性的对象。driver 通过 ResourceSlice 发布每个设备的能力（型号、显存、MIG profile、自定义 topology 键），workload 用 ResourceClaim + CEL 表达需求：

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: h100-nvlink8
spec:
  spec:
    devices:
      requests:
        - name: gpus
          deviceClassName: gpu.nvidia.com
          count: 8
          selectors:
            - cel:
                expression: >-
                  device.attributes["gpu.nvidia.com"].productName == "NVIDIA-H100-80GB-HBM3" &&
                  device.attributes["gpu.nvidia.com"].nvlinkDomain == "node-a"
```

属性名由 driver 决定，别照抄任何博客里的键名——先 `kubectl get resourceslices -o yaml` 看你自己的 driver 到底发了什么，再写 CEL。1.36 起 partitionable devices（动态 MIG）进 beta，切片终于能在调度时按容量而不是按固定 profile 卖。

## 第二层：gang 不是免费的

分布式训练的 pod 互相等：NCCL init 要求所有 rank 同时在线的集合通信域，缺一个就挂住。默认 kube-scheduler 逐 pod 决策，于是出现"半启动"——一半在跑（占着 8 卡烧电、不产出），另一半 Pending 等容量。

我写了个离散事件模拟器量化这件事：64 卡 = 8 节点 × 8 卡，每节点一个 NVLink 域；900 个任务，70% 是 1 卡推理（均值 1.5h），22% 是 8 卡单机训练（9h），8% 是 16 卡两机训练（18h）。到达率调到 1.79 个/小时，此时需求超过集群供给（duty cycle 约 93%），是 GPU 集群的常态。

三种策略：`pod_fifo`（pod 是独立调度单位，FIFO，即默认 kube-scheduler 的行为）、`gang_fifo`（整 job 为单位，严格 FIFO，不许插队）、`gang_backfill`（gang + 装箱 + 保守回填）。

| 策略 | 平均等待 | P99 等待 | 1 卡任务 | 8 卡任务 | 16 卡任务 | 利用率 | 半启动浪费 |
|---|---|---|---|---|---|---|---|
| pod_fifo | 25.9h | 82.8h | 17.8h | 46.7h | 44.6h | 93% | 1013 GPU·h |
| gang_fifo | 61.8h | 119.2h | 61.5h | 63.7h | 58.8h | 88% | 0 |
| gang_backfill | 20.3h | 84.6h | 10.4h | 43.7h | 47.2h | 93% | 0 |

反直觉的是第二行：**严格 FIFO 的 gang 调度比不管 gang 还差一倍多**。平均等待从 25.9h 涨到 61.8h，P99 从 82.8h 到 119.2h，利用率掉 5 个百分点（约 2300 GPU·h 空转）。

原因是队头阻塞（head-of-line blocking）加上"预留空洞"：队头是一个 16 卡任务，此时集群有 10 张卡空闲，但凑不出两台整机——这 10 张卡被队头"预留"，后面的 1 卡推理任务全部不许进。队头的启动时刻被最长的 8 卡任务支配，而排队的小任务本来可以立刻吃掉这些空洞。gang 保证了原子性，代价是把整个队列的时间轴绑在最慢的那个任务上。

回填把这个代价收回来。保守回填（EASY 风格）的规则很简单：算出队头**预计**能启动的时刻 t\*，任何排在后面的小任务，只要它能在 t\* 之前跑完，就允许插进去。它不许抢走队头需要的资源，所以不会无限推迟队头。

```python
import heapq

def take(n, free, size=8):
    """装箱：优先塞进最满的节点，把大块空洞留出来"""
    pool = [k for k, v in free.items() if v >= size]
    if len(pool) < n:
        return None
    pool.sort(key=lambda k: free[k])
    for k in pool[:n]:
        free[k] -= size
    return pool[:n]


def t_star(job, free, running):
    """队头最早能在什么时刻被放下：按 running 的结束时刻逐个归还 GPU"""
    sim = dict(free)
    for end in sorted({e for e, _, _ in running}):
        for e, node, gpus in running:
            if e == end:
                sim[node] += gpus
        if take(job.pods, sim, job.per_pod) is not None:
            return end
    return float("inf")


def schedule(queue, free, running, now, backfill=True):
    head = queue[0]
    nodes = take(head.pods, free, head.per_pod)
    if nodes:
        for k in nodes:
            heapq.heappush(running, (now + head.dur, k, head.per_pod))
        queue.pop(0)
        return 1
    if not backfill:
        return 0

    ts = t_star(head, free, running)
    if ts == float("inf"):
        return 0
    reserved = dict(free)
    take(head.pods, reserved, head.per_pod)        # 先替队头占位
    placed = 0
    for j in [x for x in queue[1:] if x.gpus < head.gpus]:
        if now + j.dur > ts:                       # 跑不完就别占坑
            continue
        probe = dict(reserved)
        if take(j.pods, probe, j.per_pod) is None:  # 抢了队头的位子，跳过
            continue
        take(j.pods, reserved, j.per_pod)
        for k in take(j.pods, free, j.per_pod):
            heapq.heappush(running, (now + j.dur, k, j.per_pod))
        queue.remove(j)
        placed += 1
    return placed
```

有一点必须承认：回填让大任务让路。16 卡任务的平均等待从 44.6h（pod 级）变成 47.2h（回填），P99 也更差一点。排队策略没有免费午餐，只有"把成本转嫁给谁"——这里的选择是把约 7 小时的等待从 630 个 1 卡推理任务转移到 72 个 16 卡任务上，总等待时间和利用率都赢了。

另外注意：低负载下三种策略几乎无差别（到达率 1.37 个/小时时平均等待 5.8h、14.5h、5.1h），问题只在超载时暴露。所以调度策略的容量评估一定要在 **duty cycle 超过 90%** 的区间做，否则测不出任何东西。

## 第三层：碎片——空闲卡数是最误导的指标

同样是 8 节点 × 8 卡，用 22 个 1/2/4 卡的小请求把集群填到约 70%，然后数"还能整块放下几个 8 卡任务"。三种放置策略，同样的请求序列：

| 放置策略 | 可放的 8 卡整机数 | 零散闲置卡 |
|---|---|---|
| 装箱（塞最满的节点） | 2.04 / 8 | 3.4 张 |
| 平衡（塞最空的节点） | 0.00 / 8 | 20.2 张 |
| 随机 | 0.17 / 8 | 18.8 张 |

**20 张免费卡，0 台可用机器。** 这是"碎片率"必须单独记账的原因：`free_gpus` 这个指标在平衡放置下会一直显示"还有 30% 空闲"，而训练队列一个任务都起不来。

正确的指标是两个：

- `largest_free_topology_domain`：还能放下完整 NVLink 域的机器数（上面的 2.04 和 0.00）
- `placeable_demand_coverage`：当前队列里各形状的任务，能被现有布局满足的比例

这个场景 Kueue 的 TAS 文档写得很直白：只按聚合 quota 准入，一个 8 卡 pod 会被 admit，然后永久 Pending——因为准入算的是总量，落位算的是布局。TAS 把节点级空闲容量与拓扑域纳入准入检查，只有真的放得下才 admit，这才是把准入和放置对齐的做法。

异构池是同一个问题的变体：A100 和 H100 混在一个队列里，同一个 job 可能一半落 A100 一半落 H100，每步同步等最慢那一半。要么用 ResourceFlavor / nodeAffinity 按卡型切队列，要么用 DRA 的 CEL 精确选型——但别指望"资源配置正确"就等于"性能正确"。

## 跨机带宽：拓扑不是洁癖

公开规格摆在这里（双向）：

| 互联 | 带宽 |
|---|---|
| NVLink 3（A100 SXM） | 600 GB/s 每卡 |
| NVLink 4（H100 SXM） | 900 GB/s 每卡 |
| PCIe 4.0 x16 | 64 GB/s |
| 400G NDR InfiniBand | 50 GB/s 单向 |
| 25G 以太网 | 3 GB/s 单向 |

8×A100 的 all-reduce busbw 在 NVLink 域内通常落在 250–300 GB/s，跨机 400G IB 大约 40–45 GB/s，差 6–7 倍。一个 7B 模型的 DDP，梯度 all-reduce 在 step time 里能占三到五成，带宽差 6 倍意味着 step time 直接翻倍甚至更多。所以"把 16 卡任务的两个 pod 放到跨 spine 的两台机器"不是配置洁癖，是 2 倍的钱。

反过来说，如果你的瓶颈是显存带宽（decode 阶段的 KV Cache 读写），跨机互联再宽也没用——拓扑感知要按负载类型算，不能一刀切。

## 落地：先分区，再谈装箱

最有效的一步不花钱：**把推理和训练拆成两个节点池**。

- 推理池：1 卡或 MIG 切片，长稳、无 gang、要高密度。小任务本来就是碎片制造机，让它们在自己的池子里碎。
- 训练池：整卡、整机（整 NVLink 域）分配、强制 gang。池内只跑大块请求，装箱策略才能把空洞留住。

混在一起的集群必然碎片化：推理任务把每台机器啃出 1–2 张卡的洞，训练的大块永远凑不齐，然后你会在监控上看到"利用率 70%、队列 P99 排队 6 小时"的经典矛盾。

gang 调度器的选型判据：

| | Kueue | Volcano |
|---|---|---|
| 位置 | 准入层，保留 kube-scheduler | 替换调度器 |
| gang 语义 | quota 准入 + TAS 布局检查 + waitForPodsReady 超时兜底 | PodGroup minMember，调度时原子决策 |
| 强项 | 多租户配额、cohort 借用、公平共享 | gang 精确、抢占与 reclaim 都在调度器内 |
| 代价 | 不保证 kube-scheduler 真能放下（TAS 后基本解决） | 多一个调度器要运维，混部时要处理 schedulerName |

Volcano 的 PodGroup 有个必须写对的细节：

```yaml
apiVersion: scheduling.volcano.sh/v1beta1
kind: PodGroup
metadata:
  name: train-16gpu
spec:
  minMember: 2                 # pod 数，不是卡数
  minResources:
    nvidia.com/gpu: "16"       # 卡数要单独写
  queue: training
```

`minMember` 只数 pod。8 个 pod、每个 4 卡的任务如果只写 `minMember: 8`，集群有 8 张卡时它就会被判定可以启动，然后一半 pod 永远起不来——这是我见过最多人踩的一个坑。

监控五个指标，缺一个就会在出问题时看错方向：

1. **分配率 vs 有效利用率**：DCGM 的 SM active 时间加权（`DCGM_FI_PROF_SM_ACTIVE`）才是"卡在干活"，分配率 95% 而 SM 活跃 30% 说明跑的是慢任务或数据饥饿，不是调度问题。
2. `largest_free_topology_domain`：直接反映碎片。
3. gang pending P99：按形状（1/8/16 卡）分开看，混在一起会互相掩盖。
4. 半启动浪费 GPU·h：pod 起来了但 job 没 ready 的时长 × 卡数，模拟里超载时这一项能吃掉 1000 GPU·h。
5. 抢占次数 / checkpoint 间隔：抢占等待必须短于 checkpoint 周期，否则每次抢占丢的进度比省下的排队还多。

## 踩过的坑

- **Kueue 只按聚合 quota 准入**（未开 TAS）：8 张空闲卡分散在 2 台，8 卡 pod 被 admit 后永久 Pending，事件里只有 `Insufficient nvidia.com/gpu`，排查方向完全被误导。开 TAS 之后这个问题消失。
- **MIG 与整卡混报**：同节点同时暴露整卡和切片，聚合 quota 把一个切片当整卡算，超卖后训练进程 CUDA OOM，报错在 `ncclAllReduce` 里，看起来像通信问题。
- **device plugin 重启后计数不一致**：`nvidia-smi` 显示空闲，调度器认为已占满。原因是 kubelet 侧旧的 checkpoint 没清，重启 kubelet 让 device plugin 重新注册才恢复。
- **训练任务没有 gang 时的重试风暴**：8 个 pod 各自 CrashLoop 几十次，把 API server 的 watch 打满，整个集群调度延迟上升，故障看起来像"整个 K8s 挂了"。
- **镜像内部自己选卡**（`CUDA_VISIBLE_DEVICES` 被脚本覆盖）：两个 pod 抢同一张卡，表现为随机进程被 OOM kill，而调度器账面上一切正常。

## 结论

三层账，三套指标，顺序不能反：

1. **整数账**（quota）：`nvidia.com/gpu` 够不够——K8s 默认只算这层。
2. **拓扑账**（domain）：整机/NVLink 域是否连续——靠 DRA 的属性选择或按卡型/形状分区。
3. **时间账**（gang）：能不能同时起——靠 Kueue TAS 或 Volcano minMember，配回填。

调度器修不了物理：它没法把 20 张零散卡拼成一台 8 卡机。所以先分区把需求形状对齐（这一步不需要任何新组件），再谈装箱与回填，最后才是指标与告警。反过来做，你会花三个月调一个 5% 的提升，而那 20 张卡依然一张都用不上。
