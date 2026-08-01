---
title: "improve-codebase-architecture：用「深模块」给代码库做一次架构体检"
date: 2026-08-02T10:00:00+08:00
draft: false
tags: ["architecture", "engineering", "agent", "ai"]
categories: ["Tech"]
description: "拆解 Matt Pocock skills 库中的 improve-codebase-architecture 技能：深/浅模块理论、deletion test、HTML 架构报告与 grilling 循环"
---

> 本文是 AI Agent 技能拆解系列的一篇。上一篇《[LLM 写代码为什么是 2 倍而不是 10 倍](/blog/2026/07/31/llm-coding-2x-not-10x)》讨论了 AI 协作编程的天花板，本篇换个角度：**代码库本身怎么设计，AI 才更好用**——从一个具体技能讲起。

`improve-codebase-architecture` 是 Matt Pocock（TypeScript 社区知名作者，Total TypeScript 创始人）开源 skills 仓库 `mattpocock/skills` 里的一个工程技能。它做的事可以概括成一句话：

> **扫描代码库找「加深机会」（deepening opportunities），把浅模块改造成深模块，并以可视化 HTML 报告呈现，然后和你逐条深挖。**

这不是又一个"找代码异味"的 Lint 工具。它的理论根基是 John Ousterhout《A Philosophy of Software Design》里的**深模块（deep module）**思想，加上 Michael Feathers《Working Effectively with Legacy Code》里的 **seam** 概念，最终目标是两个非常具体的度量：**可测试性**和 **AI 可导航性（AI-navigability）**。

{/* truncate */}

## 一、先装起来

```bash
npx skills add mattpocock/skills --skill=improve-codebase-architecture
```

更新：

```bash
npx skills update improve-codebase-architecture
```

这个技能在仓库里的位置是 `skills/engineering/improve-codebase-architecture/`，由三部分组成：`SKILL.md`（主流程）、`agents/openai.yaml`（显式调用声明）、`docs/` 里的速查文档。注意它的 frontmatter 里有一行关键配置：

```yaml
disable-model-invocation: true
```

意思是：**模型不会自作主张调用它**。你必须主动输入 `/improve-codebase-architecture` 来触发。这符合它的定位——周期性健康检查，而不是日常开发链路里的一环。

## 二、理论核心：深模块 vs 浅模块

整个技能只围绕一个概念转：**depth（深度）**。

- **深模块**：大量行为藏在一个小而稳定的接口后面。调用方只需学会很少的东西，就能获得很多能力。
- **浅模块**：接口的复杂度几乎等于实现本身。调用方要理解的东西和实现里藏的东西一样多——接口没有"隐藏"任何东西。

Ousterhout 的经典例子是 Unix 文件 I/O：`open`/`read`/`write`/`close` 五个调用，背后是缓存、权限、文件系统驱动、磁盘调度这一大堆东西。这就是深模块。而一个只做 `getter`/`setter` 的类，接口和实现一样薄——典型浅模块。

但 `improve-codebase-architecture` 对 depth 的定义比 Ousterhout 原版更严格，它明确拒绝了一种流行解读：

> **"深度 = 实现行数 / 接口行数"** —— 这个定义被技能文档明确标注为 rejected framing，因为它奖励往实现里灌水。

它用的是 **depth-as-leverage**：深度是接口给调用方带来的杠杆。一个接口能让 N 个调用方 + M 个测试共享一份复杂度，它就是深的；如果删掉一个模块后，复杂度只是从它内部"搬"到 N 个调用方身上，它就是在赚辛苦费（pass-through）。

这引出了技能里最锋利的判断工具——**deletion test（删除测试）**：

> 想象删掉这个模块。如果复杂度随之消失，说明它是个 pass-through，没在隐藏任何东西；如果复杂度重新出现在 N 个调用方身上，说明它在干活，值得保留。

这个测试的妙处在于它把"这个模块好不好"从审美问题变成了可操作的问题：复杂度是集中了，还是只是被移动了？

## 三、共享词汇表：为什么术语要精确

技能里有一整套强制词汇（来自配套的 `/codebase-design` 技能）：

| 术语 | 含义 | 不要用 |
|---|---|---|
| **Module** | 任何有接口和实现的东西（函数/类/包/跨层切片） | unit, component, service |
| **Interface** | 调用方必须知道的一切：类型、不变量、错误模式、顺序、配置 | API, signature |
| **Depth** | 接口处的杠杆：每学一单位接口能获得多少行为 | — |
| **Seam** | 接口所在的位置，一个可以不改原地就改变行为的地方（Feathers 定义） | boundary |
| **Adapter** | 在 seam 处满足接口的具体实现，描述"角色"而非"实质" | — |
| **Leverage** | 调用方从深度获得的东西 | — |
| **Locality** | 维护者从深度获得的东西：变更、bug、知识集中在同一处 | — |

为什么抠这个？因为**语言一致本身就是设计工具**。如果 `CONTEXT.md` 里定义了 "Order"，候选方案就必须说"加深 Order intake 模块"，而不是"重构 FooBarHandler"，更不是"重构 Order 服务"。"service" 这个词会让人联想到 DDD 的 bounded context，而 "seam" 不会——术语污染会悄悄改变讨论的方向。

三条核心原则：

1. **The interface is the test surface** —— 调用方和测试穿过同一个 seam。如果测试要"穿过"接口去测内部状态，模块形状大概率错了。
2. **One adapter = hypothetical seam. Two adapters = real seam.** —— 只有一个实现的"接口"就是多绕了一层；有两个实现（典型：生产 + 测试）的接口才是真 seam。
3. **内部 seam 和外部 seam 要区分** —— 深模块内部可以有小零件，但它们不该通过接口暴露出来。

## 四、工作流程：Explore → HTML 报告 → Grilling

### Step 1: Explore（先限定范围，YAGNI）

技能明确要求**先决定看哪里，再去看**：

- 如果用户指明了方向（某个模块、某个子系统、某个痛点），直接采用，跳过推断。
- 否则 `git log --oneline` 往回走一段，找代码库的**热点**——最近一直在改的文件和区域优先。理由很务实：加深一个模块的收益来自"以后改它更轻松"，所以近期改动多的地方权重最高。
- 如果改动分散、没有明显热点，再放宽网。

然后读取 `CONTEXT.md`（领域词汇表）和相关 `docs/adr/`（架构决策记录），最后派 Explore 子代理去逛代码库。逛的时候记录"摩擦感"：

- 理解一个概念要蹦多少个模块之间？
- 哪里是浅模块（接口 ≈ 实现）？
- 哪里为了可测试性抽了纯函数，但真正的 bug 藏在调用方式里（没有 locality）？
- 哪些地方紧耦合的模块跨 seam 泄漏？
- 哪些部分没测试，或者通过当前接口很难测？

对每个疑似浅模块跑 deletion test。**只有"复杂度会集中"的才值得上报**——这个过滤器就是报告不会沦为"通用清理建议"的原因。

### Step 2: 输出可视化 HTML 报告

报告的物化形式很特别：**一个自包含的 HTML 文件，写到系统临时目录**（`$TMPDIR` → `/tmp` → `%TEMP%`），命名 `architecture-review-<timestamp>.html`，**绝不落进仓库**。然后用 `xdg-open`/`open`/`start` 打开给用户看。

技术栈是 Tailwind + Mermaid（都走 CDN），但混用手工 CSS/SVG：

- 关系是图状的就用 Mermaid（调用图、依赖、时序）
- 需要编辑感就用自绘 div/SVG（质量对比图、剖面图、折叠动画）

每个候选是一张卡片，包含：

- **Files** —— 涉及哪些文件/模块
- **Problem** —— 当前架构为什么造成摩擦
- **Solution** —— 纯白话描述要改什么
- **Benefits** —— 用 locality 和 leverage 语言解释收益，以及测试会怎么变好
- **Before / After 图** —— 并排自绘，直观展示"浅"和"加深"的区别
- **Recommendation strength** —— `Strong` / `Worth exploring` / `Speculative` 徽章

报告结尾是 **Top recommendation**：先做哪个、为什么。

两个重要约束：

1. **ADR 冲突处理**：如果候选和已有 ADR 矛盾，只在摩擦真实到值得重开 ADR 时才上报，并且必须在卡片里显著标注（如 warning callout "contradicts ADR-0007 — but worth reopening because…"）。不要罗列所有 ADR 禁止的理论重构。
2. **此时禁止提接口设计**。报告只到"候选"为止，然后问用户："Which of these would you like to explore?"

### Step 3: Grilling 循环

用户选中一个候选后，进入 `/grilling` 技能主导的对话循环——沿着决策树走：约束、依赖、加深后模块的形状、seam 后面是什么、哪些测试能活下来。

关键设计：**决策固化的副作用要内联写入文档**（由 `/domain-modeling` 技能驱动）：

- 给加深后的模块起了个 `CONTEXT.md` 里没有的名字？→ 立刻加进 `CONTEXT.md`（懒创建，文件不存在就建）。
- 对话中澄清了一个模糊术语？→ 当场更新 `CONTEXT.md`。
- 用户用有分量的理由拒绝了一个候选？→ 主动提议写成 ADR："要不要我把这条记成 ADR，免得以后的架构评审再提一遍？"——但只在理由确实承载信息时提议（"现在没空"这种临时理由和显而易见的理由都跳过）。
- 想探索加深模块的替代接口？→ 调 `/codebase-design`，用它的 design-it-twice 并行子代理模式：3+ 个子代理各拿一个完全不同的设计约束（最小接口 / 最大灵活 / 优化最常见调用方 / 端口与适配器），产出后逐个展示、散文对比、给出有立场的推荐。

## 五、为什么要"AI 可导航性"作为北极星

这个技能最反直觉的地方在于：它服务的对象不只是人，还有 AI。文档里反复出现的词是 **AI-navigability**。

想想 LLM 改代码时发生什么：它要把相关文件全部读进上下文。如果理解一个概念要蹦五个小模块，AI 的 context window 就被浅模块的接口噪音填满了——它读到的全是 getter/setter 和转发逻辑，真正的行为散落在各处。深模块意味着：**AI 只要读一个接口 + 一份实现，就能理解并正确修改一大块行为**。Locality（变更集中）对 AI 尤其重要——改动集中在文件级别，diff 干净，幻觉和遗漏的风险都更低。

这解释了为什么报告用 HTML + 可视化而不是纯文本：候选方案要在人机之间高效传达，图比文字省 context。也解释了为什么强调"AI 不会自己触发它"——这是给**人**做决策的工具，AI 只是执行者。

## 六、和配套技能的生态关系

`improve-codebase-architecture` 不是孤立技能，它是 Matt Pocock 技能生态里的一环：

| 技能 | 角色 |
|---|---|
| `/codebase-design` | 提供词汇表（module/depth/seam...）和设计工作台（design-it-twice） |
| `/improve-codebase-architecture` | **调研**：扫全库找加深候选，输出报告 |
| `/grilling` | 选中候选后，走决策树深挖 |
| `/domain-modeling` | 维护 CONTEXT.md 和 ADR，让领域模型跟上重构 |
| `/ask-matt` | 不知道用哪个时问它路由 |

定位很清晰：**这是周期维护工具，不是流水线步骤**。每几天跑一次，或者当"理解一个概念要蹦太多小模块"的感觉出现时跑一次。如果已经知道要改哪个模块、只是需要思考的语言，直接用 `/codebase-design`；这个技能是"找候选的普查"，那个是"设计的工作台"。

## 七、我的评价

作为工程实践，这个技能最值得借鉴的不是流程，而是三个设计决策：

1. **deletion test 当过滤器**。大多数"架构改进"建议死在"复杂度只是被移动了"这一点上。把测试前置到候选生成阶段，报告质量直接上一个台阶。
2. **语言先行**。先立一套精确的词汇表（含"不要用哪些词"），再谈架构。术语的精确性本身就是一种架构约束。
3. **把文档写进流程而非事后补**。CONTEXT.md 和 ADR 不是静态文件，是 grilling 循环的副产品——决策固化的那一刻就落盘，且只在该落盘的时候落盘（三条硬条件：难逆转、无上下文会费解、有真实权衡）。

对 LLM 协作开发尤其有价值的是它的北极星——**AI-navigability**。当代码库的单元是"深模块"而非"服务"，AI 在 context window 里能看到的东西才真正代表行为，而不是接口噪音。这可能是 AI 时代软件设计最被低估的一个转变：**代码的组织方式，决定了模型能多好地读懂并修改它**。

如果你的代码库最近开始"每改一个功能要开五个文件"，值得跑一次 `/improve-codebase-architecture` 看看报告里会蹦出什么。
