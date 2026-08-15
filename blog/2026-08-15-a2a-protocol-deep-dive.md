---
title: "A2A 协议深挖：Agent 之间怎么协作？AgentCard、Task 状态机与 SSE 流式传输全解析"
date: 2026-08-15T22:30:00+08:00
draft: false
tags: ["ai", "llm", "agent", "protocol", "mcp", "a2a", "architecture", "engineering"]
categories: ["AI"]
description: "MCP 解决 Agent 调工具，A2A 解决 Agent 之间组队协作。拆解 AgentCard 能力自描述、Task 状态机、JSON-RPC 2.0 + HTTP/SSE + gRPC 传输，附可运行的流式客户端与极简服务端，以及认证缺失、AgentCard 投毒等生产踩坑。"
---

很多人到现在还分不清 **MCP** 和 **A2A** 的区别，把它们当成一回事。一句话讲清：**MCP 是给 Agent 接外设的 USB 接口，A2A 是给 Agent 联网的网卡**。MCP 让一个 Agent 用统一方式调用工具、文件、数据库；A2A 让多个 Agent 之间互相发现、协商、委托任务。上篇拆解了 MCP 2026-07-28 新规范（[MCP 规范解读](/blog/2026/08/01/mcp-spec-stateless-core)），这篇聊它的姊妹协议 A2A。

{/* truncate */}

## 一、为什么需要 A2A

MCP 解决的是「一个 Agent 怎么调用外部能力」，但它管不到「两个 Agent 之间怎么协作」。一旦你开始拆多 Agent——一个做检索、一个写代码、一个做质检、一个做安全审查——它们之间就需要一种标准化的机制：**怎么被对方发现？怎么描述自己会干什么？怎么委托一个可能跑很久的任务？怎么流式地拿到中间结果？**

A2A（Agent-to-Agent Protocol）就是干这个的。它由 Google 在 2025 年 4 月的 Cloud Next 大会上提出，同年 6 月捐赠给 Linux Foundation，首批就有 Atlassian、Box、Salesforce、SAP、ServiceNow、LangChain 等 50 多家公司签名支持。注意，它是 MCP 的**互补**而非替代——两者常被同时部署在同一套 Agent 系统里。

## 二、四个核心抽象

A2A 的模型很干净，核心就四样东西：AgentCard、Task、Message、Artifact。

### 2.1 AgentCard：Agent 的「自我介绍」

Agent 把自己的能力写成一张 JSON「名片」，放在 `/.well-known/agent.json`，作用类似 OpenID Connect 的 discovery document。任何 Agent 想找帮手，先去目标 URL 拉这张卡：

```json
{
  "name": "ResearchAgent",
  "description": "研究类 Agent，负责联网检索与文献综述",
  "url": "https://agent.internal/research",
  "version": "1.2.0",
  "protocolVersion": "0.3.7",
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "stateTransitionHistory": false
  },
  "defaultInputModes": ["text"],
  "defaultOutputModes": ["text"],
  "skills": [
    {
      "id": "web-research",
      "name": "Web research",
      "description": "给定主题返回带引用的综述",
      "tags": ["research", "citation"],
      "inputModes": ["text"],
      "outputModes": ["text"],
      "examples": ["调研 2026 年向量数据库市场格局"]
    }
  ]
}
```

三个字段决定了路由决策的质量：

- `capabilities.streaming`：是否支持 `message/stream` 流式，决定客户端怎么拉结果。
- `capabilities.pushNotifications`：长任务是否支持 webhook 推送，决定客户端要不要挂长连接。
- `skills`：能力清单加示例。这是 Agent 被检索、被路由的依据——编排层往往拿它做语义匹配，决定把任务分给谁。

### 2.2 Task：一次委托的生命周期

Task 是 A2A 的核心对象，带一个**显式状态机**：

```json
{
  "id": "task-01H7X9K",
  "contextId": "ctx-01H7Y2L",
  "status": {
    "state": "working",
    "message": { "role": "agent", "parts": [{ "kind": "text", "text": "正在检索……" }] }
  }
}
```

状态流转是 `submitted` 到 `working` 到 `completed`，中间可能进入 `input-required`（Agent 反问你，需要补充输入）或 `auth-required`（需要认证才能继续），终态有 `completed`、`failed`、`canceled`、`rejected` 四种。把状态机显式化是 A2A 区别于「两个 LLM 随便发 JSON」的关键——它让客户端可以可靠地轮询、续接、取消，而不是赌对方一定秒回。

### 2.3 Message 与 Artifact

Message 是对话单元，`parts` 数组承载 `TextPart`（文本）、`FilePart`（文件，带 mimeType）、`DataPart`（任意结构化数据）。Artifact 是 Agent 的产出物，一个 Task 可以产出多个 Artifact——比如「检索结果」是一个 Artifact，「综述草稿」是另一个。

## 三、传输层：JSON-RPC 2.0 之上

A2A 用 **JSON-RPC 2.0** 做 RPC 封装，叠在两种传输上：默认 **HTTP + SSE**（请求响应走 HTTP，流式结果走 SSE），0.3.0 引入 **gRPC** 面向低延迟、高吞吐场景。选 JSON-RPC 而不是自定义 REST，是因为它天然带 method/params/result/error 的结构化语义，且生态成熟；选 SSE 而不是 WebSocket，是因为 Agent 交互天然是「一次请求、单向流式返回」，不需要双向长连接。

### 3.1 message/send：非流式

```bash
curl -X POST https://agent.internal/research \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-001",
        "role": "user",
        "parts": [{ "kind": "text", "text": "调研 2026 年向量数据库市场" }]
      }
    }
  }'
```

返回的 `result` 就是一个 Task 对象。短任务会阻塞到 `completed` 或 `failed` 再返回；长任务可能立刻返回 `working`，调用方随后用 `tasks/get` 轮询。

### 3.2 message/stream：流式

SSE 流里的每个事件是一段 JSON-RPC 响应，靠**事件名**区分类型：`status-update`（状态变更）、`artifact-update`（产出增量，token 级别）、`task`（最终的完整 Task 对象，流的结束标志）。这也是 A2A 把流式当「一等公民」的体现——不是事后补的开关，而是协议设计的一部分。

### 3.3 长任务的 push notification

长任务不适合让客户端一直挂连接。A2A 的做法是：客户端先注册一个 webhook，Agent 完成时把状态/产出事件 POST 推回来：

```bash
curl -X POST https://agent.internal/research \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tasks/pushNotificationConfig/set",
    "params": {
      "taskId": "task-01H7X9K",
      "pushNotificationConfig": {
        "url": "https://my-app.internal/a2a/callback",
        "token": "rotating-shared-secret"
      }
    }
  }'
```

## 四、可运行的客户端与服务端

下面这段不依赖 a2a-sdk，直接用 `httpx` 消费协议。协议本身是稳定的，SDK 只是薄封装（且 pre-1.0 的 SDK API 变动频繁，直接掌握协议层更划算）：

```python
import json
import httpx

def stream_task(agent_url: str, text: str):
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "message/stream",
        "params": {
            "message": {
                "messageId": "msg-001",
                "role": "user",
                "parts": [{"kind": "text", "text": text}],
            }
        },
    }
    with httpx.stream("POST", agent_url, json=payload, timeout=None) as resp:
        for line in resp.iter_lines():
            if not line.startswith("data:"):
                continue
            event = json.loads(line[len("data:"):].strip())
            result = event.get("result", {})

            # status-update：状态变更
            if "status" in result:
                print(f"\n[state] {result['status'].get('state')}", flush=True)

            # artifact-update：产出增量（append=true 表示续接上一段）
            artifact = result.get("artifact")
            if artifact:
                for part in artifact.get("parts", []):
                    if part.get("kind") == "text":
                        print(part["text"], end="", flush=True)

            # 终态 Task 可能直接带完整 artifacts
            for art in result.get("artifacts", []):
                for part in art.get("parts", []):
                    if part.get("kind") == "text":
                        print(part["text"], end="", flush=True)
```

服务端给一个极简骨架（FastAPI），把 AgentCard、JSON-RPC 分发、SSE 流串起来：

```python
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import json, asyncio

app = FastAPI()

AGENT_CARD = {
    "name": "EchoAgent",
    "url": "http://localhost:8000",
    "version": "0.1.0",
    "protocolVersion": "0.3.7",
    "capabilities": {"streaming": True, "pushNotifications": False},
    "defaultInputModes": ["text"],
    "defaultOutputModes": ["text"],
    "skills": [],
}

@app.get("/.well-known/agent.json")
def agent_card():
    return AGENT_CARD

def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"

@app.post("/")
async def rpc(request: Request):
    body = await request.json()
    method = body.get("method")
    if method == "message/stream":
        return StreamingResponse(_stream(body), media_type="text/event-stream")
    if method == "message/send":
        return {"jsonrpc": "2.0", "id": body["id"],
                "result": {"id": "t1", "status": {"state": "completed"}}}
    return {"jsonrpc": "2.0", "id": body["id"], "error": {"code": -32601, "message": "method not found"}}

async def _stream(body):
    text = body["params"]["message"]["parts"][0]["text"]
    yield sse("status-update", {"jsonrpc": "2.0", "id": body["id"],
        "result": {"kind": "status-update", "taskId": "t1", "status": {"state": "working"}}})
    for ch in text:
        yield sse("artifact-update", {"jsonrpc": "2.0", "id": body["id"],
            "result": {"kind": "artifact-update", "taskId": "t1",
                "artifact": {"artifactId": "a1", "parts": [{"kind": "text", "text": ch}]}}})
        await asyncio.sleep(0.02)
    yield sse("task", {"jsonrpc": "2.0", "id": body["id"],
        "result": {"id": "t1", "status": {"state": "completed"}}})
```

## 五、MCP 与 A2A：别再混了

| 维度 | MCP | A2A |
|---|---|---|
| 解决的问题 | Agent 调工具 / 资源 | Agent 之间协作 |
| 类比 | USB 外设接口 | 网卡 / HTTP 服务 |
| 发现机制 | 工具列表（tools/list） | AgentCard（well-known） |
| 核心对象 | Tool / Resource / Prompt | Task / Message / Artifact |
| 有状态性 | 2026-07 起无状态 | 有状态（Task 状态机） |
| 传输 | stdio / Streamable HTTP | HTTP + SSE / gRPC |
| 流式 | 可选 | 一等公民（message/stream） |

一句话收束：**MCP 让 Agent 会「用工具」，A2A 让 Agent 会「组队」**。

## 六、生产踩坑记录

这些是我在把 A2A 引入生产时踩过或见过别人踩的坑：

1. **认证是裸奔的**。规范本身不含认证授权，Agent 之间默认「零信任」都不算——是「无信任」。生产必须在传输层补：API key、OAuth2 或 mTLS。尤其 push notification 的回调 URL，token 一定要轮换，否则你的回调端点等于对公网裸奔。

2. **AgentCard 投毒**。AgentCard 是自描述的，一个恶意 Agent 可以宣称自己「会写安全代码」然后给你喂恶意输出。路由决策不能只信 AgentCard，要配合双向信任（签名、白名单）和沙箱执行。

3. **SSE 断线重连**。SSE 没有内建重连语义，A2A 也没有统一 Last-Event-ID 约定。生产要自己维护 taskId，断线后用 `tasks/get` 拉全量、或重发 `message/stream` 续接增量，别指望协议替你兜底。

4. **长任务别挂连接**。超过几十秒的任务走 push notification + 轮询兜底，别让 HTTP 连接一直挂着，否则连接池会被一批慢 Agent 耗尽。

5. **版本不兼容**。`protocolVersion` 字段是协商依据。客户端应显式检查并拒绝不支持的版本，而不是静默降级——静默降级在跨组织互联时会把「协议不匹配」伪装成「任务跑挂了」，极难排查。

## 七、多 Agent 拓扑怎么选

- **点对点**：Agent 之间直接 A2A，适合小规模、单一信任域内。
- **Hub-Spoke**：中心编排 Agent 通过 A2A 调度一群专职 Agent，适合有明确分工的场景——这也是目前最常见的落地形态。
- **网状 + 消息总线**：Agent 通过事件总线异步解耦，A2A 只作为点对点的同步通道，适合大规模、跨团队。

最后说句实话：A2A 的价值不在协议本身多精巧，而在于它把「Agent 之间的委托」标准化成了**可发现、可协商、可流式、可推送的 HTTP 服务**。对后端工程师来说，它就是「Agent 世界的 OpenAPI + 状态机」——理解了这一层，多 Agent 系统的互操作就不再是黑盒。
