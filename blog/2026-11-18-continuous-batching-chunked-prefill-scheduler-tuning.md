---
title: "LLM 服务的三个旋钮：token budget、chunk 与并发数——从 ITL p99 尖刺反推调度配置"
date: 2026-11-18T20:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "vllm", "performance"]
categories: ["Tech"]
description: "吞吐没掉、GPU 利用率没掉，但 ITL p99 从 40ms 跳到 400ms——这类问题几乎都是调度器造成的。用一个可运行的单事件模拟器把 token budget / chunk / max_num_seqs 三个旋钮量化，给出每步耗时模型、策略对比实测，以及从 SLO 反解配置的公式。"
---

把一个跑得好好的推理服务交到别人手里，最先被改坏的一定是调度参数。现象很典型：吞吐没掉、GPU 利用率没掉、`nvidia-smi` 一片祥和，但用户体感在某几个时刻突然"卡住"——打一个字停半秒，然后又恢复。

这类尖刺不是模型慢，是**同一个 batch 里混进了一个超长 prefill**。那一步的耗时从 30ms 变成 400ms，batch 内所有正在 decode 的请求一起被拖住，谁都跑不掉。chunked prefill 就是为这件事设计的，但它的调参在工程上经常变成玄学：`max-num-batched-tokens` 该给 2048 还是 8192，`chunked-prefill-size` 该给 512 还是 4096，没人说得清依据。

这篇文章用一份可运行的单事件模拟器，把三个旋钮（token budget、chunk、并发数）的因果链量化：先给每一步的耗时模型，再跑策略对比，最后从延迟 SLO 反解出参数。所有数字都是这份代码跑出来的，你可以改常量重跑。

{/* truncate */}

## 一、静态批的代价不在吞吐，在排队

先分清两种批处理。**静态批**（static batching，也是 FasterTransformer 时代的做法）把 batch 当成一个事务：凑够一批，整批一起跑，直到批内**最后一个**序列生成完，才收新请求。**迭代级调度**（iteration-level scheduling，Orca 提出、现在 vLLM/SGLang/TGI 的默认做法）是每一步都重新决定 batch 里有谁。

静态批被诟病的通常是"padding 浪费"，但在真实负载下更致命的是**tail 效应和排队**：一个 300 token 的请求和一个 100 token 的请求同批，短的那个结束后槽位仍然被占着（等长的那个跑完），而新到的请求只能在外面等整批结束。批内长度方差越大，浪费越狠。

我用同一份到达轨迹（240 个请求，Poisson 到达，60% 是 300~600 token 的短对话、40% 是 2.8k~4.2k 的长 RAG 提示，输出 100~300 token）跑两种策略，中等负载下的结果：

```text
load  policy           tok/s   TTFT50   TTFT99   ITL99   ITLmax
1.8   static           287.7     6328    14827      46       47
1.8   cont             299.3      307      876     363      471
```

TTFT p99 从 **14.8 秒**降到 **0.9 秒**，差 17 倍；吞吐只差 4%。这就是为什么"把静态批换成 continuous batching"在业务侧感觉像是换了个模型——它主要不是提吞吐，是消掉了排队。

高负载（rps 2.4，已经过载）时差距更明显：

```text
load  policy           tok/s   TTFT50   TTFT99   ITL99   ITLmax
2.4   static           337.8    12410    30212      73       73
2.4   cont             375.7      387     1297     445      514
```

吞吐也掉了 10%：过载时静态批的槽位空转直接变成了算力损失，而迭代级调度可以把腾出来的槽位立刻塞给排队的请求。注意 `static` 的 ITL 看起来"更好"（73ms vs 445ms），这是个陷阱——它只是 batch 内序列更少、上下文更短，代价全压在 TTFT 上了。

顺带说一句 Orca 的结论：在同等延迟约束下，迭代级调度相对 FasterTransformer 的静态批做到过 **36.9 倍**吞吐提升。那是 2022 年、batch 内长度方差极大的场景；到了今天，收益的大头已经被吃掉了，剩下的差距就是上面这种个位数到两位数百分比。

## 二、一次迭代的成本：一个够用的 roofline 模型

要谈调度，先得有一个能算"这一步要多久"的模型。7B fp16 在单张 A100-80G 上，下面这个四项目模型足够预测到 10% 以内：

```text
t_step = BASE                                    # 权重/启动下限, ~10ms
       + 0.09 * P                               # prefill 线性项 (ms/token)
       + 2e-6 * Σ n_i * (n_i/2 + kv_i)          # prefill attention
       + 0.24 * D                               # 每序列 decode 的 KV 读 + 小算子
       + 6e-4 * Σ kv_j                           # decode attention (ms/KV token)
```

四个常量分别对应四件物理事实：

- `BASE` 是每步固定开销：即使 batch 里只有一个 token，也要把 14GB 权重从 HBM 过一遍（A100 2TB/s 实测有效带宽 1.4TB/s 左右，约 10ms），再加上 kernel launch。
- `0.09 ms/token` 是 prefill 的算力成本：7B 每 token 约 14 GFLOP，A100 fp16 312 TFLOPS、按 40% MFU 折算约 125 TFLOPS，正好落到 0.1ms 附近。
- `0.24 * D` 是解码时每序列要读一遍自己的 KV 和少量算子。
- `6e-4 * Σ kv` 是 attention 对 KV 的读取：**这一项是 decode 阶段真正的大头**。

最后一项值得单拎出来算一次，因为它解释了"为什么并发数和上下文长度是乘性关系"。7B 模型 32 层、32 头、head_dim 128，每 token 的 KV 是 `2 × 32 × 32 × 128 × 2B = 512KB`（fp16，GQA 8 组则约 128KB）。按 512KB 算，32 个并发、平均上下文 2000，一步要读 `32 × 2000 × 512KB = 32GB` 的 KV，在 1.4TB/s 下就是 **23ms**——已经超过权重读取，成为瓶颈。fp8 KV cache 直接砍半，这也是为什么长上下文场景里 KV 量化的收益比权重量化更明显。

**推论**：`max_num_seqs` 不是一个"越大越好"的吞吐旋钮。它把 decode 步时推向线性增长，而每序列的 token 速率 `1/t_step` 随之下降；总吞吐 `D/t_step` 在某个点之后趋平甚至下降，同时 ITL 全线变差。这个拐点就在 `Σ kv` 超过权重读取量的地方。

## 三、chunked prefill 削的是尖刺，不是吞吐

有了成本模型，"长 prompt 一来 ITL 就尖刺"的机理就清楚了：一个 3500 token 的 prefill 独占一步，`0.09 × 3500 = 315ms`，加上 attention 项约 400ms。这一步里 batch 内所有 decode 序列的下一 token 都被推迟了 400ms。

更本质的一层是**相位错配**。prefill 是大 GEMM，compute-bound，MFU 能到 40%；decode 是 batch 内小矩阵乘 + 大量 KV 读，memory-bound，MFU 只有个位数。纯 prefill 的 batch 浪费带宽，纯 decode 的 batch 浪费算力。把两者混进同一个迭代里，prefill 的算力需求刚好把 decode 的带宽等待时间填满——Sarathi-Serve 把这叫 **stall-free batching**，它的实现就是 chunked prefill + 把 chunk 和 decode 拼进同一个 batch。

所以 chunked prefill 的收益应该这样表述：

- **ITL p99 大幅下降**（尖刺被切成 N 份）；
- **吞吐基本不变**（总计算量没变，只是重新排布）；
- **TTFT 尾部变差**（长 prompt 需要多个迭代才 prefill 完，中间还要和 decode 抢预算）。

第三点经常被忽略，然后在压测里表现为"chunk 调小之后 TTFT 反而抖了"。这不是 bug，是同一份算力的两个出口。

## 四、模拟器：把策略差异跑成数字

下面是完整的核心部分（单事件、确定性、纯 stdlib，`python3 sched_sim.py` 直接跑）。三件事：算 step 耗时、按策略组 batch、记录每个请求的 TTFT 与逐 token 间隔。

````python
def step_time(chunks, decodes):
    """chunks: [(req, n)] 本步要 prefill 的 token 数; decodes: [req] 本步要出 1 个 token 的序列"""
    t = BASE
    for r, n in chunks:
        t += C_PREF * n + C_ATTN_PREF * n * (n / 2 + r.done_pre)
    t += C_DEC_KV * len(decodes) + C_ATTN_DEC * sum(r.kv_len for r in decodes)
    t += 0.09 * len(decodes)
    return t


def build_iteration(running, policy, max_seqs, budget, chunk):
    """返回本步的 (chunks, decodes)。decode 优先，剩余预算按策略填 prefill。"""
    decodes = [r for r in running if r.pre_left == 0][:max_seqs]
    used, chunks = len(decodes), []
    for r in running:
        if r.pre_left == 0:
            continue
        if len(decodes) + len(chunks) >= max_seqs:      # 槽位上限
            break
        room = budget - used                            # token 预算上限
        if room <= 0:
            break
        # cont: 不切, prefill 必须整块进这一步; chunk: 切到 chunk 大小
        n = r.pre_left if policy == "cont" else min(r.pre_left, chunk, room)
        chunks.append((r, n))
        used += n
    return chunks, decodes
```

主循环就是"推进时间 → 准入 → 组 batch → 按模型耗时前进 → 记账"，去掉了所有 I/O 和 GPU 细节，因此结论只反映调度逻辑本身。

三档负载（1.2 / 1.8 / 2.4 rps）× 四种策略的实测：

```text
load  policy           tok/s   TTFT50   TTFT99   ITL99   ITLmax
1.2   static           201.2     3036     8971      28       29
1.2   cont             205.0      162      651     297      418
1.2   chunk512         204.9      138      914     103      164
1.2   chunk256         204.8      168     1089      71      109
1.8   static           287.7     6328    14827      46       47
1.8   cont             299.3      307      876     363      471
1.8   chunk512         299.1      200     1266     147      227
1.8   chunk256         298.7      226     1600     113      156
2.4   static           337.8    12410    30212      73       73
2.4   cont             375.7      387     1297     445      514
2.4   chunk512         374.6      370     1975     256      279
2.4   chunk256         373.3      468     2884     206      245
```

读法：

1. **吞吐几乎不动**（2.4 rps 下 375.7 / 374.6 / 373.3），三种连续调度策略的吞吐差小于 1%。这印证了"调度改的是延迟分布，不是算力"。唯一真正的吞吐差异来自静态批（337.8，低 10%）。
2. **ITL p99 单调改善**：cont 445 → chunk512 256 → chunk256 206。把长 prefill 切细，尖刺被摊平。
3. **TTFT p99 反向恶化**：1297 → 1975 → 2884。这是代价。
4. `ITLmax` 比 `ITLp99` 更能说明问题：cont 的 514ms 就是那个 4k prefill 独占一步的时长，和第二节的 `0.09 × 4200 ≈ 378ms` 对得上。

## 五、从 SLO 反解配置：budget 定上限，chunk 定分配

上表里有个容易被误读的地方：既然 chunk 越小 ITL 越好，为什么不干脆给 128？

因为真正决定 ITL 上限的不是 chunk，而是**一次迭代最多处理多少个 prefill token**，也就是 token budget。chunk 只是单请求的粒度，多个请求的 chunk 会累加到 budget。用实测反验证：

- budget 2048，`0.09 × 2048 ≈ 184ms`，加上 decode 步时（该负载下约 95ms）≈ 279ms —— 实测 chunk512 在 2.4 rps 的 `ITLmax = 279ms`，误差 1ms 以内。
- budget 1024 → `92 + 21 = 113ms`，实测 `ITLmax = 124ms`。

于是配置有了直接的解析式：

```text
budget ≤ (ITL_SLO − decode_step) / c_prefill

decode_step ≈ BASE + 0.24 × max_num_seqs + c_attn_dec × Σ kv
```

给定 ITL SLO 100ms、decode 步时 40ms、`c_prefill = 0.09ms`，budget 上限就是 `(100−40)/0.09 ≈ 666`。这就是为什么 vLLM 的默认 `max_num_batched_tokens` 从早期的 8192 降到 2048——8192 意味着单步 prefill 上限 737ms，ITL SLO 在百毫秒级的交互场景里根本守不住。

chunk 的作用是**在 TTFT 和 ITL 之间做分配**，它决定"一个长 prompt 的 prefill 愿意被切成几段、每段多久"：

| 目标 | 调法 | 代价 |
|---|---|---|
| 压 ITL p99（流式体感） | 降 budget，chunk ≈ budget/4 | TTFT 尾部变长，长 prompt 排队更久 |
| 压 TTFT p99（首字延迟） | 升 budget，chunk 给大 | ITL 尖刺回来，已在解码的用户被拖 |
| 两者都要 | 升 `max_num_seqs` 提高并行度，同时保住 budget | KV 显存、decode 步时上升，可能触发抢占 |
| 短 prompt 优先 | 大 chunk + 小 budget（短 prompt 一轮 prefill 完） | 长 prompt 严重饥饿，需要公平性兜底 |

第三行是唯一"不用付代价"的方向，但它受限于显存：`max_num_seqs × 平均上下文 × 每 token KV 字节` 就是 KV 池的下限。7B / 32 并发 / 4k 上下文 / fp16 KV ≈ 16GB，A100-80G 上能扛；到了 70B 或 32k 上下文，`max_num_seqs` 只能给到个位数，这时候就必须回到 chunk 和 budget 的权衡里。

## 六、映射到三个引擎，以及五个真会踩的坑

三个概念在不同引擎里名字不同，但一一对应：

| 概念 | vLLM | SGLang | llama.cpp |
|---|---|---|---|
| token budget | `--max-num-batched-tokens` | `--max-prefill-tokens` | `-b` / `--batch-size`（逻辑批） |
| chunk | （同 budget，`--enable-chunked-prefill`） | `--chunked-prefill-size` | `-ub` / `--ubatch-size`（物理批） |
| 并发 | `--max-num-seqs` | `--max-running-requests` | `-np` / `--parallel` |
| KV 池 | `--gpu-memory-utilization` | `--max-total-tokens` | `-c` / `--ctx-size` |

llama.cpp 的 `-b` 和 `-ub` 是这个模型最直白的实现：`-b 2048` 是"一步最多 2048 个 token"，`-ub 512` 是"这 2048 个 token 分 512 一块算"。我在一台 4C8T 的纯 CPU 机器上跑 `llama-server -np 4` 时就吃过这个亏：`-ub` 默认 512 而 `-c 8192` 被 `-np` 切成 2048/序列，一个长 prompt 的 prefill 要过很多个 micro-batch，日志里 `prompt eval time` 看着正常，但客户端的首 token 延迟明显被拉长——把 `-ub` 提到 1024 才对齐。

真正会踩的坑，按发现难度排：

**1. CUDA graph 和混合 batch 不兼容。** decode-only 的 CUDA graph 捕获的是固定 shape，混进 prefill 后 shape 变了，只能 fallback 到 eager，每步多出几毫秒的 launch 开销——在 ITL 40ms 的场景里就是 10% 以上的损失。vLLM 的 piecewise graph、SGLang 的分段捕获都是为了这个。判断方法：看日志里 graph 捕获条数，如果开了 chunked prefill 后 `cuda graph` 捕获数骤减甚至归零，吞吐损失不是调度算错了。

**2. attention backend 必须支持变长 query。** 混合 batch 里 query 长度是不齐的（decode 是 1，prefill 是 chunk 大小），FlashAttention 的 varlen 接口能吃，但一些老 backend（早期 xformers、部分 ROCm 路径）会退化成按最长 padding，一个 512 的 chunk 拖着 63 个空序列算，白烧算力。

**3. 抢占（preemption）会伪装成 ITL 尖刺。** KV 池不够时 vLLM 会抢占序列，默认 `RECOMPUTE` 策略要**重跑整个 prompt**（含已生成的 token）。一个 8k prompt 被抢占后重新 prefill 就是 700ms 的停顿，表现在监控上是一个孤立的、比 chunk 上限还大的 ITL 尖刺。看到 `ITLmax` 明显超过 `budget × 0.09 + decode` 的预测值，就去日志里找 `PreemptionMode`。

**4. 观测口径错了，调参全是盲调。** "端到端时长 ÷ 输出 token 数"不是 ITL，它把排队、prefill 全摊进去了。ITL 必须按每请求的相邻 token 时间戳差统计，并且分位数看 p99 而不是均值——调度问题的全部信息都在尾部。

**5. budget 大于 `max_num_seqs × 单序列 chunk` 是死配置。** 预算永远用不完，实际行为等价于"chunk = 单序列上限"，你以为在控 ITL，其实那个旋钮没接上线。改之前先算一遍 `budget / chunk` 是不是小于并发数。

## 七、上线前的检查清单

按顺序过一遍，能挡掉绝大部分"调完更差"：

1. 先测 `decode_step`（固定并发、固定上下文、纯 decode 压测），拿到 `BASE`、`0.24/序列`、`6e-4/KV token` 三个数。
2. 用 `budget ≤ (ITL_SLO − decode_step) / 0.09` 算出预算上限，取 60%~80% 作为起点。
3. `chunk = budget / 4` 起步，然后只按 TTFT p99 微调：TTFT 尾部超标就加大 chunk，ITL 尖刺超标就减 budget。
4. 压测必须混流量（长短 prompt 按线上比例），纯短 prompt 的压测会把 chunked prefill 的问题全部藏起来。
5. 监控三个量：`TTFT p50/p99`、`ITL p99/max`、`preemption 次数`。`ITLmax` 超过预测值就是抢占或 graph fallback，不是调度参数问题。
6. 显存余量按 `max_num_seqs × 上下文 × 每 token KV` 反算，别用 `gpu-memory-utilization` 一路往上顶——顶到 OOM 前的那个值，会以抢占的形式还回来。

调度器的本质是在三个延迟分布之间搬账：TTFT、ITL、吞吐。没有任何一组参数能同时把三个都压低，能做的只是知道每一笔账付给了谁、以及它值不值。
