---
title: "LLM 流式响应后端工程：SSE、背压、超时与取消传播的实战细节"
date: 2026-08-20T16:30:00+08:00
draft: false
tags: ["ai", "llm", "backend", "engineering", "performance", "architecture"]
categories: ["AI"]
description: "流式是 LLM 应用的默认形态，但难点不在 SSE 协议本身，而在异步管道的生命周期：慢客户端怎么背压、TTFB/空闲/总超时怎么配、客户端断开后上游还在烧钱怎么停。附纯 asyncio 可运行 demo（背压/超时/取消传播三场景），以及 CancelledError 落在流读取器内部的真实踩坑。"
---

流式输出（streaming）已经是 LLM 应用的默认形态——用户等不了非流式的 TTFB，ChatGPT 系的打字机效果也成了产品预期。但对后端工程师来说，**SSE 协议本身只有半小时的学习成本，真正的工程难点在异步管道的生命周期管理**：客户端慢了怎么办？上游断了怎么办？用户关页面了，上游还在生成、还在烧钱，怎么办？这篇文章聊的就是这些。

{/* truncate */}

## 一、SSE 协议速览：半小时入门，三个坑十年

SSE（Server-Sent Events）本质是 `Content-Type: text/event-stream` 的 HTTP 长连接，服务端持续写 `data: ...` 行，空行分隔事件。LLM 服务（OpenAI/DeepSeek 兼容接口）一般每个 chunk 发一条 `data: {"choices":[{"delta":{"content":"..."}}]}`，末尾发 `data: [DONE]`。

三个经典坑：

1. **代理缓冲**：Nginx 默认缓冲响应，SSE 会被攒成一坨。必须关掉，并让上游响应头带 `X-Accel-Buffering: no` 防 Nginx 二次缓冲：
```nginx
location /v1/chat/completions {
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 300s;   # 空闲超时，SSE 长连接必须放大
    proxy_set_header Connection '';
    proxy_http_version 1.1;
}
```
2. **CDN/网关二次缓冲**：Cloudflare 等对 `text/event-stream` 默认直通，但自建网关（如 APISIX/Kong）要显式配置流式透传，否则同样攒批。
3. **重连语义**：SSE 有 `id:` 字段 + `Last-Event-ID` 重连机制，但 LLM 流一般**不支持断点续传**（生成状态在服务端内存里），前端重连只能重新发起请求——所以重连逻辑要放在业务层（重新提问并附带"已有前缀"提示），而不是依赖 SSE 原生重连。

## 二、背压：谁慢谁负责

流式链路有三个环节：上游 LLM API → 你的服务 → 客户端。**任何一个环节慢，都不该让上游无限狂奔**——上游跑得快意味着 token 在内存里堆积、客户端最终收到一堆过期数据，最坏情况是内存被打爆。

标准解法是有界队列 + 生产者阻塞（asyncio 里 `asyncio.Queue(maxsize=N)` 天然满足：队列满时 `put()` 阻塞，上游自然被限速）。要点：

- **队列上限**决定"允许的错峰量"。上游瞬时快、客户端瞬时慢的场景，队列给足余量（如几十个 token）就够了，给太大等于没背压；
- **阻塞 vs 丢弃**：token 流不能丢（丢了语义就坏了），所以必须阻塞而不是 drop。跟消息队列的"满则拒绝"哲学不同，这里是"满则暂停"；
- **背压要能传到上游**：如果上游是你包的一层 HTTP 客户端，暂停的必须是"读取下一个 chunk"的协程，而不是把已读到的 chunk 缓存下来——否则背压只压了内存，没压上游连接。

## 三、超时矩阵：三种超时，各有各的误伤

流式场景不能只配一个总超时，要分三层：

| 超时 | 含义 | 典型值 | 误伤风险 |
|---|---|---|---|
| **TTFB 超时** | 从发请求到收到第一个字节 | 10-30 秒（长 prompt 的 prefill 慢） | 配太短，长上下文请求全被误杀 |
| **空闲超时** | 流中两次 chunk 间隔 | 30-60 秒 | 配太长，上游挂死要等半天才察觉 |
| **总超时** | 整个流的最长时长 | 按业务定，一般 2-5 分钟 | 长文生成（万字报告）会被截断 |

要点：**TTFB 和空闲超时是分开计的**。很多库只有一个 `timeout` 参数包全部，导致要么 TTFB 误伤长 prefill，要么空闲挂死检测不了。OpenAI SDK 的 `max_retries` + 超时配置也常让人踩这个坑。

## 四、取消传播：客户端断开后，上游还在烧钱

这是流式后端**最贵的坑**：用户关掉页面/App 杀掉连接，你的服务如果还傻傻地继续读完上游的流，那剩下的几百个 token 全是白烧的钱（LLM API 按生成量计费，没有"客户不要了"的退款）。

正确姿势是取消传播：客户端连接断开 → 取消消费协程 → 消费协程的 `finally` 里关闭上游流 → 上游 HTTP 连接被关 → 停止计费。看起来简单，但有一个非常隐蔽的坑，我实际调 demo 时踩出来的：

**当取消（`CancelledError`）落在流读取器内部时，异常类型会变成 `CancelledError` 而不是 `GeneratorExit`——如果流读取库只在 `except GeneratorExit` 里做清理，清理代码永远不会执行。** 更糟的是某些库用 `except BaseException` 吞掉异常，取消被静默吸收，整个任务还"正常完成"了，连接既不关、错误也不报。真实 HTTP 流式客户端（httpx/aiohttp）在取消时会正确关闭连接，但你自己包的一层生成器/reader 很容易漏。

## 五、可运行 demo（纯 asyncio，零依赖）

下面这个 demo 把上面三件事全演示了：有界队列背压、TTFB 超时、取消传播。`python3` 直接跑：

```python
"""LLM 流式管道最小可运行 demo —— 纯 asyncio 标准库
1. 背压：有界队列，上游比客户端快时自动暂停
2. 超时：首 token 超时（TTFB）
3. 取消传播：客户端断开 -> 上游生成器被关闭，不再产生/计费
"""
import asyncio
import time

async def upstream_llm(prompt, n_tokens=20, speed=0.05):
    """模拟上游 LLM：按 speed 秒/块产出 token（真实场景=HTTP 流式响应）"""
    print(f"  [upstream] 开始生成 {n_tokens} 个 token")
    i = 0
    try:
        for i in range(n_tokens):
            await asyncio.sleep(speed)
            yield f"t{i}"
        print("  [upstream] 生成完毕")
    except GeneratorExit:
        print(f"  [upstream] 被关闭！已产出 {i+1}/{n_tokens}，剩余 token 不再计费")
    except asyncio.CancelledError:
        # 真实 HTTP 流式客户端也这么处理：取消时关连接并继续传播
        print(f"  [upstream] 被取消！已产出 {i+1}/{n_tokens}")
        raise

async def proxy(prompt, client, max_q=5, ttfb_timeout=1.0):
    """流式代理：上游 -> 有界队列 -> 客户端。队列满则上游暂停（背压）。"""
    q = asyncio.Queue(maxsize=max_q)
    gen = upstream_llm(prompt)
    prod_task = None

    async def producer():
        try:
            async for tok in gen:
                await q.put(tok)      # 队列满时这里阻塞 = 背压
            await q.put(None)         # 结束哨兵
        finally:
            await gen.aclose()        # 关键：无论正常/取消，都关闭上游生成器

    prod_task = asyncio.create_task(producer())
    try:
        # 首 token 超时：客户端等第一个 token 的耐心上限
        first = await asyncio.wait_for(q.get(), timeout=ttfb_timeout)
    except asyncio.TimeoutError:
        prod_task.cancel()
        print(f"  [proxy] TTFB 超时({ttfb_timeout}s)，取消整个流")
        raise

    try:
        if first is not None:
            await client(first)
            yield first
        while True:
            tok = await q.get()
            if tok is None:
                break
            await client(tok)         # 客户端消费（可能很慢，触发背压）
            yield tok
    finally:
        if prod_task and not prod_task.done():
            prod_task.cancel()        # 客户端提前结束 -> 停上游
        if prod_task:
            await asyncio.gather(prod_task, return_exceptions=True)

async def fast_client(tok):
    await asyncio.sleep(0.01)
    return tok

async def slow_client(tok):
    await asyncio.sleep(0.2)          # 比上游(0.05s/块)慢 4 倍 -> 背压必然触发
    return tok

async def main():
    print("=== 场景1: 正常流（快速客户端）===")
    got = 0
    async for _ in proxy("hello", fast_client):
        got += 1
    print(f"  客户端收到 {got} 个 token")

    print("\n=== 场景2: 慢客户端 -> 背压（上游被队列阻塞，不会失控）===")
    t0 = time.time()
    got = 0
    async for _ in proxy("hello", slow_client, max_q=5):
        got += 1
    print(f"  客户端收到 {got} 个 token，总耗时 {time.time()-t0:.2f}s（被慢客户端限速）")

    print("\n=== 场景3: 客户端中途断开 -> 取消传播，上游立即停 ===")
    gen = proxy("hello", fast_client, max_q=5, ttfb_timeout=1.0)
    agen = gen.__aiter__()
    for _ in range(6):
        await agen.__anext__()
    await asyncio.sleep(0.5)          # 等生产者填满队列并阻塞在 put，确定性触发回退
    print("  [main] 客户端断开，关闭流...")
    await gen.aclose()
    await asyncio.sleep(0.05)

if __name__ == "__main__":
    asyncio.run(main())
```

运行输出：

```
=== 场景1: 正常流（快速客户端）===
  [upstream] 开始生成 20 个 token
  [upstream] 生成完毕
  客户端收到 20 个 token

=== 场景2: 慢客户端 -> 背压（上游被队列阻塞，不会失控）===
  [upstream] 开始生成 20 个 token
  [upstream] 生成完毕
  客户端收到 20 个 token，总耗时 4.07s（被慢客户端限速）

=== 场景3: 客户端中途断开 -> 取消传播，上游立即停 ===
  [upstream] 开始生成 20 个 token
  [main] 客户端断开，关闭流...
  [upstream] 被关闭！已产出 12/20，剩余 token 不再计费
```

三个场景对应的工程含义：场景 2 里 20 个 token 只用了 4.07 秒——和上游生成速度无关，**是慢客户端把整个链路限速了**，这就是背压在起作用（如果没有队列，内存里会堆积 80 个待发 token）。场景 3 里上游在 12/20 处被关闭——**剩下 8 个 token 的生成费用省下来了**，这就是取消传播的价值。

## 六、生产踩坑清单

1. **取消被吞**：`except BaseException` 或只处理 `GeneratorExit` 的 reader 会吞掉/漏掉取消。审计你的流式封装：清理逻辑放 `finally`，异常处理覆盖 `CancelledError` 并 `raise`。
2. **重试即双倍计费**：LLM API 不幂等，请求失败后盲目重试 = 同样的 token 生成两遍。重试只对**建连失败/HTTP 层错误**做，已开始出流的请求断了不要重放（要重放就带上"已有内容"提示词重新生成）。
3. **计量要跟流走**：计费/用量统计要在流的 `finally` 里落账（含中断流），不能等"正常结束"。中断流的上游 usage 信息拿不到，按已收到的 delta 估算。
4. **粘性路由**：多副本部署时，长连接要么无状态（每 chunk 都能独立处理），要么按会话粘到同一副本——否则中间代理重连后请求落到别的副本，上下文就丢了。
5. **心跳**：网关/负载均衡器会掐空闲连接，流式响应如果偶尔长时间无 chunk（思考型模型"想"很久），要么客户端侧配空闲超时容忍，要么服务端定期发注释行（SSE 允许 `: ping` 注释行保活）。
6. **TTFB 指标必埋**：业界广泛引用 Google 的研究——延迟每增加 100ms 用户流失约 1%。流式 TTFB 是第一体验指标，配不上 500ms 内出首 token 就要查（prefill 太长？路由太慢？网关缓冲？）。

## 七、结论

流式后端的工程本质是**一条异步管道的生命周期管理**：背压控制节奏、超时兜底异常、取消传播止损。协议本身（SSE）反而是最简单的一层。把上面六条踩坑写进你的代码评审 checklist，比记住协议格式值钱得多——尤其第 2 条和第 5 条，一个省的是钱，一个救的是线上事故。

相关阅读：[LLM 可观测性：延迟拆解与 Token 计量](/blog/2026/08/06/llm-observability-production)、[结构化输出技术拆解](/blog/2026/08/10/structured-output-techniques)、[LLM Router 工程经验](/blog/2026/08/03/llm-router-engineering-lessons)
