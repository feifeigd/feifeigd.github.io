---
title: "偏好优化训练课：DPO 的闭式解与它的三个隐性代价，GRPO 为什么敢不要 critic"
date: 2026-11-13T21:10:00+08:00
draft: false
tags: ["ai", "llm", "training", "finetuning", "preference-optimization"]
categories: ["Tech"]
description: "SFT 教模型说话，偏好优化才教它选哪个回答。DPO 把 RLHF 的 KL 约束解出闭式解，用一次监督式反向传播干掉 reward model 和 PPO；GRPO 则把 critic 换成组内均值基线。但两者的账都在细节里：DPO 的 margin 是 logprob 求和，于是长度成了隐式奖励；βΔ 一大梯度就指数衰减；GRPO 的组越大，全对全错的退化组越多。本文推导闭式解、给出梯度形式，附三段可直接运行的纯标准库数值实验（长度偏置放大 10 倍、β=1 时 Δ=10 梯度权重掉到 4.5e-5、p=0.05 时 G=16 有 44% 的组梯度为零），再列七条实战踩坑。"
---

SFT 之后模型的分布已经很窄了：它学会了"怎么回答"，但没学会"哪个回答更好"。偏好优化补的就是这一步——给定同一个 prompt 下的一对回答（chosen / rejected），把概率质量往人类偏好的那一侧搬。

2023 年之后这件事有两条主流路线：DPO 系列（DPO / IPO / ORPO / SimPO / KTO）和在线 RL 系列（PPO / GRPO / RLOO）。前者把 RLHF 化简成一次监督式训练，工程上便宜到可以在单机 8 卡上跑；后者保留了探索，效果上限更高但难调。这篇不写综述，只算三笔账：**DPO 到底在优化什么、它偷偷付了哪些代价、GRPO 去掉 critic 之后靠什么撑住方差**。每笔账都配可直接运行的数值实验。

{/* truncate */}

## 一、先把闭式解推出来：DPO 不是"近似"RLHF

RLHF 的目标是带 KL 约束的期望奖励最大化：

```text
max_π  E_{x~D, y~π(·|x)}[ r(x, y) ]  -  β · D_KL( π(·|x) || π_ref(·|x) )
```

这个目标有一个精确解。把它看成一个逐 prompt 的变分问题（对每个 x 单独求解，约束是概率归一化），拉格朗日一下就能得到：

```text
π*(y|x) = (1 / Z(x)) · π_ref(y|x) · exp( r(x, y) / β )
```

其中 `Z(x) = Σ_y π_ref(y|x) exp(r(x,y)/β)` 是配分函数。关键一步是**反解奖励**：

```text
r(x, y) = β · log( π*(y|x) / π_ref(y|x) ) + β · log Z(x)
```

注意 `β log Z(x)` 只跟 prompt 有关。把它塞进 Bradley-Terry 模型 `p(y_w ≻ y_l) = σ(r(y_w) - r(y_l))`，同一个 prompt 下的两项**相互抵消**，reward model 就消失了，只剩下策略本身的似然比：

```text
L_DPO(θ) = -E_{(x, y_w, y_l)} [ log σ( β·log(π_θ(y_w|x)/π_ref(y_w|x))
                                   - β·log(π_θ(y_l|x)/π_ref(y_l|x)) ) ]
```

这就是 DPO 全部的内容。它**不是** RLHF 的近似：在"BT 偏好模型 + KL 到参考分布"这套假设下，DPO 的最优解和 RLHF 的最优解是同一个点，只是路径不同——DPO 用离线 pair 做监督学习，PPO 在线采样再估梯度。

顺带说，这个推导也说明了数据侧的一条硬约束：**配分项能抵消，前提是 chosen 和 rejected 来自同一个 prompt**。如果你的 pair 是跨 prompt 拼出来的，或者 chosen 用了模板 A、rejected 用了模板 B，抵消就不成立，梯度是有系统偏置的。这个错误在自建数据集里非常常见。

## 二、梯度长什么样，以及三个隐性代价

对上面的损失求导，得到一个相当好读的形式（记 `Δ` 为隐式奖励差，即中括号里那一坨）：

```text
∇L = -β · σ(-β·Δ) · [ ∇log π_θ(y_w|x) - ∇log π_θ(y_l|x) ]
```

前一项 `β · σ(-βΔ)` 是一个**自适应权重**，它随偏好对"已经被分开了多少"而衰减。三个代价全从这一项和 Δ 的定义里长出来。

### 代价一：Δ 一大，梯度就指数消失

```python
import math
# 梯度权重 w = sigmoid(-beta * delta)
for beta in (0.01, 0.1, 1.0):
    print(beta, [round(1/(1+math.exp(beta*d)), 6) for d in (0, 2, 10, 50)])
```

实测（纯 Python，`math.exp`）：

```text
beta=0.01   Δ=0 5.0e-01 | Δ=2 4.95e-01 | Δ=10 4.75e-01 | Δ=50 3.78e-01
beta=0.1    Δ=0 5.0e-01 | Δ=2 4.50e-01 | Δ=10 2.69e-01 | Δ=50 6.69e-03
beta=1.0    Δ=0 5.0e-01 | Δ=2 1.19e-01 | Δ=10 4.54e-05 | Δ=50 1.93e-22
```

β=1 时，Δ 只要到 10，学习信号就掉到 5e-5 —— 相当于这一条样本被静音了。这不是 bug，而是 DPO 的设计意图（已经学会的样本不再训），但在工程上意味着：**β 同时是"约束强度"和"学习率调节器"**。很多人调 DPO 时把 β 从 0.1 改成 0.01 觉得"约束放松一点"，实际上顺手把有效学习率放大了 10 倍，然后怪 DPO 训崩。改 β 必须重扫 lr，这是两条耦合的旋钮。

### 代价二：Δ 是 logprob 的**求和**，长度因此成了隐式奖励

`log π(y|x) = Σ_t log p(y_t | y_1..y_{t-1})`。同样的"每 token 平均好 0.05 nats"，在长度 512 的回答上会变成 25.6 nats 的 margin：

```text
len=1    margin=  0.050  梯度权重=0.4988
len=8    margin=  0.400  梯度权重=0.4900
len=64   margin=  3.200  梯度权重=0.4207
len=512  margin= 25.600  梯度权重=0.0718
```

而人类标注数据的经验是：**chosen 平均比 rejected 长**（更完整、更有礼貌、更少一句话敷衍）。于是 DPO 学到的捷径里混进了"更长 = 更好"。这个现象不是猜测，用长度受控的评测（Length-Controlled AlpacaEval）去衡量时，DPO 相对 SFT 的胜率优势会大幅缩水——说明相当一部分"提升"其实是长度换来的。

下面这个玩具训练把机制摆在明面上：chosen 长 6 个 token、rejected 长 1 个 token，同一个 β、同一个学习率，只改归一化方式。

```python
import math, random
random.seed(0)

def log_softmax(zs):
    m = max(zs); lse = m + math.log(sum(math.exp(z - m) for z in zs))
    return [z - lse for z in zs]

def seq_logp(logits, toks):
    lp = sum(log_softmax(z)[t] for z, t in zip(logits, toks))
    return lp, lp / len(toks)          # (求和, 平均)

def margin(pw, tw, pl, tl, refw, refl, mode="sum"):
    k = 0 if mode == "sum" else 1      # 0: logprob 求和, 1: 按长度平均
    return (seq_logp(pw, tw)[k] - seq_logp(refw, tw)[k]) - \
           (seq_logp(pl, tl)[k] - seq_logp(refl, tl)[k])

def toy(Lw=6, Ll=1, beta=0.1, lr=0.5, steps=200, mode="sum"):
    V = 3
    pw = [[random.uniform(-1, 1) for _ in range(V)] for _ in range(Lw)]
    pl = [[random.uniform(-1, 1) for _ in range(V)] for _ in range(Ll)]
    refw, refl = [r[:] for r in pw], [r[:] for r in pl]   # 冻结的参考模型
    tw, tl = [0] * Lw, [1] * Ll
    nw = 1.0 if mode == "sum" else 1.0 / Lw
    nl = 1.0 if mode == "sum" else 1.0 / Ll
    for _ in range(steps):
        m = margin(pw, tw, pl, tl, refw, refl, mode)
        g = -beta / (1 + math.exp(beta * m))              # dL/dmargin
        for i, t in enumerate(tw):                        # 推高 chosen
            sm = log_softmax(pw[i])
            for v in range(V): pw[i][v] -= lr * g * nw * ((v == t) - math.exp(sm[v]))
        for i, t in enumerate(tl):                        # 压低 rejected
            sm = log_softmax(pl[i])
            for v in range(V): pl[i][v] += lr * g * nl * ((v == t) - math.exp(sm[v]))
    return seq_logp(pw, tw), seq_logp(pl, tl)

for mode in ("sum", "mean"):
    (c_sum, c_mean), (r_sum, r_mean) = toy(mode=mode)
    print(f"[{mode:4}] chosen logp sum={c_sum:6.3f} mean={c_mean:6.3f} | "
          f"rejected logp sum={r_sum:6.3f} mean={r_mean:6.3f}")
```

实测输出：

```text
[sum ] chosen logp sum=-1.594 mean=-0.266 | rejected logp sum=-5.202 mean=-5.202
[mean] chosen logp sum=-4.365 mean=-0.727 | rejected logp sum=-8.445 mean=-8.445
```

同一个目标、同样的步数，求和归一化把 chosen 的**每 token** 概率推得更高（-0.266 vs -0.727），代价是 rejected 被压得更狠。注意这个方向不是"求和更糟"——它说明两件事：求和归一化让长度更长的一侧获得更大的有效步长；一旦你偏好短回答或者要求长度受控，就得用平均（SimPO / R-DPO 的路子），否则训练动力和你的业务指标是两套东西。

### 代价三：离线 pair 没有探索，参考分布成了天花板

DPO 的梯度只作用在训练集覆盖的 token 上，而且 `π_ref` 是冻结的。这带来两个后果：一是模型不会去发现"数据里没有但更好的回答"，SFT 阶段没见过的风格基本学不出来；二是当 chosen 与 rejected 的起始 token 完全相同时，前半段梯度会互相抵消，实际有效的更新只发生在分叉点之后。

还有一个常被忽略的副作用：压制 rejected 时，如果 rejected 里混着 chosen 也需要的通用能力 token（比如都在讲同一段代码），`β` 太大会顺带把这些 token 的概率也压下去。表现出来就是"偏好指标涨了，通用能力掉了"。所以 DPO 之后一定要跑一遍通用能力回归（MMLU / 代码单测通过率这类硬指标），不能只看 win-rate。

## 三、GRPO：把 critic 换成"同一道题做 G 遍"

在线 RL 的价值函数（critic）在长 CoT 场景里很难训：它要和策略同步更新、显存翻倍，而且对"推理步骤"的信用分配本来就不准。GRPO 的思路很朴素——**同一道题采 G 个回答，用组内均值当基线**：

```text
Â_i = ( r_i - mean(r_1..r_G) ) / ( std(r_1..r_G) + ε )

L_GRPO = -E[ (1/G) Σ_i min( ρ_i·Â_i , clip(ρ_i, 1-ε, 1+ε)·Â_i ) ] + β·D_KL(π_θ || π_ref)
        其中 ρ_i = π_θ(y_i|x) / π_old(y_i|x)
```

理论上的正当性只有一条：**基线只要与动作无关，就不引入偏置**。组内均值是同一个 prompt 下其它样本的平均，天然与具体动作无关，所以它是合法的 baseline；用 G 个样本估它，方差比单样本大，但只要 G 够小、prompt 够多，噪声就被 batch 平均掉了。critic 的价值函数估计的是"这个状态多好"，组内均值估计的是"这道题平均能做多好"——对最终奖励是规则校验（答对 1 分、答错 0 分）的任务，后者其实更准。

### 但组大小 G 不是越大越好

奖励二值化（0/1）时，一个组里"全对"或"全错"的组，标准差为 0，优势全为 0——这些样本白采样了。退化组的比例是 `p^G + (1-p)^G`，p 是单次成功概率：

```python
for p in (0.5, 0.2, 0.05):
    print(f"p={p}: " + ", ".join(f"G={G}->{100*(p**G + (1-p)**G):.1f}%" for G in (4, 8, 16)))
```

实测：

```text
p=0.5 : G=4->12.5%, G=8->0.8%, G=16->0.0%
p=0.2 : G=4->41.1%, G=8->16.8%, G=16->2.8%
p=0.05: G=4->81.5%, G=8->66.3%, G=16->44.0%
```

**题越难，G 越大反而越亏**：pass@1 只有 5% 的题，G=16 时仍有 44% 的组完全没有梯度信号，而每组的采样成本是 G 倍。这就是 DAPO 要加"动态采样"（把全对/全错的组丢掉，超采样补足 batch）的原因；也是为什么早期 GRPO 实现里 G=64 效果不一定比 G=8 好。

另一个坑是优势幅值。二值奖励下，组内有 k 个成功时成功样本的优势是 `sqrt((G-k)/k)`——G=64、k=1 时幅值是 7.94，比 G=8、k=1 时的 2.65 大得多。也就是说 **G 变大不只是降低方差，还悄悄放大了梯度尺度**，clip 的 ε 相对变紧/变松，超参就漂了。DAPO 的 clip-higher（把上界放宽）和 Dr.GRPO 的 token-level loss（按 token 数归一化，而不是按样本数）都是在修这个尺度问题。

## 四、选择：什么时候用哪个

| 场景 | 选择 | 理由 |
|---|---|---|
| 有 10 万级高质量 pair，算力有限 | DPO / ORPO | 单次监督训练，无采样成本，单机可跑 |
| 长度敏感（客服、摘要、结构化抽取） | SimPO / R-DPO（长度归一化） | 避免 logprob 求和把"长"当"好" |
| 任务可规则校验（单测通过、SQL 执行成功、数学答案） | GRPO / RLOO | 无需 reward model，组内基线足够 |
| 需要探索新策略、数据分布外 | PPO 或 online DPO | 离线 pair 无法产生未见过的回答 |
| 只有 1k 级偏好数据 | ORPO（SFT+偏好一步） | pair 太少时 DPO 容易过拟合 ref |

经验判断：**能用规则奖励就不要训 reward model，能离线就不要在线**。DPO 的成本是"一次训练"，GRPO 的成本是"G 倍采样 × 数百步"，两者差一到两个数量级；对绝大多数业务微调，先 DPO 打底、再针对难样本做小规模 GRPO，是性价比最高的组合。

## 五、踩坑清单（七条，都是真踩过的）

1. **ref model 忘了 `.eval()` 或用了不同精度**。ref 在训练模式下的 dropout 会让参考 logprob 抖动；ref 用 4bit 量化、policy 用 bf16，KL 基线直接偏掉，表现出来是"训练前期 loss 就很高然后不动"。
2. **chat template 不一致**。policy 和 ref 必须用同一份模板，且 chosen / rejected 都要**只算回答部分的 logprob**（prompt 部分 mask 掉）。用整段序列算 logprob 时，长 prompt 会淹没回答部分的差异。
3. **padding 侧与 mask**。右侧 padding + 按 `attention_mask` 求和是对的；如果按 `seq_len` 求平均（把 pad 也算进分母），不同 batch 的归一化系数就不同，梯度噪声会大到看不出趋势。这是"mean 归一化"最常见的实现错误。
4. **β 和 lr 耦合**。梯度前面乘了 β，改 β 等于改步长。调参顺序应该是：固定 β=0.1 扫 lr → 再动 β。
5. **用 loss 选 checkpoint**。DPO loss 单调下降毫无意义（Δ 越大 loss 越小，而 Δ 大恰恰说明学不动了）。要盯两个指标：长度受控的 win-rate + 平均输出长度。长度涨 20% 而 win-rate 涨 1%，这是负收益。
6. **pair 不独立**。同一个 prompt 配 5 个 rejected 拼成 5 条样本，effective batch 是名义 batch 的 1/5，梯度噪声被严重低估；要么按 prompt 聚合损失，要么在 sampler 里做 prompt 级去重。
7. **GRPO 里 `π_old` 更新粒度**。`ρ_i` 是相对采样时策略的比值，一个 batch 内做多次梯度累积就必须用同一份 `π_old` 快照；边训边更新会让 ρ 漂移，clip 频繁触发、有效样本骤降。这也是"GRPO 训着训着 reward 突然掉"最常见的原因。

## 总结

- DPO 的价值在于把 KL 约束解成闭式解，让 reward model 和 RL 循环消失；它优化的是**策略与参考策略的似然比**，不是"回答有多好"。
- 三个隐性代价都写在梯度里：`β·σ(-βΔ)` 带来梯度饱和（β 也是步长旋钮）、Δ 的求和形式带来长度偏置、冻结的 ref + 离线 pair 带来探索缺失和通用能力回退。
- GRPO 用组内均值替掉 critic，成立的理由只有"基线无偏"这一条；代价是采样成本和退化组，G 的选择在"难度"和"成本"之间做权衡，而不是越大越好。
- 工程上，长度受控的评测 + 通用能力回归，比任何 loss 曲线都更能告诉你这次偏好优化是赚了还是亏了。

参考：DPO（Rafailov et al., 2023）、IPO、KTO、ORPO、SimPO（长度归一化）、DeepSeekMath 的 GRPO 原始报告、DAPO 与 Dr.GRPO 对 clip 与归一化的修正、Length-Controlled AlpacaEval 对长度偏置的量化。文中所有表格外的数字均为我自己在本机跑的纯标准库实验，脚本就是文中那三段代码。
