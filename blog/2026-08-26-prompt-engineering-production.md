---
title: "Prompt 工程的下半场：System Prompt 分层、缓存感知设计与评测回归"
date: 2026-08-26T14:00:00+08:00
draft: false
tags: ["ai", "llm", "prompt-engineering", "engineering", "performance", "eval"]
categories: ["Tech"]
description: "2023 年的 prompt 技巧在推理模型时代已经失效。System Prompt 怎么分层设计？为什么缓存感知的 prompt 结构能省 70% 输入成本？改 prompt 怎么才能像改代码一样有门禁？"
---

2023 年的 prompt 技巧（"扮演 XX 角色"、few-shot 堆例子、`Let's think step by step`）在 2026 年基本失效了：推理模型自带思维链，few-shot 反而拖后腿；上下文窗口动辄 128K 起步，token 成本大头从输出转移到了输入；更重要的是，prompt 一旦进入生产，它就是**代码**——要版本化、要评测、要灰度、要监控缓存命中率。

本文不聊"怎么写好一句 prompt"，那部分已经被 [上下文工程](/blog/2026/08/02/context-engineering-deep-dive) 和 [结构化输出](/blog/2026/08/10/structured-output-techniques) 覆盖了。本文聊的是 prompt 作为生产系统的另一半：**分层体系怎么搭、推理模型怎么伺候、缓存怎么薅、改动怎么验证**。

{/* truncate */}

## 一、System Prompt 分层：把提示词当配置文件

生产级 System Prompt 的敌人是**熵**：产品经理加一句、安全同事加一句、你修个 bug 又加一句，三个月后没人知道哪句在起作用。解法是把它拆成**固定区**和**可变区**，用模板渲染，版本哈希跟随：

```python
# prompt_builder.py —— 模块化 System Prompt 渲染器
from dataclasses import dataclass, field
import hashlib, json, time

@dataclass
class SystemPrompt:
    role: str                 # 你是谁（固定）
    task: str                 # 你干什么（固定）
    constraints: list[str]    # 输出约束（固定，但可增删）
    tools: list[str]          # 工具定义（固定顺序！见第三节）
    dynamic: dict = field(default_factory=dict)  # 用户信息等动态内容

    def render(self) -> tuple[str, str]:
        # 固定区在前，动态区在后：保证前缀稳定，见第三节
        parts = [
            f"<role>\n{self.role}\n</role>",
            f"<task>\n{self.task}\n</task>",
            "<constraints>",
            *[f"- {c}" for c in self.constraints],
            "</constraints>",
            "<tools>",
            *self.tools,
            "</tools>",
            f"<dynamic>\n{json.dumps(self.dynamic, ensure_ascii=False)}\n</dynamic>",
        ]
        prompt = "\n\n".join(parts)
        digest = hashlib.sha256(self.role + self.task + json.dumps(
            self.constraints + self.tools, ensure_ascii=False)).hexdigest()[:12]
        return prompt, digest  # digest 进日志，问题回放全靠它
```

三个设计要点：

1. **角色与任务分离**。`role` 描述身份和能力边界，`task` 描述本次业务目标。业务迭代只改 `task` 区，`role` 区稳定，缓存前缀不碎。
2. **约束写进"不要"清单，不写进任务描述**。Anthropic 官方建议把 `what not to do` 单独成区——模型对"任务描述里的否定句"理解远差于"约束区的禁止项"。例：任务里写"总结时不要提价格"不如约束区写"禁止提及任何金额信息"。
3. **指令放最前，动态内容沉底**。模型对 prompt 开头和结尾的敏感度高于中间（primacy/recency 效应），所以最重要的指令在 role 标记顶部，用户输入、检索上下文这类易变内容全部放 dynamic 区。这也是缓存命中的前提。

## 二、推理模型：别再喂 CoT 和 few-shot

指令模型时代养成的两个习惯，在 R1/QwQ 这类推理模型上全是反效果。DeepSeek 官方 R1 提示指南说得非常直白：

- **不要 few-shot**。R1 对示例不敏感，且示例会引入风格污染，官方明确建议"直接描述问题和需求"。实测里给 R1 配 3 个 few-shot 例子，输出会被例子里的格式带着走，推理质量不升反降。
- **不要说"请一步一步思考"**。推理模型内部已经做了长链推理，外部指令反而干扰它的思考节奏。你要控制的是**思考预算**，不是思考方式。
- **输出格式约束要放对位置**。强格式需求走输出侧（`response_format`/JSON Mode，见 [结构化输出实战](/blog/2026/08/10/structured-output-techniques)），prompt 里只描述"期望输出包含哪些字段"，不要用"你必须输出 JSON"这种命令句式。
- **temperature 按场景分档**。R1 官方建议 0.6 而不是 0——推理模型温度归零反而容易陷入局部最优。确定性问题（分类、抽取）用 0.1-0.3，开放生成（写作、头脑风暴）用 0.7-1.0。

思考预算的工程化控制，代码层面长这样（以 DeepSeek API 为例）：

```python
resp = client.chat.completions.create(
    model="deepseek-reasoner",
    messages=[{"role": "user", "content": "解这道题：" + problem}],
    max_tokens=4096,        # 总预算：思考 + 答案
    temperature=0.6,
    stream=True,
)
# 流式返回里 reasoning_content 是思维链，content 是最终答案：
# 思维链单独落库（审计/蒸馏素材），不计入用户可见输出
```

一个常见事故：`max_tokens` 给太小，模型把预算全花在思考上，答案被截断。R1 类模型的 `max_tokens` 必须预留答案空间，保守做法是思考与答案 3:1 起步。

## 三、缓存感知设计：System Prompt 就是钱

输入 token 成本已经超过输出，而各家缓存的价差大到离谱：

| 厂商 | 缓存命中输入价 | 未命中输入价 | 说明 |
|---|---|---|---|
| Anthropic | 0.1x（省 90%） | 1x | 写入需付 1.25x 附加费，TTL 最长 5 分钟 |
| OpenAI | 0.5x（省 50%） | 1x | 自动生效，前缀至少 1024 token |
| DeepSeek | 约 0.1x | 1x | 自动生效，前缀越长越稳 |

算一笔真实账：System Prompt 2000 token（固定）+ 用户输入 500 token（动态），日请求 1 万次，按 DeepSeek 未命中 $0.28/百万 token 计：

- 不缓存：2500 × 1 万 = 2500 万 token/天 → **$7.0/天**
- 缓存命中：2000 走命中（0.028）+ 500 走未命中（0.28）→ 20M×0.028 + 5M×0.28 = **$1.96/天**

**省 72%**，还顺带降低了 TTFT（命中前缀直接复用 KV Cache）。工程上三个动作：

1. **固定区永远不动**：角色、任务、约束、工具定义的拼接顺序和内容都是"不可变部署"。改一个字 = 前缀全断 = 缓存全灭。
2. **动态内容沉底**：用户信息、时间戳、检索结果一律放 dynamic 区。真实事故：有人把当前日期渲染进 System Prompt 开头做"时效性提示"，缓存命中率从 80% 直接归零——日期天天变，前缀天天断。
3. **监控命中率**，把它当成和延迟同级的 SLO 指标：

```python
# cache_metrics.py —— 各家的 usage 字段
# OpenAI:  usage.prompt_tokens_details.cached_tokens
# Anthropic: usage.cache_read_input_tokens / cache_creation_input_tokens
# DeepSeek: usage.prompt_cache_hit_tokens / prompt_cache_miss_tokens
def record_usage(usage, ts):
    hit = getattr(usage, "prompt_cache_hit_tokens",
                  getattr(getattr(usage, "prompt_tokens_details", None),
                          "cached_tokens", 0))
    total = usage.prompt_tokens or (hit + getattr(usage, "prompt_cache_miss_tokens", 0))
    # 推给 Prometheus：cache_hit_ratio = hit / total
    # 告警阈值：低于 0.5 且此前稳定在 0.8+ → 查前缀断裂
```

工具定义是隐藏的前缀杀手：**工具列表按用户动态拼接**（A 用户 5 个工具、B 用户 8 个）会让每个用户一个前缀；按"全量固定顺序 + 禁用标记"或按工具组路由才能保住命中率。工具 description 怎么写、schema 怎么约束，见 [Function Calling 内部实现](/blog/2026/08/11/function-calling-internals)。

## 四、评测回归：prompt 是代码，就得有门禁

prompt 改坏是生产中最高频的"静默故障"——模型不报错，只是效果变差。所以改 prompt 的流程必须对齐改代码：[LLM 评测工程化](/blog/2026/08/04/llm-eval-llm-as-judge) 讲了评测体系，这里给最小闭环：

```python
# test_prompt_regression.py —— prompt 回归门禁（CI 里跑）
import pytest
from prompt_builder import SystemPrompt

REGRESSION_SET = [  # (输入, 期望包含, 期望排除)
    ("退款到账要几天？", ["退款", "工作日"], ["立即"]),
    ("你们是不是骗子", ["抱歉"], ["退款"]),
]

def test_system_prompt_v2_regression():
    sp = SystemPrompt(role="客服助手", task="处理售后咨询",
                      constraints=["不承诺到账时间"], tools=[])
    for question, must_have, must_not in REGRESSION_SET:
        resp = call_llm(sp.render()[0], question)  # 真实调用或录制的 golden 响应
        for kw in must_have:
            assert kw in resp, f"缺少关键词: {kw}"
        for kw in must_not:
            assert kw not in resp, f"出现禁词: {kw}"
```

要点：回归集要小（几十条够用）、断言要稳（关键词/规则优先，LLM-as-judge 只用于开放题）、跑在 CI 上、每次 prompt 版本变更必须附带回归结果。上线前再看一眼缓存影响——大改固定区 = 缓存全失效，成本可能暴涨，要和收益一起评估。灰度期对比三个指标：**任务成功率、cache hit ratio、每请求成本**，三者一起看才能判断改动是真有效还是靠烧钱堆出来的。

## 五、踩坑清单

1. **"不要用 Markdown"不如后处理**：模型对否定指令的执行不稳定，输出约束走结构化输出 + 服务端清洗，别指望 prompt 一句"不要"管用。
2. **few-shot 例子会泄漏域知识**：示例里的措辞、口吻、隐藏偏好会被模型当成先验，尤其中文场景。示例宁缺毋滥，且要覆盖边界情况而不是漂亮情况。
3. **多轮对话里指令会被稀释**：关键约束在每轮 user 消息尾部重申一次（recency 效应），比只写在 System Prompt 里可靠。
4. **动态 ID 别放前缀**：request_id、时间戳、随机数进固定区 = 缓存自杀，上文事故同理。
5. **推理模型的格式要求越具体越糟**：给 R1 详细规定"第一段写背景、第二段写方案"会压掉它的推理空间，输出反而变差。要格式去输出侧，要质量给自由。

## 总结

Prompt 工程的上半场是"怎么把话说明白"，下半场是"怎么把话管起来"：**分层结构保证可维护，缓存感知保证成本，评测回归保证可演进**。三者共同的前提是把 prompt 当代码——版本化、可回放、有门禁。工具调用侧的对应实践可以接 [Function Calling 背景](/blog/2026/07/14/function-calling-background) 和 [多 Agent 编排](/blog/2026/08/16/multi-agent-orchestration) 继续往下挖。
