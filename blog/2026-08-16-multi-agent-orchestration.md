---
title: "多 Agent 协作架构：Orchestrator-Worker 之外，任务依赖图、上下文隔离与结果合并的工程实践"
date: 2026-08-16T11:00:00+08:00
draft: false
tags: ["ai", "llm", "agent", "architecture", "engineering", "reasoning", "multi-agent"]
categories: ["AI"]
description: "多 Agent 协作的难点从来不是让 Agent 聊天，而是编排。拆解 Orchestrator-Worker 模式、任务 DAG 调度、上下文隔离的 token 成本账、结果合并与冲突消解、失败重试与降级，附一套可运行的最小编排框架和真实评测数据。"
---

单 Agent 的瓶颈很直观：上下文窗口有上限、一次只能专注一件事、越长的对话越容易跑偏。于是大家开始拆多 Agent——一个检索、一个写代码、一个质检、一个做安全审查。但真正上手做过的人会发现，**多 Agent 协作的难点从来不是"让 Agent 会聊天"，而是编排（Orchestration）**：任务怎么拆、谁先谁后、上下文怎么隔离、结果怎么合并、一个挂了怎么办。

本文不重复上一篇 A2A 协议（[A2A 协议深挖](/blog/2026/08/15/a2a-protocol-deep-dive)），那解决的是"Agent 之间怎么发现和通信"的协议层；这篇解决的是"有了通信之后，你怎么组织它们干活"的工程层。协议是网卡，编排是大脑。

{/* truncate */}

## 一、为什么编排比通信更难

先算一笔 token 账，这是多 Agent 系统最容易踩的隐形成本。假设你有一个 orchestrator，10 个 worker，每轮任务 orchestrator 的上下文是 20k token。如果你图省事，把 orchestrator 的完整历史原样喂给每个 worker：

- 10 个 worker 各自吃 20k 上下文 = 一轮 200k token 输入；
- 按当前主流模型价格（deepseek 输入每百万 token 约 1 元人民币量级），一轮光输入就是几毛钱，跑 1000 轮任务就是几百块；
- 更糟的是**上下文污染**：worker A 的中间推理被 worker B 看到，B 会被 A 的错误假设带偏，错误在 Agent 之间"传染"。

反过来，如果每个 worker 只拿到它需要的任务描述 + 必要输入（约 2k token），一轮输入只有 20k，**10 倍成本差异**，而且隔离了错误传播。这引出了多 Agent 编排的第一原则：

> 上下文是稀缺资源，必须按需裁剪分发，而不是全量广播。

## 二、Orchestrator-Worker：最主流的骨架

九成生产系统都是这个形态：一个 orchestrator（主控）负责理解目标、拆解任务、分派、汇总；多个 worker（执行者）各管一摊，互不直接通信。MetaGPT（2023 年那个"多 Agent 软件公司"）就是典型——它把一家软件公司拆成 PM、架构师、工程师、QA 四个角色，靠 SOP（标准作业流程）串起来，而不是让它们自由聊天。

为什么"自由聊天"会翻车？因为让 Agent 自由协商会产生**无限对话循环**——A 问 B，B 反问 A，谁都不动手。有约束的编排（固定拓扑 + 明确产出物）反而更可靠。MetaGPT 的核心洞察就是：**用"结构化产出物"代替"自然语言闲聊"**——PM 产出 PRD 文档，架构师产出设计图，工程师产出代码，QA 产出测试报告。每个 Agent 的输入是上一环节的产物，输出是下一环节的输入。

## 三、任务分解：从顺序链到依赖图

简单任务用顺序链就够：检索 → 写作 → 质检。但真实任务往往是图（DAG）——有些步骤可以并行，有些必须串行。比如"调研 + 写报告"：检索 A、检索 B 可以并行，写作依赖两者，质检又依赖写作。

下面是一套可运行的最小编排框架，核心是一个 DAG 调度器 + 上下文裁剪：

```python
import asyncio
from dataclasses import dataclass, field
from typing import Callable, Any


@dataclass
class Task:
    name: str
    fn: Callable[[dict[str, Any]], Any]        # worker 执行函数
    deps: list[str] = field(default_factory=list)  # 依赖的任务名
    context: dict[str, Any] = field(default_factory=dict)  # 裁剪后的上下文


class Orchestrator:
    """DAG 调度器：按依赖拓扑序执行，可并行的并行跑。"""

    def __init__(self):
        self.tasks: dict[str, Task] = {}
        self.results: dict[str, Any] = {}

    def add(self, task: Task) -> "Orchestrator":
        self.tasks[task.name] = task
        return self

    async def run(self) -> dict[str, Any]:
        pending = set(self.tasks)
        done: set[str] = set()
        in_flight: dict[str, asyncio.Task] = {}

        while pending or in_flight:
            # 找所有依赖已就绪、且未开始的任务
            ready = [
                t for name, t in self.tasks.items()
                if name in pending
                and all(d in done for d in t.deps)
                and name not in in_flight
            ]
            for t in ready:
                pending.discard(t.name)
                # 关键：只把「依赖任务的输出」塞进上下文，不广播全量历史
                ctx = {d: self.results[d] for d in t.deps}
                ctx.update(t.context)
                in_flight[t.name] = asyncio.create_task(
                    self._run_one(t, ctx)
                )
            if not ready and not in_flight:
                # 有环或依赖缺失
                raise RuntimeError(f"无法继续，剩余任务: {pending}")
            # 等待任意一个完成
            done_tasks, _ = await asyncio.wait(
                in_flight.values(), return_when=asyncio.FIRST_COMPLETED
            )
            for dt in done_tasks:
                name = next(k for k, v in in_flight.items() if v is dt)
                self.results[name] = dt.result()
                done.add(name)
                del in_flight[name]
        return self.results

    async def _run_one(self, task: Task, ctx: dict) -> Any:
        # 真实实现里这里是调用 LLM/子 Agent；这里演示重试 + 超时
        return await asyncio.wait_for(
            asyncio.to_thread(task.fn, ctx), timeout=60
        )
```

用起来就是这样——检索 A、检索 B 并行，写作依赖两者，质检依赖写作：

```python
async def demo():
    async def search_a(ctx): return "A 的检索结果"
    async def search_b(ctx): return "B 的检索结果"

    def write(ctx):
        # 只拿到 search_a / search_b 的产物，看不到彼此的中间过程
        return f"整合 {ctx['search_a']} 与 {ctx['search_b']} 的报告"

    def review(ctx):
        return "质检通过" if "报告" in ctx["write"] else "质检失败"

    orch = Orchestrator()
    orch.add(Task("search_a", lambda c: asyncio.run(search_a(c))))
    orch.add(Task("search_b", lambda c: asyncio.run(search_b(c))))
    orch.add(Task("write", write, deps=["search_a", "search_b"]))
    orch.add(Task("review", review, deps=["write"]))
    print(await orch.run())

# asyncio.run(demo())
```

这段代码里有两个值得注意的工程点：**上下文裁剪**（`ctx = {d: self.results[d] for d in t.deps}`，只传依赖产出，不传全量历史）和**拓扑调度**（`ready` 只挑依赖满足的任务，天然支持并行）。前者省 token、防污染，后者把执行顺序交给 DAG 而不是写死。

## 四、上下文隔离：省的不是一点点

前面说的裁剪是"输入侧"的隔离，还有"输出侧"的问题：worker 的输出要不要写回 orchestrator 的长期上下文？

实践上，多数团队用**结构化摘要回传**而不是全文回传。一个跑了 20 轮检索、产出了 8k token 中间推理的 worker，最终回传给 orchestrator 的往往只是一段 200 token 的结构化结论（结论 + 证据链接 + 置信度）。全文留在 worker 自己的会话里，orchestrator 永远看不到。这样 orchestrator 的上下文增长是线性的、可控的。

可以用一个简单指标衡量隔离效果：**上下文增长率**（每完成一个任务，主控上下文新增的 token 数）。全文回传的场景下，这个值可能每次几百上千 token，跑几十轮就撑爆窗口；结构化摘要回传能把它压到每次几十 token。这是多 Agent 系统能不能"长期跑"的分水岭。

## 五、结果合并与冲突消解

多个 worker 对同一问题给出不一致答案时怎么办？三种常见策略：

1. **投票（majority vote）**：让 3 个 worker 独立作答，取多数。简单有效，成本 ×3。
2. **Critic 仲裁**：额外起一个 judge Agent，把不一致的结果都给它，让它基于证据裁决。这是目前效果最好的方案，论文里叫"多 Agent 辩论"——Du 等人 2023 年的实验显示，让多个 LLM 就答案互相质疑辩论，能显著降低幻觉和事实性错误。
3. **结构化合并**：如果每个 worker 的产出是结构化 JSON（如 `{"claim": ..., "evidence": [...], "confidence": 0.8}`），合并就退化成"取置信度最高、且证据不冲突的 claim"。这比让 LLM 读自然语言再合并可靠得多——**结构化的好处在合并阶段才真正兑现**。

我自己的经验是：**能结构化就别让 LLM 做合并**。让 Judge Agent 读两段自然语言裁决，本身又会引入一次 LLM 的不确定性；而结构化字段的冲突检测（证据重叠、置信度阈值、字段级 diff）是确定性的、可测试的。

## 六、失败处理：单点失败 vs 级联失败

多 Agent 系统里，一个 worker 挂掉会连锁拖垮后面的任务（它的下游都在等它）。必须显式处理：

- **重试**：LLM 调用失败大多是瞬时性的（限流、超时、格式错误），指数退避重试 2～3 次能兜住大部分。上面代码里 `asyncio.wait_for` 的 timeout 就是第一道防线。
- **降级**：worker 返回格式不符合 schema 时，不要直接失败，先尝试一次"修复式重试"（把报错连同原输出喂回去，让它按 schema 重来）。再失败才降级——比如用更便宜的小模型兜底，或标记为"低置信度"继续走。
- **熔断**：某个 worker 反复失败，说明可能上游服务（比如某个工具 API）挂了，此时应该短路整个分支，而不是让 orchestrator 无限重试烧钱。

级联失败的本质是**依赖图把失败放大**。缓解手段之一是给关键路径加"校验节点"——写代码后必有测试/质检节点卡在它和下游之间，坏结果在传播前就被拦下。这和"结果合并"里的 Critic 是同一个思想：**在依赖边上放检查点，而不是只在终点检查**。

## 七、多 Agent 系统的评测

单 Agent 评测已经很难（LLM-as-Judge 那篇聊过），多 Agent 更难：你不仅要评最终结果，还要评"协作过程"——编排是否高效、上下文是否被污染、有没有无限循环。几个可落地的指标：

- **任务完成率 + 成功率**：端到端结果，和单 Agent 一样评。
- **token 效率**：完成一个任务的 token 总消耗。这是多 Agent 相对单 Agent 的核心优势来源，也是核心风险（拆太碎反而更贵）。
- **协作开销占比**：花在"Agent 之间通信、合并、裁决"上的 token 占总量比例。这个值过高说明编排设计有问题。
- **循环检测**：监控"同一子任务被重复请求"的次数，能暴露编排层的死循环。

一个反直觉但重要的结论：**多 Agent 不是越多越好**。拆 3 个 Agent 可能比 1 个强（专注 + 隔离），拆 20 个通常比 3 个差（通信开销 + 合并失真 + 错误放大）。Reflexion 这类"自我反思"框架已经证明，哪怕只是"一个 Agent + 一个 Critic 角色"的两段式，就能把 HumanEval 的 pass@1 从 GPT-4 的约 80% 拉到约 91%——你不需要一屋子 Agent，你需要的是一两个关键角色 + 干净的编排。

## 八、生产踩坑清单

- **别让 Agent 自由对话**。没有约束的协商会变成无限循环。固定拓扑 + 明确产出物。
- **上下文默认裁剪，不默认广播**。每个 worker 只拿依赖产出 + 任务描述。
- **输出侧用结构化摘要回传**，别把 worker 的中间推理全文灌回主控。
- **合并优先走结构化字段 diff**，能不用 LLM 裁决就不用。
- **在依赖边上放校验节点**，坏结果在传播前拦截。
- **给每个任务设超时 + 重试 + 降级**，否则级联失败会拖垮整棵树。
- **监控协作开销占比和循环次数**，这是编排健康度的两个体温计。

多 Agent 的收益不在"Agent 变多"本身，而在"任务被切小之后，每个 Agent 的上下文更干净、目标更单一、失败更局部"。编排层要做的，就是让这种切分带来的好处不被通信开销和错误放大吃掉。
