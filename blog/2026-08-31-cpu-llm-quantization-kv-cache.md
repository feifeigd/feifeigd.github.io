---
title: "30GB 内存 4 核 CPU 上跑 16B MoE：GGUF 量化与 KV Cache 的实战调优账本"
date: 2026-08-31T16:30:00+08:00
draft: false
tags: ["llm", "inference", "quantization", "kv-cache", "llama-cpp", "infra", "performance"]
categories: ["Tech"]
description: "一台 30GB 内存、4 核 8 线程、无 GPU 的 K8s worker 上跑 llama-server 给 IDE 用的实战记录：Q4_K_M 为什么是甜点位、KV Cache 每 token 多少字节怎么算、MLA 比 MHA 省多少、为什么 4 核 CPU 上 prefill 比 decode 还慢、KV cache 满载时的日志级联长什么样。全部有实测数字。"
---

公司那台 K8s worker 是台「三无」机器：无 GPU、4 核 8 线程（AMD EPYC 9754）、30GB 内存，CentOS 7 + nerdctl，还要兼顾集群负载。我在上面用 llama-server 跑了一个给 IDE 用的代码补全/问答服务，模型从 16B 的 DeepSeek-Coder-V2-Lite 到 135M 的 SmolLM2 随意切换。这篇把选型账本和踩坑记录写下来：**量化怎么选、KV Cache 每个 token 到底吃掉多少内存、CPU 上 prefill 为什么比 decode 还慢、KV cache 满载时日志长什么样**。上一篇讲了 [CentOS 7 + nerdctl 编译 llama.cpp 的完整流程](/blog/llama-cpp-centos7-nerdctl-build)，这篇是运行期的优化。GPU 侧的理论对比（Continuous Batching、PagedAttention）见 [vLLM 推理面试题](/blog/2026/08/29/vllm-inference-interview)，[投机解码](/blog/2026/08/24/speculative-decoding) 是另一条优化路线，这里只谈 CPU 上最现实的三个杠杆：量化、KV Cache、并发槽位。

{/* truncate */}

## 一、量化：Q4_K_M 为什么是甜点位

llama.cpp 用 GGUF 格式存权重，量化单位是「块」（block）：把一组权重打包，块内共享 scale/offset，比逐元素量化省得多。当前主流是 k-quants 家族（Q4_K / Q5_K / Q6_K），按张量角色混合精度：注意力权重用更宽的量化、FFN 用更窄的，整体质量损失大约只有同比特数旧格式（q4_0）的一半。更高端还有 i-quants（IQ2/IQ3/IQ4），用重要性矩阵（importance matrix）把信息量低的权重压得更狠，能在接近 Q4 的体积下逼近 Q5 的质量，但解码速度略慢、加载更慢，CPU 场景不划算。

社区基准（llama.cpp 各模型页的困惑度测试）大致是这个量级：相比 FP16，Q8_0 的困惑度损失约 0.02、可忽略；Q5_K_M 约 0.15；Q4_K_M 约 0.3~0.5；Q3_K 开始明显（超过 1）。换算到实际任务，Q4_K_M 相比 FP16 在代码生成这类任务上的准确率掉点通常在一个百分点以内——对 IDE 补全来说完全无感。

内存账本才是关键。我机器上三个模型的实际文件大小：

| 模型 | 参数量 | Q4_K_M 文件 | 加载后 RSS |
|------|--------|-------------|-----------|
| DeepSeek-Coder-V2-Lite | 16.7B（MoE，2.4B 激活） | 10.36 GB | 约 8 GB |
| Qwen2.5-Coder-7B | 7.6B | 4.68 GB（两个分片） | 约 4.7 GB |
| SmolLM2-135M | 0.14B | 105 MB | 约 0.2 GB |

注意 16B 模型 Q4_K_M 就要 10.36GB——因为量化压缩的是**所有权重**，MoE 的专家参数一个都跑不掉，总参数 16.7B × 约 0.5 字节/参数 ≈ 8.4GB，加上 embedding 和中间张量就是 10GB 量级。机器上 `free -g` 显示 30GB 总量、日常已用 24GB、可用只有 4GB——这决定了**这台机器同时只能常驻一个 16B 模型**，所以切换模型必须做成「优雅停止再启动」，见第五节。

**结论：无 GPU、内存吃紧的机器，Q4_K_M 就是甜点位**——体积和质量的平衡最好，解码速度也快（块尺寸 256，反量化开销小）。Q5_K_M 只在内存有余量且质量敏感（比如做评估集）时用；Q8_0 对权重来说是浪费，同样的字节数不如拿去给 KV Cache 用。

## 二、KV Cache：每 token 多少字节，一行公式算清楚

KV Cache 是推理时的隐藏内存大户。它存的是每个历史 token 的 K/V 张量，随上下文线性增长，而且**在启动时就按最大上下文一次性分配**，不管用不用得完。公式：

```
每 token KV 字节 = 层数 × 每层每 token 元素数 × 每元素字节
每层每 token 元素数：
  GQA/MHA: n_kv_heads × head_dim × 2（K 一份 + V 一份）
  MLA:     2 × kv_lora_rank + qk_rope_head_dim（K 潜变量 + V 潜变量 + K 的 RoPE 分量）
```

DeepSeek 系模型的 MLA（Multi-head Latent Attention）是个大杀器：不存完整的 K/V，而是先压缩成一个低秩潜变量再缓存，推理时用一个小矩阵展开。拿 DeepSeek-Coder-V2-Lite 算：27 层、kv_lora_rank=512、qk_rope_head_dim=64，FP16 下每 token 是 27 × (2×512+64) × 2 字节 ≈ 57.4 KiB。如果它用传统的 32 头 MHA，这个数字是 27 × 32×128×2 × 2 ≈ 432 KiB——**MLA 省了 7.5 倍**。有意思的是，这个数字恰好和 Qwen2.5-Coder-7B（GQA，4 个 KV 头）的 56 KiB/token 打平——也就是说 MLA 和 GQA-4 在 KV 压缩上殊途同归，都远好于 MHA。

下面这段 Python 可以直接跑，从 config.json 或内置参数算任意模型的 KV 内存（我在文章里引用的数字都由它算出）：

```python
#!/usr/bin/env python3
"""KV cache 内存计算器 — 从 config.json 或内置参数算每 token KV 字节数"""
import json

MODELS = {
    "qwen2.5-coder-7b": dict(n_layers=28, n_kv_heads=4, head_dim=128, kv_lora_rank=None, rope_dim=32),
    "ds-coder-v2-lite": dict(n_layers=27, n_kv_heads=32, head_dim=128, kv_lora_rank=512, rope_dim=64),
}

def kv_bytes_per_token(m, cache_dtype_bytes):
    if m["kv_lora_rank"]:  # MLA：K 潜变量 + V 潜变量 + K 的 RoPE 分量
        per_layer = 2 * m["kv_lora_rank"] + m["rope_dim"]
    else:                  # GQA/MHA：完整 K + V
        per_layer = m["n_kv_heads"] * m["head_dim"] * 2
    return m["n_layers"] * per_layer * cache_dtype_bytes

def report(name, m):
    print(f"=== {name} ===")
    for label, b in (("FP16", 2), ("Q8_0", 1)):
        per_tok = kv_bytes_per_token(m, b) / 1024
        print(f"  [{label}] {per_tok:6.1f} KiB/token")
        for ctx in (2048, 8192, 32768):
            per_slot = per_tok * ctx / 1024
            print(f"    ctx={ctx:>6}: {per_slot:7.1f} MiB/槽, 4 槽 = {per_slot*4:7.1f} MiB")

for n, m in MODELS.items():
    report(n, m)

# 也可直接喂 config.json：
# c = json.load(open("config.json"))
# m = dict(n_layers=c["num_hidden_layers"],
#          n_kv_heads=c.get("num_key_value_heads", c["num_attention_heads"]),
#          head_dim=c.get("head_dim", c["hidden_size"] // c["num_attention_heads"]),
#          kv_lora_rank=c.get("kv_lora_rank"), rope_dim=c.get("qk_rope_head_dim", 64))
```

关键输出（FP16 缓存、单槽）：

| 模型 | KiB/token | ctx=8192 单槽 | ctx=8192 × 4 槽 |
|------|-----------|---------------|-----------------|
| Qwen2.5-Coder-7B | 56.0 | 448 MiB | 1.75 GiB |
| DS-Coder-V2-Lite | 57.4 | 459 MiB | 1.79 GiB |

llama-server 默认**每槽按 -c 全量分配**，`-np 4`（默认）就是 4 份。我这台机器常驻一个 16B 模型已经占掉 8GB，再给 KV 划 1.8GB，加上系统和其他容器，可用内存就剩不下多少了——所以我实际用的是 `-np 4 -c 8192` 但把 KV 缓存量化打开：

```
-c 8192 -t 4 --port 8081 -ctk q8_0 -ctv q8_0
```

`-ctk/-ctv` 把 K/V 缓存从 FP16 压到 Q8_0，每 token 从 2 字节降到 1 字节，**KV 内存直接减半**（上表 Q8_0 一列），而 Q8_0 对 KV 缓存质量的影响实测几乎测不出来（KV 的量化误差被注意力 softmax 吸收掉了，社区共识是 KV 用 Q8 无感知、Q4 才开始有可测损失）。如果你的构建支持，这是性价比最高的一行配置。注意：MLA 架构的 KV 量化支持取决于 llama.cpp 版本，先 `llama-server --help` 确认，老版本只支持 GQA/MHA 模型。

## 三、实测性能：prefill 比 decode 还慢，MoE 是罪魁

直接上实测。对运行中的服务发一个 `/completion` 请求，llama.cpp 返回的 `timings` 字段就是最准的指标，一个 30 行的 Python 客户端（文章所有数字都来自它）：

```python
import json, urllib.request

def generate(prompt, n=128, base="http://127.0.0.1:8081"):
    req = urllib.request.Request(
        base + "/completion",
        data=json.dumps({"prompt": prompt, "n_predict": n,
                         "cache_prompt": False}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        d = json.load(r)
    t = d["timings"]
    return (t["prompt_per_second"], t["predicted_per_second"], d["content"])
```

DeepSeek-Coder-V2-Lite Q4_K_M、ctx 8192、4 线程，多次实测：

| 指标 | 实测值 |
|------|--------|
| decode 速度 | 2.4 ~ 3.8 token/s（67 token 用时 27.9s / 34 token 用时 8.7s） |
| prefill 速度（7~9 token 的短 prompt） | 0.5 ~ 0.9 token/s |
| 单请求端到端（128 token 生成） | 30 ~ 60 秒 |

decode 2.4~3.8 token/s 对 16.7B 参数的 Q4 模型在 4 核 CPU 上是正常水平——decode 是访存密集型，瓶颈在内存带宽。真正反直觉的是 **prefill 竟然比 decode 还慢**：7 个 token 的 prompt 花了 13 秒。原因在 MoE：Dense 模型 prefill 把整批 prompt 并行喂给同一个 FFN，batch 越大越划算；而 MoE 每个 token 要路由到不同的专家，7 个 token 就是 7 次路由，每层要跑 6 个活跃专家 × 7 个 token = 42 次专家前向，CPU 上专家计算基本是串行排队。**所以 CPU + MoE 的 prefill 对 prompt 长度极其敏感，短 prompt 的「固定开销」很高**。

这直接改变了服务形态的取舍：

- 短 prompt 多次往返（聊天式 IDE 插件、每轮都重发历史）在这台机器上是灾难——每次往返都付一次昂贵的 prefill；
- 长上下文单次生成反而相对划算（prefill 摊销 + KV Cache 命中）；
- 用 `cache_prompt: true` 并配合 prompt 缓存（llama.cpp 按前缀复用 KV），连续追问能跳过重复部分的 prefill，实测连续对话的第二次请求能省掉大半 prefill 时间。

另一个坑是线程数：这台机器 `nproc` 报 8，但物理核只有 4 个（超线程）。llama-server 开 `-t 8` 反而更慢——超线程的第二个逻辑核和物理核抢执行单元，访存型负载下纯粹是负优化。**`-t` 设成物理核数（4）**，实测比 8 快约两成。`-tb`（batch 线程）同理，别超过物理核数。

## 四、KV Cache 满载：日志级联长什么样

这台机器跑了四天后，日志里出现了一长串级联告警：

```
W srv  decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 1024, ret = 1
W srv  decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 512, ret = 1
W srv  decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 1024, n_batch = 1024, ret = 1
...（一直缩到 n_batch = 16）
```

触发条件是 **4 个槽位全被长对话占满、新请求找不到 KV 空位**。llama.cpp 的兜底策略是不断缩小 batch 重试，而不是立刻驱逐旧会话——结果就是请求被拖进一个指数级的重试循环，prefill 延迟爆炸（我们观察到单次请求卡了十几秒）。缓解三板斧：

1. **控制槽位**：`-np 2` 甚至 `-np 1`。对单用户 IDE 服务，4 个并发槽位纯属浪费，还会让每个槽的 KV 预算翻倍膨胀；
2. **控制上下文**：IDE 补全场景 `-c 4096` 完全够用，别给 `-c 8192` 以上的慷慨配置；
3. **看现场**：`curl /slots` 返回每个槽的 `n_ctx`/`n_past`，槽位占用一眼可见；`/health` 看服务是否健康。修复后重启容器，日志干净了，prefill 恢复正常。

排查这类问题别只看 CPU 占用——KV 是内存问题，症状却表现为「请求变慢」，不看日志根本猜不到是槽位占满。

## 五、部署形态：优雅切换 + 内存水位

最后是这台机器上沉淀下来的部署形态。核心约束是 **30GB 内存只够同时常驻一个 16B 模型**，所以切换模型必须是「先优雅停止、再启动、再健康检查」三步，脚本长这样（关键行）：

```bash
# switch_model.sh 的核心骨架
nerdctl stop llama-server && nerdctl rm llama-server
nerdctl run -d --name llama-server --restart=always --network host \
  -v /data:/data llamacpp-build /data/llama.cpp/build/bin/llama-server \
  -m "$MODEL" -c "$CTX" -t 4 -ctk q8_0 -ctv q8_0 --port 8081
# 轮询 /health 直到返回 ok，超时 90 秒报错
```

三个必须记住的坑：

- **nerdctl 必须 `--network host`**：这个运行时写 `unprivileged_port_start` 配置会直接崩，端口映射走不了，只能 host 网络（见上一篇编译文章）；
- **`--restart=always`**：K8s worker 上容器被 node 重启连带拉起，没有它服务就静默消失了；
- **内存水位**：`free -g` 可用内存常年只有 4GB 时要警惕——swap 一开，decode 从 3 token/s 掉到 0.5 token/s 都是轻的。KV 减半（`-ctk q8_0`）、槽位收紧（`-np 2`）、上下文收敛（`-c 4096`）这三招一起上，能把 KV 总预算压到原来的四分之一。

## 六、可迁移清单

1. 无 GPU 内存吃紧 → 权重选 **Q4_K_M**，质量损失约 0.3~0.5 ppl，代码生成任务无感；
2. KV Cache 用 **Q8_0**（`-ctk q8_0 -ctv q8_0`），内存减半、质量无感，性价比最高的单行配置；
3. KV 内存按「层数 × 每层元素 × 上下文 × 槽位数 × 字节」算，启动即分配，别拍脑袋；
4. MoE 模型 CPU 上 **prefill 比 decode 慢**，短 prompt 多轮往返是灾难，开 prompt 缓存、减少往返；
5. `-t` 设物理核数，超线程逻辑核是负优化；
6. KV 满载的症状是「请求变慢 + batch 缩水级联日志」，先看 `/slots` 再动配置；
7. 内存水位低于一个模型体积时，切换模型必须「优雅停 → 起 → 健康检查」，别用 kill -9。
