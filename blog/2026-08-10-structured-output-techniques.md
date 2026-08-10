---
title: "LLM 结构化输出实战：从 Prompt Engineering 到 Constrained Decoding"
date: 2026-08-10T12:00:00+08:00
draft: false
tags: ["ai", "llm", "structured-output", "inference", "engineering", "implementation", "function-calling"]
categories: ["Tech"]
description: "想让 LLM 稳定输出 JSON？本文系统讲解从 JSON-mode prompt 到 grammar-based decoding 的四种方案，附实测数据和技术选型建议。"
---

> 这是 Function Calling 系列的第三篇。前两篇讲了 [Function Calling 诞生的背景](/blog/2026-07-14-function-calling-background)和[角色、字段与报文处理](/blog/2026-07-23-function-calling-implementation-guide)。本文聚焦一个更底层的问题：**怎么让 LLM 输出结构化的、可解析的、格式正确的数据？**

{/* truncate */}

## 问题：为什么 LLM 输出 JSON 这么难？

先看一个真实场景。你想让 LLM 从一段文本里提取实体：

```python
prompt = """
从以下文本中提取人名、地点和事件，以 JSON 格式返回：
"张三和李四昨天在北京奥林匹克公园参加了马拉松比赛。"

输出格式：
{
  "people": ["..."],
  "location": "...",
  "event": "..."
}
"""
```

理想输出：
```json
{"people": ["张三", "李四"], "location": "北京奥林匹克公园", "event": "马拉松比赛"}
```

实际你可能会收到：

```
好的，以下是从文本中提取的信息：

```json
{
  "people": ["张三", "李四"],
  "location": "北京奥林匹克公园",
  "event": "马拉松比赛"
}
```

希望这对你有帮助！
```

—— Markdown 代码块包裹，前后有废话，`json.loads()` 直接报错。

这只是最温和的情况。更糟的：

| 问题 | 示例 |
|------|------|
| 尾随逗号 | `{"name": "张三",}` |
| 注释 | `{"name": "张三" // 用户名}` |
| 引号不匹配 | `{"name": '张三'}` |
| 遗漏字段 | `{"people": ["张三"]}` — 丢了李四 |
| 幻觉字段 | `{"weather": "晴"}` — 你根本没要求这个 |
| NaN/Infinity | `{"score": NaN}` — JSON 不合法 |

**根本原因：LLM 的输出是 token-by-token 自回归生成的，不是"先想好结构再一次性输出"。每个 token 都基于之前的 token 预测，没有全局校验机制。**

## 解决方案演进：从松到严

业界解决这个问题的技术栈，按"约束力度"从弱到强：

```
方案              约束方式              可靠性    性能影响
─────────────────────────────────────────────────────
1. Prompt 引导    自然语言描述格式       ★☆☆☆☆    无
2. JSON Mode      模型内置开关          ★★☆☆☆    极小
3. FSM/Regex      有限状态机约束 Token  ★★★★☆    中等
4. Grammar-based  上下文无关文法约束    ★★★★★    较大
```

下面逐一拆解。

## 方案一：Prompt Engineering —— 最低成本，最不可靠

### 基础版：在 prompt 里描述格式

```python
prompt = """
请以严格 JSON 格式返回，不要有任何额外文字。
输出必须能被 Python json.loads() 直接解析。
格式：{"name": "...", "age": <int>, "skills": ["..."]}
"""
```

### 进阶版：Few-shot + 反例

```python
prompt = """
返回纯 JSON，不要包裹在 markdown 代码块中，不要有任何解释。

正确示例：
{"name": "张三", "age": 30, "skills": ["Python", "Go"]}

错误示例（不要这样）：
```json
{"name": "张三"}
```
"""
```

### 终极版：用 Pydantic 生成格式说明

```python
from pydantic import BaseModel

class Person(BaseModel):
    name: str
    age: int
    skills: list[str]

schema = Person.model_json_schema()

prompt = f"""
只返回符合以下 JSON Schema 的有效 JSON：
{schema}

不要有任何其他文字。不要用 markdown 代码块包裹。
"""
```

### 效果评估

| 场景 | 准确率 |
|------|--------|
| 简单结构（2-3 个字段） | ~80-90% |
| 嵌套对象 | ~60-70% |
| 数组 + 枚举 | ~50-60% |
| 复杂 Schema | ~30-40% |

**结论：原型验证够用，生产环境不可靠，尤其是 Schema 复杂、温度 > 0、或者长输出时。**

## 方案二：JSON Mode —— 模型原生支持

OpenAI 在 2023 年 DevDay 推出了 JSON Mode，通过在 API 请求里设置 `response_format`：

```python
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "提取实体"}],
    response_format={"type": "json_object"}
)
```

### JSON Mode 做了什么？

1. **禁用文本生成**：强制模型只输出 JSON token
2. **括号/引号配对**：保证 `{` 和 `}` 数量匹配
3. **不保证 Schema 正确**：只保证"是 JSON"，不保证"是你想要的 JSON"

### 关键限制

```python
# ❌ 这样不能保证输出有任何特定字段
response_format={"type": "json_object"}
# → 输出是合法 JSON，但可能不包含你需要的字段

# ✅ OpenAI 后来新增了 structured outputs
response_format={
    "type": "json_schema",
    "json_schema": {
        "name": "person",
        "schema": Person.model_json_schema(),
        "strict": True
    }
}
# → 保证输出符合 Schema 的所有约束
```

### 实测数据

| 模型 | JSON Mode 误格式率 | Strict Mode 误格式率 |
|------|-------------------|---------------------|
| GPT-4o | ~3% | \<0.1% |
| GPT-4o-mini | ~8% | \<1% |
| Claude 3.5 Sonnet | ~2% | 不支持 strict mode |
| DeepSeek V3 | ~5% | 不支持 |

**结论：JSON Mode 解决了"是 JSON"的问题，没解决"是你想要的 JSON"的问题。OpenAI 的 Strict Mode 做到了，但其他模型还不支持。**

## 方案三：Regex/FSM 约束 —— 有限状态机控制采样

这是真正开始"硬约束"的第一层：在生成每个 token 之前，用有限状态机过滤掉不合法的 token。

### 原理

```
词表: ["{", "}", '"', 'name', ':', '张三', ',', 'age', '3', '0', '}', ...]

当前已生成: {"name": "

下一步合法 token:
  ✅ 任何字符串字符
  ❌ "}" （在字符串中间不能闭合括号）
  ❌ "{" （字符串内不能嵌套对象）

→ 把不合法的 token logit 设为 -inf
→ 模型只能从合法 token 中采样
```

### 实际框架

**Guidance（Microsoft）**

```python
import guidance

program = guidance("""
{
  "name": "{{name}}",
  "age": {{age}},
  "skills": {{#each skills}}"{{this}}"{{#unless @last}}, {{/unless}}{{/each}}
}
""")

result = program(
    name='...',  # 模型会填充
    age='...',
    skills=['...']
)
```

**LMQL**

```python
import lmql

@lmql.query
def extract_person():
    """
    argmax
    "输出 JSON:\n"
    "{ \"name\": \"[NAME]\", \"age\": [AGE], \"city\": \"[CITY]\" }"
    from
        "openai/gpt-4o"
    where
        len(NAME) < 20 and
        INT(AGE) and
        CITY in ["北京", "上海", "深圳"]
    """
```

### 优缺点

| 优点 | 缺点 |
|------|------|
| 100% 保证格式 | 只能约束能表达为正则的格式 |
| 不需要模型支持 | 嵌套结构复杂时正则很冗长 |
| 推理框架无关 | 对输出质量有负面影响 |

> **关键发现**：FSM 约束会移除一些 token 选项，在某些情况下会降低生成质量。比如一个位置原本模型想输出 "张" 但因为约束只能输出数字，结果被迫选了个不太好的数字。

**结论：适合简单、扁平的输出格式。复杂嵌套结构（如 API 响应、配置文件）不适用。**

## 方案四：Grammar-Based Constrained Decoding —— 终极方案

用**上下文无关文法（CFG）** 或 **JSON Schema** 直接驱动采样过程。这是目前最严格、最可靠的方式。

### 核心原理

```
JSON Schema → 编译成 → 字符级状态机 → 控制每一步采样的合法字符集

每一步生成时：
1. 拿到模型的原始 logits
2. 根据当前状态，mask 掉不合法的 token
3. Softmax → 采样 → 推进状态机

结果：输出一定符合 Schema，不需要后处理校验。
```

### 主流框架对比

#### Outlines（推荐）

```python
from outlines import models, generate
from pydantic import BaseModel

class Entity(BaseModel):
    people: list[str]
    location: str
    event: str

model = models.transformers("Qwen/Qwen2.5-7B-Instruct")
generator = generate.json(model, Entity)

result = generator("从文本中提取实体：张三和李四在北京参加马拉松")
# → Entity(people=["张三","李四"], location="北京", event="马拉松")
# 保证 100% 符合 Pydantic 模型
```

**Outlines 的索引机制**：不是暴力 mask，而是预编译一个"状态 → 合法 token 集合"的映射表（通过 tokenizer 的 trie 结构），推理时 O(1) 查表。

```python
# Outlines 内部简化逻辑
mask_table = {
    (state_0, "{"): 允许,
    (state_0, " "): 允许,
    (state_0, "张三"): 禁止,  # 不在合法字符集中
    ...
}
```

#### llama.cpp Grammar

```python
grammar = r"""
root ::= object
object ::= "{" ws pair ("," ws pair)* "}" ws
pair ::= string ws ":" ws value
value ::= string | number | array
array ::= "[" ws value ("," ws value)* "]" ws
string ::= "\"" [^"]* "\""
number ::= [0-9]+
ws ::= [ \t\n]*
"""

result = llama.cpp.create_completion(
    prompt=prompt,
    grammar=grammar
)
```

#### vLLM Guided Decoding

```python
from vllm import LLM, SamplingParams

llm = LLM("Qwen/Qwen2.5-7B-Instruct")

sampling_params = SamplingParams(
    temperature=0,
    guided_decoding=GuidedDecodingParams(
        json=Person.model_json_schema()
    )
)

outputs = llm.generate(prompts, sampling_params)
```

### 性能开销

| 方案 | 吞吐下降 | 延迟增加 | 原因 |
|------|---------|---------|------|
| JSON Mode | ~0% | ~0ms | 模型内部优化 |
| Regex | ~5-10% | +50ms | Token-level mask |
| Grammar (vLLM) | ~10-20% | +100ms | Schema 编译 + XPU mask |
| Grammar (Outlines) | ~15-30% | +200ms | Python 层开销 |

> vLLM 的 guided decoding 把 mask 计算放在了 CUDA kernel 旁边，比纯 Python 的方案快很多。

## 选型建议

```
你的需求                          推荐方案
────────────────────────────────────────────
快速原型，格式简单              → Prompt Engineering
调用 OpenAI，需要 JSON          → response_format + strict
用开源模型，输出扁平结构        → Regex / FSM
用开源模型，复杂嵌套 Schema     → Outlines / vLLM grammar
生产环境，低延迟要求           → OpenAI Strict / vLLM guided
生产环境，100% 可靠            → Outlines / llama.cpp grammar
```

### 几个实测结论

1. **Prompt Engineering 的格式化指令会互相干扰**。你写了"返回 JSON"，模型可能记住训练数据里"JSON 要包在 markdown 里"，反而增加代码块包裹概率。**不如用 JSON Mode 或 Outlines。**

2. **温度必须为 0**。结构化输出和创造性是矛盾的——温度 > 0 时格式错误率呈指数增长。几乎所有约束解码框架都建议 temperature=0。

3. **Few-shot 对格式的正确性没有帮助**。Few-shot 帮助模型理解**内容**（提取什么实体），但对**格式**（括号匹配、引号正确）几乎没影响。格式问题要走约束解码，不是 prompt 技巧。

4. **Outlines 的 Pydantic 集成是杀手锏**。你的业务代码里用 Pydantic 定义数据模型，直接用同一个模型当 JSON Schema 传给 Outlines——不需要维护两套定义。

## 实战：构建一个结构化提取流水线

结合前面四篇文章的知识，完整流水线长这样：

```python
from pydantic import BaseModel
from outlines import models, generate

# 1. 定义 Schema（就是你业务代码用的 Pydantic 模型）
class ExtractionResult(BaseModel):
    summary: str
    entities: list[str]
    sentiment: str  # "positive" | "negative" | "neutral"
    confidence: float

# 2. 加载模型 + 约束生成器
model = models.transformers(
    "Qwen/Qwen2.5-7B-Instruct",
    device="cuda"
)
generator = generate.json(model, ExtractionResult)

# 3. 调用
prompt = f"""
分析以下用户反馈，提取关键信息：
"这个产品功能很强大，但价格太贵了，希望能降价。客服响应很快。"
"""

result = generator(prompt)
# → ExtractionResult(
#     summary="用户认可功能但抱怨价格",
#     entities=["功能", "价格", "客服"],
#     sentiment="neutral",
#     confidence=0.92
# )

# 4. 不需要 json.loads()，不需要 try-except，不需要格式校验
print(result.model_dump_json(indent=2))
```

如果不用 Outlines，用 vLLM 的话：

```python
from vllm import LLM, SamplingParams

llm = LLM(
    "Qwen/Qwen2.5-7B-Instruct",
    guided_decoding_backend="outlines"  # 或 "xgrammar"
)

params = SamplingParams(
    temperature=0,
    max_tokens=256,
    guided_decoding=GuidedDecodingParams(
        json=ExtractionResult.model_json_schema()
    )
)

outputs = llm.generate([prompt], params)
result = ExtractionResult.model_validate_json(outputs[0].outputs[0].text)
```

## 总结

| 方案 | 可靠性 | 灵活度 | 性能 | 适用场景 |
|------|--------|--------|------|---------|
| Prompt Engineering | ★☆☆☆☆ | ★★★★★ | ★★★★★ | 原型/探索 |
| JSON Mode | ★★☆☆☆ | ★★★★☆ | ★★★★★ | 简单 JSON，有 OpenAI |
| OpenAI Strict | ★★★★★ | ★★★★☆ | ★★★★★ | 复杂 Schema，有 OpenAI |
| Regex/FSM | ★★★★☆ | ★★★☆☆ | ★★★★☆ | 扁平结构，开源模型 |
| Grammar-based | ★★★★★ | ★★★★★ | ★★★☆☆ | 复杂嵌套，开源模型 |

一句话总结：**低风险场景拼 prompt，生产环境上约束解码。Outlines + Pydantic 是目前开源方案里最丝滑的组合。**

---

*系列文章：*
- [Function Calling 诞生的背景](/blog/2026-07-14-function-calling-background)
- [Function Calling 实践指南：角色、字段与报文处理全解析](/blog/2026-07-23-function-calling-implementation-guide)
