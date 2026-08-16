---
title: "面试题：设计一个分布式 ID 生成器，雪花算法、时钟回拨、美团 Leaf 一次讲清"
date: 2026-08-16T09:00:00+08:00
draft: false
tags: ["system-design", "distributed", "architecture", "interview"]
categories: ["Interview"]
description: "系统设计高频题：分布式 ID 生成器怎么设计？从数据库自增、UUID、号段模式到雪花算法、美团 Leaf、百度 UidGenerator 的演进路线，附完整雪花算法代码和时钟回拨处理方案。"
---

> 这是「每日一题」专栏的第六篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇讲了[短链接系统](/blog/2026/08/12/url-shortener-system-design-interview)，今天解决另一个「看似简单、坑很深」的题。

{/* truncate */}

## 题目

**设计一个全局唯一的 ID 生成器，用于订单、用户等业务。要求：全局唯一、趋势递增、高性能、不依赖中心节点。**

## 为什么需要分布式 ID

单库时代，`AUTO_INCREMENT` 自增主键就够用了。分库分表之后，问题一个接一个冒出来：

1. **多库自增会冲突**：订单表拆成 128 张，每张表都从 1 开始自增，主键 `1` 会出现 128 次，全局不唯一。
2. **合并数据会打架**：把多张分表的数据合并到一张大表做分析，主键直接撞车。
3. **暴露业务量**：自增 ID 是连续的，竞争对手看到你今天的订单 ID，就能反推你一天下了多少单。
4. **单点依赖**：自增靠数据库，数据库一挂，ID 断供，整个写入链路瘫痪。

所以「全局唯一 + 趋势递增 + 高性能 + 信息安全」成了分布式 ID 的四个硬指标。下面按演进顺序逐个讲。

## 方案一：UUID（最省事，但有两个致命伤）

```java
String id = UUID.randomUUID().toString();
// 输出: 550e8400-e29b-41d4-a716-446655440000
```

优点：本地生成、零依赖、天然全局唯一。

缺点：

- **无序**：UUID 是随机的，作为主键插入 B+ 树时会造成大量页分裂和随机 IO，数据库写入性能雪崩。
- **太长**：36 个字符（去掉横线也有 32 个），按字符串存储，索引和内存开销都大。

**结论：UUID 只适合「非主键」场景（比如 TraceID），不适合做数据库主键。**

## 方案二：数据库号段模式（美团 Leaf-segment 的前身）

核心思路：不是每条 ID 都查数据库，而是一次「批」一批号段放进内存，用完了再取。

```sql
-- 号段表
CREATE TABLE id_alloc (
    biz_tag    VARCHAR(32) PRIMARY KEY,  -- 业务标识，如 order
    max_id     BIGINT      NOT NULL,     -- 当前已分配到的最大 ID
    step       INT         NOT NULL      -- 每次分配的号段长度
);

-- 每次取号段（事务内）
UPDATE id_alloc SET max_id = max_id + step WHERE biz_tag = 'order';
SELECT max_id FROM id_alloc WHERE biz_tag = 'order';
```

应用拿到 `[max_id - step + 1, max_id]` 这个区间，在内存里自增分配，用完再取下一段。

优点：

- 全局唯一、趋势递增、实现简单。
- **号段缓存**：一次取 1000 个，DB 压力降为千分之一。

缺点：

- 号段用完那一瞬间有短暂的「取号段」延迟（可用双 Buffer 缓解）。
- 仍依赖数据库，DB 不可用就断供。
- **不保证单调递增**：A 机器先拿到 `[1,1000]`，B 机器拿到 `[1001,2000]`，B 先分配完，可能出现「后分配机器的 ID 更小」——但「趋势递增」已满足绝大多数场景。

## 方案三：Redis INCR（简单，但要持久化）

```python
import redis
r = redis.Redis(host="localhost", port=6379)

def next_id():
    return r.incr("order:id")   # 原子自增，返回 1, 2, 3, ...
```

`INCR` 命令天然原子，单机 Redis 能做到 10 万 QPS 级别。

缺点：

- Redis 是内存存储，不持久化重启就归零（要配 AOF 且 `appendfsync always`）。
- 数据量大时 Redis 也是单点，做集群还要额外设计。

## 方案四：雪花算法 Snowflake（面试必考，重点）

Twitter 开源的经典方案，**不依赖任何中间件，纯本地生成**。这也是[短链接系统](/blog/2026/08/12/url-shortener-system-design-interview)里「分布式 ID + Base62」方案提到的那个雪花算法。

### 64 位组成

```
0 - 0000000000 0000000000 0000000000 0000000000 0 - 00000 - 00000 - 000000000000
│   └────────────── 41 位时间戳 ──────────────┘   └ 10 位 ┘   └── 12 位序列号 ──┘
符号位(1)        毫秒级，可用约 69 年              工作机器ID   同毫秒内递增序列号
```

| 部分 | 位数 | 说明 |
|------|:---:|------|
| 符号位 | 1 | 固定为 0，保证 ID 为正数 |
| 时间戳 | 41 | 相对某个起始时间的毫秒数，可用约 69 年 |
| 工作机器 ID | 10 | 最多 1024 台机器（5 位机房 + 5 位机器） |
| 序列号 | 12 | 同一毫秒内最多 4096 个 ID |

**算力**：每毫秒 4096 个，每秒约 409.6 万个 ID，单机完全够用。

### 完整代码

```java
public class SnowflakeIdGenerator {
    private static final long START_TIMESTAMP = 1704067200000L; // 2024-01-01 00:00:00
    private static final long WORKER_ID_BITS = 5L;      // 机房 5 位
    private static final long DATACENTER_ID_BITS = 5L;  // 机器 5 位
    private static final long SEQUENCE_BITS = 12L;      // 序列号 12 位

    private static final long MAX_WORKER_ID = ~(-1L << WORKER_ID_BITS);        // 31
    private static final long MAX_DATACENTER_ID = ~(-1L << DATACENTER_ID_BITS); // 31
    private static final long MAX_SEQUENCE = ~(-1L << SEQUENCE_BITS);           // 4095

    private static final long WORKER_ID_SHIFT = SEQUENCE_BITS;                        // 12
    private static final long DATACENTER_ID_SHIFT = SEQUENCE_BITS + WORKER_ID_BITS;   // 17
    private static final long TIMESTAMP_SHIFT = SEQUENCE_BITS + WORKER_ID_BITS + DATACENTER_ID_BITS; // 22

    private final long workerId;
    private final long datacenterId;
    private long sequence = 0L;
    private long lastTimestamp = -1L;

    public SnowflakeIdGenerator(long workerId, long datacenterId) {
        if (workerId > MAX_WORKER_ID || workerId < 0) {
            throw new IllegalArgumentException("workerId 超出范围");
        }
        if (datacenterId > MAX_DATACENTER_ID || datacenterId < 0) {
            throw new IllegalArgumentException("datacenterId 超出范围");
        }
        this.workerId = workerId;
        this.datacenterId = datacenterId;
    }

    public synchronized long nextId() {
        long timestamp = System.currentTimeMillis();

        // ① 时钟回拨：当前时间小于上次时间，说明时钟被拨回去了
        if (timestamp < lastTimestamp) {
            throw new RuntimeException(
                "时钟回拨 " + (lastTimestamp - timestamp) + " 毫秒，拒绝生成 ID");
        }

        // ② 同一毫秒内，序列号自增
        if (timestamp == lastTimestamp) {
            sequence = (sequence + 1) & MAX_SEQUENCE;
            // 序列号用完，自旋等待下一毫秒
            if (sequence == 0) {
                timestamp = waitNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;  // 不同毫秒，序列号归零
        }

        lastTimestamp = timestamp;

        // ③ 拼装 64 位
        return ((timestamp - START_TIMESTAMP) << TIMESTAMP_SHIFT)
             | (datacenterId << DATACENTER_ID_SHIFT)
             | (workerId << WORKER_ID_SHIFT)
             | sequence;
    }

    private long waitNextMillis(long lastTimestamp) {
        long timestamp = System.currentTimeMillis();
        while (timestamp <= lastTimestamp) {
            timestamp = System.currentTimeMillis();
        }
        return timestamp;
    }
}
```

### 雪花算法的致命问题：时钟回拨

如果机器发生 NTP 对时，把系统时钟拨回了 100 毫秒，那么当前 `timestamp` 会小于 `lastTimestamp`，继续生成就会产出**重复 ID**。这就是雪花算法最经典的坑，也是面试能拉开差距的部分。

常见处理策略：

| 策略 | 做法 | 代价 |
|------|------|------|
| 抛异常 | 回拨就拒绝服务 | 短时间不可用，业务要重试 |
| 等时钟追上 | `waitNextMillis` 自旋 | 回拨太久会阻塞线程 |
| 逻辑时钟 | 记录上次时间戳，回拨时继续用上次时间 + 序列号 | 序列号提前耗尽 |
| 备用时间戳 | 百度 UidGenerator：取「当前时间」和「上次时间」的较大值 | 回拨期间 ID 时间戳不准 |

**一句话总结：生产环境必须对时钟回拨兜底，裸奔的雪花算法就是一颗定时炸弹。**

## 方案五：工业级实现（美团 Leaf、百度 UidGenerator）

### 美团 Leaf（双模式）

1. **Leaf-segment**：即前面的号段模式，用**双 Buffer** 优化——一个号段快用完时，后台线程异步预取下一个号段，「取号段」做到零等待。
2. **Leaf-snowflake**：改进版雪花，通过 ZooKeeper 持久节点分配 workerId，并做**时钟回拨校验**（回拨超过阈值就报警 / 摘除节点）。

### 百度 UidGenerator

基于雪花，两个优化：

- **RingBuffer 预生成**：用环形数组提前批量生成 ID 缓存起来，消费时直接取，削峰填谷。
- **容忍时钟回拨**：用逻辑时钟替代系统时钟，回拨时使用备用时间戳，不抛异常。

## 方案对比总表

| 方案 | 唯一性 | 趋势递增 | 性能 | 依赖 | 是否推荐 |
|------|:---:|:---:|:---:|------|:---:|
| UUID | ✅ | ❌ 无序 | 高 | 无 | 仅非主键 |
| DB 号段 | ✅ | ✅ | 中 | MySQL | ✅ 简单可靠 |
| Redis INCR | ✅ | ✅ | 高 | Redis | 需持久化 |
| 雪花算法 | ✅ | ✅ | 极高 | 无 | ✅ 最常用 |
| Leaf / UidGenerator | ✅ | ✅ | 极高 | ZK/MySQL | ✅ 大厂首选 |

## 面试话术（怎么答这道题）

1. **先亮需求**：「分布式 ID 要满足四件事——全局唯一、趋势递增、高性能、不依赖单点（还要防止暴露业务量）。」
2. **讲演进**：UUID 无序不适合主键 → 数据库自增有单点和冲突 → 号段模式解决压力 → 雪花算法彻底去中心化。
3. **重点讲雪花**：64 位组成背出来——41 位时间戳 + 10 位机器 + 12 位序列号，算一下每秒约 409 万。
4. **主动说坑**：时钟回拨怎么处理——抛异常 / 等时钟 / 逻辑时钟，主动说出来是加分项。
5. **收尾拔高**：「实际生产很少裸写雪花，直接用美团 Leaf 或百度 UidGenerator，它们在号段双 Buffer、workerId 分配、时钟回拨兜底上都做了工程化。」

## 总结

| 问题 | 答案 |
|------|------|
| 为什么不用自增？ | 分库分表后多库自增冲突，且暴露业务量 |
| UUID 能用吗？ | 无序、太长，只适合 TraceID 这类非主键场景 |
| 雪花算法 64 位怎么分？ | 1 符号 + 41 时间戳 + 10 机器 + 12 序列号 |
| 每秒能生成多少？ | 每毫秒 4096 个，约 409.6 万/秒 |
| 时钟回拨怎么处理？ | 抛异常 / 等时钟追上 / 逻辑时钟，生产必须兜底 |
| 工业级用啥？ | 美团 Leaf、百度 UidGenerator |

分布式 ID 这道题，本质考的是「从单机到分布式，主键唯一性这个老问题怎么重新解决」。能把雪花算法讲透、再主动抛出时钟回拨这个坑，基本就到 Offer 线了。

---

*明日预告：AI/LLM 方向 —「大模型微调里 LoRA 为什么能省这么多显存？低秩分解的原理是什么？」*
