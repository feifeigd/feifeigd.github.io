---
title: "Tesla T4 云服务器部署 ComfyUI + CogVideoX 视频生成完整指南"
date: 2026-08-09T19:30:00+08:00
draft: false
tags: ["comfyui", "gpu", "infra", "video-generation", "opensource"]
categories: ["Tech"]
description: "在 Ubuntu 20.04 + Tesla T4 上从零搭建 ComfyUI，部署 CogVideoX-5B 开源视频生成模型，含网络加速、踩坑全记录。"
---

云服务器搭 AI 绘图/视频生成环境，网络和依赖是最大拦路虎。本文记录在 AutoDL Tesla T4（16 GB 显存）实例上，从裸 Ubuntu 20.04 到跑通 ComfyUI + CogVideoX-5B 的完整过程。

{/* truncate */}

## 硬件与环境

| 项目 | 配置 |
|------|------|
| 系统 | Ubuntu 20.04.4 LTS |
| GPU | Tesla T4 16 GB |
| RAM | 251 GB |
| 磁盘 | 系统 30 GB + 数据盘 50 GB |
| CUDA | 12.4 |

T4 的 16 GB 显存刚好能跑 CogVideoX-5B（推理约占 12-14 GB），Wan 2.1 和 HunyuanVideo 等 24 GB+ 的模型就不用想了。

## 第一步：Python 环境

服务器自带 miniconda3 但 Python 3.8 太老，清华源又 403。换 conda-forge 创建 3.10 环境：

```bash
conda config --remove-key channels
conda config --add channels conda-forge
conda create -n comfyui python=3.10 -y
```

## 第二步：网络加速

云服务器在国内，GitHub、PyTorch 官方源全部龟速。用 SSH 反向隧道借本地 Clash：

**本地机器：**

```bash
ssh -N -R 1080:127.0.0.1:7890 root@region-9.autodl.pro -p 33734
```

**服务器：**

```bash
export http_proxy="http://127.0.0.1:1080"
export https_proxy="http://127.0.0.1:1080"
```

之后所有 pip、git 全走代理，2.5 GB 的 PyTorch 几分钟下完。

## 第三步：安装 PyTorch CUDA 版

第一个坑：pip 清华源没有 torch wheel，阿里云 PyTorch 镜像也挂了。直接用代理从官方源下：

```bash
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu124
```

第二个坑：中途不小心装成了 ROCm 版（AMD 的）。一定要确认：

```bash
python -c "import torch; print(torch.__version__)"
# torch-2.6.0+cu124   ← 必须是 cu124，不是 rocm
```

## 第四步：安装 ComfyUI

```bash
cd /root/autodl-tmp
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
pip install -r requirements.txt
```

这一步会装很多依赖（transformers、diffusers、aiohttp 等），走代理大约 5-10 分钟。

## 第五步：安装 CogVideoX 节点

```bash
mkdir -p custom_nodes && cd custom_nodes
git clone https://github.com/kijai/ComfyUI-CogVideoXWrapper.git --depth 1
cd ComfyUI-CogVideoXWrapper
pip install -r requirements.txt
```

`--depth 1` 减少 clone 体积，在慢网络下很关键。

## 第六步：下载 CogVideoX-5B 模型

HuggingFace 在国内基本不可用，走 ModelScope 镜像：

```bash
pip install modelscope
mkdir -p /root/autodl-tmp/ComfyUI/models/CogVideo/CogVideoX-5b

python3 -c "
from modelscope import snapshot_download
snapshot_download('ZhipuAI/CogVideoX-5b',
    cache_dir='/root/autodl-tmp/ComfyUI/models/CogVideo/CogVideoX-5b')
"
```

第三个坑：ModelScope 上模型名是 `ZhipuAI/CogVideoX-5b`，不是 `THUDM/CogVideoX-5b`。总大小约 17 GB（两个 safetensors 分片 + VAE + text encoder），下载速度约 600-800 KB/s，需要 6-7 小时。

## 第七步：启动 ComfyUI

```bash
/root/miniconda3/envs/comfyui/bin/python \
  /root/autodl-tmp/ComfyUI/main.py \
  --listen 0.0.0.0 --port 8188
```

启动日志关键行：

```
Device: cuda:0 Tesla T4 : cudaMallocAsync
To see the GUI go to: http://0.0.0.0:8188
```

看到这两行就说明 GPU 识别成功，Web 服务已启动。

## 第八步：访问 Web 界面

AutoDL 的公网 IP 不通，用 SSH 本地端口转发：

```bash
# 本地机器执行（58188 可换成其他端口）
ssh -N -L 58188:127.0.0.1:8188 -p 33734 root@region-9.autodl.pro
```

然后浏览器打开 `http://localhost:58188`。

第四个坑：本地 8188 可能被其他服务占用，换一个端口就行。

## 踩坑全记录

| 坑 | 原因 | 解法 |
|----|------|------|
| conda 创建环境失败 | 清华源 403 + conda 4.10.3 太旧 | 换 conda-forge |
| pip 找不到 torch | 清华 pip 镜像没有 PyTorch wheel | 走代理从官方源 |
| 装成 ROCm 版 PyTorch | SJTU 镜像默认给了 rocm wheel | Kill 后用 `--index-url cu124` 重装 |
| GitHub clone 超时 | 国内到 GitHub 直连太慢 | 走代理 + `--depth 1` |
| ModelScope 下载失败 | 模型 ID 不对（`THUDM/` vs `ZhipuAI/`） | 搜对 ID：`ZhipuAI/CogVideoX-5b` |
| 公网 IP 打不开 | AutoDL 实例有防火墙 | SSH `-L` 本地端口转发 |
| 本地端口 Permission denied | 8188 被占用 | 换 58188 等其它端口 |

## 常用命令速查

```bash
# SSH 到服务器
ssh -p 33734 root@region-9.autodl.pro

# 激活环境 + 设置代理
export PATH=/root/miniconda3/envs/comfyui/bin:$PATH
export https_proxy=http://127.0.0.1:1080

# 启动 ComfyUI
python /root/autodl-tmp/ComfyUI/main.py --listen 0.0.0.0 --port 8188

# 查看模型下载进度
tail -f /root/dl_cog.log

# 查看 ComfyUI 日志
tail -f /root/comfyui.log

# 停止 ComfyUI
kill $(pgrep -f main.py)

# 从本地打开
ssh -N -L 58188:127.0.0.1:8188 -p 33734 root@region-9.autodl.pro
# → http://localhost:58188
```

## 架构一览

```
┌──────────────────────────────────────────────────┐
│  本地机器                                         │
│  Clash :7890 ───── SSH -R ─────► 服务器 :1080     │
│  浏览器 :58188 ──── SSH -L ────► 服务器 :8188     │
└──────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼────────────────────────┐
│  AutoDL 云服务器 (Tesla T4 16 GB)                  │
│                                                   │
│  /root/autodl-tmp/                                │
│  ├── ComfyUI/              ← 主程序               │
│  │   ├── main.py                                  │
│  │   └── custom_nodes/                            │
│  │       └── ComfyUI-CogVideoXWrapper/            │
│  └── models/CogVideo/CogVideoX-5b/  ← 模型 17 GB │
│                                                   │
│  /root/miniconda3/envs/comfyui/ ← Python 3.10     │
│    ├── torch 2.6.0+cu124                          │
│    ├── transformers                               │
│    └── diffusers                                  │
└──────────────────────────────────────────────────┘
```

## 总结

T4 16 GB 跑 CogVideoX-5B 是可行的，但有三个关键点：

1. **网络**：SSH 反向隧道借本地代理是最干净的方案，服务器零额外配置
2. **显存**：16 GB 刚好卡线，运行时别开其他 GPU 程序
3. **耐心**：一段 5 秒 720p 视频在 T4 上预计 5-10 分钟，不是实时
