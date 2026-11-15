---
title: "LLM 推理服务的过载保护：QPS 限流为什么一定失效，token 级准入控制怎么落地"
date: 2026-11-15T09:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "infra", "performance", "engineering"]
categories: ["Tech"]
description: "线上推理服务雪崩的典型形态不是 OOM，而是 P99 TTFT 从 300ms 涨到 40s、加机器无效、限流反而更糟。原因是被保护的资源不是 QPS 而是 KV token，而排队本身会让吞吐下降形成正反馈。本文用一个纯标准库的离散事件仿真（1 step = 10ms，TBUD=400 token-cost/step，KV 池 90k token）对比四种准入策略：无准入、固定并发上限、token 预扣、SLO 硬闸，给出真实跑出来的 goodput、TTFT p99、抢占次数与重试风暴下的劣化幅度。结论有两个反直觉：无准入策略的原始吞吐最高但 goodput 只有 0.20；参数越多的策略越容易调坏，SLO 硬闸反而跑输最朴素的 token 预扣。"
---

> 上一篇 [PD 分离](/blog/2026/11/14/pd-disaggregation-interview) 算的是「拆开之后账怎么记」，这篇算另一头的账：**过载的时候怎么不雪崩**。
>
> 这两件事在线上是同一场事故的两面。PD 分离让你能在饱和区多榨 30% 吞吐，但如果你没有准入控制，那个「饱和区」根本不可达——流量一冲，服务会自己掉进一个吞吐更低的稳定态，加机器也拉不回来。今天把这条正反馈拆开，并且给出四种准入策略的真实仿真对比。

{/* truncate */}

## 一、事故形态：不是 OOM，是「越忙越慢」

先说观测到的样子。某天下午的一次典型事故：

- 入口 QPS 从 300 涨到 900（三倍，没到容量估算的三倍余量）
- TTFT P50 从 200ms 涨到 2.5s，P99 从 300ms 涨到 **41s**
- TPOT（每 token 输出间隔）几乎没变，还是 10ms 左右
- GPU 利用率 100%，KV cache 使用率 100%，waiting queue 长度单调上涨，冲到 1700 之后再也不降
- 运维第一反应是「限流到 400 QPS」——结果 goodput 又掉了一半

最后一条是最反直觉的。限流本该保护服务，为什么 goodput 反而下降？因为**限流的单位选错了**。

## 二、为什么 QPS 和并发数都不是成本单位

一个 LLM 请求的成本是 `prompt_tokens + generated_tokens`（准确说是 prefill 的 O(prompt²) 部分加上 decode 的 O(seq) 部分乘 batch），不是「一次」。线上真实分布里，一个 80 token 的分类请求和一个 4000 token 的文档摘要请求，成本差 50 倍以上——而它们在 QPS 计数器里各算 1。

我用 lognormal（prompt 中位 570，输出中位 200，长尾到 4000/1200）做了个仿真，`lambda=60` 时的分布：

```text
prompt:  p50 = 572   p90 = 1157   p99 = 2059   max = 4000
output:  p50 = 199   p90 = 433    p99 = 808    max = 1200
单请求成本 p50 = 816 token-cost，p99 = 2335，P99/P50 = 2.9x
```

固定并发上限的问题就在这里：上限 100 个并发，在全部是便宜请求时是**严重欠载**（GPU 闲着），在全部是贵请求时是**10 倍过载**。它保护的是一个和真实瓶颈无关的量。

第二个更致命的原因：**排队会让吞吐下降**。

在传统服务里，队列长只是延迟高，吞吐不变甚至更高（批处理效应）。LLM 推理不是。KV 池是共享资源，队列长导致 batch 大，batch 大导致每个请求分到的 KV 变少，KV 满了触发抢占（preemption）→ 被抢占的请求 KV 全部丢弃 → 重新走一遍 prefill → 而 prefill 又要吃算力预算，挤掉别人的 decode。

于是形成一个闭环：

```text
队列变长 → batch 变大 → KV 打满 → 抢占 + 重算
    ↑                                    ↓
    └──── 有效吞吐下降 ←── prefill 挤占 decode ────┘
```

这个环一旦闭合，系统会稳定在「吞吐 60%、延迟 40 倍」的坏平衡点上。这是**双稳态**，不是线性劣化——所以你加 30% 机器解决不了，因为新机器的 KV 也会立刻被队列灌满。

## 三、仿真：四种准入策略，真实跑出来的数

模型定义（纯标准库，单文件可跑）：

- `1 step = 10ms`，引擎每 step 有 `TBUD = 400` 个 token-cost 预算
- prefill 1 token 计 1 单位，decode 每 step 计 1 单位（刻意简化，真实系统 decode 单位更贵，但不影响结论方向）
- KV 池 90k token，chunked prefill 单请求每 step 最多 512 token
- decode 优先调度（先给所有 decode 请求各 1 个 token，剩下的预算给 prefill）
- SLO：TTFT 不超过 1.0s 且 TPOT 不超过 80ms 的请求算有效 → **goodput = 有效完成数 / 到达数**

四种策略：

| 策略 | 准入判据 |
|---|---|
| `none` | 全收，装不下就排队（等价于「vLLM 默认等待队列 + 不设上限」） |
| `concurrency` | 运行 + 排队总数不超过 100（等价于固定 QPS/并发限流） |
| `token` | 预扣 `prompt + max_tokens`，超过 KV 的 95% 就拒绝 |
| `token_amort` | 预扣 `prompt + min(max_tokens, 320)`（按 P50 输出摊销） |

### 3.1 恒定负载扫描

每种策略跑 60 秒，同一随机种子：

| 到达率 | 策略 | 到达 | 拒绝 | 完成 | goodput | TTFT p50 | TTFT p99 | 引擎吞吐(tok/s) | 抢占次数 |
|---|---|---|---|---|---|---|---|---|---|
| 40 | none | 2367 | 0 | 2279 | 0.963 | 0.10s | 0.76s | 35599 | 105 |
| 40 | concurrency | 2367 | 137 | 2143 | 0.905 | 0.05s | 0.26s | 33517 | 1 |
| 40 | token | 2367 | 78 | 2201 | 0.930 | 0.05s | 0.28s | 33925 | 0 |
| 80 | none | 4770 | 0 | 2681 | **0.276** | 1.05s | 32.77s | **39150** | 770 |
| 80 | concurrency | 4770 | 2317 | 2356 | 0.494 | 0.06s | 0.67s | 35970 | 1 |
| 80 | token | 4770 | 1899 | 2753 | 0.577 | 0.16s | 0.80s | 38312 | 0 |
| 140 | none | 8297 | 0 | 2892 | **0.200** | 0.36s | **47.10s** | **39181** | **1017** |
| 140 | concurrency | 8297 | 5823 | 2374 | 0.284 | 0.07s | 0.95s | 36582 | 2 |
| 140 | token | 8297 | 5130 | 3036 | **0.361** | 0.29s | 1.08s | **39375** | 0 |

三个读数值得盯住：

**（1）无准入策略的引擎吞吐最高，goodput 最低。** `lambda=140` 时它跑到 39181 tok/s，是四种策略里最高的——因为它在疯狂地 prefill、抢占、重算，GPU 一刻没停。但 8297 个请求里只有 1660 个在 SLO 内完成，goodput 0.200。这就是「吞吐幻觉」：如果你只看 tokens/s 看板，过载的服务看起来健康得不得了。

**（2）固定并发上限被 token 预扣双向碾压。** 同一负载下 `concurrency` 的吞吐（36582）比 `token`（39375）低 7%，goodput（0.284）比它低 21%。既没保护住延迟，又白白拒了一堆本来能跑的请求。原因是它拒绝的对象是**随机的**——按到达顺序砍尾巴，而 `token` 拒绝的对象是**当前装不下的**。

**（3）token 预扣把抢占压到 0，代价是 3.3% 的误杀。** `lambda=40` 时 2367 个请求里拒了 78 个（全是 KV 处于 95%~100% 之间的倒霉请求），换来抢占从 105 次降到 0。这笔交易在 p99 上是划算的：0.76s 对 0.28s。

### 3.2 尖峰下的队列演化

同一尖峰（30rps 15s → 140rps 20s → 30rps 25s），每 5 秒采样一次：

| t | none: 运行 / 排队 / KV | token: 运行 / 排队 / KV |
|---|---|---|
| 15s | 69 / 0 / 66% | 69 / 0 / 66% |
| 20s | 136 / 470 / **100%** | 124 / 0 / 94% |
| 25s | 123 / 896 / 100% | 123 / 0 / 93% |
| 30s | 125 / **1372** / 99% | 127 / 0 / 92% |
| 35s | 125 / 1767 / 100% | 135 / 0 / 95% |
| 40s | 113 / **1690** / 100% | **70 / 0 / 62%** |

`none` 的队列在尖峰结束后还在涨（1690），因为积压的请求继续占着 KV，新请求继续进来排队——**尖峰结束后 20 秒都没恢复**。`token` 在 40s 时队列瞬间归零、KV 掉到 62%。

这一段是全文最有用的对照：**过载保护的真正价值不是「挡住请求」，而是保证系统在尖峰结束后能自己回来。**

### 3.3 重试风暴

这是最容易漏掉的一环。被拒绝的请求，客户端会重试（这里设 80% 概率重试，服务端建议退避 0.2/0.4/0.8s）：

| 策略 | 实际到达 | 其中重试 | 拒绝 | 完成 | goodput | TTFT p99 |
|---|---|---|---|---|---|---|
| concurrency | 8790 | 4772 | 6763 | 1928 | 0.219 | 0.40s |
| token | 7875 | 3964 | 5522 | 2272 | **0.289** | 0.67s |
| token_amort | 7904 | 4002 | 5587 | 2243 | 0.284 | 0.49s |

对照 3.2 无重试时 `token` 的 goodput 0.545：**重试把 goodput 砍掉 47%**。原始到达 3930 被放大到 7875，翻了一倍。而且注意 `concurrency` 的放大更严重（8790）——它的拒绝更随机，重试更容易再撞上拒绝，形成重试-拒绝的正反馈。

结论很硬：**准入控制必须自带「让客户端别再来了」的信号**。返回 429 + `Retry-After`（而不是 503），并且 Retry-After 要是服务端算出来的（基于当前队列长度和预估处理速率），不是拍脑袋的常量：

```python
def retry_after_seconds(queue_len: int, tok_per_s: float) -> int:
    # 队列里还有多少 token 要处理，除以引擎有效吞吐
    backlog = queue_len * AVG_COST_TOKENS
    return max(1, min(60, int(backlog / max(tok_per_s, 1) + 0.5)))
```

## 四、实现：一个 token 级准入器

核心只有三件事：**成本估算、预扣、结算**。

```python
import time
from collections import deque

AVG_COST_TOKENS = 800      # 滚动统计的单请求成本 P50，用于 Retry-After 估算
OUT_RESERVE = 320          # 输出预扣额度（约为线上输出长度 P50 的 1.6 倍）


def cost(prompt_tokens: int, max_tokens: int) -> int:
    """把请求翻译成 KV 预扣额度。prompt 立刻占 KV，输出按固定额度预扣。"""
    return prompt_tokens + min(max_tokens, OUT_RESERVE)


class KVAdmitter:
    def __init__(self, kv_tokens: int, headroom: float = 0.95):
        self.kv = kv_tokens
        self.headroom = headroom
        self.used = 0                       # 已预扣的 token 额度
        self.rejected = deque(maxlen=1000)  # 拒绝原因审计

    def try_acquire(self, prompt_tokens: int, max_tokens: int, now: float):
        c = cost(prompt_tokens, max_tokens)
        if self.used + c > self.kv * self.headroom:
            util = self.used / self.kv
            self.rejected.append((now, prompt_tokens, max_tokens, round(util, 3)))
            return None
        self.used += c
        return c

    def settle(self, quota: int, actual_generated: int, prompt_tokens: int,
               max_tokens: int) -> None:
        """请求结束时结算：预扣的额度还回去，只留真实消耗"""
        self.used -= quota
```

接入点在流式 handler 的 `try/finally` 里。这里有个必须踩过的坑：**客户端断连、超时、取消，都必须走到 `settle`**，否则预扣额度永久泄漏，跑几天之后准入器会以「KV 满」为由拒绝一切请求——而真实 KV 池是空的。这个 bug 我在 KV 池按请求计费的实现里见过两次，表现是「服务重启就恢复，不重启就越来越慢」。

```python
async def handle(req):
    quota = admitter.try_acquire(req.prompt_tokens, req.max_tokens, time.time())
    if quota is None:
        raise HTTP429(retry_after=retry_after_seconds(admitter.queue_len, engine.tok_s))
    try:
        async for chunk in engine.stream(req):
            yield chunk
    finally:
        admitter.settle(quota, req.generated, req.prompt_tokens, req.max_tokens)
```

如果引擎本身已经暴露了 KV 用量（vLLM 的 `vllm:kv_cache_usage_perc`、`vllm:num_requests_waiting`），更好的做法是**把准入器当成影子账本**：用真实指标做周期性校准，账本负责「在请求进来之前」就能算出拒绝，而不是等引擎 OOM。

```python
def calibrate(self, real_kv_used_tokens: int) -> None:
    """每 1s 用真实 KV 用量校准影子账本，防止慢漏"""
    drift = real_kv_used_tokens - self.used
    if abs(drift) > self.kv * 0.05:
        log.warning("admitter drift %+d tokens (%.1f%%)", drift, 100 * drift / self.kv)
    self.used = real_kv_used_tokens
```

## 五、两个负结果：别迷信「更聪明」的策略

仿真里我特意加了两个看起来更高级的策略，结果都**没跑赢最朴素的 token 预扣**。写出来是因为这比成功案例更值钱。

**负结果一：把输出预扣从 `max_tokens` 摊销到 P50，几乎没区别。** `token` 与 `token_amort` 在 `lambda=40` 时分别是 78 和 77 次拒绝，`lambda=140` 时 goodput 0.361 对 0.353（摊销还略差）。原因想通了很简单：稳态下在途预扣总量本来就约等于 KV 池实际占用，「保守 vs 摊销」只影响单个请求的准入边界，而瓶颈是总量。真正影响误杀率的是 `headroom` 这个参数，不是预扣口径。

**负结果二：加 SLO 硬闸（KV 用量超过 88% 就全拒）比精确预扣更差。** 尖峰场景下 goodput 0.484 对 0.545，掉了 11%。硬闸是「一刀切」，它在 88% 附近会同时拒掉便宜请求和昂贵请求，而精确预扣只拒「这一个装不下的」。**策略里可调阈值越多，你越可能把它调坏**——这条在限流、熔断、负载均衡上我被教育过很多次，准入控制也一样。

## 六、上线清单

监控（缺一不可，只有 QPS 和 GPU 利用率等于没监控）：

- `kv_cache_usage_perc` 的 P50/P99 — 稳态应该在 70~90%；长期贴 100% 说明准入太松或 headroom 太小
- `num_requests_waiting` — **这是最重要的一个**。健康状态它应该恒为 0 或个位数；一旦单调上涨且尖峰后不回落，就是雪崩前兆
- `preemption_rate` — 抢占次数 / 秒。大于 0 就要查，它意味着算力在重复做功
- `goodput` — 用业务侧的 TTFT/TPOT 阈值算，不要用引擎的 tokens/s
- 拒绝原因分布 — 按 `prompt_tokens` 分桶，如果拒绝集中在长 prompt 上，说明该做的是**大请求隔离**（单独队列/单独实例/离线批），而不是继续收紧阈值

容量规划：

- 容量单位用 `token-cost/s`，不是 QPS。用线上 P50 成本和 P99 成本分别算一遍，取 P99 口径的那个数当上限
- 峰值余量按「单请求成本 P99/P50（本文分布下是 2.9 倍）」准备，而不是按 QPS 峰值准备
- 压测必须测「突然放大 3 倍」而不是「缓慢爬坡」，因为雪崩是双稳态的，缓慢加压可以一直保持在线性区，永远测不出来

一个更基本的判断：如果 P99 TTFT 已经涨到 P50 的 100 倍以上，同时 TPOT 没变，那**不用怀疑，就是排队**。decode 优先的调度器会死死护住 TPOT（本文所有场景里 TPOT p99 都是 10ms，一次没变），代价全部由 TTFT 承担。这也是为什么只看「整请求延迟」的看板会骗人：健康时 e2e p99 就有 8 秒（1200 token 输出 × 10ms），雪崩时涨到 34 秒，你很难从 8 到 34 的跳变里读出「这是排队」还是「这是长输出」。

---

仿真代码在单个文件里，纯标准库，`python3 sim.py` 约 35 秒跑完全部四组场景。想改结论就改 `TBUD` 和 `KV` 两个常量——它们是这套系统里唯一真正重要的两个数。
