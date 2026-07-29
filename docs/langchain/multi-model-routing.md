# LangChain 多模型调度：从静态路由到自适应路由

## 为什么要做多模型调度

做 Agent 时接入的模型远不止一个：

| 任务类型 | 可选模型 |
|----------|----------|
| 文本推理（主力） | GPT-4o, DeepSeek-V3, Qwen-Max |
| 文本推理（省钱） | DeepSeek-R1, Qwen-Turbo, GPT-4o-mini |
| 语音识别 | Paraformer, Whisper-large |
| 语音合成 | CosyVoice, FishSpeech |
| 图片生成 | Seedream, Kolors, Flux |
| 视频生成 | Kling, Wan2.7-Video |

每个模型有自己的**价格、速度、能力边界**。专业模型做专业事——让 GPT-4o 写代码，让 Paraformer 做 ASR，让最小成本的模型处理简单闲聊。

但问题来了：

- **怎么判断任务的复杂度？** 简单问答和复杂推理是同一条 prompt，模型怎么区分？
- **怎么把任务分到对应的模型？** 路由策略——路由错了浪费钱，路由对了省成本。
- **分错了怎么办？** 没有兜底的调度是不完整的。

下文由浅入深，依次实现四种路由模式。

---

## 前置准备

本文 demo 基于 LangChain + Python 3.11+，依赖：

```bash
pip install langchain langchain-openai langchain-community pydantic
```

先定义几个工具函数，贯穿全文：

```python
import json, time, asyncio
from typing import Any
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage, SystemMessage

# ──  mock 模型：模拟不同模型的行为 ──

class MockCheapModel:
    """"便宜"模型：简单问答，复杂问题瞎答"""
    def invoke(self, messages):
        text = messages[-1].content
        if len(text) < 30:
            return type("Msg", (), {"content": f"[Cheap] 简单回答: {text[:20]}..."})()
        return type("Msg", (), {"content": "[Cheap] 问题太复杂了，我不会"})()
    async def ainvoke(self, messages):
        return self.invoke(messages)

class MockExpensiveModel:
    """"贵"模型：啥都能答"""
    def invoke(self, messages):
        text = messages[-1].content
        return type("Msg", (), {"content": f"[Expensive] 完整回答: 关于「{text[:30]}」的详细分析……"})()
    async def ainvoke(self, messages):
        return self.invoke(messages)

class MockSpecializedModel:
    """专业模型：只能回答特定领域"""
    def __init__(self, domain: str, name: str):
        self.domain = domain
        self.name = name
    def invoke(self, messages):
        text = messages[-1].content
        if self.domain in text.lower():
            return type("Msg", (), {"content": f"[{self.name}] 专业回答（{self.domain}领域）: {text}"})()
        return type("Msg", (), {"content": f"[{self.name}] 不在我的领域范围内"})()
    async def ainvoke(self, messages):
        return self.invoke(messages)
```

> **说明**：生产环境换成真实的 `ChatOpenAI(model=..., api_key=...)` 即可。

---

## 一、静态路由（Static Routing）

最简单的方案：**写死规则**。根据关键词或 prompt 长度决定用哪个模型。

```python
class StaticRouter:
    def __init__(self):
        self.models = {
            "coding":    ChatOpenAI(model="gpt-4o", temperature=0),
            "chat":      ChatOpenAI(model="gpt-4o-mini"),
            "audio":     MockSpecializedModel("audio", "Whisper"),
            "image":     MockSpecializedModel("image", "Kolors"),
        }

    def route(self, query: str):
        """根据关键词静态路由"""
        q = query.lower()
        if any(kw in q for kw in ["代码", "代码", "python", "代码审查"]):
            return "coding"
        elif any(kw in q for kw in ["语音", "音频", "asr", "转文字"]):
            return "audio"
        elif any(kw in q for kw in ["画图", "生成图片", "文生图"]):
            return "image"
        else:
            return "chat"

    def run(self, query: str):
        route_key = self.route(query)
        model = self.models[route_key]
        result = model.invoke([HumanMessage(content=query)])
        print(f"[路由: {route_key}] {result.content}")
        return result

# 使用
router = StaticRouter()
router.run("帮我写一段 Python 代码")    # → coding
router.run("把这段语音转成文字")        # → audio
router.run("今天天气怎么样？")          # → chat
```

**优势**：简单、零延迟、零额外成本。
**劣势**：全靠关键词匹配，用户说"写个脚本"可能匹配不到"代码"；无法处理复合意图（"帮我画张图并描述一下"）。

---

## 二、带兜底的静态路由（Fallback Routing）

选错了怎么办？加一层**兜底**。先用便宜模型试，如果模型"承认不会"（或信心分低），自动升级到贵模型。

```python
class FallbackRouter:
    def __init__(self):
        self.cheap = MockCheapModel()
        self.expensive = MockExpensiveModel()

    def needs_escalation(self, response: str) -> bool:
        """判断是否需要升级模型"""
        refuse_patterns = [
            "不会", "无法", "太复杂", "我不懂",
            "超出能力", "cannot", "sorry", "i don't know"
        ]
        return any(p in response.lower() for p in refuse_patterns)

    def run(self, query: str):
        # 第一步：用便宜模型
        t0 = time.time()
        cheap_result = self.cheap.invoke([HumanMessage(content=query)])
        t1 = time.time()

        print(f"[Cheap] ({t1-t0:.2f}s) {cheap_result.content}")

        # 如果便宜模型说不会，升级
        if self.needs_escalation(cheap_result.content):
            print("[Fallback] ↻ 升级到昂贵模型")
            expensive_result = self.expensive.invoke([HumanMessage(content=query)])
            print(f"[Expensive] {expensive_result.content}")
            return expensive_result

        return cheap_result

# 使用
router = FallbackRouter()
router.run("你好")                                   # cheap 能答
router.run("请详细解释量子纠缠的数学原理")           # cheap → fallback → expensive
```

**检查模型"会不会"的几种策略**：

| 策略 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| 关键词匹配 | 检查 refusal 关键词 | 简单高效 | 模型不一定会说"不会" |
| 置信度打分 | 让模型给回答附上 confidence 分数 | 更精确 | 多一次推理 |
| 长度阈值 | 回答太短(&lt;10字)则认为不会 | 零成本 | 过于粗暴 |
| 验证模型 | 用第二个小模型检查回答质量 | 准确率高 | 多一次调用 |

**置信度打分模式示例**：

```python
class ConfidenceFallbackRouter(FallbackRouter):
    def needs_escalation(self, response: str) -> bool:
        # 让便宜模型自己评估回答质量
        checker_prompt = f"""
        用户问题已被回答。请判断回答是否充分、准确。
        回答: {response}
        输出 ONLY JSON: {{"sufficient": true/false, "reason": "..."}}
        """
        check = self.cheap.invoke([HumanMessage(content=checker_prompt)])
        try:
            result = json.loads(check.content)
            return not result["sufficient"]
        except:
            return True  # 解析失败就保守升级
```

---

## 三、并行路由（Parallel Routing）

有些场景需要**多模型同时工作**。比如一个 Agent 需要同时：
- 用 GPT-4o 分析意图
- 用 Paraformer 听语音输入
- 用 Kolors 根据描述生成图片

```python
class ParallelRouter:
    def __init__(self):
        self.models = {
            "coding": MockSpecializedModel("python", "GPT-4o"),
            "chat":   MockCheapModel(),
            "image":  MockSpecializedModel("image", "Kolors"),
        }

    async def run_all(self, query: str) -> dict[str, Any]:
        """并行调用所有模型"""
        tasks = {}
        for name, model in self.models.items():
            tasks[name] = asyncio.create_task(
                model.ainvoke([HumanMessage(content=query)])
            )

        results = {}
        for name, task in tasks.items():
            try:
                result = await task
                results[name] = result.content
            except Exception as e:
                results[name] = f"[Error] {e}"

        return results

    def analyze_and_merge(self, query: str, results: dict[str, Any]):
        """从多个结果中选出最佳（或用 LLM 汇总）"""
        print(f"用户输入: {query}")
        for model_name, resp in results.items():
            print(f"  [{model_name}] {resp[:80]}...")

        # 简单策略：取第一个非错误的、非"不会"的结果
        for model_name in ["coding", "image", "chat"]:
            resp = results.get(model_name, "")
            if resp and "不在我的领域" not in resp and "Error" not in resp:
                print(f"\n→ 选用: [{model_name}] {resp}")
                return resp

        return results.get("chat", "无可用结果")

# 使用
async def main():
    router = ParallelRouter()
    results = await router.run_all("用 Python 写一个冒泡排序，并配图说明")
    router.analyze_and_merge("用 Python 写一个冒泡排序，并配图说明", results)

asyncio.run(main())
```

**并行 vs 串行**：

| | 串行 | 并行 |
|---|---|---|
| 延迟 | 所有模型延迟之和 | 最慢模型的延迟 |
| 成本 | 相同 | 相同（同时计费） |
| 资源 | 低（依次使用） | 高（同时占用连接池） |
| 适用 | 顺序依赖的流水线 | 独立模型同时服务 |

---

## 四、自适应路由（Adaptive Routing）

终极方案：**让 LLM 自己决定怎么路由**。用一个「路由器模型」（通常是轻量便宜的）来分析用户输入，输出路由决策。

```python
ROUTER_SCHEMA = """
你是一个智能路由引擎。分析用户输入，输出 JSON 路由决策。

可用模型:
- coding:   GPT-4o，适合写代码、debug、技术问答
- chat:     GPT-4o-mini，适合闲聊、简单问答
- image:    Kolors，适合文生图
- audio:    Whisper，适合语音转文字
- coding-pro: DeepSeek-V3，适合长代码生成和复杂算法

输出格式:
{
    "primary": "模型名称",
    "confidence": 0.0-1.0,
    "fallback": "兜底模型名称（primary 失败时用）",
    "parallel": ["并行的模型列表，需要同时调用的"],
    "reason": "路由理由"
}
"""

class AdaptiveRouter:
    def __init__(self):
        # 路由器用一个便宜的模型
        self.router_llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)

        self.models = {
            "coding":     ChatOpenAI(model="gpt-4o"),
            "chat":       ChatOpenAI(model="gpt-4o-mini"),
            "coding-pro": MockExpensiveModel(),
            "image":      MockSpecializedModel("image", "Kolors"),
            "audio":      MockSpecializedModel("audio", "Whisper"),
        }

    def decide(self, query: str) -> dict:
        """让 LLM 做路由决策"""
        resp = self.router_llm.invoke([
            SystemMessage(content=ROUTER_SCHEMA),
            HumanMessage(content=query),
        ])
        try:
            decision = json.loads(resp.content.strip().removeprefix("```json")
                                  .removesuffix("```").strip())
            return decision
        except:
            # LLM 输出非 JSON 时的兜底
            return {"primary": "chat", "confidence": 0.5,
                    "fallback": "coding", "parallel": [], "reason": "parse_error"}

    def run(self, query: str):
        # 1. 决策
        decision = self.decide(query)
        print(f"[Router] → {decision['primary']} "
              f"(信心: {decision['confidence']}, 理由: {decision['reason']})")

        # 2. 主模型调用
        primary_result = None
        try:
            model = self.models[decision["primary"]]
            primary_result = model.invoke([HumanMessage(content=query)])
            print(f"[{decision['primary']}] {primary_result.content}")
        except Exception as e:
            print(f"[{decision['primary']}] 失败: {e}")

        # 3. 兜底：主模型失败 或 信心不足
        if (primary_result is None
            or decision["confidence"] < 0.6
            or self._refused(primary_result.content)):

            fallback_model = decision.get("fallback", "coding")
            if fallback_model != decision["primary"]:
                print(f"[Fallback] ↻ {decision['primary']} → {fallback_model}")
                model = self.models[fallback_model]
                primary_result = model.invoke([HumanMessage(content=query)])
                print(f"[{fallback_model}] {primary_result.content}")

        # 4. 并行任务（如语音识别 + 文本分析同时做）
        if decision.get("parallel"):
            print(f"[Parallel] 同时启动: {decision['parallel']}")
            for name in decision["parallel"]:
                if name in self.models and name != decision["primary"]:
                    model = self.models[name]
                    result = model.invoke([HumanMessage(content=query)])
                    print(f"  [Parallel:{name}] {result.content}")

        return primary_result

    def _refused(self, text: str) -> bool:
        return any(p in text.lower() for p in ["不会", "无法", "超出能力"])

# 使用
router = AdaptiveRouter()
router.run("用 Python 实现一个 LRU Cache")            # → coding
router.run("画一只猫")                                 # → image（如果路由器判断正确）
router.run("把这段录音转成文字，然后总结")              # → audio + 并行 chat 总结
```

**自适应路由的核心优势**：路由规则不需要手写关键词，模型根据语义理解自动分配，能处理复合意图。

---

## 路由策略对比

| 方案 | 灵活性 | 延迟 | 成本 | 兜底 | 适用场景 |
|------|--------|------|------|------|----------|
| 静态路由 | ⭐⭐ | 低 | 低 | ❌ | 规则明确、意图单一 |
| 带兜底静态路由 | ⭐⭐⭐ | 中 | 中 | ✅ | 成本敏感、可以接受偶尔升级 |
| 并行路由 | ⭐⭐⭐ | 中（并行） | 高 | ❌ | 需要多模态输出 |
| 自适应路由 | ⭐⭐⭐⭐⭐ | 中（+路由开销） | 中 | ✅ | 复合意图、复杂场景 |

---

## 生产环境注意事项

1. **路由模型的选择**：路由器本身用便宜模型（GPT-4o-mini / DeepSeek-R1），但因为多了一次推理，会增加 ~200-500ms 延迟。可接受的话，收益远大于成本。

2. **路由缓存的必要性**：相同的 query 不需要反复路由。用 LRU Cache 缓存路由决策：

   ```python
   from functools import lru_cache
   
   @lru_cache(maxsize=1024)
   def route_decide(query: str) -> str:
       return router_llm.invoke(...)
   ```

3. **降级策略**：路由器 LLM 本身也可能超时或返回非 JSON。这种情况下默认走一个保守的静态路由或最贵的模型。

   ```python
   try:
       decision = router_llm.invoke(...)
   except Exception:
       decision = {"primary": "coding-pro", "fallback": "chat", ...}
   ```

4. **可观测性**：每个路由决策都应该记录——`query`, `决策`, `实际执行模型`, `耗时`, `成功/失败`。方便后续调优路由规则。

---

## 总结

多模型调度的本质是**用最小的成本，给用户最好的回答**。

- **静态路由**：简单暴力，适合入门
- **带兜底**：增加容错，适合生产
- **并行路由**：多模态场景下的刚需
- **自适应路由**：让 AI 自己判断，接近"通用解决方案"

从静态到自适应，每一步都在解决前一步的痛点。生产环境推荐从"带兜底"起步，根据业务场景逐步升级到自适应路由。

完整源码见 [github/demo-multi-model-routing](https://github.com/)（TODO: 实际仓库链接）。
