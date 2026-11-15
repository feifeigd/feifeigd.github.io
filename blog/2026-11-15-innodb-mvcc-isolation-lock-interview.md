---
title: "面试题：InnoDB 的四种隔离级别到底隔离了什么？MVCC 的快照读为什么在可重复读下看不见别人提交的数据、undo 版本链和 Read View 怎么配合、当前读为什么必须加锁、间隙锁又怎么在等值查询里锁住一整片区间、线上死锁该怎么读？"
date: 2026-11-15T09:00:00+08:00
draft: false
tags: ["backend", "mysql", "transaction", "mvcc", "innodb", "interview"]
categories: ["Interview"]
description: "MySQL 事务高频面试题：把「隔离级别」从背表格变成能推导的机制。行格式里的 DB_TRX_ID / DB_ROLL_PTR 怎么串出 undo 版本链，Read View 的四个字段怎么逐条判可见性，RC 与 RR 的唯一差别为什么只是 Read View 的创建时机（实测：普通 BEGIN 首次读等于 200，WITH CONSISTENT SNAPSHOT 首次读等于 100）。再往下是锁：当前读为什么绕开 MVCC 必须加锁、RR 下的幻读到底还存不存在（三段实测）、唯一索引等值命中为什么退化成 record lock 而非唯一索引不退化成 next-key lock（实测相邻插入被阻塞 2.01 秒）、插入意向锁和间隙锁的兼容矩阵，最后是 1213 死锁日志的逐行解读与定序加锁、事务重试的落地清单。"
---

> 这是「每日一题」专栏的第二十五篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇是 [PD 分离为什么能提速](/blog/2026/11/14/pd-disaggregation-interview)，今天按轮换回到后端/分布式方向，兑现上一篇的预告：**InnoDB 的隔离级别、MVCC 与锁**。
>
> 这题是「八股文浓度最高」的一道。几乎所有人都能背出那张四行三列的隔离级别表，也都能说出「RR 靠 MVCC 实现可重复读」。但面试官只要往下压两层——「MVCC 具体怎么让一条旧记录变回旧值？」「既然 RR 用 MVCC 解决了幻读，那间隙锁是干什么用的？」——大部分人就开始绕了。今天不谈结论，只谈机制，并且每一条机制都在 MySQL 8.0.46 上跑出来给你看。

{/* truncate */}

## 一、题目与考点拆解

面试官的原话通常是：

> 你们数据库用的什么隔离级别？四种隔离级别分别解决了什么问题？MVCC 是怎么实现可重复读的——同一条记录，别人改了又提交了，为什么我这个事务还能读到旧值？那 undo log 里到底存了什么、版本链怎么串？你说 RR 解决了幻读，可间隙锁又是干什么的？最后，线上报了个 `Deadlock found when trying to get lock`，日志怎么读、怎么改代码？

这一题真正考六层，缺一层都算没答透：

1. **三种读异常的精确语义**：脏读 / 不可重复读 / 幻读，各自的定义边界在哪里，SQL 标准那张表和 InnoDB 的实际行为差在哪。
2. **版本是怎么被"留住"的**：行格式的隐藏列、undo log 的记录结构、版本链的物理形态。
3. **可见性判定**：Read View 的四个字段、逐条判定算法、以及 RC 和 RR 的唯一差别。
4. **快照读与当前读的分裂**：为什么 `SELECT` 和 `UPDATE` 读的不是同一份数据，这个分裂是幻读残留的根源。
5. **锁的真实加锁范围**：record / gap / next-key / insert intention 四种锁，以及"唯一索引等值命中会退化"这条规则背后的原因。
6. **死锁的读法与预防**：1213 与 1205 的区别、`LATEST DETECTED DEADLOCK` 逐行含义、以及工程上怎么让它不再发生。

先说结论，后面全部展开：

> **隔离级别的本质不是"加多少锁"，而是"什么时候建立一致性快照 + 当前读要不要加间隙锁"。** MVCC 只服务快照读，锁只服务当前读，两套机制各管一半，交界处就是幻读残留和死锁发生的地方。

## 二、隔离级别：先把它从"背表格"变成"能推导"

### 2.1 三种读异常的精确定义

很多人背得出名字但说不清边界，而面试官恰恰卡边界。

**脏读（Dirty Read）**：读到了另一个事务**尚未提交**的修改。注意关键词是"未提交"——哪怕对方最后回滚了，你也已经把脏数据拿去做了业务决策。这是最严重的一档，因为读到的数据在数据库里从未真实存在过。

**不可重复读（Non-Repeatable Read）**：同一个事务内，两次读**同一行**，结果不同，因为中间有别的事务提交了更新。争议点在于"这是不是 bug"——对很多业务来说，事务内两次读到不同值确实会让逻辑错乱（先查余额再扣款，两次余额不一致），所以要防。

**幻读（Phantom Read）**：同一个事务内，两次**同样的范围查询**，第二次多出了行，因为别的事务插入了新记录。和不可重复读的区别是**对象不同**：不可重复读针对已存在的行（值变了），幻读针对结果集的行数（行变多了）。这个区别决定了它们的解法完全不同——行值变化用版本快照就能挡住（因为那一行本来就在你的结果集里，只是取哪个版本的问题），而"凭空多出来的行"没法靠"给已有行拍快照"解决，因为插入发生时你根本不知道它要插在哪。

### 2.2 标准表格与 InnoDB 的真实行为

SQL 标准给的表是这样的：

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|---|---|---|---|
| READ UNCOMMITTED | 可能 | 可能 | 可能 |
| READ COMMITTED | 不可能 | 可能 | 可能 |
| REPEATABLE READ | 不可能 | 不可能 | **可能（标准）/ 基本不可能（InnoDB）** |
| SERIALIZABLE | 不可能 | 不可能 | 不可能 |

最后一行那个脚注就是本题最大的坑。**标准说 RR 允许幻读，InnoDB 的 RR 却基本挡住了幻读**——但"基本"两个字里有文章，第七节细讲。

至于 READ UNCOMMITTED，实际几乎没人用：InnoDB 实现它不需要额外逻辑（直接把 Read View 里所有事务都当成已提交），所以它连脏读都不加保护。线上见到它基本都是配置写错了。

### 2.3 为什么没人把默认级别改成 RC

MySQL 默认 RR（8.0 也是），PostgreSQL / Oracle 默认 RC。这个差异经常被追问。

原因有两层。第一层是历史包袱：MySQL 早期只有 statement 格式的 binlog，RC 级别下主库上"先删后插"这类操作在从库重放时可能因为加锁范围不同导致数据不一致，所以 InnoDB 干脆把默认设成 RR。第二层是 RR 确实对业务更"省心"：很多业务代码在事务里做了多次读，RR 帮你免费挡住不一致。

反过来说，**RC 也有 RC 的好处**：没有间隙锁，锁范围最小，死锁概率低得多。所以现在不少团队会主动切到 RC + `binlog_format=ROW`。这是个真实的取舍，面试时能说出"我们选哪个、为什么"比背"默认是 RR"值钱得多。

## 三、版本是怎么被留住的：隐藏列 + undo 版本链

### 3.1 行格式里的三个隐藏列

InnoDB 的聚簇索引叶子节点存的不是一个裸的行，而是带三个隐藏列的行（COMPACT / DYNAMIC 行格式）：

- `DB_TRX_ID`：6 字节，最后修改这行的事务 ID。
- `DB_ROLL_PTR`：7 字节，回滚指针，指向 undo log 里这条记录的上一个版本。
- `DB_ROW_ID`：6 字节，**只在表没有主键也没有唯一非空索引时才有**，InnoDB 用它造一个隐藏的聚簇索引键。

这两个长度不是随便定的：6 字节事务 ID 意味着上限是 2 的 48 次方，7 字节回滚指针意味着能寻址 2 的 56 次方字节的 undo 空间。这些数字在死锁日志里能直接看到——第七节我们会拿一段真实日志佐证。

### 3.2 版本链长什么样

假设 `id=1` 这一行被三个事务依次改过：trx 102 改成 100，trx 105 改成 200，trx 108 改成 300。物理上只存一行，但通过 `DB_ROLL_PTR` 串成一条链：

```
当前行（聚簇索引叶子节点）
┌────────────────────────────────┐
│ id = 1                         │
│ v  = 300                       │
│ DB_TRX_ID   = 108              │
│ DB_ROLL_PTR ───────────────────┼──┐
└────────────────────────────────┘  │
                                    ▼
             undo log：trx 108 写入前的旧值
             ┌───────────────────────┐
             │ v = 200               │
             │ roll_ptr ─────────────┼──┐
             └───────────────────────┘  │
                                        ▼
             undo log：trx 105 写入前的旧值
             ┌───────────────────────┐
             │ v = 100               │
             │ roll_ptr ─────────────┼──► undo log：trx 102 的插入前状态（更早）
             └───────────────────────┘
```

关键点：**undo log 存的是"修改前的值"，不是"修改后的值"**。所以想回退到某个时间点的视图，就是沿着链往回走，找到第一个"对我可见"的版本。这也是为什么长事务会撑爆 undo 表空间——只要有人还可能需要某个老版本，它就不能被 purge。

### 3.3 undo 什么时候才能被清理

InnoDB 有个后台线程叫 purge，它负责把"确定不会再有人需要"的 undo 记录删掉。判断标准是：**当前所有活跃 Read View 里最小的那个，比这条 undo 记录还新，那这条 undo 就可以回收。**

这就解释了线上一个常见现象：`SHOW ENGINE INNODB STATUS` 里 `History list length` 一直往上涨，磁盘 io 抖动，查询越来越慢。根因几乎总是同一件事——**有人开了长事务**。一个忘了提交的事务会让整个 undo 链卡死在那，所有后续修改产生的旧版本都堆着不能删。

面试时如果被问到"长事务有哪些危害"，标准答案的三条正是：undo 膨胀导致回滚段撑爆、锁持有时间长导致等锁、主从延迟（大事务一次性提交）。

## 四、Read View：把"可见"变成一个可以逐条判定的算法

### 4.1 四个字段

每次需要一致性读的时候，InnoDB 会构造一个 Read View（本质是快照时刻的活跃事务清单）：

- `m_ids`：生成 Read View 时，**所有活跃（未提交）的读写事务 ID 列表**。
- `min_trx_id`：`m_ids` 里的最小值。
- `max_trx_id`：生成 Read View 时**下一个将要分配的事务 ID**（注意不是 `m_ids` 的最大值，而是最大值加一之后的分配水位）。
- `creator_trx_id`：创建这个 Read View 的事务自己的 ID。

### 4.2 可见性判定：四步走

拿到一行记录，看它的 `DB_TRX_ID`，按顺序判：

```python
def visible(db_trx_id, rv, creator):
    # 0. 自己改的，永远可见
    if db_trx_id == creator:
        return True
    # 1. 比最小活跃事务还小 → 在我建快照之前就已经提交了 → 可见
    if db_trx_id < rv.min_trx_id:
        return True
    # 2. 大于等于下一个待分配 ID → 在我建快照之后才开启的事务 → 不可见
    if db_trx_id >= rv.max_trx_id:
        return False
    # 3. 落在 min 和 max 之间：还在活跃列表里 → 未提交 → 不可见
    if db_trx_id in rv.m_ids:
        return False
    # 4. 落在区间内但不在活跃列表 → 那种"建快照时活跃、现在已提交"的事务
    #    注意：这里其实也返回不可见（快照语义），因为 m_ids 是快照时刻的
    return False
```

第 4 步是最容易被背错的地方。正确说法是：**`m_ids` 是快照时刻的活跃事务集合，只要这个事务在建快照时还活着，它的任何修改对我的快照都不可见——哪怕它现在已经提交了。** 这才是"可重复读"为什么能成立的物理原因：不是我看不到新数据，而是我的判定表被冻住了。

判定为不可见时，就顺着 `DB_ROLL_PTR` 走到上一个版本，拿上一版的 `DB_TRX_ID` 重判，直到找到可见版本或者链走到底。

### 4.3 RC 与 RR 的唯一差别：Read View 建在什么时候

这是本文最值得记住的一句话：

> **RC 和 RR 的代码差别只有一个：Read View 是每条 SELECT 重建一次，还是事务内第一条 SELECT 建完就复用。**

- RC：每条 `SELECT` 都新建 Read View → 每次都能看到"此刻已提交"的最新数据 → 不可重复读。
- RR：事务内第一条 `SELECT` 建 Read View，之后全程复用 → 每次都按同一张判定表算 → 可重复读。

但这里有个非常容易被忽略的细节：**RR 下 Read View 不是在 `BEGIN` 时创建的，而是在第一条快照读时创建的**。这意味着"我 `BEGIN` 之后、第一次 `SELECT` 之前，别人提交的修改，我是能看到的"。这条如果背错了，面试官一追问就会翻车。实测验证：

```python
# 场景 A：普通 BEGIN
#   A: BEGIN                      <- 此刻 v=100，但还没建 Read View
#   B: UPDATE r SET v=200 ... COMMIT
#   A: SELECT v FROM r WHERE id=1  <- Read View 此刻才建，B 已提交，所以可见
# 场景 B：WITH CONSISTENT SNAPSHOT
#   A: START TRANSACTION WITH CONSISTENT SNAPSHOT  <- 立刻建 Read View
#   B: UPDATE r SET v=300 ... COMMIT
#   A: SELECT v FROM r WHERE id=1  <- 按快照读，B 不可见
```

在 MySQL 8.0.46 上的实测输出：

```
[A] 普通 BEGIN，别人改成 200 并提交后，A 首次快照读 = 200  (期望 200)
[B] WITH CONSISTENT SNAPSHOT 起事务(此刻 v=100)，别人改成 300 并提交后，A 首次快照读 = 100  (期望 100)
[C] RR 事务内先快照读 = 100
[C] 别人改成 400 并提交后，再快照读 = 100  (期望仍 100)
```

A 和 B 两个场景都是"别人先提交、我再读"，结果一个 200 一个 100，差别只在 Read View 建的时机。而 C 证明了一旦快照建好，后续无论别人怎么改，本事务读到的都是同一个值。

这就是 `mysqldump --single-transaction` 为什么能用：它会先 `START TRANSACTION WITH CONSISTENT SNAPSHOT` 再开始导出，否则在 `BEGIN` 之后、第一条 `SELECT` 之前发生的写入会漏进备份，造成备份不一致。

## 五、当前读：为什么 UPDATE 读的不是快照

### 5.1 两种读的分裂

InnoDB 里读分成两类：

- **快照读（一致性读）**：普通的 `SELECT`，走 MVCC，不加锁，读 Read View 里的可见版本。
- **当前读（锁定读）**：`SELECT ... FOR UPDATE`、`SELECT ... FOR SHARE`、以及所有 `INSERT` / `UPDATE` / `DELETE`，它们**必须**读到最新版本，并且要加锁。

为什么 `UPDATE` 不能读快照？因为它要基于最新值做修改。如果按快照读到 v=100，而实际已经是 300 了，那 `v = v + 1` 就会把别人的 300 覆盖成 101，直接丢更新。所以当前读必须读最新提交版本，并且锁住它防止别人再改——**"读最新 + 加锁"这两件事是绑定的，读最新不锁就等于没读**。

### 5.2 RR 下的幻读：我实测给你看

教科书说 RR 解决了幻读。真实情况是：**快照读靠 MVCC 挡住了，当前读靠 next-key lock 挡住了，但两者混用时幻读依然会发生。**

在一个 RR 事务里做三段操作：先快照读统计，中间别的事务插入并提交，然后当前读统计，最后执行一次 UPDATE，再快照读统计。

```sql
-- 表 t(id PK, v, k)，idx_k 是 k 上的普通索引，初始 k=5 有两行
-- A: BEGIN
-- A: SELECT COUNT(*) FROM t WHERE k=5;             -> 2
-- B: BEGIN; INSERT INTO t VALUES (3,100,5); COMMIT;  (B 已插一行)
-- A: SELECT COUNT(*) FROM t WHERE k=5;             -> ?  快照读
-- A: SELECT COUNT(*) FROM t WHERE k=5 FOR UPDATE;  -> ?  当前读
-- A: UPDATE t SET v=v+1 WHERE k=5;                  -- 当前读，改到 B 插的那行
-- A: SELECT COUNT(*) FROM t WHERE k=5;             -> ?  又变回快照读
```

MySQL 8.0.46 实测输出：

```
A 快照读  count(k=5) = 2
B 插入 id=3 (k=5) 并提交, B 自己看到 count = 3
A 快照读  count(k=5) = 2   (MVCC 挡住了)
A 当前读  count(k=5) = 3   (看到 B 的新行)
A 执行 UPDATE ... WHERE k=5 后再快照读 count = 3   <- 幻读
```

最后一行就是幻读的实锤：**同一个事务里，两次一模一样的快照读，结果从 2 变成了 3。** 原因是那个 `UPDATE` 是当前读，它读到了 B 插的行并且改了它——而"被自己改过的行"在可见性判定里走的是第一条规则（`DB_TRX_ID == creator_trx_id` 直接可见），于是它突然就出现在了本事务的快照视图里。

所以要背的准确说法是：

> **InnoDB 的 RR 只在"纯快照读"和"纯当前读"两种极端情况下分别避免了幻读；一旦混用，幻读仍会出现。** MySQL 官方文档明确写了 RR 不保证完全避免幻读。

这段实测还有一个副作用值得记住：**如果你的业务代码在 RR 事务里先 `SELECT COUNT(*)` 做校验，再用 `UPDATE` 改数据，那么校验和修改看到的数据集很可能不一样。** 想真正一致，就得用 `SELECT ... FOR UPDATE` 从一开始就加锁（当前读），而不是先快照读再改。

## 六、间隙锁：凭空锁住一整片区间

### 6.1 四种锁

- **Record Lock**：锁住索引上的一条记录。
- **Gap Lock**：锁住两条索引记录**之间**的间隙，不含记录本身。它的唯一用途就是阻止别的插入。
- **Next-Key Lock**：Record Lock + Gap Lock 的组合，锁住"前开后闭"的区间 `(prev, cur]`。这是 InnoDB 在 RR 下的默认加锁单位。
- **Insert Intention Lock**：插入前对目标间隙加的一种特殊 gap lock，多个插入意向锁**互相兼容**（不同位置插入不冲突），只在插入位置已被 gap lock 占用时才等待。

一个反直觉的点：**gap lock 之间是互相兼容的**。两个事务可以对同一个间隙都加 gap lock，谁也不挡谁——因为 gap lock 的唯一目的是挡插入，而它自己不插入。真正撞车的是"gap lock 持有者"和"想在该间隙插入的 insert intention"。

### 6.2 为什么 RR 需要它：一个不存在的值

考虑"查不到就插"的经典逻辑：

```sql
-- RR 下，A 想确保 id=20 这个会员不存在
BEGIN;
SELECT * FROM t WHERE id=20 FOR UPDATE;   -- 返回空
-- 如果这里没有间隙锁，A 就会认为"20 不存在，我可以插"
INSERT INTO t VALUES (20, ...);
COMMIT;
```

如果没有间隙锁，两个事务同时执行这段，都会查到空，都去插，一个成功一个主键冲突回滚；更糟的是如果没主键约束，就插进去两条。有了间隙锁，第一个事务虽然"什么都没查到"，但它把 20 所在的那个间隙锁住了，第二个事务的插入会被挡住，从而串行化。

**这就是间隙锁的本质：锁的不是数据，是"数据不存在"这个事实。**

实测 RR 与 RC 的对照（表里 id 有 1、2、10、30，锁住 id=20 这个不存在的值）：

```
[REPEATABLE-READ] A: SELECT * FROM t WHERE id=20 FOR UPDATE -> ()
[REPEATABLE-READ] B: INSERT id=20 被阻塞 2.01s 后失败: 1205 Lock wait timeout exceeded
[READ-COMMITTED]  A: SELECT * FROM t WHERE id=20 FOR UPDATE -> ()
[READ-COMMITTED]  B: INSERT id=20 成功，耗时 0.01s  <- 没有间隙锁
```

同一句 SQL、同一个不存在的值，RR 下把整个间隙锁住、插入被堵了 2.01 秒（我设的 `innodb_lock_wait_timeout`），RC 下同一秒就插进去了。**RC 不加间隙锁，是因为 RC 靠别的手段保证复制一致性**——`binlog_format=ROW` 下从库重放的是行变更镜像，不需要靠加锁范围来保证主从一致，所以 RC 干脆放弃了间隙锁，换来更小的锁范围、更低的死锁概率。

### 6.3 加锁范围不是"WHERE 条件"，是"索引扫描路径"

这是 Java / Go 后端最容易搞错的地方：**InnoDB 加锁加在索引上，加多少取决于优化器实际走了哪条索引、扫了哪些记录、有没有回表。** 不是"你 WHERE 写了什么就锁什么"。

最实用的两条规则（业界总结成五条，最常考的是这两条）：

1. **唯一索引上的等值查询、命中记录 → next-key lock 退化为 record lock。** 因为唯一索引保证等值最多一行，锁住这一行就够了，没必要锁间隙。
2. **非唯一索引上的等值查询 → 不会退化，仍要 next-key lock。** 因为同一索引值可能有多行，而且还要防止别人在这个值附近插新行。

实测对照（表 r 里 id 有 1、2、10、11、30，k 有 5、5、7、7、9，idx_k 建在 k 上）：

```
A: SELECT id FROM r WHERE id=10 FOR UPDATE   (唯一索引，命中记录)
   B: INSERT id=12 (紧跟其后): INSERT 成功 0.10s  -> 没被锁住
   B: INSERT id=20 (差得远):  INSERT 成功 0.19s  -> 没被锁住

A: SELECT id FROM r WHERE k=7 FOR UPDATE     (非唯一索引 idx_k)
   B: INSERT k=7 的新行:  INSERT 阻塞 2.01s 后 1205  -> 被锁住了
   B: INSERT k=6 (区间外): INSERT 阻塞 2.02s 后 1205  -> 也被锁住了
```

第二条尤其值得盯着看：**`k=6` 明明不在 `k=7` 的等值条件里，为什么也被锁住了？** 因为 idx_k 上有序值是 5、5、7、7、9，对 `k=7` 的等值查询会加 next-key lock 覆盖 `(5,7]` 和 `(7,9]` 这些区间，而 6 正落在 `(5,7)` 这个间隙里，属于被保护的区间内部。

这就是线上"加锁太多导致死锁"最典型的成因：**你以为是行锁，实际拿到了区间锁；两个事务各自锁住一大片交错的区间，互相等对方释放。**

规避的办法很实在：

- 尽量让 `FOR UPDATE` 走**唯一索引等值查询**，让它退化成 record lock。
- 如果业务必须按非唯一条件锁，要么改成 RC，要么先把主键捞出来，再按主键 `FOR UPDATE` 锁。
- 不要在 `FOR UPDATE` 后面跟范围条件（`k BETWEEN` / `k >`），那是把整个区间交给数据库决定锁多少。

## 七、死锁：从 1213 到日志逐行

### 7.1 1213 和 1205 不是一回事

这两个错误码经常被混：

- **1213 Deadlock found when trying to get lock**：InnoDB 的死锁检测（wait-for graph 出现环）**主动**回滚了某个事务，**立即返回**，不等待。
- **1205 Lock wait timeout exceeded**：没人检测到死锁，就是单纯等不到锁，**等满 `innodb_lock_wait_timeout`（默认 50 秒）**才返回。

区别在延迟上：1213 是毫秒级，1205 是分钟级。线上如果看到接口"偶发卡 50 秒然后失败"，那是 1205，说明锁等待没被检测到死锁，通常是对同一条热点行排队太长；如果是"偶发秒级失败"，那才是死锁。

### 7.2 一个最小的死锁

```sql
-- A: BEGIN; UPDATE d SET v=v+1 WHERE id=1;   -- 持有 id=1 的行锁
-- B: BEGIN; UPDATE d SET v=v+1 WHERE id=2;   -- 持有 id=2 的行锁
-- A: UPDATE d SET v=v+1 WHERE id=2;          -- 等 B
-- B: UPDATE d SET v=v+1 WHERE id=1;          -- 等 A -> 成环
```

反向加锁顺序，两事务互相持有对方要的锁，形成 wait-for 环。实测结果：

```
A 持有 id=1 的行锁, B 持有 id=2 的行锁
A: OK                                    <- A 的第二个 UPDATE 也在等，但先被判为 victim 的是 B
B: 1213 Deadlock found when trying to get lock; try restarting transaction
总耗时 0.59s
```

注意这里 InnoDB 的选择：**回滚 undo 量少的那个事务**（`WE ROLL BACK TRANSACTION (2)`）。所以"谁被回滚"是不确定的，业务层必须能容忍任意一方失败。

### 7.3 逐行读 LATEST DETECTED DEADLOCK

线上排查时执行 `SHOW ENGINE INNODB STATUS`，抓 `LATEST DETECTED DEADLOCK` 段。下面是这次实测的原文（删掉了重复的 hex 行）：

```
*** (1) TRANSACTION:
TRANSACTION 2109, ACTIVE 1 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 3 lock struct(s), heap size 1128, 2 row lock(s), undo log entries 1
MySQL thread id 50, OS thread handle ..., query id 388 172.17.0.1 root updating
UPDATE d SET v=v+1 WHERE id=2

*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 14 page no 4 n bits 72 index PRIMARY of table `lab`.`d`
trx id 2109 lock_mode X locks rec but not gap
Record lock, heap no 2 PHYSICAL RECORD: n_fields 4; compact format; info bits 0
 0: len 4; hex 80000001; asc     ;;      <- id = 1（0x80000001 是 1 的有符号编码）
 1: len 6; hex 00000000083d; asc     =;;  <- DB_TRX_ID = 0x83d = 2109
 2: len 7; hex 01000001880151; ...        <- DB_ROLL_PTR（7 字节，undo 指针）
 3: len 4; hex 80000065; asc     e;;      <- v = 0x65 = 101

*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
... index PRIMARY of table `lab`.`d` trx id 2109 lock_mode X locks rec but not gap waiting
 0: len 4; hex 80000002 ...               <- 想锁 id = 2

*** (2) TRANSACTION:
TRANSACTION 2110, ACTIVE 1 sec starting index read
... UPDATE d SET v=v+1 WHERE id=1
*** (2) HOLDS THE LOCK(S):
... trx id 2110 lock_mode X locks rec but not gap
 0: len 4; hex 80000002 ...               <- 持有 id = 2
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
 0: len 4; hex 80000001 ...               <- 想要 id = 1

*** WE ROLL BACK TRANSACTION (2)
```

读这段日志的顺序是固定的，别从头逐字看，按这个顺序三分钟定位：

1. **先看最后一行** `WE ROLL BACK TRANSACTION (n)`——确定谁是 victim，先假设被回滚的那条业务路径是受害者。
2. **找两个事务的 `WAITING FOR THIS LOCK TO BE GRANTED`**——这就是成环的两条边。日志里是"1 持有 id=1 等 id=2"和"2 持有 id=2 等 id=1"，一眼成环。
3. **回到 `HOLDS THE LOCK(S)` 看加锁类型**：这里写的是 `lock_mode X locks rec but not gap`，说明只加了 record lock，没加间隙锁，是典型的"按主键更新但顺序反了"。如果写的是 `locks rec but not gap` 之外的形态（比如 `X`，或带 `gap`），说明涉及 next-key lock，要回去查索引使用情况。
4. **看 `2 row lock(s)` 和 `undo log entries 1`**——undo 越多越容易被选作 victim。
5. **拿 `UPDATE` 的那句 SQL 原文去代码里搜**，找到调用链，然后看两条链路各自的加锁顺序。

日志里那段 hex 正好印证了第三节讲的隐藏列：`len 6` 的那一列就是 `DB_TRX_ID`，`00000000083d` 换成十进制就是 2109，和 `TRANSACTION 2109` 完全对上；`len 7` 那一列是 `DB_ROLL_PTR`。**"6 字节事务 ID + 7 字节回滚指针"不是书上的说法，在死锁日志里是肉眼可见的字段。**

### 7.4 死锁检测本身的代价

`innodb_deadlock_detect=ON`（默认）意味着**每当一个事务进入锁等待，InnoDB 都要遍历一遍等待图找环**，复杂度是"等待中的事务数"量级。单机几十个并发事务时完全无感；但如果是秒杀场景、几千个事务同时等同一行，这个 O(n) 检测本身就会吃掉大量 CPU，表现为"CPU 打满但 QPS 上不去"。

这时候的取舍是：关掉死锁检测（`innodb_deadlock_detect=OFF`），让死锁退化成 1205 锁等待超时，同时把 `innodb_lock_wait_timeout` 调小（比如 5 秒）。代价是死锁的发现从毫秒变成秒级。所以顺序应该是：**先想办法消除锁热点（排队、拆行、异步化），再考虑关检测。** 直接关掉只是把问题换个形态。

## 八、工程实践清单

把上面的机制翻译成能落到代码里的规则：

**事务要短。** 不要在事务里做 RPC 调用、发消息、等用户输入。事务越长，undo 越难回收，锁持有越久，`History list length` 越容易爆。

**加锁顺序要统一。** 死锁的唯一根治手段是消灭环。对所有"多行/多表更新"的路径，按同一个键（通常是主键升序）排序后再更新。转账就是最经典的例子：永远按 `min(from,to)` 先锁。

**`FOR UPDATE` 要打到唯一索引上。** 让它退化成 record lock。如果条件是非唯一索引，先查出主键再按主键锁，虽然多一次查询，但锁范围从"一片区间"缩到"几行"。

**别用 `SELECT ... FOR UPDATE` 做"存在性校验 + 插入"。** 更稳的做法是唯一索引 + `INSERT ... ON DUPLICATE KEY UPDATE`，或者 `INSERT` 直接靠唯一约束兜底、捕获 1062 错误。锁只在数据库内部存在一瞬间，不走两段式。

**事务失败要能重试。** 1213 是"正常的并发冲突"，不是 bug。捕获 1213 / 1205 后做有限次退避重试，业务逻辑必须幂等。这一点如果不做，上线后必然会遇到"偶发下单失败"。

**RR 下"先查后改"要小心。** 第五节实测过：快照读看到的数据集和随后 `UPDATE` 影响的数据集可能不同。校验和修改要落在同一份"当前读"上。

**监控 `History list length` 和 `INNODB_TRX`。** `SELECT * FROM information_schema.INNODB_TRX ORDER BY trx_started` 能直接抓到长事务，按 `trx_started` 排序看最老的那个，基本就是元凶。

## 九、总结

回到最开始那句话：**隔离级别的本质，是"什么时候建立一致性快照"加上"当前读要不要加间隙锁"这两件事的组合。**

- 脏读、不可重复读、幻读不是三个并列的概念，而是"读到未提交"、"同一行值变"、"结果集行数变"三个不同层次的不一致，后两个的解法完全不同。
- 可重复读靠的不是锁，是 `DB_TRX_ID` + `DB_ROLL_PTR` 串出的 undo 版本链，加上一张冻结的 Read View 判定表。
- RC 和 RR 的代码差别只有一行：Read View 每条语句重建，还是事务内只建一次。顺手记住 RR 下建在**第一次快照读**时，不是 `BEGIN` 时。
- 当前读必须读最新且加锁，这两件事不可分割；快照读与当前读混用，幻读依然存在——这是 RR 最容易被答错的地方。
- 间隙锁锁的是"不存在"，因为它要保护的是一个事实而不是一行数据；RC 因为没有间隙锁，锁范围小、死锁少，代价是要配 `binlog_format=ROW`。
- 死锁日志按"先看 victim、再看两条 waiting、再看 holds 的锁类型、最后回到 SQL"的顺序读，三分钟能定位。

如果面试官继续往下压，还能往这几个方向走：`INSERT` 语句本身会加什么锁（插入意向锁 + 唯一性检查的共享锁，`INSERT ... SELECT` 更复杂）、`SELECT FOR SHARE` 与 `FOR UPDATE` 在间隙上的差异、MDL 元数据锁怎么让 `ALTER TABLE` 卡住整张表、以及分布式事务里"本地事务 + 消息表"与 InnoDB 事务的边界。这些留到后面的题。

*明日预告：按轮换转到系统设计方向 ——「设计一个支持百万级延迟任务的调度系统：为什么数据库扫表方案在十万级任务量就撑不住、时间轮为什么只适合内存级且精度受 tick 限制、Redis ZSet 分桶方案怎么做、消息队列的延迟消息（RocketMQ 18 级时间轮 / 任意延迟）各自的天花板在哪、任务分片与多实例抢占怎么避免重复执行、以及"任务已经触发但业务失败了"这件事该怎么幂等补偿？」*

---

**相关阅读**

- [MySQL 索引与深分页：为什么 B+ 树、最左前缀与 O(1) 翻页](/blog/2026/10/10/mysql-index-deep-pagination-interview)
- [IM 即时通讯系统：百万长连接怎么撑住](/blog/2026/11/13/im-messaging-system-interview)
- [分布式 ID 生成器：为什么需要它、怎么做到单调递增](/blog/2026/08/16/distributed-id-generator-interview)
- [LLM 推理的 PD 分离为什么能提速](/blog/2026/11/14/pd-disaggregation-interview)
