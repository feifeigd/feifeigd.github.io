---
title: "LLM-as-Judge 的统计幻觉：73% 一致率对应 κ=0.47，200 条样本测不出 3 个点的提升"
date: 2026-11-24T10:10:00+08:00
draft: false
tags: ["eval", "benchmark", "llm", "engineering"]
categories: ["Tech"]
description: "同一个评测平台，报告『与人类一致率 73%』和报告『κ=0.47』是两个完全不同的事实。这篇把 LLM-as-Judge 的四个统计陷阱算清楚：分数坍缩让 pointwise 打分在 A/B 测试里等于抛硬币、换位一致率只能治位置偏差治不了分辨力、原始一致率被 base rate 抬高、以及 200 条样本的置信区间宽到能跨过 50%。附一套能跑的 harness（判定缓存 + Bradley-Terry + bootstrap + 对抗性长度测试）。"
---

评测平台报「我们的 judge 跟人类标注一致率 73%」，听起来可以上线了。同一个 judge，换成 Cohen's κ 报出来是 0.47——按 Landis-Koch 的惯例只是「moderate」，离「能替代人工」还差一截。这两个数字来自同一批数据，都不算撒谎，但只有一个能支撑决策。

问题在于大多数人只算前者。原始一致率会被 base rate 抬高：一个永远回答「A 更好」的退化 judge，在人类也有 60% 选 A 的数据集上，一致率就是 60%，κ 是 0。你的评测流水线不会报错，图表会很漂亮，A/B 结论会很自信地错掉。

这篇不谈 prompt 怎么写，只谈「judge 给出的这些标签，能支撑多强的结论」。所有表格里的数字都能用文末的脚本复算——它们来自一个模拟脚本，参数（判别力、位置偏差强度、判平率）是我按线上手感设定的，不是某个具体模型的实测；公开论文的数字我单独标注了出处。

{/* truncate */}

## 一、pointwise 打分在 A/B 测试里基本等于抛硬币

先看为什么「让 judge 给 1-10 分，比平均分」这条路在模型对比里几乎必然失效。

模拟设定：500 个回答，每个有真实质量 q 服从均匀分布，judge 的分数是质量经过一次带噪映射，再四舍五入到整数格点。真实 judge 的行为比这更糟（有锚定效应，喜欢给 7-8 分），这里已经算宽容了。

```text
=== pointwise 分数分布（n=500，1-10 分制）===
  1:   0
  2:   0
  3:   1 #
  4:  10 ##########
  5:  53 #####################################################
  6: 104 ########################################################################################################
  7: 142 ##############################################################################################################################################
  8: 113 #################################################################################################################
  9:  62 ##############################################################
 10:  15 ###############
不同取值: 8 个    8 分和 9 分合计占: 35.0%
```

500 个回答只落在 8 个格点上，中间三档（6/7/8）吃掉 72% 的样本。这意味着相邻两次评测的分数差异，绝大部分是格点量化噪声，不是模型差异。

更致命的是分辨力。把 pointwise 分数当排序用，问「真实质量差 0.05（5% 相对差）的两个版本，pointwise 判对序的概率是多少」：

```text
=== pointwise 分数用于成对比较的正确率 ===
  真实质量差 0.05 -> 判对序概率 0.546
  真实质量差 0.10 -> 判对序概率 0.590
  真实质量差 0.20 -> 判对序概率 0.678
  真实质量差 0.40 -> 判对序概率 0.820
```

0.546。这就是「50 条样本上，新 prompt 平均分 7.62 vs 旧版 7.48，结论是提升 1.9%」这类报告的真实信息量——和抛硬币的区别，统计上要上千条样本才能测出来（第四节给具体数字）。

如果只能用一个指标，**pairwise 比较 + 强制二选一 + 换位**几乎总是优于 1-10 分。理由不是「pairwise 更准」，而是 pairwise 的决策边界只有一个（二分类），而 1-10 分要求 judge 在 9 个边界上校准；LLM 的分数校准能力是它最弱的能力之一。

## 二、换位法只治位置偏差，治不了分辨力

换成 pairwise，下一个问题是位置偏差。MT-Bench 那篇论文给的第一手测量很直白：用两个近似的答案让 judge 比较，然后交换顺序再问一次，GPT-4 在两种顺序下给出一致结论的比例是 65%，30% 的情况偏好第一个；GPT-3.5 一致率 46.2%；Claude-v1 只有 23.8% 一致，75% 的情况选第一个（连把答案改叫「Assistant A」都能影响它）。加 few-shot 把 GPT-4 的一致率抬到 77.5%，但论文自己也提醒：一致性不等于正确性。

现在把两个维度分开看。位置偏差（logit 空间的一个偏置项）和分辨力（judge 能把多大的质量差变成倾向）是两个独立参数，我用 20k 对样本扫了一遍：

```text
分辨力(noise) 首位偏差 | 首位胜率 换位一致率 一致样本内正确率 判平率
     0.15       0.0    |  0.503    0.764        0.930       0.236
     0.15       0.6    |  0.575    0.733        0.932       0.267
     1.00       0.0    |  0.500    0.522        0.655       0.478
     1.00       0.6    |  0.642    0.473        0.654       0.527
     2.00       0.6    |  0.642    0.458        0.583       0.542
```

三行结论，每一行都能对应一个工程决策：

1. **位置偏差只在质量差小的时候显形。** 高分辨力下（noise 0.15），把偏差从 0 加到 0.6，首位胜率只从 0.503 漂到 0.575；一旦分辨力下降（noise 1.0），同样的偏差直接把首位胜率推高到 0.642。这也是 IJCNLP 2025 那篇 15 个 judge、15 万次判定的大规模研究的结论：位置偏差「strongly affected by the quality gap between solutions」。**你在「同一模型两个 prompt」这种近邻对比上做评测，恰恰是位置偏差最严重的场景。**
2. **换位能把位置偏差从胜率里扣掉。** 用「两次顺序结论一致才算胜，否则判平」的规则，0.642 的首位胜率被拉回 0.5。这一步是必须的、廉价的、且有效的。
3. **换位对分辨力没有任何帮助。** 看最后一行和上一行：偏差从 0.6 降到 0.0，换位后的正确率从 0.583 变成 0.581（±0.002 噪声内）。分辨力不够时，换位一致率从 0.52 掉到 0.46，判平率涨到 54%——**一半的评测预算被扔掉了，剩下的那一半还是 58% 的正确率。** 换位法让你诚实地知道自己不知道，它不会让你知道。

所以换位一致率应该当「质量门禁」用：低于 0.6 的 judge 不该进决策链路，先换更强模型、加参考答案、或把评分细则写细。它不该当结论用。

## 三、73% 一致率，κ 可能只有 0.47

这是最容易被刷指标坑杀的一条。Cohen's κ 要减掉「随机也会一致」的部分：

```text
κ = (p_agree - p_expected) / (1 - p_expected)
```

构造一个真实分布：人类标注 1000 条，60% 选 A、30% 选 B、10% 判平。judge 的混淆矩阵如下：

```text
=== 原始一致率 vs Cohen's κ（1000 条，三分类 A/B/Tie）===
        人类A  人类B  人类T
judge A   540     40     20
judge B   120    150     30
judge T    40     20     40

原始一致率 0.730 | 随机期望一致 0.492 | Cohen's κ 0.469
退化 judge（永远答 A）：原始一致率 0.600，κ = 0.000
```

73% 的原始一致率，扣掉 base rate 之后是 0.47。而且这个 judge 有明显的「宽松偏向」：它在人类判 B 的 300 条里有 120 条（40%）改投 A，人类判平的 100 条里只有 40 条保持平局。这种偏移在做「新版本 vs 旧版本」比较时会系统性偏向 A 位——如果 A 位永远放新版本，你就得到了一个永远报「新版本更好」的评测平台。

工程上的要求很简单：**评测报告里同时给 p_agree、p_expected、κ，以及 judge 的三类边际分布。** 只有 κ 才能跨任务比较（人类标注者之间的 κ 在 0.6-0.8 是常见的），原始一致率连跨数据集比较都不行。

## 四、200 条样本测不出 3 个点

第三个陷阱是功效。评测集通常是拍脑袋定的：200 条问答、50 条 prompt 对比。用 bootstrap 重采样看 p̂=0.55 时的 95% 置信区间：

```text
=== bootstrap 置信区间（每次 400 次重采样）===
  n=  100  p_hat=0.55 -> 95% CI [0.460, 0.660]  半宽 10.0pp  跨 0.5? 是
  n=  200  p_hat=0.55 -> 95% CI [0.485, 0.625]  半宽  7.0pp  跨 0.5? 是
  n=  500  p_hat=0.55 -> 95% CI [0.504, 0.594]  半宽  4.5pp  跨 0.5? 否
  n= 2000  p_hat=0.55 -> 95% CI [0.525, 0.573]  半宽  2.4pp  跨 0.5? 否
  n= 5000  p_hat=0.55 -> 95% CI [0.537, 0.565]  半宽  1.4pp  跨 0.5? 否

=== 80% 功效所需样本量（双比例 z 检验近似）===
  真实胜率 0.52 -> n ≈ 4900
  真实胜率 0.55 -> n ≈  784
  真实胜率 0.60 -> n ≈  197
  真实胜率 0.65 -> n ≈   88
```

**800 条才能可靠地测出「胜率 55%」；要测出 52% 这种小改进，需要接近 5000 条。** 这条算术应该在写评测需求的时候就写进文档，而不是在结论被质疑的时候才补。

还要叠加第二节的判平率损耗：500 对样本、判平率 24% 时剩 380 对，CI 半宽从 2.2pp 变成 2.5pp；判平率 54% 时只剩 229 对，半宽 3.2pp。**弱 judge 的代价是双向的：既降低正确率，又因为判平把有效样本砍半。** 一个 0.58 正确率、50% 判平率的 judge 配 1000 条数据，实际等价于 500 条数据 + 抛硬币，这比没有评测更危险——因为它给出数字。

## 五、排名要 Bradley-Terry，而且要多打几轮

多模型对比时不要用「两两胜率矩阵手工排」。用 Bradley-Terry（BT）拟合：

```text
P(i 胜 j) = sigmoid(theta_i - theta_j)
```

BT 有两个实战优势：一是把所有成对判定联合估计，比只看相邻两名的胜率稳；二是它天然处理「A 胜 B、B 胜 C、C 胜 A」这种传递性破坏（这在真实 judge 上很常见）。

问题是要打多少轮。8 个模型，20% 的判定被随机翻转（模拟一个不算太差的 judge），用 MM 算法迭代拟合，重复 15 次：

```text
=== Bradley-Terry 恢复能力（K=8，20% 判定被翻转）===
   5 次/对 (n= 140) -> Kendall τ 0.695 ±0.134 | top-1 正确 53%
  20 次/对 (n= 560) -> Kendall τ 0.893 ±0.089 | top-1 正确 87%
  50 次/对 (n=1400) -> Kendall τ 0.952 ±0.062 | top-1 正确 87%
 150 次/对 (n=4200) -> Kendall τ 0.995 ±0.018 | top-1 正确 100%
```

每对 20 次是拐点：τ 从 0.70 跳到 0.89，top-1 从 53% 到 87%。再往上加只提升 τ 的小数点——注意 20 和 50 次时 top-1 都是 87%，因为第一名和第二名的真实差距只有 0.4，在 20% 翻转率下本来就测不稳。**「谁是第一」需要 50 次以上，「前四名是谁」20 次就够。**

关键取舍：**不要把换位不一致的样本丢掉再拟合 BT。** 判平率 50% 时你扔掉一半数据；正确做法是把「不一致」记成 0.5 胜（或作为 BT 的 tie 项），或者干脆把两次顺序的判定当两条独立观测喂进 BT——BT 的似然对有噪声的标签是鲁棒的，而丢弃样本是有偏的（丢弃的恰好是最难的、差距最小的样本，这会让 τ 系统性虚高）。

一个常被忽略的细节：评测集样本量够大时，**同一对模型的多次比较应该复用不同的 prompt/样本，而不是重复问同一个样本 20 次**。重复问同一样本 20 次测的是 judge 的稳定性（temperature 0 下几乎必为 1.0），不是模型能力。

## 六、长度偏差要做对抗测试，别做口头承诺

MT-Bench 的实验设计很值得抄：拿 23 条含编号列表的答案，让模型「不加任何信息地改写一遍」，然后把改写版拼在原答案前面——答案变成两倍长，内容完全没变。结果 Claude-v1 和 GPT-3.5 有 91.3% 的情况选了这个注水版，GPT-4 是 8.7%。而且三个 judge 都能正确判定「两个完全相同的答案」为平局——**它们能处理格式，但仍然会判错内容。**

模拟一下长度偏置的量级：让注水版的内容质量比原版略差（差 0.06，约 6% 相对差），长度加 40%，然后扫「每个额外字符值多少 logit」：

```text
=== 注水答案（内容更差、长 40%）的胜率 ===
  长度加成 0.0 logit -> 注水版胜率 0.474
  长度加成 0.3 logit -> 注水版胜率 0.539
  长度加成 0.6 logit -> 注水版胜率 0.601
  长度加成 1.0 logit -> 注水版胜率 0.677
```

0.3 个 logit 的长度加成，就足以让一个内容更差的答案赢 54%。这个量级意味着：**任何「让回答更详细」的 prompt 改动，在 A/B 里都会赢，无论它是否真的有用。**

对抗测试应该是评测流水线的一个常驻用例，而不是一次性实验：

```python
# adversarial_length_test.py —— 内容不变、长度翻倍，judge 应判平
import asyncio, hashlib, json

PAD_PROMPT = (
    "把下面回答中的编号列表改写成完整的散文段落，不得增加任何新信息、"
    "不得删减任何信息，允许重复措辞。只输出改写结果。\n\n{answer}"
)

async def run(judge, items, concurrency=8):
    sem = asyncio.Semaphore(concurrency)
    async def one(it):
        async with sem:
            padded = it["answer"] + "\n\n" + await judge.complete(
                PAD_PROMPT.format(answer=it["answer"]))
            v1 = await judge.compare(it["question"], it["answer"], padded)   # 原文在前
            v2 = await judge.compare(it["question"], padded, it["answer"])   # 注水在前
            return {"id": it["id"], "v1": v1, "v2": v2}
    rows = await asyncio.gather(*(one(i) for i in items))
    # 指标：判平率（越高越好）、注水版双向胜率（应接近 0.5）
    tie = sum(1 for r in rows if r["v1"] == "tie") / len(rows)
    pad = sum(1 for r in rows
              if (r["v1"] == "b" and r["v2"] == "a")
              or (r["v1"] == "a" and r["v2"] == "b")) / len(rows)
    return {"tie_rate": tie, "pad_win_rate_both_orders": pad, "n": len(rows)}
```

判据：**判平率低于 0.8 或注水版双向胜率高于 0.55，这个 judge 就不能用来比较「详细程度不同」的两个版本**——而这恰好是大多数 prompt 改动的形态。

## 七、一套能跑的 harness

把上面四件事落成一个模块。核心不是 prompt，是**判定的可复用性和统计层的正确性**：

```python
# judge_harness.py —— 判定缓存 + 双向换位 + 统计层（纯标准库，可直接跑）
import asyncio, hashlib, json, math, random, statistics
from itertools import combinations

def cache_key(judge_id, item_id, a, b, order):
    h = hashlib.sha256(f"{judge_id}|{item_id}|{a}|{b}|{order}".encode()).hexdigest()
    return h[:32]

class JudgeRunner:
    """所有判定写 JSONL，重跑时按 key 命中缓存——评估集迭代时省 90% 的钱。"""
    def __init__(self, judge, path="judgments.jsonl", budget_usd=None, concurrency=8):
        self.judge, self.path, self.budget = judge, path, budget_usd
        self.sem = asyncio.Semaphore(concurrency)
        self.cache = {}
        try:
            with open(path) as f:
                for line in f:
                    r = json.loads(line); self.cache[r["key"]] = r
        except FileNotFoundError:
            pass

    async def _call(self, item, a, b, order, **kw):
        key = cache_key(self.judge.id, item["id"], a["id"], b["id"], order)
        if key in self.cache:
            return self.cache[key]["verdict"]
        async with self.sem:
            for attempt in range(5):                      # 429/5xx 指数退避
                try:
                    v = await self.judge.compare(item["question"], a["text"], b["text"], **kw)
                    break
                except Exception:
                    if attempt == 4: raise
                    await asyncio.sleep(2 ** attempt)
        rec = {"key": key, "item": item["id"], "order": order, "verdict": v,
               "judge": self.judge.id}
        with open(self.path, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.cache[key] = rec
        return v

async def evaluate(runner, items, model_a, model_b):
    """双向跑；一致性作为质量门禁，不一致的样本不丢弃，记 0.5 胜喂 BT。"""
    async def pair(it):
        v1 = await runner._call(it, model_a, model_b, "ab")
        v2 = await runner._call(it, model_b, model_a, "ba")
        if v1 == v2:
            return {"item": it["id"], "winner": v1, "consistent": True}
        return {"item": it["id"], "winner": "tie", "consistent": False}
    rows = await asyncio.gather(*(pair(i) for i in items))
    n = len(rows); cons = sum(r["consistent"] for r in rows) / n
    wins = sum(1 for r in rows if r["winner"] == "a") / n
    return {"n": n, "consistency": cons, "win_rate_a": wins, "rows": rows}


# ---------- 统计层 ----------
def cohen_kappa(a, b, labels=("a", "b", "tie")):
    n = len(a); agree = sum(x == y for x, y in zip(a, b)) / n
    pa = {l: a.count(l) / n for l in labels}
    pb = {l: b.count(l) / n for l in labels}
    pe = sum(pa[l] * pb[l] for l in labels)
    return (agree - pe) / (1 - pe) if pe < 1 else 0.0

def bootstrap_ci(rows, alpha=0.05, B=2000, seed=0):
    rnd = random.Random(seed); n = len(rows); stats = []
    for _ in range(B):
        s = [rows[rnd.randrange(n)] for _ in range(n)]
        stats.append(sum(1 for r in s if r["winner"] == "a") / n)
    stats.sort()
    return stats[int(alpha / 2 * B)], stats[int((1 - alpha / 2) * B)]

def bradley_terry(counts, wins, iters=500):
    """counts[i][j]=i 与 j 的比较次数，wins[i]=i 的胜场（平局各记 0.5）。"""
    K = len(wins); th = [0.0] * K
    for _ in range(iters):
        new = []
        for i in range(K):
            denom = sum(counts[i][j] * (1 / (1 + math.exp(-(th[i] - th[j]))))
                        for j in range(K) if j != i and counts[i][j])
            new.append(math.log(max(wins[i], 0.5) / max(denom, 1e-9)))
        m = sum(new) / K
        th = [x - m for x in new]
    return th
```

配套的三条硬性检查，建议直接做进 CI：

- **鉴别力门槛**：在已知答案的对照组（golden set，人工标注 300 条）上跑，κ 低于 0.5 或换位一致率低于 0.6，评测任务直接 fail，不许产出报告。
- **样本量门槛**：报告的每个胜率必须带 bootstrap CI；CI 跨 0.5 的结论一律标成「无显著差异」，不允许写「提升 X%」。
- **对抗用例**：长度注水、无关开头（「这是个好问题」）、markdown 装饰（加粗/表格化）三组，judge 的判平率要高于 0.8。

顺带说成本：500 条样本 × 2 个顺序 = 1000 次调用，按 1200 输入 token + 60 输出 token 算，中端 judge 约 0.22 美元，前沿模型约 3.6 美元（每对比较 0.0004 / 0.0072 美元）。**样本量从来不是被钱卡住的**——按第四节的算式，跑到 2000 条也就十几美元。真正的瓶颈是构造评估集和拿到可信的人工锚点，而锚点只需要 200-300 条，且可以长期复用。

## 八、清单

1. 模型对比用 pairwise + 强制二选一 + 双向换位；不要用 1-10 分平均分（真实质量差 5% 时判对序概率只有 0.546）。
2. 换位一致率是**质量门禁**不是结论：它治位置偏差（首位胜率 0.642 拉回 0.5），治不了分辨力（正确率 0.583 一点没变）。
3. 报 κ 不报原始一致率；73% 一致率可以是 κ=0.47，甚至可以是 κ=0 的退化 judge。
4. 写清功效：测 5 个点要 800 条，测 2 个点要 5000 条；判平率会再砍掉一半有效样本。
5. 多模型排名用 BT，每对至少 20 次比较（τ 0.70 变 0.89），争第一名要 50 次以上；不一致的判定记 0.5 胜，不要丢弃。
6. 长度、格式、开头寒暄三组对抗用例常驻，判平率低于 0.8 的 judge 不许比较「详细程度不同」的版本。
7. 所有判定落 JSONL 并按 key 缓存；迭代评估集时重跑成本接近零，才能做到「改了 rubric 就把历史数据全重算一遍」。

评测的可信度不来自 judge 有多强，来自你有没有把它当一台有已知误差的仪器来校准：给误差条、给门禁、给对抗测试。缺了这三样，那张漂亮的胜率表只是在把不确定性转移给读它的人。
