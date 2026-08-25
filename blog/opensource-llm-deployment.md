---
title: "开源 LLM 部署方案全景 — 从本地 Ollama 到生产级 vLLM 集群"
date: 2026-08-25T21:30:00+08:00
draft: false
tags: ["llm", "opensource", "vllm", "llama-cpp", "deployment", "gpu"]
categories: ["Tech"]
description: "开源大模型怎么部署？按算力场景分四档方案：Ollama 本地、vLLM 单机、多卡集群、国内云 GPU 实战，每条路都有可跑命令和显存预算。"
---

开源 LLM 怎么部署，取决于你手里有什么算力、要服务多少人。本文不讨论引擎内部机制（选型见[推理引擎选型](/blog/2026/08/23/inference-engine-selection)），只给**端到端部署方案**：按算力场景分四档，每档给可跑命令、显存预算和踩坑。

{/* truncate */}

## 一、方案全景：按算力场景选

| 场景 | 推荐方案 | 典型硬件 | 一句话理由 |
|---|---|---|---|
| 个人学习 / 办公辅助 | **Ollama + llama.cpp** | CPU 或 8G 显卡 | 一条命令跑起来，QQ 群级别的体验 |
| 团队内网 / 开发联调 | **vLLM 单机** | 单卡 24G（4090 起步） | OpenAI 兼容 API，吞吐稳定 |
| 生产 API（高并发） | **vLLM / SGLang 多卡** | 多卡 A100 / H100 | 张量并行 + Continuous Batching |
| 平台化（多模型多框架） | **Triton + KServe** | K8s 集群 | 统一调度、弹性扩缩、多框架托管 |

**核心决策变量只有两个：显存大小和并发量。** 显存决定能跑多大模型，并发量决定要不要上 vLLM 级别的调度器。

## 二、方案 A：本地个人用 — Ollama / llama.cpp

个人场景优先选 **Ollama**：它把 llama.cpp 封装成了一键体验，模型管理、OpenAI 兼容 API、CPU/GPU 自动调度全内置。

```bash
# 安装（Linux / macOS）
curl -fsSL https://ollama.com/install.sh | sh

# 拉模型并对话（自动选量化版，Q4 级别）
ollama run qwen2.5:7b

# 服务模式：默认监听 11434，OpenAI 兼容
ollama serve
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:7b","messages":[{"role":"user","content":"你好"}]}'
```

想要更底层的控制（指定量化档位、手动分配 GPU 层数），直接用 llama.cpp 的 `llama-server`，支持直接从 Hugging Face 拉 GGUF：

```bash
llama-server -hf bartowski/Llama-3.2-3B-Instruct-GGUF:Q8_0 --port 8080
# OpenAI 兼容端点：http://localhost:8080/v1/chat/completions
```

**GGUF 量化档位**：个人聊天起步 `Q4_K_M`（质量/体积平衡点）；写代码建议 `Q5_K_M` 或 `Q6_K`（代码对精度敏感）；显存实在紧张再降 `Q3_K_M`。

**显存预算表**（Q4_K_M 量化，含 KV cache 余量，约数）：

| 模型规模 | 权重占用 | 推荐显存 | 典型卡 |
|---|---|---|---|
| 3B | ~2GB | 4GB | CPU 也能跑 |
| 7B | ~4.5GB | 8GB | RTX 3060/4060 |
| 14B | ~9GB | 16GB | RTX 4080 |
| 32B | ~20GB | 24GB | RTX 4090 |
| 70B | ~40GB | 2×24G 或 48G+ | A6000 / A100 |

FP16 权重大约是 GGUF Q4 的 2 倍，显存不够就先量化，别硬扛。

## 三、方案 B：单机生产 — vLLM

要给团队/业务提供稳定的 API，上 vLLM。它自带 Continuous Batching（并发请求共享显存批处理）、PagedAttention（KV cache 按页分配防碎片）、OpenAI 兼容接口。

```bash
pip install vllm

vllm serve Qwen/Qwen2.5-7B-Instruct \
  --port 8000 \
  --gpu-memory-utilization 0.9 \
  --max-model-len 32768
```

验证：

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"讲个冷笑话"}]}'
```

**显存规划**：`权重 + KV cache`。`--gpu-memory-utilization 0.9` 表示权重外剩余显存的 90% 留给 KV cache——并发越高、上下文越长，KV cache 需求越大。显存紧张时调低这个值或缩短 `--max-model-len`，比换小模型快。

**量化部署**（显存减半）：vLLM 对 AWQ/GPTQ 支持最成熟。

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \
  --quantization awq \
  --gpu-memory-utilization 0.9
```

## 四、方案 C：模型获取与量化文件怎么选

### 下载渠道

- **海外/有代理**：Hugging Face 直连，`huggingface-cli download` 或直接让 vLLM/Ollama 拉
- **国内服务器**：**ModelScope**（阿里，国内直连快），模型 ID 与 HF 略有差异，先到 modelscope.cn 搜索确认：

```bash
pip install modelscope
python -c "
from modelscope import snapshot_download
snapshot_download('Qwen/Qwen2.5-7B-Instruct', cache_dir='/data/models')
"
```

### 量化格式选择

| 格式 | 生态 | 适用 |
|---|---|---|
| **GGUF** | llama.cpp / Ollama / LM Studio | CPU、苹果芯片、消费级显卡 |
| **AWQ / GPTQ** | vLLM / TensorRT-LLM | GPU 生产部署，精度损失小 |
| **FP8** | TensorRT-LLM / 新版 vLLM | H100 / 4090+，吞吐上限最高 |

**判断规则**：跑 llama.cpp/Ollama 系 → 找 GGUF（仓库名带 `-GGUF` 后缀）；跑 vLLM/TensorRT-LLM → 找 AWQ/GPTQ 版；新卡追求极致吞吐 → FP8。别把 GGUF 塞给 vLLM（vLLM 对 GGUF 支持是后补的，效果和性能都打折）。

## 五、方案 D：多卡与集群

### 单机多卡：张量并行

单卡放不下 70B 时，把模型切到多张卡上：

```bash
vllm serve Qwen/Qwen2.5-72B-Instruct \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9
```

TP 通信走 NVLink/PCIe，多卡之间带宽越高收益越大；跨机（多节点）一般用 DeepSpeed/其他方案，vLLM 多节点配置复杂度高，非必要不上。

### K8s 平台化：KServe + Triton

生产平台化的标准组合：

- **nvidia-device-plugin**：让 K8s 认识 GPU，Pod 按 `nvidia.com/gpu` 申请
- **KServe InferenceService**：声明式部署，指定模型仓库（HF/ModelScope 或 PVC），自动拉起 vLLM/TGI runtime，自带扩缩容
- **Triton Inference Server**：多框架统一（TensorRT/PyTorch/ONNX），一个服务暴露多个模型，适合存量模型杂的平台

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-7b
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: pvc://llm-models/qwen2.5-7b-instruct
      resources:
        requests:
          nvidia.com/gpu: "1"
        limits:
          nvidia.com/gpu: "1"
```

扩缩容按 GPU 利用率做 HPA：vLLM 的 Continuous Batching 让单实例吞吐很高，**副本数通常只按冗余和故障域算，别指望靠扩副本线性扛并发**。

## 六、国内云 GPU 实战链路

国内部署（AutoDL / 阿里云 / 腾讯云）的核心痛点：**HuggingFace、GitHub、PyTorch 官方源都慢**。完整链路：

**1. 网络：SSH 反向隧道借本地代理**（本地有 Clash 时最快）：

```bash
# 本地执行：把服务器的 1080 端口隧道到本地 7890
ssh -N -R 1080:127.0.0.1:7890 root@服务器IP

# 服务器上执行
export http_proxy=http://127.0.0.1:1080
export https_proxy=http://127.0.0.1:1080
```

没有本地代理就用镜像：pip 走阿里云镜像（注意 PyTorch CUDA 轮子镜像源常缺，直接 `--index-url https://download.pytorch.org/whl/cu124` 配合代理）、conda 用 conda-forge。

**2. 模型：ModelScope 下载**（见第四节）。

**3. 访问：SSH 本地端口转发**。国内云 GPU 实例公网 IP 常被 NAT，开不了端口，用反向转发：

```bash
# 本地执行：把服务器的 8000 端口映射到本地 18000
ssh -N -L 18000:127.0.0.1:8000 root@服务器IP
# 浏览器打开 http://localhost:18000
```

**4. 算力选择**：入门选 T4（便宜、显存 16G，跑 7B Q4 或 14B 没问题）；认真部署选 4090（24G，32B 量化可跑）；训练/大模型选 A100/H100。

## 七、前端与统一网关

模型服务只是后端，日常使用还差一层入口：

- **Open WebUI**：开箱即用的聊天前端，一条命令接 Ollama/vLLM，支持多用户、RAG、联网搜索
- **LobeChat**：体验更好的多模型聚合前端，自托管部署见[上篇](/blog/lobechat-docker-deploy)
- **LiteLLM**：统一网关——一个 API Key 路由到 Ollama、vLLM、DeepSeek、OpenAI 多后端，团队切换模型零改动

```bash
# LiteLLM 把本地 vLLM 和云端 DeepSeek 挂到同一个网关
litellm --model vllm/qwen2.5-7b --api_base http://localhost:8000
litellm --model deepseek/deepseek-chat --api_key sk-xxx
```

## 八、选型决策表与总结

| 你的情况 | 直接抄作业 |
|---|---|
| 个人电脑，想本地玩模型 | Ollama + qwen2.5:7b |
| 公司内网，几十人用 | 4090 单卡 + vLLM（7B/14B AWQ） |
| 线上业务，高并发 | 多卡 vLLM/SGLang + K8s + HPA |
| 国内云 GPU，不想折腾网络 | ModelScope + SSH 隧道 + vLLM |
| 多模型多框架并存 | Triton/KServe + LiteLLM 网关 |

开源 LLM 部署的本质是**用显存换体验，用调度换吞吐**：显存不够先量化（GGUF/AWQ），并发不够再上调度器（vLLM）。所有方案都提供 OpenAI 兼容 API，上层业务永远不用改——这也是开源生态最值钱的地方：**方案可以随时换，接口不用动**。

相关阅读：[LLM 推理引擎选型：vLLM、SGLang、TensorRT-LLM、TGI 到底怎么选？](/blog/2026/08/23/inference-engine-selection)、[LobeChat 自托管部署指南](/blog/lobechat-docker-deploy)、[Tesla T4 云服务器部署 ComfyUI + CogVideoX](/blog/comfyui-cogvideox-t4-deploy)
