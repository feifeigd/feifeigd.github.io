---
title: "0.26 tok/s：CPU 上 MoE 推理被 page cache 抖动打崩的定量复盘"
date: 2026-11-17T18:00:00+08:00
draft: false
tags: ["llm", "inference", "llama-cpp", "performance", "moe"]
categories: ["Tech"]
description: "同一台 4C8T/30G 的机器、同一份 16B MoE 模型，decode 从可用水平掉到 0.26 tok/s。用 /proc/vmstat、kswapd 回收量和每 token 需要搬运的字节数把根因钉死：不是算力不够，是激活专家权重被挤出了 page cache，每个 token 都在读盘。"
---

上周把一台 4C8T、30G 内存的 CentOS 7 机器上的 `llama-server` 当团队私有补全后端用，模型是 DeepSeek-Coder-V2-Lite-Instruct 的 Q4_K_M（9.7 GB 文件，16B 总参数、2.4B 激活的 MoE），启动参数只有一行：

```bash
llama-server -m /data/models/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf \
  -c 8192 -t 4 --port 8081
```

日常体感是"能用"：IDE 里触发补全，等个一两秒出第一段。但某天下午它彻底崩了——不是报错，是慢到像死机。`/completion` 返回的 timings 长这样：

```text
prompt eval time =   11936.64 ms /      7 tokens ( 1705.23 ms per token,     0.59 tokens per second)
       eval time =  120575.15 ms /     32 tokens ( 3889.52 ms per token,     0.26 tokens per second)
```

**每个 token 3.89 秒**。32 个 token 生成了两分钟。这不是"CPU 慢"，因为同一份模型、同样的 `-t 4`，之前不是这个数；CPU 再弱也不会弱出 15 倍的差距，而且弱得如此稳定。

我一开始的怀疑方向全错了：先怀疑 `-t` 配错（超线程负优化），再怀疑 `-np` 把 `-c 8192` 切碎了，又去看 KV 是不是太大。直到把 `/proc/vmstat` 和 `vmstat` 摆在一起看，才发现问题根本不在 llama.cpp 的参数上——**模型权重正在被内核从 page cache 里赶出去，每个 token 都要重新从磁盘读一遍**。

这篇文章把这个链条的每一环都算清楚，顺便给出判别脚本和一份参数配方，避免下次再花一个下午怀疑自己配错了线程数。

{/* truncate */}

## 一、先排除"参数配错"：三个指纹能直接定性

CPU 上跑 LLM 慢，只有三种可能，而且它们的内核指纹完全不同：

| 现象 | 算力不足（compute bound） | 内存带宽不足（DRAM bound） | 缓存/磁盘抖动（IO bound） |
|---|---|---|---|
| `us`+`sy` | 高，接近 100% | 高 | 低（大量时间在等） |
| `wa`（iowait） | 接近 0 | 接近 0 | **几十个百分点** |
| `vmstat` 的 `bi`（块设备读） | 0 | 0 | **数百 MB/s 持续** |
| `pgmajfault` 增速 | 平稳 | 平稳 | **每秒成百上千** |
| 进程状态 | `R` | `R` | **`D`（不可中断睡眠）** |
| 抖动性 | 稳定地慢 | 稳定地慢 | **时快时慢，跳变** |

故障当时的实测快照：

```text
top:  %Cpu(s):  4.2 us, 11.6 sy, 26.4 id, 57.4 wa
       PID  USER  VIRT  RES  SHR S  %CPU  TIME+  COMMAND
     63373  root 18.0g 8.8g 1.1g D  27.3  4:43  llama-server
        66  root    0    0    0 S   9.1 48:55  kswapd0

vmstat 1 3
 r  b   swpd   free   buff  cache   si   so     bi    bo    in     cs us sy id wa
 0 27      0 233432  11800 4301028    0    0 373280   920 24496  36070  8  9 12 72
 0 15      0 233280  10928 4306680    0    0 337552   456 20816  30848  6  8 12 74
```

三个决定性信号同时出现：

1. **`wa` 72%~74%**：CPU 有四分之一的核在"空闲"状态，等 IO。
2. **`bi` 每秒 330~370 MB/s 持续读盘**：没有任何任务在下载、没有备份在跑，那就是有人在自己的模型文件上做随机读。
3. **`llama-server` 处于 `D` 状态**：不可中断睡眠，说明它卡在 page fault 的磁盘读上，不是在算。

到这一步就可以宣布：不是线程数配错。线程数配错的表现是"稳定地慢一点"，不会是"每个 token 读 370 MB 盘"。

## 二、把 tok/s 换算成字节：每 token 到底要搬多少

定性之后要定量，否则调参全靠猜。decode 阶段的访存不是"读整个模型"，而是"读这一步激活的那部分权重"，所以第一件事是算清每生成一个 token 需要搬运多少字节。

MoE 的好处在这里：模型总参数 16B，但每个 token 只过 2.4B 激活参数（含 attention 与共享专家）。Q4_K_M 的有效位宽约 4.9 bit/参数，于是

```text
每 token 字节数 ≈ 2.4e9 参数 × 4.9 bit / 8 ≈ 1.47 GB
```

再乘上上下文里要读的 KV（4k 上下文、GQA 下是几十 MB 量级，这里先忽略；到 32k 时它会变成第二项），得到估算函数：

```python
# bw_model.py —— 用带宽算 tok/s 上限，不含任何玄学系数
def bytes_per_token(active_params: float, bpw: float = 4.9, kv_bytes: int = 0) -> float:
    """激活参数按 bpw 位宽折算成字节，加上这一步要读的 KV。"""
    return active_params * bpw / 8 + kv_bytes


def predict_tok_s(per_token_bytes: float, effective_bw_bps: float) -> float:
    """decode 的理论上限：有效带宽 / 每 token 字节数。"""
    return effective_bw_bps / per_token_bytes


if __name__ == "__main__":
    b = bytes_per_token(2.4e9)
    print(f"每 token 需搬运 {b / 1e9:.2f} GB")
    for bw_gbps in (400, 1_000, 10_000, 20_000):
        print(f"  有效带宽 {bw_gbps/1000:>5.1f} GB/s → 上限 {predict_tok_s(b, bw_gbps*1e6):>7.2f} tok/s")
```

我把实测的 0.26 tok/s 反代回去，看它对应多少带宽：

```text
每 token 3.8894 s，需要 1.47 GB
→ 有效读带宽 = 1.47 GB / 3.8894 s ≈ 378 MB/s
```

而 `vmstat` 里同一时刻的 `bi` 是 **337~373 MB/s**。

两边对上了，误差不到 5%。这条计算不是"解释"，是**证据**：decode 的耗时几乎全部是权重搬运，算力在这个场景里根本没有参与竞争。也顺手解释了为什么 `-t 4` 换成 `-t 8` 在这种状态下完全没有区别——瓶颈在盘上，加线程只会让更多线程一起排队等 `read()`。

一旦接受"tok/s ≈ 有效带宽 / 每 token 字节数"这个模型，很多经验现象立刻变得可预测：

- 量化从 Q4 降到 Q3，权重少 25%，tok/s 涨 30% 左右（稳定近似线性）。
- MoE 比同尺寸稠密模型快好几倍，不是因为"算得少"，而是因为"读得少"。
- 上下文拉到 32k 后变慢，因为 KV 项从几十 MB 涨到 GB 级，开始和权重抢带宽。

而这三个数量级的差距，才是真正的重点：

| 数据在哪 | 有效带宽量级 | 1.47 GB 要多久 | 等效 tok/s |
|---|---|---|---|
| L2/L3 缓存 | 数百 GB/s ~ TB/s | 几毫秒 | 数百 |
| DRAM（这台 4C8T 的份额） | 10 GB/s 上下 | 0.15 s | 7 左右 |
| 本地盘（抖动时） | 0.35 GB/s | 4.2 s | **0.24** |

同一份模型，命中与不命中差 **30 倍**。这就是为什么"CPU 能不能跑 LLM"这个问题没有意义——要问的是"权重能不能待在内存里"。

## 三、为什么 mmap 的权重总是第一个死

llama.cpp 默认用 `mmap` 加载 GGUF。这是个非常合理的设计：权重变成 file-backed 的 page cache 页，多个进程共享同一份物理页，启动不用等 9.7 GB 读完，不用时还能被自然回收。

但"可回收"这三个字是双刃剑。内核回收内存时，对两类页的处置方式完全不同：

- **anon 页**（`malloc`、进程堆栈、KV cache 缓冲）：没有 swap 就**不可回收**，只能靠 OOM killer。
- **file-backed 页**（mmap 的权重、普通文件缓存）：**随时可回收**，丢掉的代价只是"下次访问再读一遍"。

内核认为后者"丢掉不亏"，因为对绝大多数程序来说确实不亏——文件读慢一点而已。但 LLM 推理是**每个 token 都要 touch 一遍全部激活权重**的工作负载，"下次访问再读一遍"意味着每秒读 300 MB。于是回收策略在这里从"优化"变成了"灾难"。

故障现场的内存账本，每一行都在讲同一件事：

```text
MemFree:          229992 kB      # 225 MB 空闲，基本见底
MemAvailable:    4046744 kB      # 4G "可用"，全是随时会被抢走的 cache
Cached:          3895080 kB      # 3.7 GB 文件缓存——9.7 GB 的模型装不下
AnonPages:      24956468 kB      # 23.8 GB 匿名页，全部不可回收
SwapTotal:             0 kB      # 没有交换区，没有任何缓冲垫
CommitLimit:    15821376 kB      # 15 GB
Committed_AS:  254473588 kB      # 承诺出去 243 GB，超额 16 倍
pgsteal_kswapd_normal: 617650289 # 已回收 6.18 亿页 × 4K ≈ 2.3 TiB
pgmajfault:        1272579       # 累计 major fault 127 万次
KernelStack:       558864 kB     # 3.5 万个线程的内核栈，约 546 MiB
```

几条推论：

**`SwapTotal: 0` 不是"内存充足"的证据，而是"没有缓冲垫"的证据。** 有 swap 时，内核可以先把冷 anon 页换出去，保住 file cache；没有 swap 时，anon 一旦逼近物理内存上限，内核唯一的出路就是抢 file cache。这台机器上 23.8 GB 的 anon 挤在 30.9 GB 的物理内存里，模型那 9.7 GB 的文件缓存自然只能留下 3.7 GB 的碎片。

**`MemAvailable` 好看不代表没在抖。** 4 GB "available" 听起来还行，但它全是可回收的 cache，kswapd 正在以 9% 的 CPU 持续回收它。判断依据应该是 `pgmajfault` 的**增速**，而不是瞬时可用量。

**`Committed_AS` 243 GiB 意味着超卖。** Linux 默认 overcommit，邻居进程申请内存时不看物理内存够不够，只在真正 touch 时才分配。于是所有人的 malloc 都成功，代价统一由 file cache 支付——而恰好只有 LLM 的权重躺在 file cache 里。

这就是完整的因果链：

```text
邻居进程 anon 增长（23.8 GB）
  → 无 swap，无法换出
  → kswapd 抢 file-backed 页（累计偷走 2.3 TiB）
  → 模型权重被逐出 page cache
  → decode 每一步 touch 权重 → major fault → 读盘
  → 每 token 3.89 秒，0.26 tok/s
```

## 四、mmap / mlock / no-mmap：三种加载语义的取舍

知道原理之后，`llama.cpp` 的三个加载选项就不是玄学了：

| 方式 | 页类型 | 可回收 | 多实例共享 | 启动 | 适用 |
|---|---|---|---|---|---|
| 默认 `mmap` | file-backed | 是 | 是 | 秒级 | 内存宽裕、或无并发实例 |
| `--mlock` | file-backed，锁定 | 否 | 是 | 秒级（随后锁页） | 需要保命的线上服务 |
| `--no-mmap` | anon | 否 | 否 | 要读完整个文件 | 单实例、且确定不会被 OOM |

取舍的关键是：**你要的是"共享 + 弹性"，还是"确定性"**。`mmap` 给你弹性（内存紧张时自动让路），但让路的代价在推理场景里是 30 倍性能；`--mlock` 给你确定性，但要求物理内存真的够，否则 `mlock` 失败后内核照样回收，你会得到"配了 mlock 却依然抖"的更迷惑的状态。

配额的算法可以很简单：

```text
物理内存 ≥ 权重 + KV + 运行时缓冲(约 1 GB) + 邻居最小工作集 × 1.2
```

这台机器：9.7 GB 权重 + 0.5 GB KV + 1 GB 缓冲 = 11.2 GB，剩下的 19 GB 才是邻居的预算。在 19 GB 里跑 MySQL、Prometheus、Grafana、containerd 和一堆云监控 agent，是够的——前提是给它们设个上限，别让 anon 无限制地涨到 23.8 GB。

```bash
# 给邻居划死线，把 file cache 从"人人可抢"变成"有保护区"
systemd-run --scope -p MemoryMax=16G -p MemoryHigh=14G \
  nerdctl run --name llama-server ...   # 或用 cgroup v1 的 memory.limit_in_bytes
```

## 五、我踩的第二个坑：测速本身也要内存预算

搞清楚机制后我想用 `llama-bench` 做一组干净对照（`-t 2/4/8` 与 `-ub` 扫描），结果这一脚把机器踹进了更深的坑：

我先把 `llama-server` 停掉腾内存，`MemAvailable` 从 4 GB 涨到 12 GB，看着够用，于是直接跑 9.7 GB 模型的扫描。但停掉服务的那一刻，隔壁的 anon 立刻又长回到 25 GB——**我以为腾出来的是我的，其实是被别人瞬间吃掉了**。`MemAvailable` 掉到 3.5 GB 时，`llama-bench` 已经开始 mmap 一个 9.7 GB 的文件：

```text
load average: 666.80, 326.72, 135.26
 41327 llama-bench  Ds  5714228      # D 状态，5.7 GB RSS 还在往上爬
```

后果不是"测出来慢"，而是**连 ssh 都进不来**：

```text
kex_exchange_identification: read: Connection reset by peer
Connection timed out during banner exchange
```

`sshd` 需要 fork、需要读配置、需要分配内存——在一台 `wa` 70%、kswapd 打满、load 666 的机器上，**控制面也会被拖死**。这是本次最贵的一课：抖动状态下你失去的不只是性能，还有修复它的手段。

所以压测脚本的第一行必须是探针，而不是压测：

```python
# guard.py —— 压测前先确认"内存真的是我的"
import re
from pathlib import Path


def meminfo() -> dict:
    out = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, v = line.split(":", 1)
        out[k] = int(v.split()[0]) * 1024  # kB -> B
    return out


def guard(model_bytes: int, headroom: int = 2 << 30) -> None:
    mi = meminfo()
    need = model_bytes + headroom
    avail = mi["MemAvailable"]
    if avail < need:
        raise SystemExit(
            f"拒绝压测：需要 {need/2**30:.1f} GiB，实际可用 {avail/2**30:.1f} GiB。\n"
            f"先释放邻居内存或换小模型，别用 D 状态把自己锁在门外。"
        )
    print(f"OK: 可用 {avail/2**30:.1f} GiB，模型 {model_bytes/2**30:.1f} GiB")
```

顺带一个纯运维的坑：`llama-bench` 编译在容器里（新 glibc + OpenSSL 3），在 CentOS 7 宿主机上直接跑会挂：

```text
/data/llama.cpp/build/bin/llama-bench: error while loading shared libraries:
  libssl.so.3: cannot open shared object file
```

宿主机是 `libssl.so.10`。正确姿势是回到构建镜像里跑（`/data` 已 bind mount）：

```bash
nerdctl exec buildenv /data/llama.cpp/build/bin/llama-bench \
  -m /data/models/model.gguf -t 4 -p 512 -n 128 -r 2 -o md
```

## 六、巡检脚本：把"感觉变慢"变成一个数

抖动是可以提前十几分钟发现的服务端指标。核心是两个量的比值：**decode 速度** 与 **major fault 速率**。正常情况下 `pgmajfault` 在预热完成后应该几乎不动；一旦它开始以每秒几百的速度涨，tok/s 会在半分钟内塌下去。

```python
# infer_health.py —— cron 里跑，输出一行判定
import time
from pathlib import Path


def vmstat() -> dict:
    out = {}
    for line in Path("/proc/vmstat").read_text().splitlines():
        k, v = line.split()
        out[k] = int(v)
    return out


def mem_avail() -> float:
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) / 1024 / 1024  # GiB
    return 0.0


def verdict(interval: float = 5.0, model_gib: float = 9.1) -> str:
    a = vmstat()
    time.sleep(interval)
    b = vmstat()
    majfault = (b["pgmajfault"] - a["pgmajfault"]) / interval
    disk_in = (b["pgpgin"] - a["pgpgin"]) / interval / 1024  # MiB/s
    avail = mem_avail()

    if majfault > 100 or disk_in > 50:
        return (f"THRASH fault={majfault:.0f}/s disk={disk_in:.0f}MiB/s "
                f"avail={avail:.1f}GiB → 权重正在被逐出，tok/s 即将塌")
    if avail < model_gib * 0.2:
        return f"LOW_MEM avail={avail:.1f}GiB → 余量不足，随时可能开始抖动"
    return f"OK fault={majfault:.0f}/s disk={disk_in:.0f}MiB/s avail={avail:.1f}GiB"


if __name__ == "__main__":
    print(verdict())
```

阈值要按机器调：`MemAvailable` 低于模型体积的 20% 就该告警；`pgmajfault` 的绝对阈值取决于页大小和负载，这台机器上预热完成后基本是 0，一旦上到每秒 100 就已经在抖了。

配合 llama-server 自己的 timings 更好：把 `predicted_per_second` 打到 Prometheus，和 `pgmajfault` 画在同一张图上，两条曲线的拐点几乎重合——这是我后来才意识到的、最省事的因果验证方式。

## 七、修复顺序（按性价比）

1. **先给权重划预留。** 这是唯一真正解决问题的动作。要么 `--mlock` 加够内存，要么用 cgroup 限制邻居的 anon 上限。其他所有优化在这个前提不成立时都是安慰剂。
2. **加 zram swap。** 30 GB 机器上 zram 给 8 GB，压缩比 2~3 倍，回收 anon 时走内存而不是磁盘，kswapd 的回收成本下降一个数量级。注意：zram 救的是"偶发压力"，救不了"anon 持续超过物理内存"。
3. **把 `-c` 按真实需求给。** 日志会告诉你实际分片：`n_slots = 4, n_ctx_slot = 8192, kv_unified = 'true'`。`kv_unified` 下这 8192 个 token 是四个会话共享的一个池子（不是 4 份），看起来更省，但代价是碎片：三个会话各自占住一段前缀后，新请求要一次吃进 1024 个 token 就找不到连续空间，于是它逐级把 batch 减半重试：

   ```text
   decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 1024, n_batch = 1024
   decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 1024, n_batch = 512
   decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 1024, n_batch = 256
   ```

   每一行都是一次独立的 decode 调用，1024 一路降到 8 就是十几轮空转——这就是那种"平时很快、偶尔卡三秒"的长尾。要么把 `-c` 提到峰值上下文总量，要么 `--parallel 1` 让一个会话独占 KV。
4. **降量化。** Q4_K_M 换 Q3_K_M，权重 9.7 GB 降到 7.6 GB，直接换来 25% 的带宽余量，代码补全这种任务几乎不掉质量。
5. **最后才是调 `-t`。** 在带宽 bound 的区间里，线程数几乎不影响 decode（只影响 prefill）。这台机器上 `-t 4` 正好等于物理核数，SMT 的第二个线程只会多一份上下文切换和 MSHR 争抢，收益远小于直觉——但这是量级很小的优化，不是 30 倍量级的救命。

## 八、踩坑清单

- **别用"CPU 弱"解释一切的慢。** decode 慢先看 `wa` 和 `bi`，这两列能在一分钟内区分"算力不够"和"在等盘"。
- **`SwapTotal: 0` 是风险项，不是优点。** 没有交换区意味着 anon 增长时内核只能抢 file cache，而 LLM 权重恰好是 file cache 里最"该被抢"的东西。
- **`MemAvailable` 的瞬时值会骗人。** 看 `pgmajfault` 增速和 `bi`，不看可用量。
- **停掉自己的服务不等于腾出了内存。** 邻居的 anon 会用几十秒把坑填回去；压测前必须重新探针。
- **D 状态进程 kill 不掉。** `kill -9` 对卡在 `read()` 的进程只是挂起请求，要等 IO 返回。别在这个状态下反复重试，只会加深堆积。
- **抖动会吃掉控制面。** load 666 时 sshd 连 banner 都发不出来，`nerdctl stop` 也可能卡住。给 sshd 和自己的 shell 留内存预算，或者至少留一个已建立的连接（`ServerAliveInterval` 保活）。
- **容器里编译的二进制别指望在宿主机跑。** CentOS 7 上的 `libssl.so.3` 缺失是老朋友的另一种形态。
- **`n_slots` 默认不是 1。** 日志里明写 `n_slots = 4, n_ctx_slot = 8192, kv_unified = 'true'`，KV 换算和并发假设都要按这个数来。

## 结语

这次故障最有意思的地方在于：**它的根因不在推理引擎里**。llama.cpp 的 `-t`、`-ub`、`-c` 全都配得合理，模型也选得对（MoE 在低带宽机器上是正确选择），但一台被超卖到 `Committed_AS` 243 GB 的机器，可以把任何"正确配置"打成 0.26 tok/s。

结论用一句话概括：**CPU 推理的性能不取决于 CPU，而取决于"每 token 要搬的字节"能不能就地取到**。算力决定 prefill，内存层级决定 decode。搞清这条，你在任何机器上看到 tok/s 异常，都能在五分钟内定位到是算力、带宽还是缓存的问题，而不是去翻参数手册。

相关阅读：[KV Cache 命中率才是 CPU 推理的 TTFT 主开关](/blog/2026/11/16/llama-server-prompt-cache-ledger)、[CPU 上量化与 KV Cache 的内存账本](/blog/2026/08/31/cpu-llm-quantization-kv-cache)。
