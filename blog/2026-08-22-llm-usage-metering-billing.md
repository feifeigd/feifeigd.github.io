---
title: "Token 即金钱：LLM 用量计量与计费系统的工程实践"
date: 2026-08-22T16:30:00+08:00
draft: false
tags: ["ai", "llm", "backend", "engineering", "infra"]
categories: ["AI"]
description: "从 usage 字段的 provider 差异、多维定价快照、append-only 计量管道到多 Agent 分账：把每次模型调用准确记成账单的地基工程，附计价/聚合/分账可运行代码"
---

聊 LLM 应用的工程，大家津津乐道的是推理优化、RAG、Agent 编排，但真正决定一个 ToB/ToC 产品能不能赚钱的，往往是没人愿意写的**计量与计费**。模型调用不像 MySQL 查询——没有免费的 `EXPLAIN`，每一次 API 调用都是真金白银的流出；而一旦你开始对用户收费、对开发者分成，计费就从「省钱工具」升级成「信任地基」：**计量错了，不是亏钱就是信任崩塌**。

这篇文章从后端工程师视角，把「一次模型调用 → 一条 usage 事件 → 一张账单 → 一笔分账」的完整链路拆开：usage 从哪来、按什么价、怎么记、怎么算、怎么对账。基于真实平台（以 DeepSeek 2026-08 官方计价为例）的实操经验，有 schema、有代码、有坑。

{/* truncate */}

## 一、usage 从哪来：先搞清 provider 给你什么

计费的第一步不是算钱，是**拿到准确的用量**。所有主流 provider 都会在响应里返回 usage，但字段完全不同：

| Provider | 字段 | 备注 |
|---|---|---|
| OpenAI | `prompt_tokens` / `completion_tokens` | 兼容接口事实标准 |
| Anthropic | `input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` | 缓存单独拆两个字段 |
| DeepSeek | `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` / `completion_tokens` | 缓存命中/未命中分开计 |

三个立刻会踩的坑：

**1. streaming 模式下 usage 是「流尾」才给的。** OpenAI 兼容接口要显式传 `stream_options: {"include_usage": true}`，usage 才会出现在最后一条 chunk；Anthropic 的 usage 在 `message_delta` 事件里，`output_tokens` 还是**增量**（每个 delta 只报本次新增的），要自己累加。更麻烦的是：**客户端中途断开、上游报错，usage 就永远拿不到了**——输入 token 数你还能自己算，输出 token 数直接失明。这个坑在第五节讲兜底方案。

**2. 永远信 provider 的 usage，别自己数 token。** 你的 tokenizer 版本和线上不一定一致，多轮对话 + 缓存前缀的边界（prompt 里哪些 token 命中缓存）只有服务端知道。自数 token 的误差在长上下文场景可以到 10% 以上，计费系统里这是不可接受的。自己数的 token 只能用来做**展示**（打字机效果的字符数），不能入账。

**3. thinking/reasoning token 是隐藏成本炸弹。** DeepSeek 的 thinking 模式默认开启，思考 token 按**输出价**计费。一次「想太多」的回答，成本可以到正常输出的 2-5 倍。做平台的话要么显式关掉 thinking（成本直降 60%+），要么把它作为独立计费项展示给用户——否则用户看到账单会以为是 bug。

## 二、定价模型：价格快照 + 多维计价

用量是「多少个 token」，价格是「每个 token 多少钱」。但现实里价格不是一个数，而是**多维矩阵**：

- 模型 × 计费项（输入/输出/缓存命中/缓存未命中/思考 token）→ 不同单价
- 计费项之间差价巨大，**缓存命中价和未命中价可以差 30 倍**（见下表）
- 峰值时段 ×2（DeepSeek 按北京时间 09-12 和 14-18 双高峰翻倍）
- 涨价/调价是常态：**老账必须按老价**

以 DeepSeek 2026-08 官方价为例（USD / M token，汇率按 7.2）：

| 模型 | 输入（未命中） | 输入（缓存命中） | 输出 | 峰值时段 |
|---|---|---|---|---|
| flash | $0.22 | $0.007 | $0.66 | ×2 |
| pro | $0.66 | $0.022 | $1.98 | ×2 |

缓存命中价是未命中价的 **1/30**——这是整个计费模型里最值得做文章的维度：固定系统提示词 + 多轮对话让前缀缓存命中，单次调用成本可以低到可忽略。反过来也意味着：**计费口径必须按 cache 字段拆分，不能只按 input 一个价**，否则用户多付 30 倍的钱，平台多赚 30 倍不该赚的钱。

价格表（price book）的设计核心是**版本化快照**：

```sql
CREATE TABLE price_book (
    id            BIGSERIAL PRIMARY KEY,
    model         TEXT NOT NULL,              -- 'deepseek-flash' / 'deepseek-pro'
    item          TEXT NOT NULL,              -- input_miss / input_hit / output / reasoning
    unit_price_usd NUMERIC(10,6) NOT NULL,    -- 每 M token 单价（USD）
    peak_factor   NUMERIC(3,2) NOT NULL DEFAULT 1.00,
    effective_from TIMESTAMPTZ NOT NULL,      -- 生效时间（涨价老账按老价的关键）
    effective_to   TIMESTAMPTZ                -- NULL = 当前生效
);

-- 一次请求 = 按请求发生时间查快照，而非按账单生成时间查
-- 查价：WHERE effective_from <= :ts AND (effective_to IS NULL OR effective_to > :ts)
```

计价函数（Python 伪代码，可直接跑）：

```python
from datetime import datetime, time

PEAK_WINDOWS = [(time(9, 0), time(12, 0)), (time(14, 0), time(18, 0))]

def is_peak(dt: datetime) -> bool:
    # DeepSeek 峰值时段按北京时间
    t = dt.astimezone(timezone(timedelta(hours=8))).time()
    return any(start <= t < end for start, end in PEAK_WINDOWS)

def price(usage: dict, book: dict, ts: datetime, rate_usd_cny: float) -> int:
    """返回人民币「分」的整数金额，杜绝浮点误差"""
    total = 0.0
    # usage 已归一化为 {input_miss, input_hit, output, reasoning}
    for item, tokens in usage.items():
        if tokens == 0:
            continue
        row = book[item]
        unit = row.unit_price_usd * (row.peak_factor if is_peak(ts) else 1.0)
        total += tokens * unit / 1_000_000          # 每 M token
    return int(total * rate_usd_cny * 100 + 0.5)    # USD → 人民币分，四舍五入
```

两个细节：金额一律用**整数分 + Decimal**，token × 单价/M 的乘法顺序固定（先乘后除，减少舍入扩散）；汇率 7.2 也是**带生效时间的快照**——汇率波动时老账单不重算。

## 三、计量管道：append-only 事件 + 窗口聚合

用量和价格都有了，剩下的问题是**怎么把几百万条调用可靠地变成账单**。核心原则一句话：**计量是 append-only 的流水账，账单是它的只读投影**。

```sql
CREATE TABLE usage_events (
    id            BIGSERIAL PRIMARY KEY,
    request_id    TEXT NOT NULL,              -- 网关生成的幂等键（每条模型调用一个）
    user_id       BIGINT NOT NULL,
    agent_id      BIGINT NOT NULL,            -- 分账维度：这笔钱归哪个 agent
    chain_id      TEXT NOT NULL,              -- 组合请求：多步 Agent 串成一个链
    model         TEXT NOT NULL,
    input_miss    BIGINT NOT NULL DEFAULT 0,
    input_hit     BIGINT NOT NULL DEFAULT 0,
    output        BIGINT NOT NULL DEFAULT 0,
    reasoning     BIGINT NOT NULL DEFAULT 0,
    raw_usage     JSONB NOT NULL,             -- provider 原始 usage，审计用
    occurred_at   TIMESTAMPTZ NOT NULL,
    UNIQUE (request_id)                       -- 幂等：重试上报直接冲突
);

CREATE INDEX idx_events_agent_time ON usage_events (agent_id, occurred_at);
```

链路：`LLM 网关 → 归一化 usage → Kafka usage_events → 5min 窗口聚合 → 账单表`。

- **幂等**：网关给每条模型调用分配全局唯一的 `request_id`，provider 超时重试、上报重放都靠 `UNIQUE(request_id)` 挡住——这是计量准确的第一道防线。聚合算子也要幂等：同一个窗口重跑结果不变（窗口聚合只依赖 `occurred_at` 和 `request_id`，不依赖处理顺序）。
- **准确大于实时**：实时给用户看的是「估算」，T+1 用完整事件重算「正式账单」。迟到的 usage 事件（流尾断线重试补报）允许追入前一天的窗口，而不是丢进当前窗口——宁可 T+1 准，不要实时错。
- **金额在聚合时算，不在展示时算**：聚合器从 price_book 取事件发生时刻的价格快照，算出「分」存下来。之后涨不涨价都不影响历史账单。

## 四、分账：组合请求的账单归属

单模型计费只是起点。一旦上了 Agent 平台，一次用户请求可能内部串了多个模型调用（规划 → 工具执行 → 总结），而**每个模型调用都可能属于不同的开发者**。分账规则一旦模糊，就是平台和开发者的信任危机。

业界通行的做法（也是我们敲定的规则）：**组合请求 = N 笔独立交易**。编排层每调一次模型，就发一条独立的 usage_event，带上自己的 `agent_id` 和共同的 `chain_id`。于是：

```sql
-- 分账就是一次 GROUP BY
SELECT agent_id,
       COUNT(DISTINCT chain_id)                            AS billable_calls,
       SUM(amount_fen) / 100.0                             AS gross_yuan,
       SUM(amount_fen) * 0.70 / 100.0                      AS dev_share_yuan  -- 毛收入抽成 30%
FROM bills
WHERE occurred_at >= date_trunc('month', now())
GROUP BY agent_id;
```

要点：

- **事件带 `agent_id`，账单按 agent 聚合**——不需要任何「分摊」逻辑，因为每次调用天然只属于一个 agent。跨 agent 的编排成本记在平台头上（编排层自己也是一条 usage_event，`agent_id` 指向平台）。
- **防套娃**：同开发者 agent 互调要限深度（比如最多 5 层）、限循环（单请求最多 2 次）、单 agent 日成本超阈值自动告警熔断。否则一个死循环的 agent 能在一小时内烧掉一个月的预算——这类事故在 Agent 平台的真实发生率远高于直觉。
- **退款 = 冲正**：计量表 append-only，不允许 UPDATE 改历史。退款就插入一条金额为负的冲正事件（同 `request_id` 关联），账单投影自然扣减，审计轨迹完整。
- **分成模式的切换要提前设计**：solo 期用「毛收入抽成」（不亮成本，平台抽 35-40%），规模化后切「净收入分成」（实付 − 模型成本 − 手续费，抽 20-30%）。两条路的分账 SQL 只差一个成本表 JOIN——但**计量口径从第一天就要按净收入的标准记**（缓存命中/未命中、思考 token 分开），否则切换那天没有历史数据可算。

## 五、踩坑记录：真实生产里遇到的四个坑

**坑 1：thinking 默认开，成本 ×2-5。** 上线第一天对账，发现成本是预估的 3 倍。查下来是 DeepSeek 的 thinking 模式默认开启，思考 token 按输出价计。解法：平台侧默认显式关闭 thinking（除非产品需要），并在计量里把 reasoning 单独拆项——既控制成本，也让用户看到钱花在哪。

**坑 2：流中断拿不到 usage。** 用户点「停止生成」，客户端断开，流尾的 usage 永远到不了。我们的兜底：网关侧记录已推送的 chunk 数和最后一个 chunk 的时间，中断后**按输入 token（自己可算）+ 输出 token 估算（chunk 数 × 该请求平均 chunk token 数）**生成一条 `verified=false` 的事件，T+1 对账时用 provider 侧数据校正。宁可先估后校正，也不能漏记——漏记是纯亏，估错是可修正的。

**坑 3：峰值判断的时区。** 峰值时段 ×2 是按**北京时间**定的。服务器跑在 UTC 的容器里，直接 `datetime.now().hour` 判断峰值，会把北京时间 17:00（UTC 9:00）的请求按非峰值计价。统一先转 `+08:00` 再判断，并且峰值判定用**请求发生时刻**而非事件落库时刻（Kafka 延迟会让两者差出几分钟，恰好卡在 12:00 边界就是两个价）。

**坑 4：多 provider 字段归一化。** 同一个网关接 OpenAI/Anthropic/DeepSeek，usage 字段名三套。归一化层必须做在**网关侧**（离 provider 最近的地方），转成 `{input_miss, input_hit, output, reasoning}` 四元组再进 Kafka。否则下游每个消费者都要写一遍字段映射，漏一个字段就是一笔账算错。

## 六、对账：计量系统的最后一道防线

再严谨的管道也会出错：provider 结算单和你的流水对不上（provider 侧缓存策略变更、计费 bug、你漏记的流中断）。所以**定期对账**是计量系统的标配：

1. 拉 provider 的用量账单（OpenAI/DeepSeek 后台都有按日的 token 报表）
2. 和本地 `usage_events` 按 `(model, 日期, 输入/输出 token 数)` 汇总比对
3. 差异超过阈值（比如 2%）触发告警，逐条 diff：多记的查 `request_id` 幂等，漏记的查流中断兜底

对账频次从日对开始。**计费的准确率是用对账对出来的，不是设计出来的**——这句话值得刻在计费系统的 README 第一行。

## 小结

计量计费不性感，但它是 LLM 平台的「总账」。回顾关键决策：**usage 信 provider 不信自己、价格用带生效时间的多维快照、流水 append-only + 幂等、金额整数分、分账靠事件维度而非分摊、T+1 对账兜底**。这套组合拳下来，从「每次调用烧了多少钱」到「每个 agent 该分多少钱」，都能给出一张经得起审计的账。

相关阅读：[LLM 流式响应后端工程（SSE/背压/取消传播）](/blog/2026/08/20/llm-streaming-backend-engineering)（usage 在流尾返回的工程细节）、[LLM 路由的工程真相](/blog/2026/08/03/llm-router-engineering-lessons)（网关层的成本优化视角）。
