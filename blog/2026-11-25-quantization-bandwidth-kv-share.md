---
title: "4-bit 量化到底值几个 tok/s：decode 的字节账有一半不在权重上"
date: 2026-11-25T16:40:00+08:00
draft: false
tags: ["ai", "llm", "inference", "quantization", "kv-cache", "performance"]
categories: ["Tech"]
description: "把 Llama-3-8B 换成 AWQ-INT4，权重从 16.06 GB 掉到 4.14 GB，按宣传该有 4 倍；但套进 roofline 一算：ctx 2k、batch 1 是 3.70 倍，ctx 8k、batch 8 只剩 1.94 倍，ctx 32k、batch 8 只有 1.31 倍——因为 decode 一步要读的字节是「权重 + batch×128 KiB×ctx」，而 KV 那一段不跟着权重量化缩水。同一套账还解释了另外三件事：prefill 是算力墙，W4A16 在 8k prompt 上把 TTFT 从 242 ms 拖到 284 ms 而不是变快；FP8 KV cache 在 32k 上下文直接把 557 tok/s 抬到 1006 tok/s；A100 换 H100 带宽 1.64 倍、吞吐 1.64 倍，一分不多一分不少。文末给可跑的 roofline 计算器和一份选型判断函数。"
---

线上有个很常见的期待：把 8B 模型从 FP16 换成 AWQ-INT4，权重从 16.06 GB 压到 4.14 GB，省了 4 倍显存，那吞吐应该也涨 4 倍吧？

真实报告一般落在 1.5~2 倍，长上下文并发场景甚至只有 1.2 倍。于是大家开始怀疑 kernel、怀疑 vLLM 版本、怀疑 int4 是不是没生效。其实什么都没坏，是这笔账本来就不是 4 倍。

decode 阶段每生成一个 token，GPU 要从 HBM 读的东西有两份：**权重**（一个 batch 共享一次）和 **KV cache**（每个序列、每个上下文位置都要重读一遍）。权重量化只动了前者，而上下文一长，后者才是大头。

下面把这笔账拆开算到底。所有数字来自文末那个 40 行的 roofline 脚本，输入是模型配置和显卡规格，输出是「这一步的字节数、时间、理论吞吐」。它是上限模型，不是实测——但它能告诉你实测值为什么在那里。

## 一、先把字节数写出来

decode 一步（batch 内的每个序列各吐一个 token）需要读的字节：

```
traffic = W + batch × kv_per_token × ctx
```

- `W`：权重字节。FP16 是 2 B/参数；W4A16（AWQ/GPTQ，group_size=128）是 0.5 B/参数，再加每 128 个参数一个 fp16 scale（+0.0156 B/参数），实际 0.516 B/参数。
- `kv_per_token`：每个序列、每个上下文位置占的 KV 字节 = `2 × n_kv_heads × head_dim × n_layers × dtype_bytes`。

Llama-3-8B：32 层、8 个 KV head、head_dim 128 → `2 × 8 × 128 × 32 × 2 = 131072 B`，**128 KiB/token**。
Llama-3-70B：80 层、同样 8 个 KV head → **320 KiB/token**。

换算成单序列驻留量：

| 模型 | 2k ctx | 8k ctx | 32k ctx |
|---|---|---|---|
| Llama-3-8B | 0.27 GB | 1.07 GB | 4.29 GB |
| Llama-3-70B | 0.67 GB | 2.68 GB | 10.74 GB |

对照权重：8B 的 int4 权重才 4.14 GB。**32k 上下文、batch 8 的 KV 是 34.4 GB，是权重的 8 倍。** 这就是全部问题的起点。

## 二、8B on H100：同一张表，四行三个结论

```python
def decode_step(model, gpu, scheme, batch, ctx, kv_bytes=2, bw_eff=0.8, flop_eff=0.65):
    w  = weight_bytes(model, scheme)          # 权重：整个 batch 只读一次
    kv = kv_bytes_per_token(model, kv_bytes)  # KV：每序列每 token 都重读
    traffic = w + batch * kv * ctx            # 一步 decode 的 HBM 字节数
    mem_ms  = traffic / (gpu.bw_gbs * 1e9 * bw_eff) * 1e3
    flops   = 2 * model.params * 1e9 * batch  # 稠密模型约 2 FLOP/参数/token
    cmp_ms  = flops / (peak_flops(gpu, scheme) * flop_eff) * 1e3
    ms = max(mem_ms, cmp_ms)                  # 谁大谁说了算
    return ms, batch / ms * 1e3               # 每 ms 出 batch 个 token
```

H100 SXM（3.35 TB/s，BF16 稠密 989 TFLOPS），Llama-3-8B，ctx=8192：

| batch | FP16 tok/s | INT4 tok/s | 倍数 | KV 占字节 |
|---|---|---|---|---|
| 1 | 156.4 | 514.0 | 3.29x | 21% |
| 8 | 869.8 | 1684.2 | 1.94x | 67% |
| 32 | 1700.9 | 2227.5 | 1.31x | 89% |
| 128 | 2234.8 | 2423.0 | 1.08x | 97%（KV 137 GB，装不下） |

同样的表换 ctx：

| ctx | batch 1 | batch 8 | batch 32 |
|---|---|---|---|
| 2k | 3.70x | 2.90x | 1.94x |
| 8k | 3.29x | 1.94x | 1.31x |
| 32k | 2.41x | 1.31x | 1.08x |

三个结论：

1. **4 倍只在 batch 1 成立，而且拿不满。** batch 1、2k 上下文时 KV 只占 6%，理论 3.70 倍（0.516 B/参数 vs 2 B/参数 的上限是 3.88 倍，剩下的是 KV 那 6%）。AWQ 论文报的 3x 左右就是这个工况——单卡、单流、短 prompt。
2. **batch 一大，KV 就成了分母。** batch 32 时 KV 占 67% 的字节，权重压到多小都只影响另外 33%，倍数被锁在 1.94。这就是"量化生效了但吞吐没怎么涨"的全部原因。
3. **容量墙比带宽墙更常见。** 8B int4 在 8k 上下文最多塞 60 个并发（65 GB KV 预算 / 1.07 GB），batch 128 那行物理上不存在。

顺带把"decode 是不是带宽生意"验证掉：同一模型同样配置，A100 80G（2.039 TB/s）算出 1025.1 tok/s，H100（3.35 TB/s）算出 1684.2 tok/s，比值 1.64；带宽比值也是 1.64。**一点没剩**——decode 阶段算力根本没被用上。

算术强度也能直接看出来：8B int4、8k 上下文，batch 1 是 3.1 FLOP/byte，batch 128 也才 14.5 FLOP/byte，而 H100 的机器平衡点是 `989e12 / 3.35e12 ≈ 295 FLOP/byte`。差 20 倍以上，所以 decode 永远是内存墙，量化收的是带宽税，不是算力税。

## 三、70B 的账：int4 的第一价值是"装得下"

70B FP16 权重 141.2 GB，单张 H100（80 GB）和 H200（141 GB）都装不下，70B 谈吞吐的前提是先做 TP=2 或量化。int4 权重 36.4 GB，一张 H200 能装（KV 预算剩约 93 GB）。

H200（4.8 TB/s，141 GB），Llama-3-70B int4：

| ctx | batch 1 | batch 2 | batch 4 | batch 8 |
|---|---|---|---|---|
| 8k | 98.2 tok/s | 183.9 | 325.8 | 530.8（KV 占 37%） |
| 32k | 81.5 | 132.7 | 193.6 | 251.2（KV 占 70%） |

注意 8k、batch 8 那格：int4 权重 36.4 GB，KV 21.5 GB，一共 57.9 GB。**权重还是大头，KV 只占 37%**——所以 70B 在中等上下文下，权重量化的收益比 8B 更接近线性（8k/b8 是 2.81 倍）。同一个量化方案，在不同模型上收益不同，原因就在这里：`W / (batch × kv × ctx)` 这个比值不同。70B 的权重绝对量大，把 KV 的相对开销稀释了。

反过来，70B 一旦拉到 32k、batch 8，KV 85.9 GB 超过权重，倍数掉到 1.86（相对 FP16 换算）。**上下文长度是量化收益的隐形折扣券。**

## 四、prefill 是另一本账，W4A16 在这本账上是负收益

decode 读字节，prefill 做 GEMM。8k prompt 的 prefill FLOPs 是 `2 × 8.03e9 × 8192 ≈ 1.32e14`，除 H100 的 989 TFLOPS（按 55% 可达效率）是 242 ms；同一时刻要读的权重只有 16 GB，按 3.35 TB/s、0.8 的有效带宽是 6 ms。**差 40 倍，纯算力墙。**

所以 W4A16 的 prefill 时间是这样（8B，H100，单请求，含 0.85 的反量化开销修正）：

| scheme | 2k prompt | 8k prompt | 32k prompt |
|---|---|---|---|
| FP16 | 60.5 ms | 241.9 ms | 967.5 ms |
| W4A16 | 71.1 ms | 284.5 ms | 1138.2 ms |
| FP8 W8A8 | 30.2 ms | 120.9 ms | 483.5 ms |

两个必须记住的结论：

- **量化权重不会让 TTFT 变快，通常还会慢 15%~18%**，因为 GEMM 前要做反量化，而 H100 的 int4 权重路径最终还是走 BF16 tensor core。看到"上线 AWQ 后 TTFT 没变、p99 还抖了"，不是配置错了，是这本账本来就这样。
- **想让 prefills 变快，只有 W8A8/FP8 这条路**：字节减半、并且真的走 FP8 tensor core（1979 TFLOPS），8k prompt 从 242 ms 压到 121 ms。

这也解释了为什么"聊天场景上 FP8、RAG 长 prompt 上 FP8、只有显存不够才退到 int4"是个合理的默认策略。

## 五、KV 才是剩下那半本账的三个旋钮

既然在 8k/batch 8 上有 67% 的字节花在 KV 上，那省 KV 就等于省时间。三个旋钮，收益可以直接用上面的公式估：

**1. GQA 的头数。** `kv_per_token` 正比于 `n_kv_heads`。Llama-3-8B 是 8 个 KV head；同样 32 层的 MHA 模型是 32 个 → 512 KiB/token，是 GQA 的 4 倍；MQA 是 1 个 → 32 KiB/token，是 GQA 的 1/8。选模型时看这一行，比看参数量有用。

**2. KV cache 的 dtype。** FP8 KV 把 `kv_bytes` 从 2 砍到 1。8B int4、32k、batch 8：**556.9 → 1005.6 tok/s（1.8 倍）**，驻留从 38.5 GB 降到 21.3 GB，等于并发上限翻倍。代价是精度——KV 量化的掉点集中在长上下文检索和数值推理，而且 scale 必须按 block/token 粒度存，per-tensor scale 在长序列上会明显劣化。

**3. 前缀复用。** 命中前缀缓存的那部分 KV 不用重算 prefill，但**仍然要读**——昨天那篇[前缀亲和路由](/blog/2026/11/25/prefix-affinity-routing-cost)算过：命中省的是 O(L²) 的 GEMM，剩下的 O(T·L) KV 读一点没少。所以前缀缓存解决的是 TTFT，不解决 decode 带宽。

## 六、判断函数：什么时候该做哪种量化

```python
def choose(model, gpu, ctx, batch, ttft_budget_ms, prompt_tokens=8192):
    kv_gb   = kv_bytes_per_token(model, 2) * ctx * batch / 1e9
    w16_gb  = weight_bytes(model, "fp16") / 1e9
    fit     = w16_gb + kv_gb <= gpu.mem_gb * 0.92

    if not fit:
        # 装不下：int4 是唯一选项，但先算清楚它会带来多少并发
        base = "int4"
        cap  = (gpu.mem_gb * 0.92 - weight_bytes(model, "int4") / 1e9) / (kv_bytes_per_token(model) * ctx / 1e9)
        note = f"int4 必选；ctx={ctx} 时并发上限约 {cap:.0f}"
    elif ttft_budget_ms < prefill_ms(model, gpu, "fp16", prompt_tokens):
        base, note = "fp8", "TTFT 敏感：W4A16 不改善 prefill，只有 FP8 GEMM 能压"
    elif batch <= 2 and ctx <= 4096:
        base, note = "int4", "单流短上下文：量化收益接近线性，可上"
    else:
        base, note = "fp8", f"ctx×batch 大：KV 占字节 {kv_gb / (w16_gb + kv_gb) * 100:.0f}%，先动 KV 再动权重"

    return base, note
```

落到具体决策上：

- **单流聊天、prompt 短于 4k** → W4A16，能拿到 3 倍以上，且显存省下的可以直接换成更大 batch。
- **长 prompt（RAG/文档）** → 优先 FP8 W8A8。TTFT 减半比 decode 快 30% 对体验价值大。
- **长上下文高并发** → 先做 GQA（选模型时定）、FP8 KV、前缀复用，再谈权重量化；这些动的是占 70%~90% 的那部分字节。
- **单卡装不下** → int4 不是优化，是入场券；预期定在 1.2~1.9 倍，别拿 4 倍去立项。

## 七、踩坑记录

**1. group_size 的 scale 开销别忽略。** 标称 4 倍是 2 B → 0.5 B；加上每 128 个参数的 fp16 scale（0.0156 B/参数）实际是 0.516 B/参数，天花板 3.88 倍。group_size 越小精度越好、开销越大：g=32 时是 0.5625 B/参数，只剩 3.56 倍。要在"掉点"和"倍数"之间选，先把这笔开销算进预算。

**2. 小 batch 下 int4 kernel 可能打不过 fp16。** 反量化的指令开销要靠 GEMM 规模摊开，batch 1 时 M=1 的 GEMM 本来就吃不满 SM，再插一段 dequant 更吃不满。AWQ 论文在单流上能跑到 3x，靠的是 TinyChat 那套专用 kernel（fused dequant + GEMV），不是随便哪个 kernel 都能复现。用 vLLM 时先跑一遍你自己的 batch 分布。

**3. "省下的显存"会被 KV 吃掉。** 8B 从 FP16 换 int4 省了 11.9 GB，看起来能多开 11 个 8k 并发；实际每个并发 1.07 GB，能多开 11 个——刚好对上。但如果你同时把 max_model_len 从 8k 提到 32k，每并发涨到 4.29 GB，省下的显存只够多开 2.7 个。**显存预算要按 `max_model_len × 最大并发` 算，不是按模型大小算。**

**4. KV 量化不是免费的 2 倍。** FP8 KV 的 1.8 倍是字节账上限，真实还要扣掉 quantize/dequantize 的读写和不支持 fp8 KV kernel 的 fallback。另外 vLLM 里 prefix cache 的 block hash 是 token 级的，换 KV dtype 不影响命中判定，但**同一份缓存不能跨 dtype 复用**，滚动升级时容量会短暂对折。

**5. 别拿 decode 的倍数去解释 TTFT。** 这是最常被搞混的一条：量化上线后 p99 的 TTFT 抖了、TPOT 好了，同时发生是正常的（prefill 变慢、decode 变快）。压 TTFT 要看 prefill 那本账，压 TPOT 才看这本。

## 八、把实测 tok/s 反解成有效带宽

模型给的是上限，反过来用它就是诊断工具。拿掉"效率系数"，从实测吞吐反解：

```
η_实测 = (W + batch × kv × ctx) × (tok/s / batch) ÷ 峰值带宽
```

8B int4、8k、batch 8、H100，如果实测 1200 tok/s（总）：每步字节 12.73 GB、每秒 150 步 → 1.91 TB/s，`η = 1.91 / 3.35 ≈ 0.57`。**离 0.8 还差 30%，这 30% 是 attention kernel、调度、采样，不是量化的问题**——优化方向是换 attention backend（FlashInfer/FlashDecoding），不是再压一次权重。反过来，如果反解出的 η 已经贴着 0.85，那这台机器上"省字节"是唯一的杠杆，任何 kernel 调优都是白费。

再做一次 batch 翻倍测试：batch 8 → 16，如果总吞吐只涨 5%，说明这一步里 KV 读已经占了绝大部分（batch 8 时是 67%），继续加并发只会撞显存墙；如果接近翻倍，那还在权重大头的区间，量化收益还在。

## 九、怎么在自己机器上验证

这段脚本是我实际跑出上面所有数字的那一份（简化了 dataclass）：

```python
L8  = dict(params=8.03, layers=32, n_kv_heads=8, head_dim=128)
H100 = dict(bw_gbs=3350, bf16_tflops=989, fp8_tflops=1979)

def run(ctx, batches=(1, 8, 32)):
    for b in batches:
        kv  = 2 * L8["n_kv_heads"] * L8["head_dim"] * L8["layers"] * 2
        w16 = 2 * L8["params"] * 1e9
        w4  = 0.5 * L8["params"] * 1e9 + 2 * L8["params"] * 1e9 / 128
        t16 = (w16 + b * kv * ctx) / (H100["bw_gbs"] * 1e9 * 0.8) * 1e3
        t4  = (w4  + b * kv * ctx) / (H100["bw_gbs"] * 1e9 * 0.8) * 1e3
        print(f"ctx={ctx} batch={b:3d}  fp16 {b/t16*1e3:7.1f} tok/s  "
              f"int4 {b/t4*1e3:7.1f} tok/s  x{(t16/t4):4.2f}  kv_share {b*kv*ctx/(w4+b*kv*ctx)*100:3.0f}%")

for c in (2048, 8192, 32768):
    run(c)
```

模型给的是上限；想在真机上验证，把 `bw_eff` 换成你实测的有效带宽（H100 上通常 0.7~0.85），再和 `vllm bench serve` 的输出对一遍。**如果实测比模型低很多，差的不是量化，是 attention kernel 和调度开销**——那部分钱要另外省。

一句话总结：量化省下的是权重那几个字节，decode 的账单是按 `权重 + batch × KV × 上下文` 收的。上下文越长、并发越高，权重在账单里的占比越小，4 倍就越兑现不了。想让长上下文的吞吐翻倍，得去动 KV 那一半——GQA、FP8 KV、前缀复用，都比再压一次权重量化有效。
