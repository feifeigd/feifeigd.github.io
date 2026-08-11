---
title: "拆解 Function Calling：大模型工具调用的全链路与坑"
date: 2026-08-11T16:00:00+08:00
draft: false
tags: ["ai", "llm", "agent", "function-calling", "tool-use", "engineering", "implementation"]
description: "从 tool definition 注入到 streaming parse，从 tool choice 强制调用到生产环境递归控制——Function Calling 全链路拆解与踩坑记录。"
---

Function Calling 是 LLM 走出聊天框的关键能力。从表面看就是调个 API、传几个 JSON schema 的事，但把这条路从头走到尾，坑全在下水道里。

这篇文章不聊"怎么用"，聊"里面长什么样"。以 OpenAI 和 Anthropic 为主线，穿插自己踩过的坑。

---

## 全链路：从定义到执行

一条工具调用链路分 6 个阶段：

```
tool definitions → prompt assembly → token generation → parsing → execution → result injection
```

每个阶段都可能翻车。

### 阶段 1：Tool Definition → System Prompt Injection

你传的 tool schema 不是直接发给模型的——各家会先把它"翻译"成某种文本格式塞进 system prompt 或特殊 token 段。

**OpenAI** 的做法：把你的 JSON schema 转成一个类似 TypeScript 函数签名的文本描述，拼进 chat template：

```
// OpenAI 内部近似格式（逆向推测，非官方文档）
namespace functions {
  // 查询天气
  type get_weather = (_: {
    city: string,  // 城市名称，如 "Beijing"
    unit?: "celsius" | "fahrenheit"
  }) => any;
}
```

**Anthropic** 则直接把 tool definition 作为 XML 块塞进 system prompt：

```xml
<tools>
  <tool_description>
    <tool_name>get_weather</tool_name>
    <description>查询指定城市的天气</description>
    <parameters>
      <parameter>
        <name>city</name>
        <type>string</type>
        <description>城市名称，如 "Beijing"</description>
      </parameter>
    </parameters>
  </tool_description>
</tools>
```

一个关键差异：**OpenAI 用特殊 token 标记 tool call 边界**（`<tool_call>` / `</tool_call>` 之类），模型被训练成在这些 token 之间输出结构化 JSON。Anthropic 的输出则是一段 XML 文本，靠后处理解析。

这意味着如果你自己搭推理服务（vLLM、TGI 等），tool calling 能否正常工作**强依赖 chat template 是否完整**。缺了 tool-related 的 special token 定义，模型要么完全不调工具，要么输出格式乱七八糟。

**坑 1：Chat template 不完整**

用 vLLM 部署开源模型时，很多人直接用默认的 `--chat-template`，结果 tool calling 全挂。正确做法：

```bash
# 从模型的 tokenizer_config.json 里找完整模板
python -c "from transformers import AutoTokenizer; \
  t = AutoTokenizer.from_pretrained('Qwen/Qwen2.5-7B-Instruct'); \
  print(t.chat_template[:2000])"
```

然后把完整模板传给 vLLM：

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --tool-call-parser hermes \
  --chat-template /path/to/chat_template.jinja
```

### 阶段 2：流式输出的结构性挑战

这是第二个大坑。前向推理的 token 序列是单向无回看的——模型不知道它"已经输出了多少个 `{`"。

**JSON 的结构约束（括号匹配、字符串引号闭合）只能靠模型自己"猜"。**

当你用 streaming 模式时，问题更严重。你没法等完整 JSON 到了再 parse——用户要实时看到 tool call 的 UI 反馈。

各家方案：

| 提供商 | 流式策略 |
|--------|----------|
| OpenAI | 帧级 parse：每当有新的 `arguments` chunk 到达，追加到 buffer 并做增量 JSON parse |
| Anthropic | 同样增量 parse，但用 XML 格式（方括号匹配问题换成标签闭合问题） |
| Hermes / Nous | 输出纯文本 tool call 格式（`<tool_call>...</tool_call>`），parse 更简单但依赖模型遵守格式 |

**坑 2：增量 JSON parse 不是 JSON.parse**

你不能直接用 `JSON.parse()` 解析流式 tool call argument——那不完整。需要一个**增量 JSON parser**。

一个最简单的实现（生产级自己写大概率有 bug，推荐用 `partial-json-parser` 或 `json-repair` 库）：

```python
import re
from typing import Iterator

def parse_streaming_tool_calls(chunks: Iterator[str]) -> list[dict]:
    """简化的增量 tool call 解析"""
    buffer = ""
    calls = {}
    
    for chunk in chunks:
        buffer += chunk
        # 尝试匹配 tool call 边界
        # 各家格式不同，这里是 Anthropic 的 XML 风格
        pattern = r'<function_calls>\s*(.*?)\s*</function_calls>'
        match = re.search(pattern, buffer, re.DOTALL)
        
        if match:
            # 解析内部的 <invoke> 块
            for invoke in re.finditer(
                r'<invoke name="(\w+)">\s*<parameter[^>]*>(.*?)</parameter>\s*</invoke>',
                match.group(1), re.DOTALL
            ):
                name = invoke.group(1)
                params = invoke.group(2)
                calls[name] = params
    
    return calls
```

现实是，生产环境需要处理：
- **跨 chunk 的 token 边界**：一个 token 可能被切成两半跨两个 chunk
- **partial JSON**：`{"city": "Bei` 过了一个 chunk 才收到 `jing"}`
- **多 tool call 并行**：`index` 字段追踪到哪个 tool call
- **argument 重传**：OpenAI 有时同一个 tool call 的 argument 会发两遍

### 阶段 3：Tool Choice——强制调用 vs 自由选择

`tool_choice: "required"` 强制模型必须调工具，这条看似简单实则暗坑无数。

**OpenAI 的做法**：tool_choice 直接影响 logit bias——给 tool-call-start 的 token 一个巨大的正 bias，确保模型第一个 token 就是 `<tool_call>`。

**坑 3：强制调用时模型瞎编参数**

当你设 `tool_choice: "required"` 但用户的输入跟任何工具都没关系时，模型会**硬编**一个 tool call。

```
User: "讲个笑话"
Model: get_weather(city="笑话")  // 🤦
```

解决方案：把"不调用工具"也暴露为一个工具选项：

```json
{
  "type": "function",
  "function": {
    "name": "no_tool_needed",
    "description": "当用户请求不需要调用任何工具时使用",
    "parameters": {
      "type": "object",
      "properties": {
        "response": {
          "type": "string",
          "description": "直接回答用户"
        }
      }
    }
  }
}
```

或者——更省 token 的做法——**不用 `required`，用 prompt engineering 在 system prompt 里约束**：

```
你必须对每个用户请求调用至少一个工具。如果没有任何工具匹配，调用 no_tool 并解释原因。
```

**Anthropic 的处理**：`tool_choice` 可以指定到具体 tool name，也可以用 `"any"` / `"auto"`。不像 OpenAI 那样用 logit bias 硬搞，而是用 system prompt 引导。副作用是 Anthropic 的 `"any"` 有时不生效，模型仍然可能不调工具。

### 阶段 4：Tool Result 注入与上下文管理

工具执行完毕后，结果需要注回对话上下文。这里有两个关键问题。

**Token 爆炸**

一个 API 返回 3000 行 JSON 你全塞回去，下一次请求直接爆 context。**该截断的不截断，模型会"记住"垃圾信息；截断了又可能丢掉关键数据。**

```python
def truncate_tool_result(result: str, max_chars: int = 8000) -> str:
    """截断 tool result 并加上警告"""
    if len(result) <= max_chars:
        return result
    
    truncated = result[:max_chars]
    return (
        f"{truncated}\n\n"
        f"[结果已截断。原始长度: {len(result)} 字符，"
        f"截断后: {max_chars} 字符。"
        f"如果需要的部分被截断，请缩小查询范围。]"
    )
```

**并行调用顺序**

OpenAI 支持并行 tool call（多个 tool call 在同一个 response 里），但它们是**同时执行**还是**顺序执行**取决于你的业务逻辑。

有依赖关系时必须串行：

```python
async def execute_tool_calls(tool_calls: list, dependency_graph: dict = None):
    """按依赖关系执行 tool call"""
    results = {}
    
    if not dependency_graph:
        # 无依赖——全部并行
        tasks = [execute_one(tc) for tc in tool_calls]
        for tc, result in zip(tool_calls, await asyncio.gather(*tasks)):
            results[tc.id] = result
        return results
    
    # 有依赖——拓扑排序后顺序执行
    for tier in topological_sort(dependency_graph):
        tasks = [execute_one(tc) for tc in tier]
        tier_results = await asyncio.gather(*tasks)
        for tc, result in zip(tier, tier_results):
            results[tc.id] = result
    
    return results
```

---

## 开源模型的 Tool Calling 解析器对比

不同开源模型用不同的 tool call 格式，全靠 parser 识别。以下是常见格式对比：

| 模型 | Tool Call 格式 | Parser |
|------|---------------|--------|
| Nous Hermes | `<tool_call>{"name": "...", "arguments": {...}}</tool_call>` | `hermes` |
| Mistral | `[TOOL_CALLS] [{"name": "...", "arguments": {...}}]` | `mistral` |
| Llama 3.x | 通过 `python_tag` 特殊 token 输出 JSON 格式 | `llama3_json` |
| Qwen 2.5 | `<tool_call>\n{"name": "...", "arguments": {...}}\n</tool_call>` | `hermes` (兼容) |
| DeepSeek | 类似 Hermes / Qwen 的 XML 包裹 JSON 格式 | `deepseek` |

**坑 4：Parser 不匹配**

vLLM 的 `--tool-call-parser` 设错了，模型照样跑、不报错，但 tool call 解析永远返回空。排查方法：

```python
# 查看模型实际输出的 raw text
from vllm import LLM

llm = LLM(model="microsoft/Phi-3.5-mini-instruct")
output = llm.generate([{"role": "user", "content": "..."}])
print(repr(output[0].outputs[0].text))  # 看 raw token 输出
```

如果输出格式和 parser 不匹配，要么换 parser，要么换模型。

---

## 生产环境踩坑清单

### 坑 5：Tool description 太长 → 模型"忘记"调用

每个 tool definition 都消耗 input token。5 个 tool 各 200 token 的 description，就是 1000 token。如果总 tool 数多到几十个，单是 tool schema 就占一半 context。

我的做法：**分层 tool selection**。先用一个轻量分类模型判断意图，只传相关的 3-5 个 tool：

```python
TOOL_GROUPS = {
    "database": ["query_db", "insert_db", "update_schema"],
    "file_system": ["read_file", "write_file", "list_dir"],
    "api": ["http_get", "http_post", "http_put"],
    "agent": ["delegate_task", "spawn_agent", "kill_agent"],
}

def select_tools(user_intent: str, all_tools: list) -> list:
    """根据意图选相关 tool group"""
    intent = classify_intent(user_intent)  # 轻量分类
    return [t for t in all_tools if t.group in TOOL_GROUPS.get(intent, [])]
```

### 坑 6：无限递归调用

模型调 tool → 返回结果 → 模型觉得不够 → 再调 tool → 再调 → ... 直到 token 耗尽。

**硬性终止条件**：

```python
MAX_TOOL_ROUNDS = 10

for round_num in range(MAX_TOOL_ROUNDS):
    response = await client.chat.completions.create(
        model="gpt-4o",
        messages=messages,
        tools=tools,
    )
    
    if not response.choices[0].message.tool_calls:
        break  # 模型自由回答了
    
    for tc in response.choices[0].message.tool_calls:
        result = await execute_tool(tc)
        messages.append({
            "role": "tool",
            "tool_call_id": tc.id,
            "content": result
        })
else:
    # 达到最大轮次，强制终止
    messages.append({
        "role": "user",
        "content": "已达到最大工具调用次数限制，请基于已获取的信息总结回答。"
    })
```

### 坑 7：Tool 执行超时不反馈

工具调了 HTTP API，API 挂了，30 秒超时。你不处理超时，模型就在那等着，用户也在那等着。

```python
import asyncio

async def execute_with_timeout(tool_call, timeout: float = 30.0):
    try:
        result = await asyncio.wait_for(execute_tool(tool_call), timeout=timeout)
        return result
    except asyncio.TimeoutError:
        return json.dumps({
            "error": "timeout",
            "message": f"工具 {tool_call.function.name} 执行超时（{timeout}s），请换一种方式查询。"
        })
```

把错误作为 tool result 返回，让模型自己决定下一步——比直接抛异常优雅得多。

---

## 一条关于 Anthropic Computer Use 的观察

Anthropic 的 `computer_use` 工具——截图→点击→截图→输入→截图——本质上是把 tool calling 推到了极致。每个操作都是 tool call，结果是一张新截图。6-8 轮 tool call 完成一页操作，token 消耗惊人（单次操作加一张高分辨率截图 ≈ 数千 token）。

这暴露了 tool calling 架构的一个根本限制：**当前的设计要求每次工具执行后都把结果全量塞回上下文**。对于长链 tool call 场景（浏览器操作、代码生成）这是无效循环。未来的方向可能是 tool result 的状态压缩——不是传完整截图，而是传一个"页面变了什么"的 diff。

---

## 总结

Function Calling 看起来只是一层薄薄的 API wrapper，但把它拆开来看，每个阶段都有暗坑：

1. **Tool definition 注入**：依赖 chat template，缺特殊 token 直接挂
2. **流式解析**：增量 JSON parse，不是 JSON.parse
3. **强制调用**：模型会编造参数，需要兜底 no-op tool
4. **结果注入**：截断策略决定信息质量
5. **Parser 匹配**：开源模型格式各异，parser 不对不报错但无结果
6. **递归控制**：必须有硬性终止条件
7. **超时处理**：把错误作为 tool result 返回，而非直接抛异常

把这些坑填了，Function Calling 才算从 Demo 级进化到生产级。
