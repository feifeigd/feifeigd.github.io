---
title: "CentOS 7 + nerdctl 服务器编译 llama.cpp 完整指南 — 容器化构建与实测"
date: 2026-08-27T21:00:00+08:00
draft: false
tags: ["llama-cpp", "docker", "linux", "deployment", "infra"]
categories: ["Tech"]
description: "在一台 CentOS 7（gcc 4.8.5 / cmake 2.8）老系统上用 nerdctl 容器编译现代 llama.cpp 的完整流程：Dockerfile 构建环境、sysctl 内核踩坑、四层验证与 llama-server 部署。"
---

云服务器上搭 LLM 推理环境，最怕的不是模型本身，而是操作系统太老。本文记录在一台 CentOS 7 + nerdctl（containerd 系容器运行时）的服务器上，从裸系统到跑通 llama.cpp 编译、推理、HTTP 服务的完整过程，包括一个可复现的 Dockerfile 和全部踩坑记录。

{/* truncate */}

## 一、环境现状与挑战

| 项目 | 配置 |
|------|------|
| 系统 | CentOS 7 (Core)，内核 3.10.0-1160 |
| CPU | 8 vCPU，AMD EPYC 9754 |
| 内存 | 30 GB |
| GPU | 无 |
| gcc | 4.8.5（2015 年，仅支持 C++11） |
| cmake | 2.8.12（2012 年） |
| 容器运行时 | nerdctl 2.3.5（containerd 系，docker 命令兼容） |
| 数据盘 | /data，336 GB 可用 |

**为什么不能直接在宿主机编译？** 三个硬伤：

1. **C++ 标准**：现代 llama.cpp 需要 C++17，gcc 4.8.5 只支持到 C++11，编译直接报语法错误
2. **cmake 版本**：llama.cpp 要求 cmake 3.14+，服务器上是 2012 年的 2.8.12
3. **运行期兼容**：即使编出来，CentOS 7 的 glibc 2.17 和 OpenSSL 1.0.2 也带不动新版依赖

结论：**编译和运行都必须在容器里完成**。这台机器装了 nerdctl（containerd 生态），用法与 docker 命令兼容。

## 二、可复现的构建环境：Dockerfile

服务器上实际用的构建镜像等价于下面的 Dockerfile（gcc 13 + cmake，一步到位）：

```dockerfile
# llamacpp-build: llama.cpp 可复现构建环境
# 用法: docker build -t llamacpp-build . （nerdctl 同理）
FROM gcc:13

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cmake git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
```

> 注意：官方 `gcc:13` 镜像自带 gcc 13.4 但**没有 cmake**，必须先装。装好后把容器 commit 成镜像，以后每次编译直接复用，不用重装。

## 三、编译流程

```bash
# 1. 拉取代码（depth 1 省时间）
git clone --depth 1 https://github.com/ggml-org/llama.cpp /data/llama.cpp

# 2. 起一个常驻构建容器（--network host 的原因见踩坑 #1）
nerdctl run -d --name buildenv --network host -v /data:/data gcc:13 sleep infinity

# 3. 容器内装 cmake
nerdctl exec buildenv bash -c "apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake"

# 4. 配置 + 编译（8 核并行，约 5-15 分钟）
nerdctl exec buildenv bash -c "cd /data/llama.cpp && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j8"

# 5. 把带 cmake 的环境固化成镜像，下次直接复用
nerdctl commit buildenv llamacpp-build:latest
```

也可以一步到位（等价于上面 2-4 步）：

```bash
nerdctl run --rm --network host -v /data:/data -w /data/llama.cpp \
  llamacpp-build bash -c "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8"
```

产物落在挂载目录 `/data/llama.cpp/build/bin/`：llama-cli、llama-server、llama-bench、llama-quantize 等全套工具和共享库。

## 四、踩坑记录

### 坑 1：内核 3.10 没有 `ip_unprivileged_port_start`，nerdctl 起容器必炸

```
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: error during container init:
open sysctl net.ipv4.ip_unprivileged_port_start file:
openat /proc/sys/net/ipv4/ip_unprivileged_port_start: no such file or directory
```

**原因**：`net.ipv4.ip_unprivileged_port_start` 是内核 4.11 才引入的 sysctl，CentOS 7 内核 3.10 根本没有这个文件。而 nerdctl 2.3.5 默认会给每个非 host 网络的容器注入该 sysctl（源码 `withDefaultUnprivilegedPortSysctl`，为了容器内能绑定 1024 以下端口），runc 初始化时写入失败，整个容器起不来。

**解法**：容器加 `--network host`。源码逻辑是 host 网络直接跳过注入。编译场景不需要端口映射，这是最干净的绕法：

```bash
nerdctl run --network host ...   # 加这个参数即可
```

### 坑 2：--rm 一次性容器，装的 cmake 每次都会丢

第一次用 `nerdctl run --rm` 编译，发现 cmake 装完、容器一退出就没了。解法：常驻容器（`sleep infinity`）+ `nerdctl commit` 固化镜像，见上面的流程。

### 坑 3：新版 llama-cli 生成完不退出

新版 llama-cli 默认进入交互对话模式，`-p` 生成完会停在 `>` 提示符等输入，CI 脚本里直接卡死。用 `-st`（single-turn）让它在单轮生成后自动退出：

```bash
llama-cli -st -m model.gguf -p "你好" -n 100 < /dev/null
```

### 坑 4：宿主机不能直跑容器产物

容器里编出来的二进制依赖 Debian 的 glibc 2.36 和 OpenSSL 3，CentOS 7 只有 glibc 2.17 / OpenSSL 1.0.2，直跑报 `libssl.so.3: cannot open shared object file`。**跑 llama 也要在容器里**，用 `nerdctl exec buildenv 二进制路径` 或直接起 llama-server 容器。

## 五、验证流程（四层证据）

编译成功 ≠ 能用，按层验证：

**① 编译日志**：确认 `[100%] Built target llama-cli/llama-app/test-chat`

**② 二进制可执行**：

```bash
$ llama-cli --version
version: 0.3.0-dev (build 1, commit d7a2074)
built with GNU 13.4.0 for Linux x86_64
```

**③ 真实推理**（Qwen2.5-1.5B-Instruct Q4_K_M，1.1 GB）：

```text
> 用一句话解释什么是量子纠缠
量子纠缠是一种量子现象，其中两个或多个粒子会相互关联，使得它们的状态在空间上相互依存。

[ Prompt: 113.2 t/s | Generation: 28.3 t/s ]
```

**④ HTTP 服务全链路**（llama-server + OpenAI 兼容接口）：

```bash
$ curl http://127.0.0.1:8080/health
{"status":"ok"}

$ curl http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"1+1=?"}],"max_tokens":32}'
# 返回标准 chat.completion JSON: "1 + 1 = 2"，usage 正常统计 token
```

性能参考（8 vCPU 纯 CPU）：SmolLM2-135M 约 174 t/s 生成，Qwen2.5-1.5B Q4 约 28 t/s 生成。要更快就换小模型，要更强内存足够上 8B。

## 六、部署：常驻 llama-server

```bash
nerdctl run -d --name llama-server --network host -v /data:/data \
  llamacpp-build /data/llama.cpp/build/bin/llama-server \
  -m /data/models/qwen2.5-1.5b-instruct-q4_k_m.gguf -c 8192 --port 8080
```

`--network host` 模式下，宿主机 8080 端口直接可用，客户端直接请求 `http://服务器地址:8080/v1/chat/completions` 即可，任何 OpenAI SDK 都能对接。

## 总结

老系统上跑现代 LLM 推理栈，核心思路就一句话：**别跟宿主机工具链死磕，容器化隔离一切**。CentOS 7 上 nerdctl 的 sysctl 内核坑、glibc 兼容坑，都可以用 `--network host` + 容器内运行统一绕开。可复现的关键是把这个环境固化成 Dockerfile 描述的镜像（本文第二节），一劳永逸。
