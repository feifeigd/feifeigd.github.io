---
title: "面试题：分布式锁除了 Redis 还能怎么做？ZooKeeper 的临时顺序节点凭什么更安全、一次 Full GC 怎么让所有基于超时的锁同时失效、etcd 的 lease 与 revision 为什么天然就是 fencing token、锁校验为什么必须下沉到存储层、以及大多数场景你根本不该用锁？"
date: 2026-11-18T09:00:00+08:00
draft: false
tags: ["backend", "distributed", "zookeeper", "etcd", "interview"]
categories: ["Interview"]
description: "分布式锁的第二层：第一层是「怎么加锁」，这一层是「加的锁到底保证了什么」。先把失败模型摆出来——进程 STW 12 秒、网络分区、时钟阶跃，然后用一条时间线证明：只要锁带超时，就一定能出现「两个客户端同时认为自己持有锁」，Redis 避免不了，ZooKeeper 和 etcd 也避免不了，区别只是概率和暴露面。接着逐层拆：ZooKeeper 的临时顺序节点为什么用 quorum 而不是时间做仲裁、watch 为什么要盯前一个兄弟节点而不是父节点（羊群效应）、session 超时与 GC 停顿的交互细节、etcd 的 lease keepAlive 与 compare-and-create-revision 抢锁、全局单调 revision 为什么天生就是 fencing token、etcd 的线性一致读怎么避免读到过期数据。然后是真正解决问题的部分：fencing token 必须在存储层用条件写校验，给出 SQL 与 S3 条件写的落地写法，并解释为什么「先查 token 再写」是错的。最后给三方案的吞吐对比表、故障降级清单，以及一节反直觉的结论：幂等状态机、乐观锁 CAS、单飞合并、按 key 串行化这四把替代方案，能干掉八成真实业务里的分布式锁。"
---

> 这是「每日一题」专栏的第二十八篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇是 [多租户 LLM 网关](/blog/2026/11/17/multi-tenant-llm-gateway-interview)，今天按轮换回到后端/分布式方向，兑现上一篇的预告：**分布式锁**。
>
> 但这里有个冲突要先说明。8 月 11 日已经写过一版 [Redis 分布式锁与 Redlock 争议](/blog/2026/08/11/redis-distributed-lock-interview)，把 SETNX 三代实现、看门狗续期、Redlock 的时钟假设都讲过了。再写一遍是重复劳动，所以今天换个角度：**不讲「怎么加锁」，讲「加的锁到底保证了什么」**。Redis 那部分只做一句回顾，重心放在三个 8 月没讲透的地方——ZooKeeper 的临时顺序节点、etcd 的 lease 与 revision、以及唯一真正能解决问题的 fencing token。

{/* truncate */}

## 一、题目与考点拆解

面试官的原话大概是：

> 我们有个定时结算任务，多个实例同时跑会重复扣款。现在用 Redis 的 `SET key val NX PX 30000` 加锁。你告诉我：这把锁在什么情况下会失效？如果换 ZooKeeper 或者 etcd 会不会好一些？为什么？另外，能不能证明「加了锁就不会有两个实例同时进临界区」？

这道题的陷阱在于：**第一问九成的人能答，第二问开始大面积翻车，第三问几乎没人能答对**。因为大部分人脑子里只有一个心智模型——「锁 = 一个大家都能看到的标记，谁抢到谁进」——而真实模型是：

> 锁 = **一个带超时的租约** + **一个乐观假设：持有者在租约内不会长时间失去执行能力**。

这个乐观假设在 GC 停顿、虚拟机热迁移、swap 抖动、网络分区、容器被 cgroup 限流这些场景下全部不成立。而一旦不成立，**任何**基于「超时过期」的锁都会出现两个客户端同时认为自己是持有者。这不是 Redis 的锅，ZooKeeper 和 etcd 一样有，区别只是窗口大小和暴露条件。

所以这道题真正考五层：

1. **失败模型**：先定义清楚要防什么——进程暂停、网络分区、时钟跳变，这三件事的破坏力各不相同。
2. **仲裁机制**：谁能判断「持有者已经死了」？Redis 用超时，ZooKeeper 用 quorum + session，etcd 用 lease + revision，三种判断的置信度完全不一样。
3. **单调性**：锁本身不提供顺序，但**如果抢锁过程能产出一个全局单调递增的序号**，这个序号就能在存储层挡住旧持锁者的写。这是 fencing token 的全部秘密。
4. **原子性边界**：校验和写入必须在同一个原子操作里，否则等于没校验。
5. **必要性**：这道题最狠的追问是「你真的需要锁吗」。绝大多数「用锁解决问题」的场景，正确答案是幂等 + 状态机。

下面按这个顺序走。

## 二、先把锁的语义定义清楚

面试里说「分布式锁」四个字，其实混着三件不同的事，必须分开：

| 性质 | 含义 | 违反了会怎样 | 能严格做到吗 |
| --- | --- | --- | --- |
| 互斥（safety） | 任意时刻最多一个持有者 | 双写、重复扣款、数据错乱 | 理论可以，工程上只能「尽量」 |
| 活性（liveness） | 持有者崩了锁最终能释放 | 任务永久卡死 | 可以（靠超时） |
| 公平性 | 先到先得，不被饿死 | 某实例长期抢不到 | 可以（ZK 顺序节点 / etcd revision） |

关键在于：**互斥和活性是直接冲突的**。你想让崩掉的持有者尽快释放（活性），就必须设超时；一设超时，就必然存在「持有者没崩只是卡住了、但锁已经过期」的窗口（破坏互斥）。分布式系统里没有免费午餐，这个矛盾只能用 fencing 这类**在临界区外**的机制绕过去。

顺带把三个失败模型点清楚，后面反复用：

| 失败模型 | 典型触发 | 客户端自知吗 | 破坏力 |
| --- | --- | --- | --- |
| 进程暂停（STW） | JVM Full GC、容器被 throttle、VM 快照、swap | 不知道，恢复后接着跑 | 最致命：客户端「以为」还持锁 |
| 网络分区 | 交换机抖动、跨 AZ 链路断、安全组误改 | 延迟察觉（心跳超时后才知道） | 高：可能脑裂出两个「多数派」假象 |
| 时钟跳变 | NTP step、运维改时间、虚拟机时钟漂移 | 部分可察觉（monotonic 不变） | 中：影响超时长度，不影响单调性判断 |

记住第一条：**STW 是唯一一个「客户端自己完全无法察觉」的失败**，所有超时型锁的安全性上限都由它决定。

## 三、一条时间线：GC 停顿怎么击穿带超时的锁

不用抽象论证，直接算。假设：

```
锁 TTL = 30s
进程 A 在 t=1s 抢到锁
A 在 t=5s 进入 Full GC，STW 12s（t=5 → t=17）
A 的临界区业务总共需要 30s，从 t=1 跑到 t=31
```

时间线：

| 时刻 | 事件 | Redis 上的锁状态 |
| --- | --- | --- |
| t=1 | A 抢到锁 | A 持有，TTL=30 |
| t=5 | A 进入 STW | A 持有（但 A 不知道自己已经「暂停」了） |
| t=17 | A 恢复，继续跑临界区 | A 仍认为自己持有 |
| t=31 | 锁自然过期 | **无主** |
| t=32 | 进程 B 抢到锁，进入临界区 | B 持有 |
| t=33 | A 和 B 同时在临界区写数据库 | 互斥已破 |

注意 t=31 那一行：**A 的业务是「跑到 t=31 才结束」，锁是「t=31 到期」，这两个 30 秒不是同一个 30 秒**。业务耗时从抢锁那一刻算，锁 TTL 也从那一刻算，只要业务的 p99 超过 TTL，或者中途发生一次不可预测的停顿，重叠就是必然的。

再加一层：A 在 t=33 跑完，执行释放锁。如果释放是裸 `DEL`，删掉的是 **B 的锁**；如果释放是「先比对 value 再删」，比对失败就不删——但**双写已经发生了**，释放逻辑再严谨也救不回来。

### 3.1 为什么「看门狗续期」不能根治

Redisson 的看门狗每 10 秒（TTL/3）续一次期，看起来把 TTL 变成「只要进程活着就永不过期」。问题在于：

- 看门狗是**同一进程里的另一个线程**。Full GC 是**整个进程**的 STW，看门狗线程一样停。12 秒的停顿照样错过续期窗口。
- 续期请求发出去了，但网络返回超时，客户端不知道服务端到底续没续上。重试可能把 TTL 推得更长，也可能在锁已过期被别人抢走后，**帮别人续期**。
- 续期线程自己也会被容器 CPU throttling 饿死（`cpu.cfs_quota` 打满时，10 秒的任务可能延迟到 40 秒）。

结论：看门狗降低的是「业务耗时长于 TTL」这一类**可预测**的失败，对**不可预测的停顿**无效。

### 3.2 为什么换 ZooKeeper 也不解决

很多人有直觉：ZK 的临时节点是靠 session 存活，不是靠 TTL，所以更安全。这只说对了一半。

ZK 的 session 靠心跳维持，`sessionTimeout` 通常 10 到 40 秒（受 `tickTime` 约束，最小 2 个 tick）。客户端 STW 12 秒，如果 sessionTimeout 设成 10 秒：

- 服务端在 10 秒内没收到心跳 → 判定 session 过期 → **删除临时节点**（锁被提前释放）
- A 在 t=17 恢复，**手上还拿着「我已经创建了节点」的对象**，继续跑临界区
- B 在 t=11 就拿到了锁，t=12 进临界区

所以 ZK 甚至比 Redis 更「积极」地丢锁：它会把「还在跑但暂时失联」的持有者当成死人。这不是 ZK 的缺陷，是它诚实地执行了「心跳即存活」这个假设。

**真正被 ZK 解决的是另一件事：脑裂。** Redis 主从异步复制，主节点在失联前刚被 A 加了锁，切到从节点后这把锁**根本不存在**（复制还没到），B 立刻就能加锁成功——这是 Redis 锁最经典的漏洞。ZK 和 etcd 用 quorum 写入，少数派分区**无法完成任何写**，也就无法产生「两把锁」。

把这两件事分开，是这一节最重要的区分：

| 问题 | Redis 主从 | ZooKeeper / etcd |
| --- | --- | --- |
| 主从切换后锁凭空消失 | 会（异步复制） | 不会（quorum 提交） |
| 持有者 STW 后仍以为自己持锁 | 会 | 会（甚至更早被判定过期） |

一句话：**quorum 解决「锁的存在性」，解决不了「持有者的自我认知」**。后者只有 fencing 能解。

## 四、ZooKeeper：临时顺序节点凭什么好

ZK 锁的标准实现是 Curator 的 `InterProcessMutex`，底层就三件事：

1. 在 `/locks/xxx` 下创建**临时顺序节点**：`create -e -s /locks/order-settle/lock-` → 得到 `lock-0000000007`
2. `getChildren` 看自己是不是**序号最小**的。是 → 拿到锁
3. 不是 → **watch 比自己序号小的那一个节点**（不是父节点！），等它被删

```java
// Curator 的用法，生产里别自己手写
CuratorFramework client = CuratorFrameworkFactory.newClient(
        "zk1:2181,zk2:2181,zk3:2181",
        new ExponentialBackoffRetry(50, 3));
client.start();

InterProcessMutex lock = new InterProcessMutex(client, "/locks/order-settle");
if (lock.acquire(3, TimeUnit.SECONDS)) {
    try {
        doSettle();
    } finally {
        lock.release();
    }
}
```

### 4.1 为什么 watch 前一个兄弟，不是父节点

如果所有等待者都 watch 父节点 `/locks/order-settle`，那么每次有人释放（删一个子节点），父节点的 `getChildren` watch 会**同时唤醒所有等待者**，几十上百个客户端一起冲到 ZK 上 `getChildren`——这就是**羊群效应（herd effect）**，ZK 的读虽然快，也扛不住这种脉冲。

watch 前一个兄弟节点则是**链式唤醒**：只有排名第二的人被唤醒，它拿到锁之后删自己的节点，再唤醒下一个。一放一醒，严格串行，ZK 的写 QPS 一下就省下来了。

顺带说一个 ZK 的坑：**watch 是一次性的**，触发后必须重新注册。而且「判断是否最小」和「注册 watch」这两步之间如果发生节点变化，可能漏掉通知（check-then-watch 竞态）。Curator 内部用 `getChildren` 加判空重试来兜这个窗口，自己手写极容易漏。

### 4.2 顺序节点的三个额外好处

- **公平性免费**：序号即排队顺序，天然先到先得，不会饿死。
- **可观测**：`getChildren` 一下就知道有多少人在排队，队列长度就是等待深度，直接做监控指标。
- **可撤销**：想强制踢掉某个持有者，删它的节点即可（配合业务侧告警）。

### 4.3 ZK 的真实代价

| 维度 | 数值 | 说明 |
| --- | --- | --- |
| 写延迟 | 1 到 5 ms（同机房 3 节点） | 每次抢锁 = 一次 quorum 写 + fsync |
| 写吞吐 | 几百到几千 TPS | 单 leader 顺序处理写，天花板在 leader 的磁盘 |
| sessionTimeout 下限 | 约 2 个 tickTime，常见 10 到 40 秒 | 决定了「崩溃后多久能自愈」 |
| 运维成本 | 高 | 3 或 5 节点集群、快照与事务日志分离、zab 选主、snapshot 膨胀要清理 |

注意第二行：**ZK 的写吞吐受限于单 leader**。拿它当高频锁用（比如每秒几万次抢锁）会直接把集群打挂。ZK 适合的是**低频、强一致、要公平**的场景——选主、配置变更、任务分片分配。

## 五、etcd：lease + revision，顺带把 fencing 送给你

etcd 是 Raft，写路径和 ZK 类似（quorum 提交），但 API 模型更适合做锁，因为它有两个 ZK 没有的东西：**可撤销的 lease** 和**全局单调递增的 revision**。

### 5.1 抢锁的三个原子动作

```bash
# 1. 建一个 15 秒的租约，客户端要持续 keepAlive 续约
LEASE=$(etcdctl lease grant 15 | awk '{print $2}')

# 2. 事务：key 不存在才创建，绑定租约（这就是「抢」）
etcdctl txn <<'EOF'
mod("lock/settle", "Version(key)", "=", "0")
put lock/settle "instance-A" --lease=$LEASE

mod("lock/settle", "Version(key)", ">", "0")
get lock/settle
EOF
```

第二步的关键是**「不存在才创建」放在一个 Raft 事务里**，不是 `get` 完再 `put`。抢到的人拿到的是这个 key 的 `create_revision`；没抢到的拿到当前 owner，然后 `watch` 这个 key 的删除事件（等它被释放再重试）。

etcd 官方的 `concurrency.Mutex` 把这套包好了：

```go
session, _ := concurrency.NewSession(cli, concurrency.WithTTL(15))
defer session.Close()

m := concurrency.NewMutex(session, "/locks/order-settle")
if err := m.Lock(ctx); err != nil {   // 阻塞等待，内部处理排队与 watch
    return err
}
defer m.Unlock(ctx)
doSettle()
```

`concurrency.NewSession` 里跑着一个 keepAlive goroutine，每 TTL/3 续一次；进程崩了 keepAlive 断，lease 15 秒后过期，key 自动删除——和 ZK 的临时节点同一个思路，但 **lease 可以被主动 `revoke`**，这比「等超时」多了一个立刻释放的手段（比如优雅下线时主动 revoke，不用让下一个等 15 秒）。

### 5.2 为什么 revision 天生就是 fencing token

etcd 的 `revision` 是**整个集群全局单调递增**的：每一次写都让全局 revision 加一。也就是说，抢锁成功的那个事务，天然带一个「比之前所有抢锁都大」的序号：

```
t1: A 抢锁成功 → create_revision = 1001
t2: 锁过期，B 抢锁成功 → create_revision = 1042
```

把 1042 当 token 写进下游存储，任何「token 小于 1042」的写请求都该被拒绝。A 恢复后带着 1001 去写，被拒——**双写被挡住**。这是 Redis 的锁给不了的东西：Redis 的 `INCR` 序号和锁不是一回事，需要你自己额外维护。

同理，ZK 的 `zxid`（事务 id）也是全局单调的，但 Curator 的 `InterProcessMutex` 不把它暴露出来（Curator 5 有 `getLockNode` 之类的办法拿到节点序号，能凑合用 `Stat.getCzxid()`），工程上比 etcd 别扭。**这就是 etcd 在「锁 + fencing」这个组合上比 ZK 更顺手的原因**。

### 5.3 线性一致读：别读到过期数据

etcd 默认读有两种：

- **串行读**（`WithSerializable()`）：可能由任意节点本地返回，读到旧值。快，但抢锁时**绝对不能用**——可能看到「key 不存在」，但其实已经有了。
- **线性一致读**（默认）：走 ReadIndex，leader 确认自己还是 leader、且已应用所有已提交日志后才返回。

抢锁的 `txn` 天然是线性一致的（写请求都走 Raft），但如果你先 `get` 判断再决定要不要 `txn`，那个 `get` 就必须是线性一致读。这是 etcd 锁实现里最常见的错误。

## 六、fencing token：唯一真正解决问题的东西

前面所有的坑，收敛成一句：**锁只能「降低并发概率」，不能「保证互斥」**。要保证正确性，必须让**被保护的那个资源自己拒绝旧持有者**。

### 6.1 错误做法：先查再写

```sql
-- 错：查和写不是原子的
SELECT last_token FROM account_fence WHERE id = 42;  -- 拿到 1001
-- 应用层比较：1001 < 1042 → 应该拒绝，退出
UPDATE account SET balance = balance - 100 WHERE id = 42;
```

问题：如果应用层比较逻辑写错了、或者部署了旧版本代码、或者这里其实是另一个服务在读（A 走的路径没有校验），照样写进去。**校验放在客户端等于没校验**。

### 6.2 正确做法：条件写在存储层

```sql
-- 对：单调 token 作为条件，永远只接受更大的
UPDATE account
   SET balance = balance - 100,
       fence_token = 1042
 WHERE id = 42
   AND fence_token < 1042;

-- 受影响行数为 0 → 说明有更新的持有者已经写过，本次拒绝并告警
```

一句话记住：**`WHERE fence_token < :token` 是分布式锁唯一能落地的安全语义**。行数 0 不是错误，是「你来晚了」。

对象存储也一样（S3 从 2024 年起支持条件写）：

```bash
# 只有对象不存在时才写成功，用来做「单写者」语义
aws s3api put-object --bucket meta --key snapshot.json \
  --body snapshot.json --if-none-match '*'
```

文件系统（HDFS、本地 NFS）用 `O_EXCL` 创建 + `rename` 原子替换；ZooKeeper 用 `setData` 带 `version` 做 CAS。所有这些都是同一件事：**把「谁是当前持有者」的判断权，从客户端挪到被写的那个系统里**。

### 6.3 fencing 的额外收益：把「锁的等待」变成「失败重试」

没有 fencing 时，锁失效的后果是**静默的数据损坏**（重复扣款、重复发货、金额对不上），排查成本极高。有 fencing 时，后果变成**一个明确失败的写请求**，日志里一条 `fence rejected: token 1001, current 1042`，直接进告警。这是从「不可见」到「可见」的质变，也是面试里最能体现工程成熟度的一点。

## 七、三方案横向对比

| 维度 | Redis（单实例 / 哨兵） | ZooKeeper | etcd |
| --- | --- | --- | --- |
| 一致性基础 | 主从异步复制 | Raft 之外的 zab，quorum | Raft quorum |
| 主从切换丢锁 | 会 | 不会 | 不会 |
| 抢锁延迟（同机房） | 0.2 到 1 ms | 1 到 5 ms | 1 到 3 ms（单次 Raft 提交） |
| 抢锁吞吐 | 单实例 10 万+ QPS | 几百到几千 TPS | 几千到一万 TPS（batch 后更高） |
| 是否天然提供单调 token | 否（要自己 INCR） | 勉强（zxid / 节点序号） | 是（revision） |
| 公平性 | 无（抢不到就轮询重试） | 有（顺序节点） | 有（revision 排序） |
| 崩溃后自动释放 | TTL 到期 | session 过期 | lease 到期或被 revoke |
| 主动踢人 | DEL（危险） | 删节点 | revoke lease |
| 典型用途 | 高频短临界区、防重复提交 | 选主、配置、分片分配 | 选主、K8s 全家的元数据、长任务租约 |

选型的一句话版本：

- **临界区短（毫秒级）、容忍极小概率双写、下游有幂等兜底** → Redis，够用且便宜。
- **要公平、要排队信息、已有 ZK 集群** → ZK 顺序节点。
- **要 fencing、要可撤销租约、本来就在 K8s 生态里** → etcd。
- **一项都不满足，且你其实只是想「不让两个实例同时干」** → 往下看第八节，八成有别的东西更合适。

## 八、反直觉的部分：大多数场景不该用锁

面试里能说出「这里其实不需要锁」的人，比能背出 Redlock 争议的人少得多，但前者得分更高。真实业务里的锁，绝大多数可以被下面四样东西替代：

### 8.1 幂等 + 状态机（最常用）

「多实例重复结算」这个需求，用锁是「防重复进入」，用状态机是「让重复进入无害」：

```sql
-- 抢占式状态迁移，受影响行数为 1 才算抢到任务
UPDATE settle_task
   SET status = 'RUNNING', owner = 'instance-A', started_at = NOW()
 WHERE id = 10086
   AND status = 'PENDING';

-- 行数为 0：别人已经在跑，直接返回，不需要任何锁
```

这个写法的安全性不依赖任何超时：**数据库行锁保证了 CAS 的原子性**，跑完之后 `status` 变成 `SETTLED`，再来的请求在第 3 行就被挡住。崩了怎么办？加一个 `running_at` 超时的兜底扫描，把卡在 `RUNNING` 超过 10 分钟的任务重置成 `PENDING`——这时你甚至不需要「谁持有锁」，只需要「这条记录的状态」。

### 8.2 乐观锁 CAS

```sql
UPDATE inventory
   SET stock = stock - 1, version = version + 1
 WHERE sku = 'A100' AND version = 37;
```

和 6.2 的 fencing 是同一个形状。区别只是 `version` 由业务自己维护，`fence_token` 由锁服务发放。**能接受重试的场景，乐观锁永远优于悲观锁**——没有锁服务就没有锁失效。

### 8.3 单飞（singleflight）合并

同一个 key 的缓存击穿，用锁是「只让一个线程回源，其他等待」。用 singleflight 是「把并发请求合并成一次调用，结果广播给所有人」：

```go
import "golang.org/x/sync/singleflight"

var g singleflight.Group

func GetUser(id string) (*User, error) {
    v, err, _ := g.Do("user:"+id, func() (interface{}, error) {
        return loadFromDB(id)   // 同一时刻只会有一个 goroutine 真正执行
    })
    if err != nil {
        return nil, err
    }
    return v.(*User), nil
}
```

注意 `singleflight` 只在**单进程内**去重。多实例场景还是要靠 8.1 的状态机，或者干脆接受「每个实例各回源一次」——比引入一把分布式锁便宜得多。

### 8.4 按 key 串行化（用队列代替锁）

如果需求本质是「同一个订单的请求必须按顺序处理」，那正确答案是**路由**，不是锁：

```
partition = hash(order_id) % N   // 同一个订单永远落到同一个 worker
```

同一分区单线程消费 → 天生串行，没有锁、没有超时、没有 fencing。Kafka 分区、RocketMQ 顺序消息、Actor 模型（同一个 actor 的 mailbox 天然串行）都是这个思路。**能用分区解决的问题不要用锁解决**，因为分区的顺序保证是拓扑结构给的，不依赖任何超时。

### 8.5 那什么时候真的需要锁

留一个诚实的边界：当临界区**无法用状态机表达**（比如要独占一个外部设备、要拿一个第三方 API 的配额、要做一次跨多个系统的短事务），且**下游无法加 fencing 校验**（对方是个你改不了的第三方接口）时，锁是唯一选择。这时就应该：用 Redis 拿性能、把 TTL 设得远大于业务 p999 耗时、加告警、并且**明确接受残余风险**——把「我们在什么条件下允许重复」写进设计文档，比假装锁能保证正确性诚实得多。

## 九、故障与降级

| 故障 | 表现 | 正确处理 | 错误处理 |
| --- | --- | --- | --- |
| 锁服务整体不可用 | 抢锁超时率 100% | fail-close：拒绝进入临界区并告警 | fail-open：全部放行 → 立刻双写 |
| 持有者 STW 后恢复 | 日志出现 fence rejected | 记录停工时长，STW 超阈值告警 | 忽略 → 掩盖了真实并发 |
| 续约失败 | keepAlive 报错 | 立即停止临界区操作，主动放弃 | 继续跑 → 与 fencing 冲突 |
| 锁等待队列过长 | 抢锁 p99 从 5ms 涨到 3s | 加大分片（按 key 前缀拆锁）、缩短临界区 | 提高超时 → 雪崩 |
| session / lease 抖动 | 锁被频繁判定过期 | 调大 sessionTimeout，检查网络 | 缩短 → 更频繁丢锁 |

其中一个细节值得单独说：**「续约失败就该立刻停手」**。当客户端发现自己的 lease 续不上，它的正确动作不是「重试续约」，而是**当作已经丢锁，停止写，让 fencing 兜底**。继续写就是在赌「别人还没抢到」，而这个赌注赔率极差。

监控上必看的四个指标：

```
lock_acquire_p99           抢锁延迟
lock_hold_p99              持锁时长（逼近 TTL 就是事故前兆）
lock_renew_fail_total      续约失败次数
fence_reject_total         fencing 拒绝次数（大于 0 就说明互斥已经被破，必须查根因）
```

第四个是这套体系里最有价值的指标：**它是唯一一个能直接测量「锁到底有没有失效」的指标**。别的都是推测，这个是实证。

## 十、面试追问三连

**追问一：ZooKeeper 的锁就没有 GC 问题吗？**

有，而且更早暴露。ZK 用 sessionTimeout（常见 10-40 秒）判定存活，客户端 STW 超过这个窗口，服务端会认为它死了并删掉临时节点，锁被提前释放；客户端恢复后依然「以为自己持锁」。ZK 相对 Redis 的优势在于 quorum 写入，能避免主从切换丢锁（脑裂），而不是避免 STW 丢锁。两者都必须靠 fencing 收口。

**追问二：既然 fencing 能解决，为什么还要锁？**

锁的价值在**性能**和**减少冲突**，不在正确性。没有锁，所有实例都会去撞存储层的条件写，99% 的请求被 fencing 拒掉，等于用存储层做争抢，放大写放大和延迟。锁把冲突挡在存储层之前，fencing 负责兜住剩下那 1%。**是「锁做优化、fencing 做正确性」的分工**，不是二选一。

**追问三：TTL 设多长？**

两个约束同时满足：① 大于业务 p999 耗时（否则正常业务就会超时丢锁）；② 小于「业务能容忍的最长阻塞时间」（否则崩一个实例，任务卡死那么久）。两者冲突时，说明业务设计有问题——应该把大临界区拆成小段，每段各自持锁，而不是把 TTL 调大。经验值：TTL 取 p999 的 2 到 3 倍，看门狗按 TTL/3 续期，并对「持锁时长超过 TTL 的 50%」打点告警。

## 十一、收尾

这道题的三条线：

- **失败线**：STW 是唯一客户端不自知的故障，所有超时型锁的安全性上限由它决定。Redis、ZK、etcd 都一样，区别只在概率。
- **仲裁线**：quorum 解决锁的「存在性」（避免脑裂丢锁），超时/心跳解决「活性」（崩溃自愈），两者都不是「互斥」的保证。
- **正确性线**：只有存储层的条件写 + 单调 token 能保证正确性。`WHERE fence_token < :token` 这一行 SQL，比任何锁实现都重要。

如果面试官继续往下压，还能往这几个方向走：跨数据中心的锁（同城双活下 quorum 的延迟代价，异地锁基本不可用）、锁的批量获取与死锁避免（多把锁排序、超时回退）、以及「分布式事务」里锁与 2PC 的关系（MySQL 的行锁 + undo 其实就是单机版的 fencing）。这些留到后面的题。

*明日预告：按轮换转到 AI/LLM 方向 ——「推理服务的 KV cache 到底怎么管：为什么 PagedAttention 能把碎片从 60% 压到 4%、block table 怎么让逻辑序列和物理显存解耦、prefix caching 的哈希前缀匹配在什么情况下会误命中、抢占（preemption）的 recompute 与 swap 两种策略怎么选、以及 continuous batching 下 decode 阶段的显存水位怎么预估才不会被 OOM 打断」。*

---

**相关阅读**

- [Redis 分布式锁怎么实现？Redlock 有什么问题？](/blog/2026/08/11/redis-distributed-lock-interview)
- [百万级延迟任务调度系统怎么设计](/blog/2026/11/16/delayed-task-scheduler-interview)
- [API 幂等性：重复请求怎么不重复扣款](/blog/2026/08/27/api-idempotency-interview)
- [分布式事务：2PC、TCC 与最终一致](/blog/2026/08/20/distributed-transaction-interview)
