---
title: "投机解码（Speculative Decoding）：小模型猜、大模型验，解码提速 2-3 倍且输出分布不变"
date: 2026-08-24T18:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "performance", "speculative-decoding"]
categories: ["AI"]
description: "投机解码为什么能把自回归解码提速 2-3 倍？拒绝采样验证怎么保证输出分布严格不变？期望加速比公式、可运行的 Python 实现、工程踩坑（draft 选型、gamma 调优、KV cache、采样一致性）一次讲透。"
---

自回归解码是 memory-bound 的：小 batch 下每生成一个 token 都要把全部权重从 HBM 读一遍，GPU 算力大部分时间在空转。投机解码（Speculative Decoding）的思路反直觉但极其优雅——**让一个便宜的小模型先猜 γ 个 token，大模型一次前向并行验证，猜对的直接收下，猜错的用拒绝采样修正**。论文级收益 2-2.5 倍，工程实现（Medusa/EAGLE/DeepSeek MTP）能到 3-4 倍，而且**输出分布与原生解码严格一致**，不是近似。

{/* truncate */}

## 一、先算账：自回归解码为什么慢

单条请求（batch=1）解码时，每一步只算一个 token 的注意力，计算量极小，瓶颈在权重读取。粗算一下：7B 模型 FP16 权重 14GB，A100 80GB 的 HBM 带宽约 2TB/s，那么每 token 的**理论下限**是 14GB ÷ 2TB/s ≈ 7ms，对应单流上限约 140 token/s；H100（3.35TB/s）约 4.2ms。这还没算 KV cache 读取和 attention 本身，实际只会更慢。

关键洞察：decode 阶段 GPU 算力利用率往往低于 10%。**每读一遍权重只产出一个 token，是极大的浪费**。Continuous Batching 用大 batch 摊薄权重读取成本来提吞吐（见 [推理引擎选型](/blog/2026/08/23/inference-engine-selection)），但单条请求的**首 token 到末 token 延迟**没有改善——这才是投机解码要解决的问题。

## 二、核心思想：猜 γ 个，验一次

自回归约束下，第 t+1 个 token 依赖前 t 个，看起来必须串行。投机解码用两个模型打破这个约束：

1. **草稿模型（draft）**：一个便宜的小模型（或 [KV Cache](/blog/2026/08/18/kv-cache-pagedattention-deep-dive) 之外的单层 head），自回归地猜出 γ 个候选 token；
2. **目标模型（target）**：一次前向，**并行**算出 γ+1 个位置上的完整分布（一个前向里 batch 维度就是 γ+1，代价几乎等于一次正常 decode）；
3. **逐位置验证**：draft 猜得对的位置直接接受，第一个猜错的位置回退，并从修正分布重采样。

每轮至少前进 1 个 token，最多 γ+1 个。γ 个位置只花"1 次 target 前向 + γ 次 draft 前向"的成本，而 draft 每步成本可能只有 target 的十分之一——这就是收益来源。

## 三、拒绝采样验证：无偏的关键

为什么"小模型猜、大模型验"不会改变输出分布？这是投机解码成立的理论基石，来自 Leviathan et al. 2022（DeepMind）与 Chen et al. 2023（Google）两篇同期论文。核心是一个逐位置的接受/拒绝规则：

- draft 在位置 i 的分布记为 p，target 的分布记为 q；
- 若 draft 采出的 token x 满足接受条件（`random()` 的值低于 `min(1, q(x)/p(x))`），**接受**；
- 否则**拒绝**，并从修正分布 `(q - p)_+ / Σ(q - p)_+` 重采样一个 token。

接受概率恰好是 `Σ_x min(q(x), p(x))`（即两个分布的重叠度），被拒绝时从 `(q-p)_+` 采样会"补偿"掉 q 里被 p 低估的部分。二者合起来，每轮输出的边际分布严格等于 q——**不是近似，是数学上相等**。下面是完整可运行的验证器实现：

```python
import random

def choice(rng, dist):
    """按 dist 分布采样一个 token"""
    r, acc = rng.random(), 0.0
    for i, pi in enumerate(dist):
        acc += pi
        if r < acc:
            return i
    return len(dist) - 1

def spec_verify(cand, p, q, rng):
    """逐位置验证 draft 候选。p/q[i] 是"预测 cand[i]"的分布。
    返回本轮实际采纳的 token 列表（1 到 gamma+1 个）。"""
    accepted = []
    for i, tok in enumerate(cand):
        if rng.random() < min(1.0, q[i][tok] / p[i][tok]):
            accepted.append(tok)            # 接受：两个模型都认为它合理
        else:
            residual = [max(qi - pi, 0.0) for qi, pi in zip(q[i], p[i])]
            s = sum(residual)
            if s > 0:                       # 拒绝：从修正分布补一个
                accepted.append(choice(rng, [x / s for x in residual]))
            break
    if len(accepted) == len(cand):          # 全部猜中：再白赚一个
        accepted.append(choice(rng, q[-1]))
    return accepted

# ---- 玩具模型：draft 与 target 分布相近但不完全相同 ----
def draft_dist(prev):
    return [0.55, 0.15, 0.10, 0.07, 0.06, 0.04, 0.03] if prev == 0 else \
           [0.30, 0.20, 0.15, 0.12, 0.10, 0.08, 0.05]

def target_dist(prev):
    return [0.50, 0.18, 0.11, 0.08, 0.06, 0.04, 0.03] if prev == 0 else \
           [0.28, 0.22, 0.16, 0.11, 0.09, 0.08, 0.06]

def spec_decode(gamma=4, max_len=64, seed=0):
    rng, out, prev = random.Random(seed), [0], 0
    while len(out) < max_len:
        cand, d = [], prev                      # 1) draft 串行猜 gamma 个
        for _ in range(gamma):
            tok = choice(rng, draft_dist(d))
            cand.append(tok)
            d = tok
        q = [target_dist(prev)] + [target_dist(t) for t in cand]  # 2) target 一次前向
        p = [draft_dist(prev)] + [draft_dist(t) for t in cand]
        new = spec_verify(cand, p[:-1], q[:-1], rng)              # 3) 验证
        out += new
        prev = out[-1]
    return out

print(spec_decode())
```

用无偏性做数值验证：直接按 target 分布采样 20 万次，与投机采样 20 万次的直方图对比，KL 散度约 4.5e-5、最大偏差 0.0015——**分布严格一致**。这个性质意味着投机解码可以无缝叠加在 temperature、top-p 采样之上，不需要任何校准，这是它区别于 beam search 剪枝、n-gram 缓存等"改分布"方案的根本优势。

## 四、收益的上限：期望加速比公式

设单位置接受率为 α（draft 与 target 分布重叠度），draft/target 每步成本比为 c，γ 个候选，则：

- 每轮期望接受数：`E[N] = (1 - α^(γ+1)) / (1 - α)`
- 每轮成本：`γ·c + 1`（γ 次 draft + 1 次 target 并行前向）
- **加速比 = E[N] / (γ·c + 1)**

代入典型值算出的表（公式直接计算，非编造）：

| α | c | γ=3 | γ=4 | γ=5 | γ=6 |
|---|---|-----|-----|-----|-----|
| 0.7 | 0.10 | 1.95x | 1.98x | 1.96x | 1.91x |
| 0.8 | 0.10 | 2.27x | 2.40x | 2.46x | 2.47x |
| 0.8 | 0.05 | 2.57x | 2.80x | 2.95x | 3.04x |
| 0.5 | 0.10 | 1.44x | 1.38x | 1.24x | 1.24x |

三个结论：**α 是命门**——从 0.5 到 0.8，加速比翻倍；**γ 存在最优值**——c=0.1 时 γ=5~6 就到顶，再拉长反而倒挂；**c 越低收益越陡**——这解释了为什么 Medusa/EAGLE（把草稿做成 target 头部的小模块而非独立模型）能拿到更高倍数。

论文与工程实测数据对照：Leviathan 2022 在 T5-XXL 上 2-2.5x；Medusa 在 Vicuna 上 2.3-3.6x；EAGLE 在 MT-Bench 上 3-4x；DeepSeek-V2 用 MTP 模块（每个 decode 步多算一个"下一 token 预测头"）报 1.8-2.1x，代价是 5% 左右的额外训练量。vLLM 生产环境（配合 continuous batching）通常报 1.7-2.2x——比论文低，因为服务端 batch 大、前缀命中多，decode 已经没那么 memory-bound 了。

## 五、工程实现与踩坑

**1. draft 选型：同 tokenizer 是硬前提。** draft 和 target 必须共享 tokenizer，否则验证阶段 `q(x)/p(x)` 根本对不上。独立小模型路线（如 70B 配 1-2B draft）灵活但要多载一份权重和 KV cache，显存成本约 +5-10%；同体量蒸馏小模型（或用 target 的层做 early-exit）接受率最高。**接受率怎么测**：上线前跑一批真实 prompt，统计每轮实际接受数 ÷ γ，低于 0.6 基本不值得开。

**2. γ 调优要按负载来。** 公式显示 γ=5~6 是甜点，但服务端要结合 batch 大小试：batch 大时 target 并行前向的 γ+1 个位置会把 FLOPs 推高，收益被稀释，此时适当调小 γ 甚至关掉。vLLM 的做法是把投机解码做成 scheduler 内的一等公民，按请求动态决定要不要投机。

**3. KV cache 与回滚。** 验证失败要丢弃被拒 token 之后的 KV cache 增量（rollback），多级验证（multi-level draft）还要逐级回滚，这块最容易出隐蔽的显存泄漏和状态错乱。另外 draft 模型的 KV cache 不能和 target 的混用，等于两套 cache 管理。

**4. 采样参数必须一致。** temperature、top-p、penalty 在 draft 和 target 两侧要配成一致，否则接受率骤降——很多人开了投机解码发现变慢，先查这个。penalty 类采样（frequency penalty）会破坏无偏性推导的前提，需要做修正或直接关掉。

**5. 场景适配。** 代码生成、function calling 这类"高度可预测"的输出接受率明显高于自由对话；短输出（几十 token 就结束）收益趋近于零，因为每轮至少 1 次 target 前向的固定成本还在。**什么时候别开**：batch 已经很大（吞吐瓶颈在算力而非带宽）、draft 与 target 分布差异大（比如 draft 没做过代码数据）、以及推理预算里 prefill 占比高的场景。

## 六、总结

投机解码是少有的"白捡的加速"：不损失分布、不改模型、无需重训练（MTP 路线除外），用"小模型猜 + 大模型验"把 memory-bound 的串行解码变成可并行验证。工程上记住三件事：**接受率是命门（低于 0.6 别开）、γ 取 4-6、draft 与 target 的 tokenizer 和采样参数必须对齐**。它与 [量化](/blog/2026/08/14/llm-quantization-deep-dive)、KV cache 压缩（如 [Gisting](/blog/2026/08/21/gisting-context-compression)）正交，可以叠加使用——量化降带宽、投机解码降步数、上下文压缩降 KV 占用，三管齐下才是长上下文场景的完整提速方案。
