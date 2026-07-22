---
title: "Function Calling 实践指南：角色、字段与报文处理全解析"
date: 2026-07-23T20:00:00+08:00
draft: false
tags: ["ai", "llm", "function-calling", "openai", "implementation"]
categories: ["Tech"]
description: "深入讲解 Function Calling 的实践细节——对话角色体系、可填写字段的完整列表、LLM 返回报文的解析与处理流程"
---

> 这是 Function Calling 系列的第二篇。第一篇《[Function Calling 诞生的背景](/blog/2026/07/14/function-calling-background)》聊了「为什么」需要 Function Calling，本文聚焦「怎么做」——从对话角色、字段定义到报文处理，手把手带你掌握 Function Calling 的实践细节。

## 前置知识：Function Calling 的基本流程

在深入细节之前，先快速过一遍 Function Calling 的标准流程：

\`\`\`
1. 定义函数列表（Schema）
   └→ 告诉 LLM 有哪些函数可用、每个函数需要什么参数

2. 构造对话上下文
   └→ 包含 system、user、assistant、tool 四种角色的消息

3. 调用 LLM API
   └→ 传入 functions 定义 + 对话历史

4. 解析 LLM 返回
   └→ LLM 返回 tool_calls（要调用的函数 + 参数）

5. 执行实际函数
   └→ 你的代码执行函数，获得真实结果

6. 将结果反馈给 LLM
   └→ 用 tool 角色将函数结果注入回对话

7. 重复步骤 3-6
   └→ 直到 LLM 不再需要调用函数，给出最终回答
\`\`\`

这个流程中有两个关键点需要深入理解：
- **对话中涉及的角色体系**：system、user、assistant、tool 的职责边界
- **函数定义的字段规范**：完整了解每个字段的作用和约束

下面逐个拆解。

---

## 一、对话中的四种角色

Function Calling 的对话不是简单的「用户问 → 模型答」，而是涉及四种角色的复杂协作。每种角色有明确的职责边界，理解这一点才能正确构造对话上下文。

### 1. System 角色——全局规则制定者

System 消息是整个对话的「宪法」，它定义了：

- **模型的行为边界**：什么能做、什么不能做
- **领域知识**：特定领域的专业术语、业务规则
- **响应风格**：语气、语言、格式偏好
- **安全策略**：敏感操作的前置检查

**典型 System Prompt 结构：**

\`\`\`python
system_prompt = \"\"\"
你是一个专业的电商客服助手，负责帮助用户查询订单、处理退换货、查询库存。

你的职责：
- 准确理解用户意图，必要时调用相应函数获取真实数据
- 不要编造订单号、物流信息等事实性数据
- 对于无法满足的需求，明确说明原因并提供替代方案

安全规则：
- 涉及订单修改、退款等操作时，必须先确认用户身份
- 不要直接调用需要高权限的函数，先请求用户确认

响应风格：
- 用中文回答，语气友好专业
- 对于数据类查询，用表格形式呈现
- 对于操作类任务，列出步骤并询问是否确认执行
\"\"\"
\`\`\`

**System 角色的关键约束：**
- System 消息只能在对话开始时发送一次（OpenAI API 限制）
- 它对整个对话生效，不能中途修改
- 权重最高——如果 user 和 system 矛盾，模型倾向于遵守 system

---

### 2. User 角色——自然语言输入者

User 消息是用户（或你的应用）的原始输入，特点是：

- **自然语言表达**：可以是口语化、模糊、不完整
- **隐含信息丰富**：用户可能不会显式说出所有参数
- **多轮对话支持**：可以通过追问补充信息

**User 消息的几种典型形态：**

\`\`\`python
# 形态 1：直接明确
{\"role\": \"user\", \"content\": \"帮我查订单 20241201001 的物流状态\"}

# 形态 2：模糊但可推导
{\"role\": \"user\", \"content\": \"看看我昨天买的手机发货了吗\"}
  # → 需要从历史上下文推导订单号

# 形态 3：多参数隐含
{\"role\": \"user\", \"content\": \"我要从北京飞上海，明天早上出发\"}
  # → destination=\"上海\", origin=\"北京\", date=明天日期
  # → time_range=\"morning\"（隐含约束）
\`\`\`

**处理 User 消息时的注意事项：**
- 不要过度解读：超出常识范围的「推导」容易出错
- 善用历史：之前的对话可能包含关键信息（订单号、偏好等）
- 必要时追问：当关键信息缺失时，让模型主动询问用户

---

### 3. Assistant 角色——决策中枢

Assistant 消息有两种形态，职责完全不同：

**形态 A：纯文本响应**

这是传统的「模型回答」，用于：
- 直接回答不需要函数调用的知识性问题
- 确认用户意图，澄清歧义
- 解释函数调用的结果

\`\`\`python
{
  \"role\": \"assistant\",
  \"content\": \"好的，我帮您查询订单 20241201001 的物流状态。\"
}
\`\`\`

**形态 B：函数调用决策（tool_calls）**

这是 Function Calling 的核心——模型决定调用哪些函数，并提取参数：

\`\`\`python
{
  \"role\": \"assistant\",
  \"content\": None,  # 注意：tool_calls 模式下 content 为 None
  \"tool_calls\": [
    {
      \"id\": \"call_abc123\",  # 调用 ID，用于后续关联结果
      \"type\": \"function\",
      \"function\": {
        \"name\": \"get_order_status\",
        \"arguments\": '{\"order_id\": \"20241201001\"}'
      }
    }
  ]
}
\`\`\`

**Assistant 决策的智能之处：**

1. **多函数同时调用**（并行）
   \`\`\`python
   {
     \"tool_calls\": [
       {\"function\": {\"name\": \"get_order_status\", ...}},
       {\"function\": {\"name\": \"get_user_profile\", ...}}
     ]
   }
   \`\`\`

2. **参数隐式提取**
   - 用户说「昨天」→ 模型计算出具体日期
   - 用户说「便宜」→ 模型根据上下文推断价格范围

3. **空值智能处理**
   - 可选参数未提及 → 自动留空，不传 null 或默认值
   - 必填参数缺失 → 决定先询问用户，而不是调用函数

4. **错误避免**
   - 发现参数明显不合理（如日期在 1900 年）→ 决定不调用，先确认

---

### 4. Tool 角色——函数结果的反馈者

Tool 消息是你把函数执行结果「喂回」给模型的唯一渠道。它有三个关键属性：

**属性 1：必须关联 tool_call_id**

\`\`\`python
{
  \"role\": \"tool\",
  \"tool_call_id\": \"call_abc123\",  # 必须匹配 Assistant 的 tool_calls[].id
  \"content\": '{\"status\": \"shipped\", \"tracking_number\": \"SF1234567890\", \"estimated_delivery\": \"2024-12-05\"}'
}
\`\`\`

**为什么必须关联？**
- 允许一次 Assistant 回复调用多个函数
- 模型需要知道哪个结果对应哪个调用
- 多轮对话场景下，避免混淆

**属性 2：内容要「模型可读」**

Tool 的 content 不是给用户看的，是给模型继续推理用的。设计原则：

- **结构化优于非结构化**：用 JSON 而不是自然语言
- **关键信息不能省略**：不要假设模型「应该知道」
- **错误信息要详细**：失败时给出具体原因，方便模型调整策略

\`\`\`python
# ❌ 错误示例
{
  \"role\": \"tool\",
  \"tool_call_id\": \"call_abc123\",
  \"content\": \"订单不存在\"  # 太模糊，模型不知道为什么
}

# ✅ 正确示例
{
  \"role\": \"tool\",
  \"tool_call_id\": \"call_abc123\",
  \"content\": '{\"error\": \"ORDER_NOT_FOUND\", \"message\": \"订单号 20241201001 不存在或已被删除\", \"suggestions\": [\"检查订单号是否输入正确\", \"联系客服确认\"]}'
}
\`\`\`

**属性 3：可以注入多个结果**

当一个 Assistant 调用了多个函数时，Tool 消息可以批量返回：

\`\`\`python
# Assistant 调用了两个函数：get_order_status 和 get_user_profile
# 你按顺序返回两个 Tool 消息

messages.append({
  \"role\": \"tool\",
  \"tool_call_id\": \"call_abc123\",
  \"content\": '{\"order_id\": \"20241201001\", \"status\": \"shipped\", ...}'
})

messages.append({
  \"role\": \"tool\",
  \"tool_call_id\": \"call_def456\",
  \"content\": '{\"user_id\": \"u12345\", \"name\": \"张三\", \"level\": \"VIP\", ...}'
})
\`\`\`

---

## 二、函数定义的完整字段列表

OpenAI 的 Function Definition 基于 JSON Schema，但不是所有字段都常用。以下是完整列表 + 实用建议。

### 函数级字段（function 对象外层）

| 字段 | 类型 | 必填 | 说明 | 实用建议 |
|------|------|------|------|----------|
| \`name\` | string | ✅ | 函数名称，用于标识 | 用 snake_case（如 \`get_user_order\`），避免与 JS 内置方法冲突 |
| \`description\` | string | ✅ | 函数功能描述 | 清晰描述**做什么**，不要只写函数名；多描述场景而非实现细节 |
| \`parameters\` | object | ✅ | 参数的 JSON Schema | 必须设置 \`type: \"object\"\`，即使没有参数 |
| \`strict\` | boolean | ❌ | 是否严格输出（OpenAI 新增） | 设为 true 可以减少格式错误，但限制模型灵活性，生产环境推荐 |
| \`additionalProperties\` | boolean | ❌ | 是否允许额外参数 | 设为 false 可以防止模型传多余字段，提高解析稳定性 |

**完整示例：**

\`\`\`python
function_def = {
  \"name\": \"search_products\",
  \"description\": \"根据关键词、分类、价格范围搜索商品。支持模糊匹配和排序。\",
  \"strict\": False,
  \"parameters\": {
    \"type\": \"object\",
    \"properties\": {
      # 详见下文
    },
    \"additionalProperties\": False
  }
}
\`\`\`

---

### 参数级字段（properties 对象内层）

#### 基础类型字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| \`type\` | string | 参数类型：\`string\` / \`number\` / \`integer\` / \`boolean\` / \`array\` / \`object\` | \`\"type\": \"string\"\` |
| \`description\` | string | 参数说明，模型用它理解如何提取 | \`\"description\": \"商品关键词，支持模糊搜索\"\` |

#### 字符串特有字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| \`enum\` | array[string] | 允许的枚举值 | \`[\"order_id\", \"tracking_number\", \"phone\"]\` |
| \`format\` | string | 字符串格式约束（非 JSON Schema 标准，但部分模型支持） | \`\"format\": \"date\"\` |

\`\`\`python
{
  \"search_type\": {
    \"type\": \"string\",
    \"description\": \"搜索方式：按订单号、运单号或手机号\",
    \"enum\": [\"order_id\", \"tracking_number\", \"phone\"]
  }
}
\`\`\`

#### 数字特有字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| \`minimum\` | number | 最小值（含） | \`\"minimum\": 0\` |
| \`maximum\` | number | 最大值（含） | \`\"maximum\": 1000000\` |
| \`exclusiveMinimum\` | boolean / number | 最小值（不含）或具体值 | \`\"exclusiveMinimum\": 0\` |
| \`exclusiveMaximum\` | boolean / number | 最大值（不含）或具体值 | \`\"exclusiveMaximum\": 999999\` |

\`\`\`python
{
  \"price_min\": {
    \"type\": \"number\",
    \"description\": \"价格下限（元），不填表示无下限\",
    \"minimum\": 0,
    \"exclusiveMaximum\": 1000000
  }
}
\`\`\`

#### 数组特有字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| \`items\` | object | 数组元素的类型定义 | 见下方示例 |
| \`minItems\` | integer | 最小元素数量 | \`\"minItems\": 1\` |
| \`maxItems\` | integer | 最大元素数量 | \`\"maxItems\": 10\` |
| \`uniqueItems\` | boolean | 元素是否必须唯一 | \`\"uniqueItems\": true\` |

\`\`\`python
{
  \"category_ids\": {
    \"type\": \"array\",
    \"description\": \"商品分类 ID 列表，最多 10 个\",
    \"items\": {
      \"type\": \"integer\",
      \"description\": \"分类 ID\"
    },
    \"minItems\": 1,
    \"maxItems\": 10,
    \"uniqueItems\": true
  }
}
\`\`\`

#### 对象特有字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| \`properties\` | object | 对象的属性定义 | 见下方示例 |
| \`required\` | array[string] | 必填字段列表 | \`[\"name\", \"age\"]\` |

\`\`\`python
{
  \"address\": {
    \"type\": \"object\",
    \"description\": \"收货地址\",
    \"properties\": {
      \"province\": {\"type\": \"string\", \"description\": \"省份\"},
      \"city\": {\"type\": \"string\", \"description\": \"城市\"},
      \"district\": {\"type\": \"string\", \"description\": \"区县\"},
      \"detail\": {\"type\": \"string\", \"description\": \"详细地址\"}
    },
    \"required\": [\"province\", \"city\", \"detail\"]
  }
}
\`\`\`

---

### 参数级通用字段

| 字段 | 类型 | 说明 | 实用建议 |
|------|------|------|----------|
| \`required\` | array[string] | 必填参数列表 | 只把真正必填的放进去，过多会降低模型调用成功率 |
| \`default\` | any | 默认值（当参数未提供时） | 慎用：Function Calling 中 default 常被忽略，更推荐在代码里处理 |
| \`examples\` | array[any] | 参数示例值 | 对复杂类型（object / array）非常有效，帮助模型理解结构 |

\`\`\`python
# examples 的强大之处
{
  \"filter\": {
    \"type\": \"object\",
    \"description\": \"搜索过滤条件\",
    \"properties\": {
      \"brand\": {\"type\": \"string\"},
      \"price_range\": {
        \"type\": \"object\",
        \"properties\": {
          \"min\": {\"type\": \"number\"},
          \"max\": {\"type\": \"number\"}
        }
      },
      \"in_stock\": {\"type\": \"boolean\"}
    },
    \"examples\": [
      {\"brand\": \"Apple\", \"price_range\": {\"min\": 5000, \"max\": 10000}},
      {\"in_stock\": true}
    ]
  }
}
\`\`\`

---

### 完整函数定义示例

\`\`\`python
functions = [
  {
    \"name\": \"search_products\",
    \"description\": \"搜索商品，支持关键词、分类、价格、品牌等多维度筛选，返回商品列表和分页信息。\",
    \"strict\": False,
    \"parameters\": {
      \"type\": \"object\",
      \"properties\": {
        \"keyword\": {
          \"type\": \"string\",
          \"description\": \"搜索关键词，支持商品名称、型号的模糊匹配。为空则返回所有符合条件的商品。\"
        },
        \"category_id\": {
          \"type\": \"integer\",
          \"description\": \"商品分类 ID，1-手机数码，2-家用电器，3-服装鞋帽，4-食品生鲜，5-图书文具\"
        },
        \"price_range\": {
          \"type\": \"object\",
          \"description\": \"价格范围约束\",
          \"properties\": {
            \"min\": {
              \"type\": \"number\",
              \"description\": \"最低价格（元），必须 ≥ 0\",
              \"minimum\": 0
            },
            \"max\": {
              \"type\": \"number\",
              \"description\": \"最高价格（元）\",
              \"minimum\": 0
            }
          },
          \"examples\": [
            {\"min\": 0, \"max\": 100},
            {\"min\": 1000, \"max\": 5000}
          ]
        },
        \"brand\": {
          \"type\": \"string\",
          \"description\": \"品牌名称，精确匹配。如：Apple、华为、小米\"
        },
        \"in_stock\": {
          \"type\": \"boolean\",
          \"description\": \"是否只显示有货商品。true-仅显示有货，false-显示全部（包含无货）\"
        },
        \"sort_by\": {
          \"type\": \"string\",
          \"description\": \"排序方式\",
          \"enum\": [\"relevance\", \"price_asc\", \"price_desc\", \"sales_desc\", \"rating_desc\"]
        },
        \"page\": {
          \"type\": \"integer\",
          \"description\": \"页码，从 1 开始\",
          \"minimum\": 1,
          \"default\": 1
        },
        \"page_size\": {
          \"type\": \"integer\",
          \"description\": \"每页数量，建议 10-50\",
          \"minimum\": 1,
          \"maximum\": 100,
          \"default\": 20
        }
      },
      \"required\": [],
      \"additionalProperties\": False
    }
  }
]
\`\`\`

---

## 三、LLM 返回报文的处理流程

LLM 的返回是 Function Calling 最容易出问题的地方。需要处理三种情况：文本响应、单次函数调用、多次函数调用。

### 情况 1：纯文本响应（不调用函数）

\`\`\`python
# LLM 返回
{
  \"id\": \"chatcmpl-abc123\",
  \"object\": \"chat.completion\",
  \"choices\": [
    {
      \"index\": 0,
      \"message\": {
        \"role\": \"assistant\",
        \"content\": \"好的，请问您要搜索哪个品牌的手机？预算大概是多少？\"
      },
      \"finish_reason\": \"stop\"
    }
  ]
}
\`\`\`

**处理逻辑：**
\`\`\`python
def handle_text_response(response):
    assistant_msg = response[\"choices\"][0][\"message\"]
    content = assistant_msg[\"content\"]
    
    # 直接返回给用户
    return content
\`\`\`

**关键点：**
- \`finish_reason: \"stop\"\` 表示对话结束
- \`content\` 不为 None，且没有 \`tool_calls\` 字段
- 这是最简单的场景，直接转发即可

---

### 情况 2：单次函数调用

\`\`\`python
# LLM 返回
{
  \"id\": \"chatcmpl-abc123\",
  \"choices\": [
    {
      \"index\": 0,
      \"message\": {
        \"role\": \"assistant\",
        \"content\": None,
        \"tool_calls\": [
          {
            \"id\": \"call_xxx123\",
            \"type\": \"function\",
            \"function\": {
              \"name\": \"search_products\",
              \"arguments\": '{\"keyword\": \"iPhone\", \"price_range\": {\"min\": 5000, \"max\": 10000}}'
            }
          }
        ]
      },
      \"finish_reason\": \"tool_calls\"
    }
  ]
}
\`\`\`

**处理逻辑：**

\`\`\`python
import json

def handle_function_call(response, functions_registry):
    assistant_msg = response[\"choices\"][0][\"message\"]
    tool_calls = assistant_msg[\"tool_calls\"]
    
    # 保存 Assistant 消息到对话历史
    messages.append(assistant_msg)
    
    # 执行每个函数调用
    tool_responses = []
    for tool_call in tool_calls:
        call_id = tool_call[\"id\"]
        function_name = tool_call[\"function\"][\"name\"]
        arguments_str = tool_call[\"function\"][\"arguments\"]
        
        # 1. 解析参数（可能失败）
        try:
            arguments = json.loads(arguments_str)
        except json.JSONDecodeError as e:
            # 参数解析失败，返回错误信息给模型
            tool_responses.append({
                \"role\": \"tool\",
                \"tool_call_id\": call_id,
                \"content\": json.dumps({
                  \"error\": \"INVALID_ARGUMENTS_JSON\",
                  \"message\": f\"参数 JSON 解析失败: {str(e)}\",
                  \"raw_arguments\": arguments_str
                })
            })
            continue
        
        # 2. 执行函数（可能失败）
        try:
            function_impl = functions_registry[function_name]
            result = function_impl(**arguments)
            # 将结果转为 JSON 字符串
            result_str = json.dumps(result) if not isinstance(result, str) else result
        except KeyError:
            # 函数不存在
            tool_responses.append({
                \"role\": \"tool\",
                \"tool_call_id\": call_id,
                \"content\": json.dumps({
                  \"error\": \"FUNCTION_NOT_FOUND\",
                  \"message\": f\"函数 {function_name} 不存在\",
                  \"available_functions\": list(functions_registry.keys())
                })
            })
            continue
        except Exception as e:
            # 函数执行失败
            tool_responses.append({
                \"role\": \"tool\",
                \"tool_call_id\": call_id,
                \"content\": json.dumps({
                  \"error\": \"FUNCTION_EXECUTION_ERROR\",
                  \"message\": str(e),
                  \"function\": function_name,
                  \"arguments\": arguments
                })
            })
            continue
        
        # 3. 成功执行，返回结果
        tool_responses.append({
            \"role\": \"tool\",
            \"tool_call_id\": call_id,
            \"content\": result_str
        })
    
    # 4. 将 Tool 结果加入对话历史，继续下一轮
    messages.extend(tool_responses)
    return messages  # 传回给 LLM API 继续对话
\`\`\`

**关键点：**
- \`finish_reason: \"tool_calls\"\` 表示需要执行函数
- 必须将 Assistant 消息保存到历史（即使 content 为 None）
- 每个函数调用都生成一个 Tool 响应，通过 \`tool_call_id\` 关联
- 错误处理要完善：JSON 解析错误、函数不存在、执行失败都要处理

---

### 情况 3：多次函数调用（并行）

LLM 可能一次性决定调用多个函数，例如用户问「查一下订单 123 的状态，顺便看看我的账户余额」。

\`\`\`python
# LLM 返回
{
  \"choices\": [
    {
      \"message\": {
        \"role\": \"assistant\",
        \"content\": None,
        \"tool_calls\": [
          {
            \"id\": \"call_aaa\",
            \"function\": {\"name\": \"get_order_status\", \"arguments\": '{\"order_id\": \"123\"}'}
          },
          {
            \"id\": \"call_bbb\",
            \"function\": {\"name\": \"get_account_balance\", \"arguments\": '{\"user_id\": \"user_456\"}'}
          }
        ]
      },
      \"finish_reason\": \"tool_calls\"
    }
  ]
}
\`\`\`

**处理逻辑：**

\`\`\`python
def handle_multiple_function_calls(response, functions_registry):
    assistant_msg = response[\"choices\"][0][\"message\"]
    tool_calls = assistant_msg[\"tool_calls\"]
    
    # 保存 Assistant 消息
    messages.append(assistant_msg)
    
    # 并行执行所有函数（如果函数之间无依赖）
    # 如果有依赖关系，按顺序执行
    tool_responses = []
    
    for tool_call in tool_calls:
        call_id = tool_call[\"id\"]
        function_name = tool_call[\"function\"][\"name\"]
        arguments = json.loads(tool_call[\"function\"][\"arguments\"])
        
        try:
            result = functions_registry[function_name](**arguments)
            result_str = json.dumps(result) if not isinstance(result, str) else result
        except Exception as e:
            result_str = json.dumps({\"error\": str(e)})
        
        tool_responses.append({
            \"role\": \"tool\",
            \"tool_call_id\": call_id,
            \"content\": result_str
        })
    
    # 按 tool_call_id 排序（保持与 tool_calls 顺序一致）
    tool_responses.sort(key=lambda x: x[\"tool_call_id\"])
    
    messages.extend(tool_responses)
    return messages
\`\`\`

**关键点：**
- 多个函数调用可以并行执行（如果无依赖）
- Tool 响应的顺序最好与 \`tool_calls\` 保持一致
- 即使某个函数失败，其他函数的结果仍要返回

---

### 完整处理流程（伪代码）

\`\`\`python
def chat_with_functions(user_message, conversation_history, functions_registry):
    # 1. 构造当前对话上下文
    messages = conversation_history + [{\"role\": \"user\", \"content\": user_message}]
    
    # 2. 调用 LLM API
    response = openai.chat.completions.create(
        model=\"gpt-4o\",
        messages=messages,
        tools=[{\"type\": \"function\", \"function\": func_def} for func_def in functions_registry.values()],
        tool_choice=\"auto\"  # 让模型自动决定是否调用函数
    )
    
    assistant_msg = response.choices[0].message
    
    # 3. 判断响应类型
    if assistant_msg.tool_calls:
        # === 函数调用场景 ===
        conversation_history.append(assistant_msg)  # 保存 Assistant
        
        tool_responses = []
        for tool_call in assistant_msg.tool_calls:
            # 执行函数并收集结果
            result = execute_function(tool_call, functions_registry)
            tool_responses.append({
                \"role\": \"tool\",
                \"tool_call_id\": tool_call.id,
                \"content\": json.dumps(result)
            })
        
        conversation_history.extend(tool_responses)
        
        # 递归调用，继续对话
        return chat_with_functions(None, conversation_history, functions_registry)
    
    else:
        # === 纯文本响应场景 ===
        conversation_history.append(assistant_msg)
        return assistant_msg.content  # 返回给用户

def execute_function(tool_call, functions_registry):
    func_name = tool_call.function.name
    arguments = json.loads(tool_call.function.arguments)
    
    func = functions_registry[func_name]
    return func(**arguments)
\`\`\`

---

## 四、常见问题与最佳实践

### 问题 1：模型返回的参数类型不符合 JSON Schema

**现象：**
\`\`\`json
// 定义时要求 integer，模型返回了 \"123\"（字符串）
{\"user_id\": \"123\"}  // 应该是 123
\`\`\`

**原因：**
- 模型有时会「过度泛化」，将数字用字符串表示
- 特别是 phone、order_id 这种「看起来像字符串的数字」

**解决方案：**
\`\`\`python
def validate_and_cast(value, schema):
    if schema[\"type\"] == \"integer\" and isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            pass
    # 其他类型转换...
    return value

arguments = {k: validate_and_cast(v, param_schema) for k, v in arguments.items()}
\`\`\`

---

### 问题 2：模型调用不存在的函数

**现象：**
模型调用了一个你根本没定义的函数，如 \`get_user_info_v2\`。

**原因：**
- 函数描述不够清晰
- 模型认为你的函数「不合适」，自己「想」了一个更好的

**解决方案：**
- 在 System Prompt 中明确：「只能调用提供的函数，不能编造新函数」
- 确保函数定义覆盖所有场景
- 在 Tool 响应中返回错误并告诉模型可用函数列表

---

### 问题 3：函数执行失败后模型陷入循环

**现象：**
模型反复调用同一个函数，每次都失败。

**原因：**
- 错误信息不够详细，模型不知道怎么调整
- 模型认为「再试一次可能成功」

**解决方案：**
\`\`\`python
# 在错误信息中给出明确建议
{
  \"error\": \"INVALID_ORDER_ID\",
  \"message\": \"订单号格式错误，应为 10 位数字\",
  \"user_input\": order_id,
  \"suggestions\": [
    \"请检查订单号是否正确\",
    \"订单号示例：20241201001\"
  ]
}

# 在 System Prompt 中增加：
# \"如果同一个函数连续失败 3 次，停止调用并告知用户无法完成\"
\`\`\`

---

### 问题 4：Context 过长导致 Token 溢出

**现象：**
对话多次后，\`context_length_exceeded\` 错误。

**原因：**
- 函数调用的结果太长
- 历史对话积累太多

**解决方案：**

**策略 1：压缩函数结果**
\`\`\`python
# ❌ 返回完整数据
{
  \"products\": [/* 100 个商品 */]
}

# ✅ 返回摘要
{
  \"total\": 100,
  \"page\": 1,
  \"products\": [/* 前 3 个 */],
  \"note\": \"共 100 个商品，仅展示前 3 个，如需更多请翻页\"
}
\`\`\`

**策略 2：智能裁剪历史**
\`\`\`python
def trim_conversation(messages, max_tokens=4000):
    # 保留 System
    # 保留最近 5 轮对话
    # 保留所有 Tool 结果（因为可能被引用）
    # 删除早期的 Assistant / User 对话
    pass
\`\`\`

---

### 最佳实践总结

| 场景 | 建议 |
|------|------|
| **函数命名** | 使用动词开头：\`get_xxx\`, \`search_xxx\`, \`create_xxx\`, \`delete_xxx\` |
| **参数命名** | 使用 snake_case，语义清晰：\`user_id\` 而不是 \`uid\` |
| **描述质量** | 描述「做什么」而非「怎么实现」；举例子比讲原理更有效 |
| **错误处理** | 返回结构化错误，包含错误码、消息、建议、原始输入 |
| **结果格式** | 尽量用 JSON，避免自然语言；大数据要摘要 |
| **历史管理** | 定期压缩；保留最近轮次 + 关键 Tool 结果 |
| **测试覆盖** | 测试所有分支：文本响应、单次调用、多次调用、错误场景 |

---

## 总结

Function Calling 不是「让模型输出 JSON」这么简单，它涉及：

1. **四种角色的协作**：system 制定规则，user 输入意图，assistant 决策调用，tool 反馈结果
2. **完整的字段体系**：从函数级的 name / description / strict，到参数级的 type / enum / minimum / items / examples
3. **健壮的报文处理**：区分三种响应类型，处理 JSON 解析、函数执行、错误反馈、历史管理

理解了这些细节，你才能在生产环境中构建稳定可靠的 Function Calling 系统。

下一篇我们会聊进阶话题：**Function Calling 的高级模式——链式调用、并行执行、条件分支、错误恢复**。

---

*延伸阅读：*
- [Function Calling 诞生的背景](/blog/2026/07/14/function-calling-background)
- [OpenAI Function Calling 官方文档](https://platform.openai.com/docs/guides/function-calling)
- [JSON Schema 规范](https://json-schema.org/)
