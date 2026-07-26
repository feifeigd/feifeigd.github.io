---
title: "AI 更擅长写 React 还是 Vue？被榜单掩盖的真相"
date: 2026-07-24T10:00:00+08:00
draft: false
tags: ["ai", "llm", "react", "vue", "frontend", "benchmark"]
categories: ["Tech"]
description: "主流榜单说 AI 写 React 更强，但它们根本没测过 Vue。唯一测过的学术基准显示差距远比想象小——真正的鸿沟在语料体量、英文语料主导和工具链的制度性锁定"
---

先从一个反直觉的数字说起。

如果你去看 2025 年的 JavaScript Rising Stars，React 以 24.2 万 GitHub stars 一骑绝尘，Vue 只有 5.26 万，看起来是近五倍的碾压级差距。但如果你记得几年前的榜单，Vue 和 React 的 stars 曾长期咬得很紧，远不是今天这个差距。

发生了什么？Vue 凉了吗？并没有。真相是 Vue 3 把仓库拆分成了 `vuejs/core`，stars 从零重新计数，而已归档的旧仓库 `vuejs/vue`（20.9 万 stars）不再计入新口径。同一个框架，换个统计口径，就从「并驾齐驱」变成了「不到 React 的四分之一」。

这个口径陷阱，是理解「AI 更擅长写 React 还是 Vue」这个问题的绝佳入口——因为**我们对这个问题的几乎所有「共识」，都建立在类似的口径陷阱之上**。

---

## 一、表面的共识：人人都说 AI 更会写 React

只要你在用 AI 辅助前端开发，大概率有过这种体感：让 Claude 或 GPT 写 React，一次通过率高、代码像模像样；换成 Vue，就容易出现新旧 API 混用、模板结构出错的情况。

这个体感并非空穴来风。生态体量的差距是实打实的：

- **npm 周下载量**：React 约为 Vue 的 4~10 倍以上（口径波动很大，含 CI、镜像和 React Native 的污染）；
- **Stack Overflow Developer Survey 2025**：React 使用率 44.7%，Vue 17.6%，相差约 2.5 倍；
- **GitHub 使用仓库数**：行业估计 React 约为 Vue 的 5~10 倍。

尤雨溪 2022 年在[知乎的回答](https://cloud.tencent.com/developer/article/2144162)里指出过，React 的 npm 下载量有相当一部分来自 React Native，按 Chrome DevTools 扩展的周活估算，纯 Web 端的真实使用比大约是 1.5~2:1，远没有 npm 数字那么夸张。

但请注意一个关键转折：**LLM 的训练语料来自公开代码，而不是真实使用分布**。npm 数字或许高估了「人的差距」，但公开仓库和代码语料里 React 的压倒性占比，恰恰就是 AI 看到的世界。

到这里为止，故事似乎很顺：React 语料多 → AI 写 React 更强。问题在于：**这个「更强」几乎从未被严肃地测量过**。

## 二、被榜单掩盖的事实：主流榜单根本没测过 Vue

开发者社区判断「AI 写前端谁强」，最常用的依据是 LMArena 的 WebDev Arena 榜单。但翻看 [WebDev Arena 的官方说明](https://arena.ai/blog/webdev-arena)（2025-06-13）会发现一个惊人的细节：它的系统提示词写死了「你是一名专家级前端 **React** 工程师……生成 React 组件……使用 TypeScript 和 Tailwind」。

换句话说，**WebDev Arena 是一个 React-only 榜单**。它只能告诉你哪个模型在 React 栈上相对更强，对「React vs Vue」这个问题零发言权。同理，Aider Polyglot 只到语言粒度，Design2Code 以 HTML 为目标，都不含框架维度。

真正系统对比过 React / Vue / Angular / vanilla 的学术基准，目前只有两个。

### DesignBench：头部模型 React 与 Vue 几乎打平

[DesignBench](https://arxiv.org/abs/2506.06251)（2025-06 首发，v3 更新于 2026-03）用 900 个网页样本测试了 9 个多模态大模型，结果相当微妙：

| 模型 | React 编译成功率（CSR) | Vue 编译成功率（CSR) |
| --- | --- | --- |
| Claude-3.7 | 0.9541 | **0.9746（全场最佳）** |
| GPT-4o | **0.9725** | 0.9492 |

不仅编译成功率互有胜负，在部分质量指标上 Vue 还反超了：Claude-3.7 的设计生成 CLIP 相似度 Vue 0.8319 > React 0.8083，设计编辑 MLLM 评分 Vue 8.36 > React 8.18。

论文另外两个结论同样值得记住：**所有模型在框架代码上都弱于 vanilla HTML/CSS**——框架特有语法对所有人都是瓶颈；两者的错误模式还不一样，React 主要栽在 JSX 解析类错误（Unexpected Token），Vue 主要栽在模板结构类错误（Missing End Tag）。Angular 则以 0.69~0.76 的编译成功率明显掉队。

### Web-Bench：多数模型 React 领先，但有反超

字节的 [Web-Bench](https://arxiv.org/abs/2505.07473)（2025-05）让四个框架共享同一套任务，Pass@2 对比如下：

| 模型 | React | Vue | Angular | Svelte |
| --- | --- | --- | --- | --- |
| Claude-3.7 | **65** | 30 | 40 | 25 |
| Claude-3.7-Thinking | 被反超 | **反超 React** | — | **反超 React** |

多数模型确实是 React 最高，论文也归因于 React 语料最多，以及「JSX 把 JavaScript 和 HTML 结合，提升了数据密度」。但必须把反面也摆出来：**Claude-3.7-Thinking 在 Vue 和 Svelte 上反超了 React**，论文原文明确写道 Vue/Svelte「与 HTML 语法相似，展现出更优的性能」。

两个基准合在一起，结论很清楚：**差距存在，但远比社区想象的小，而且在部分指标、部分模型上互有胜负。**至于中文社区流传的那组「Claude 写 React 一次通过率远超 Vue」的精确百分比，它出自 CSDN 内容农场，无方法、无样本量，没有任何引用价值，本文不予采信。

## 三、真正的差距在哪里

既然框架能力差距没那么大，「AI 写 React 更强」的体感从何而来？答案藏在三层结构性因素里。

### 1. 语料体量：JSX 排第 8，Vue 排第 16

最硬的证据来自 [Replit 公开的 replit-code-v1-3b 训练语料配比](https://huggingface.co/replit/replit-code-v1-3b)（基于 The Stack）：按 token 降序，**JSX 作为一门单独的「语言」排第 8**，比 Rust、C、Go、C++ 都多；而 **Vue 只排第 16**，还在 HTML 之后。

React 代码在训练语料里是「头等公民」，Vue 是「二等公民」。这不是框架优劣问题，是纯粹的数据分布问题。侧面证据是 [State of JS 2024](https://2024.stateofjs.com/)：Vue 的留存率 87% 反而高于 React 的 75%。用过 Vue 的人满意度不差，只是写 Vue 的公开代码少。

### 2. 英文语料主导：庞大的中文 Vue 社区近乎隐形

Vue 的用户大量集中在中国和亚洲，而 CommonCrawl 语料约 46% 是英文、中文只占 3% 左右，GPT 系语料的中文占比同样很低（&lt;0.1%~7%）。掘金、知乎、中文博客上浩如烟海的 Vue 教程、踩坑记录、最佳实践，在模型训练时几乎不存在。**Vue 社区的地理分布，恰好撞上了 AI 语料的语言盲区。**

### 3. 语料新旧混杂：同一个问题有三代「正确答案」

两个框架都有范式变迁带来的语料污染。React 经历了 class 组件（含已废弃生命周期）→ hooks（2019）→ Server Components（2022+）三代范式，[arXiv:2509.20277](https://arxiv.org/abs/2509.20277) 已证实 LLM 会生成引用已废弃组件的代码。Vue 这边，Vue 2 于 2023-12-31 正式 EOL，而 Options API 与 Composition API 官方承诺长期双轨并存，语料里 Vue 2 Options、Vue 2.7、Vue 3 `<script setup>` 三种风格混杂。有开发者[实测观察](https://vibecoder.me)（社区经验，非严格基准）发现 AI 生成 Vue 代码时常见新旧 API 混用。

另外需要标注的是，社区里流行的「Vue 三段式 SFC 模板/脚本/样式逻辑分散、对 AI 不友好，React 纯 JS 单上下文更利于生成」的说法（源自掘金等社区文章的对比表格），是**社区观点而非实测结论**——DesignBench 和 Web-Bench 的数据恰恰提示，类 HTML 的模板语法对模型也有独特优势。

### 4. 组件库格局：碎片化是 React 的隐藏成本

还有一个少有人提的反向变量：React 组件库是头部多极格局——MUI（约 9.5 万 stars）、Ant Design（约 9.4 万）、shadcn/ui（约 8.3 万）、Chakra（约 3.9 万）……LLM 需要记忆多套互不兼容的 API，生成的代码常常张冠李戴。Vue 则向 Element Plus 和 Vuetify 双头集中，模型「押对」的概率反而更高。有意思的是，shadcn/ui「把组件源码复制进项目」的模式意外地为 React 解了围——LLM 从「凭记忆猜 API」变成「读本地源码」，绕开了碎片化问题。这也提示 Vue 用户：让 AI 读项目里的真实代码，比让它背框架 API 可靠得多。

## 四、工具链的制度性锁定与马太效应

比语料更要命的是工具链。语料差距是历史存量，工具链的差距是每天都在发生的新增量：

- **v0 是架构级 React-only**：泄露的系统提示词硬性规定 React + Next.js App Router + Tailwind + shadcn/ui，第三方评测直言「用 Vue 的话 v0 完全没用」；
- **Lovable 固定 React + TypeScript + Vite + Tailwind + Supabase**，根本没有 Vue 选项；头部工具里只有 Bolt.new 支持 Vue，且复杂构建的质量不稳；
- 前端 AI 工具横评（PinkLime，2026-02）显示 Vue/Nuxt 的支持「全面降一档」，Claude Code 在 `.vue` 文件里偶尔还会默认套 React 的模式；
- 连学术界都默认 React：字节的 [Flame](https://arxiv.org/abs/2503.01619) 论文构建的是 React 生成基准，并自认「扩展到 Vue/Angular 是未来工作」。

这就形成了一个正反馈循环：**语料多 → 生成质量好 → 工具默认 React → 新项目更多选择 React → 产生更多语料**。[arXiv:2509.23261《The Matthew Effect of AI Programming Assistants》](https://arxiv.org/abs/2509.23261)用 13.5 万次真实生成请求加上 17 个任务 × 6 个技术栈的严格实验量化了这个效应：主流技术栈 1~3 次尝试就能完成任务，小众栈尝试 5 次以上仍然失败——论文把这个现象称为「**AI 生产力税**」（AI Productivity Tax）：选择小众栈，就要额外支付反复调试、人工兜底的成本。

但这篇论文里有个极易被忽略的关键细节：**在实验中，Vue + Spring Boot 属于「主流栈」，表现良好**。也就是说，Vue 的 AI 劣势高度集中在「纯前端生成工具」这个场景；在企业全栈场景里，Vue 根本不交「生产力税」。

## 五、Vue 阵营的补课：文档层与协议层

面对锁定，Vue 阵营的回应值得一提：2025 年 5 月，尤雨溪宣布 Vue、Vite、Rolldown 官方文档全面接入 [llms.txt](https://llmstxt.org/)（通过 vitepress-plugin-llms），让 LLM 能直接抓取结构化、无噪音的官方文档；社区也补位了 vite-plugin-vue-mcp、shadcn-vue-mcp 等 MCP 工具，让 AI Agent 能实时查询 Vue 组件和 API。

注意这个补课的形态：是「文档层 + 协议层」的建设，而不是「做一个 Vue 版 v0」。这种不对称本身很说明问题——**生态的弱势方选择把自己变成对 AI 更友好的数据源，而不是正面复制对方的工具链**。这条路能不能走通，还要观察。

## 六、给开发者的实际建议

综合以上证据，我的建议分三个场景：

**已经在用 Vue 的团队：不必换。**学术基准显示头部模型在 Vue 上的能力差距远小于体感差距，提示词质量和工程实践的权重更高。务实的做法是：项目里维护一份 `.cursorrules` / `CLAUDE.md`，明确锁定 Vue 3 + `<script setup>` + Composition API，杜绝新旧 API 混用；接入 llms.txt 文档源或 Vue 相关 MCP；把常用组件用法沉淀成项目内示例。这些措施能抹平大部分体感差距。

**重度依赖 AI 生成工具链的新项目：React 生态确实更省力。**如果你的工作流深度绑定 v0、Lovable 这类「描述需求 → 生成完整页面」的工具，那这不是框架之争，是工具链之争——这些工具根本不给 Vue 选项。这时候选 React 是对工具链现实的妥协，而不是对框架优劣的投票。

**企业 Java 全栈场景（Vue + Spring Boot）：按团队基因选，不用管 AI 焦虑。**马太效应论文自己的实验里这个组合就是「主流栈」，表现良好。AI 生产力税在这里不适用，让团队熟悉度和人才储备做决定即可。

---

最后回到开头的 stars 陷阱。「AI 更擅长 React」这个说法，很大程度上和「Vue stars 只有 React 的一个零头」是同一种错觉——统计口径、语料分布、工具链默认值共同制造的错觉。真实的情况是：AI 写 React 的**平均下限**确实更高，但那是数据分布和制度性锁定的产物；Vue 的 HTML 式模板本身并不吃亏，吃亏的是语料体量、中英文语料失衡和专用工具的缺位。

看清这一层的意义在于：框架选型应该基于团队、生态和业务，而不是基于一个被榜单放大的错觉。毕竟，AI 的「偏好」是会随着语料和工具变化的，而你的代码库要陪你很多年。
