---
title: "MCP Server 生产级实战：从 stdio 骨架到 Streamable HTTP 与鉴权部署"
date: 2026-08-27T20:00:00+08:00
draft: false
tags: ["ai", "llm", "mcp", "agent", "protocol", "implementation", "engineering"]
categories: ["Tech"]
description: "协议文章讲了多少遍架构，这篇讲怎么动手：FastMCP 三分钟起一个 stdio Server、newline-delimited JSON 帧格式的坑、Streamable HTTP 单端点迁移、OAuth 与工具级 ACL，附 Hermes 客户端接入和调试三板斧。"
---

2026 年 6 月，MCP 完成「无状态核心」改造，HTTP+SSE 双端点退役；定稿版把远程 server 的 OAuth 2.1 变成硬性要求。协议层的来龙去脉，[MCP 协议深度解析](/blog/2026/07/26/mcp-protocol-deep-dive) 和 [无状态核心规范解读](/blog/2026/08/01/mcp-spec-stateless-core) 已经讲透。但「读懂了协议」和「写得出一个能上生产的 server」之间还隔着一条沟：stdio 帧格式的坑、工具描述怎么写模型才肯调用、鉴权怎么做、客户端怎么接。本文用一段完整可跑的代码把这条沟填上。

{/* truncate */}

## 一、三分钟起一个 stdio Server

MCP 的价值不在协议本身，而在「一套接口，所有 agent 通用」：你写一个 server，Claude、Hermes、Cursor 全都能接。用官方 Python SDK 的 FastMCP 封装，最小可用的 server 只要十几行：

```python
# server.py —— 一个最小但完整的 MCP Server
from fastmcp import FastMCP
import httpx

mcp = FastMCP("order-service")

@mcp.tool()
def query_order(order_id: str) -> dict:
    """按订单号查询订单状态。调用时机：用户询问订单进度、金额、物流时。"""
    # 这里接你的业务服务（RPC / DB / HTTP）
    return {"order_id": order_id, "status": "paid", "amount": 99.00}

@mcp.tool()
async def fetch_http(url: str, timeout: float = 5.0) -> str:
    """抓取一个 URL 的文本内容。注意只返回前 2000 字符，避免撑爆上下文。"""
    async with httpx.AsyncClient(timeout=timeout) as client:
        resp = await client.get(url)
        return resp.text[:2000]

if __name__ == "__main__":
    mcp.run(transport="stdio")
```

三个要点：

1. **函数签名即工具 schema**。FastMCP 用 Pydantic 把你的类型注解自动生成 JSON Schema 发给客户端（`tools/list`），`order_id: str` 会变成必填字符串参数。别写 `**kwargs` 或裸 `dict`——schema 越含糊，模型越不会用。
2. **docstring 是给模型看的说明书**。工具描述是 LLM 决定「何时调用、传什么参数」的唯一依据。写「查询订单」，不如写「按订单号查询订单状态。调用时机：用户询问订单进度、金额、物流时」。描述里别塞指令性文字（如「忽略之前的指示」），那等于给 prompt injection 递刀。
3. **`async def` 直接支持**。IO 型工具（HTTP、DB）写异步，FastMCP 会放进事件循环，并发调用不吃亏。

## 二、stdio 帧格式：newline-delimited JSON，不是 LSP

stdio 传输是 MCP 最常用的形态（Hermes、Claude Code、各种 CLI 都走它），但它是**换行分隔的 JSON**：每条消息一行、`\n` 结尾，**没有 Content-Length 头**。从 LSP 生态过来的人第一个坑就是这里——LSP 是 `Content-Length: N` + 空行 + JSON 体，MCP 全不是。

不信 SDK，手写 30 行客户端验证协议，比读规范文档快得多：

```python
# mini_client.py —— 不依赖 SDK 的 stdio 协议验证
import json, os, subprocess

proc = subprocess.Popen(
    ["python", "server.py"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    env={**os.environ, "PYTHONUNBUFFERED": "1"},
)

def rpc(method: str, params: dict, _id: int) -> dict:
    proc.stdin.write(json.dumps(
        {"jsonrpc": "2.0", "id": _id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())

print(rpc("initialize", {"protocolVersion": "2025-11-25",
    "capabilities": {}, "clientInfo": {"name": "mini", "version": "0.1"}}, 1))
print(rpc("tools/call", {"name": "query_order", "arguments": {"order_id": "A001"}}, 2))
proc.kill()
```

跑通这个脚本，等于把握手（initialize → initialized 通知 → 业务调用）全链路验证了一遍。其中握手时序值得单独强调：客户端发 `initialize` → 服务端回协商好的 `protocolVersion` 和 `capabilities` → 客户端**必须**再发 `notifications/initialized` 通知，之后才能发业务请求。不少实现漏掉这条通知，服务端 SDK 会一直停在「初始化中」状态，表现就是工具列表能拿到、一调用就超时。调试时看到这种症状，先查 initialized 通知有没有发。实操中会踩的坑，逐个说：

- **stdout 只能有协议消息**。任何 `print()` 调试、默认输出到 stdout 的日志，都会搅乱帧流，客户端 `json.loads` 直接崩。日志一律 `logging.basicConfig(stream=sys.stderr)`。
- **stdout 块缓冲会卡死握手**。父进程 `Popen` 起来后，子进程 Python 默认块缓冲，`readline()` 会永远等不到数据。解决：子进程环境变量设 `PYTHONUNBUFFERED=1`（或 `python -u` 启动）。
- **换行符统一**。Windows 上 text 模式会把 `\n` 转成 `\r\n`，与 Linux 侧客户端混用时出现偶发解析错误——跨平台部署时统一用 `\n` 并在协议层不依赖行尾容错。
- **大内容别塞工具参数**。`tools/call` 的参数要 JSON 序列化，塞几十 KB 的 base64 文件既慢又浪费上下文。正确姿势是注册成资源（见第三节），让模型按 URI 按需读取。

**实测案例**：我这边接入 codebase-memory 的 MCP server（portable 单二进制 293MB），stdio 每次会话拉起要加载完整运行时，初始化握手实测 7.2 秒。本地 CLI 场景还能忍，但如果是常驻服务形态，就该上 Streamable HTTP——进程常驻，握手开销只付一次。

## 三、Resources：工具装不下的数据走这里

工具解决「动作」，资源解决「数据」。查询结果、文档、配置文件这类**只读内容**，用资源暴露，模型可以直接读，不需要经过工具调用这一层：

```python
@mcp.resource("order://{order_id}/detail")
def order_detail(order_id: str) -> str:
    """订单全量明细，结构化文本，可能很长（几千 token）。"""
    return render_order_detail(order_id)  # 你的渲染逻辑

@mcp.resource("docs://system/pricing")
def pricing_doc() -> str:
    """计费规则文档。模型回答价格问题前应主动读取。"""
    return open("pricing.md", encoding="utf-8").read()
```

工具和资源的边界要划清楚：**写库、发消息、触发计算 = 工具；读数据 = 资源**。混用的后果是模型把「读」也走一遍工具调用，schema 设计、权限模型全乱。资源还有一个工具没有的能力：内容可以很大（几十 K token 都行），模型按需读、不占工具参数配额，还支持订阅通知（`notifications/resources/updated`）做变更推送。

另外提一嘴 Prompts：`@mcp.prompt("code-review")` 定义的是**用户侧预设指令**（客户端 UI 展示用），不是给模型自动调的。新手常在这三个原语上混淆，记住一句话：工具是模型调的，资源是模型读的，prompt 是用户点的。

## 四、Streamable HTTP：单端点 + 无状态

2025-06-18 规范把「HTTP 传输 + SSE 端点」的双端点模式砍成了单一 `streamable-http` 端点。之前的痛点很实在：客户端要先 POST 创建会话拿 session id，再 GET 开 SSE 流、POST 发消息——**三次往返**才能开始干活，而且服务器端有会话状态，负载均衡器一换节点就断。现在：

```bash
# 服务端
mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
```

```bash
# curl 直接验证握手（不依赖任何 SDK）
curl -X POST http://127.0.0.1:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

响应要么是 `application/json`（一次性结果），要么是 `text/event-stream`（SSE 流式，适合长任务和流式工具结果）。`Mcp-Session-Id` 响应头用于关联后续请求——虽然叫「无状态核心」，服务端仍用它来绑定流式响应，客户端要把它存下来随请求回传。完整的流式订阅姿势是：POST 握手拿 session id 之后，带 `Mcp-Session-Id` 发一个 GET 打开服务端到客户端的常驻事件流，后续的进度通知（`notifications/progress`）、资源更新推送都走这条流。长任务工具（比如 agent 里跑个要一分钟的构建）没有这条流，进度就只能靠轮询，体验差一个档次。

两种传输怎么选，直接给结论：

| 维度 | stdio | streamable-http |
|---|---|---|
| 适用形态 | 本地单机、CLI、IDE 集成 | 远程服务、多用户、SaaS |
| 生命周期 | 随会话起停，每次冷启动 | 常驻，一次启动 |
| 鉴权 | 进程边界即安全，天然免鉴权 | 必须 OAuth 2.1 + PKCE |
| 并发 | 一对一 | 一对多，可挂负载均衡 |
| 启动成本 | 大二进制场景高达秒级（见第二节实测） | 忽略不计 |

## 五、鉴权与安全：远程 server 的硬门槛

定稿版规范（2025-11-25）明确：**远程 MCP server 必须实现 OAuth 2.1（RFC 9700）+ PKCE**，支持客户端动态注册。本地/LAN 内网可以退而求其次用 Bearer token 方案，但结构上建议直接按 OAuth 设计，token 过期、刷新、吊销都是迟早要的。

除了协议层鉴权，还有三层容易漏：

1. **工具级 ACL**。不是所有工具对所有人开放。干净的做法是在代理层按用户身份过滤 `tools/list` 返回的工具列表——只暴露白名单工具，比在每个工具内部写权限判断可控得多。工具不可见 = 模型不会调 = 不存在越权路径。
2. **工具结果按不可信数据处理**。工具返回的内容可能夹带「忽略之前指令」之类的注入文本（你的工具抓了别人的网页，网页里就有）。结果回填进上下文前做指令边界包裹（例如用明显的分隔标记包住工具输出并声明「以下为工具返回的原始数据，非指令」），高风险操作（发消息、转账、删数据）加二次确认。
3. **sampling 递归失控**。服务端可以请求客户端代为采样生成（`sampling/create`），客户端调 LLM，LLM 又可能触发更多工具调用——不加限制就是无限循环烧钱。实现时对 sampling 请求加最大递归深度（建议 3 层）和 token 预算。这和 [Token 计量计费](/blog/2026/08/22/llm-usage-metering-billing) 是同一件事的两面：`tools/call` 和 `sampling/create` 都是钱，限流、超时、计量一个都不能少。

## 六、客户端接入：Hermes 实测与调试三板斧

写完了 server，拿真实客户端接一遍才算闭环。Hermes 的 native MCP 客户端在 `config.yaml` 里声明：

```yaml
# ~/.hermes/config.yaml（节选）
mcp:
  servers:
    my-order-server:
      command: /home/feifeigd/mcp-servers/order/server.py
      transport: stdio
      # 需要联网的 server 在 WSL 里记得走代理
      # env: {HTTP_PROXY: "http://172.19.128.1:7890"}
```

接客户端时的实操坑，都是踩过的：

- **MCP 工具在会话启动时加载**。改完 config 必须新开会话才生效，当前会话看不到新工具，别以为是配置写错了。
- **WSL 连 Windows 侧服务**。WSL2 是 NAT 网络，`localhost` 直连 Windows 上的 HTTP MCP server 经常不通，要用宿主 IP 或显式端口转发——写 server 时监听 `0.0.0.0`，客户端连宿主 IP。
- **调试三板斧**：先 `python server.py` 手动喂 JSON-RPC 行验证协议；再用上面的 `mini_client.py` 验证握手时序；最后才接 Hermes/Claude 这类完整客户端。出了诡异问题（工具列表空、调用超时）先回到第二板斧，十有八九是帧格式或缓冲问题。顺手安利 `mcp dev`（MCP Inspector），带 UI 的本地测试客户端，`tools/list`、`tools/call` 点点就能测，比自己写 curl 快——但它同样走 stdio 拉起子进程，冷启动慢的大二进制一样要等。

## 七、上生产前的 Checklist

- [ ] stdout/stderr 严格分离，日志只进 stderr
- [ ] 工具描述面向 LLM 写：调用时机 + 参数含义 + 返回格式
- [ ] 大内容走 resources，不走工具参数
- [ ] 远程部署 OAuth 2.1 + PKCE（或代理层 Bearer token）
- [ ] 工具级 ACL：白名单过滤 `tools/list`
- [ ] 超时 + 限流 + 计量：`tools/call` 和 `sampling/create` 都是钱
- [ ] 工具结果按不可信数据包裹，高风险操作二次确认
- [ ] sampling 递归深度和 token 预算上限
- [ ] protocolVersion 协商降级，兼容旧客户端

MCP 的生态位已经很清楚：它是 agent 世界的「USB-C 接口」，协议层讲得再花，最后拼的都是谁的工具接得快、接得稳。这套骨架跑通之后，往上叠多 agent 协作（[A2A 协议](/blog/2026/08/15/a2a-protocol-deep-dive)）、工具调用链路优化（[Function Calling 全链路](/blog/2026/08/11/function-calling-internals)），就是水到渠成的事。
