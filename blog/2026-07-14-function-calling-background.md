---
title: "Function Calling 诞生的背景：LLM 为什么要学会调用函数"
date: 2026-07-14T22:00:00+08:00
draft: false
tags: ["ai", "llm", "function-calling", "agent", "openai"]
categories: ["Tech"]
description: "从 LLM 的能力边界出发，理解 Function Calling 为什么是必然产物"
---

## 引言

2023 年 6 月，OpenAI 在 GPT-4-0613 和 GPT-3.5-turbo-0613 中首次引入了 **Function Calling** 能力。当时很多人第一反应是："这不就是让模型生成 JSON 吗？有什么特别的？"

两年后再回头去看，Function Calling 是 LLM 从"聊天玩具"走向"生产工具"的关键一步。本文不讲 API 怎么调用，而是聊清楚一个更根本的问题：**Function Calling 到底解决了什么问题？它为什么一定会出现？**

{/* truncate */}

---

## 纯文本 LLM 的能力天花板

GPT-3 在 2020 年横空出世，ChatGPT 在 2022 年底引爆全球，LLM 展现出了惊人的对话和生成能力。但你在生产环境用过就知道，纯文本模型有几个绕不过去的死穴：

### 1. 幻觉问题——模型不知道自己不知道

你问模型"今天北京天气怎么样？"，它会流畅地编一段天气预报出来。因为训练数据截止到某个时间点，它根本不知道"今天"是什么。更致命的是，它**不会主动告诉你它不知道**，而是用最自信的语气胡说八道。

### 2. 无法与外部系统交互

企业的核心业务逻辑跑在数据库、API、微服务上，而不是 LLM 的 prompt 里。一个客服机器人如果查不到订单号对应的物流状态、不能取消订单、不能查询库存，那它再"会聊天"也没用——用户要的是解决问题，不是听你绕圈子。

### 3. 无法执行确定性计算

$12345.67 \times 0.13$ 这种精确计算，LLM 是靠概率"猜"出来的，而不是算出来的。你让 GPT-3.5 做两位数乘法都有概率出错。更不用说日期计算、汇率转换、UUID 生成这些必须 100% 准确的操作。

### 4. 回答不可控

同样的 prompt，两次回答可能完全不一样。在对话场景下这或许是"温度"的美，但在"调用 API 删除一台服务器"这种场景下，你绝不希望模型即兴发挥。

**总结一句话：LLM 擅长"理解意图"，但完全不具备"执行动作"的能力。** 而这个世界大部分有价值的事情，最终都是"动作"而非"文字"。

---

## 早期解决方案：Prompt Engineering 的暴力美學

在 Function Calling 出现之前，大家已经在用 Prompt Engineering 强行让 LLM 输出结构化数据。大概长这样：

```
你是一个助手。如果用户想查天气，请严格按照以下 JSON 格式输出：
{"action": "get_weather", "city": "城市名"}

用户：北京今天天气怎么样？
```

然后代码里 `json.loads()` 解析模型输出，匹配到对应函数去执行。

这套方案**能跑，但极其脆弱**。问题包括：

- **格式不稳定**：模型偶尔多输出一个换行、一个逗号，`json.loads()` 直接炸。加个 `try-except` 再重试？那延迟就翻倍了。
- **依赖 prompt 质量**：你需要在 prompt 里精确描述每个函数的参数、类型、约束。参数一多，prompt 膨胀到几千 token，不仅慢，而且模型的注意力会被稀释。
- **无法处理复杂嵌套**：嵌套对象、数组、枚举类型，靠纯 prompt 描述会让模型困惑，输出结构经常不符合预期。
- **没有官方契约**：每个人都在自己的代码里手写 JSON Schema 的"prompt 翻译"，没有任何标准化。

那时候社区做了很多轮子——LangChain 的 `OutputParser`、Guardrails、Instructor——本质上都是在对 LLM 的不稳定输出做"正则匹配 + 重试 + 修复"的补丁。

---

## 关键转折：Fine-tuning 让模型"原生理解"结构化输出

OpenAI 在 2023 年 6 月推出了 Function Calling，核心改动不是 API 层面的——而是**模型层面**的。

他们做了什么？

**在 fine-tuning 阶段，用大量结构化的 function call 样本训练模型，让模型学会：**

1. **精确识别**：用户说的话里，哪些意图需要调用函数
2. **参数提取**：从自然语言中精确提取函数所需的参数，即使参数是隐式的
3. **类型感知**：真正"理解"字段的类型（string / number / boolean / object / array / enum），而不是靠 prompt 猜测
4. **空值处理**：知道哪些参数是必填的，哪些是可选的，可选参数没提到时就留空
5. **多函数选择**：面对多个候选函数时，能选择最合适的那一个，或者决定需要按顺序调用多个

用更通俗的话说：**之前的方案是在 prompt 里"教"模型输出 JSON，Function Calling 是让模型在训练阶段就"学会"了这件事。** 从 prompt hack 变成了模型 native capability。

这是一个质变。就像你不需要在 prompt 里说"请用中文回答"，模型自己就知道——因为它在训练时已经内化了这个概念。

---

## Function Calling 真正解决的核心问题

把 Function Calling 理解为"让模型输出 JSON"是只见树木不见森林。它本质上是一种**连接 LLM 与外部世界的标准化协议**。

### 1. 将"意图"桥接到"动作"

```
用户："帮我订一张明天去上海的机票"
     ↓
LLM 理解意图 → 结构化输出：
{
  "function": "search_flights",
  "parameters": {
    "destination": "上海",
    "date": "2026-07-15"
  }
}
     ↓
代码执行函数 → 返回真实结果
     ↓
LLM 将结果转为自然语言："明天去上海有以下航班..."
```

LLM 只负责"理解意图"和"组织语言"，**真实数据由外部系统提供**。幻觉问题在关键环节被绕开了。

### 2. 分离"推理"和"执行"

这是架构层面的关键演进。纯文本 LLM 把推理和执行混在一起——它直接输出"最终答案"，你没法干预中间过程。Function Calling 创造了一个清晰的断点：

- **LLM 负责推理**：理解用户要什么，决定调用哪个函数，提取什么参数
- **你的代码负责执行**：真正调 API、查数据库、做计算
- **LLM 负责组织回复**：把执行结果转换成用户友好的语言

每一步都是可观测、可拦截、可修正的。这为构建"安全可控"的 AI 系统打下了基础。

### 3. 解决"时效性"和"私有数据"的死结

这是 Function Calling 最实际的商业价值：

- **实时数据**：天气、股价、新闻、汇率——这些通过 Function Calling 接入实时 API，不需要重新训练模型
- **私有数据**：订单系统、CRM、内部知识库——Function Calling 让 LLM 可以在需要时查询，而不是把所有数据塞进 prompt（既有隐私风险又有长度限制）
- **写操作**：发邮件、创建工单、下订单——这些 LLM 自己做不到，但通过函数调用完全可以

**Function Calling 让 LLM 从"一个聪明的数据库"变成了"一个能办事的接口"。**

---

## 生态演进：从 OpenAI 到行业标准

Function Calling 不是 OpenAI 一个人的发明，而是整个行业共识的产物。几乎在同一时期：

- **Anthropic** 在 Claude 中推出了 **Tool Use**，理念完全一致
- **Google** 在 Gemini 中提供了 **Function Calling** 支持
- **开源模型**通过 fine-tuning 支持 function calling——NexusRaven、Gorilla、Functionary 等专用模型
- **推理框架**如 vLLM、Ollama 原生支持 tool calling 的 grammar 约束
- **LangChain / LlamaIndex** 将 function calling 作为 Agent 机制的核心

更重要的是，function 的 schema 定义正在收敛到 **JSON Schema** 这个标准上。你定义的函数只要符合 JSON Schema 规范，就可以在 OpenAI、Anthropic、Google 三家 API 之间切换，迁移成本极低。

这标志着 Function Calling 从一个"API 特性"升级为 **LLM 生态的基础设施**。

---

## 再往前看：从 Function Calling 到 Agent

理解了 Function Calling 诞生的背景，你才能理解为什么 2024-2025 年 Agent 会这么火。

Function Calling 只是第一步——**单次调用、单个函数**。Agent 是这个逻辑的多步延伸：

1. **ReAct 模式**：Reasoning + Acting 循环，模型思考→调用函数→观察结果→再思考→再调用
2. **多步规划**：复杂任务拆解为多个子任务，每个子任务可能需要多次函数调用
3. **工具组合**：自动决定使用搜索、计算器、代码执行器、文件读写等不同工具
4. **错误恢复**：函数调用失败后，模型能分析错误信息并调整策略

而这些所有能力的基石，恰恰就是 **Function Calling 定义的那个"从意图到结构化动作"的转化能力**。

---

## 一张图总结演进路径

```
2020-2022: 纯文本 LLM
  └→ 对话流畅，但无法执行动作，有幻觉

2022-2023: Prompt Engineering 硬解
  └→ 能输出 JSON 了，但脆弱、不稳定、难维护

2023.06: OpenAI Function Calling
  └→ 模型原生理解结构化输出，标准化协议

2023-2024: 全行业跟进 + JSON Schema 标准化
  └→ Anthropic Tool Use / Gemini Function Calling / 开源模型

2024-2025: Agent 时代
  └→ 多步推理 + 工具组合 + 自主规划
  └→ 基石：Function Calling
```

---

## 最后

Function Calling 没那么神秘。它本质上就是解决了 LLM 从"会说话"到"会办事"之间的那一公里路。

如果你今天在构建 AI 应用，function calling 不是一个可选项——它是把 LLM 接入真实业务系统的唯一可靠手段。理解了它为什么诞生，你才能真正用好它。
