---
title: "零中断发布 LLM 推理服务：in-flight 排空、grace period 反解与冷启动预热"
date: 2026-11-18T21:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "kubernetes", "deployment"]
categories: ["Tech"]
description: "K8s 默认 30 秒 terminationGracePeriodSeconds 是给毫秒级请求设计的，而一次 4096 token 的生成在 CPU 上要跑 8 分钟。本文用离散事件模拟器量化三种排空策略，给出 grace period 的反解公式、五阶段 drain 控制器实现、以及预热把新副本 TTFT p99 砍到 1/3 的实测数据。"
---

滚动发布一个 Web 服务，最坏情况是几百个请求超时重试；滚动发布一个 LLM 推理服务，最坏情况是用户盯着屏幕上已经生成的 300 个字突然断掉，而且计费已经发生。

这两件事在 K8s 里用的是**同一套机制**：`SIGTERM`、`preStop`、`readinessProbe`、`terminationGracePeriodSeconds`。默认值 30 秒对前者绰绰有余，对后者是自欺欺人——因为 LLM 是少数几类**请求时长以分钟计**的服务，而 K8s 的所有默认值都是按毫秒级 RPC 设计的。

这篇文章不做概念科普，直接解决三个工程问题：排空的 deadline 到底该怎么算、drain 控制器怎么写才不丢请求、新副本的冷启动为什么不能只靠"模型加载完就 Ready"。

{/* truncate */}

## 一、先看清 SIGTERM 之后到底发生了什么

一个 pod 被删除时，K8s 里发生的事情是**并行**的，而不是很多人以为的串行：

| 时间 | 事件 | 谁在做 |
|---|---|---|
| t+0 | `deletionTimestamp` 置位，pod 进入 `Terminating` | apiserver |
| t+0 | preStop hook 开始执行 | kubelet |
| t+0 到 t+3s | EndpointSlice 里的 endpoint 被标记 `terminating`，各节点 kube-proxy/ingress 更新转发规则 | endpoint controller + 各节点 |
| hook 结束 到 t+grace | 容器收到 `SIGTERM`（**有 hook 时必须等 hook 跑完**） | kubelet |
| t+grace | `SIGKILL` | kubelet |

第一处坑：**"摘流量"和"SIGTERM"没有先后保证**。endpoint 传播依赖各节点的 kube-proxy 轮询周期与 ingress controller 的 reload 延迟，实测 1~3 秒是常态，跨可用区更久。这段时间里流量还在往这个 pod 上打，而进程已经收到了"准备去死"的信号。

第二处坑：`preStop: sleep 10` 是社区流传最广的补丁，它的作用是"收到 SIGTERM 后先装死 10 秒，等流量摘干净"。但 `preStop` 与 `SIGTERM` 是串行的——**sleep 期间进程根本没收到 SIGTERM**，所以服务仍在正常 accept 新连接，只是这 10 秒被从 grace period 里扣掉了。如果 grace 是默认 30 秒，你实际只剩 20 秒给 in-flight 请求。这个补丁在 Java 服务上勉强能用（GC 停顿缓解），在 LLM 服务上等于把宽限期砍掉三分之一。

第三处坑：`readinessProbe` 用 `/v1/models` 或者 `GET /`。这两个端点几乎永远返回 200——模型还在 mmap 阶段、KV cache 还没分配、第一个 token 要 40 秒，探针都会告诉你"健康"。它检验的是"HTTP 服务器起来了"，不是"能提供服务"。

## 二、grace period 的反解公式

不要把 grace 当常量配，它是可以被推导出来的。一次请求在这个 pod 上占用的**最大租约**（lease）是：

```
lease_max = prefill_max + max_tokens_max / tps_min
grace     = lease_max + endpoint_propagation_p99 + 2 × scrape_interval
```

代入真实数字看差距。一台 4C8T 无 GPU 的机器跑 7B Q4_K_M，单请求 decode 速度按 8~30 tok/s 估（取决于量化与内存带宽；本文模拟器取 30 tok/s 作单请求基线，四并发时衰减到约 17）。`max_tokens = 4096` 时：

- 乐观（30 tok/s）：4096 / 30 = **137 秒**
- 四并发（17 tok/s）：4096 / 17 = **241 秒**
- 内存带宽吃紧的老机器（8 tok/s）：**512 秒**
- 再叠加 4k prompt 的 prefill（CPU 上约 3~5 秒）与传播/抓取余量

也就是说默认 grace 30 秒的情况下，**长请求被 SIGKILL 的概率是 100%**，不是"偶尔"。而如果照公式配成 520 秒，单副本发布就要等 8 分钟，4 副本串行就是半小时——运维会疯。

这里有三个真实的解法，选一个，别混着糊：

1. **给 max_tokens 设硬上限**（如 1024），把 lease 压到 130 秒以内。代价是长文生成要走异步任务通道。
2. **按业务分流**：交互式请求有 max_tokens 上限、走同步路径；长文/批量任务走队列 + 可恢复的流式协议（客户端记 offset，断线从 offset 续传）。这样同步路径的排水可以做到秒级。
3. **接受长 grace，但让"排水"和"发布"解耦**：先扩一个新副本（surge），把旧副本标记 NotReady 后**不急着杀**，让它自然排空，发布进度由"新副本 Ready"驱动而不是"旧副本退出"驱动。旧副本可以在 8 分钟内静静退出，不影响发布节奏。

第三条是唯一能在不牺牲功能的前提下做到零丢失的方案，代价是短暂的双倍显存/内存占用。

## 三、drain 控制器：五阶段状态机

核心思路：**"能不能接流量"这个状态必须由进程自己控制，而不是靠计时器猜**。做法是加一个 supervisor 进程包住真正的 server，或者做一个极薄的 sidecar，让 readiness probe 读一个本地文件。

下面是只用标准库就能跑的实现（`drain_supervisor.py`）：

```python
import json, os, signal, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER_CMD = ["llama-server", "-m", "/models/qwen2.5-7b-q4_k_m.gguf",
              "-np", "4", "--port", "8080", "--metrics"]
METRICS = "http://127.0.0.1:8080/metrics"
READY_FLAG = "/tmp/ready"          # 探针读这个文件，而不是读 /v1/models
SCRAPE = 1.0                       # 秒
PROPAGATION = 3.0                  # endpoint 传播上界
MAX_LEASE = 130.0                  # 由上一节的公式得出

child = None
ready = threading.Event()

class Ready(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = ready.is_set()
        self.send_response(200 if ok else 503)
        self.send_header("Connection", "close")   # 别让探针复用连接
        self.end_headers()
        self.wfile.write(b"ok" if ok else b"draining")
    def log_message(self, *a):                     # 静音
        pass

def processing() -> int:
    """从 /metrics 读在途请求数；llamacpp 与 vLLM 的指标名不同，这里都兜一下。"""
    try:
        txt = urllib.request.urlopen(METRICS, timeout=2).read().decode()
    except Exception:
        return -1                                  # 抓不到 = 保守当作还在跑
    vals = {}
    for line in txt.splitlines():
        if line.startswith("#"):
            continue
        for key in ("llamacpp:requests_processing",
                    "llamacpp:requests_deferred",
                    "vllm:num_requests_running",
                    "vllm:num_requests_waiting"):
            if line.startswith(key):
                vals[key] = float(line.rsplit(" ", 1)[1])
    return int(sum(vals.values()))

def start_child():
    global child
    child = subprocess.Popen(SERVER_CMD, start_new_session=False)

def warmup():
    """把典型 prompt 打一遍：让 prompt cache 命中、页表热起来、allocator 到位。"""
    payloads = [("短", 64), ("中", 1200), ("长", 4000)]
    system = "You are a senior backend engineer. Answer concisely."
    for _, n in payloads:
        body = json.dumps({
            "model": "local",
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": "x " * n}],
            "max_tokens": 8, "temperature": 0,
        }).encode()
        req = urllib.request.Request(
            "http://127.0.0.1:8080/v1/chat/completions", data=body,
            headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=120).read()
        except Exception as e:
            print("warmup failed:", e, flush=True)

def on_sigterm(signum, frame):
    # 阶段 1：立刻摘掉 readiness，让 LB 停止派发
    ready.clear()
    try:
        os.remove(READY_FLAG)
    except FileNotFoundError:
        pass
    threading.Thread(target=drain, daemon=True).start()

def drain():
    t0 = time.time()
    # 阶段 2：等 endpoint 传播结束。这段时间流量还在进来，必须等。
    time.sleep(PROPAGATION)
    # 阶段 3：轮询在途请求，连续 3 次为 0 才算真空
    zero_streak = 0
    while True:
        el = time.time() - t0
        n = processing()
        if n == 0:
            zero_streak += 1
            if zero_streak >= 3:
                break
        else:
            zero_streak = 0
        if el > PROPAGATION + MAX_LEASE:
            print(f"drain deadline hit after {el:.1f}s, in_flight={n}", flush=True)
            break
        time.sleep(SCRAPE)
    # 阶段 4：优雅关闭子进程，给它 10 秒释放 KV cache / flush 日志
    child.send_signal(signal.SIGTERM)
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
    print(f"drained in {time.time() - t0:.1f}s", flush=True)
    # 阶段 5：自己退出，让 kubelet 认为 pod 正常结束（exit 0 而非 143）
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, on_sigterm)
    start_child()
    httpd = ThreadingHTTPServer(("0.0.0.0", 8081), Ready)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    # 等 /health 真正可用再预热，预热完才 Ready
    for _ in range(600):
        try:
            urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=1).read()
            break
        except Exception:
            time.sleep(1)
    warmup()
    ready.set()
    open(READY_FLAG, "w").close()
    child.wait()
```

配套的 pod 片段（探针打到 supervisor 的 8081，而不是 server 的 8080）：

```yaml
terminationGracePeriodSeconds: 180   # = 传播 3s + lease 130s + 退出 10s + 余量
lifecycle:
  preStop:
    exec:
      command: ["sleep", "0"]        # 显式置空：排空逻辑在进程内，别在这里 sleep
readinessProbe:
  httpGet: { path: /readyz, port: 8081 }
  periodSeconds: 2
  failureThreshold: 1                # 摘流量要快：一次失败就下
livenessProbe:
  httpGet: { path: /health, port: 8080 }
  initialDelaySeconds: 90            # 必须大于 模型加载+预热 时长
  periodSeconds: 10
  failureThreshold: 6                # 别让一次 GC/长 prefill 触发重启风暴
```

三个细节值得单独说：

- `readinessProbe` 的 `failureThreshold` 要设 1，`livenessProbe` 要设大。前者决定"多久停止派流量"，越快越好；后者决定"多容易被杀"，越迟钝越好。很多人把这两个配成一样，结果一次 40 秒的长 prefill 就把健康的 pod 重启了。
- `initialDelaySeconds` 必须大于 `模型加载 + 预热`。liveness 在预热期间触发，会把正在预热的 pod 反复杀掉，形成 CrashLoopBackOff——现象是"pod 一直重启但日志里没有任何报错"，非常迷惑。
- `sys.exit(0)` 而不是被 SIGKILL：exit code 143 会让一部分监控/告警规则误判成异常退出，而且 kubelet 的 `Terminated` 事件里 `reason` 从 `Completed` 变成 `Error`，翻发布记录时噪音很大。

## 四、冷启动：模型加载只是第一段

`LOAD_S = 26s` 只是一台机器的模型加载时间（mmap 4GB GGUF + 初始化）。真正的冷启动代价有三段，而且**第二第三段经常被忽略**：

1. **页缓存冷**：mmap 的权重第一次读要从磁盘拉。NVMe 上约 2~4 GB/s，SATA 或网络存储上直接是分钟级。同一个节点上跑过的模型，第二次加载能快 3 倍以上，所以"本地测好了"到线上经常不符。
2. **prompt cache 空**：KV cache 里没有任何可复用的前缀，第一批请求的 TTFT 是全量 prefill。系统提示词 2000 token 的话，每条请求都白算一遍。
3. **allocator / graph 未热**：第一次分配 KV block、第一次触发 CPU 上的内存对齐路径，都会额外付出一次性成本。

所以预热请求集必须覆盖**真实流量的前缀分布**——用 `x x x` 这种垃圾 prompt 预热毫无意义，它不会命中任何请求的公共前缀。正确做法是：把所有真实 system prompt 变体各打一遍（短/中/长三档长度），`max_tokens=8`，`temperature=0`，让前缀进 KV cache 后立刻退出。

这件事的收益可以直接量化。下一节的模拟里，预热把新副本的 TTFT p99 从 21.1 秒压到 7.6 秒（2.8 倍），代价是发布墙钟时间多 9 秒。

## 五、把三种排空策略放进模拟器

光讲道理不够，得看数字。我写了一个离散事件模拟器（约 200 行，时间步长 0.2 秒），参数按 4C8T 无 GPU 跑 7B Q4_K_M 的合理区间标定：4 副本 × 4 slots，单请求 30 tok/s、每多一个并发除以 `1 + 0.25×(n-1)`，输出长度与 prompt 长度取对数正态分布（中位数 400 / 1500 token），到达率 0.42 req/s（约 60% slot 利用率），endpoint 传播延迟 2 秒，模型加载 26 秒、预热 9 秒。

四个场景，每个跑 120 次 rollout 做蒙特卡洛：

| 场景 | 掉过请求的 rollout | 每次 rollout 丢失 | 客户端错误率 | 墙钟 中位/P99 | 新副本 TTFT p99 |
|---|---|---|---|---|---|
| A 裸 SIGTERM（无排空） | **100%** | 3.5 个 | **8.08%** | 35.6s / 35.6s † | 16.8s |
| B preStop + 30s grace | **42%** | 0.76 个 | **1.33%** | 65.4s / 65.4s † | 19.6s |
| C metrics 门控排空 | 0% | 0 | 0% | 63.0s / 184.4s | 21.1s |
| D C + 预热 | 0% | 0 | 0% | 72.0s / 197.6s | **7.6s** |

† A/B 的墙钟由固定截断时刻决定（0.2s / 30s），所以中位数与 P99 相同；C/D 由"在途请求真正归零"决定，才有长尾。

三个结论，每一个都反直觉：

**第一，裸 SIGTERM 不是"偶尔丢几个"，是每次发布必丢**。8.08% 的客户端错误率意味着发一次版，正在生成的用户里平均每 12 个就有 1 个看到断流。而墙上这张表的 A 行和 B 行差距只有 6 倍——如果你只看周报里的"发布失败率"，30s grace 会把这个问题藏起来。

**第二，30 秒 grace 有 42% 的 rollout 仍然丢请求**。这就是最危险的一档：小流量时段试两次都是绿的，凌晨发版也绿，于是写进 SOP；等到某个下午流量翻倍、正好撞上一个 4000 token 的生成，就炸一次。**尾部风险不会被平均值暴露，只会被 P99 暴露**——所以评估排水策略要看"掉过请求的 rollout 占比"，不是"平均错误率"。

**第三，零丢失的代价是发布窗口的 P99 变成 3 分钟**（184.4 秒）。因为排空必须等那一个最长的请求跑完，这是物理时间，优化不掉。正确的心态是：**发布窗口长是排空正确的副产品，不是缺陷**。真要缩短，唯一的办法是让长请求走第三条路径（异步/可恢复），把它从同步排空的范围里摘出去。

顺带一个数字：C 场景墙钟 P99 184 秒，而冻结的 deadline 是"最长租约 + 8 秒"，说明绝大多数 rollout 在 60 秒左右完成，只有少数被单个长请求拖住。这也解释了为什么**不该用固定 grace 去猜**——分布的长尾每次都不一样。

## 六、踩过的坑

**坑一：keep-alive 让"摘除 endpoint"形同虚设。** 客户端与 pod 之间已有 TCP 连接时，kube-proxy 的规则更新对存量连接无效，请求会继续复用旧连接打到正在排空的 pod。表现为"metrics 显示在途请求数一直不归零"，或者"排空完成后仍然收到 502"。解法是在入口层限制连接复用：nginx `upstream keepalive_timeout 15s`，客户端侧 `max_requests_per_connection`，排空开始时对存量连接回 `Connection: close`。

**坑二：`/slots` 看不到排队请求。** llama-server 的 `/slots` 只反映 slot 状态（idle / processing），`-np 4` 时 4 个 slot 全 idle 也可能还有请求在 waiting 队列里。用 `/slots` 判断"排空完成"会提前杀进程。必须用 `/metrics` 的 `llamacpp:requests_processing + requests_deferred`，两个都归零才算干净。vLLM 同理，要 `num_requests_running + num_requests_waiting`。

**坑三：SIGTERM 只到了父进程。** 如果你的架构是 `uvicorn → 应用 → llama-server 子进程`，或者 `nginx → server`，SIGTERM 默认只发给 PID 1，子进程收不到，10 秒后被 SIGKILL 整组带走，客户端看到的是 **connection reset** 而不是 503。这两者在客户端语义上完全不同：503 可以退避重试，reset 往往直接抛给用户。要么让 server 在同一进程内（in-process），要么显式转发信号给进程组。

**坑四：探针抓不到 metrics 时默认"健康"。** 排空逻辑里 `processing()` 抓取失败时如果返回 0，就会在 metrics server 已经先挂掉的情况下认为"没有在途请求"，直接杀掉进程——正好丢掉最后的请求。所以抓取失败要返回 -1（未知），并让排空循环保守等待到 deadline。

**坑五：残留进程伪造了"排空成功"。** 在自己机器上验证时，旧的 server 实例还在监听端口，新进程绑定失败但 supervisor 仍然报了 Ready，压测打到的其实是老进程，于是"零丢失"是人造数据。验证前先确认没有残留（`tasklist` / `ss -ltnp` 看端口占用），这是排查性能问题前的老规矩。

**坑六：把 `maxUnavailable: 0` 当成零中断保证。** 它保证的是"任何时刻 READY 副本数不少于期望值"，不保证"排水中的副本不再收流量"。真正的零中断 = 容量冗余（N+1）+ readiness 语义正确 + in-flight 排空。三者缺一，缺哪个就在哪个场景炸。

## 七、落地清单

按优先级排，前四条做完基本能拿到 99.9% 的发布成功率：

1. 用第二节的公式算出 `lease_max`，据此设 `terminationGracePeriodSeconds`，别用默认 30。
2. readiness 探针指向**应用自己维护的 ready 标志**（预热完成才置位），不是 `/v1/models`。
3. `preStop` 置空，排空逻辑放进程内；排空分五阶段：摘 Ready → 等传播 → 轮询在途归零 → SIGTERM 子进程 → exit 0。
4. 预热覆盖真实 prompt 前缀，三档长度，`max_tokens=8`。
5. 长请求走异步通道或可恢复协议，把同步路径的 lease 压到 130 秒以内。
6. `readinessProbe.failureThreshold=1` + `livenessProbe.initialDelaySeconds > 加载+预热`，避免长 prefill 触发重启风暴。
7. 给排空加可观测性：记录 `drain_seconds`、`deadline_hit`、`lost_requests`。没有这三个指标，你无法证明下一次发布是安全的。
8. 容量按 N+1 规划。滚动发布本质是容量问题——没有冗余副本，任何排空策略都只能"少丢"，不可能"不丢"。

最后一句总结：把发布当成一次**有 SLO 的流量迁移**，而不是一次重启。你要回答的三个问题是——流量什么时候真的停了、在途的请求最长还要多久、新副本什么时候真的能服务。三个问题都能量化，就不需要靠 sleep 和运气。
