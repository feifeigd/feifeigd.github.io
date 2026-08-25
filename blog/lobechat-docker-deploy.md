---
title: "LobeChat 自托管部署指南 — Docker 一条命令接 DeepSeek"
date: 2026-08-25T20:00:00+08:00
draft: false
tags: ["lobe-chat", "docker", "deepseek", "ai", "opensource"]
categories: ["Tech"]
description: "用 Docker 一条命令跑起 LobeChat 私有 AI 聊天助手，接入 DeepSeek 模型，附环境变量详解与踩坑记录。"
---

LobeChat 是当前最流行的开源 AI 聊天前端之一，界面漂亮、功能齐全，支持聚合多家大模型供应商。自己部署一台的好处很实在：**对话数据不出自己的服务器，模型按需切换，还省了订阅费**。本文给出一条命令的 Docker 部署方案，直接接 DeepSeek——国内直连、便宜、够用。

{/* truncate */}

## 一、LobeChat 是什么

LobeChat 是一个基于 Next.js 的开源 AI 聊天应用（MIT 协议），核心定位是**多模型统一入口**：

- **多供应商聚合**：OpenAI、DeepSeek、Claude、Gemini、Ollama 本地模型等几十家，一个界面切换
- **Agent 市场**：官方社区有大量预设角色（翻译、编程、写作等），一键安装
- **插件系统**：联网搜索、代码执行、绘图等插件扩展能力
- **知识库**：上传文档做 RAG 检索问答
- **语音**：TTS 朗读回复、STT 语音输入、文生图（DALL·E / Stable Diffusion）

和 LibreChat、Open WebUI 相比，LobeChat 的优势是前端体验最好（移动端适配、会话管理、UI 细节），社区也最活跃。

自托管的意义：**服务端只有你的代码和配置，对话记录默认存浏览器本地**，不经过任何第三方云；模型 API 由你自己掌控，可以随时换更便宜的供应商。

## 二、前置条件

- Docker（Docker Desktop 或 Linux 上的 docker-engine，都行）
- 一个 DeepSeek 的 API Key：[platform.deepseek.com](https://platform.deepseek.com) 注册后创建，几块钱就能用很久
- 服务器/本机 3210 端口空闲

检查端口没被占用：

```bash
ss -tlnp | grep 3210   # 有输出说明被占，先处理
```

## 三、一条命令部署

官方镜像 `lobehub/lobe-chat`，把 API Key 和模型端点通过环境变量注入，一条命令即可：

```bash
docker run -p 3210:3210 -e OPENAI_API_KEY=sk-XX -e OPENAI_PROXY_URL=https://api.deepseek.com -e ACCESS_CODE=lobe66 --name=lobe-chat lobehub/lobe-chat
```

拆开看每一段（建议直接抄这段多行版，方便改）：

```bash
docker run -d \
  -p 3210:3210 \
  -e OPENAI_API_KEY=sk-你的DeepSeekKey \
  -e OPENAI_PROXY_URL=https://api.deepseek.com \
  -e ACCESS_CODE=lobe66 \
  --name=lobe-chat \
  --restart=unless-stopped \
  lobehub/lobe-chat
```

- `-d`：后台运行（加了这个，容器不会占住终端）
- `--restart=unless-stopped`：开机自启、崩溃自动拉起，生产习惯
- 镜像约 1GB 以内，首次 `docker pull` 可能要等一会儿（国内网络慢的见踩坑节）

## 四、环境变量解读

| 变量 | 必填 | 说明 |
|---|---|---|
| `OPENAI_API_KEY` | ✅ | 模型供应商的 API Key。接 DeepSeek 就填 DeepSeek 的 key |
| `OPENAI_PROXY_URL` | 接 DeepSeek 时填 | OpenAI 兼容端点的 base URL，这里指向 `https://api.deepseek.com`。DeepSeek 官方兼容 OpenAI 协议，`/v1` 后缀可加可不加 |
| `ACCESS_CODE` | 推荐 | 访问密码。打开页面后需要输入才能用，防止部署到公网后被白嫖。多个密码用逗号分隔 |

常用进阶变量（不配也能跑，配了更好用）：

| 变量 | 说明 |
|---|---|
| `OPENAI_MODEL_LIST` | 模型白名单/自定义模型列表。DeepSeek 是 OpenAI 兼容通道，默认列表里只有 GPT 系列模型，不配的话要在设置里手动添加 `deepseek-chat` |
| `DEFAULT_MODEL` | 默认选中的模型，如 `deepseek-chat` |
| `DEFAULT_AGENT_CONFIG` | 默认助手配置（JSON） |

## 五、验证与使用

```bash
docker ps                # 看到 lobe-chat 状态 Up 即可
docker logs -f lobe-chat # 看启动日志
```

浏览器打开 `http://localhost:3210`：

1. 输入访问码 `lobe66`（就是你配的 ACCESS_CODE）
2. 左侧新建会话，模型选择 `deepseek-chat`（或 `deepseek-reasoner` 推理版）
3. 开聊

如果模型下拉里没有 DeepSeek 的模型，在「设置 → 语言模型 → OpenAI」里手动添加模型名 `deepseek-chat`，或者用 `OPENAI_MODEL_LIST` 环境变量预置：

```bash
docker run -d \
  -p 3210:3210 \
  -e OPENAI_API_KEY=sk-你的DeepSeekKey \
  -e OPENAI_PROXY_URL=https://api.deepseek.com \
  -e ACCESS_CODE=lobe66 \
  -e OPENAI_MODEL_LIST='[{"name":"deepseek-chat","displayName":"DeepSeek Chat"},{"name":"deepseek-reasoner","displayName":"DeepSeek Reasoner"}]' \
  --name=lobe-chat \
  lobehub/lobe-chat
```

## 六、生产化进阶

**数据持久化**：默认部署下，会话数据存在**浏览器本地**（localStorage/IndexedDB），服务端不落库——换浏览器、清缓存、换设备都会丢历史。介意的话挂一个卷保存配置和缓存：

```bash
docker run -d \
  -p 3210:3210 \
  -v ~/.lobe-chat:/app/data \
  -e OPENAI_API_KEY=sk-你的DeepSeekKey \
  -e OPENAI_PROXY_URL=https://api.deepseek.com \
  -e ACCESS_CODE=lobe66 \
  --name=lobe-chat \
  lobehub/lobe-chat
```

**Docker Compose 版**（推荐，配置可版本管理）：

````yaml
services:
  lobe-chat:
    image: lobehub/lobe-chat
    container_name: lobe-chat
    ports:
      - "3210:3210"
    environment:
      OPENAI_API_KEY: sk-你的DeepSeekKey
      OPENAI_PROXY_URL: https://api.deepseek.com
      ACCESS_CODE: lobe66
      OPENAI_MODEL_LIST: '[{"name":"deepseek-chat","displayName":"DeepSeek Chat"},{"name":"deepseek-reasoner","displayName":"DeepSeek Reasoner"}]'
    volumes:
      - ~/.lobe-chat:/app/data
    restart: unless-stopped
````

**升级**：

```bash
docker pull lobehub/lobe-chat
docker rm -f lobe-chat
# 重新跑上面的 run 命令
```

**HTTPS 反代**：公网部署建议前面挂 Caddy/Nginx 反代，自动签发证书，配合 `ACCESS_CODE` 防白嫖。

## 七、踩坑记录

1. **端口被占**：`docker: Error response from daemon: driver failed programming external connectivity ... bind: address already in use`——换端口（如 `-p 3211:3210`）或先杀掉占用进程
2. **401 / Invalid API key**：`sk-XX` 是占位符，必须换成真实 key；另外确认 DeepSeek 账户有余额
3. **模型列表里没有 DeepSeek**：OpenAI 兼容通道默认只显示 GPT 系列模型，按第五节添加 `deepseek-chat`
4. **WSL 里找不到 docker 命令**：Docker Desktop 装在 Windows 侧时，WSL 里要开「Settings → Resources → WSL Integration」；临时方案是直接用 `docker.exe` 调用
5. **镜像拉取慢/超时**：配置国内镜像加速器（docker.io 镜像源），或用代理后重启 Docker
6. **对话记录丢失**：不是 bug，是设计——默认存浏览器端，要服务端持久化按第六节挂卷/落库
7. **`/v1` 后缀疑惑**：DeepSeek 的 base URL 官方支持 `https://api.deepseek.com` 和 `https://api.deepseek.com/v1` 两种写法，都兼容 OpenAI 协议，二选一即可

## 八、架构一览

```text
浏览器 (React SPA + 会话本地存储)
        │  HTTP
        ▼
Next.js 服务端 (lobehub/lobe-chat 容器, :3210)
        │  转发请求（带上你的 API Key）
        ▼
DeepSeek API (api.deepseek.com, OpenAI 兼容协议)
```

要点：**API Key 在服务端环境变量里**，浏览器端只拿渲染后的结果，不会泄露 key；服务端做模型路由、会话管理、插件调用，对话内容按需转发给模型厂商。自托管版本数据链路完全在你掌控之内。

## 总结

LobeChat + DeepSeek 是当前性价比很高的自托管组合：界面体验接近 ChatGPT Plus，模型按量付费（比订阅便宜得多），数据自己掌控。部署核心就是一条 `docker run`，剩下的都是环境变量的事。跑起来之后，配合 Agent 市场和插件，基本可以替代日常的 ChatGPT/Claude 网页版。

相关阅读：[SSH 反向隧道 + Clash 搭建代理](/blog/ssh-reverse-proxy-clash)、[Tesla T4 云服务器部署 ComfyUI + CogVideoX](/blog/comfyui-cogvideox-t4-deploy)
