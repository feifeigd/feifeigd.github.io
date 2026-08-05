---
title: "多模态大模型工程实践：视觉 token、动态分辨率与推理部署"
date: 2026-08-05T12:00:00+08:00
draft: false
tags: ["ai", "llm", "multimodal", "inference", "engineering"]
categories: ["Tech"]
description: "一张图 576 个 token？拆解 VLM 的视觉编码、token 压缩、动态分辨率与 vLLM 部署的关键工程问题"
---

2026 年的生产应用里，纯文本模型越来越少见——文档解析、截图问答、票据识别、视频审核，几乎每个场景都绕不开「看图」。但把图片塞进 LLM 不是免费的：一张 336×336 的图在 LLaVA 范式下要 576 个 token，比一段 500 字的中文还贵；一次文档问答可能吃掉数千 token 的 prefill。本文从架构、token 成本、数据管线、推理部署、评测五个角度，拆解 VLM 工程落地的关键问题，重点是可复现的数据与可执行的配置。

{/* truncate */}

## 一、三种架构路线

| 路线 | 代表 | 视觉编码 | 特点 |
|---|---|---|---|
| 双塔 + 投影（LLaVA 范式） | LLaVA-NeXT、Qwen2.5-VL | ViT + MLP 投影 | 开源主流，灵活可控 |
| 原生多模态 | GPT-4o、Gemini | 统一 token 空间 | 端到端对齐好，闭源 |
| 离散视觉 token | 早期 VQGAN 系 | 码本量化 | 训练复杂，已边缘化 |

开源路线里，Qwen2.5-VL 是目前工程化程度最高的之一：ViT-675M 视觉编码器 + 动态分辨率 + 2D 位置编码（M-RoPE），配合 72B/32B/7B 三档 LLM，部署形态灵活，也是本文展开的主要对象。

## 二、视觉 token 的成本模型

以 14×14 patch 的 ViT 为例，先算账：

- 336×336 图 → 24×24 = **576 token/张**
- 4 张 A4 文档扫描 → 约 2300 token
- 10 张产品图 → 约 5760 token
- 对比：中文 1000 字约 800–1500 token——**一张图相当于 300–600 字**

图片是「最贵的输入格式」，而且贵在 prefill：576 个视觉 token 参与全序列 attention，TTFT 随图片数量线性上涨。视频更夸张：10 秒 30fps 的视频逐帧送入就是 300 帧 × 每帧 token 数，直接打爆上下文，必须采样。

**动态分辨率（Qwen2.5-VL 方案）**：不再把图缩放到固定 336×336，而是按原图宽高比选分辨率，token 预算与像素数成正比（28×28 patch = 1 token），并设上下限：

```python
MIN_PX = 256 * 28 * 28   # 200,704 像素
MAX_PX = 1280 * 28 * 28  # 1,003,520 像素

def vision_tokens(w: int, h: int) -> int:
    px = min(max(w * h, MIN_PX), MAX_PX)
    return px // (28 * 28)

print(vision_tokens(336, 336))   # 144 token（LLaVA 范式是 576）
print(vision_tokens(1280, 720))  # 约 1175 token
```

同一张图，token 从 576 降到 144——这是 Qwen2-VL 引入的 2×2 token 合并（stride-14 ViT 输出后合并相邻 4 个 patch 再投影）带来的 4 倍压缩，配合 2D 位置编码避免空间信息错乱。**token 压缩是 VLM 性价比最高的架构优化，没有之一**：它同时降低 prefill 计算量、KV 占用与 TTFT。

## 三、数据与训练管线

VLM 的能力上限由数据决定。主流开源模型的数据构成：

1. **图像-文本对**：LAION 系网络数据，量大但噪声高，需清洗；
2. **交错图文**：网页/PDF 中的图文混排，训练「图文混排理解」；
3. **文档密集型数据**：OCR、表格、图表，直接决定 DocVQA/ChartQA 成绩；
4. **合成数据**：用强模型生成 caption 与问答对。

关键工程判断：**caption 质量 > 数据量**。LLaVA-1.5 用 GPT-4 生成的 64 万条对话数据，效果超过了此前数亿条弱对齐数据；Qwen2.5-VL 技术报告同样强调高质量 caption（recap）与数据去噪的重要性。训练阶段大致是「对比预训练 → 图文对齐 → SFT → 偏好对齐」，其中 SFT 数据里交错图文与文档类数据的配比，直接决定生产场景表现——想做好票据识别，就要在训练数据里多放票据。

## 四、推理部署的工程要点

**1. prefill 是 VLM 的 TTFT 瓶颈。** 纯文本 8K prompt 的 prefill 已经是 decode 的好几倍，VLM 加上图像后更甚。单图 144–576 token 看着不多，但全部参与全序列 attention。做容量规划时，把「图像 token 数 × 请求数」单独列一项，别只按文本长度算。

**2. 用 vLLM 的多模态支持。** vLLM 对 Qwen2.5-VL/LLaVA 等做了专门的 mm-processor（缩放、归一化、位置编码都在服务端完成），客户端只需传 base64/URL：

```bash
vllm serve Qwen/Qwen2.5-VL-7B-Instruct \
  --limit-mm-per-prompt image=5 \
  --max-model-len 32768 \
  --enable-prefix-caching
```

```python
resp = client.chat.completions.create(
    model="Qwen/Qwen2.5-VL-7B-Instruct",
    messages=[{"role": "user", "content": [
        {"type": "image_url",
         "image_url": {"url": "data:image/png;base64,..."}},
        {"type": "text", "text": "这张发票的总金额是多少？"}
    ]}],
)
```

**3. 图像特征缓存。** 同一张图被反复提问（截图问答、文档检索）时，前缀缓存能复用图像预处理后的 KV/特征；更进一步可在业务层做「图 → 特征向量」缓存，避免重复编码。注意图像编码的确定性会影响命中率：同一张图用不同分辨率编码会得到不同 token 序列，缓存 key 要带上尺寸与处理参数。

**4. 分辨率与 OCR 的权衡。** 低分辨率 token 少、便宜，但小字号文字直接糊掉。文档场景建议按 `MAX_PX`（1280 档）走，用 token 换准确率；UI 截图场景则可以压低分辨率。这个权衡要用自己的数据测，不能拍脑袋。

## 五、评测：MMMU 之外

| 模型 | MMMU | DocVQA | ChartQA | 备注 |
|---|---|---|---|---|
| GPT-4o | 69.1 | 94.4 | 85.7 | 原生多模态 |
| Gemini 1.5 Pro | 62.2 | — | — | 原生多模态 |
| Claude 3.5 Sonnet | 68.3 | — | — | 闭源 |
| Qwen2.5-VL-72B | 70.2 | 95.7 | 90.8 | 开源，动态分辨率 |
| Qwen2.5-VL-7B | 58.6 | 94.5 | 85.5 | 开源，7B 档 |

（数据来自各官方技术报告与发布公告，MMMU 为官方 val 集。）

- **MMMU**：大学多学科知识，偏「知识广度」，与工程场景相关性一般；
- **DocVQA / ChartQA / OCRBench**：文档与图表理解，**和办公自动化场景最相关**；
- 生产建议：按自己的任务建 200–500 条评测集（表格、票据、截图各一档），用 LLM-as-a-Judge 或规则打分并纳入 CI——具体做法见[评测工程化一文](/blog/2026/08/04/llm-eval-llm-as-judge)。

VLM 的两个常见失败模式要提前预期：**视觉幻觉**（图中没有的内容被「看」出来）和**低分辨率漏识别**。前者靠评测集拦截，后者靠分辨率策略缓解。

## 结论

VLM 工程化的本质是「用 token 换能力、用数据换质量」：**架构上动态分辨率 + token 合并把每张图的成本降 4 倍，数据上高质量 caption 比堆量有效，部署上 prefill 与图像缓存是吞吐关键，评测上文档类指标比 MMMU 更贴近生产**。先想清楚任务属于「文档理解」还是「开放视觉问答」，再决定模型档位与分辨率策略——这两类任务的最优解完全不同。

**相关阅读**
- [KV Cache 优化实战：长上下文推理的内存、量化与驱逐](/blog/2026/08/05/kv-cache-optimization-guide)
- [vLLM 架构详解：PagedAttention、Continuous Batching 与生产级推理优化](/blog/2026/07/26/vllm-architecture-deep-dive)
- [上下文工程：把 Context 当作一等资源来管理](/blog/2026/08/02/context-engineering-deep-dive)
- [LLM 评测的工程化：从基准分数到 LLM-as-a-Judge 的生产实践](/blog/2026/08/04/llm-eval-llm-as-judge)

**参考来源**
- Liu et al.: [Visual Instruction Tuning (LLaVA)](https://arxiv.org/abs/2304.08485)
- Liu et al.: [LLaVA-NeXT: Improved reasoning, OCR, and world knowledge](https://arxiv.org/abs/2401.01729)
- Wang et al.: [Qwen2-VL: Enhancing Vision-Language Model's Perception of the World at Any Resolution](https://arxiv.org/abs/2409.12191)
- Bai et al.: [Qwen2.5-VL Technical Report](https://arxiv.org/abs/2502.13923)
- Yue et al.: [MMMU: A Massive Multi-discipline Multimodal Understanding and Reasoning Benchmark](https://arxiv.org/abs/2311.16502)
- Bolya et al.: [Token Merging: Your ViT But Faster](https://arxiv.org/abs/2305.15300)
- OpenAI: [GPT-4o System Card](https://openai.com/index/gpt-4o-system-card/)
- Google: [Gemini 1.5: Unlocking multimodal understanding across millions of tokens of context](https://arxiv.org/abs/2403.05530)
- vLLM: [Multimodal Inputs 文档](https://docs.vllm.ai/en/latest/features/multimodal_inputs.html)
