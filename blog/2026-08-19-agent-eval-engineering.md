---
title: "AI Agent 评测工程化：从单轮问答到轨迹与环境反馈"
date: 2026-08-19T18:00:00+08:00
draft: false
tags: ["ai", "llm", "agent", "eval", "engineering"]
categories: ["Tech"]
description: "单轮 LLM 评测为什么测不出 Agent 好坏？四个评测层级、主流基准数据、可运行的评测骨架代码，以及把 Agent 评测变成 CI 门禁的工程实践与踩坑。"
---

「这个模型写代码不错」和「这个 Agent 能完成 20 轮工具调用把事办成」是两回事。单轮评测测的是「会不会答」，Agent 评测测的是「会不会把事情办成」——后者涉及状态、工具副作用、长程规划，评测的复杂度直接上了一个数量级。

上一篇[LLM 评测工程化](/blog/2026/08/04/llm-eval-llm-as-judge)讲了单轮文本评测的偏见与校准，这篇聚焦 Agent 场景：**评测什么、拿什么当标准答案、怎么写评测骨架、怎么避免评测本身成为成本黑洞**。面向已经在跑 Agent 生产流量的后端工程师，不讲科普。

{/* truncate */}

## 一、Agent 评测的四个层级

单轮评测只看「输出文本」，Agent 评测至少要多看三层。按可靠程度从低到高：

**L1 输出文本**：给 Agent 一个任务，看最终回复内容。最弱——它完全不验证 Agent 是否真的调用了工具、工具是否生效。一个「假装查了数据库」的 Agent 在 L1 上可能拿满分。

**L2 工具调用**：校验每一轮工具调用的参数是否合法（schema 校验）、是否在预期时机调用。这是纯规则可判定的，**不需要任何 LLM 参与**，可靠且便宜。

**L3 轨迹**：整条 (观察 → 行动) 序列。比如「先查余额再转账」的顺序是否合理、有没有跳过二次确认、步数有没有超预算。轨迹断言大部分可以用规则表达，小部分需要 LLM 判断。

**L4 结果（环境反馈）**：任务完成后，直接检查**环境状态**而不是 Agent 的自述。这是最硬的标准——转账任务就看收款方余额是不是真变了。能拿到环境信号就不要用 LLM 判断，这是 Agent 评测的第一原则。

> 原则：**环境信号优先于文本判断，规则优先于 LLM。** LLM judge 只在没有环境信号的维度（回答质量、规划合理性）出场。

## 二、主流基准都在测什么

几个代表性基准，注意它们的共同点：**都引入了外部环境或执行器**，而不是让模型自评。

| 基准 | 环境 | 评测方式 | 2026 年中的大致水平 |
|------|------|----------|---------------------|
| SWE-bench Verified | 真实 GitHub 仓库 + 测试套件 | 运行测试，看 patch 是否让测试从红变绿 | 顶级商用 coding agent 约 70% 以上，开源最强 50% 上下 |
| tau-bench | 模拟银行/航空客服系统 | 环境状态比对（余额、订单状态） | 顶级模型零售场景约 55% 起步 |
| BFCL v3 | 工具调用 schema 集合 | 参数与调用顺序精确匹配 | 顶级模型 85% 以上 |
| GAIA | 网页/文件/代码混合任务 | 最终答案与参考答案比对 | 顶级 agent 约 60% 以上 |

两个值得注意的工程细节：

1. **SWE-bench 的 pass 判定是「跑测试」而不是「看 patch」**——环境执行结果说了算，这天然免疫了文本相似度匹配的种种坑。
2. **tau-bench 的判定是「环境终态」**——银行场景直接比对转账后的账户余额，不关心 Agent 中间说了什么漂亮话。

## 三、一个最小可用的评测骨架

生产级评测（如 OpenHands 的 harness、tau-bench 的模拟器）本质都是这套结构：**有状态的环境 + 动作接口 + 结果判定**。核心骨架如下：

````python
# agent_eval.py — 最小评测骨架
# 环境：带状态的「银行客服」模拟器，任务 = 完成转账并核对结果
# 关键设计：判定只看 env 终态，不看 agent 的自述

class BankEnv:
    def __init__(self):
        self.balance = {"alice": 1000.0, "bob": 200.0}
        self.steps = 0
        self.done = False

    def reset(self):
        self.balance = {"alice": 1000.0, "bob": 200.0}
        self.steps, self.done = 0, False
        return f"alice={self.balance['alice']:.2f}, bob={self.balance['bob']:.2f}"

    def act(self, action: dict) -> str:
        self.steps += 1
        kind = action.get("type")
        if kind == "transfer":
            src, dst = action["from"], action["to"]
            amt = float(action["amount"])
            if amt <= 0 or amt > self.balance[src]:
                return "失败：余额不足或金额非法"
            self.balance[src] -= amt
            self.balance[dst] += amt
            return f"成功，已转账 {amt:.2f}"
        if kind == "done":
            self.done = True
            return "任务结束"
        return "未知动作"

    def goal_reached(self) -> bool:
        # 判定规则：alice 转出 300 且 bob 收到 300
        return abs(self.balance["alice"] - 700.0) < 0.01 \
           and abs(self.balance["bob"] - 500.0) < 0.01


def run_episode(agent, env, task, max_steps=20):
    """跑一轮，返回结果 + 步数 + 成本（token 计价）"""
    obs = env.reset()
    cost = 0.0
    for _ in range(max_steps):
        if env.done:
            break
        action, tok_in, tok_out = agent.step(obs, task)
        cost += 1.5 * (tok_in + tok_out) / 1e6  # $1.5/M token 计费
        obs = env.act(action)
    return {
        "success": env.goal_reached(),
        "steps": env.steps,
        "cost": cost,
    }


def pass_at_k(episodes, k=3):
    """pass@k：同一任务采样 k 次，至少一次成功即算通过"""
    grouped = [episodes[i:i + k] for i in range(0, len(episodes), k)]
    return sum(any(e["success"] for e in g) for g in grouped) / len(grouped)
````

注意三处容易被忽略的设计：

1. **判定函数是纯函数**——只读环境状态，与 Agent 的生成过程解耦，天然支持重放和并行。
2. **成本计量进评测结果**——Agent 评测的 token 消耗比单轮评测高一到两个数量级，成功率和成本必须一起看，否则「暴力重试直到成功」会刷爆预算。
3. **pass@k 而非单次成功**——温度采样有方差，单次失败不能说明 Agent 能力不行，k 次采样至少一次成功是 coding agent 评测的事实标准。

## 四、LLM judge 在 Agent 评测里的正确位置

环境信号覆盖不到的维度（回答是否礼貌、规划是否合理、是否主动询问缺失信息）才轮到 LLM judge，且必须做两件事：

**1. 打乱顺序去偏见。** judge 有强烈的 position bias——A/B 对比中先出现的答案更容易得高分。稳妥做法是正序反序各评一遍，只取两次一致的结论：

````python
# judge 双跑去 position bias：结论一致才采纳
def robust_judge(model, a, b):
    fwd = model.judge(a, b)   # A 在前
    rev = model.judge(b, a)   # B 在前
    if fwd == "A" and rev == "B":
        return "A"
    if fwd == "B" and rev == "A":
        return "B"
    return "TIE"  # 不一致 → 判平，人工介入
````

**2. 警惕 self-serving bias。** 多个研究反复观察到 judge 模型倾向于给自己的输出打高分。对策：judge 与待评 Agent 用不同模型家族，或者干脆用规则/环境信号覆盖能覆盖的一切，把 LLM 的使用面压到最小。

## 五、踩坑记录

**1. 环境非确定性会让评测结果不可复现。** 工具调用重放、随机 seed、外部 API 时延都会造成同一 Agent 两次跑出不同结果。把环境做成纯状态机（如上文的 BankEnv）、固定 seed、工具调用记录落盘，失败用例必须能重放定位——不能重放的评测是无效评测。

**2. 成本黑洞。** 一个 agent episode 动辄几万 token，50 个回归用例 × 20 轮 × 1.5 美元/M 就是几十美元一轮评测。工程对策是分级：**冒烟集（10 个用例，每次变更跑）→ 回归集（100 个，合并前跑）→ 全量集（发布前跑）**，并用上文的方法把成本写进每次评测报告，监控单位成本的漂移。

**3. 评测集污染。** Agent 的 context 里塞满了系统提示词，评测用例一旦被写进任何 prompt、示例或工具描述，Agent 就会「背题」。SWE-bench 上就出现过用例泄漏导致分数虚高的事故。对策：评测集与生产提示词完全隔离，定期轮换题目，用「题目变形」抽查（换数字、换人名，分数暴跌说明在背题）。

**4. 判定的语义鸿沟。** 别用文本相似度判定任务成败——「转账成功了吗」的正确回答是「看余额」，不是「看字符串像不像」。所有能用环境状态判定的维度一律用环境状态。

## 六、把评测变成 CI 门禁

Agent 评测的最终形态是 eval-driven development：**每次修改 prompt、工具定义、Agent 编排逻辑，都必须先跑冒烟集再合并**，像单测一样卡门禁。两个关键指标一起卡：

- **成功率**：冒烟集成功率低于基线（比如 0.85）直接拒合并；
- **单位成本**：成本上涨超过 20% 需要人工确认——「多花钱换成功率」有时是合理交易，但要显式记录。

单轮评测解决「模型选型」，Agent 评测解决「系统演进」——后者才是线上流量每天都在验证的东西。
