---
title: "多模态 RAG 的检索层工程化：视觉后期交互（ColQwen）的账本、剪枝与踩坑"
date: 2026-10-10T20:30:00+08:00
draft: false
tags: ["ai", "llm", "rag", "multimodal", "embedding", "vector-database", "inference", "eval"]
categories: ["Tech"]
description: "文本 RAG 的信息损失发生在解析那一步。视觉后期交互（ColPali/ColQwen）把整页当图直接嵌入，ViDoRe 上比传统管线高一档，代价是多向量带来的存储与打分成本。本文算清这笔账：每页 755 个 128 维向量在 100 万页规模下是多少 GB、MaxSim 一次全量打分为什么不可能、token pooling 与 PLAID/MUVERA 怎么把成本压回工程可行区间，附可运行代码与六条踩坑。"
---

做 RAG 的后端工程师大多有过这样的经历：一套 PDF 解析（PyMuPDF + pdfplumber）、分块、embedding、rerank 的管线在技术文档上效果不错，一换到财报、合同、产品手册就开始掉分。检索出来的段落看着相关，但答案在表格的某个交叉格里、在某张流程图的标注里、或者依赖两栏排版的位置关系——这些信息在"解析成纯文本"的那一步就已经丢了。

[VisRAG](https://arxiv.org/abs/2410.10594) 这篇工作把这个损失量化过：不做文本解析、直接把文档页当图片用 VLM 嵌入，端到端比传统文本 RAG 管线高 20%~40%。这个数字不必照搬（它建立在自建的检索/生成数据上），但方向是明确的：**多模态文档的检索单元应该是"页"，而不是"段落"**。

本文不讨论 VLM 生成侧，只讲检索层怎么落地：三条技术路线的取舍、多向量的存储与算力账本、把成本压下来的四种手段，以及我自己在 ColQwen 上趟过的坑。前置阅读可以看 [RAG 进阶检索](/blog/2026/08/30/rag-advanced-retrieval) 和 [向量索引 HNSW/IVF-PQ](/blog/2026/10/09/vector-index-hnsw-ivfpq) 两篇。

{/* truncate */}

## 一、三条路线，差在哪

**路线 A：OCR/解析 + 文本 embedding。** 成熟、便宜、可解释，但你花钱买的是"文本重建质量"。表格合并单元格、公式、图注、页眉页脚噪声，每一样都在扣分。而且解析管线是脆的：换个 PDF 生成器就可能全崩。

**路线 B：VLM 单向量页嵌入（VisRAG 式）。** 整页图过一遍 VLM，池化成一个向量（常见 2048 维，可 Matryoshka 截断到 128）。好处极诱人：索引就是一个普通向量库，HNSW、量化、分片全部复用现有设施。代价是**整页压缩成一个向量**，信息瓶颈就在池化层——页面上三十个数字，池化后还剩多少信号？

**路线 C：多向量 + 后期交互（ColPali/ColQwen 式）。** 整页过 VLM，**不做池化**，保留每个 patch（视觉 token）的 128 维向量，打分时对每个 query token 在文档 token 上取最大相似度再求和，也就是 ColBERT 的 MaxSim：

```text
score(q, d) = Σ_{i ∈ q} max_{j ∈ d} ( q_i · d_j )
```

信息瓶颈消失了，代价是索引和检索成本上一个台阶——本文剩下的部分都在处理这个"代价"。

同一主干网络下两条路线的分差有多大？ViDoRe 榜单上有现成的对照，Gemma-3-4B 主干的两个模型几乎就是消融实验：

| 模型 | 类型 | ViDoRe 分数 |
|------|------|-------------|
| vidore/colpali（PaliGemma-3B，论文原版） | 多向量 | 81.3 |
| vidore/colpali-v1.3（调大 batch、3 epoch） | 多向量 | 84.8 |
| vidore/colqwen2-v1.0（Qwen2-VL-2B） | 多向量 | 89.3 |
| vidore/colqwen2.5-v0.2（Qwen2.5-VL-3B） | 多向量 | 89.4 |
| vidore/colSmol-256M（SmolVLM-256M） | 多向量 | 80.1 |
| tomoro-colqwen3-embed-4b（320 维） | 多向量 | 90.6 |
| Cognitive-Lab/NetraEmbed（gemma-3-4b） | **单向量**（Matryoshka） | 81.0 |
| Cognitive-Lab/ColNetraEmbed（gemma-3-4b） | **多向量**（22 语） | 86.4 |

NetraEmbed 和 ColNetraEmbed 是同一个 gemma-3-4b 主干、同一套多语言数据的单向量/多向量版本，分差 5.4 分。这就是后期交互买到的质量，也是你必须还的工程债。

## 二、账本：多向量到底贵多少

先固定一组真实形状。ColQwen2.5 模型卡的官方示例里，一条 query 编码成 `(25, 128)`，一页文档编码成 `(755, 128)`；`128` 是投影维度，`755` 是这一页的视觉 patch 数（该版本上限 768 个 patch）。

按 755 个向量、128 维来算每页成本：

| 表示方式 | 每页字节数 | 100 万页索引 | 单次全量打分的得分张量（fp32） |
|----------|-----------|--------------|------------------------------|
| 多向量 fp16 | 755 × 128 × 2 = 189 KiB | ~189 GB | 25 × 755 × 4 B = 75.5 KB/页 → 75.5 GB |
| 多向量 int8 | 94 KiB | ~94 GB | — |
| 多向量二值化（1 bit/维） | 11.8 KiB | ~12 GB | — |
| token pooling ×3 后 fp16 | 63 KiB | ~63 GB | — |
| 单向量 2048 维 fp16 | 4 KiB | ~4 GB | 一条 query 一个向量，直接 ANN |
| 单向量 128 维（Matryoshka 截断） | 256 B | ~256 MB | 同上 |

三行结论：

1. **存储是 40~700 倍量级差**。fp16 多向量对比 2048 维单向量是 47 倍，对比 128 维 Matryoshka 是 700 倍。百万页文档从"单机内存塞得下"变成"要正经规划磁盘和量化"。[Embedding 的 Matryoshka 与量化](/blog/2026/08/17/embedding-matryoshka-quantization) 那篇讲过的截断收益，在多向量这条路上没有对应物——投影维度已经压到 128 了。
2. **算力账**：每个 query token 对每个文档 token 做一次 128 维点积，一页是 25 × 755 × 128 × 2 = 4.8 MFLOP。100 万页全量扫一遍是 4.8 TFLOP/query。更致命的是那个 `(Lq, Ld)` 得分张量——它不能像单向量那样折叠成一次 ANN，100 万页一次性物化就是 75.5 GB，**内存先炸，不是算力先炸**。这就是为什么后期交互系统一定带"剪枝"这一层。
3. **维度上涨别忽视**。新一代模型（colqwen3 系、colqwen3.5）把 ColBERT 式向量从 128 维提到 320 维，每向量成本 2.5 倍：755 × 320 × 2 = 472 KiB/页，百万页就是 472 GB。选型时 90.9 分和 89.4 分差的 1.5 分，要拿 2.5 倍存储去换。

## 三、能跑起来的最小实现

### 3.1 渲染：DPI 决定 patch 数，patch 数决定一切

```python
# pip install pymupdf pillow
import io
import pymupdf
from PIL import Image

PATCH = 14        # Qwen2.5-VL 视觉侧 patch 尺寸
MERGE = 2         # spatial_merge_size，2x2 个 patch 合成一个视觉 token
PATCH_CAP = 768   # ColQwen2.5 版本上限

def render_pages(pdf_path: str, dpi: int = 150):
    doc = pymupdf.open(pdf_path)
    pages = []
    for page in doc:
        pix = page.get_pixmap(dpi=dpi)
        pages.append(Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB"))
    return pages

def est_visual_tokens(img: Image.Image) -> int:
    """估算一页会产出多少个视觉 token，用来在做索引之前预估存储和延迟"""
    w, h = img.size
    n = (w // (PATCH * MERGE)) * (h // (PATCH * MERGE))
    return min(n, PATCH_CAP)

if __name__ == "__main__":
    for dpi in (100, 150, 200):
        pages = render_pages("report.pdf", dpi=dpi)
        toks = [est_visual_tokens(p) for p in pages]
        kb = sum(t * 128 * 2 for t in toks) / 1024
        print(f"dpi={dpi:4d} pages={len(toks):3d} tokens={sum(toks):6d} "
              f"min/max={min(toks)}/{max(toks)} index_size={kb/1024:.1f} MiB")
```

把 `min/max` 打出来是刻意为之：同一份 PDF 里页面版式不同，token 数能差好几倍，存储和延迟的方差就是这么来的。**渲染 DPI 必须作为索引的一部分被固定下来**，不能今天 150 明天 200。

### 3.2 编码，和手写一遍 MaxSim

```python
# pip install "colpali-engine[plaid]" torch pillow
import torch
import numpy as np
from colpali_engine.models import ColQwen2_5, ColQwen2_5_Processor

DEVICE = "cuda:0"
MODEL_ID = "vidore/colqwen2.5-v0.2"

model = ColQwen2_5.from_pretrained(
    MODEL_ID, torch_dtype=torch.bfloat16, device_map=DEVICE
).eval()
processor = ColQwen2_5_Processor.from_pretrained(MODEL_ID)

def encode_pages(images, batch_size: int = 4):
    out = []
    for i in range(0, len(images), batch_size):
        batch = processor.process_images(images[i:i + batch_size]).to(DEVICE)
        with torch.no_grad():
            emb = model(**batch)                      # (B, n_patch, 128)
        out.extend(torch.unbind(emb.to(torch.float16).cpu()))
    return out                                        # List[(n_patch, 128)]

def encode_query(text: str):
    batch = processor.process_queries([text]).to(DEVICE)
    with torch.no_grad():
        emb = model(**batch)                          # (1, n_q, 128)
    return emb[0].to(torch.float16).cpu()

def maxsim(q: np.ndarray, d: np.ndarray) -> float:
    """q: (Lq, 128)  d: (Ld, 128)，两者都已 L2 归一化"""
    sim = q @ d.T                    # (Lq, Ld)
    return float(sim.max(axis=1).sum())

if __name__ == "__main__":
    pages = render_pages("report.pdf", dpi=150)[:4]
    docs = [v.numpy().astype(np.float32) for v in encode_pages(pages)]
    docs = [d / (np.linalg.norm(d, axis=1, keepdims=True) + 1e-9) for d in docs]
    q = encode_query("Which year did total outlay peak?").numpy().astype(np.float32)
    q = q / (np.linalg.norm(q, axis=1, keepdims=True) + 1e-9)
    print("query tokens:", q.shape, "page tokens:", docs[0].shape)
    for i, d in enumerate(docs):
        print(f"page {i}: maxsim={maxsim(q, d):.2f}   "
              f"eager_score_tensor={q.shape[0] * d.shape[0] * 4 / 1024:.1f} KiB")
```

注意最后打的那行：单页的 `(Lq, Ld)` 张量只有几十 KiB，看着无害；一旦你把 batch 里的几十万页一起喂进去，就是上一节算出来的 75 GB。**MaxSim 必须裁剪候选集，不能在全集上算。**

### 3.3 两阶段检索：把单向量当粗筛，多向量当精排

这是我在生产里最推荐的形状——不追求把多向量塞进向量库，而是让两者各干擅长的事：

```python
def encode_dense(vecs, dim: int = 128) -> np.ndarray:
    """把每页的多向量 mean-pool 成单向量，只用于一阶段 ANN 粗筛"""
    out = np.empty((len(vecs), dim), dtype=np.float16)
    for i, v in enumerate(vecs):
        a = v.numpy().astype(np.float32)
        a /= (np.linalg.norm(a, axis=1, keepdims=True) + 1e-9)
        mean = a.mean(axis=0)
        out[i] = (mean / (np.linalg.norm(mean) + 1e-9)).astype(np.float16)
    return out

def two_stage_search(q, doc_multi, doc_dense, top_k: int = 1000, final_k: int = 10):
    # 一阶段：单向量内积，走你现有的 HNSW/IVF 索引；1M 页毫秒级
    cand = np.argsort(-(doc_dense @ q.mean(axis=0))) [:top_k]
    # 二阶段：只在候选集上算 MaxSim
    # 1000 页 × 25 × 755 × 128 × 2 ≈ 4.8 GFLOP，单卡 GPU 毫秒级
    scored = [(maxsim(q, doc_multi[i]), int(i)) for i in cand]
    scored.sort(reverse=True)
    return scored[:final_k]
```

用 mean pooling 做粗筛是有意为之的"借用"：jina-embeddings-v4 的做法就是把 mean pooling 作为单向量池化策略（`single_vector_pool_strategy: "mean"`），同一个模型同时输出 2048 维稠密向量和 128 维多向量。粗筛只负责"别把正解漏掉"，召回率比排序质量更重要，所以它的维度（128/256/512）可以现场权衡。

踩坑提示：粗筛的 `top_k` 直接决定整体召回上限。我一般从 1000 起，把最终 top-10 的召回率和 `top_k` 画成曲线，找到拐点再定。

## 四、剪枝四件套

**1）token pooling：最划算的一招。** ColPali 团队的 `HierarchicalTokenPooler` 对图像 embedding 做层次均值池化。官方 README 给的实测结论是：池化因子取 3 时，**向量总数减少 66.7%，保留 97.8% 的原性能**。三行代码，存储和打分同时降 2/3：

```python
from colpali_engine.compression.token_pooling import HierarchicalTokenPooler

pooler = HierarchicalTokenPooler()
list_embeddings = [v.numpy() for v in encode_pages(pages)]
pooled = pooler.pool_embeddings(list_embeddings, pool_factor=3)
print([p.shape for p in pooled])   # 755 -> 约 250
```

这个方案还有个附加好处：它是 CRUDE 兼容的（文档可增可删，不需要重建全库），对增量更新的索引很友好。

**2）量化。** 上面表格里的 int8 和二值化把存储再降 2~16 倍。多向量的量化比单向量更"耐受"——因为 MaxSim 只取最大值、不做平均，个别向量的量化误差会被 max 操作吸收一部分。但**必须用你自己的评测集验证**，别照抄 leaderboard。

**3）PLAID / fast-plaid。** ColBERT 生态里最成熟的剪枝引擎：把每页看成"质心的袋子"，先用质心交互做粗筛、再做质心剪枝，避免在全部 token 上算完整 MaxSim。`colpali-engine` 直接支持：

```python
# pip install "colpali-engine[plaid]"
plaid_index = processor.create_plaid_index(doc_embeddings)      # List[(n_patch, 128)]
scores = processor.get_topk_plaid(query_embeddings, plaid_index, k=10)
```

**4）MUVERA / FDE。** [MUVERA](https://arxiv.org/abs/2405.19504) 的思路是给多向量构造固定维度的编码（Fixed Dimensional Encoding），把一个多向量问题**归约成单向量 MIPS**，从而直接复用现成的 ANN 索引和服务栈。如果你的向量库对多向量支持很差（这是常态），FDE 是比"两阶段 mean pooling"更有理论保证的路子，代价是编码本身对分布敏感、要调参数。

顺带一个训练/批量打分侧的优化：`colpali-engine[lik]` 装的 fused Triton MaxSim kernel 避免物化 `(B, B, Lq, Ld)` 那个二次增长的得分张量。官方在 80 GB H100、ColQwen2 + LoRA 的 benchmark 里，可训练最大 batch 从 64 提到 128，吞吐不变。用环境变量 `COLPALI_SCORES_BACKEND=lik` 强制启用。

## 五、踩坑记录

**1）预处理版本漂移会让召回断崖，而且不报错。** ColQwen2.5 模型卡明确写了一件事：`colpali-engine` 0.3.13 起不再发送该 checkpoint 训练时使用的 `"Query: "` 查询前缀，而 Sentence Transformers 侧的配置复现的是原始训练格式，**两边输出的 embedding 不完全一致**。也就是说：你用 colpali-engine 建索引、用 Sentence Transformers 查询（或者反过来），或者升级一次库版本，都会得到两套互不兼容的向量空间——它不会抛异常，只会让检索悄悄地变烂。我的做法是把 `model_id + revision + 查询前缀 + processor 实现` 作为索引元数据落库，任何一项变了就强制全量重建并跑回归。

**2）patch 上限决定了分辨率的收益边界。** ColQwen2.5 是动态分辨率、不缩放，默认最多 768 个 patch，模型卡的注释说"更多 patch 有明确收益，但内存代价同步上涨"。所以 DPI 不是越高越好，而是"到 768 为止"，再高只是浪费渲染时间和显存。反过来，如果为了省成本把 DPI 压到 100，一张密集表格里的细小文本可能在视觉 token 上已经糊掉了——**这个拐点要用自建评测集扫一遍，别拍脑袋**。

**3）框架支持是真实瓶颈。** vLLM 的 embedding 接口输出单向量，多向量要么走专门的 fused kernel，要么用别人预先"把 adapter 合并进主干"的权重（jina-embeddings-v4 就是按 retrieval / text-matching / code 三个任务分别发布合并版权重来换取 vLLM 原生兼容）。如果你的服务栈是 vLLM 统一托管，多向量大概率要单独部署一个 ColQwen 服务——这属于架构决策，不是调参问题。

**4）License 说法三方不一致，商用前必须自己核。** 这个坑比技术坑更贵：`vidore/colqwen2.5-v0.2` 在 HF 的 tags 里带 `license:mit`，模型卡正文却说"适配器 MIT，但主干 Qwen2.5-VL 受 Qwen Research LICENSE 约束"；而 colpali README 的模型表里同一行标的是 Apache 2.0。jina-embeddings-v4 也专门声明"此前误标 cc-by-nc-4.0，正确协议是 Qwen Research License"。教训很简单：**tags 字段不可信，往下追到主干模型的协议**。这与 [开源模型选型](/blog/2026/09/01/opensource-model-selection-eval) 里那条"License 是一等公民"的结论完全一致。

**5）MPS 上的 torch 版本坑。** 官方 README 记录：Mac 上用 MPS 跑 ColQwen 系列，torch 2.6.0 会报错，降到 2.5.1 解决。本地做 POC 的同事注意。

**6）检索单位是"页"，上下文成本要单独算。** 页级召回之后，你要么把整页图喂给 VLM，要么再做区域切分——前者 token 成本按 patch 数走，一张密集页可能顶十几段文本；后者等于把文本 RAG 的分块问题又请回来了，只不过这次有 token 级相似图可以辅助定位（多向量的可解释性优势，单向量给不了）。这一段的成本模型应该和检索精度一起评估，否则很容易出现"召回率涨了、单次问答成本涨了三倍"的局面。

## 六、自建评测与选型决策

ViDoRe 是页级英文学术+合成数据为主，你的语料（发票、PPT、扫描合同、中文年报）分布不同，榜单分数只用来排除明显不合格的模型。落地必须自建：

- **30~50 条 (query, 正解页)** 就够起步。标注成本远低于想象，收益是你能对 DPI、pool_factor、int8/binary、top_k 做四组 A/B。
- 指标看两个：nDCG@5（排序质量）和 **答案页是否进 top-5**（端到端可用性）。后者才是老板关心的。
- 同时记录三个成本指标：索引字节数、P99 检索延迟、单次问答喂给 LLM 的 token 数。

决策上我的经验是：

- 页面版式简单、以连续文字为主，且已有稳定解析管线 → 继续用文本 RAG，别为了时髦换栈。
- 文档里有表格/图表/多栏/扫描件，且索引规模在十万页以内 → 路线 C 直接上，多向量存储完全可控。
- 规模到百万页、又想复用现有向量库和分片 → 路线 B 或 **路线 C + FDE/两阶段**，把多向量限制在精排层。
- 只要能接受"少几分"就想要最低成本 → 路线 B + Matryoshka 截断到 128 维，每页 256 字节，这个量级下你甚至可以把索引放进内存。

后期交互不是"更好的 embedding"，它是一种**显式地用存储和算力换召回**的架构选择。把账本算清楚，这个选择才是工程决策，而不是信仰。

---

参考：ColPali（arXiv:2407.01449，ICLR 2025）、VisRAG（arXiv:2410.10594）、PLAID（arXiv:2205.09707）、MUVERA（arXiv:2405.19504）、jina-embeddings-v4（arXiv:2506.18902）、illuin-tech/colpali 仓库 README 与 vidore/colqwen2.5-v0.2 模型卡（文中数据均取自这些公开来源，存储与算力数字为按公开形状自算）。
