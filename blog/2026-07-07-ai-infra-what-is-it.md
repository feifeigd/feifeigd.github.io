---
title: "AI Infra 到底是什么"
date: 2026-07-07T22:20:00+08:00
draft: false
tags: ["ai", "infra", "mlops", "engineering"]
categories: ["Tech"]
description: "一张图讲清楚 AI Infrastructure 的四个层面"
---

## 一句话

**AI Infra = AI Infrastructure（AI 基础设施）**，指的是支撑 AI 系统从研发到落地全流程的底层技术栈。

只要你听过"大模型训练太贵了"、"推理速度不够快"、"GPU 利用率上不去"——这些问题的根都在 AI Infra 上。

---

## 四层架构

AI Infra 不是单一的东西，从上到下可以拆成四个层面：

### 1. 硬件层 — 算力的物理基础

这层最重、最贵，也是普通人最容易感知的部分：

- **GPU / NPU / TPU** — 算力核心。NVIDIA H100/B200 是当前主流，AMD MI300X 在追赶，Google 有自己的 TPU
- **高速互联** — 多卡多机通信的命脉：NVLink、InfiniBand、RoCE
- **存储系统** — 数据集和 checkpoint 的读写瓶颈：Lustre、GPFS、MinIO、JuiceFS

训练一个 70B 模型，单机 8 卡 H100 是不够的，需要几十上百台机器组集群，这时候 InfiniBand 的带宽决定了你"能不能卡在通信上"。

### 2. 编排层 — 算力怎么分、怎么调

硬件买回来只是开始，怎么让几十上百台机器跑起来是另一回事：

- **资源调度** — Slurm（学术圈标配）、Kubernetes + GPU Operator（工业界主流）、Volcano
- **任务调度** — 谁先跑、跑多久、失败了怎么重试：Apache Airflow、Ray
- **弹性/混部** — 训练和推理任务混合调度，提高 GPU 利用率

搞过 K8s 的人都知道，加上 GPU 之后调度复杂度直接翻倍——要处理 GPU 显存碎片、MIG 分区、节点选择、拓扑亲和性。这层是 AI Infra Engineer 最常打交道的地方。

### 3. 平台软件层 — 训练和推理的工程化

这层解决两个核心问题：**怎么训得快** 和 **怎么跑得稳**。

**训练方向：**

- PyTorch / JAX — 框架选型
- DeepSpeed、Megatron-LM、FSDP — 分布式策略：ZeRO、TP、PP、SP
- 混合精度训练（FP16/BF16/FP8）
- Checkpoint 管理和故障恢复

**推理方向：**

- vLLM、TensorRT-LLM、TGI、SGLang — 推理引擎
- PagedAttention、Continuous Batching、FlashAttention — 推理加速技术
- FP8/INT4/INT8 量化

**模型与数据管理：**

- MLflow、Hugging Face Hub、NVIDIA NIM — 模型注册和版本管理
- Spark、Ray Data、Dask — 数据预处理流水线

### 4. 服务/业务层 — 让模型真正可用

模型训练完了，要部署成线上服务，这层关注的是稳定性、可观测性和自动化：

- **推理网关** — Triton Inference Server、KServe，负责路由、限流、负载均衡
- **监控** — Prometheus + Grafana 盯 GPU 利用率、吞吐、P99 延迟
- **MLOps** — 自动评测、A/B 部署、模型回滚（Kubeflow、MLflow、Weights & Biases）

---

## 为什么 AI Infra 这么重要

三个字：**成本差**。

同样的 70B 模型，AI Infra 做得好的团队，训练成本可能是别人的 1/3，推理延迟可能是别人的 1/5。这不是夸张——DeepSpeed 的 ZeRO-3 能在同样硬件上省 60% 显存，vLLM 的 PagedAttention 能提升 2-4 倍推理吞吐。

另一个角度：**GPU 利用率就是钱**。

H100 一小时几十块的折旧成本，利用率从 30% 提到 80%，相当于 2.6 倍的硬件收益。AI Infra 干的就是这件事。

---

## 谁在干这个活

对应的职位通常是 **AI Infra Engineer** / **AI 基础设施工程师**，日常工作包括：

- GPU 集群的搭建、监控和维护
- 分布式训练的性能分析和优化
- 推理服务的延迟优化和稳定性保障
- MLOps 平台和 CI/CD 流水线的建设
- 存储和网络层面的性能调优

如果你在用 Rust / Go / C++ 做这些方向，非常明确就是 Infra 角色。

---

## 一张图总结

```
┌─────────────────────────────────┐
│  服务/业务层                     │
│  推理网关 · 监控 · MLOps · CI/CD│
├─────────────────────────────────┤
│  平台软件层                     │
│  PyTorch · DeepSpeed · vLLM    │
│  TensorRT · Triton · MLflow    │
├─────────────────────────────────┤
│  编排层                         │
│  K8s + GPU Op · Slurm · Ray   │
│  调度 · 弹性 · 混部             │
├─────────────────────────────────┤
│  硬件层                         │
│  GPU · InfiniBand · 分布式存储  │
└─────────────────────────────────┘
```

**AI Infra = 让 AI 模型能"算得快、训得起、部署稳"的底层工程体系。**

不是每个人都需要深入每一层，但理解这个分层结构，能帮你快速定位问题在哪层，以及你的工作落在哪个位置。
