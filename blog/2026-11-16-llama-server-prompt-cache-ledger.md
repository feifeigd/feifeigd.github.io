---
title: "KV Cache 命中率才是 CPU 推理的 TTFT 主开关 — llama-server prompt cache 实测账本"
date: 2026-11-16T18:00:00+08:00
draft: false
tags: ["llm", "inference", "kv-cache", "llama-cpp", "performance"]
categories: ["Tech"]
description: "在 4 线程 CPU 上用 llama.cpp 实测 prompt cache：1193 token 的前缀，冷启动 3.0 秒、命中 10.5 毫秒；顺手把 n_ctx_slot 怎么被 -np 吃掉、kv_unified 为什么让 4 个会话互相踩、KV 每 token 到底吃多少内存全部量了一遍。"
---

前段时间把一台 4C8T 的 CentOS 7 机器改成团队的私有补全后端，`llama-server` 挂 DeepSeek-Coder-V2-Lite 的 Q4_K_M，端口 8081，桌面一个隧道 bat 指过来，日常写代码够用。真正让人难受的不是吞吐，而是 **TTFT 抖动**：同一个 system prompt、同一份 6 KB 的代码上下文，有时候 300 毫秒出第一个字，有时候三秒还没动静。

我一开始以为是 CPU 太弱，后来把 llama.cpp 的 `timings` 打开才发现，问题不在算力，在 **前缀缓存有没有命中**。这篇文章把账算清楚：命中时省了多少、`-np` 怎么把 `-c` 切成碎片、`kv_unified` 为什么让四个会话互相踩 KV、以及 KV 每个 token 到底多少字节（实测值和公式对得上，误差 0.4%）。

所有数字都来自一台真实机器，不是抄文档。

{/* truncate */}

## 一、先把测量口径钉死

llama.cpp 的 `/completion` 返回里有个 `timings` 对象，其中四个字段决定了你能不能判断"缓存有没有生效"：

```json
{
  "timings": {
    "cache_n": 1193,
    "prompt_n": 1,
    "prompt_ms": 10.5,
    "prompt_per_second": 95.1
  }
}
```

- `cache_n`：这次请求从 KV 缓存里**复用了多少 token**。
- `prompt_n`：这次**真正需要重新算**的 token 数。
- `prompt_ms`：prefill 阶段耗时——注意它**包含排队时间**，并发场景下不能直接拿来算 prefill 吞吐。
- `prompt_per_second` 由 `prompt_n / prompt_ms` 算出，`prompt_n=1` 时这个数字毫无意义（10.5 毫秒算 1 个 token 会显示 95 tok/s，纯噪声）。

判据只有一个：**`cache_n` 和 `prompt_n` 的比例**。判断墙钟时间会被页缓存、权重预热、调度排队污染。

下面这段客户端我用来跑完全部实验，只依赖标准库，直接对着 `llama-server` 打：

```python
import json, time, urllib.request

def post(host, path, obj, timeout=900):
    req = urllib.request.Request(f"http://{host}{path}",
                                 data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode())
    return body, time.time() - t0

def toklen(host, text):
    return len(post(host, "/tokenize", {"content": text})[0]["tokens"])

def ask(host, prompt, cache_prompt=True, n_predict=1):
    body, wall = post(host, "/completion", {
        "prompt": prompt,
        "n_predict": n_predict,      # 只要 TTFT，不需要生成
        "temperature": 0.0,
        "cache_prompt": cache_prompt,
        "stream": False,
    })
    t = body["timings"]
    return {
        "cache_n":   t["cache_n"],
        "prompt_n":  t["prompt_n"],
        "prompt_ms": round(t["prompt_ms"], 1),
        "wall_ms":   round(wall * 1000, 1),
    }
```

`n_predict=1` 很关键：生成 1 个 token 就返回，decode 阶段被压到忽略不计，量到的就是纯 prefill。想要更准可以再减到 0（部分版本不支持），`n_predict=1` 是最稳的折中。

## 二、实验环境

| 项目 | 配置 |
|------|------|
| CPU | 8 vCPU / 4 线程（超线程已实测为负收益，只给 `-t 4`） |
| 内存 | 30 GB，无 GPU |
| OS / 运行时 | CentOS 7.9 + nerdctl 2.3.5，容器 `--network host` |
| llama.cpp | 0.3.0-dev，commit `d7a2074`，local build |
| 模型 | SmolLM2-135M-Instruct Q4_K_M（实验用，加载 0.3 秒） |
| KV 精度 | 默认 f16 |

选 135M 不是为了测性能，是为了**让 prefill 成本落在可观测区间**：135M 在这台机器上 prefill 约 400–550 tok/s，一次 1200 token 的冷启动 2.5–3 秒，正好和真实场景里的大模型"比例一致"——大模型 prefill 更慢，但**缓存命中带来的相对收益几乎是常数**，这是 KV 复用的本质：省掉的是 O(n²) 里已经算过的那部分。

生产上的 `llama-server` 是 `-c 8192 -t 4 --port 8081`，没有写 `-np`。这个"没写"后面埋了一个大坑，第五节讲。

## 三、命中一次，省掉 99.6% 的 prefill

同一个 1193 token 的 prompt（一段重复的 Python 函数体，模拟长 system prompt + 代码上下文），连着发四次，前两次关掉 `cache_prompt`，后两次打开：

| 次序 | cache_prompt | cache_n | prompt_n | prompt_ms |
|------|--------------|---------|----------|-----------|
| 1 | false | 0 | 1193 | 3005.8 |
| 2 | false | 0 | 1193 | 2173.5 |
| 3 | true | 1193 | 1 | 10.5 |
| 4 | true | 1193 | 1 | 8.6 |

两个结论，第二个比第一个重要：

1. **命中后 10.5 ms，冷启动 3005 ms，286 倍**。TTFT 从"肉眼可感"直接掉到"不存在"。
2. **第 2 次 `cache_prompt=false` 比第 1 次快了 28%（2173 vs 3006），但 `cache_n` 还是 0**。如果只看墙钟时间，很容易得出"缓存已经在工作"的错误结论——实际那 833 毫秒来自 mmap 权重被内核页缓存接住、CPU 频率爬满。**这就是为什么必须看 `cache_n` 而不是看耗时**。反过来说，任何"我加了缓存但没变快"的排查，先看 `cache_n` 是不是 0，再谈别的。

顺手做了一组对照：两个 token 序列只在**最后两个 token** 不同（`// tag: A` 对 `// tag: B`），各 1193 token：

```text
A#1  cache_n=0     prompt_n=1193  prompt_ms=2531.0
B#1  cache_n=1191  prompt_n=2     prompt_ms=14.1
A#2  cache_n=1191  prompt_n=2     prompt_ms=13.0
B#2  cache_n=1191  prompt_n=2     prompt_ms=13.2
```

`cache_n=1191` 意味着匹配走的是**最长公共前缀**，不是"整个 prompt 全等"。这条性质决定了工程里唯一正确的写法：**稳定内容放最前，易变内容放最后**。把时间戳、request_id、随机排序的检索结果拼在 system prompt 前面，等于每次请求都亲手把缓存打掉。

再看真正不共享前缀的情况（两个 prompt 从第 1 个 token 就不同，各 1769 token，单 slot）：

```text
A#1  cache_n=0     prompt_n=1769  prompt_ms=4237.7
B#1  cache_n=3     prompt_n=1766  prompt_ms=4686.6
A#2  cache_n=1768  prompt_n=1     prompt_ms=38.3
B#2  cache_n=1768  prompt_n=1     prompt_ms=13.4
```

注意 `A#2` 和 `B#2` **都命中了**——只有 1 个 slot 的情况下，两个互不相干的长 prompt 依然各自被缓存住了。这是新版 llama.cpp 的行为：`--cache-ram`（默认 8192 MiB）把空闲 slot 的状态存到 host 内存，下次请求来了按 token 序列去比。**"slot 数 = 能缓存的会话数"是旧结论，在这一版上不成立**（第六节还有一条更反直觉的对照实验）。

## 四、多轮对话：省掉的正好是"上一轮的全部"

真实场景不是重复同一个 prompt，而是**每轮在末尾追加**。构造一个 594 token 的 system prompt，然后每轮追加约 200 token：

| 轮次 | cache_n | prompt_n | prompt_ms | 墙钟 |
|------|---------|----------|-----------|------|
| turn1 | 0 | 594 | 1065.6 | 1118.8 |
| turn2 | 594 | 201 | 558.9 | 618.5 |
| turn3 | 795 | 201 | 519.1 | 583.5 |
| turn4 | 1003 | 194 | 521.2 | 583.3 |

`prompt_n` 稳定在 200 上下，`cache_n` 单调上涨——每轮只重算新增的那一段。第 4 轮的 prompt 总共 1197 token，如果不缓存需要约 2.1 秒（按 550 tok/s），实际 0.52 秒。

这张表还解释了一个常见错觉："多轮对话越聊越慢"。**命中的情况下每轮成本是常数**（~520 ms，只看新增 token），不命中的情况下才是线性恶化。如果线上观察到第 10 轮突然慢到几秒，八成是**上下文被截断/压缩**了：一旦中间某段被删掉，公共前缀就断在那里，后面全部重算。所以上下文压缩策略（滑动窗口、摘要）必须作用在**尾部**，或者接受"压缩一次，全量重算一次"的代价——不要做成每轮都微调头部。

## 五、`-np` 把 `-c` 切成碎片，`kv_unified` 又把它糊起来

这是这次实测里最有价值的一组，因为它直接影响线上配置，而文档里几乎没人把两者放一起讲。

llama.cpp 的 `-c/--ctx-size` 是**整个 KV 池的总大小**，`-np/--parallel` 是 slot 数。显式给了 `-np`，`kv_unified=false`，池子按 slot 平分：

```text
# -c 2048 -np 4
n_slots = 4, n_ctx_slot = 512, kv_unified = 'false'
GET /slots -> [{'n_ctx': 512}, {'n_ctx': 512}, {'n_ctx': 512}, {'n_ctx': 512}]

POST /completion (2000 token 的 prompt)
{"error":{"code":400,
  "message":"request (2000 tokens) exceeds the available context size (512 tokens), try increasing it",
  "type":"exceed_context_size_error","n_prompt_tokens":2000,"n_ctx":512}}
```

**`-c 2048 -np 4` 意味着每个会话只有 512 token 的上下文**，任何真实请求直接 400。想给每个 slot 2048，得写 `-c 8192 -np 4`：

```text
-c 8192 -np 4  ->  n_ctx_slot = 2048
```

四个 1193 token 的请求同时打进去（刚好都塞得下 2048/slot）：

| 请求 | cache_n | prompt_n | prompt_ms | 墙钟 |
|------|---------|----------|-----------|------|
| req0 | 1192 | 1 | 3539.0 | 7372.5 |
| req1 | 0 | 1193 | 7369.3 | 7372.6 |
| req2 | 0 | 1193 | 3538.8 | 7371.9 |
| req3 | 0 | 1193 | 3829.7 | 3833.6 |

三点必须说清楚：

1. **4 路并发总墙钟 7.37 秒，单发 2.67 秒——吞吐只提升 1.4 倍，延迟劣化 2.8 倍**。CPU 上 4 个线程被 4 个 slot 抢，prefill 并行度没有提升，只有调度开销。CPU 上并发的主要价值是**掩盖 decode 期间的算力空转**（等用户输入、等工具返回），不是提升吞吐。
2. **`req0` 的 `prompt_n=1` 却花了 3539 毫秒**——这 3.5 秒全是排队。所以 `prompt_ms` 不能当 prefill 性能指标用，这个坑值得写进监控脚本的注释里。
3. **四个请求的 prompt 完全一样，只有一个吃到 `cache_n` 复用**。原因是它们同时进来，最早的那个还没把 KV 写进去，其余三个已经开始算了。想做"同一批离线任务去重",得让它们**串行**或者提前预热一次。

再看生产机：`-c 8192 -t 4`，**没写 `-np`**。日志里是这样的：

```text
n_slots = 4, n_ctx_slot = 8192, kv_unified = 'true'
```

`-np` 是 auto（`-1`）时，llama.cpp 走 **unified KV**：4 个 slot 共享同一个 8192 token 的池子，`/slots` 里报的 `n_ctx=8192` 是**每个 slot 的上限**，不是"独占 8192"。四个 slot 同时写也超不过 8192 总量。所以：

| 配置 | n_slots | 每 slot 上限 | 总池 | 4 个 5k token 会话 |
|------|---------|--------------|------|--------------------|
| `-c 8192`（auto np） | 4 | 8192 | 8192 | 放不下，KV 逐出 + 重算 |
| `-c 8192 -np 4` | 4 | 2048 | 8192 | 各自 2048，长会话直接 400 |
| `-c 32768 -np 4` | 4 | 8192 | 32768 | 放得下 |

这张表是给"为什么两个会话一起用就卡"的最好解释：unified 模式下，长会话互相挤占 KV，被挤掉的部分下次请求要**重新 prefill**——表现就是延迟忽高忽低、`cache_n` 忽大忽小。**如果你在 unified 模式上看到 `cache_n` 明显缩水，那不是缓存坏了，是池子不够。**

## 六、KV 每个 token 吃多少内存：实测和公式对得上

调 `-c` 之前得知道每个 token 要多少内存。公式（GQA / MHA 通用）：

```text
KV_bytes_per_token = n_layer × n_kv_embd × 2 × bytes_per_elem
                     ↑层数    ↑K/V 头数×head_dim  ↑K和V   ↑f16=2, q8_0≈1.06
```

用 RSS 实测校准（SmolLM2-135M，`--cache-ram 0` 关掉 prompt cache 干扰，只留 KV）：

| -c | RSS (KB) |
|----|----------|
| 1024 | 163,216 |
| 2048 | 186,140 |
| 4096 | 232,376 |
| 8192 | 324,720 |

差分非常干净：每多 1024 token 涨 22.4 / 22.6 / 22.6 MB，即 **22.6 KB/token**。公式算：30 层 × 192（3 KV head × 64）× 2（K+V）× 2 字节 = 23,040 B = 22.5 KB。**误差 0.4%**，说明没有隐藏开销，可以直接拿公式做容量规划。

套到真实模型上（f16）：

| 模型 | 结构 | KV/token | 8192 ctx | 32k ctx |
|------|------|----------|----------|---------|
| SmolLM2-135M | 30 层，3 KV head × 64 | 22.5 KB | 180 MiB | — |
| Qwen2.5-Coder-7B | 28 层，4 KV head × 128 | 56 KB | 448 MiB | 1.75 GiB |
| DS-Coder-V2-Lite | 27 层，MLA（512+64） | 30.4 KB | 243 MiB | 973 MiB |

最后一行的对比最有意思：**V2-Lite 是 16B 总参数量，KV 每 token 只比 7B 的 Qwen 少一半还多**。MLA 把 KV 压成 `kv_lora_rank + qk_rope_dim` 的隐向量，**与 head 数彻底解耦，只随层数线性增长**。这就是为什么一台 30 GB 的 CPU 机器敢开 8192 上下文还留得住余量：模型权重 7.9 GB RSS，KV 才 243 MiB。换成同规模的 MHA 模型，KV 会是 4~8 倍，池子立刻成为瓶颈。

想再省，`-ctk q8_0 -ctv q8_0` 把 KV 量化到 8 bit，直接省一半；代价是长上下文下注意力分数轻微漂移，7B 以下的小模型实测差异可忽略，写代码这种高确定性任务基本看不出来。

## 七、踩坑清单

按被坑的先后顺序：

1. **`-c` 是总池不是每槽**。写 `-c 2048 -np 4` 等于每会话 512 token，真实请求全 400。要么 `-c 8192 -np 4`，要么干脆别写 `-np` 走 unified。
2. **`-c` 超过模型 max_position 会被静默 clamp**。我试 `-c 16384`（SmolLM2 上限 8192），日志里 `n_ctx_slot = 8192`，不报错、不警告。容量规划算错时你会以为池子翻倍了。
3. **显式 `-np` 会让 `kv_unified=false`**，行为从"共享池"变成"平分池"，同一份 `-c` 的含义彻底变了。改 `-np` 必须同时重算 `-c`。
4. **`cache_prompt=false` 的第二次也比第一次快**（2173 vs 3006 ms），别把这 28% 当成缓存生效。判据永远是 `cache_n`。
5. **`prompt_ms` 含排队时间**。并发下 `prompt_n=1` 也可能报 3539 ms，用它算 prefill 吞吐会得出荒谬结论。
6. **单 slot 不等于只能缓存一个会话**。`--cache-ram`（默认 8192 MiB）会把空闲 slot 状态存到 host 内存，不同 prompt 都能恢复；就算 `--cache-ram 0 --no-cache-idle-slots`，我实测交替发两个只差末尾 token 的长 prompt 也照样命中（1191/1193）。所以"缓存被打掉"的排查不能靠 slot 数推，只能看 `cache_n`。
7. **稳定内容必须放最前**。检索结果、时间戳、request_id 拼在头部等于每次全量重算。多轮对话里做上下文压缩时同样：动头部＝全废，动尾部＝只重算尾部。
8. **`-t` 别超过物理核**。这台机器 4C8T，`-t 8` 实测比 `-t 4` 慢，超线程在 prefill 这种纯 SIMD 稠密计算上是负收益。

## 八、配置怎么定

回到最初的问题：TTFT 抖动。按上面这些账，我要把线上配置从裸的 `-c 8192` 改成：

```text
-c 16384 -np 2 -t 4 --cache-ram 2048
```

- `-c 16384 -np 2` → 每会话 8192 上限，两个并发会话互不挤占。比原来的 unified 8192 更好推理：池子边界是静态的，不会因为另一个会话变长而把你这边的 KV 挤出去。
- `--cache-ram 2048` → 2 GB host 内存做跨 slot 的 prompt cache，够存几十个会话前缀。不沿用默认 8192 是因为这台机器只有约 4 GB 空闲，prompt cache 把页缓存挤掉之后，重新 mmap 权重反而更慢——这是个典型的"缓存打架"，两个缓存都在抢同一块内存。
- KV 预算：8192 × 30.4 KB ≈ 243 MiB/slot，两槽不到 500 MiB；加上 7.9 GB 权重，30 GB 机器余量充足。

预期收益可以按实测外推，不用拍脑袋：8192 token 的前缀在这台机器上冷启动约 2.4 秒（135M 实测 550 tok/s，V2-Lite 的 prefill 更慢但同量级），命中后 `prompt_n` 只剩余量 token，落在 10~40 毫秒区间。也就是说 TTFT 的抖动来源被彻底拆掉——**剩下的抖动只可能来自 decode 和排队，而这两者在监控里是能分开看的**（`prompt_ms` 减排队时间、`predicted_ms` 各自独立）。这才是可运维状态：出问题时你知道该查哪一段，而不是对着一个 2 秒和 3 秒之间随机跳的数字干瞪眼。

一句话总结：**在 CPU 上做 LLM 服务，KV 复用不是优化项，是主开关**。它省的不是算力，是把"已经算过的 token"从 O(n²) 的注意力里摘出来的那部分重复劳动；而这条路径能不能走通，取决于三件事——前缀是否稳定、`-c` 和 `-np` 有没有配对、`kv_unified` 开没开。三件事里任何一件搞错，你都会看到"缓存配了但没用"，然后去怀疑模型、怀疑 CPU、怀疑框架，唯独不会怀疑自己把 `-c 8192 -np 4` 写成了每槽 2K。
