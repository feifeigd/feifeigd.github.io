---
title: "面试题：MoE 为什么能用更少的激活参数换来更大的容量？专家路由怎么设计、负载不均衡怎么治、为什么 MoE 推理比同规模稠密模型更难？"
date: 2026-10-02T09:00:00+08:00
draft: false
tags: ["ai", "llm", "moe", "inference", "training", "interview"]
categories: ["Interview"]
description: "LLM 高频面试题：MoE 凭什么用 37B 激活参数打出 671B 的总参数量——稀疏到底省了什么？Router 的 top-k 门控、capacity factor、token dropping 怎么设计？负载不均衡和路由塌缩怎么治，为什么 DeepSeek 的 aux-loss-free 偏置调节比辅助损失更优雅？专家并行 all-to-all 通信、显存墙、FP8 量化与 router 精度、小 batch 下的长尾延迟，从训练到推理一次讲透。"
---

> 这是「每日一题」专栏的第十九篇。每天一道面试题，后端 + AI 混合路线，从原理到代码一次讲清。上一篇是 [短链接系统进阶](/blog/2026/08/31/url-shortener-advanced-interview)，间隔了一个月没更新，今天按轮换回到 AI/LLM 方向，聊近两年面试出现频率陡增的一题：**混合专家（MoE）**——为什么 671B 的模型只需要 37B 的激活参数就能跑起来，这条路到底省了什么、又难在哪。

{/* truncate */}

## 一、题目与考点拆解

先看面试官的原话通常是这么问的：

> Mixtral 8x7B 有 47B 参数，但每个 token 只激活 13B；DeepSeek-V3 总参数 671B，激活 37B。既然每次只算一小部分，为什么不能说它「就是一个 13B / 37B 的模型」？MoE 的稀疏到底换来了什么？代价是什么？

这一题真正的考点有四个，逐个拆：

1. **容量与计算量的解耦**：模型「记得住多少」（参数容量）和「算得多累」（FLOPs）被拆成两个独立旋钮；
2. **路由机制**：token 怎么选专家，top-k、门控、capacity、dropping 各自的作用；
3. **负载均衡**：路由塌缩（所有 token 挤向少数专家）为什么必然发生，怎么治；
4. **工程代价**：训练时的 all-to-all 通信、推理时的显存墙与长尾延迟——为什么 MoE 不是「免费的午餐」。

前三题答得好只能算及格，第四题才是区分 P6 和 P7 的地方。

## 二、先讲清楚稀疏换来了什么

### 2.1 稠密模型的死结

标准 decoder-only Transformer 里，FFN（MLP 层）是参数大头。以 `d_model = d`、中间维度 `4d`（门控版 3 个矩阵按 LLaMA 的 SwiGLU 口径约 `3 * d * d_ff`，取 `d_ff = 8/3 d` 时约等于 `8d²`）计算，每层 FFN 参数量约：

- Attention（QKV + O 四个 `d × d`）：约 `4d²`
- FFN（SwiGLU 三个矩阵）：约 `8d²`

也就是说 **FFN 吃掉了每层约 2/3 的参数**。想让模型更「聪明」（更多参数、更强记忆容量），就只能把 FFN 加宽加深——而 FFN 的参数是每个 token 都要参与的，参数量和计算量**线性绑定**。想扩容就得等比多花钱，这条路在 2022 年之后就走到了成本墙。

### 2.2 MoE 的破局：把一个大 FFN 切成 N 个小 FFN

MoE 的做法极其直白：把一层的 FFN 换成 `N` 个并行的「专家」FFN，再加一个轻量的路由网络（router / gate）。每个 token 只被送往其中 `k` 个专家（典型 `k = 1~2`，DeepSeek-V3 是 top-8）。

于是两个量被彻底分开了：

| 概念 | 公式 | 含义 |
| --- | --- | --- |
| 总参数量 | `P_total ≈ P_attn + N × P_expert` | 决定**显存占用**和「模型容量」 |
| 激活参数量 | `P_active ≈ P_attn + k × P_expert` | 决定**单 token 计算量**（FLOPs） |

关键点：**MoE 省的是 FLOPs，不是显存。** 这句话一定要说出来，很多候选人答到「省参数」就停了，直接暴露没部署过。

### 2.3 落到真实数字

| 模型 | 总参数 | 激活参数 | 稀疏度 | 路由策略 |
| --- | --- | --- | --- | --- |
| Switch Transformer | 1.6T | ~? | top-1 | 单专家，容量因子 1.25 |
| Mixtral 8x7B | 47B | ~13B | 8 选 2 | top-2 |
| DeepSeek-V2 | 236B | 21B | 160 选 6 + 2 共享 | top-6 + shared |
| DeepSeek-V3 | 671B | 37B | 256 选 8 + 1 共享 | top-8 + shared，无辅助损失 |

看 Mixtral 这行：**47B 的参数量、13B 的推理算力**，效果却接近更大规模的稠密模型——这就是稀疏的红利。而 DeepSeek-V3 用 37B 的激活量打到接近稠密 70B+ 的效果，同时保持训练成本可控。

面试时补一句「容量和算力解耦」的定量直觉更加分：在固定 FLOPs 预算下，把稠密模型换成 MoE，通常能在等算力下拿到明显更低的 loss——这是 GLaM / Switch Transformer 时代的核心结论。

## 三、路由机制怎么设计

### 3.1 最朴素的 top-k 门控

Router 是一个只有 `d × N` 参数的小线性层（相对整个模型可以忽略不计）：

```python
import torch, torch.nn as nn, torch.nn.functional as F

class TopKGate(nn.Module):
    """最简门控：token 级 top-k 路由 + 权重归一化"""
    def __init__(self, d_model, num_experts, top_k=2):
        super().__init__()
        self.num_experts = num_experts
        self.top_k = top_k
        self.gate = nn.Linear(d_model, num_experts, bias=False)

    def forward(self, x):                      # x: [T, d]
        logits = self.gate(x)                  # [T, N]
        scores = F.softmax(logits, dim=-1)     # 概率
        topv, topi = scores.topk(self.top_k, dim=-1)   # [T, k]
        # 只保留被选中的专家权重并按和归一化
        topv = topv / topv.sum(dim=-1, keepdim=True)
        return topi, topv
```

然后每个 token 的输出是：

```
y = Σ_{i ∈ top-k}  gate_i · Expert_i(x)
```

三个必须讲清的设计点：

1. **为什么用 softmax 之后再取 top-k（而不是取 top-k 再 softmax）**：工程上两种都有人用，但主流实现（GShard 系）是先 softmax 再 top-k 再重归一化，这样门控权重天然非负且和为 1，数值更稳。
2. **top-1 还是 top-2**：top-1 最省算力但训练不稳（Switch Transformer 靠精心调参和大容量因子压住了）；top-2 让两个专家各贡献一半，梯度更平滑，是现在的主流。
3. **token 级 vs 序列级路由**：token 级（逐 token 独立选）最灵活；但有些实现用句子级/序列级路由以提高一致性、降低路由抖动。

### 3.2 共享专家与细粒度专家（DeepSeek 的两个改进）

这两点值得单独提，是近两年 MoE 设计里最常被追问的：

- **共享专家（Shared Expert）**：留 1~2 个专家**永远参与**，所有 token 都过它。目的是把「通用知识」沉淀到共享专家里，避免每个专家都重复学一遍公共模式，同时缓解路由的随机性。
- **细粒度专家（Fine-grained Expert Segmentation）**：不再用少量「大专家」，而是把专家切得更细（如 256 个），但激活更多个（top-8）。好处是同等的激活参数下，**组合空间爆炸**（`C(256,8)` 远超 `C(8,2)`），模型可以更精细地组合不同能力。

一句话总结：**共享专家负责通用底座，细粒度路由负责专用能力。**

### 3.3 Capacity Factor 与 Token Dropping（训练侧）

训练时如果把专家当成「带缓冲区的队列」，一个专家能处理的 token 数上限是：

```
capacity = ceil( (tokens_per_batch / num_experts) × capacity_factor )
```

- `capacity_factor` 通常取 **1.25**（Switch 论文口径）；
- 超出容量的 token 会被 **drop**（跳过该专家的计算，直接走残差）；
- drop 掉的 token 相当于这一层少算了，会造成信息损失和训练不稳。

这就引出一个根本矛盾：**capacity 设小了丢 token，设大了显存/算力浪费且负载更不均衡**。所以要治负载，而不是靠调 capacity 硬扛。

## 四、负载不均衡：MoE 最核心的坑

### 4.1 为什么必然不均衡（路由塌缩）

这不是调参问题，而是**自我强化**的系统效应：

1. 初始时某几个专家恰好表现稍好 →
2. 更多 token 路由到它们 → 它们被更多梯度更新，变得更强 →
3. 于是更多 token 流向它们……最终少数专家吃掉绝大部分 token，其余专家几乎不训练。

专家的利用率可以画成一条长尾曲线，塌缩严重时几个专家承担 90% 的 token，其余专家基本是「僵尸参数」——总参数白白占了显存，容量优势全丢。

### 4.2 传统解法：辅助损失（Aux Loss）

在训练 loss 里加一项，惩罚「专家负载不均」和「路由概率不均」：

```python
def load_balancing_loss(gate_probs, expert_idx, num_experts):
    """
    gate_probs: [T, N] softmax 后的路由概率
    expert_idx: [T] 每个 token 的主专家
    返回: 负载均衡辅助损失（越小越均衡）
    """
    T = gate_probs.shape[0]
    # f_i: 分给专家 i 的 token 比例
    f = torch.bincount(expert_idx, minlength=num_experts).float() / T
    # P_i: 专家 i 的平均路由概率
    P = gate_probs.mean(dim=0)
    # 两者的点积：既惩罚 token 数不均，也惩罚概率偏高
    return num_experts * torch.sum(f * P)
```

要点：

- 辅助损失系数要小心调（典型 0.01 量级），**太大会让路由偏离语言建模目标，损害效果**；
- DeepSeek-V3 里还加了一个极小的**序列级均衡损失**（约 1e-4），只用来兜底防极端不均衡，其余交给下面的新方法。

### 4.3 新解法：Aux-loss-free 偏置调节（加分项）

DeepSeek-V3 的做法很漂亮，面试官大概率会追问「除了辅助损失还有别的办法吗」：

- 给每个专家维护一个**可学习的偏置项 `b_i`**，只加在「选谁」的比较分数上，**不参与门控权重的计算**；
- 训练中按**符号规则**更新：某专家过载就 `b_i -= γ`，欠载就 `b_i += γ`（`γ` 是固定步长，如 1e-3）；
- 偏置只影响 `top-k` 的选择顺序，不影响最终加权系数，所以**不干扰语言建模目标的梯度**。

对比一下：

| 方案 | 均衡效果好 | 损害主目标 | 调参成本 |
| --- | --- | --- | --- |
| 辅助损失 | 中 | 有（系数大时明显） | 系数敏感 |
| 容量因子 + dropping | 中 | 丢 token | 依赖 capacity |
| 偏置调节（aux-loss-free） | 好 | 几乎无 | 一个 γ |

一句话回答：**辅助损失是「用梯度逼路由均衡」，偏置调节是「在路由选择上做加法、把均衡和主任务解耦」。**

### 4.4 专家并行（EP）与 all-to-all

负载均衡不只是效果问题，还是**性能问题**：专家分布在不同 GPU 上，一个 token 被路由到别的卡的专家，就必须跨卡传输。

- 训练时常见组合是 **TP / EP / DP / PP** 混合并行，其中 EP 通常把专家切到不同 rank；
- 每层两次 **all-to-all**：一次把 token 发给目标专家所在的卡（dispatch），一次把结果收回来（combine）；
- 这是 MoE 训练的主要通信瓶颈，也是为什么 MoE 对**互联带宽（NVLink / IB）**极其敏感；
- 如果负载不均衡，就是「少数卡通信排队、多数卡空转」，**理论 FLOPs 没变，但端到端被最慢的卡拖死**。

## 五、推理阶段：为什么 MoE 比同规模稠密模型更难

这一节是很多候选人的盲区。训练省算力不代表推理省事，MoE 在推理侧有三堵墙。

### 5.1 显存墙（memory-bound）

- 计算量按**激活参数**走，但权重要**全部常驻显存**——`671B` 参数即使按 FP8 存也要约 671GB；
- 结论就是：**MoE 推理首先是显存问题，其次才是算力问题**。DeepSeek-V3 官方 FP8 部署要 8 卡级别的机器；
- 反过来看，MoE 在**低并发、单请求**场景下非常吃亏：显存要装 671B，但每步只算 37B，GPU 算力严重闲置，性价比远不如一个稠密的 37B 模型。

### 5.2 长尾延迟（tail latency）

decode 阶段每步都要路由：

- 同一个 batch 里不同 token 命中不同专家，**单卡上专家负载天然不均**；
- 一两张卡成为热点 → 整个 batch 的迭代时间由它决定 → **tail latency 拉高**；
- 这就是为什么 MoE 在**大 batch / 高吞吐**场景才划算：batch 越大，专家负载越平均，稀疏红利才被吃满；
- 工程手段：expert 复制（热点专家多副本）、动态路由调度、PD 分离（prefill 与 decode 分池）。

### 5.3 量化与 router 精度

MoE 对量化非常敏感，原因是**误差会被路由放大**：

- expert 权重可以放心量化（FP8 / INT8 / 4-bit），因为它们是「计算主体」，量化误差平摊到大量累加上；
- **router 和门控权重必须保持高精度**（FP32/BF16）。一旦 router 输出的排序因量化翻转，token 会被送到**完全不同的专家**，输出直接崩掉，而且是不可预测的崩；
- 实践口径：**量化专家，别量化路由**。

### 5.4 KV Cache 视角的补充

MoE 不改变 attention 的结构，所以 **KV Cache 的显存占用与同层数的稠密模型一样**。也就是说：MoE 靠稀疏省了权重计算，但长上下文场景下 KV Cache 依然按 token 数线性增长——这两笔账要分开算，别混在一起说。

## 六、一个能跑的 MoE 层（含容量与丢弃）

```python
import torch, torch.nn as nn, torch.nn.functional as F

class Expert(nn.Module):
    def __init__(self, d_model, d_ff):
        super().__init__()
        self.w1 = nn.Linear(d_model, d_ff, bias=False)
        self.w2 = nn.Linear(d_ff, d_model, bias=False)

    def forward(self, x):
        return self.w2(F.silu(self.w1(x)))

class MoELayer(nn.Module):
    """教学版 MoE：top-k 路由 + capacity factor + token dropping + 负载辅助损失"""
    def __init__(self, d_model, d_ff, num_experts=8, top_k=2, capacity_factor=1.25):
        super().__init__()
        self.num_experts = num_experts
        self.top_k = top_k
        self.capacity_factor = capacity_factor
        self.gate = nn.Linear(d_model, num_experts, bias=False)
        self.experts = nn.ModuleList([Expert(d_model, d_ff) for _ in range(num_experts)])

    def forward(self, x):                      # [T, d]
        T, d = x.shape
        logits = self.gate(x)
        probs = F.softmax(logits, dim=-1)
        topv, topi = probs.topk(self.top_k, dim=-1)          # [T, k]
        topv = topv / (topv.sum(-1, keepdim=True) + 1e-9)

        capacity = int((T / self.num_experts) * self.capacity_factor)
        capacity = max(capacity, self.top_k)                 # 至少留 k 个位置
        # 每个专家维护一个计数器，超容量则丢弃（用 -1 标记）
        counts = torch.zeros(self.num_experts, dtype=torch.long)
        slot = torch.full_like(topi, -1)

        for i in range(T):
            for j in range(self.top_k):
                e = int(topi[i, j])
                if counts[e] < capacity:
                    slot[i, j] = counts[e]
                    counts[e] += 1

        out = torch.zeros_like(x)
        for e in range(self.num_experts):
            mask = (topi == e)                               # [T, k]
            tok_idx, k_idx = mask.nonzero(as_tuple=True)
            if tok_idx.numel() == 0:
                continue
            keep = slot[tok_idx, k_idx] >= 0                 # 保留未被丢弃的
            if keep.sum() == 0:
                continue
            y = self.experts[e](x[tok_idx[keep]])            # 只算被保留的 token
            w = topv[tok_idx[keep], k_idx[keep]].unsqueeze(-1)
            out.index_add_(0, tok_idx[keep], y * w)

        # 辅助损失：让分给各专家的 token 比例尽量均匀
        dominant = topi[:, 0]
        f = torch.bincount(dominant, minlength=self.num_experts).float() / T
        P = probs.mean(dim=0)
        aux = self.num_experts * torch.sum(f * P)
        return out, aux
```

这个版本是所有主流框架（Megablocks、Tutel、DeepSpeed-MoE、vLLM 的 fused MoE）的简化骨架。真实实现把上面的 Python 循环换成一个大的 **`index_select` + grouped GEMM**，一次矩阵乘算完所有专家，否则性能会差一个数量级。

## 七、面试官的连环追问（附简答）

**Q1：MoE 是「模型更大」还是「模型更小」？**
总参数按 `N × P_expert` 看是更大（容量更大），单 token 计算量按 `k × P_expert` 看是更小。它把两个维度解耦了，所以「更大还是更小」本身是个错误问题。

**Q2：为什么 MoE 能比稠密模型省训练成本？**
等 FLOPs 下 MoE 的有效容量更高、loss 更低；反向看，达到同等效果时 MoE 的总训练算力更省（注意总参数量并不省显存）。

**Q3：top-1 和 top-2 怎么选？**
top-1 最省算力，训练不稳、对均衡机制依赖重；top-2 梯度更平滑、效果更稳，多花一份专家算力。工程默认 top-2，超大模型用更细粒度 + 更大的 k。

**Q4：token dropping 为什么不好，能不能不丢？**
丢弃会让部分 token 这一层的 FFN 完全失效，等于随机少了容量，还会让梯度信号变稀。所以出现了 **dropless MoE**（不设容量上限，用别的机制保均衡），代价是显存和通信峰值不可控。

**Q5：为什么不干脆把专家做成跨卡共享 / 全放一张卡？**
放一张卡受限于显存（671B 根本装不下）；跨卡就必然 all-to-all 通信。这是 MoE 的本质权衡——**用通信换计算**。

**Q6：MoE 的显存和稠密 671B 一样吗？**
权重显存基本一样（都是 `P_total`），KV Cache 也基本一样（attention 没变）。省的是激活值和部分中间计算，不是权重。

**Q7：MoE + LoRA 微调有什么坑？**
只微调部分专家会导致路由漂移（其他专家在推理时被选中但没微调过）；稳妥做法是同时微调 router 或给所有专家加 LoRA，或冻结路由、只动指定专家并保持负载均衡。

## 八、一页速记

| 维度 | 稠密模型 | MoE |
| --- | --- | --- |
| 参数与算力 | 线性绑定 | 解耦（`P_total` vs `P_active`） |
| 省的是什么 | —— | 省 FLOPs，**不省权重显存** |
| 核心机制 | —— | Router + top-k + capacity |
| 必修课 | —— | 负载均衡（aux loss / 偏置调节） |
| 训练瓶颈 | 通信（TP/DP） | all-to-all（EP） |
| 推理瓶颈 | 算力/带宽 | 显存墙 + 长尾延迟 |
| 量化 | 全层可量化 | 专家可量化，**router 必须高精度** |
| 最佳场景 | 低并发单请求 | 大 batch 高吞吐 |

一句话收尾：**MoE 是用「通信复杂度 + 工程复杂度 + 显存占用」去换「等算力下的模型容量」——它不是免费的，只是这笔账在超大规模训练里划得来。**

## 九、下一篇预告

按轮换，下一篇回到 **后端/分布式** 方向。预告一题：**分库分表之后的在线扩容——不停机把 4 库扩到 8 库，双写、影子表、数据校验与回滚怎么做？** 数据迁移期间的读写一致性、增量补偿、灰度切流，是这套题的主线。

---

**相关阅读**

- [为什么 vLLM 是当前最快的 LLM 推理框架](/blog/2026/08/29/vllm-inference-interview)
- [KV Cache 显存与长上下文推理](/blog/2026/08/19/kv-cache-interview)
- [LLM 量化：从 INT8 到 4-bit](/blog/2026/08/23/llm-quantization-interview)
- [投机解码为什么能加速推理](/blog/2026/08/24/speculative-decoding)
