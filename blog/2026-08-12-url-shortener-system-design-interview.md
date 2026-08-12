---
title: "面试题：设计一个短链接系统（URL Shortener），从百亿 QPS 到数据一致性一次讲清"
date: 2026-08-12T09:00:00+08:00
draft: false
tags: ["system-design", "architecture", "interview"]
categories: ["Interview"]
description: "系统设计面试高频题：短链接系统怎么做？哈希碰撞怎么办？Base62 编码原理？分布式 ID 怎么选？从需求到架构一次讲清。"
---

> 这是「每日一题」专栏的第三篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。

{/* truncate */}

## 题目

**设计一个 URL 短链接服务（类似 TinyURL / Bitly），支持每天 10 亿次写入、100 亿次读取，短链永久有效。**

## 第一步：需求澄清

面试官说完题目，别急着画架构图。先确认边界条件——这本身就是考察点。

| 维度 | 需要确认 |
|------|----------|
| **写入量** | 每天多少新短链？峰值 QPS？ |
| **读取量** | 短链跳转 QPS？读写比？ |
| **短链长度** | 几个字符？允许什么字符集？ |
| **有效期** | 永久还是过期？支持自定义过期？ |
| **API 设计** | 只有 `create` 和 `redirect`？需要统计吗？ |
| **一致性** | 强一致还是最终一致？用户刚创建立刻能用？ |

假设面试官给的数字：**每天写入 1 亿，读取 100 亿，短链 7 位字符，永久有效。**

## 第二步：估算容量

先算清楚数据量有多大，才知道架构怎么做。

```
每天写入 100M 条
每年写入 100M × 365 ≈ 365 亿条

7 位字符，Base62（0-9 + a-z + A-Z = 62 个字符）
62⁷ ≈ 3.5 万亿种组合
存储 365 亿条绰绰有余（仅用 约 1%）

单条记录：短链(7B) + 原URL(100B avg) + 元数据 ≈ 200B
365 亿条 × 200B ≈ 7.3TB/年 存储

读取 QPS：100 亿/天 ÷ 86400 ≈ 115K QPS（均值）
峰值 ≈ 115K × 3 ≈ 350K QPS
写入 QPS：1 亿/天 ÷ 86400 ≈ 1.2K QPS
```

核心矛盾马上出来了：**读多写少，读是写的 100 倍——缓存是必选项。**

## 第三步：短链生成算法（核心）

这是面试最核心的部分：**怎么生成短链？**

### 方案一：Hash 函数 + Base62

```
原 URL → MD5/SHA256 → 取前 7 字节 → Base62 编码 → 短链
```

```python
import hashlib

BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

def base62_encode(num: int) -> str:
    """整数转 Base62"""
    if num == 0:
        return BASE62[0]
    result = []
    while num > 0:
        result.append(BASE62[num % 62])
        num //= 62
    return ''.join(reversed(result))

def hash_to_short(url: str, length: int = 7) -> str:
    """Hash 法生成短链"""
    h = hashlib.sha256(url.encode()).digest()
    # 取前 6 字节转整数再 Base62 编码
    num = int.from_bytes(h[:6], 'big')
    return base62_encode(num)[:length]

print(hash_to_short("https://example.com/very-long-url"))
# 输出类似: 3dK2mN9
```

**问题：哈希碰撞。** 两个不同 URL 可能生成相同短链。概率有多大？

SHA256 取 6 字节 = 48 bit → 约 2.8 × 10¹⁴ 种。生日悖论：存 1000 万条就有约 0.018% 碰撞概率。生产环境不能赌。

**解决方案：查 DB 检测碰撞，碰撞了就重试（加盐/追加时间戳）**

```python
def create_short_url(original_url: str) -> str:
    attempt = 0
    while True:
        attempt += 1
        # 碰撞后加递增计数器
        short = hash_to_short(original_url + str(attempt))
        if not db.exists(short):  # 查数据库
            db.insert(short, original_url)
            return short
```

缺点：每次都要查 DB 确认唯一性，写入时多一次 DB 查询。

### 方案二：分布式 ID + Base62（更优）

不依赖 hash，用**分布式唯一 ID** 直接编码。

```python
# Snowflake 风格生成唯一 ID，再 Base62 编码
def generate_short_url(original_url: str) -> str:
    unique_id = snowflake.next_id()  # 全局唯一递增 ID
    short = base62_encode(unique_id)
    # Snowflake 64-bit → Base62 约 11 位，截取 7 位
    return short[:7]

print(generate_short_url("https://example.com"))
# 输出: aB3xK9L
```

| 方案 | 优点 | 缺点 |
|------|------|------|
| **Hash + Base62** | 同一 URL 生成相同短链（幂等） | 碰撞要处理，需查 DB |
| **分布式 ID + Base62** | 无碰撞，性能高 | 同一 URL 每次生成不同短链（非幂等） |

**推荐：Hash + 查 DB 碰撞重试**。因为幂等是产品需求——同一个 URL 用户短两次应该返回同一个短链（避免浪费）。

### 进阶：预生成短链池

写入 QPS 不高时够用，但高并发下碰撞重试会成为瓶颈。解决方案：

```python
# 后台线程持续生成未使用的短链，放入 Redis 队列
# 写入时直接从池里取，零碰撞、零等待

def prepare_pool():
    while True:
        short = generate_random_short()
        if not db.exists(short):
            redis.lpush("short_url_pool", short)

# 写入时
short = redis.rpop("short_url_pool")  # O(1)，无需碰撞检测
```

## 第四步：数据库设计

读多写少 → **MySQL 持久化 + Redis 缓存**。

### MySQL 表结构

```sql
CREATE TABLE short_urls (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    short_code  VARCHAR(10)  NOT NULL UNIQUE,
    original_url TEXT        NOT NULL,
    created_at  TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
    expire_at   TIMESTAMP   NULL,
    INDEX idx_short_code (short_code),
    -- 对长 URL 建索引做幂等查询（用前缀哈希减少索引大小）
    INDEX idx_url_hash (CRC32(original_url))
);
```

### 分库分表

百亿级数据单表扛不住。按 `short_code` 的前 2 位做 hash 分片：

```
short_code 前 2 位 → hash % 64 → 决定分片

/home/feifeigd/  → db_00
/aBcdefg/ → db_15
/3xK9LmZ/ → db_42

共 62² = 3844 个可能前缀，映射到 64 个分片足够。
```

### Redis 缓存结构

```
Key:   short:<short_code>
Value: original_url
TTL:   7 天（热点短链常驻缓存）

未命中时查 DB → 回填缓存 → 返回
```

## 第五步：API 设计

### 创建短链

```
POST /api/v1/shorten
Content-Type: application/json

{
  "url": "https://example.com/very-long-url",
  "custom_code": "myalias",    // 可选：自定义短链
  "expire_days": 365           // 可选：过期天数
}

Response 201:
{
  "short_url": "https://s.com/aB3xK9L",
  "original_url": "https://example.com/very-long-url",
  "expire_at": "2027-08-12T09:00:00Z"
}
```

### 重定向

```
GET /aB3xK9L

Response 302 Found
Location: https://example.com/very-long-url
```

**注意：用 302（临时重定向）而不是 301（永久）。** 因为 301 会被浏览器永久缓存，以后短链跳转统计就不准了。只有确定永不更改的场景才用 301。

```python
# 301 vs 302 的选择
# 301: 浏览器直接缓存目标 URL，后续不再请求短链服务
# 302: 每次都请求短链服务，可以统计数据
# 结论：短链跳转用 302
```

## 第六步：架构总览

```
                    ┌─────────────┐
                    │   CDN/DNS   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  Load       │
                    │  Balancer   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌───▼───┐ ┌─────▼─────┐
        │  API Node  │ │  API  │ │  API Node │
        │  (create)  │ │  Node │ │ (redirect)│
        └─────┬─────┘ └───┬───┘ └─────┬─────┘
              │            │            │
           ┌──▼──┐     ┌───▼───┐    ┌──▼──┐
           │Redis│◄────┤Redis  │◄───┤Redis│
           │Cache│     │Cache  │    │Cache│
           └─────┘     └───────┘    └─────┘
              │            │            │
              └────────────┼────────────┘
                           │
                    ┌──────▼──────┐
                    │   MySQL     │
                    │  (Sharded)  │
                    └─────────────┘
```

## 第七步：安全与防滥用

面试官追问"怎么防止恶意刷短链"：

1. **速率限制**：同一 IP 每分钟最多创建 10 条（令牌桶算法）
2. **恶意 URL 检测**：接入 Google Safe Browsing API，拒绝钓鱼/恶意链接
3. **短链预览**：返回重定向前显示目标域名（Bitly 的做法：`s.com/aB3xK9L+` 显示预览）
4. **黑名单域名**：维护恶意域名黑名单，拒绝为这些域名生成短链

## 面试追问合集

| 追问 | 关键点 |
|------|--------|
| 怎么保证缓存与 DB 一致？ | Cache-Aside 模式：读未命中回填，写时先写 DB 再删缓存 |
| 用户自定义短链怎么办？ | 校验唯一性、长度限制、敏感词过滤 |
| 短链过期了怎么处理？ | 定时任务清理 + 访问时惰性检查 `expire_at` |
| 怎么统计点击量？ | 异步写入 ClickHouse，不阻塞主链路 |
| 跨机房多活怎么做？ | 短链生成带机房标识前缀，避免跨机房分配冲突 |

## 总结

短链接系统看似简单，实际考察：

1. **哈希碰撞处理**：生产环境不能赌概率，必须有碰撞检测 + 重试
2. **Base62 编码**：理解进制转换本质
3. **分库分表**：百亿级数据的分片策略
4. **缓存策略**：读多写少场景下的 Cache-Aside 模式
5. **302 vs 301**：细节决定统计准确性

面试场上，别一口气背架构图。先问需求，再算容量，然后选算法，最后画图——这个节奏本身就是加分项。

---

> **下一篇预告：AI/LLM 方向** —— Transformer 之外还有哪些值得关注的注意力机制变体？Linear Attention 和 FlashAttention 到底解决了什么问题？明天 9 点见。
