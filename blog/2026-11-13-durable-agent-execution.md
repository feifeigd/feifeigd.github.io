---
title: "Agent 崩溃之后：把 Agent Loop 做成可恢复的工作流，journal、replay 与工具副作用的 exactly-once"
date: 2026-11-13T20:30:00+08:00
draft: false
tags: ["ai", "llm", "agent", "engineering", "architecture", "observability"]
categories: ["Tech"]
description: "Agent 跑 24 步、几分钟、几十万 token，进程一被驱逐就从头再来，副作用还重放一遍——这不是 Agent 的新问题，是长事务的老问题，只是多了一个非确定性的采样环节。本文把 Agent loop 当工作流来设计：事件日志记什么、三个崩溃点各自怎么恢复、幂等键怎么构造，附一份纯标准库可运行的实现和 200 次崩溃注入的实测数据（token 浪费 34.9%、重复副作用从 184/200 降到 0/200），以及我自己写第一版时踩的坑。"
---

一个 Agent 处理一张工单，跑了 24 步：检索政策文档、查客户历史、算 SLA 抵扣、发邮件给客服、发审批给财务、发合同条款给法务。中间隔了几十次模型调用，耗时四分多钟，烧掉九万多 token。

然后进程没了。可能是 K8s 滚动发布，可能是 OOMKilled，可能是网关 60 秒超时把连接掐了，也可能是你自己写的 `max_steps` 护栏把它判死。

大多数团队这时候的处理是「失败重试 3 次」。于是你付出了三份账单，并且——更糟——客服收到了两封一模一样的邮件，财务系统里多了两张审批单。重试逻辑本身没错，错的是它假设这个循环是**可以重跑的函数**，而实际上它是一条**带副作用的长时间运行工作流**。

这篇不谈 prompt，不谈工具设计，只谈一件事：怎么让这个循环在进程随时会死的环境里，做到「钱不重花、副作用不重放」。这篇文章的核心结论可以先用一句话说完：**日志里要记的不是动作，而是决策与效果；执行前先落 intent，恢复时用同一把幂等键重放工具**。

{/* truncate */}

## 一、这是分布式系统的老问题，外加一个新变量

长流程加崩溃恢复，后端工程师都熟：Saga、TCC、事件溯源、Temporal/Cadence 的工作流引擎，答案都一样——把执行过程记成一条只追加的事件日志，崩溃后**重放日志**，而不是**重跑世界**。

Temporal 的重放模型有个前提：工作流代码是确定性的，同样的历史输入必然产生同样的分支。这个前提在 Agent 里直接断了。Agent 的每一步都经过一次大模型采样，温度 0.7、上下文漂移、服务端模型静默升级，任何一个都会让「重放」得到不同的动作。你重放二十步历史，模型可能在第 7 步改主意，去调另一个工具。

所以 Agent 的可恢复性不能靠「代码确定性」，只能靠「把不确定性也记下来」。这是本文所有设计的出发点。

## 二、两类不确定性，决定了日志该记什么

| 来源 | 表现 | 能不能重算 | 处理方式 |
|---|---|---|---|
| 模型采样 | 同一 prompt 两次输出不同 | 不能 | 记录完整输出，重放时直接复用 |
| 工具副作用 | 邮件发出去了、订单下了 | 绝对不能重做 | 记录 intent + 幂等键，重放时交给服务端去重 |

由此推出事件设计。一张最小可用的表，四类事件加两个边界事件：

| 事件 | 关键字段 | 重放时的语义 |
|---|---|---|
| `RunStarted` | 模型版本、prompt 模板 hash、预算上限 | 一致性校验，版本不符拒绝重放 |
| `LlmSampled` | step、完整输出（含 tool call）、usage | 直接复用，**零 token** |
| `ToolRequested` | step、tool、规范化后的 args、idem_key | 恢复时用同一把 key 重放 |
| `ToolResult` | step、结果 | 直接复用，不再调用 |
| `StepCommitted` | step | 提交点，对外可见的边界 |
| `RunFailed` | 错误分类、重试次数 | 决定重试还是进死信 |

最容易搞错的是第一行和第三行。很多实现只记 `ToolRequested`（「第 7 步调了 send_email」），恢复时重新让模型决策。这在 demo 里能跑通，在生产里会出两类事故：重采样出来的动作不一样，日志和历史对不上；以及每次恢复都要为已经付过钱的上下文再付一遍。

反过来，只记 `LlmSampled` 而不记 `ToolRequested`，就丢掉了幂等键——恢复时你没法证明「这次要执行的调用，和崩溃前那次是同一个逻辑调用」。

## 三、三个崩溃点，只有一个是真危险

把一步拆成「采样 → 执行 → 提交」三段，崩溃可能落在四个位置：

| 崩溃位置 | 已落盘 | 危险 | 恢复动作 |
|---|---|---|---|
| 采样前 | 无 | 无 | 重采样，这次决策首次落盘 |
| 采样后、执行前 | `LlmSampled` | 无 | 直接执行，不再问模型 |
| **执行中** | intent 有、result 无 | **高** | 同 key 重放工具，服务端去重 |
| 结果后、提交前 | `ToolResult` 有、commit 无 | 无 | 补写提交点 |

第二行和第四行都好办，第三行是全部难点所在。崩溃发生在「HTTP 请求已发出、响应还没收到」的窗口里，你的日志只有 intent，没有 result。此时进程重启，你面临的问题是一个**不可判定的状态**：邮件到底发出去了没有？

没有 intent 记录，你连这个不可判定性都意识不到——你只会看到「第 7 步没有结果」，然后天真地重发。有了 intent 记录但没有幂等键，你同样只能在「可能重复」和「可能遗漏」之间二选一。

所以规则的顺序很重要：**先写 intent（含幂等键），再执行，最后写 result**。intent 那一次 insert 的成本是几十微秒，换来的是崩溃后可判定的状态。

## 四、一份可跑的实现

下面这段只用标准库，`sqlite3` 的 WAL 模式当事件存储，够用到单机每天几万次 run。核心不到七十行。

```python
import json, sqlite3, hashlib

def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

class Journal:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS events(
            run_id TEXT NOT NULL, seq INTEGER NOT NULL, type TEXT NOT NULL,
            payload TEXT NOT NULL, PRIMARY KEY(run_id, seq))""")

    def append(self, run_id, etype, payload):
        # (run_id, seq) 主键冲突 = 另一个 worker 抢先提交，天然乐观锁
        seq = self.db.execute(
            "SELECT COALESCE(MAX(seq),0)+1 FROM events WHERE run_id=?",
            (run_id,)).fetchone()[0]
        self.db.execute("INSERT INTO events VALUES(?,?,?,?)",
                        (run_id, seq, etype, canon(payload)))
        self.db.commit()

    def index(self, run_id):
        rows = self.db.execute(
            "SELECT type,payload FROM events WHERE run_id=? ORDER BY seq",
            (run_id,)).fetchall()
        return {(t, json.loads(p).get("step")): json.loads(p) for t, p in rows}

def idem_key(run_id, step, tool, args):
    # 参数必须先规范化，否则 {"a":1} 和 {"a":1.0} 会算出两把不同的键
    return hashlib.sha256(
        canon([run_id, step, tool, args]).encode()).hexdigest()

def run_agent(run_id, j, tools, llm, plan_len):
    for step in range(plan_len):
        idx = j.index(run_id)                      # 重放路径：只读，绝不 append
        ctx = [e["result"] for (t, s), e in idx.items() if t == "ToolResult"]

        out = idx.get(("LlmSampled", step))
        if out is None:                            # 只有首次执行才花 token
            out = llm(ctx, step)
            j.append(run_id, "LlmSampled", dict(step=step, **out))

        if ("ToolResult", step) not in idx:
            intent = idx.get(("ToolRequested", step))
            key = intent["key"] if intent else idem_key(
                run_id, step, out["tool"], out["args"])
            if intent is None:                     # 先落 intent，再产生副作用
                j.append(run_id, "ToolRequested",
                         dict(step=step, tool=out["tool"],
                              args=out["args"], key=key))
            result = tools.call(out["tool"], out["args"], key=key)
            j.append(run_id, "ToolResult", dict(step=step, result=result))
            j.append(run_id, "StepCommitted", dict(step=step))
```

工具侧的契约只有一条：`tools.call(name, args, key)` 必须对同一个 `key` 返回同一个结果，且只产生一次副作用。Stripe 的 `Idempotency-Key`、支付网关的 `out_trade_no`、`INSERT ... ON CONFLICT DO NOTHING`，都是这个契约的实现。这一层不做，上面的日志再漂亮也拦不住重复扣款。

## 五、实测：200 次崩溃注入

光说道理没有说服力，我写了个 harness 跑了一组对照：24 步的工单处理流程，其中 6 步是有副作用的 `send_email`（写文件计数），18 步是只读检索，每次检索返回三篇约 400 字的文档。对照组是「不加日志、失败后从头重跑」的朴素实现。每个组合跑 200 次，崩溃点随机取。

| 场景 | token 消耗 | 模型调用次数 | 实际发出的邮件 | 重复副作用 |
|---|---|---|---|---|
| 无崩溃基线 | 91,203 | 24 | 6 | 0 |
| 朴素 + 崩溃 1 次 | 126,960 (+39%) | 35 | 9 | 3 |
| 朴素 + 崩溃 3 次 | 212,416 (+133%) | 62 | 15 | 9 |
| 持久化 + 崩溃 1 次 | 91,203 (+0%) | 24 | 6 | 0 |
| 持久化 + 崩溃 3 次 | 91,203 (+0%) | 24 | 6 | 0 |
| 200 次随机崩溃·朴素 | 均值 140,006 | — | 均值 8.90，最多 12 | **184/200 次出现** |
| 200 次随机崩溃·持久化 | 均值 91,203 | — | 恒为 6 | **0/200 次出现** |

三组数字值得停了看一眼。

**第一，token 只省了 34.9%，不是省了 100%。** 因为崩溃点越靠前，已经花掉的钱越少；而且重跑时上下文是重新累积的，前期 prompt 比原 run 短。省下来的本质是「崩溃前那一段已经付过钱的前缀」，不是全部。

**第二，崩溃 3 次时差距拉到 133%。** 朴素实现的浪费是**乘法**的：每次重跑都要把前面所有步骤再付一遍，崩溃概率越高越吃亏。这也解释了为什么「重试 3 次」这个策略在长流程里是反模式——它不是把成功率乘以三，而是把最坏情况的成本乘以三，同时把副作用风险也乘以三。

**第三，重复副作用是会被用户看见的那一半。** token 浪费是账面成本，重复邮件是事故。184/200 次随机崩溃里，朴素实现都至少多发了一封；最坏的一次 12 封，正好是期望值的两倍。

恢复本身的延迟：24 步、96 条事件的历史全量重放，p50 47.6ms、p95 94.2ms。这个量级完全够用，因为重放不碰网络、不碰模型。如果 run 会长到几百步，就该上快照：日志每 N 步存一份上下文摘要，恢复时只重建尾段。我测了 24 步里只重建最后 8 步，payload 七千多字节，重建耗时 0.10ms。

日志本身的体积：96 条事件的主库 48KB，含工具返回的原文。一千条事件的库约 3.7MB，建一次全量索引 216ms——所以重放路径一定要一次性建索引，而不是每次查询都全表扫。

## 六、踩坑：我自己第一版就错了两次

这部分是这篇文章真正的价值所在，因为下面每一条我都在同一个下午撞到过。

**坑一：重放路径不能写日志。** 我第一版把 `StepCommitted` 写在循环末尾，不在 `if` 里面。结果每次恢复都把二十几步重新「提交」一遍：事件数从 96 涨到 131，而且每次重启都更长，重放越来越慢。规则很硬：**replay 是只读的**，只有「首次执行」的那条分支才有资格 append。这个 bug 不会报错，只会让你的日志慢慢膨胀，很难归因。

**坑二：空幂等键被当成了「共享一把键」。** harness 第一版里朴素实现调工具时传 `key=""`，而服务端去重的实现是 `if key in self.sent: return cached`。空串在字典里是个合法键，于是所有邮件都被判成「重复请求」——6 封只落地 1 封，测出来的数字全错。空键必须显式表示「无幂等保护、不去重」，而不是「大家共用一把键」。这个概念错误在真实系统里对应的是：拿 `user_id` 当幂等键，把用户的所有请求都判成同一个。

**坑三：参数哈希必须先规范化。** `json.dumps` 默认保留空格、不排序键。`{"to": "a", "subject": "b"}` 和 `{"subject": "b", "to": "a"}` 是两个不同的字符串，算出两把不同的键，服务端认为是两次独立调用，于是发了两封。必须 `sort_keys=True, separators=(",", ":")`。同理：`1` 和 `1.0`、`"café"` 的 NFC 与 NFD 两种 Unicode 规范化形式，都会让同一个逻辑调用算出不同键。哈希之前先过一遍规范化函数。

**坑四：时间和随机数不能进 prompt。** 把 `now()` 或者 `uuid4()` 塞进上下文，会同时破坏两件事：前缀缓存命中率（每次前缀都不同），以及「同一 step 的 prompt 因该稳定」这个假设，导致你没法用 prompt hash 判断决策是否可复用。正确做法是把时间当成一个 journaled 的输入值——在 `RunStarted` 里记一次，重放时用它，不要重新取。

**坑五：并行工具调用要稳定排序。** 模型一轮返回三个 tool call，用 `asyncio.gather` 并发执行，结果按完成顺序写入日志。崩溃恢复后按日志顺序重放，上下文里工具结果的顺序就变了，模型看到的输入和上次不同。执行可以并发，**写入日志必须按模型给出的 call 顺序**。

**坑六：WAL 文件会吃掉你的磁盘。** 我用 `PRAGMA journal_mode=WAL`，主库文件一直是 4KB，所有数据都在 `-wal` 里躺着，直到 checkpoint。测体积的时候只看主库会得出「日志才 4KB」的错误结论。生产上要定时 `wal_checkpoint(TRUNCATE)`，否则一个长跑进程的 WAL 能涨到几个 G。

**坑七：两个 worker 同时 resume。** 滚动发布时新旧两个 pod 可能都持有同一个 run。我的实现靠 `(run_id, seq)` 主键冲突当乐观锁——两个 worker 都想写 seq=42，一个成功一个报错退出。但这只保证日志不重，不保证副作用不重：两个 worker 可能都已经读到了 intent 并各自去执行。所以还需要一把带 fencing token 的租约（`SELECT ... FOR UPDATE` 或 Redis 的 `SET NX PX` 加续约），拿到租约的才能执行工具。

**坑八：预算要进日志。** `max_steps=30`、`max_cost=2 美元` 这类护栏，如果在恢复时重新初始化，那么崩溃 3 次就能花掉 4 倍预算。预算的消耗量必须和 step 一样是日志里的状态。

**坑九：换模型之后不要重放旧 run。** `RunStarted` 里记下模型版本和 prompt 模板 hash。模型升级后，旧 run 的 `LlmSampled` 事件是另一个模型产生的，用它继续跑会导致上下文风格断裂；更隐蔽的是模板改了之后 tool schema 对不上，重放直接抛异常。策略应该是：版本不一致就拒绝重放，从最近一次快照以「新 run」继续，而不是假装历史连续。

**坑十：日志是第二份数据副本。** 工具返回里可能有身份证号、手机号、合同金额。事件日志的保留期、脱敏、访问控制，要和你的业务库同等级别对待——很多团队把 trace 和日志接到第三方可观测平台时完全没考虑这一点。

## 七、什么时候不值得这么做

别把它当银弹。判断标准是一个粗糙的乘法：

**（单次 run 的副作用数量 × 单次副作用出错的代价）对比（崩溃概率 × 重跑成本）**

只读检索类 Agent——查文档、答问题、做分析——副作用数量是零，重跑只是多花钱，加日志的收益有限，先做好 trace 和超时控制更划算。反过来，只要涉及支付、通知、写业务库、提交代码、发工单，副作用出错的代价就是事故级别，此时几十行日志代码的投入产出比高得离谱。

中间地带是那些「单次 run 超过一分钟、每天上万次、跑在会被驱逐的调度器上」的场景。这类系统崩溃不是异常，是**常态**——按每天 10 万次 run、1% 的崩溃率算，一天就是一千次重跑。这时候日志不是可靠性优化，而是成本控制的必需品。

## 八、小结

三句话：

1. Agent loop 是长事务，不是函数调用。把它当工作流设计，别当 `while` 循环设计。
2. 日志记决策（模型输出）和效果（工具结果 + 幂等键），不记动作。动作会在重放时漂移，决策不会。
3. 先写 intent 再执行。这一条决定了崩溃后你面对的是「可判定的状态」还是「二选一的赌博」。

顺带一提，这套东西和传统工作流引擎并不冲突：Temporal 也能跑 Agent，把模型调用包成 activity 就行。但要注意 activity 的默认重试语义是为幂等操作设计的，而模型调用既不幂等、又贵，必须配置成「不重试、结果记录在案」，或者干脆当成不可变的历史事件处理。这一点想不清楚，用框架也只是把坑挪了个地方。

相关阅读：[AI Agent 工程化实践](/blog/2026/07/30/agent-engineering-production-guide)（可观测性与容错的全景）、[Agent 的记忆系统](/blog/2026/08/13/agent-memory-system)（长期记忆与上下文分层）、[分布式事务](/blog/2026/08/20/distributed-transaction-interview)（Saga/TCC 与补偿的原始账本）、[Agent 评测工程化](/blog/2026/08/19/agent-eval-engineering)（轨迹级评测怎么衡量恢复后的正确性）。
