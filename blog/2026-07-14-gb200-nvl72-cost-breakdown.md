---
title: "HyperFrames 视频脚本：GB200 NVL72 — 一台 300 万美元的 AI 机柜，钱到底花在哪？"
date: 2026-07-14T23:00:00+08:00
draft: false
tags: ["ai", "nvidia", "gb200", "hardware", "gpu", "infrastructure", "video-script"]
categories: ["Tech"]
description: "逐层拆解 NVIDIA GB200 NVL72 的 300 万美元成本构成，附 TTS 旁白、图片提示词、关键来源"
---

> 本文是一份完整的 **HyperFrames 时间线视频制作脚本 + 实际生成记录**。前半部分为逐帧镜头设计和生图 Prompt，后半部分记录了用 `edge-tts` + `Pillow` + `ffmpeg` 纯代码生成视频的全过程（含踩坑）。成品 1080p / 3m51s / 7.5MB，带 TTS 配音和硬字幕。

---

## 视频总览

- **时长**：实际 231 秒 / 3 分 51 秒（28 个镜头，TTS 中速朗读）, 理想压缩后可到 2 分钟
- **风格**：HyperFrames 快节奏数据可视化 + 产品特写 + 动态图表
- **配音**：edge-tts `zh-CN-YunxiNeural` 男声，rate +10%
- **字幕**：底部中文字幕，SRT 硬字幕（微软雅黑）
- **画面**：Pillow 代码信息图（可替换为 GPT Image 2 / Midjourney 出图升级）
- **BGM**：暂无（可后期加入科技感电子乐垫底）

---

## 成本分解总表（核心数据）

| 组件 | 数量 | 单价（估算） | 小计 | 占比 |
|------|------|-------------|------|------|
| GB200 Superchip (1 Grace + 2 B200) | 36 | $60K-$70K | $2.16M-$2.52M | ~72-78% |
| NVLink 5 Switch 交换盘 | 18 | $12K-$15K | $216K-$270K | ~7-9% |
| 液冷散热系统 (DLC/CDU) | 1 套 | $80K-$120K | $80K-$120K | ~3-4% |
| ConnectX-8/7 网卡 + Spectrum-X 交换机 | 36 NIC + 交换机 | 整套 ~$120K-$180K | $120K-$180K | ~4-6% |
| 定制机柜 + 电源分配 (PDU) | 1 套 | $40K-$70K | $40K-$70K | ~1.5-2.5% |
| BlueField-3 DPU | 2-4 | $3K-$5K | $12K-$20K | ~0.5% |
| 组装/集成/测试 + 原厂 margin | — | — | ~$100K-$150K | ~3-5% |
| **合计** | — | — | **~$2.7M-$3.3M** | **100%** |

> **来源说明**：NVIDIA 不公开组件级定价。以上数据综合自 **SemiAnalysis** 深度分析（2024.03）、**Morgan Stanley** 研报（2024.03）、**Dell/Supermicro OEM** 报价泄露、**ServeTheHome** 和 **Tom's Hardware** 报道。实际价格因 OEM 厂商、采购规模、配置差异浮动 ±15%。

{/* truncate */}

---

## 完整镜头脚本（35 镜）

---

### 📍 第 1 幕：开场钩子（0-10s）

#### 镜 1 · 暗场数字浮现
- **时长**：3s
- **画面描述**：纯黑背景，金色粒子聚合成 "$3,000,000"，然后缓慢旋转
- **字幕**：一台 AI 服务器机柜，300 万美元
- **旁白**：一台 AI 服务器机柜，三百万美元。
- **图片 Prompt**：
> A cinematic dark scene with a floating golden number "$3,000,000" made of glowing particles against a pure black background, volumetric lighting, 8K photorealistic, dramatic atmosphere —ar 16:9

#### 镜 2 · 数据中心走廊
- **时长**：4s
- **画面描述**：一条未来感数据中心走廊，两侧排列着一模一样的黑色机柜，蓝色 LED 灯带，镜头缓缓推近其中一台
- **字幕**：它叫 GB200 NVL72。72 颗 Blackwell GPU 塞进一个机柜
- **旁白**：它叫 GB200 NVL72，NVIDIA 在 2024 年 GTC 大会上甩出的王炸。72 颗 Blackwell GPU，塞进一个机柜。
- **图片 Prompt**：
> A futuristic data center corridor lined with identical black server racks glowing with blue LED strips, the camera slowly pushing toward one specific rack in the center, cyberpunk aesthetic, clean lighting, photorealistic 8K —ar 16:9

#### 镜 3 · 黄仁勋 GTC
- **时长**：3s
- **画面描述**：分屏构图——左侧 Jensen Huang 在 GTC 舞台手举 GB200 主板，右侧快速闪过 $2-3M 价格标签
- **字幕**：相当于 3 台法拉利 488，或者北京五环一套房
- **旁白**：三百万美元——相当于三台法拉利 488，北京五环一套房。
- **图片 Prompt**：
> Split screen: left side shows Jensen Huang on GTC stage holding a GPU board under dramatic stage lighting; right side shows a Ferrari 488 and a luxury apartment with "$3M" price tag overlay, tech magazine editorial style, 8K —ar 16:9

---

### 📍 第 2 幕：逐层拆解钱花在哪（10-90s）

#### 镜 4 · 章节标题
- **时长**：2s
- **画面描述**：全屏大字 "💰 钱花在哪？"，逐行出现，金属质感
- **字幕**：（无）
- **旁白**：现在，我们来把它拆开。
- **图片 Prompt**：
> A bold typographic design with metallic gold text "WHERE DOES THE MONEY GO?" in Chinese on a dark gradient background, luxury branding style, minimalist, 8K —ar 16:9

---

### 🔴 第一层：GPU 与 HBM 显存 — $2.2M-$2.5M（~75%）

#### 镜 5 · GB200 Superchip 特写
- **时长**：4s
- **画面描述**：一颗 GB200 Superchip 在黑色托盘上 45 度旋转，流光扫过表面。B200 GPU die 和 HBM3e 堆栈用不同颜色高亮标注
- **字幕**：GB200 Superchip = 1 颗 Grace CPU + 2 颗 B200 GPU。单颗售价 $60,000-$70,000
- **旁白**：最大的一笔钱，当然在 GPU 上。这台机柜里有 36 颗 GB200 Superchip，每一颗里面封装着两颗 Blackwell B200 GPU 和一颗 Grace CPU。单颗价格六万到七万美元。三十六颗，两百万就出去了。
- **图片 Prompt**：
> A single NVIDIA GB200 Superchip floating on a matte black pedestal, rotating 45 degrees, laser scanning across its surface with different colored highlights showing B200 GPU die in blue and HBM3e stacks in gold, product shot style, extreme detail, 8K —ar 16:9

#### 镜 6 · GPU 裸片结构图
- **时长**：3s
- **画面描述**：X 光透视风格剖面图，B200 GPU 内部——2080 亿个晶体管，两个计算 die 通过 10TB/s NV-HBI 桥接
- **字幕**：单颗 B200：2080 亿晶体管，台积电 4NP 工艺
- **旁白**：一颗 B200 上有两千零八十亿个晶体管，台积电四纳米定制工艺。这个量级的芯片，光流片费用就要上亿美元。
- **图片 Prompt**：
> An X-ray style cutaway diagram of a B200 GPU die showing 208 billion transistors as a dense glowing circuit city, two compute dies connected by a bright NV-HBI bridge labeled "10TB/s", technical illustration, dark theme with neon accents, 8K —ar 16:9

#### 镜 7 · HBM3e 显存堆叠
- **时长**：3s
- **画面描述**：8 颗 HBM3e 堆栈像摩天大楼一样围绕在 GPU die 周围，数据如瀑布般从 HBM 流入 GPU。每颗 B200 搭载 192GB HBM3e
- **字幕**：每颗 B200 搭载 192GB HBM3e。全机柜共计 13.5TB 高速显存
- **旁白**：比 GPU Die 更贵的，是它身边的 HBM3e 高带宽显存。每颗 B200 搭载一百九十二 GB，整个机柜堆了十三点五 TB。按市场价算，这些显存光物料成本就接近二十万美元。
- **图片 Prompt**：
> Eight HBM3e memory stacks towering like skyscrapers around a central B200 GPU die, data cascading as bright waterfalls from HBM into GPU, cross-section view, labeled "192GB HBM3e" and "8TB/s bandwidth", technical illustration, 8K —ar 16:9

#### 镜 8 · 关键数字放大
- **时长**：2s
- **画面描述**：全屏数字 "$2,200,000 GPU 与显存"，金色粗体，下方小字 "占总成本 ~75%"
- **字幕**：GPU 与显存：约 220 万美元，占总成本 75%
- **旁白**：仅 GPU 和显存，就花掉两百二十万美元，占总成本的四分之三。
- **图片 Prompt**：
> A bold financial infographic with a massive golden number "$2,200,000" filling the frame, subtitle "75% of total cost" below, dark background with subtle data visualization elements, clean typography, 8K —ar 16:9

---

### 🟠 第二层：NVLink 5 交换网络 — $220K-$270K（~8%）

#### 镜 9 · NVSwitch 机箱
- **时长**：3s
- **画面描述**：机柜内部，目光穿过 GPU compute tray，看到上方排列整齐的 NVSwitch 交换盘——共 18 个，银灰色金属外壳、密集接口
- **字幕**：18 个 NVSwitch 交换盘，把 72 颗 GPU 连成一台"巨型 GPU"
- **旁白**：第二笔大开销：NVLink 交换网络。十八个 NVSwitch 交换盘，用九千个铜缆连接器把七十二颗 GPU 焊成一个整体。
- **图片 Prompt**：
> Inside view of a GB200 NVL72 rack showing 18 NVSwitch trays arranged in neat rows above compute trays, silver metallic enclosures with dense copper connectors visible, server hardware photography, clean lighting, 8K —ar 16:9

#### 镜 10 · 铜背板互联
- **时长**：3s
- **画面描述**：简化的机柜背面线框透视图——9,000+ 根铜缆像神经网络一样交织，每条线代表 1.8TB/s 双向带宽。数据包以光点形式在线上飞速穿梭
- **字幕**：NVLink 5 铜背板：5000 根线缆，总带宽 130TB/s，铜缆成本比光纤低 6 倍
- **旁白**：这套铜背板互联方案是 NVIDIA 的秘密武器。五千多根线缆提供每秒一百三十 TB 的总带宽，而且比用光纤方案便宜六倍。
- **图片 Prompt**：
> A wireframe cutaway diagram showing the backplane of a GB200 NVL72 rack with 9,000+ copper cables intertwining like a neural network, labeled "NVLink 5 Backplane" and "130TB/s total bandwidth", glowing data packets traveling along cables, technical illustration, dark theme, 8K —ar 16:9

#### 镜 11 · 交换成本数字
- **时长**：2s
- **画面描述**：图表——横轴组件列表，纵轴成本，NVSwitch 柱状图 $250K 突出显示，旁边标注 "每 Tray ~$14K × 18"
- **字幕**：NVLink 交换网络：约 25 万美元
- **旁白**：仅交换网络部分，又是二十五万美元。
- **图片 Prompt**：
> A sleek bar chart infographic showing cost breakdown with NVSwitch highlighted at $250K, labeled "~$14K per tray × 18 trays", clean data visualization style, dark theme with gold accents, 8K —ar 16:9

---

### 🟡 第三层：液冷散热 — $80K-$120K（~3-4%）

#### 镜 12 · 液冷管道特写
- **时长**：3s
- **画面描述**：镜头从机柜后方的冷却液分配单元开始，跟随半透明管道（能看到蓝色冷却液流动），一路走到每个 GPU cold plate
- **字幕**：每个机柜功耗 120kW。必须上液冷，风冷根本压不住
- **旁白**：别忘了，这个机柜跑起来要吃掉一百二十千瓦的电。什么概念？一栋三十户的居民楼，夏天开满空调也就这个功率。风冷根本顶不住，必须上液冷。
- **图片 Prompt**：
> A macro shot following translucent blue coolant flowing through liquid cooling pipes from a CDU toward GPU cold plates in a server rack, industrial technical photography, dramatic lighting, showing the complexity of the plumbing, 8K —ar 16:9

#### 镜 13 · 功耗对比
- **时长**：3s
- **画面描述**：左右对比——左侧一个标准 42U 风冷机柜（标注 "Max 20-30kW"），右侧 GB200 NVL72（标注 "120kW"），右侧高出近 5 倍。右侧机柜顶部有大量管道
- **字幕**：传统风冷单柜极限 30kW。GB200 NVL72：120kW
- **旁白**：传统数据中心单柜功耗撑死三十千瓦，GB200 直接冲到一百二。液冷散热系统的整套方案——CDU、冷板、管路——加起来又要八到十二万美元。
- **图片 Prompt**：
> Side by side comparison: left a standard 42U air-cooled rack labeled "Max 30kW", right a GB200 NVL72 rack labeled "120kW" with complex liquid cooling pipes on top, dramatic contrast, infographic style, 8K —ar 16:9

#### 镜 14 · CDU 设备特写
- **时长**：2s
- **画面描述**：一台独立的 Coolant Distribution Unit，不锈钢外观，多个水泵和热交换器，科技感工业产品摄影
- **字幕**：CDU 冷却液分配单元：$40K-$60K
- **旁白**：光这台冷却液分配单元，就要四到六万美元。
- **图片 Prompt**：
> A standalone Coolant Distribution Unit in stainless steel finish with multiple pumps and heat exchangers visible, industrial product photography, clean studio lighting, technology aesthetic, 8K —ar 16:9

---

### 🟢 第四层：网络 — $120K-$180K（~4-6%）

#### 镜 15 · 网卡阵列
- **时长**：3s
- **画面描述**：36 块 ConnectX-8 网卡排成阵列，每块卡标注 "800Gb/s"。网卡像多米诺骨牌依次亮起
- **字幕**：36 块 ConnectX-8 网卡，每块 800Gb/s。加上 Spectrum-X 交换机
- **旁白**：GPU 算得再快，数据进不来也白搭。每颗 Superchip 配一块八百 G 的 ConnectX-8 网卡，加上顶层的 Spectrum-X 交换机，整套网络方案十二到十八万美元。
- **图片 Prompt**：
> An array of 36 ConnectX-8 NICs arranged in a grid pattern, each labeled "800Gb/s", lighting up sequentially like dominoes, product photography, dark background, dramatic lighting, 8K —ar 16:9

#### 镜 16 · 网络拓扑图
- **时长**：2s
- **画面描述**：简化的网络拓扑——底部 36 个 GB200 node 通过 ConnectX-8 连接到上层 Spectrum-X 交换机，标注 "Rail-optimized / Adaptive Routing / 低延迟"
- **字幕**：Spectrum-X 以太网：专为 AI 流量优化
- **旁白**：Spectrum-X 是 NVIDIA 专门为 AI 训练流量优化的以太网方案，能做到 InfiniBand 级别的性能。
- **图片 Prompt**：
> A simplified network topology diagram: 36 GB200 nodes at bottom connected via ConnectX-8 NICs to Spectrum-X switches at top, labeled "Rail-optimized" and "Adaptive Routing", clean technical diagram, dark theme, 8K —ar 16:9

---

### 🔵 第五层：机柜基础设施 — $40K-$70K（~2%）

#### 镜 17 · 定制机柜
- **时长**：3s
- **画面描述**：GB200 NVL72 机柜的骨架结构——不是标准 19 英寸机柜，而是 NVIDIA 定制设计的宽体机箱，电源母排像脊柱一样贯穿
- **字幕**：NVIDIA 定制机柜，非标准宽体设计。功率密度是传统机柜 5 倍以上
- **旁白**：这个机柜不是标准件——它比普通机柜宽得多，NVIDIA 重新设计了整个结构来容纳 72 颗 GPU 和 120 千瓦的供电。定制机柜、电源分配、组装测试，四到七万美元。
- **图片 Prompt**：
> The bare skeleton structure of a GB200 NVL72 custom rack showing its wider-than-standard design, copper power busbars running like a spine through the center, industrial design photography, factory setting, 8K —ar 16:9

#### 镜 18 · PDU 供电母排
- **时长**：2s
- **画面描述**：密集的铜质电源母排特写，标注 "415V 三相供电 / 120kW"，安全警示标识
- **字幕**：415V 三相供电，120kW 总功率
- **旁白**：供电是 415 伏三相直入，跳过传统 UPS 直接上电，就是为了省转换损耗。
- **图片 Prompt**：
> A close-up of dense copper power busbars labeled "415V 3-Phase 120kW" with safety warning labels, industrial electrical photography, moody lighting, 8K —ar 16:9

---

### 🟣 第六层：组装 & 原厂利润 — ~$100K-$150K（~4%）

#### 镜 19 · 工厂组装线
- **时长**：3s
- **画面描述**：整洁的服务器组装车间，工人（或机械臂）正在将 GB200 Superchip 插入机柜。防静电服、洁净室环境
- **字幕**：每一台 NVL72 在出厂前需要数周的组装、布线、测试、烧机
- **旁白**：把这些东西装到一起也不是免费的。每台 NVL72 在出厂前需要数周组装和烧机测试。NVIDIA 不收组装费，但整机打包卖，利润自然加在里面。
- **图片 Prompt**：
> A clean server assembly workshop with workers in anti-static suits inserting GB200 Superchips into a rack, robotic arms in background, clean room environment, industrial documentary photography style, 8K —ar 16:9

#### 镜 20 · 测试屏幕
- **时长**：2s
- **画面描述**：多块监控屏幕排成一面墙，显示各种温度曲线、功耗曲线、网络吞吐、GPU 利用率，绿色通过标志
- **字幕**：出厂前 72 小时满负荷烧机测试
- **旁白**：七千两百小时满负荷烧机测试——任何一个节点出问题，整柜都得返工。
- **图片 Prompt**：
> A wall of monitoring screens showing temperature curves, power draw graphs, network throughput, and GPU utilization, all with green "PASS" indicators, command center aesthetic, dark room, 8K —ar 16:9

---

### 📍 第 3 幕：为什么会有人买？（90-105s）

#### 镜 21 · 训练时间对比
- **时长**：3s
- **画面描述**：对比图表——训练 GPT-4 级别模型：H100 集群需要 [X] 天 / GB200 NVL72 集群需要 [Y] 天（时间少 4 倍）。绿色下箭头
- **字幕**：训练一个万亿参数模型。H100：90-100 天。GB200：25-30 天
- **旁白**：三百万值不值？看你怎么算。训练一个万亿参数的大模型，用上一代 H100 集群要跑三到四个月。上了 GB200 NVL72，一个月以内搞定。
- **图片 Prompt**：
> A comparison bar chart: left bar "H100 Cluster: 90-100 days" in red, right bar "GB200 NVL72: 25-30 days" in green with a bold down arrow, clean infographic style, dark theme, 8K —ar 16:9

#### 镜 22 · 推理吞吐对比
- **时长**：3s
- **画面描述**：动态图表——同一个 LLM 推理请求，H100 每秒生成 20 tokens，GB200 NVL72 每秒生成 100+ tokens（5 倍吞吐）。气泡上升动画
- **字幕**：推理吞吐提升 5 倍以上。同样 300 万，比多买 5 台 H100 还划算
- **旁白**：推理性能更是四到五倍的提升。而且因为 72 颗 GPU 共享 13.5TB 统一显存，不用切模型，一整个万亿参数模型直接塞进一个机柜跑。
- **图片 Prompt**：
> An animated chart showing tokens-per-second throughput: H100 at 20 tokens/s vs GB200 NVL72 at 100+ tokens/s, with rising bubble animation, labeled "5x inference throughput", data visualization style, 8K —ar 16:9

#### 镜 23 · 统一显存
- **时长**：3s
- **画面描述**：72 颗 B200 以 NVLink 连接成一个巨大的单一逻辑 GPU，上方悬浮 "13.5TB 统一显存"。一个巨大的模型图标被整个装进这个大 GPU 里
- **字幕**：72 颗 GPU 在 NVLink 下变成一台"超级 GPU"，不需要模型切分
- **旁白**：这是 NVL72 最核心的卖点——七十二颗 GPU 在 NVLink 下变成一台拥有 13.5TB 显存的超级 GPU。大模型不用切，直接跑。省掉了分布式训练的通信开销，这是质的区别。
- **图片 Prompt**：
> A visual metaphor: 72 B200 GPUs connected by glowing NVLink bridges merging into one giant logical GPU, with a massive AI model fitting entirely inside it, labeled "13.5TB Unified Memory", futuristic tech illustration, 8K —ar 16:9

#### 镜 24 · 大客户俱乐部
- **时长**：3s
- **画面描述**：一排知名公司 logo——Microsoft、Meta、Oracle、Tesla（xAI）、Google、Amazon，金光流转
- **字幕**：首批客户：Microsoft、Meta、Oracle、xAI、CoreWeave、Lambda Labs
- **旁白**：这也是为什么 OpenAI 的对手、Meta、微软、Oracle 这些公司已经在排队下单。因为在这个级别的竞赛里，时间就是护城河。
- **图片 Prompt**：
> A prestigious lineup of tech company logos — Microsoft, Meta, Oracle, xAI, Google, Amazon — arranged in a row with golden light sweeping across them, premium brand style, dark background, 8K —ar 16:9

---

### 📍 第 4 幕：结尾总结（105-120s）

#### 镜 25 · 完整饼图
- **时长**：3s
- **画面描述**：一张精美的环形饼图，显示全部 6 层成本占比。每层用不同颜色，旁边标注金额和百分比。中心是 GB200 NVL72 的正视图
- **字幕**：GPU 与显存 75% · NVLink 交换 8% · 液冷 4% · 网络 5% · 机柜 2% · 组装&利润 6%
- **旁白**：拆完你会发现——三百万里，两百二十万花在 GPU 和显存上。剩下的八十万，是让这七十二颗 GPU 真正能一起工作的代价。
- **图片 Prompt**：
> A beautiful donut chart showing 6-layer cost breakdown with GB200 NVL72 image at center, each segment colored differently with amount labels, professional financial infographic design, dark theme, 8K —ar 16:9

#### 镜 26 · 摩尔定律对比
- **时长**：3s
- **画面描述**：一条向上飙升的成本曲线。2016 年 DGX-1 $129K → 2022 年 H100 HGX $300K → 2024 年 GB200 NVL72 $3M。曲线末端陡然变陡
- **字幕**：AI 训练成本的超级摩尔定律：每 2 年 10 倍增长
- **旁白**：从 2016 年的 DGX-1 十二万九，到今天的 GB200 NVL72 三百万——AI 硬件的价格曲线，比摩尔定律陡十倍。这就是算力军备竞赛的真相。
- **图片 Prompt**：
> A dramatic upward cost curve chart: DGX-1 (2016) $129K → H100 HGX (2022) $300K → GB200 NVL72 (2024) $3M, the curve steepening sharply at the end, labeled "Super Moore's Law: 10x every 2 years", data visualization, 8K —ar 16:9

#### 镜 27 · 结尾画面
- **时长**：4s
- **画面描述**：回到开场数据中心走廊视角，镜头缓缓拉远，一台 NVL72 机柜的蓝色 LED 在画面中渐小，然后叠上 "算力无价，但硬件有价" 字样，fade out
- **字幕**：算力无价。但硬件，真的有价。
- **旁白**：算力无价。但硬件，真的有价。
- **图片 Prompt**：
> The futuristic data center corridor from shot 2, camera slowly pulling back as the GB200 NVL72 rack's blue LEDs become smaller, text "COMPUTE IS PRICELESS. HARDWARE IS NOT." fading in, cinematic, emotional, 8K —ar 16:9

---

## TTS 完整旁白文本（字幕轨）

以下是连续朗读文本，供 TTS 引擎使用，按正常语速约 120 秒：

```
一台 AI 服务器机柜，三百万美元。

它叫 GB200 NVL72，NVIDIA 在 2024 年 GTC 大会上甩出的王炸。72 颗 Blackwell GPU，塞进一个机柜。

三百万美元——相当于三台法拉利 488，北京五环一套房。

现在，我们来把它拆开。

最大的一笔钱，当然在 GPU 上。这台机柜里有 36 颗 GB200 Superchip，每一颗里面封装着两颗 Blackwell B200 GPU 和一颗 Grace CPU。单颗价格六万到七万美元。三十六颗，两百万就出去了。

一颗 B200 上有两千零八十亿个晶体管，台积电四纳米定制工艺。这个量级的芯片，光流片费用就要上亿美元。

比 GPU Die 更贵的，是它身边的 HBM3e 高带宽显存。每颗 B200 搭载一百九十二 GB，整个机柜堆了十三点五 TB。按市场价算，这些显存光物料成本就接近二十万美元。

仅 GPU 和显存，就花掉两百二十万美元，占总成本的四分之三。

第二笔大开销：NVLink 交换网络。十八个 NVSwitch 交换盘，用九千个铜缆连接器把七十二颗 GPU 焊成一个整体。

这套铜背板互联方案是 NVIDIA 的秘密武器。五千多根线缆提供每秒一百三十 TB 的总带宽，而且比用光纤方案便宜六倍。

仅交换网络部分，又是二十五万美元。

别忘了，这个机柜跑起来要吃掉一百二十千瓦的电。什么概念？一栋三十户的居民楼，夏天开满空调也就这个功率。风冷根本顶不住，必须上液冷。

传统数据中心单柜功耗撑死三十千瓦，GB200 直接冲到一百二。液冷散热系统的整套方案——CDU、冷板、管路——加起来又要八到十二万美元。

光这台冷却液分配单元，就要四到六万美元。

GPU 算得再快，数据进不来也白搭。每颗 Superchip 配一块八百 G 的 ConnectX-8 网卡，加上顶层的 Spectrum-X 交换机，整套网络方案十二到十八万美元。

Spectrum-X 是 NVIDIA 专门为 AI 训练流量优化的以太网方案，能做到 InfiniBand 级别的性能。

这个机柜不是标准件——它比普通机柜宽得多，NVIDIA 重新设计了整个结构来容纳 72 颗 GPU 和 120 千瓦的供电。定制机柜、电源分配、组装测试，四到七万美元。

供电是 415 伏三相直入，跳过传统 UPS 直接上电，就是为了省转换损耗。

把这些东西装到一起也不是免费的。每台 NVL72 在出厂前需要数周组装和烧机测试。NVIDIA 不收组装费，但整机打包卖，利润自然加在里面。

七十二小时满负荷烧机测试——任何一个节点出问题，整柜都得返工。

三百万值不值？看你怎么算。训练一个万亿参数的大模型，用上一代 H100 集群要跑三到四个月。上了 GB200 NVL72，一个月以内搞定。

推理性能更是四到五倍的提升。而且因为 72 颗 GPU 共享 13.5TB 统一显存，不用切模型，一整个万亿参数模型直接塞进一个机柜跑。

这是 NVL72 最核心的卖点——七十二颗 GPU 在 NVLink 下变成一台拥有 13.5TB 显存的超级 GPU。大模型不用切，直接跑。省掉了分布式训练的通信开销，这是质的区别。

这也是为什么 OpenAI 的对手、Meta、微软、Oracle 这些公司已经在排队下单。因为在这个级别的竞赛里，时间就是护城河。

拆完你会发现——三百万里，两百二十万花在 GPU 和显存上。剩下的八十万，是让这七十二颗 GPU 真正能一起工作的代价。

从 2016 年的 DGX-1 十二万九，到今天的 GB200 NVL72 三百万——AI 硬件的价格曲线，比摩尔定律陡十倍。这就是算力军备竞赛的真相。

算力无价。但硬件，真的有价。
```

---

## 关键数字来源索引

| 数字 | 来源 |
|------|------|
| NVL72 整柜 72 B200 GPU | [NVIDIA GTC 2024 Keynote](https://www.nvidia.com/gtc/) (Jensen Huang, 2024.03.18) |
| GB200 Superchip 2×B200 + 1×Grace | [NVIDIA GB200 Datasheet](https://www.nvidia.com/en-us/data-center/gb200-nvl72/) |
| $3M 整柜价格区间 | SemiAnalysis "GB200 NVL72 Deep Dive" (2024.03); Morgan Stanley Research (2024.03); Dell/超聚变 OEM 报价 |
| B200 2080 亿晶体管 | [NVIDIA Blackwell Architecture Whitepaper](https://resources.nvidia.com/en-us-blackwell-architecture) |
| 192GB HBM3e / B200 | NVIDIA Blackwell 官方规格 |
| 8TB/s HBM3e 带宽 / B200 | NVIDIA Blackwell 官方规格 |
| NVLink 5 1.8TB/s 双向 | NVIDIA Blackwell 官方规格 |
| 130TB/s 全柜总带宽 | NVIDIA GTC 2024 Keynote |
| 120kW 整柜功耗 | NVIDIA GTC 2024 / ServeTheHome NVL72 实机分析 |
| 铜背板比光互联便宜 6× | NVIDIA GTC 2024 (Jensen Huang 原话) |
| DGX-1 $129K (2016) | NVIDIA DGX-1 历史定价 |
| 训练时间对比 (4× 加速) | NVIDIA 官方性能声明 |

> **注意**：组件级价格（GPU die / HBM / NVSwitch / 网卡）为行业分析师根据已知物料成本和供应商报价推估，实际价格可能因批量折扣和 OEM 协议差异浮动 ±15%。建议在视频中以 "约" / "区间" 表述，并在画面角落标注 "基于分析师估算" 字样。

---

## 实际生成：从脚本到视频的全流程

上面是"理想方案"（GPT Image 2 生图 + 专业剪辑），下面是**真的跑出来的方案**——纯代码，无需任何付费 API，一行命令出片。

### 工具链

| 环节 | 工具 | 说明 |
|------|------|------|
| TTS 配音 | `edge-tts` (Python) | Microsoft 免费 TTS，`zh-CN-YunxiNeural` 男声 |
| 画面生成 | `Pillow` (Python) | 代码绘制 28 张信息图帧（非 AI 生图） |
| 字幕 | Python 生成 SRT | 按音频时长自动对齐时间轴 |
| 合成 | `ffmpeg` | 帧序列 + 音频 + 字幕 → MP4 |

### 生成步骤

**第 1 步：TTS 配音（28 段）**

```python
import edge_tts
import asyncio

async def gen():
    for i, text in enumerate(narrations):
        comm = edge_tts.Communicate(text, "zh-CN-YunxiNeural", rate="+10%")
        await comm.save(f"audio/shot_{i:02d}.mp3")

asyncio.run(gen())
```

28 段旁白总时长 3 分 51 秒（比预期 2 分钟长，因为技术细节密集，TTS 中速朗读就是这个节奏）。

**第 2 步：Pillow 绘制 28 个画面帧**

每帧本质是一张 1920×1080 的 PNG，暗色底 + 金色主题：

- 标题数字帧（如 `$3,000,000` 大号金色字体 + 光晕效果）
- 数据对比帧（柱状图 / 饼图 / 条形图纯 Pillow 手绘）
- 架构图帧（GB200 Superchip 内部结构、NVSwitch 阵列、网络拓扑）
- 客户 logo 帧、摩尔定律曲线帧

代码量约 500 行，所有绘图函数集中在 `build_video.py` 里。

**第 3 步：生成 SRT 字幕**

根据 28 段音频的时长自动计算时间轴，生成标准 SRT 文件。

```python
def srt_time(t):
    h, m, s = int(t//3600), int((t%3600)//60), int(t%60)
    ms = int((t%1)*1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"
```

**第 4 步：ffmpeg 合成**

```bash
# 先把所有音频合并，放大音量，提升采样率
ffmpeg -f concat -safe 0 -i audio_concat.txt \
  -af "aresample=44100,volume=4.0" \
  -c:a aac -b:a 192k -ar 44100 audio_final.m4a

# 帧序列 + 处理后的音频 → 无字幕版
ffmpeg -f concat -safe 0 -i frames_concat.txt \
  -i audio_final.m4a \
  -c:v libx264 -preset ultrafast -crf 30 \
  -pix_fmt yuv420p -c:a copy -shortest \
  -movflags +faststart \
  gb200_nvl72_cost_no_subs.mp4

# 烧录中文字幕
ffmpeg -i gb200_nvl72_cost_no_subs.mp4 \
  -vf "subtitles=_subs.srt:force_style='FontName=Microsoft YaHei,FontSize=26'" \
  -c:v libx264 -preset ultrafast -crf 23 \
  -c:a copy -movflags +faststart \
  gb200_nvl72_cost.mp4
```

### 踩过的坑

**坑 1：没声音**

`edge-tts` 输出的 MP3 是 24000Hz / 48kbps 低码率，音量极小。直接用 `-c:a aac` 转码时，ffmpeg 的 `loudnorm` 滤镜需要两遍扫描，导致编码时间翻倍。最终方案：先单独处理音频（`aresample=44100,volume=4.0`），再用 `-c:a copy` 无损合入视频。

**坑 2：NVENC 硬件编码不可用**

机器有 NVIDIA 显卡但 `h264_nvenc` 报 `Cannot load cuMemAllocAsync`，驱动版本不兼容。回退到 `libx264 -preset ultrafast`，1920×1080 编码速度约 10 fps，231 秒视频耗时 ~4 分钟。

**坑 3：Windows 路径中的冒号**

ffmpeg 的 `subtitles` 滤镜解析 `H:/path/to/file.srt` 时，把盘符 `H:` 后的冒号当成滤镜参数分隔符，报 `Invalid argument`。解决：把 SRT 复制到当前目录，用纯文件名 `subtitles=_subs.srt` 引用。

**坑 4：长视频超时**

单次 ffmpeg 同时编码视频 + 音频处理 + 字幕烧录，总耗时超过 10 分钟触发超时，moov atom 未写入导致文件损坏。解决：拆成两次编码——先做无字幕版（快速过），再单独烧字幕。

### 最终成品

| 属性 | 值 |
|------|-----|
| 文件 | `gb200_nvl72_cost.mp4` |
| 大小 | 7.5 MB |
| 分辨率 | 1920×1080 (16:9) |
| 时长 | 3 分 51 秒 |
| 视频编码 | H.264 (libx264 ultrafast) |
| 音频 | AAC 44100Hz 单声道（4 倍增益） |
| 字幕 | 硬字幕（微软雅黑, 28 条 SRT） |
| 帧数 | 28 帧（每帧持续 2.7~14.1 秒不等） |

### 一键生成脚本

完整脚本已开源在 `video_output/build_video.py`，执行即可复现：

```bash
cd video_output
python build_video.py
```

依赖：`pip install edge-tts pillow`，系统需安装 `ffmpeg`。

> **改进方向**：将 Pillow 绘制的帧替换为 GPT Image 2 / Midjourney 出图（保持同名），重新跑合成步骤即可升级画面质量。也可用 Manim 替代 Pillow 做动画过渡。

---

## 附录：完整源码 (`video_output/build_video.py`)

<details>
<summary>点击展开完整源码（~770 行）</summary>

```python
#!/usr/bin/env python3
"""
GB200 NVL72 成本拆解视频生成器
使用 edge-tts + Pillow + ffmpeg 生成完整视频
"""

import asyncio
import json
import os
import subprocess
import sys
import textwrap
import edge_tts
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

# ============================================================
# 配置
# ============================================================
OUTPUT_DIR = Path(__file__).parent
FRAMES_DIR = OUTPUT_DIR / "frames"
AUDIO_DIR = OUTPUT_DIR / "audio"
VIDEO_OUT = OUTPUT_DIR / "gb200_nvl72_cost.mp4"
SRT_OUT = OUTPUT_DIR / "subtitles.srt"

W, H = 1920, 1080  # 16:9
FPS = 30
TTS_VOICE = "zh-CN-YunxiNeural"  # 男声 或 "zh-CN-XiaoxiaoNeural" 女声
TTS_RATE = "+10%"               # 稍快

# 颜色方案：dark theme + gold accent
BG       = (18,  18,  24)
GOLD     = (212, 175, 55)
WHITE    = (240, 240, 245)
LIGHT    = (160, 160, 180)
RED      = (220, 60,  60)
GREEN    = (60,  200, 100)
BLUE     = (80,  160, 255)
ORANGE   = (255, 150, 50)
PURPLE   = (160, 100, 220)
CYAN     = (60,  200, 220)
GRAY_BAR = (50,  50,  65)
DARK_CARD = (28, 28, 38)

# 字体路径（Windows + fallback）
def find_font(size=40):
    candidates = [
        "C:/Windows/Fonts/msyh.ttc",        # 微软雅黑
        "C:/Windows/Fonts/simhei.ttf",       # 黑体
        "C:/Windows/Fonts/simsun.ttc",       # 宋体
        "C:/Windows/Fonts/arial.ttf",
    ]
    for fp in candidates:
        if os.path.exists(fp):
            return ImageFont.truetype(fp, size)
    return ImageFont.load_default()

# ============================================================
# 镜头数据 (标题, 字幕, 绘图函数名)
# ============================================================
SHOTS = [
    ("$3,000,000",       "一台AI服务器机柜 • 三百万美元",                  "draw_title_big_num"),
    ("GB200 NVL72",      "NVIDIA 2024 GTC • 72颗Blackwell GPU塞进一个机柜", "draw_title_bold"),
    ("300万美元",         "相当于 3台法拉利488 · 北京五环一套房",            "draw_comparison"),
    ("钱花在哪？",        "逐层拆解 GB200 NVL72 成本构成",                  "draw_section_title"),
    ("GB200 Superchip",  "1×Grace CPU + 2×B200 GPU  单颗$60K-$70K × 36颗", "draw_superchip"),
    ("2080亿晶体管",     "台积电4NP工艺  单颗B200 = 2080亿晶体管",         "draw_transistor"),
    ("HBM3e 高带宽显存", "每颗B200搭载192GB HBM3e  全柜13.5TB",           "draw_hbm"),
    ("$2,200,000",       "GPU与显存  占总成本的 75%",                      "draw_cost_bar_1"),
    ("NVLink 5 交换网络","18个NVSwitch交换盘  9000根铜缆连接器",          "draw_nvswitch"),
    ("铜背板 130TB/s",   "5000+根铜缆  总带宽130TB/s  比光纤便宜6倍",     "draw_backplane"),
    ("$250,000",         "NVLink交换网络  约25万美元  占比8%",             "draw_cost_bar_2"),
    ("液冷散热系统",     "全柜功耗120kW  风冷极限30kW  必须上液冷",       "draw_cooling"),
    ("120kW vs 30kW",    "传统风冷单柜30kW  GB200 NVL72高达120kW",        "draw_power_compare"),
    ("$100,000",         "CDU冷却液分配单元+冷板+管路  约10万美元  占比3-4%", "draw_cost_bar_3"),
    ("ConnectX-8 网卡",  "36块800Gb/s网卡 + Spectrum-X交换机",             "draw_nic_array"),
    ("Spectrum-X 以太网","专为AI流量优化的以太网方案  InfiniBand级性能",   "draw_network_topology"),
    ("$150,000",         "整套网络方案  约15万美元  占比5%",                "draw_cost_bar_4"),
    ("定制机柜 & 供电",  "NVIDIA定制宽体机柜  415V三相供电  非标准设计",   "draw_rack"),
    ("415V 120kW",       "铜质电源母排  跳过UPS直供  省转换损耗",          "draw_busbar"),
    ("$55,000",          "定制机柜+PDU供电+组装测试  约5.5万美元  占比2%",  "draw_cost_bar_5"),
    ("组装与烧机测试",   "数周组装 + 72小时满负荷烧机  任何一个节点出问题整柜返工","draw_assembly"),
    ("训练速度对比",     "万亿参数模型  H100:90-100天  GB200:25-30天       → 4倍加速","draw_training_compare"),
    ("推理吞吐 5x提升",  "同一LLM推理  H100:20 tok/s  GB200:100+ tok/s","draw_inference_compare"),
    ("13.5TB 统一显存",  "72颗GPU在NVLink下变成一台超级GPU  大模型不切分直接跑","draw_unified_memory"),
    ("谁在买？",         "Microsoft · Meta · Oracle · xAI · CoreWeave · Lambda Labs","draw_customers"),
    ("成本全景图",       "GPU显存75% · NVLink8% · 液冷4% · 网络5% · 机柜2% · 组装6%","draw_pie_chart"),
    ("超级摩尔定律",     "DGX-1$129K(2016) → H100$300K(2022) → GB200$3M(2024)  每2年10倍增长","draw_moore_curve"),
    ("算力无价 硬件有价","COMPUTE IS PRICELESS. HARDWARE IS NOT.","draw_ending"),
]

# ============================================================
# 绘图函数
# ============================================================
def new_frame():
    return Image.new("RGB", (W, H), BG)

def draw_centered_text(draw, text, y, font, color=WHITE):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) / 2, y), text, font=font, fill=color)

def draw_subtitle(draw, text, font=None):
    if font is None:
        font = find_font(28)
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) / 2, H - 100), text, font=font, fill=LIGHT)

def draw_logo(draw):
    font = find_font(18)
    draw.text((40, H - 50), "NVIDIA GB200 NVL72 · 成本拆解", font=font, fill=(60, 60, 80))

# ---------- 各镜头绘图（28个函数）----------

def draw_title_big_num(img):
    draw = ImageDraw.Draw(img)
    font_big, font_sub = find_font(200), find_font(40)
    text = "$3,000,000"
    bbox = draw.textbbox((0, 0), text, font=font_big)
    tw = bbox[2] - bbox[0]
    for offset, alpha in [(8, 30), (4, 60), (2, 100), (0, 255)]:
        c = tuple(min(255, int(GOLD[i] * alpha / 255)) for i in range(3))
        draw.text(((W - tw) / 2 + offset, 320 + offset), text, font=font_big, fill=c)
    draw.text(((W - tw) / 2, 320), text, font=font_big, fill=GOLD)
    draw_subtitle(draw, "一台AI服务器机柜 • 三百万美元", font_sub)
    draw_logo(draw)

def draw_title_bold(img):
    draw = ImageDraw.Draw(img)
    draw_centered_text(draw, "GB200 NVL72", 300, find_font(100), GOLD)
    draw_centered_text(draw, "NVIDIA 2024 GTC 大会发布", 460, find_font(32), WHITE)
    draw_centered_text(draw, "72 颗 Blackwell GPU 塞进一个机柜", 520, find_font(32), LIGHT)
    draw.line([(W//2-300, 620), (W//2+300, 620)], fill=GOLD, width=3)
    draw_subtitle(draw, "2024年3月18日 · Jensen Huang 主题演讲")
    draw_logo(draw)

def draw_comparison(img):
    draw = ImageDraw.Draw(img)
    items = [("🏎️", "3 台", "法拉利 488"), ("🏠", "1 套", "北京五环房"), ("🖥️", "1 台", "GB200 NVL72")]
    col_w = W // 3
    for i, (emoji, num, label) in enumerate(items):
        cx = col_w * i + col_w // 2
        draw_centered_text(draw, emoji, 250, find_font(80))
        draw_centered_text(draw, num, 400, find_font(64), GOLD)
        draw_centered_text(draw, label, 480, find_font(36), WHITE)
    draw_centered_text(draw, "$  3 , 0 0 0 , 0 0 0", 620, find_font(40), LIGHT)
    draw_subtitle(draw, "三百万美元 能买什么？")
    draw_logo(draw)

def draw_section_title(img):
    draw = ImageDraw.Draw(img)
    draw_centered_text(draw, "💰", 200, find_font(100))
    draw_centered_text(draw, "逐层拆解", 400, find_font(120), GOLD)
    draw_centered_text(draw, "一台 GB200 NVL72 的 6 层成本结构", 580, find_font(36), LIGHT)
    draw.line([(W//2-400, 680), (W//2+400, 680)], fill=GOLD, width=2)
    draw_logo(draw)

def draw_superchip(img):
    draw = ImageDraw.Draw(img)
    cx, cy = W//2, 380
    draw.rounded_rectangle([cx-300, cy-150, cx+300, cy+150], radius=20, outline=GOLD, width=4)
    draw_centered_text(draw, "GB200 Superchip", cy-80, find_font(30), GOLD)
    draw.rounded_rectangle([cx-260, cy-20, cx-30, cy+120], radius=12, outline=BLUE, width=3, fill=(0, 30, 60))
    draw_centered_text(draw, "Grace CPU", cy+20, find_font(24), BLUE)
    draw.rounded_rectangle([cx+30, cy-50, cx+260, cy+40], radius=12, outline=GREEN, width=3, fill=(0, 40, 0))
    draw_centered_text(draw, "B200 GPU", cy-30, find_font(24), GREEN)
    draw.rounded_rectangle([cx+30, cy+50, cx+260, cy+120], radius=12, outline=GREEN, width=3, fill=(0, 40, 0))
    draw_centered_text(draw, "B200 GPU", cy+60, find_font(24), GREEN)
    draw_centered_text(draw, "× 36 颗  每颗 $60,000 – $70,000", 640, find_font(48), GOLD)
    draw_subtitle(draw, "GB200 Superchip = 1×Grace CPU + 2×B200 GPU  全柜36颗", find_font(26))
    draw_logo(draw)

def draw_transistor(img):
    draw = ImageDraw.Draw(img)
    draw_centered_text(draw, "208,000,000,000", 280, find_font(80), GOLD)
    draw_centered_text(draw, "个晶体管", 380, find_font(80), WHITE)
    draw_centered_text(draw, "台积电 4NP（4纳米）定制工艺", 500, find_font(32), LIGHT)
    draw_centered_text(draw, "单颗 B200 GPU   流片费用 > 1亿美元", 580, find_font(32), LIGHT)
    for i in range(0, W, 40):
        for j in range(0, 200, 40):
            draw.rectangle([i, 650+j, i+30, 650+j+30], outline=(30, 30, 45), width=1)
    draw_centered_text(draw, "▸ 208 BILLION TRANSISTORS ◂", 910, find_font(22), (80, 80, 100))
    draw_subtitle(draw, "单颗B200：2080亿晶体管  台积电4NP工艺")
    draw_logo(draw)

def draw_hbm(img):
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([W//2-120, 280, W//2+120, 480], radius=18, outline=BLUE, width=4, fill=(5, 15, 40))
    draw_centered_text(draw, "B200", 355, find_font(36), BLUE)
    draw_centered_text(draw, "GPU Die", 400, find_font(24), BLUE)
    hbm_positions = [(W//2-180,180),(W//2-60,140),(W//2+60,140),(W//2+180,180),
                     (W//2-180,520),(W//2-60,560),(W//2+60,560),(W//2+180,520)]
    for px, py in hbm_positions:
        draw.rectangle([px-35, py-45, px+35, py+45], outline=GOLD, width=2, fill=(30, 25, 5))
        draw.text((px-25, py-30), "HBM", font=find_font(14), fill=GOLD)
    draw_centered_text(draw, "192GB HBM3e × 72 = 13.5TB", 700, find_font(72), GOLD)
    draw_centered_text(draw, "8TB/s 显存带宽 / 每颗GPU", 790, find_font(30), WHITE)
    draw_subtitle(draw, "全柜 13.5TB 高速显存  物料成本近 20 万美元")
    draw_logo(draw)

def draw_nvswitch(img):
    draw = ImageDraw.Draw(img)
    for row in range(3):
        for col in range(6):
            rx, ry = 260 + col*240, 200 + row*180
            draw.rounded_rectangle([rx, ry, rx+200, ry+140], radius=10, outline=ORANGE, width=3, fill=(30, 20, 5))
            draw.text((rx+40, ry+40), "NVSwitch", font=find_font(20), fill=ORANGE)
            draw.text((rx+50, ry+70), f"{row*6+col+1:02d}", font=find_font(22), fill=WHITE)
    draw_centered_text(draw, "18 个 NVSwitch 交换盘", 760, find_font(60), GOLD)
    draw_centered_text(draw, "9,000+ 铜缆连接器  把72颗GPU焊成整体", 840, find_font(30), WHITE)
    draw_subtitle(draw, "NVSwitch 5 交换盘 × 18  每盘 ~$14K")
    draw_logo(draw)

def draw_backplane(img):
    draw = ImageDraw.Draw(img)
    draw_centered_text(draw, "130 TB/s", 280, find_font(110), GOLD)
    draw_centered_text(draw, "总带宽", 420, find_font(48), WHITE)
    draw_centered_text(draw, "🟤 铜缆背板  比光纤便宜 6 倍", 560, find_font(32), GOLD)
    draw_centered_text(draw, "NVLink 5  1.8TB/s 双向带宽 / GPU", 690, find_font(32), LIGHT)
    draw_centered_text(draw, "\"用铜不用光\"——Jensen Huang, GTC 2024", 780, find_font(24), (100, 100, 120))
    draw_subtitle(draw, "NVLink 5 铜背板  5000+根铜缆  130TB/s总带宽")
    draw_logo(draw)

def draw_cooling(img):
    draw = ImageDraw.Draw(img)
    for i in range(6):
        y = 180 + i*100
        draw.rectangle([100, y, 600, y+60], outline=CYAN, width=2, fill=(0, 30, 40))
        draw.text((120, y+10), "❄️", font=find_font(30))
        for j in range(8):
            draw.ellipse([160+j*55, y+20, 180+j*55, y+40], fill=CYAN if j%2==0 else (0, 60, 80))
    draw_centered_text(draw, "120 kW", 380, find_font(80), RED)
    draw_centered_text(draw, "≈ 一栋30户居民楼夏天开满空调", 560, find_font(34), LIGHT)
    draw_centered_text(draw, "风冷单柜极限仅 30kW  必须上液冷", 630, find_font(34), WHITE)
    draw_subtitle(draw, "功耗 120kW  传统风冷撑不住  液冷是唯一方案")
    draw_logo(draw)

def draw_power_compare(img):
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([100, 250, 600, 550], radius=15, outline=RED, width=3, fill=(30, 10, 10))
    draw_centered_text(draw, "传统风冷机柜", 220, find_font(32), RED)
    draw_centered_text(draw, "Max 30 kW", 400, find_font(80), RED)
    draw.rounded_rectangle([W-600, 200, W-100, 600], radius=15, outline=GREEN, width=4, fill=(0, 30, 10))
    draw_centered_text(draw, "GB200 NVL72", 180, find_font(32), GREEN)
    draw_centered_text(draw, "120 kW", 340, find_font(90), GREEN)
    draw_centered_text(draw, "4 倍于极限", 460, find_font(60), GREEN)
    draw_centered_text(draw, "VS", 400, find_font(120), GOLD)
    draw_subtitle(draw, "传统风冷 vs GB200 NVL72  功耗差距 4 倍")
    draw_logo(draw)

def draw_nic_array(img):
    draw = ImageDraw.Draw(img)
    for row in range(6):
        for col in range(6):
            nx, ny = 300+col*200, 180+row*120
            draw.rounded_rectangle([nx, ny, nx+170, ny+90], radius=8, outline=BLUE, width=2, fill=(5, 10, 35))
            draw.text((nx+20, ny+15), "CX-8", font=find_font(26), fill=BLUE)
            draw.text((nx+20, ny+45), "800Gb/s", font=find_font(18), fill=WHITE)
    draw_centered_text(draw, "36 块 ConnectX-8", 900, find_font(60), GOLD)
    draw_centered_text(draw, "每块 800Gb/s + Spectrum-X 交换机", 970, find_font(28), WHITE)
    draw_subtitle(draw, "网络方案  36 NIC × 800Gb/s + Spectrum-X 交换")
    draw_logo(draw)

def draw_network_topology(img):
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([W//2-250, 120, W//2+250, 200], radius=12, outline=PURPLE, width=3, fill=(20, 10, 30))
    draw_centered_text(draw, "Spectrum-X 交换机", 145, find_font(28), PURPLE)
    for i in range(36):
        sx, sy = 180+(i%12)*130, 320+(i//12)*160
        draw.line([(W//2, 200), (sx, sy)], fill=(60, 40, 100), width=1)
        draw.rectangle([sx-35, sy-20, sx+35, sy+20], outline=BLUE, width=2, fill=(5, 10, 30))
        draw.text((sx-25, sy-12), f"GB{i+1}", font=find_font(14), fill=BLUE)
    draw_centered_text(draw, "Rail-optimized  Adaptive Routing  低延迟", 850, find_font(28), PURPLE)
    draw_subtitle(draw, "Spectrum-X  专为AI训练流量优化的以太网")
    draw_logo(draw)

# ... 其余绘图函数 (draw_rack, draw_busbar, draw_assembly, draw_cost_bar 系列,
#     draw_training_compare, draw_inference_compare, draw_unified_memory,
#     draw_customers, draw_pie_chart, draw_moore_curve, draw_ending)
#     完整代码见 video_output/build_video.py，此处略去以保持博客可读性。

# ============================================================
# TTS 旁白 (28段)
# ============================================================
NARRATIONS = [
    "一台AI服务器机柜，三百万美元。",
    "它叫GB200 NVL72，NVIDIA在2024年GTC大会上发布的旗舰。72颗Blackwell GPU，塞进一个机柜。",
    "三百万美元，相当于三台法拉利488，或者北京五环一套房。",
    "现在，我们来把它拆开。",
    "最大的开销在GPU。36颗GB200 Superchip，每颗封装两颗B200 GPU和一颗Grace CPU。单颗六到七万美元。三十六颗，两百万就出去了。",
    "一颗B200上有两千零八十亿个晶体管，台积电四纳米定制工艺。这个量级的芯片，光流片费用就要上亿美元。",
    "比GPU Die更贵的，是它身边的HBM3e高带宽显存。每颗B200搭载192GB，整个机柜堆了13.5TB。物料成本接近二十万美元。",
    "仅GPU和显存，就花掉两百二十万美元，占总成本的四分之三。",
    "第二笔大开销是NVLink交换网络。十八个NVSwitch交换盘，用九千个铜缆连接器把七十二颗GPU焊成一个整体。",
    "铜背板提供每秒130TB总带宽，比光纤方案便宜六倍。这是NVIDIA的秘密武器。",
    "仅交换网络部分，又是二十五万美元。",
    "这个机柜跑起来要吃掉一百二十千瓦的电。一栋三十户居民楼夏天开满空调也就这个功率。风冷根本顶不住，必须上液冷。",
    "传统数据中心单柜功耗撑死三十千瓦，GB200直接冲到一百二，是极限的四倍。",
    "液冷散热系统——冷却液分配单元、冷板、管路——加起来要十万美元。",
    "GPU算得再快，数据进不来也白搭。每颗Superchip配一块八百G的网卡，加上Spectrum-X交换机，整套网络方案十五万美元。",
    "Spectrum-X是NVIDIA专为AI训练流量优化的以太网方案，能做到InfiniBand级别的性能。",
    "整套网络方案约十五万美元，占总成本百分之五。",
    "这个机柜不是标准件，NVIDIA重新设计了整个结构来容纳七十二颗GPU和一百二十千瓦的供电。",
    "供电是415伏三相直入，跳过传统UPS直接上电，就是为了省转换损耗。",
    "定制机柜、电源分配、组装测试，五万五千美元。",
    "每台NVL72出厂前需要数周组装和七十二小时满负荷烧机测试。任何一个节点出问题，整柜都得返工。",
    "三百万值不值？看你怎么算。训练一个万亿参数大模型，H100要跑三到四个月，GB200一个月以内搞定。",
    "推理性能更是五倍提升，而且因为72颗GPU共享13.5TB统一显存，不用切模型，整个万亿参数模型可以直接塞进一个机柜跑。",
    "72颗GPU在NVLink下变成一台超级GPU，大模型不切分，直接跑。省掉分布式训练的通信开销，这是质的区别。",
    "这也是为什么微软、Meta、Oracle、xAI这些公司已经在排队下单。在这个级别的竞赛里，时间就是护城河。",
    "拆完你会发现，三百万里，两百二十万花在GPU和显存上。剩下的八十万，是让这七十二颗GPU真正能一起工作的代价。",
    "从2016年的DGX-1十二万九，到2024年的GB200 NVL72三百万，AI硬件的价格曲线比摩尔定律陡十倍。这就是算力军备竞赛的真相。",
    "算力无价。但硬件，真的有价。",
]

# ============================================================
# 核心流程
# ============================================================
async def generate_tts():
    """逐段生成 TTS 音频，返回 (路径, 时长) 列表"""
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    results = []
    for i, text in enumerate(NARRATIONS):
        out_file = AUDIO_DIR / f"shot_{i:02d}.mp3"
        if out_file.exists():
            r = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries",
                "format=duration", "-of", "json", str(out_file)],
                capture_output=True, text=True)
            dur = float(json.loads(r.stdout)["format"]["duration"])
            results.append((str(out_file), dur))
            continue
        comm = edge_tts.Communicate(text, TTS_VOICE, rate=TTS_RATE)
        await comm.save(str(out_file))
        r = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries",
            "format=duration", "-of", "json", str(out_file)],
            capture_output=True, text=True)
        dur = float(json.loads(r.stdout)["format"]["duration"])
        results.append((str(out_file), dur))
        print(f"  [音频] shot_{i:02d} ({dur:.1f}s)")
    return results

def generate_frames(audio_durations):
    """Pillow 绘制 28 张 1920×1080 信息图"""
    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    frame_list = []
    for i, (title, subtitle, draw_fn) in enumerate(SHOTS):
        img = new_frame()
        globals()[draw_fn](img)   # 按函数名动态调用绘图函数
        out_path = FRAMES_DIR / f"frame_{i:03d}.png"
        img.save(out_path)
        dur = audio_durations[i][1]
        frame_list.append((str(out_path), dur))
    return frame_list

def generate_srt(audio_durations):
    """自动生成 SRT 字幕"""
    srt, t = [], 0.0
    for i, (_, dur) in enumerate(audio_durations):
        def fmt(x):
            h, m, s = int(x//3600), int((x%3600)//60), int(x%60)
            return f"{h:02d}:{m:02d}:{s:02d},{int((x%1)*1000):03d}"
        srt += [f"{i+1}", f"{fmt(t)} --> {fmt(t+dur)}", NARRATIONS[i], ""]
        t += dur
    SRT_OUT.write_text("\n".join(srt), encoding="utf-8")

def compose_video(frame_list):
    """ffmpeg 合成：帧序列 + 音频 + 字幕 → MP4
    注意：实际踩坑后改为两遍编码（先无字幕再烧字幕），
    且音频需预处理音量（aresample=44100,volume=4.0）。
    此处保留原始逻辑供参考，实际执行命令见上文"实际生成"章节。
    """
    # ... (实际合成逻辑见上文"实际生成"章节的 ffmpeg 命令)

async def main():
    audio = await generate_tts()
    frames = generate_frames(audio)
    generate_srt(audio)
    compose_video(frames)

if __name__ == "__main__":
    asyncio.run(main())
```

</details>

> **完整版源码**（含所有 28 个 Pillow 绘图函数的完整实现）见仓库 `video_output/build_video.py`。
