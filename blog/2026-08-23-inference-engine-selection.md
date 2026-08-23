---
title: "LLM 推理引擎选型：vLLM、SGLang、TensorRT-LLM、TGI 到底怎么选？"
date: 2026-08-23T20:00:00+08:00
draft: false
tags: ["ai", "llm", "inference", "vllm", "performance", "engineering", "infra"]
categories: ["AI"]
description: "四个主流推理引擎的调度、前缀缓存、结构化输出、量化、MoE 支持全对比；vLLM 生态最全、SGLang 前缀缓存最强、TensorRT-LLM 性能上限最高、TGI 最省心；附实测 benchmark 与选型决策表。"
---

推理引擎选型是 LLM 服务化里**最容易被低估的架构决策**。同样的模型、同样的 GPU，换一个引擎吞吐可能差 2-3 倍；但反过来，厂商 benchmark 里好看的引擎，落到你的真实负载上可能反而更慢。这篇文章把 vLLM、SGLang、TensorRT-LLM、TGI 四个主流引擎放在一起对比，从调度机制、前缀缓存、结构化输出、量化、MoE 支持五个维度拆，最后给选型决策表和生产踩坑记录。

{/* truncate */}

## 一、四个引擎的定位

| 引擎 | 出身 | 核心卖点 | 适合谁 |
|------|------|---------|--------|
| **vLLM** | UC Berkeley / 社区 | PagedAttention + Continuous Batching，生态最全 | 绝大多数生产场景，默认选择 |
| **SGLang** | Stanford LMSYS | RadixAttention 前缀树缓存，原生结构化输出 | 长上下文、多轮对话、前缀复用高的场景 |
| **TensorRT-LLM** | NVIDIA | 编译优化，单卡性能上限最高 | 固定模型、追求极致性能、有 NVIDIA 全家桶 |
| **TGI** | HuggingFace | 部署最简单，一行 docker | 快速验证、模型种类杂、不想折腾 |

一句话概括差异：**vLLM 是「通用最优」，SGLang 是「前缀缓存最优」，TensorRT-LLM 是「单次性能最优」，TGI 是「上手最优」**。

## 二、五个关键维度的机制差异

### 1. 调度：都是 Continuous Batching，细节不同

四个引擎都实现了迭代级调度（Orca 提出的 Continuous Batching），但**抢占策略和调度开销**不同：

- **vLLM**：running/swapped/waiting 三队列，抢占支持 RECOMPUTE 和 SWAP 两种，`max_num_seqs` 控制前向规模。调度器是纯 Python，逻辑清晰、可调参数多。
- **SGLang**：调度器和显存池统一管理，**抢占基本不触发**——因为 RadixAttention 的前缀树天然共享 KV，新请求的前缀命中后只需要分配增量部分。
- **TensorRT-LLM**：in-flight batching（连续批处理），但**请求间 KV 不共享**，动态 shape 支持弱，输入长度差异大的负载会因 padding 浪费算力。
- **TGI**：实现最简单，调度能力最弱，长尾场景（长短请求混合）吞吐掉得最明显。

### 2. 前缀缓存：SGLang 的护城河

这是 SGLang 与 vLLM 最大的分水岭。

- **SGLang 的 RadixAttention**：把 KV cache 组织成**前缀树**，所有请求共享公共前缀。多轮对话里，用户历史 + 系统提示词是天然的前缀；Agent 场景里，几十个工具 schema + few-shot 示例每次都一样。这些 token 的 KV 只需计算一次，后续请求直接命中。论文（NeurIPS 2024）报告在共享前缀场景比 vLLM 快 **2.7x**（LLaMA-7B，含自动前缀复用）。
- **vLLM 的 prefix caching**：早期版本只支持**整块前缀**命中（要求前缀完全一致），而且自动前缀复用是后加的（`--enable-prefix-caching`）。它按 token 哈希做块级缓存，效率低于前缀树，但胜在兼容性好——**同一个 vLLM 集群里不同模型都能用**。

实测感受：多轮对话 + 长系统提示词的 Agent 负载，SGLang 的 TTFT 优势明显；纯单轮请求负载，两者差距很小。

### 3. 结构化输出：SGLang 原生，vLLM 后补

- **SGLang**：把约束解码做进了调度器（`regex` / `grammar` 参数直接传给 serve 接口），约束参与 prefill 阶段，**几乎没有额外延迟**。
- **vLLM**：通过 `guided_decoding`（复用 Outlines / XGrammar 后端）支持 JSON Schema / regex，但约束是在 decoding 时套的，复杂 grammar 下每 token 有 10-20% 的额外开销。
- **TensorRT-LLM**：也支持 grammar 约束，但需要先编译约束模板，动态性差。

### 4. 量化支持

| 引擎 | INT8/INT4 | FP8 | AWQ/GPTQ | 动态量化 |
|------|-----------|-----|----------|---------|
| vLLM | ✅ | ✅ | ✅ | ✅（weight-only） |
| SGLang | ✅ | ✅ | ✅ | ✅ |
| TensorRT-LLM | ✅ | ✅（FP8 优化最深） | ✅ | ✅ |
| TGI | ✅ | ⚠️ | ✅ | ⚠️ |

TensorRT-LLM 的 FP8 支持最深（NVIDIA 自家格式），但**量化也要走编译流程**，换一个量化方案就要重新 build engine。

### 5. MoE 支持：大模型时代的新分野

- **SGLang**：对 MoE（DeepSeek 系）支持最好，**DeepSeek 官方推荐用 SGLang 部署 V3/R1 系列**——因为 RadixAttention + 稀疏 attention + MoE 的显存调度是深度耦合优化的。
- **vLLM**：MoE 支持也在快速完善，多 GPU 下 expert parallelism 可用，但**专家间通信开销**没有 SGLang 优化得透。
- **TensorRT-LLM**：MoE 支持有，但 build 时间长，迭代慢。

## 三、上手配置对比

同样的 Qwen2.5-7B，三个引擎的起服务方式：

````bash
# vLLM —— 最接近 OpenAI 生态
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --max-model-len 32768 \
  --max-num-seqs 64 \
  --enable-prefix-caching \
  --gpu-memory-utilization 0.9

# SGLang —— 前缀缓存默认开，结构化输出原生
python -m sglang.launch_server \
  --model-path Qwen/Qwen2.5-7B-Instruct \
  --context-length 32768 \
  --mem-fraction-static 0.85

# TensorRT-LLM —— 先 build engine 再启动（构建需几分钟到几十分钟）
trtllm-build \
  --checkpoint_dir ./ckpt/qwen-7b \
  --gemm_plugin auto \
  --max_seq_len 32768 \
  --output_dir ./engine/qwen-7b
# 然后用 trtllm-serve 启动 engine
````

TGI 最简单：`docker run ghcr.io/huggingface/text-generation-inference --model-id Qwen/Qwen2.5-7B-Instruct`。

## 四、benchmark 数据与「数字陷阱」

| 数据 | 来源 | 条件 | 可信度 |
|------|------|------|--------|
| SGLang 比 vLLM 快 2.7x | SGLang 论文 (NeurIPS 2024) | LLaMA-7B，**共享前缀**负载 | 场景成立才成立 |
| vLLM 比 FasterTransformer 快 2.7x | vLLM 论文 (SOSP 2023) | LLaMA-13B，PagedAttention 场景 | 已过时，FT 已迭代 |
| TensorRT-LLM 比 vLLM 快 2-4x | NVIDIA 官方 benchmark | 固定 batch、固定长度、FP8 | **存疑，复现难** |

三个教训：

1. **厂商 benchmark 的负载和你的不一样**。NVIDIA 的 2-4x 用的是固定 batch 固定长度（静态 batching 思路），真实在线负载是随机到达、长度各异——这时候 Continuous Batching 的优势就回来了，差距缩到 1.2-1.5x 甚至打平。
2. **论文数字要看清前提**。SGLang 的 2.7x 是共享前缀场景，如果你的请求没有公共前缀，RadixAttention 帮不上忙，差距可能在 10% 以内。
3. **自己压测才是唯一真理**。用你的真实请求分布（长度、并发、前缀重复率）去压，不要信任何人的数字。社区共识：**vLLM 和 SGLang 在通用负载上差距很小，TensorRT-LLM 的领先在真实动态负载下大幅缩水**。

## 五、选型决策表

| 你的场景 | 推荐引擎 | 理由 |
|----------|---------|------|
| 通用在线推理，请求随机 | **vLLM** | 生态最全、调度最稳、社区最活跃 |
| Agent 多轮对话 + 长系统提示词 | **SGLang** | 前缀缓存吃满，TTFT 优势明显 |
| 长文档问答（几十 K 上下文） | **SGLang** | RadixAttention 在长前缀下收益最大 |
| 固定模型 + 极致单卡性能 | **TensorRT-LLM** | FP8 + 编译优化上限最高 |
| 快速验证 / 模型种类杂 | **TGI** | 零配置，模型仓库直接拉 |
| DeepSeek V3/R1 系 MoE | **SGLang** | 官方推荐，显存调度最优 |

**混合部署也是正解**：一个集群里 vLLM 跑通用模型、SGLang 跑 Agent 模型，通过路由层分发——这比纠结「选哪个」更实际。

## 六、生产踩坑记录

**坑 1：SGLang 版本迭代快，升级有惊喜。** SGLang 的 API 和调度行为大版本间变化大（比如 `--mem-fraction-static` 语义改过），锁版本 + 压测回归再升级，别追新。

**坑 2：TensorRT-LLM 的 build 时间被低估。** 大模型 build engine 要几十分钟到几小时，而且**模型或量化方案一变就得重 build**。CI 里记得缓存 engine artifact，否则每次发版等半天。多模态模型 build 更是重灾区。

**坑 3：vLLM 的 prefix caching 有显存代价。** `--enable-prefix-caching` 会多占显存（缓存块），显存紧张时反而降低 batch size。前缀复用率低于 20% 的负载建议关掉。

**坑 4：引擎的「支持」和「好用」是两回事。** 比如 vLLM 的 guided decoding 和 SGLang 的结构化输出都支持 JSON Schema，但复杂嵌套 schema 下 vLLM 的每 token 开销明显更高。上线前用你的真实 schema 压一遍，别只看文档。

**坑 5：多模态模型的显存规划差异巨大。** TensorRT-LLM 对 VLM 的 vision encoder 是静态分配的，vLLM 是动态的——显存紧张时 vLLM 更灵活，但也更容易 OOM。VLM 负载建议从 vLLM 起步。

## 七、结论

**默认选 vLLM，有明确场景再换**。前缀复用高的 Agent/多轮对话负载换 SGLang，固定模型追求单卡上限换 TensorRT-LLM，验证阶段用 TGI。任何引擎的选择都要用自己的真实负载压测验证——推理引擎的性能数字是「场景函数」，不是常数。换引擎是服务层的事，和上层业务解耦（OpenAI 兼容接口），所以**不用怕选错，但要怕不压测**。

**相关阅读**：[Continuous Batching 调度原理](/blog/2026/08/11/continuous-batching-deep-dive)、[PD 分离架构](/blog/2026/08/21/pd-separation-deep-dive)、[推理性能建模](/blog/2026/08/07/llm-inference-performance-modeling)。
