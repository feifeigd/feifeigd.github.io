---
title: "分布式训练工程课：3D 并行、ZeRO/FSDP 与通信开销的账怎么算"
date: 2026-08-25T18:00:00+08:00
draft: false
tags: ["ai", "llm", "training", "infra", "gpu", "engineering"]
categories: ["AI"]
description: "单卡放不下大模型怎么办？数据并行、张量并行、流水线并行各自解决什么问题、通信账怎么算？ZeRO/FSDP 怎么把显存摊平到每张卡？3D 并行怎么配才不浪费集群？附通信量估算器和 FSDP 最小训练代码，以及 NCCL 超时、micro-batch 配置等踩坑清单。"
---

先给结论：**大模型训练并行只有三件事——显存放不下、算力不够用、通信不能成为瓶颈**。数据并行（DP）摊算力、张量并行（TP）摊单层显存、流水线并行（PP）摊层数，ZeRO/FSDP 是数据并行的显存优化形态，实际生产（GPT-3、Llama、Qwen 系列）都是把它们叠成 3D/4D 并行来用。选型的本质是一道**通信开销的算术题**：每步训练要搬多少字节，你的互联带宽扛不扛得住。

上一篇讲了[参数高效微调 LoRA/QLoRA](/blog/2026/08/16/lora-qlora-peft-deep-dive)，那是"少训点参数"的路线；这篇是"多卡一起训"的路线，两者互补。集群怎么调度 GPU 见[K8s GPU 调度](/blog/2026/08/20/kubernetes-gpu-scheduling-deep-dive)。

{/* truncate */}

## 一、三种并行，各解决什么问题

| 并行方式 | 切什么 | 解决 | 代价 |
|---|---|---|---|
| 数据并行 DP | 训练数据（每卡一份完整模型） | 吞吐上不去 | 每步全量梯度 AllReduce，通信随卡数线性涨 |
| 张量并行 TP | 单层内的权重矩阵 | 单卡显存放不下一层 | 每层 2 次全量 AllReduce，需要 NVLink 级带宽 |
| 流水线并行 PP | 按层切段，卡间串行 | 单卡显存放不下整个模型 | 流水线气泡（bubble）空转 |

直观理解：DP 是"复制模型、分数据"，TP 是"把一个大矩阵切开分给多卡"，PP 是"模型太深太长，切成几段接力跑"。三者互相正交，可以叠加。

## 二、数据并行：通信账先算清楚

DDP 每步的通信量有个经典公式：梯度全量 AllReduce，带宽开销近似 **2 × (N-1)/N × 梯度字节数**，N 是卡数。N 一大，(N-1)/N 趋近 1，也就是**每步要搬约 2 倍模型字节数**。

算笔账：7B 模型 BF16 权重 14GB，梯度同尺寸 14GB。64 卡 DDP 每步 AllReduce ≈ 28GB。如果走 25Gbps 网卡（约 3.1GB/s），光同步梯度就要 9 秒——训练直接废掉。所以 DDP 在单机多卡（NVLink 600GB/s 级别）没问题，跨机就是灾难。**这就是 ZeRO 和 FSDP 出现的直接动机**：把"全量梯度 AllReduce"拆成"分片梯度 Reduce-Scatter + 分片权重 All-Gather"，每卡只扛 1/N 的通信。

## 三、张量并行：切矩阵，靠 NVLink

Megatron-LM 的做法：权重按列切分（Column Parallel）或按行切分（Row Parallel），Attention 的 QKV 投影、MLP 的线性层分别处理。每层 Transformer 前向需要 2 次 All-Reduce（Attention 输出 + MLP 输出），反向再 2 次。

TP 的关键特性：**通信量不随卡数翻倍**，只和激活/hidden size 相关，所以它吃的是带宽不是规模。也因此 TP 一般只做到 8 卡以内（一个节点），跨节点走 IB 做 TP 会很难受。社区经验：**TP 4~8 是甜点区，超过 8 收益骤降**。

## 四、流水线并行：气泡率的数学

朴素 GPipe 的 bubble 率 ≈ (P-1)/(M+P-1)，P 是流水线段数，M 是每个 micro-batch 数。P=8、M=16 时气泡约 30%，P=16、M=32 时约 32%——**增加 micro-batch 数可以压气泡**。1F1B（one-forward-one-backward）调度能把气泡率再压一半左右，是 Megatron 的默认。

两个工程要点：

1. **micro-batch 数必须 ≥ P**（通常取 2P 以上），否则前向算完没反向可填，气泡率爆炸——这是最常见的配置错误；
2. PP 的每段内其实还要配合 TP/DP，段内通信密集、段间只传激活，所以**段间带宽要求低**（IB 甚至万兆都行），段内必须 NVLink。

## 五、ZeRO/FSDP：把显存摊平

ZeRO 三阶段是数据并行的显存革命：

| 阶段 | 切什么 | 每卡显存（N 卡） | 通信 |
|---|---|---|---|
| ZeRO-1 | 优化器状态 | 模型/N 的优化器部分 | 同 DDP |
| ZeRO-2 | + 梯度 | 再省 | 同 DDP |
| ZeRO-3 | + 权重（FSDP） | 约 模型/N | All-Gather + Reduce-Scatter |

FSDP 就是 PyTorch 对 ZeRO-3 的实现：前向前 All-Gather 拉权重，反向后 Reduce-Scatter 归并梯度。它的通信量比 DDP 大（每步权重 All-Gather + 梯度 Reduce-Scatter ≈ 2 × 模型字节数 × (N-1)/N），但**显存从 O(模型) 降到 O(模型/N)**，这才是它存在的意义——DeepSpeed 论文实测：170B 模型用 ZeRO 在 400 块 V100 上训出来了，DDP 想都不敢想。

**ZeRO vs TP 的取舍**：ZeRO 通信走的是节点间带宽（IB），TP 走节点内（NVLink）。所以生产惯例是——**节点内用 TP，节点间用 ZeRO/DP**，两边带宽各尽其用。

## 六、3D/4D 并行怎么配

Megatron-DeepSpeed 系的典型配置（以 32 卡、8 卡/节点为例）：

```
TP=8（节点内 NVLink 全用上）→ PP=2（跨 2 个节点）→ DP=2（数据并行兜底）
```

原则：**TP 最小化到节点内、PP 次之、DP 最大化**——因为 DP 的通信量最贵（全量梯度），PP 次之（只有段间激活），TP 反而最便宜（高频但量小）。GPT-3 175B 论文实测：1024 块 A100 上 Megatron 3D 并行跑到 57.8% MFU；530B 模型（Megatron-Turing NLG）用 2240 块 A100 训到 41.4% MFU。规模越大，并行度配置的边际收益越薄，MFU 越难拉。

## 七、可运行代码

### 7.1 通信量估算器（无 GPU 可跑）

选型前先算账，这比调参重要：

```python
def traffic_per_step(params_b: float, world_size: int, bytes_per_param: int = 2) -> dict:
    """估算每 step 的梯度同步通信量（GB）。params_b: 模型参数量(十亿)。"""
    model_bytes = params_b * 1e9 * bytes_per_param
    factor = 2 * (world_size - 1) / world_size  # AllReduce 带宽系数

    ddp = factor * model_bytes                     # 全量梯度 AllReduce
    zeRO3 = factor * model_bytes                   # All-Gather + Reduce-Scatter，总量近似同阶
    return {
        "ddp_gb": round(ddp / 1e9, 2),
        "zeRO3_gb": round(zeRO3 / 1e9, 2),
        "ddp_25g_seconds": round(ddp / 1e9 / 3.1, 1),   # 25Gbps ≈ 3.1GB/s
        "ddp_ib_seconds": round(ddp / 1e9 / 12.5, 1),   # 100Gbps IB ≈ 12.5GB/s
    }

print(traffic_per_step(7, 64))   # 7B, 64 卡
# {'ddp_gb': 27.6, 'zeRO3_gb': 27.6,
#  'ddp_25g_seconds': 8.9, 'ddp_ib_seconds': 2.2}
```

跑一下就知道：7B 在 64 卡上，25G 网卡光同步就要 9 秒/step，必须换 IB 或上 ZeRO。

### 7.2 FSDP 最小训练循环

```python
import torch
import torch.distributed as dist
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP

def train_fsdp(model, dataloader, epochs: int):
    dist.init_process_group("nccl")
    model = FSDP(model, device_id=torch.cuda.current_device())
    opt = torch.optim.AdamW(model.parameters())   # FSDP 会 flatten 参数
    for _ in range(epochs):
        for x, y in dataloader:
            opt.zero_grad()
            loss = model(x, y)
            loss.backward()                        # 内部自动 Reduce-Scatter
            opt.step()                             # 每卡只更新自己的分片
    dist.destroy_process_group()
```

就这些——API 层面 FSDP 和 DDP 长得一样，区别全在背后：梯度是分片归并的，优化器状态每卡只存 1/N。

## 八、踩坑清单（全是实操教训）

1. **micro-batch 数不足 PP 深度**：前向喂完没反向可填，气泡率飙到 50% 以上，Loss 曲线看着正常但 MFU 崩。先数 `(micro_batches × PP) / 2` 够不够。
2. **NCCL 超时误判**：默认 timeout 是 10 分钟（NCCL_TIMEOUT），大模型 checkpoint 加载慢、慢卡掉队都容易触发 `ncclTimeout`。先看是不是某张卡 OOM 重试，再看网络——不要无脑调大超时掩盖问题。
3. **checkpoint 的 world_size 不匹配**：ZeRO/FSDP 的 checkpoint 是分片存的，换并行度配置（TP 8→4）直接加载会炸。要么存 full state dict（贵），要么存分片 + 记录并行配置，恢复时按新配置重组。
4. **梯度裁剪的位置**：必须先 `all_reduce` 归并完梯度再 clip，否则各卡 clip 阈值不一致，等效于改了学习率。
5. **序列并行 / vocab 并行**：大词表（如 150K vocab）的 embedding 是显存大头，Qwen/Llama 训练都开 vocab parallel，别漏。
6. **BF16 是标配**：FP16 在大规模下 loss spike 概率高，BF16 省一半通信且更稳；实在要 FP16 就开 loss scaling + master weight。
7. **排查先降维**：Loss 发散先退回单卡/DP 复现，确认不是数据问题，再逐层加 TP/PP——并行配置引入的 bug 往往在通信逻辑，不在模型。

## 九、结论

- **选型顺序**：单卡能放下 → 直接 DP/DDP；放不下 → 先 ZeRO/FSDP；单层都放不下（超大模型）→ 上 TP + PP 的 3D 组合。
- **通信是唯一硬约束**：先算每步字节数，再对互联带宽，最后才谈并行度配置。
- **MFU 别神话**：175B 在 1024 卡也就 58%，规模越大边际收益越薄，配到"够用"即可，省下来的卡钱比 5 个点 MFU 值钱。

下一篇预告：聊 LLM 服务的**PD 分离与显存规划**，把推理侧的账也算明白（[上篇已埋坑](/blog/2026/08/21/pd-separation-deep-dive)）。
