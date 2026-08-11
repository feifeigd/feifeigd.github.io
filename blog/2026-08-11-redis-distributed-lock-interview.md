---
title: "面试题：Redis 分布式锁怎么实现？Redlock 有什么问题？"
date: 2026-08-11T09:00:00+08:00
draft: false
tags: ["backend", "redis", "distributed", "interview"]
categories: ["Interview"]
description: "面试高频题：从 SETNX 到 Redlock，锁续期、可重入、红锁争议，附完整生产级实现。"
---

> 这是「每日一题」专栏的第二篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。

{/* truncate */}

## 题目

**Redis 分布式锁怎么实现？Redlock 算法有什么问题？你会怎么设计一个生产可用的分布式锁？**

## 先回顾：为什么需要分布式锁

单机环境下，一把 `synchronized` 或 `ReentrantLock` 解决一切。到了分布式环境，多个服务实例竞争同一资源（扣库存、生成唯一 ID），JVM 级别的锁失效了，需要一把所有实例都能看到的锁。

Redis 是天然的分布式协调工具——单线程、原子命令、所有实例共享同一个 Redis。

## 第一代：SETNX + EXPIRE（致命缺陷）

```python
# 加锁：两步，非原子
ok = redis.setnx("lock:order:123", "instance-1")
if ok:
    redis.expire("lock:order:123", 30)  # 30 秒超时
    try:
        do_something()
    finally:
        redis.delete("lock:order:123")
```

**致命问题**：SETNX 和 EXPIRE 不是原子操作。如果在两个命令之间进程崩溃，锁永远不会释放——死锁。

## 第二代：SET ... NX EX（原子化，但仍有坑）

Redis 2.6.12 起，一条命令搞定加锁和设超时：

```python
# 原子操作：SET key value NX EX 30
ok = redis.set("lock:order:123", "instance-1", nx=True, ex=30)
```

### 坑 1：锁被误删

```
时间线：
T0:  实例A 拿到锁，开始处理
T30: 锁过期自动释放（A 还没处理完）
T31: 实例B 拿到锁
T32: 实例A 处理完，执行 delete → 删掉的是 B 的锁！💥
```

**解法**：value 用唯一标识，释放时 Lua 原子比对：

```python
import uuid

lock_id = str(uuid.uuid4())
ok = redis.set("lock:order:123", lock_id, nx=True, ex=30)

# 释放：先比对 value，再删除（Lua 保证原子性）
lua = """
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end
"""
redis.eval(lua, 1, "lock:order:123", lock_id)
```

### 坑 2：锁到期了，业务还没跑完

30 秒超时到了，但下游服务卡了 40 秒。锁自动释放，别的实例进来——数据一致性炸了。

**解法：看门狗（Watchdog）自动续期。**

## 第三代：Redisson 看门狗模式

核心思路：加锁后启动后台线程，定期检查"锁还是不是我的"，是就续期。

```
加锁时：SET lock:order:123 instance-1:thread-5 NX PX 30000

看门狗线程（每 10 秒）：
  检查 → 锁还在？持有者还是我？
    是 → PEXPIRE 续到 30000ms
    否 → 停止续期
```

```python
import threading

class RedisLockWithWatchdog:
    def __init__(self, redis_client, key, ttl_ms=30000):
        self.redis = redis_client
        self.key = key
        self.ttl_ms = ttl_ms
        self.lock_id = str(uuid.uuid4())
        self._running = False

    def acquire(self):
        ok = self.redis.set(
            self.key, self.lock_id,
            nx=True, px=self.ttl_ms
        )
        if ok:
            self._start_watchdog()
        return ok

    def _start_watchdog(self):
        self._running = True
        t = threading.Thread(target=self._renew_loop, daemon=True)
        t.start()

    def _renew_loop(self):
        interval = self.ttl_ms / 3000  # 每 1/3 TTL 续期一次
        while self._running:
            time.sleep(interval)
            lua = """
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("pexpire", KEYS[1], ARGV[2])
            end
            return 0
            """
            self.redis.eval(lua, 1, self.key, self.lock_id, self.ttl_ms)

    def release(self):
        self._running = False
        lua = """
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        end
        return 0
        """
        self.redis.eval(lua, 1, self.key, self.lock_id)
```

## 第四代：Redlock（多实例红锁）

上面的方案都依赖单台 Redis。如果 Redis 挂了或主从切换，锁数据可能丢失。

**Redlock 算法（Redis 作者 antirez 提出）**：用多台独立 Redis 实例，多数派原则（N/2+1 台加锁成功才算成功）。

```
前提：5 台独立 Redis 实例（不是主从，各自独立部署）

加锁流程：
  1. 记录当前时间 t_start
  2. 依次向 5 台 Redis 请求加锁（SET key val NX PX ttl）
     - 每次请求设超时（远小于锁 TTL，如 5ms）
     - 超时或失败 → 跳过，继续下一台
  3. 统计成功次数 n
  4. 计算耗时 elapsed = 当前时间 - t_start
  5. 如果 n >= 3（多数派）且 elapsed 未超过 ttl：
      加锁成功，有效时间 = ttl - elapsed
    否则：
      向所有实例发送释放命令
```

```python
import time

class Redlock:
    def __init__(self, redis_clients):
        self.clients = redis_clients
        self.quorum = len(redis_clients) // 2 + 1

    def lock(self, key, ttl_ms=30000):
        lock_id = str(uuid.uuid4())
        start = time.time() * 1000

        success = 0
        for client in self.clients:
            try:
                ok = client.set(key, lock_id, nx=True, px=ttl_ms)
                if ok:
                    success += 1
            except Exception:
                pass

        elapsed = time.time() * 1000 - start
        valid = ttl_ms - elapsed - 2  # 留 2ms 安全余量

        if success >= self.quorum and valid > 0:
            return lock_id, valid
        else:
            for client in self.clients:
                lua = """
                if redis.call("get", KEYS[1]) == ARGV[1] then
                    return redis.call("del", KEYS[1])
                end
                return 0
                """
                try:
                    client.eval(lua, 1, key, lock_id)
                except Exception:
                    pass
            return None, 0
```

## Redlock 的争议

Redlock 看起来挺美，但分布式系统大神 **Martin Kleppmann** 写了长文炮轰，antirez 也回击了。这是面试展示深度的好切入点。

### 争议 1：依赖时钟

Redlock 用各 Redis 实例的**墙上时钟**计算 TTL 和 elapsed。如果某台 Redis 的时钟发生跳跃（NTP 校时、虚拟机暂停）：

- 时钟跳前 → 锁提前过期，多数派判断失效
- 时钟跳后 → 锁超期持有，破坏互斥性

**Kleppmann**：依赖物理时钟的分布式算法理论上不安全，应该用逻辑时钟（Lamport Clock）。

**antirez**：现代 NTP 不会跳只会微调，工程上可接受。

### 争议 2：GC 暂停 —— 最致命的攻击点

Java 的 Full GC 可能暂停进程 10 秒以上。GC 暂停期间：

- 应用代码被冻结
- 看门狗线程也被冻结
- 锁自动过期，别的实例拿到锁
- GC 结束后，原实例继续执行 → **两个实例同时持有锁**

```
实例A: [===拿到锁===][==GC 暂停 10s==][==继续执行业务==]
实例B:                        [===拿到锁===][==执行业务==]
                             ↑ 互斥性彻底失效！
```

#### 解药：Fencing Token

每次加锁返回一个**单调递增**的 token。写操作时带上 token，存储层拒绝低 token 的写入：

```python
# 服务端：获取锁 + token
lock, token = redlock.lock("resource-x")  # token = 42

# 写数据时带上
storage.write("key", "value", fencing_token=token)

# 存储层
def write(key, value, fencing_token):
    if fencing_token < current_token(key):
        raise StaleWrite("你的锁已过期，拒绝写入")
    current_token[key] = fencing_token
    do_write(key, value)
```

### 争议 3：Redlock 到底该不该用？

| 场景 | Redlock 够用吗？ |
|------|:---:|
| 效率优化（避免重复计算、限流） | ✅ 够用 |
| 正确性要求（如金融转账） | ❌ 不够，需 Fencing Token 或共识算法 |
| 需要严格互斥 | 考虑 Zookeeper / etcd（CP 系统） |

## 实用选型指南

```
你需要分布式锁？
│
├─ 只是避免重复计算、限流
│   → 单实例 Redis + 看门狗，足够
│
├─ 需要较高可用性，数据可容忍偶尔冲突
│   → Redlock（3-5 实例）
│
└─ 强一致性要求（金融、库存扣减）
    → Zookeeper / etcd / 数据库乐观锁
    → 加 Fencing Token
    → 或者直接用：SELECT ... FOR UPDATE
```

## 面试加分项：手写生产级分布式锁

```python
import uuid
import time
import socket
import threading

class ProductionRedisLock:
    """
    生产级 Redis 分布式锁
    - SET NX PX 原子加锁
    - Lua 脚本原子释放（只释放自己的锁）
    - 看门狗自动续期
    - 支持可重入（同实例/同线程重复加锁只计数）
    """

    def __init__(self, redis_client, key, ttl_ms=30000):
        self.redis = redis_client
        self.key = f"lock:{key}"
        self.ttl_ms = ttl_ms
        self.lock_id = (
            f"{socket.gethostname()}:{threading.get_ident()}:{uuid.uuid4()}"
        )
        self._watchdog_stop = threading.Event()
        self._lock_count = 0

    def acquire(self, timeout_ms=0):
        """阻塞获取锁。timeout_ms=0 为非阻塞"""
        deadline = time.monotonic() + timeout_ms / 1000
        while True:
            # 可重入：同一实例已持锁，只续期 + 计数
            current = self.redis.get(self.key)
            if current and current.startswith(
                self.lock_id.split(":")[0]
            ):
                lua = """
                if redis.call("get", KEYS[1]) == ARGV[1] then
                    redis.call("pexpire", KEYS[1], ARGV[2])
                    return 1
                end
                return 0
                """
                if self.redis.eval(
                    lua, 1, self.key, current, self.ttl_ms
                ):
                    self._lock_count += 1
                    self._start_watchdog()
                    return True

            # 正常加锁
            ok = self.redis.set(
                self.key, self.lock_id, nx=True, px=self.ttl_ms
            )
            if ok:
                self._lock_count = 1
                self._start_watchdog()
                return True

            if timeout_ms and time.monotonic() < deadline:
                time.sleep(0.01)
            else:
                return False

    def release(self):
        if self._lock_count <= 0:
            return
        self._lock_count -= 1
        if self._lock_count > 0:
            return  # 可重入锁还没完全释放

        self._watchdog_stop.set()
        lua = """
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        end
        return 0
        """
        self.redis.eval(lua, 1, self.key, self.lock_id)

    def _start_watchdog(self):
        if self._watchdog_stop.is_set():
            self._watchdog_stop.clear()
            t = threading.Thread(
                target=self._watchdog_loop, daemon=True
            )
            t.start()

    def _watchdog_loop(self):
        interval = self.ttl_ms / 3000
        while not self._watchdog_stop.wait(interval):
            lua = """
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("pexpire", KEYS[1], ARGV[2])
            end
            return 0
            """
            self.redis.eval(
                lua, 1, self.key, self.lock_id, self.ttl_ms
            )

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *args):
        self.release()
```

## 总结

| 方案 | 核心思路 | 可靠性 | 适用场景 |
|------|---------|:---:|------|
| SETNX + EXPIRE | 非原子，已淘汰 | ❌ | 不要用 |
| SET NX PX | 原子加锁 | ⚠️ | 简单场景 |
| + Lua 释放 | 解决误删 | ✅ | 单实例够用 |
| + Watchdog | 自动续期 | ✅ | 长任务场景 |
| Redlock | 多实例多数派 | ✅✅ | 要求高可用 |
| + Fencing Token | 防止 GC 暂停问题 | ✅✅✅ | 金融级正确性 |

一道题把分布式锁从青铜写到王者。

---

*明日预告：系统设计题 —「设计一个短链接系统」*
