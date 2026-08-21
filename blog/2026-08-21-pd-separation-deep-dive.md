---
title: "PD 分离架构：prefill 和 decode 拆到不同节点，Kimi 多扛了 75% 请求"
date: 2026-08-21T17:30:00+08:00
draft: false
tags: ["ai", "llm", "inference", "infra", "performance", "engineering", "vllm", "kv-cache"]
categories: ["AI"]
description: "prefill 算力密集、decode 带宽密集，塞在同一张卡上互相拖累。DeepSeek-V3 把两阶段拆到不同节点，Mooncake 靠 KVCache-centric 调度让 Kimi 多处理 75% 请求。拆解 KV 传输盈亏平衡、两级调度与踩坑清单，附可运行模拟器。"
---

PD 分离（Prefill/Decode Disaggregation）是这两年推理集群改造里回报最高的一步。DeepSeek-V3 技术报告在部署章节明确写了 "separates the prefilling and decoding stages"；Kimi 的 Mooncake 平台靠它多扛了 75% 的真实流量；vLLM、SGLang、NVIDIA Dynamo 都把它做成了一等公民。

但这项技术有个反直觉的点：**它几乎不提升峰值吞吐，买的是延迟的可控性**。vLLM 官方文档第一句就是 "Disaggregated prefill DOES NOT improve throughput"。本文拆解它为什么成立、KV cache 传输这笔账怎么算、两级调度怎么设计，最后给一个可运行的模拟器和一份踩坑清单。

{/* truncate */}

## 一、同一个 GPU 上的两个互斥需求

decode 每生成一个 token，都要把整个序列的 KV cache 从 HBM 读一遍，是**带宽瓶颈**；prefill 一次吃掉整段 prompt，是**算力瓶颈**（算术强度差了两个数量级，MFU 可以差 3 倍以上，推导见[推理性能 Roofline 建模](/blog/2026/08/07/llm-inference-performance-modeling)）。两者塞在同一张卡上，互相拖累：

1. **长 prefill 阻塞 decode，制造尾部延迟尖刺**。一个 32K 的 prefill 要 1 秒以上，期间正在 decode 的所有请求全部冻结。
2. **调参耦合**。TTFT 想要更大的 TP（并行度），decode 想要小 TP 减少通信开销；DP 度、chunk 大小、显存预算，全是两套最优解。
3. **显存账本冲突**。prefill 要为长 prompt 腾瞬时 KV 峰值，decode 需要大 batch 摊薄权重读取成本。

chunked prefill 能缓解，但 vLLM 文档的原话是 "in practice it's hard to figure out the correct chunk size value"——把两个阶段**物理拆开**，才是彻底的解耦。

DeepSeek-V3 的部署参数直接体现了这种独立演进：prefill 阶段最小单元 4 节点 32 卡，attention 用 TP4+SP+DP8、MoE 用 EP32，还专门部署了 32 个冗余专家；decode 阶段最小单元 40 节点 320 卡，DP80 + EP320，每张卡只放一个专家。两个池子的并行策略完全独立，各调各的。

## 二、KV cache 传输：这笔账怎么算

拆分之后，prefill 算完的 KV cache 必须搬到 decode 节点。先算数据量：70B、GQA-8（8 个 KV head、80 层、fp16），每 token 的 KV 是 2 × 80 × 8 × 128 × 2B ≈ 320KB。32K 上下文就是 10GB，128K 是 40GB。

传输还是重算？盈亏平衡点是个很干净的公式：

- 传输时间 = KV 字节数 ÷ 网络有效带宽
- 重算时间 = 2 × 序列长度 × 参数量 ÷ 有效算力

代入 128K 上下文、200Gbps IB（有效约 20GB/s）、8 卡 H100（约 50% MFU，4 PFLOPS）：传输 40GB ÷ 20GB/s ≈ 2 秒；重算 2 × 128K × 70B ÷ 4 PFLOPS ≈ 4.5 秒。**传输赢**。再看 4K 短请求：1.28GB ≈ 64ms 传输，重算约 140ms——传输仍然赢，但短请求的调度、握手、序列化固定开销占比太高，所以生产实践是：**短请求直接走 decode 节点本地 prefill，只有长请求才走 PD 分离**（vLLM 里对应 kv_both 角色）。

两个隐性前提值得一提：

- **MLA 是底气**。DeepSeek 的 MLA 把每 token 的 KV 压到约四分之一，传输成本同步下降，PD 分离才划算。
- **KV 传输早就不是"序列化成字节流"**。vLLM 把传输抽象成 Connector：LookupBuffer 提供 insert / drop_select（SQL 语义，insert 非阻塞、drop_select 阻塞），Pipe 是单方向 FIFO 的张量管道；NixlConnector 用 UCX + GDS 做 GPU 直读直写，Mooncake 甚至把集群里闲置的 CPU/DRAM/SSD 组织成 KV 缓存池，KV 不只在 GPU 间搬，还会分层落盘。

## 三、两级调度：路由 + SLO

PD 分离后调度变成两层：**全局 dispatcher** 决定请求去哪个 prefill 节点、KV 存哪里、decode 阶段去哪个 decode 节点；**节点内 scheduler** 继续做迭代级 continuous batching（机制见[Continuous Batching 深读](/blog/2026/08/11/continuous-batching-deep-dive)）。路由策略主流有两种：

- **time-based**：decode 请求在队列里等若干迭代再派发，凑批，vLLM 早期实现
- **request-based**：像 Mooncake 的 KVCache-centric scheduler，把"满足 SLO 前提下的有效吞吐"当目标函数，高负载时用预测性早期拒绝（early rejection）直接拒掉会拖垮系统的请求

Mooncake 论文的数字：模拟长上下文场景吞吐最高提升 525%，真实负载下 Kimi 多处理了 75% 的请求。DeepSeek-V3 分离部署后，端到端生成速度是 V2 的两倍以上。

但请记住那条反直觉结论：这些收益来自"两阶段各跑各的最优并行配置 + 延迟可控"，不是"把 prefill 挪走"本身。**TTFT 仍然由 prefill 队列决定，分离前后基本不变**——下面的模拟器会亲眼看到。

## 四、可运行模拟器

一个玩具级事件模拟（示意参数，非生产基准）：150 个请求泊松到达，prompt 4K~64K，统一生成 512 token。对比"8 卡合一"与"PD 分离"两种部署：

```python
"""合一 vs PD 分离：玩具级事件模拟（示意参数，非生产基准）"""
import random, heapq, statistics

random.seed(7)
PREFILL_F = 2.0e15     # prefill 有效算力（8 卡 H100，约 50% MFU），FLOP/s
DECODE_BW = 26.8e12    # 8 卡 HBM 聚合带宽，B/s
W_B = 140e9            # 70B fp16 权重字节数
KV_B = 64 * 1024       # 每 token KV 字节（GQA + FP8 量化后）
NET_BW = 20e9          # KV 传输有效带宽（200Gbps IB，约 80% 效率）

def prefill_s(seq):   return 2 * seq * 70e9 / PREFILL_F
def transfer_s(seq):  return seq * KV_B / NET_BW
def step_s(batch, max_seq): return (batch * W_B + batch * max_seq * KV_B) / DECODE_BW

def gen_reqs(n, rate):
    t, out = 0.0, []
    for _ in range(n):
        t += random.expovariate(rate)
        out.append((t, random.choices([4_000, 16_000, 32_000, 64_000], weights=[3, 4, 2, 1])[0], 512))
    return out

def simulate(separated, reqs):
    events = [(t, 'arrive', i) for i, (t, p, g) in enumerate(reqs)]
    heapq.heapify(events)
    state = {}                 # idx -> [arrive, seq, gen_left]
    pref_until = 0.0           # prefill 池被占用到何时
    decode_loop = False
    ttft, steps = {}, []
    while events:
        t, kind, idx = heapq.heappop(events)
        if kind == 'arrive':
            state[idx] = [t, reqs[idx][1], reqs[idx][2]]
            start = max(t, pref_until)
            pref_until = start + prefill_s(state[idx][1])
            heapq.heappush(events, (pref_until + (transfer_s(state[idx][1]) if separated else 0.0), 'ready', idx))
        elif kind == 'ready':
            ttft[idx] = t - state[idx][0]
            if not decode_loop:
                decode_loop = True
                heapq.heappush(events, (t, 'step', -1))
        elif kind == 'step':
            batch = [i for i, s in state.items() if s[2] > 0]
            if batch:
                dt = step_s(len(batch), max(state[i][1] for i in batch))
                if not separated and pref_until > t:
                    dt = max(dt, pref_until - t)   # 合一模式：prefill 冻结 decode
                for i in batch:
                    state[i][2] -= 1
                steps.append(dt)
                heapq.heappush(events, (t + dt, 'step', -1))
            else:
                decode_loop = False
    return ttft, steps

def report(name, ttft, steps):
    tt = sorted(ttft.values())
    p95 = lambda x: sorted(x)[int(len(x) * 0.95)]
    print(f"{name}: TTFT P50={tt[len(tt)//2]:.2f}s P95={p95(tt):.2f}s "
          f"| ITL 均值={statistics.mean(steps):.3f}s P95={p95(steps):.3f}s "
          f"| decode 总耗时={sum(steps):.0f}s")

reqs = gen_reqs(150, 0.5)
print(f"请求数={len(reqs)} 平均 prompt={statistics.mean(p for _, p, _ in reqs)/1000:.0f}K 生成=512 tok")
report("合一部署    ", *simulate(False, reqs))
report("PD 分离部署 ", *simulate(True, reqs))
```

真实运行输出（Python 3.11）：

```text
请求数=150 平均 prompt=21K 生成=512 tok
合一部署    : TTFT P50=4.43s P95=13.20s | ITL 均值=0.434s P95=0.796s | decode 总耗时=598s
PD 分离部署 : TTFT P50=4.46s P95=13.28s | ITL 均值=0.160s P95=0.452s | decode 总耗时=413s
```

机制看得很清楚：**TTFT 两侧几乎一样**（4.43s vs 4.46s，prefill 队列说了算），但分离后 ITL 均值掉到三分之一（0.434s → 0.160s），P95 从 0.796s 降到 0.452s，decode 侧总耗时少了 31%——尾部延迟和吞吐的改善来自"decode 不再被 prefill 冻结"。

## 五、vLLM 落地配置

vLLM 的 disaggregated prefill 目前是实验特性：跑两个实例（prefill instance / decode instance），通过 KV connector 传 cache：

```bash
# prefill 实例
vllm serve meta-llama/Llama-3.1-70B-Instruct \
  --kv-transfer-config '{"kv_connector": "NixlConnector", "kv_role": "kv_prefill", \
  "kv_buffer_device": "cuda", "kv_connector_extra_config": {"backends": ["UCX", "GDS"]}}'

# decode 实例
vllm serve meta-llama/Llama-3.1-70B-Instruct \
  --kv-transfer-config '{"kv_connector": "NixlConnector", "kv_role": "kv_decode", \
  "kv_buffer_device": "cuda", "kv_connector_extra_config": {"backends": ["UCX", "GDS"]}}'
```

NixlConnector 支持完全异步的 send/recv；也可以用 MooncakeConnector（接 Mooncake KV 池）、LMCacheConnector、FlexKVConnectorV1 等第三方 connector。请求侧一个容易漏的细节：prefill 和 decode 两个实例都要从 messages 渲染并 tokenize prompt，**decode 端应该复用 prefill 算好的 token id**，跳过这步：

```python
# 第一步：发 prefill，要求返回 token id
prefill = client.chat.completions.create(
    model=model, messages=messages,
    extra_body={"return_token_ids": True,
                "kv_transfer_params": {"do_remote_decode": True}},
)
ids = prefill.prompt_token_ids

# 第二步：decode 带着 KV 传输参数和 token id 去 decode 实例
decode = client.chat.completions.create(
    model=model, messages=messages, stream=True,
    extra_body={"kv_transfer_params": {"do_remote_prefill": True,
                                       "prompt_token_ids": ids}},
)
```

## 六、踩坑清单

1. **短请求别走 KV 传输**。调度、握手、序列化的固定开销吃利润，给 decode 节点配 kv_both 角色本地消化短请求。
2. **网络是硬约束**。KV 传输与训练/其他通信共用 IB，带宽要单列预算；GDS/UCX 零拷贝不是可选项，序列化走 CPU 内存的版本在 40GB 级 KV 面前直接崩。
3. **prefix caching 要叠加设计**。prefill 端命中 prefix 后 KV 更小、传输成本更低，但 decode 端也要能接受带 prefix 语义的 KV——两个池子的 cache 状态必须一致，否则命中率白算。
4. **故障恢复别裸奔**。KV 丢了不能假装没事：要么回源重新 prefill，要么降级为本地重算；vLLM 有专门的 KV Load Failure Recovery，生产必须验证这条路径。
5. **局部性/粘性**。Agent 多轮对话的续传请求要尽量路由到持有该请求 KV 的 decode 节点；扩缩容时 KV 分布要平滑迁移，否则缓存全部失效。
6. **最小部署单元很大**。DeepSeek-V3 的 decode 单元 40 节点起步，小团队先上 chunked prefill + prefix caching，等流量曲线出来再上 PD 分离。
7. **指标分开统计**。TTFT、ITL（TPOT）、goodput 各自监控，别用单卡利用率判断 PD 分离是否有效——它优化的恰恰是利用率之外的延迟分布。

## 参考

- [Mooncake: A KVCache-centric Disaggregated Architecture for LLM Serving](https://arxiv.org/abs/2407.00079)
- [DeepSeek-V3 Technical Report（3.4 部署章节）](https://arxiv.org/abs/2412.19437)
- [vLLM Disaggregated Prefilling（实验特性文档）](https://docs.vllm.ai/en/latest/features/disagg_prefill.html)
- 站内：[KV Cache 深度解析（PagedAttention/GQA/MLA）](/blog/2026/08/18/kv-cache-pagedattention-deep-dive) · [Continuous Batching 深读](/blog/2026/08/11/continuous-batching-deep-dive) · [Roofline 性能建模](/blog/2026/08/07/llm-inference-performance-modeling)
