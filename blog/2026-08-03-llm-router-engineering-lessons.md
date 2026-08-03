---
title: "LLM 路由的工程真相：大家都在做，为什么 Manifest 下线了自己的路由器？"
date: 2026-08-03T11:00:00+08:00
draft: false
tags: ["ai", "llm", "engineering", "performance", "inference", "opensource"]
categories: ["Tech"]
description: "拆解 LLM Router 的分类与实现，用 Manifest 的复盘数据说明：为什么多数场景下缓存与确定性比动态路由更划算"
---

2026 年 7 月末，两件事把「LLM 路由」推到了聚光灯下：Manifest 发表《Everyone is building LLM routers, we deprecated ours》在 Hacker News 拿到 130+ 分；Techstrong 则断言 LLM 路由器「已经从 niche 基础设施技巧变成主流产品品类」。Cursor 上线了 Cursor Router，Ramp 把内部自用的路由系统开放成产品，Meta 被曝在内部开发代号 SwitchBoard 的成本优化平台，YC S26 还出现了 Tokenless 这样的「自动换模型省钱」创业公司。

一面是产品化的火热，一面是亲自下场者（Manifest，一个 LLM 网关公司）的撤退。这篇文章不站队，而是把路由这件事拆开：它到底怎么工作、能省多少钱、隐性成本在哪，以及什么场景下它依然成立。

{/* truncate */}

## 一、先给「LLM 路由」分个类

「路由」这个词被用得太泛了。业界实际存在三种定位完全不同的东西：

| 类型 | 代表 | 核心职责 | 决策方式 |
|---|---|---|---|
| 网关（Gateway） | OpenRouter、LiteLLM、Portkey | API 统一、日志、密钥管理、故障转移 | 大多固定配置 + 简单策略 |
| 智能路由（Smart Router） | Martian、Not Diamond、RouteLLM | 每次请求选「最合适」的模型 | 分类器 / 强化学习 / 奖励模型 |
| 语义路由（Semantic Router） | Semantic Router 等 | 按意图做确定性分发 | embedding 相似度 |

网关解决的是「接得上、稳得住」，智能路由解决的是「选得对、花得省」，语义路由则是两者之间轻量、可解释的中间态。Techstrong 把路由策略细分为五类：**rule-based（规则）、semantic（语义）、predictive（预测）、cascading（级联）、cost-based（成本）**，实际产品通常组合多种。Cursor Router 的公开口径是「用 AI 按 query、context、任务复杂度、领域给请求分类」，底层是一个用 **60 万+ 线上请求训练的分类器**；OpenRouter 的 Auto Router 则直接内嵌了 Not Diamond。

## 二、路由决策是怎么做出来的

抛开营销，主流实现只有四种：

**1. 分类器路由（classifier）**。把「模型选择」建模成分类问题：特征来自请求文本、历史行为、用户上下文，输出是目标模型。RouteLLM 论文（LMSYS，2024）是这个方向的代表，用奖励模型打分 + 矩阵分解训练路由矩阵，路由矩阵给出「便宜模型 vs 昂贵模型」的偏好边界：

```python
# 示意：RouteLLM 风格的成本偏好路由
def route(query, threshold=0.5):
    score = router_matrix(query)   # 偏好「强模型」的连续分数
    return "strong" if score > threshold else "cheap"
```

**2. 语义路由（embedding）**。用向量相似度匹配预定义的意图槽位，确定性、可解释，适合「意图数量有限且清晰」的场景——比如把翻译、分类、抽取请求分给专用小模型。这是四类里最不容易翻车的。

**3. 级联路由（cascade）**。先上便宜模型，用验证器检查输出质量，不合格再升级到贵模型。这是**唯一把「任务复杂度未知」显式建模**的方案：

```python
def cascade(prompt, max_level=3):
    for model, validator in [(cheap, is_ok), (mid, is_ok), (frontier, is_ok)]:
        out = model(prompt)
        if validator(prompt, out):
            return out
    return frontier(prompt)
```

**4. 成本/延迟感知路由**。LiteLLM 提供的 weighted、latency-based、least-busy、lowest-cost 都是这类——不判断任务难度，只按运行时指标选模型。

## 三、Manifest 为什么下线了自己的路由器

Manifest 的 Router 2026 年 3 月上线，6 月宣布废弃，9 月 1 日彻底关闭。它把每个请求分成 **simple / standard / complex / reasoning** 四档，目标很朴素：简单任务别调贵模型。跑在 7,000 个云用户之上四个月后，结论却是：**「大多数场景下，省下的钱会在别处加倍还回去」**。四个论点值得逐条看：

### 论点 1：复杂度无法从 prompt 推断

prompt 只是任务的触发器，不是任务本身。`"evaluate the tests for the repo $GIT_REPO and improve them"`——如果目标是纯 HTML 个人网站，这是简单任务；如果目标是 Linux 内核仓库，这是地狱级任务。复杂度信息要在工具调用、检索、多轮探索之后才显形，而路由决策发生在这一切**之前**。用「请求这一刻」的特征预测「执行结束时」的复杂度，本质是在做一个条件概率很差的预测。

### 论点 2：缓存比路由更省钱

这是最容易被忽略的一条：**缓存命中输入比未命中便宜 75%-90%**（各家前缀缓存折扣不同，DeepSeek 一档甚至到 ~0.05x）。系统提示和对话历史占了请求 token 的大头，而它们恰好坐在 prompt 前缀——前缀缓存的最佳作用区。路由器的副作用是**反复横跳破坏缓存**：同一会话每次选不同模型，前缀缓存永远打不中。一个 cache-aware 的路由器必须给「初始选中的模型」加粘性，持续命中同一模型——讽刺的是，**路由器的正确做法是不路由**。

### 论点 3：路由破坏行为一致性

Manifest 的原话很直接：工程师应该像画家熟悉画笔一样理解模型差异，而不是把选型交给黑盒。「跨模型跳转会降低整体工作质量，也让人失去对工具的掌控」。对 Agent 类工作负载尤其致命：同一会话前半段用 A 模型、后半段用 B 模型，风格、格式、工具调用习惯全部漂移，下游解析器和评估体系跟着遭殃。

### 论点 4：不可预测性有成本

路由给系统引入了一个**新的不确定性层**：同样的输入，今天走便宜模型、明天走贵模型。于是 eval 要覆盖模型组合空间、system prompt 要兼容多模型行为、可观测性要同时追踪路由决策和模型输出。对人工对话也许还能容忍，对自动化 Agent 工作流，「管理这层不确定性」的工程成本常常超过路由省下的 token 钱。

## 四、路由什么时候仍然成立

否定一切不是答案。综合 Manifest 的复盘与 Techstrong 的观察，路由在四类场景下依然成立：

1. **故障转移与可用性（fallback/failover）**。这是网关场景，不是成本场景：主模型 5xx 或超时，切到备模型。决策信号是确定性的（错误码、延迟），不存在「猜复杂度」问题——**先做这个，再谈成本路由**。
2. **意图可明确判别**。请求类型在 prompt 里就写死（分类、抽取、翻译 vs 长程推理），用语义路由或规则路由即可，不需要训练分类器。
3. **成本优化的正确顺序**：先开 prompt caching（收益 75-90%，立竿见影），再考虑路由；路由必须带粘性，避免缓存击穿。Cursor Router 声称 30-50% 成本下降，但那是「分类 + 大量线上反馈」的组合拳，且没有把缓存损失计入。
4. **路由 + 网关分层**。让网关负责统一与稳定性，路由只做「同质模型池内的选型」——比如在多个等价开源模型之间按价格/延迟选，而不是在「小模型 vs 大模型」之间赌复杂度。

一个务实的最小实现是把确定性策略显式写出来，而不是交给黑盒：

```python
def route_request(req):
    # 1. 稳定前缀优先：同一会话保持粘性
    if req.session_id in ACTIVE_MODEL:
        return ACTIVE_MODEL[req.session_id]
    # 2. 明确的低复杂度信号走便宜模型
    if req.intent in {"translate", "classify", "extract"} and len(req.text) < 500:
        model = "cheap"
    else:
        model = "default"
    ACTIVE_MODEL[req.session_id] = model   # 记住，别跳
    return model
```

## 五、结论

Manifest 下线路由器不是「路由无用论」，而是**「路由是优化问题，不是能力问题」**：当模型选择从「哪家强」变成「哪家划算」时，路由器的收益是边际的、可计算的，而它的隐性成本（缓存击穿、行为漂移、评估复杂度、工程师的失控感）却难以量化。Techstrong 点破了一个商业模式上的悖论：**模型厂商希望你多用贵模型，路由器厂商希望你少花钱**——这个结构性张力决定了路由会一直存在，但也决定了它很难成为像「模型 API」一样的基础设施。

对大多数团队，今天的正确决策顺序是：**先缓存、再 fallback、最后才考虑动态路由**；如果一定要路由，把决策放在网关层、显式化、带粘性、且持续用线上数据验证它真的在省钱——而不是省下了 token，赔上了确定性。

**相关阅读**
- [GPT-5.6 价格与性能分析：前沿模型的成本结构](/blog/2026/07/31/gpt-5-6-price-performance-analysis)
- [LLM 量化技术实战指南：从 FP8 到 INT4 的生产级优化](/blog/2026/07/30/llm-quantization-production-guide)
- [上下文工程：把 Context 当作一等资源来管理](/blog/2026/08/02/context-engineering-deep-dive)
- [Agent 入侵事件技术复盘：Hugging Face 七月入侵全链条解析](/blog/2026/08/03/hf-agent-intrusion-analysis)

**参考来源**
- Manifest: [Everyone is building LLM routers, we deprecated ours](https://manifest.build/blog/why-we-deprecated-our-llm-router/)
- Techstrong: [LLM Routers Have Become a Service Category of Their Own](https://techstrong.ai/articles/llm-routers-have-become-a-service-category-of-their-own/)
- RouteLLM: [A framework for serving and evaluating LLM routers](https://github.com/lm-sys/RouteLLM)
- HN: [Everyone is building LLM routers, we deprecated ours](https://news.ycombinator.com/item?id=49126630)
- YC: [Tokenless — Automatic model switching to save money](https://usetokenless.com/)
