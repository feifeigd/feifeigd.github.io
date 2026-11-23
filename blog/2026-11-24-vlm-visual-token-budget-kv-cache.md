---
title: "VLM 的视觉 Token 不是常数：分辨率、merge 率与 KV Cache 账单的工程算术"
date: 2026-11-24T01:30:00+08:00
draft: false
tags: ["multimodal", "inference", "kv-cache", "performance", "vllm"]
categories: ["Tech"]
description: "一张 4K 截图在 Qwen2.5-VL 上是 10549 个 token，占 0.56 GiB KV；32 路并发各带三张就是 54 GiB。视觉 token 是分辨率的函数，不是常数——把公式、KV 账单、准入控制和内容寻址缓存 key 一起算清楚，才能解释线上那些『延迟莫名其妙翻了五倍』的多模态请求。"
---

一个纯文本请求的 token 数，你能从字符串直接估出来；一个带图请求的 token 数，取决于图片分辨率、patch 大小、merge 率、以及 processor 的 resize 策略——四个因素相乘，跨度能到两个数量级。同一个「上传一张截图」的接口，用户传 224×224 的图标是 64 个视觉 token，传 4K 显示器截图是 10549 个，差 165 倍。中间没有任何报错，只有延迟和显存账单悄悄变成另一种东西。

这篇把三件事算清楚：视觉 token 怎么算（四家主流程模型的公式差异）、token 怎么变成 KV Cache 字节、以及为什么多模态的前缀缓存命中率总是比纯文本低一个数量级。所有表格数字来自文中的脚本实际跑出来的输出，你可以直接改参数复算。

{/* truncate */}

## 一、视觉 token 是分辨率的函数

主流 VLM 的图像编码路径是同一套骨架：把图切成固定大小的 patch，过 ViT，然后（可选地）把若干个相邻 patch 的特征合并成一个语言模型输入 token。区别只在「切多大」和「合并多少」。

- **LLaVA-1.5**：图和 CLIP ViT-L/14 对齐到 336×336，patch=14，得到 24×24=576 个 patch，不合并，所以恒定 576 token。分辨率信息在 resize 那一步就丢了。
- **LLaVA-NeXT**：anyres，把图切成若干 336 的子图再加一张全局缩略图。默认 4 个子图 + 1 个全局，576×5=2880 token，恒定。
- **InternVL**：448 动态切块，patch=14 得 32×32=1024，再做 0.5 倍 pixel unshuffle，每块 256 token，块数随分辨率增长。
- **Qwen2.5-VL**：动态分辨率，patch=14、2×2 merge，等于每 28×28=784 像素换 1 个 token；有 `min_pixels` / `max_pixels` 上下限约束。

前两个是「常数模型」，后两个是「线性模型」。常数模型的好处是可预测，坏处是小图浪费（224 的图标也烧 576 token）、大图信息丢失（2480 宽的扫描件被压到 336，字全糊了）。线性模型反过来：小图极省，大图能把显存吃干。

实测一张表（脚本见下一节）：

| 图片 | 尺寸（宽×高） | Qwen2.5-VL | LLaVA-1.5 | LLaVA-NeXT | InternVL |
|---|---|---|---|---|---|
| 图标 | 224×224 | 64 | 576 | 2880 | 256 |
| 手机照片 | 1024×768 | 999 | 576 | 2880 | 1536 |
| 网页截图 | 1280×720 | 1196 | 576 | 2880 | 1536 |
| 4K 桌面截图 | 3840×2160 | 10549 | 576 | 2880 | 3072 |
| A4 扫描件 300dpi | 2480×3508 | 11125 | 576 | 2880 | 3072 |

注意 4K 那一列：10549 个 token 已经超过很多模型的默认 `max_model_len` 的一半，一个请求里放三张就直接顶到 32k 上下文。而 LLaVA-1.5 那一列全是 576——不是它更强，是它把 4K 图压成了 336 的缩略图，你看不清的字它也看不清。所以「换个模型 token 就下来了」这种优化，多数时候是拿信息量换的。

## 二、把它写成能跑的算术

下面这段是我用来出上面两张表的脚本核心，纯标准库，改参数就能复算自己的场景：

```python
import math

def qwen_vl_tokens(h, w, patch=14, merge=2,
                   min_pixels=4*28*28, max_pixels=12845056):
    """Qwen2/2.5-VL: 对齐到 patch*merge 的倍数，merge*merge 个 patch 合成 1 token。"""
    unit = patch * merge                       # 28 -> 每 token 784 px
    if h * w > max_pixels:                     # 等比缩小
        beta = math.sqrt(h * w / max_pixels)
        h, w = int(h / beta), int(w / beta)
    if h * w < min_pixels:                     # 等比放大
        beta = math.sqrt(min_pixels / (h * w))
        h, w = int(h * beta), int(w * beta)
    gh = max(unit, round(h / unit) * unit) // unit
    gw = max(unit, round(w / unit) * unit) // unit
    return gh * gw

def internvl_tokens(h, w, tile=448, patch=14, downsample=0.5, maxtiles=12):
    per_tile = int((tile // patch) ** 2 * downsample ** 2)   # 256
    n = min(maxtiles, max(1, math.ceil(h / tile) * math.ceil(w / tile)))
    return per_tile * n

def kv_bytes_per_token(layers, kv_heads, head_dim, elem_bytes=2):
    # K 和 V 各一份
    return 2 * layers * kv_heads * head_dim * elem_bytes

print(qwen_vl_tokens(2160, 3840))        # 10549
print(internvl_tokens(2160, 3840))       # 3072
print(kv_bytes_per_token(28, 4, 128))    # 57344  = 56 KiB
```

`kv_bytes_per_token` 是整篇文章最该记住的一行：KV 每 token 的字节数与序列长度无关，只跟层数、KV 头数和 head_dim 有关。GQA 把 KV 头从 32 砍到 8 或 4，省的就是这里的倍数。Llama-3.1-8B 是 128 KiB/token，Qwen2.5-7B（以及 Qwen2.5-VL-7B）是 56 KiB/token，Llama-3.1-70B 是 320 KiB/token。

## 三、把 token 乘成显存账单

单张图在 Qwen2.5-VL-7B 上的 KV 占用（fp16、只算图、不含文本和生成）：

| 图片 | 视觉 token | KV 占用 |
|---|---|---|
| 图标 224×224 | 64 | 3 MiB |
| 照片 1024×768 | 999 | 53 MiB |
| 网页截图 1280×720 | 1196 | 64 MiB |
| 4K 截图 | 10549 | 563 MiB |
| A4 扫描件 | 11125 | 594 MiB |

单张看不出问题，乘上并发就露出来了。假设一个「表格问答」产品，32 路并发，每路会话带 3 张 4K 截图：每会话 31647 个视觉 token，KV 1.69 GiB，32 路合计 **54 GiB**——这还只是 KV，不算权重（7B fp16 约 15 GiB）和激活。一张 80G 卡直接爆，`max_model_len` 那条线会先拦住你，但拦住的方式是把请求变慢（排队、prefill 分块）而不是报错。

`max_pixels` 是这里唯一的一阶旋钮。同一张 4K 截图扫一遍：

| max_pixels | 实际 resize | 视觉 token | KV |
|---|---|---|---|
| 12845056（默认） | 3836×2156 | 10549 | 576.9 MiB |
| 4194304 | 2744×1540 | 5390 | 294.8 MiB |
| 1048576 | 1372×756 | 1323 | 72.4 MiB |
| 262144 | 672×392 | 336 | 18.4 MiB |

把上限压到 1MP，同一批 32 路并发的 KV 从 54 GiB 掉到 **6.78 GiB**，多出 8 倍容量。代价是 token 数掉到八分之一，密集表格和 UI 上的小字开始认不出来。预填时间同理：10549 个 token 在 2000 tok/s 的 prefill 吞吐下要 5.27 秒，5000 tok/s 要 2.11 秒，12000 tok/s 要 0.88 秒——注意这是**只有图**的那部分，用户问题、系统提示、历史消息都还没算，而 TTFT 里最贵的就是这一段不可省略的 prefill。

## 四、准入控制应该放在网关，不是引擎

引擎发现超长是请求触到上限之后的事，那时你已经付了 queue 时间和 tokenize 成本，而且用户拿到的是一句 400。正确的位置是在请求进门时、用图片 header 里的宽高算出 token 估算值、按租户配额决定「原图跑 / 降分辨率跑 / 走 OCR 分支 / 拒绝」。

关键是**不要为了量尺寸而解码整张图**。`PIL.Image.open()` 是惰性的，只读头部拿 `size`，几毫秒：

```python
from PIL import Image
import io

def image_dims(raw: bytes):
    """只读 header 不解码像素。注意不要顺手调 .load() 或 .verify() 之后再用同一对象。"""
    with Image.open(io.BytesIO(raw)) as im:
        return im.size          # (w, h)

def admission(raw: bytes, tenant_quota_tokens=16000):
    w, h = image_dims(raw)
    est = qwen_vl_tokens(h, w)                     # 复用上面的公式
    if est <= tenant_quota_tokens // 2:
        return {"max_pixels": None, "est_tokens": est}      # 原图
    for cap in (4194304, 1048576, 262144):                   # 降级阶梯
        e = qwen_vl_tokens(h, w, max_pixels=cap)
        if e <= tenant_quota_tokens // 2:
            return {"max_pixels": cap, "est_tokens": e}
    return {"route": "ocr", "est_tokens": None}              # 兜底转文本管线
```

几个实操细节：

- `image_dims` 拿到的是**原始**宽高，Qwen 的 resize 会再等比缩到 `max_pixels` 以下，所以估算必须复用同一套公式，不能只按原始 `h*w/784` 硬除。
- 估算只需要「够用」，不需要「精确」。差几个百分点对准入判断无影响（下面会讲为什么它不能拿去计费）。
- 别在网关里做 `verify()`：它会解析整张图一次，且把对象标记为不可复用，后面传字节流给引擎还要重新 open。

## 五、多模态前缀缓存为什么总是打不穿

纯文本服务的 prefix cache 命中率能到 60% 以上，多模态往往只有个位数。原因基本是两个，都是「key 设计」问题。

**坑 1：key 用了 URL、文件名或 mtime。** 同一个用户反复上传同一张图，很多 SDK 会带上签名 URL（每次都变）、临时文件名（变）、上传时间戳前缀（变）。以这些做 key，等于给每张图分配一个全新 ID，缓存永远不会命中。而同一张图在像素层面完全一致，KV 完全可以复用。

**坑 2：重新编码让字节变了。** 客户端把 PNG 转成 JPEG（质量 85）、加一层时间戳水印、或者用不同的 libjpeg 重新压一遍——像素几乎一样，但在 **decoded bytes** 层面全变了。如果你的 key 是「解码后 RGB 缓冲的 sha256」，这两张图会被判成不同；如果你把 key 放宽到「感知哈希」，又有碰撞风险（16 位 aHash 在百万级图库里碰撞是必然的）。

工程上可行的折中是两级 key——先用廉价指纹做入口，命中后再用高置信哈希确认:

```python
import hashlib
from PIL import Image
import io

def cache_key_strong(raw: bytes, processor_params: dict):
    """高置信 key：解码后的 RGB 像素 + 会改变 token 布局的 processor 参数。"""
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    h = hashlib.sha256()
    h.update(b"vlm-prefix-v1")
    h.update(str((im.width, im.height)).encode())
    h.update(im.tobytes())                       # 像素级，抗重新编码
    for k in ("patch_size", "merge_size", "max_pixels", "min_pixels"):
        h.update(f"{k}={processor_params.get(k)}".encode())
    return h.hexdigest()

def cache_key_cheap(raw: bytes):
    """入口指纹：8x8 灰度均值，几十微秒，只用来索引候选，不单独做命中判断。"""
    im = Image.open(io.BytesIO(raw)).convert("L").resize((8, 8))
    px = list(im.getdata())
    avg = sum(px) / 64
    bits = 0
    for i, v in enumerate(px):
        if v > avg:
            bits |= 1 << i
    return bits
```

`processor_params` 必须进 key，这是很多人漏掉的一颗雷：`max_pixels` 从 12.8MP 调到 1MP，token 数从 10549 变 1323，视觉 token 的 KV 长度完全不同——两个不同配置下算出来的 KV 不可能共用一个槽位。上线时改了这个参数忘了清缓存，症状是「同一张图第一次回答对、第二次回答对半条」，因为命中了旧配置的 KV。

**还有一条顺序陷阱**：前缀缓存只能复用「从头开始连续相同」的那一段。如果你的 prompt 拼法是 `system + 用户问题 + 图片`，那么图片之后的每一个 token 都是不稳定的，图片那段 KV 只有第一次请求能命中——因为每个请求的图都排在问题后面，前面已经分叉了。正确拼法是 `system + 图片（静态资产） + 每轮变化的问题`，让图片落在最长的公共前缀里。这条在「一次会话反复追问同一张截图」的场景下能把命中率从零直接拉到七成以上，改的是 prompt 布局，不是引擎。

顺带一个容易忽略的浪费：同一张图在同一个请求里被引用两次（比如两个不同的问题都指向它），多数 HF processor 是逐 image 处理、不去重，token 直接翻倍。在 prompt 组装层按 `cache_key_strong` 去重，只把它当一次输入，靠占位符在文本里引用。

## 六、估算不能拿来计费

最后说一个必须分的口径：上面所有公式都是**近似**。真正的 token 数以 processor 返回的 `image_grid_thw` 为准，它给出的 (T, H, W) 三元组里，`H*W/(merge**2)` 才是这一张图实际进入语言模型的 token 数。差别来自 `smart_resize` 的取整细节——Python 的 `round()` 是银行家舍入（`round(1.5)` 得 2，`round(2.5)` 得 2），而 HF 实现里用的是 `floor` 到 factor 倍数再夹到上下界，两边在边界分辨率上会差几个 grid 单位，一张 4K 图差几十到上百个 token。

所以两条纪律：

1. **准入用估算**（要快，误差可接受）。
2. **计费用 `image_grid_thw`**（要准，同一个请求重算两次必须一致），并且把它落到日志里——这是你事后解释「为什么这个用户的月度 token 账单是别人的三倍」的唯一证据。没有这个字段，你只能看到「他传了很多图」，看不到「他传了 47 张 4K 截图」。

## 七、清单

- 视觉 token = f(分辨率, patch, merge, resize 上限)，先算，再谈优化。
- KV/token 是常数，只跟层数、KV 头数、head_dim 有关；把它乘进并发，才是真正的容量数字。
- `max_pixels` 是唯一的一阶旋钮，1MP 能让 4K 截图的显存掉 8 倍；降级阶梯（原图 → 4MP → 1MP → 256K → OCR）比单一阈值稳。
- 准入用 header 里的宽高算，别解码整图；别在网关 `verify()`。
- 缓存 key 必须内容寻址（像素级哈希 + processor 参数），并接受「感知指纹做索引、强哈希做确认」的两级结构。
- prompt 布局把图片放前面，否则前缀缓存永远命不中。
- 计费以 `image_grid_thw` 为准，估算只用于准入。

这七条里没有一条是模型层面的技巧，全是算术和 key 设计。多模态的成本问题，八成不在模型能力上——在于没人算过那张图到底值多少 token。
