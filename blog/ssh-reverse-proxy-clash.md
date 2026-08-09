---
title: "公网服务器通过 SSH 反向隧道使用局域网 Clash 代理"
date: 2026-08-09T18:45:00+08:00
draft: false
tags: ["ssh", "proxy", "clash", "network"]
categories: ["Tech"]
description: "一行 SSH 命令，让没有科学上网的云服务器走回你家局域网的 Clash 代理。"
---

你有一台国内云服务器，需要从 GitHub / HuggingFace / PyTorch 官方源下载东西，直连慢到怀疑人生。但你本地电脑已经跑着 Clash，出国速度飞快。能不能让服务器**借用**本地的 Clash？**能，一行 SSH 反向隧道搞定。**

{/* truncate */}

## 原理：SSH Remote Port Forwarding

```
┌─────────────────┐          SSH 反向隧道            ┌─────────────────┐
│   本地机器       │ ◄══════════════════════════════ │   公网服务器      │
│                 │                                 │                 │
│  Clash :7890 ───┼──── 映射到 ──────────────────►  │ 127.0.0.1:1080  │
│                 │                                 │        │         │
└─────────────────┘                                 │   curl github   │
                                                    │   pip install   │
                                                    │   git clone     │
                                                    └─────────────────┘
```

`ssh -R` 在远程服务器上开一个监听端口，所有到这个端口的流量都**反向**通过 SSH 隧道送回本地机器，再由本地 Clash 转发出去。服务器自己不需要装任何代理客户端。

## 第一步：本地建立反向隧道

你的 Clash 跑在本机 `127.0.0.1:7890`，在**本地终端**执行：

```bash
ssh -N -R 1080:127.0.0.1:7890 root@你的服务器IP
```

| 参数 | 含义 |
|------|------|
| `-N` | 不执行远程命令，只做端口转发 |
| `-R 1080:127.0.0.1:7890` | 远程 `1080` 端口 → 本地 `7890` 端口 |
| `root@IP` | 你的服务器 |

执行后终端会挂住（正常现象），隧道在后台维持。**不要关掉这个窗口。**

> 防止断连：加上 `-o ServerAliveInterval=60` 保持心跳。

## 第二步：服务器上设置代理

在**服务器终端**：

```bash
export http_proxy="http://127.0.0.1:1080"
export https_proxy="http://127.0.0.1:1080"
export ALL_PROXY="socks5h://127.0.0.1:1080"
```

验证一下：

```bash
curl -I https://github.com
# HTTP/2 200  ← 走通了
```

然后该怎么用怎么用——pip、git、wget 全部自动走代理。

## 为什么用 `-R` 而不是 `-L`？

| 场景 | 方向 | 用 |
|------|------|-----|
| 从**本机**访问**远程**内网服务 | 本机 → 远程 | `-L`（本地转发）|
| 让**远程**访问**本机**的服务 | 远程 → 本机 | `-R`（远程转发）|

这里是**远程要连本机的 Clash**，所以用 `-R`。

## 进阶：autossh 自动重连

SSH 隧道断了不会自动恢复。用 `autossh` 解决：

```bash
autossh -M 0 -N \
  -o "ServerAliveInterval=60" \
  -o "ServerAliveCountMax=3" \
  -R 1080:127.0.0.1:7890 \
  root@你的服务器IP
```

断了自动重连。再写个 alias 到 `.bashrc` 更方便：

```bash
alias proxy-server='autossh -M 0 -N -o ServerAliveInterval=60 -R 1080:127.0.0.1:7890 root@你的服务器IP'
```

以后 `proxy-server` 一个命令就搞定。

## 实战：AutoDL 云服务器装 PyTorch

我最近在 AutoDL 的 Tesla T4 实例上搭 ComfyUI，PyTorch 官方源下载 2.5 GB 的 wheel 直接 600 秒超时。挂了反向隧道之后，一台没有代理客户端的云服务器瞬间跑满带宽：

```bash
# 服务器上
export https_proxy=http://127.0.0.1:1080
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
# 2.5 GB 几分钟下完
git clone https://github.com/comfyanonymous/ComfyUI.git
# 秒克隆
```

## 注意事项

1. **Clash 开启 Allow LAN**：设置里打开"允许局域网连接"
2. **安全**：`-R` 默认只 bind 到远程的 `127.0.0.1`，外部连不进来——这是安全设计
3. **端口冲突**：如果服务器 `1080` 被占用，换个端口，比如 `-R 2080:127.0.0.1:7890`
4. **SOCKS5 vs HTTP**：Clash 的 7890 通常同时支持 HTTP 和 SOCKS5

## 总结

```
本地：     ssh -N -R 1080:127.0.0.1:7890 root@服务器IP
服务器：   export https_proxy=http://127.0.0.1:1080
           # 之后随便下，全走家里网
```

一行命令 + 三个环境变量，服务器立刻拥有和你本地一样的网络。不需要 root、不需要装软件、不需要改服务器配置。SSH 反向隧道是最干净的科学上网方案。
