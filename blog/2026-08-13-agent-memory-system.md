---
title: "大模型 Agent 的记忆系统：从上下文窗口到长期记忆的完整设计"
date: 2026-08-13T18:00:00+08:00
draft: false
tags: ["ai", "llm", "agent", "rag", "memory"]
categories: ["AI"]
description: "Agent 为什么越聊越健忘？上下文窗口不是记忆，长上下文也解决不了跨会话遗忘。这篇从记忆分层（工作/短期/长期）、写路径打分（recency+importance+relevance）、读路径检索、记忆固化（reflection）四步，讲清一套可落地的 Agent 记忆系统，附可运行 Python 与 benchmark 数据。"
---

> 一个 agent 连续跟你工作三周后，突然忘了你的数据库密码格式约定、忘了上周定的接口规范——这不是 bug，是它的记忆系统根本没设计。上下文窗口是「RAM」，断电（会话结束）就没了；真正的记忆系统，是往 RAM 之外再加一层「硬盘 + 索引」。

{/* truncate */}

## 一、为什么「上下文窗口」不是记忆

先破除一个常见误解：把上下文窗口调大（128k、200k、1M），不等于 agent 有了记忆。它只是把 RAM 加大了，没改变三件事：

1. **会话边界即失忆**。窗口里的内容会话一结束就清空，下次启动从零开始。你上周教它的约定，它一个字都不记得。
2. **窗口越大越贵、越慢**。输入 token 按量计费，注意力还是 O(n²)（这块今天上午那篇 [《为什么标准 Attention 的 O(n²) 绕不开》](/blog/2026/08/13/attention-n2-softmax-mathematical-origin) 拆过数学根源），长上下文推理时延非线性上涨。
3. **长上下文本身会漏**。斯坦福的 **"Lost in the Middle"** 实验证明：把答案藏在长上下文中间位置，模型 recall 呈现明显的 U 形曲线——开头和结尾记得住，中间一大段直接漏掉。窗口再大，中间的信息照样丢。

所以记忆系统的目标不是「塞更多」，而是**把该留的东西抽离出窗口，按需取回**。这需要回答四个问题：**存什么**（记忆分层）、**怎么判断值不值得存**（写路径）、**用的时候怎么找回来**（读路径）、**旧记忆怎么升级**（固化）。

---

## 二、记忆分层：工作 / 短期 / 长期

认知科学里把人类记忆分成工作记忆、情景记忆、语义记忆、程序性记忆。工程上把它映射成一张表：

| 层级 | 对应概念 | 载体 | 生命周期 | 典型容量 |
|------|----------|------|----------|----------|
| 工作记忆 | 当前推理的 scratchpad | 上下文窗口 + 当前 tool 结果 | 单次调用 | 受窗口限制 |
| 短期记忆 | 本次会话的对话历史 | 滑动窗口 / 摘要缓存 | 单次会话 | 几十轮 |
| 情景记忆（Episodic） | 「发生过什么事」 | 带时间戳的事件流 + 向量库 | 跨会话持久 | 长期 |
| 语义记忆（Semantic） | 「关于用户/世界的稳定事实」 | 结构化 store（KV/图） | 跨会话持久 | 长期 |
| 程序性记忆（Procedural） | 「怎么做这件事」 | skill / SOP 文档 | 跨会话持久 | 长期 |

关键的区分是**情景 vs 语义**：

- 情景记忆是「2026-08-13 下午，用户说要把日志级别从 DEBUG 改成 INFO」——带时间、会过期、可能被推翻。
- 语义记忆是「这个项目的日志规范是 INFO 起步，不要打敏感字段」——稳定的、长期有效的事实。

把两者混在一个向量库里，是记忆系统最常见的工程失误：一条过期的情景记忆会「污染」稳定事实的检索结果。下面会展开。

### MemGPT 的 OS 类比

**MemGPT**（Packer et al., 2023）把这件事推到了最清晰的形态——直接把 LLM 上下文当操作系统内存管理：

- **main context（主上下文）**：固定 token 预算的「物理内存」，装当前任务最需要的东西。
- **external context（外部上下文）**：放不下时先挪到这里的「换页空间」。
- **recall / archival storage（归档存储）**：长期记忆，存到向量库/数据库。

它给 LLM 一整套 `core_memory_append / recall / archival_insert` 这样的 function call，让模型**自己决定什么时候把哪段记忆换页出去、什么时候召回**。这套「内存自管理」的收益是实的：在多会话聊天和文档 QA 的 deep memory 任务上，MemGPT 的 recall 显著超过固定上下文的 GPT-4——因为它不是「把全部历史塞进去祈祷模型自己挑」，而是主动把相关信息召回进窗口。

---

## 三、写路径：什么样的记忆值得存？

记忆不能全存——存多了检索噪声爆炸，成本也扛不住。所以写路径的核心是一个**打分函数**。斯坦福 **Generative Agents**（Smallville 小镇，25 个 agent）给了一套至今仍是最实用的打分公式：

```
score = α_recency · recency + α_importance · importance + α_relevance · relevance
```

三个分量分别解决三个问题：

- **recency（新近度）**：越近的事件越重要，用指数衰减模拟遗忘曲线。
- **importance（重要性）**：LLM 打分（1~10），「用户改了密码约定」比「打了个招呼」重要得多。
- **relevance（相关性）**：记忆 embedding 与当前查询的余弦相似度。

落地成可运行代码：

```python
import math
import time
import numpy as np
from dataclasses import dataclass

@dataclass
class Memory:
    id: str
    content: str
    created_at: float          # unix 时间戳
    importance: float          # 1~10，LLM 打分
    embedding: np.ndarray      # 语义向量，dim = d

class MemoryWriter:
    def __init__(self, decay_factor: float = 0.995,       # 每小时衰减
                 a_rec=1.0, a_imp=1.0, a_rel=1.0):
        self.decay_factor = decay_factor
        self.a_rec, self.a_imp, self.a_rel = a_rec, a_imp, a_rel
        self.store: list[Memory] = []

    def importance_score(self, content: str, llm) -> float:
        # 让 LLM 给 1~10 打分；生产里用结构化输出 + 缓存避免重复调用
        return llm.rate_importance(content)  # 返回 1~10

    def _cosine(self, a: np.ndarray, b: np.ndarray) -> float:
        return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-8))

    def score(self, m: Memory, query_emb: np.ndarray, now: float) -> float:
        hours = (now - m.created_at) / 3600.0
        recency = self.decay_factor ** hours              # 指数衰减，模拟遗忘
        relevance = self._cosine(query_emb, m.embedding)
        return (self.a_rec * recency
                + self.a_imp * (m.importance / 10.0)      # 归一化到 [0,1]
                + self.a_rel * relevance)

    def should_store(self, content: str, emb: np.ndarray,
                     llm, threshold: float = 0.5) -> bool:
        # 低价值信息（重要性低、与当前任务无关）直接丢弃，不写库
        m = Memory(id=..., content=content, created_at=time.time(),
                   importance=self.importance_score(content, llm),
                   embedding=emb)
        return self.score(m, emb, time.time()) >= threshold
```

这个 `should_store` 门控是很多人漏掉的一步：**不是「有信息就存」，而是「过了阈值才存」**。没有它，记忆库会被「用户说嗯」「收到」「好的」这种垃圾淹没。

---

## 四、读路径：用的时候怎么找回来

读路径决定 agent 用记忆时的命中率，比写路径更影响体验。三个必须做的动作：

### 1. 混合检索（hybrid search）

纯向量检索会漏掉精确匹配（项目名、版本号、ID）。工程标准做法是 dense（向量）+ sparse（BM25）双路召回，再融合：

```python
class MemoryReader:
    def __init__(self, vec_index, bm25_index):
        self.vec_index = vec_index          # FAISS / Milvus 之类
        self.bm25_index = bm25_index        # 倒排索引，精确词匹配

    def retrieve(self, query: str, query_emb: np.ndarray,
                 top_k: int = 10, alpha: float = 0.5) -> list[Memory]:
        vec_hits = self.vec_index.search(query_emb, top_k)     # 语义召回
        sparse_hits = self.bm25_index.search(query, top_k)     # 关键词召回
        # RRF (Reciprocal Rank Fusion)：按排名倒数融合，无需调分数尺度
        fused = {}
        for rank, hit in enumerate(vec_hits):
            fused[hit.id] = fused.get(hit.id, 0) + alpha / (rank + 60)
        for rank, hit in enumerate(sparse_hits):
            fused[hit.id] = fused.get(hit.id, 0) + (1 - alpha) / (rank + 60)
        return sorted(fused, key=fused.get, reverse=True)[:top_k]
```

RRF 不用归一化两路分数，直接按排名倒数求和，是生产里最省心的融合方式。

### 2. 时间衰减过滤

记忆带时间戳是有原因的——一条 6 个月前说「临时用 demo 数据库」的记忆，不该继续压过今天说的「切到生产库」。检索后按 recency 加权重排：

```python
def rerank_by_recency(self, memories: list[Memory], now: float, tau: float = 30.0):
    # 时间加权：每 30 天衰减一半，旧的慢慢沉底而不是直接删
    def weight(m):
        return 0.5 ** ((now - m.created_at) / (tau * 86400))
    return sorted(memories, key=lambda m: -weight(m))
```

### 3. 语义 / 情景分离

回到第二节的坑：**情景记忆和语义记忆要分库，或至少分区过滤**。检索「这个项目的日志规范是什么」时，不应该被「8 月 3 号那次 debug 日志打太多了」这种过期事件干扰。简单做法是给记忆加 `type` 字段，检索时按需过滤：

```python
memories = store.search(query, filter={"type": "semantic"})   # 只要稳定事实
events   = store.search(query, filter={"type": "episodic"})   # 只要事件流水
```

---

## 五、记忆固化：让旧记忆「升级」而不是堆积

只写不整理，记忆库会变成一个巨大的、自相矛盾的流水账。**固化（consolidation）**是记忆系统的成人礼，两种典型形态：

### 1. Reflection（反思提炼）

Generative Agents 的核心机制：定期把最近一批低层级观察喂给 LLM，让它提炼出**更高层级的洞察**，写回为新的记忆。模拟人类「把经历总结成经验」：

```python
def reflect(self, llm, top_n: int = 100) -> list[str]:
    recent = self.store[-top_n:]                      # 最近 N 条事件
    if len(recent) < top_n:
        return []
    prompt = (
        "下面是一个 agent 最近 {n} 条工作记录。"
        "请提炼出 3 条比原记录更高层级的、对未来有用的洞察或规律，"
        "用陈述句输出，每条一行，不要重复已有事实：\n\n"
        "{records}"
    ).format(n=len(recent), records="\n".join(m.content for m in recent))
    insights = llm(prompt)
    return [line for line in insights.strip().splitlines() if line.strip()]
```

提炼出的洞察（如「用户偏好 INFO 级日志，且所有日志必须带 trace_id」）作为新的语义记忆写入，旧的 100 条事件可以降权或归档。

### 2. 摘要压缩 + 去重合并

短期记忆滑出窗口前，把它压缩成摘要；长期记忆里语义相近的条目合并，避免「同一条事实存了 8 个版本」：

```python
def consolidate(self, llm):
    # 去重：向量相似度超过阈值视为同一事实，保留最新的
    to_merge = self._find_duplicates(threshold=0.92)
    for group in to_merge:
        newest = max(group, key=lambda m: m.created_at)
        self.store = [m for m in self.store if m not in group or m is newest]
```

---

## 六、生产踩坑记录

这套东西我实际搭过几版，踩过的坑比设计决策多：

1. **幻觉记忆（最危险）**：agent 会把「自己生成的推测」当「观察到的真事」写进记忆库。必须把「观察/事实」和「推断/计划」分字段存，只允许事实进语义记忆，推断永远标 `uncertain=True` 且带来源。

2. **记忆污染 vs 检索噪声是两回事**：污染是「不该进的进了」，噪声是「检索带回了不相关的」。前者靠写路径门控 + 类型隔离解决，后者靠 RRF 融合 + rerank 解决，别混着调参。

3. **重要性打分别每句都调 LLM**：一个 session 几百条消息，逐条打分又慢又贵。用规则预筛（长度、是否含命令/结论关键词），只有候选信息才进 LLM 打分。

4. **embedding 模型切换是灾难**：记忆库的向量是某个模型算出来的，换 embedding 模型后余弦相似度语义全乱。切模型要么全量重算，要么存 `model_version` 字段、旧向量只做粗召回不做精排。

5. **隐私和权限**：长期记忆会攒下大量敏感信息（密钥、内部约定）。至少做到：敏感字段单独加密、记忆带 `owner`/`scope` 做访问隔离、支持一键删除单条记忆。

---

## 总结

Agent 记忆系统的本质，是**把「该记的」从易失的上下文窗口里抽出来，放进一个可写、可查、可升级的外部存储，并在每次推理时按需取回**。

| 环节 | 要回答的问题 | 关键手段 |
|------|--------------|----------|
| 分层 | 存什么 | 工作/短期/长期，情景 vs 语义分离 |
| 写路径 | 值不值得存 | recency + importance + relevance 打分 + 阈值门控 |
| 读路径 | 怎么找回来 | 混合检索（RRF 融合）+ 时间衰减 + 类型过滤 |
| 固化 | 旧记忆怎么升级 | reflection 提炼 + 摘要压缩 + 去重合并 |

一句话收尾：**上下文窗口决定 agent 这一刻能想多深，记忆系统决定它长期能走多远。** 前者买硬件就有，后者只能靠设计。
