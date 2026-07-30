---
title: "Function Calling 诞生的背景：从 LLM 聊天到工具调用"
date: 2026-07-14T10:00:00+08:00
draft: false
tags: ["ai", "llm", "function-calling"]
categories: ["Tech"]
description: "LLM 从聊天到工具的进化史：Prompt Engineering 的局限、Function Calling 的诞生、以及它如何为 Agent 和 MCP 铺路"
---

# Function Calling 诞生的背景：从 LLM 聊天到工具调用

## 引言

2023 年 6 月 13 日，OpenAI 发布 GPT-4-0613 和 GPT-3.5-turbo-0613，首次正式引入 **Function Calling** 能力。当时社区的反应两极分化：一线开发者欢呼雀跃，但也有人不以为然地评价：「不就是让模型输出 JSON 吗？」

两年半过去，答案已经明朗。Function Calling 是 LLM 从「聊天机器人」走向「AI Agent」最关键的一步基础设施创新。本文不教你怎么调 API，而是从工程视角系统梳理：**Function Calling 到底解决了什么问题？它是怎么从社区 hack 演变为行业标准的？**

{/* truncate */}

---

## 一、纯文本 LLM 的工程天花板

在被 Function Calling「拯救」之前，开发者面临四个真实痛点。

**痛点 1：幻觉无法规避。** 问 GPT-3.5「今天北京天气怎么样」，它流畅地编一段预报——因为它根本不知道「今天」是哪天，但绝不会主动说不知道。在任何一个生产系统中，这种「自信的胡说八道」都是不可接受的。

**痛点 2：无法与外部系统交互。** 企业的核心逻辑在数据库、API、微服务里，不在 prompt 里。客服机器人查不到订单物流、取消不了订单、查不到库存——它再会聊天也没用。用户要的是解决问题，不是绕圈子。

**痛点 3：不能做确定性计算。** `$12345.67 × 0.13` 这种精确计算，LLM 是概率「猜」的，不是算的。日期计算、汇率转换、UUID 生成等 100% 精确的操作，纯文本模型完全不靠谱。

**痛点 4：输出不可控。** 同样 prompt，两次回答可能完全不同。对话场景下这是「温度」，但在「调用 API 删除一台服务器」的场景下，你绝不希望模型即兴发挥。

**一句话总结：LLM 擅长理解意图，但完全不具备执行动作的能力。** 而这个世界大部分有价值的事情，最终都是动作而非文字。

---

## 二、Function Calling 之前：Prompt Engineering 的暴力美学

在 OpenAI 官宣之前，社区已经在用 Prompt Engineering 强行让 LLM 输出结构化数据：

```python
import json, openai

# Function Calling 之前：靠 prompt 教模型输出 JSON
def call_llm_before(prompt: str) -> dict:
    response = openai.ChatCompletion.create(
        model="gpt-3.5-turbo",
        messages=[
            {"role": "system", "content": (
                "你是一个助手。如果用户想查天气，"
                "请以纯 JSON 格式输出："
                '{"action": "get_weather", "city": "城市名"}'
                "不要输出任何其他文字。"
            )},
            {"role": "user", "content": prompt},
        ],
    )
    text = response["choices"][0]["message"]["content"]
    # 靠 try-except 兜底，极其脆弱
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # 重试？延迟翻倍。不重试？直接崩。
        return {"action": "fallback", "error": "parse failed"}
```

这套方案能跑但极其脆弱，问题有三：

| 问题 | 表现 | 后果 |
|------|------|------|
| **格式不稳定** | 多一个换行、少一个逗号就解析失败 | `json.loads()` 异常 → 重试延迟翻倍 |
| **Prompt 膨胀** | 函数越多，prompt 越长 | 注意力稀释，参数字段丢失率上升 |
| **无类型契约** | 枚举值、嵌套对象全靠文字描述 | 输出结构频繁偏离预期 |

社区为此造了大量轮子——LangChain 的 `OutputParser`、Instructor、Guardrails、Jsonformer——本质上都是对 LLM 不稳定的输出做「正则匹配 + 重试 + 修复」的打补丁操作。

---

## 三、转折点：Fine-tuning 让模型原生理解结构化输出

OpenAI Function Calling 的核心突破不在 API 设计，而在**模型层面**。他们在 fine-tuning 阶段用大量结构化 function call 样本训练模型，让模型内化了四件事：

1. **意图识别**：判断用户输入是否需要调用函数
2. **参数提取**：从自然语言中精确提取参数（即使是隐式提及）
3. **类型感知**：真正「理解」string / number / boolean / object / array / enum
4. **多函数选择**：从候选列表中选出最合适的函数，或决定按顺序调用多个

用工程语言说：**之前是在 prompt 里教模型输出 JSON，Function Calling 是在训练阶段让模型学会这件事。** 从 prompt hack 变成模型原生能力——就像你不需要在 prompt 里说「请用中文回答」，因为模型在训练时已经内化了。

```python
# Function Calling 之后：模型原生输出结构化 JSON
response = openai.ChatCompletion.create(
    model="gpt-3.5-turbo-0613",
    messages=[{"role": "user", "content": "北京今天天气怎么样？"}],
    functions=[{
        "name": "get_weather",
        "description": "获取指定城市的当前天气",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {
                    "type": "string",
                    "description": "城市名称"
                }
            },
            "required": ["city"]
        }
    }],
)
# 直接拿到结构化输出，无需 json.loads() 碰运气
tool_call = response["choices"][0]["message"]["function_call"]
print(tool_call)
# → {"name": "get_weather", "arguments": '{"city": "北京"}'}
```

---

## 四、从 OpenAI 到行业标准：各厂商对比

Function Calling 不是 OpenAI 的专利。2023 下半年到 2024 年，全行业快速跟进：

| 厂商/项目 | 特性名 | 发布时间 | Schema 标准 | 独特设计 |
|-----------|--------|----------|-------------|----------|
| **OpenAI** | Function Calling | 2023.06 | JSON Schema 子集 | 首个实现，fine-tuned 原生能力 |
| **Anthropic** | Tool Use | 2024.03 | JSON Schema 兼容 | 支持并行工具调用，$tool_use_content_block |
| **Google** | Function Calling | 2024.02 | JSON Schema 兼容 | 支持函数声明的 Declaration 模式 |
| **Ollama** | Tool Support | 2024 | JSON Schema | Grammar-based 约束，本地推理 |
| **vLLM** | Tool Calls | 2024 | JSON Schema | 支持 guided decoding + grammar |

关键趋势是 **Schema 标准化**——所有主流厂商都在向 JSON Schema 收敛。你定义一次函数描述，可以在 OpenAI / Anthropic / Google 三家之间切换，迁移成本极低。同时，本地推理框架（Ollama、vLLM）通过 grammar-based guided decoding 解决了开源模型输出不稳定问题：

```python
# Ollama 工具调用示例
import ollama

response = ollama.chat(
    model="llama3.1",
    messages=[{"role": "user", "content": "北京的天气怎么样？"}],
    tools=[{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "获取天气信息",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {"type": "string"},
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
                },
                "required": ["city"]
            }
        }
    }],
)
# 输出同样符合 JSON Schema
tool_call = response["message"]["tool_calls"][0]
```

---

## 五、Function Calling 没有解决的问题

承认 Function Calling 重要，也要承认它的局限：

1. **单次调用范式**：原始的 Function Calling 是一次推理一次调用，无法表达多步推理链（ReAct）。Agent 框架（LangChain、AutoGen）在它之上搭了循环逻辑才解决。

2. **无状态**：每次 function call 是独立的，函数之间的上下文共享必须由上层代码维护。没有「工作流」层面的状态管理。

3. **Schema 表达能力有限**：JSON Schema 对复杂约束（参数互斥、动态引用、条件必填）支持不足。一些框架选择用 Pydantic 做中间层。

4. **缺少工具发现机制**：Agent 必须提前知道所有工具的 Schema 和地址，无法动态发现和协商。这在微服务架构下尤其痛苦。

5. **工具结果处理靠手动**：拿到函数返回值后怎么处理、怎么合并、怎么判断继续还是终止——全部由上层代码负责，openAI 的 API 不承诺任何「Agent runtime」能力。

---

## 六、Function Calling → MCP：工具调用的下一步

正是这些局限催生了 **MCP（Model Context Protocol）**。Anthropic 在 2024 年底开源的 MCP 在 Function Calling 基础上做了三层升级：

- **资源发现**：Agent 可以动态查询 Server 暴露了哪些工具，无需硬编码 Schema
- **有状态通知**：Server 可以主动推送资源变更，实现实时感知
- **标准化传输**：定义了一套通用的 HTTP 和 STDIO 传输协议，打破厂商锁

MCP ≠ Function Calling 的替代品，而是**在 Function Calling 的基础上增加了工具发现和上下文同步层**。两者关系可以理解为：Function Calling 定义了「工具怎么调用」，MCP 定义了「工具怎么被找到和被感知」。

当前行业格局：

```
应用层 Agent 框架（LangChain、AutoGen、CrewAI）
                    ↕
工具调用层（Function Calling / Tool Use）
                    ↕
工具发现层（MCP Server 注册 / 资源通知）
                    ↕
实际工具（数据库、API、浏览器、文件系统）
```

---

## 七、总结

Function Calling 的历史意义不在于它「让模型输出 JSON」——那只是表象。真正的价值在于它定义了 **LLM 与外部世界之间的标准化通信契约**：

- **输入标准**：功能描述 → JSON Schema
- **输出标准**：调用请求 → 结构化的 `function_call` 对象
- **架构模式**：推理（LLM）与执行（外部代码）的清晰分离

沿着这个思路往下走，Agent、MCP、Tool-Use 生态的爆发几乎是必然的。Function Calling 就是那个让一切成为可能的第一块多米诺骨牌。

---

*「LLM 擅长理解意图，Function Calling 让它们能执行动作。这两者的结合，才是 AI Agent 的真实起点。」*
