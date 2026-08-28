---
title: "流式 TTS 合成工程：延迟预算、模型选型与评测回环"
date: 2026-08-28T18:00:00+08:00
draft: false
tags: ["ai", "llm", "multimodal", "tts", "engineering", "performance"]
categories: ["Tech"]
description: "语音 Agent 的体验差距经常死在最后一跳：TTS。三代架构怎么选？流式合成怎么做到首包 200ms？中文多音字怎么消歧？MOS 之外用什么客观指标验收？附可运行的 CosyVoice2 流式合成、ASR 回环评测与 WebSocket 流式服务骨架。"
---

语音 Agent 的体验差距，经常不是死在 ASR 听错，而是死在最后一跳：**合成的声音不够快、不够自然**。上一篇 [语音 Agent 与流式 ASR](/blog/2026/08/20/streaming-asr-voice-agent-engineering) 讲了 VAD、ASR 和打断，本篇专攻合成侧：模型选型、流式机制、中文特有的工程坑、以及一套不依赖人耳的评测方法。

先把预算摆出来：语音场景 800ms 的端到端延迟预算里，TTS 通常只能分到 300-400ms，其中**首包延迟（TTFB）是硬指标**——用户听到第一个字之前的所有环节，VAD、ASR、LLM、TTS，都在为这 800ms 打工。

## 一、三代 TTS 架构：选型先看你要什么

**第一代：自回归系（VALL-E / XTTS）**。神经编解码器（EnCodec 这类）把音频打成离散 token，再用 transformer 逐 token 生成。VALL-E 在 2023 年证明了 3 秒参考音频就能克隆音色，这是声音克隆的起点。代价：逐 token 生成天然慢，长句容易重复、吞字，而且**不支持流式**。今天的定位基本只剩离线高质量生成。

**第二代：非自回归系（VITS / FastSpeech 2）**。一步出整句 mel 谱，快、稳、RTF 极低，但克隆能力弱、韵律平。适合 IVR 播报这类对音色无要求的场景，或者作为流式拼接链路的底层单元。

**第三代：Flow Matching / DiT 系（F5-TTS / CosyVoice2）**。把语音生成建模成流匹配问题，推理步数可压缩——F5-TTS 默认 10 步，论文报告单卡 A100 上 RTF 约 0.15（RTF = 合成耗时 / 音频时长，低于 1 才够实时，流式场景要更低）。CosyVoice2 走 LLM + Flow 双栈，官方口径是把流式合成延迟压到 150ms 量级、推理速度较上一代提升约 50%。零样本克隆 + 可控步数 = 自然度与速度兼得，是 2026 年生产的事实标准。

| 维度 | 自回归 | 非自回归 | Flow/DiT |
|------|--------|----------|----------|
| 自然度 | 高 | 中 | 高 |
| 声音克隆 | 强（3s 提示） | 弱 | 强 |
| 推理速度 | 慢 | 极快 | 快 |
| 原生流式 | 不支持 | 不支持 | 支持（如 CosyVoice2） |
| 代表模型 | VALL-E、XTTS | VITS、FastSpeech2 | F5-TTS、CosyVoice2 |

选型结论：**做语音 Agent 直接选 Flow/DiT 系**；做稳定的播报机器人可以用 VITS 系省 GPU；自回归留给离线精修。别在自回归模型上硬做流式——那是在给架构缺陷打补丁。

## 二、流式合成的两条路线

**路线 A：模型原生流式**。CosyVoice2 的 speech token 是流式产出的，`stream=True` 就能边生成边吐音频块，这是延迟最低的路线：

```python
from cosyvoice.cli.cosyvoice import CosyVoice2
import torchaudio

cosyvoice = CosyVoice2("pretrained_models/CosyVoice2-0.5B",
                       load_jit=False, load_trt=False, fp16=False)

prompt_wav, sr = torchaudio.load("ref.wav")   # 3-10 秒参考音频
prompt_speech_16k = torchaudio.transforms.Resample(sr, 16000)(prompt_wav)

# stream=True：每个 chunk 出来立刻可以推给客户端
for chunk in cosyvoice.inference_zero_shot(
    "今天上海多云转晴，气温二十四到三十一度。",
    "希望你以后能够做的比我还好呦。",   # 参考音频的原文，用于对齐
    prompt_speech_16k,
    stream=True,
):
    torchaudio.save("chunk.wav", chunk["tts_speech"], cosyvoice.sample_rate)
    # 这里把 chunk 编码成 opus 推 WebSocket
```

**路线 B：chunk 级流式封装（模型无关）**。任何非流式模型都能切成块：按句/按标点切，块间透传上下文。两个坑必须处理：句边界韵律断裂、块间静音过长。做法是 overlap——把上一句结尾的 200ms 作为下一句的 prompt 前缀，让模型"接着读"而不是"重新读"。服务骨架：

```python
import asyncio
from fastapi import FastAPI, WebSocket

app = FastAPI()

def tts_one(sentence: str) -> bytes:      # 任意非流式模型，返回 24k PCM
    ...

async def synthesize(text: str):
    for sent in split_sentences(text):
        yield tts_one(sent)               # 逐句合成即推，不等整段

@app.websocket("/tts")
async def tts_ws(ws: WebSocket):
    await ws.accept()
    text = await ws.receive_text()
    async for chunk in synthesize(text):
        await ws.send_bytes(chunk)        # 帧头带上 seq 与句子边界标记
    await ws.close()
```

端到端延迟预算的典型量级：VAD 50-100ms + 流式 ASR 150-250ms + LLM 首 token 100-300ms + TTS 首包 150-300ms。TTS 段能抠的点：模型常驻 warmup（首次推理含权重加载和图编译，可能多出几百 ms）、首 chunk 用低步数、文本归一化放到与 LLM 并行的流水线里做。

## 三、中文 TTS 的特有坑：归一化与多音字

英文数字转读法靠规则就能覆盖九成，中文不行——"二十四"和"两千四百"的读法规则、单位量词的搭配、"一行代码"和"银行行长"的多音，规则表写起来是无底洞。**文本归一化 + G2P 是中文 TTS 的前端核心，不是模型的事**。

最小归一化实现（整数和百分比，够演示思路）：

```python
import re

CN_NUM = "零一二三四五六七八九"

def num_to_cn(n: int) -> str:
    if n < 10:
        return CN_NUM[n]
    if n < 100:
        tens = "" if n < 20 else CN_NUM[n // 10] + "十"
        return tens + (CN_NUM[n % 10] if n % 10 else "")
    return str(n)   # 三位以上兜底给 G2P

def normalize(text: str) -> str:
    text = re.sub(r"(\d+)%", lambda m: f"百分之{num_to_cn(int(m.group(1)))}", text)
    text = re.sub(r"(?<!\d)(\d{1,2})(?!\d)", lambda m: num_to_cn(int(m.group(1))), text)
    return text
```

多音字消歧，2026 年的生产做法是 **LLM 前端**：把句子丢给一个小模型，输出拼音 + 停顿位置 + 情感标记，一次把 G2P 和韵律控制全做掉：

```text
输入: 重庆的银行行长今天下午到达重庆北站。
输出: {"pinyin": "chong2qing4 ... hang2zhang3 ...",
       "pauses": [4, 12], "emotion": "neutral"}
```

踩坑记录：LLM 前端本身有 30-80ms 延迟，必须与 TTS 合成并行流水线化，否则它自己就成了延迟大头；生产上建议规则优先、LLM 兜底——常见词查表秒出，查不到的再走模型，把 LLM 调用量压到一成以下。

## 四、声音克隆：zero-shot 的工程真相

原理一句话：参考音频抽说话人表征（嵌入或 speech token），文本条件生成时把音色"带"过去。VALL-E 证明 3 秒可行，CosyVoice2 把跨语种克隆做进了同一条流水线——中文参考音色直接说英文。工程上真正决定成败的不是模型，是参考音频：

- **质量上限**：16k 采样、无噪声、3-10 秒、内容与目标文本无关
- **必须预处理**：VAD 裁剪 + 响度归一，别拿整段播客去克隆
- **合规**：克隆真实人物音色上生产，先过授权关

## 五、评测：MOS 会骗人，回环才客观

人工 MOS 贵、慢、不稳定。UTMOS 这类预测器论文报告系统级 Spearman 相关约 0.94、句子级只有约 0.5——**适合给系统排序，不适合逐句验收**。生产三件套：

**1. ASR 回环（可懂度）**：合成 → ASR 转写 → 算 CER。这是回归测试的必备件，改前端、换模型、调步数，跑一遍回环就知道有没有退化：

```python
from faster_whisper import WhisperModel
import numpy as np

model = WhisperModel("small", device="cpu", compute_type="int8")

def cer(ref: str, hyp: str) -> float:
    dp = np.zeros((len(ref) + 1, len(hyp) + 1), dtype=int)
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1,
                           dp[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    return dp[len(ref)][len(hyp)] / max(1, len(ref))

ref = "今天上海多云转晴"
segments, _ = model.transcribe("tts_out.wav", language="zh")
hyp = "".join(s.text for s in segments)
print(f"CER = {cer(ref, hyp):.2%}")
```

注意回环用 whisper small 做基线就够了，别用大模型——它的纠错能力会把 TTS 的口齿不清"修好"，测不出问题。

**2. SPK-SIM（音色相似度）**：说话人嵌入（WeSpeaker / ResNet34 系）的余弦相似度，验收克隆效果。经验阈值：同人同设备一般 0.8 上下，克隆验收从 0.6 起，低于 0.5 基本是克隆失败了。

**3. RTF 与首包延迟（性能）**：压测统计合成耗时 / 音频时长，目标 RTF 低于 0.3（给编码、网络留余量）；流式场景额外记 TTFB 和 chunk 间隔抖动——chunk 间隔抖动比平均延迟更伤听感，用户听的是"卡不卡"，不是"平均多少毫秒"。

## 六、实战踩坑清单

- **chunk 边界爆破音**：块间加 10-20ms 交叉淡入淡出，或把上句末尾作下句 prompt 前缀；两招都试过，后者对自然度提升更明显
- **首包慢的隐藏原因**：模型 warmup（首次推理）、G2P 未预热、归一化在合成线程里串行做——把这三样都提前，首包能砍掉一截
- **并发上限**：TTS 是计算密集任务，多路并发按 RTF × 显存反推，别裸开线程池；FP16 比 FP32 省一半显存，先开 FP16
- **长文本切句**：超过 30 秒的合成任务必须前端切句、后端逐句流式返回，等整段合成就别谈延迟了
- **格式统一**：内部 24k/16bit PCM，出口按端侧转 opus/PCM；采样率转换只在出口做一次，别在合成路径里反复转
- **预合成缓存**：欢迎语、系统播报这类高频固定文本，预合成 + 语义 hash 缓存，命中直接推音频，连模型都不进

## 小结

2026 年做 TTS 的路线图很清晰：模型选 Flow Matching/DiT 系（F5-TTS、CosyVoice2），流式优先用模型原生能力、次选 chunk 封装，中文必须自建归一化 + G2P 前端，验收靠 ASR 回环 + SPK-SIM + RTF 三件套。语音 Agent 的体验优化顺序建议先攻 TTS——用户对"答得快不快、声音像不像人"的感知，比对 LLM 智商差异敏感得多。合成侧补齐之后，接上 [语音 Agent 全链路](/blog/2026/08/20/streaming-asr-voice-agent-engineering) 和 [多模态 VLM 工程](/blog/2026/08/05/multimodal-vlm-engineering-guide)，多模态 Agent 的地基就齐了。
