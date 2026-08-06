---
slug: /blog/2026/08/06/nerdctl-docker-shim
title: 没有 docker daemon 的节点，怎么让 docker 命令照常工作？
date: 2026-08-06
draft: false
tags: [kubernetes, nerdctl, containerd, docker, devops]
categories: ["Tech"]
description: "K8s 节点只有 containerd + nerdctl、没有 docker daemon，但脚本和习惯都离不开 docker 命令。一个 60 行 bash shim 搞定：docker→nerdctl 转发、k8s.io 命名空间切换、compose/buildx 映射，以及一个 CentOS 7 bash 4.2 的隐蔽坑。"
---

KubeKey 搭的 k8s 集群，节点上装的是 **containerd + nerdctl**，没有 docker daemon。平时操作没问题，但一旦要跑别人的脚本、CI 或者凭肌肉记忆敲 `docker` 命令时就傻眼了——`docker: command not found`。

这篇记录我写的一个 60 行 bash shim：把 `docker` 伪装成 nerdctl 的转发器，以及部署过程中踩到的一个 **CentOS 7 专属的隐蔽坑**。

{/* truncate */}

## 一、为什么需要 shim

两种方案对比：

| 方案 | 优点 | 缺点 |
|---|---|---|
| 装完整 docker daemon | 完全兼容 | 与 containerd 抢资源、双运行时、kubelet 不认 docker 的容器 |
| **docker→nerdctl shim** | 零依赖、纯转发、不动运行时 | 少量命令（swarm/plugin）不支持 |

k8s 节点上装 dockerd 是反模式——kubelet 用的是 containerd socket，docker 起容器跟 k8s 完全是两套命名空间视图。而 nerdctl 本身就是 containerd 的"docker 兼容 CLI"，命令参数 90% 对齐 docker。所以缺的只是一个壳：让 `docker` 这个命令名存在，把参数原样转发给 nerdctl。

## 二、核心设计

```bash
# 命名空间参数：k8s 集群容器在 k8s.io，用户容器在 default
NS_ARGS=()
if [[ -n "${DOCKER_NAMESPACE:-}" ]]; then
    NS_ARGS=(-n "$DOCKER_NAMESPACE")
fi

cmd="${1:-}"
shift || true

case "$cmd" in
    swarm|plugin|builder)   # nerdctl 无对应，明确报错
        echo "docker-shim: '$cmd' 不支持" >&2; exit 1 ;;
    compose)                # docker compose -> nerdctl compose
        exec "$NERDCTL_BIN" compose "$@" ;;
    buildx)                 # docker buildx build -> nerdctl build
        exec "$NERDCTL_BIN" "${NS_ARGS[@]}" build "$@" ;;
    *)
        exec "$NERDCTL_BIN" "${NS_ARGS[@]}" "$cmd" "$@" ;;
esac
```

三个关键决策：

**1. 命名空间用环境变量注入**

nerdctl 有命名空间概念：集群容器在 `k8s.io`，手动跑的容器在 `default`。docker 没有这个概念，所以 shim 里用 `DOCKER_NAMESPACE` 环境变量控制，默认 `default`，需要看集群容器时：

```bash
export DOCKER_NAMESPACE=k8s.io
docker ps          # 列出 k8s 集群的容器
docker images      # 列出集群镜像（165 个）
```

**2. 命令映射表**

- `docker compose` → `nerdctl compose`（v2.3.5 自带 Compose v2）
- `docker buildx build` → `nerdctl build`（走 buildkitd）
- `docker swarm/plugin/builder/system` → 明确报"不支持"，而不是把错误吞掉

**3. 不支持的命令要"响亮的失败"**

shim 最忌讳静默吞错。swarm 这类 nerdctl 没有的命令，直接 `exit 1` 并打清楚提示，让脚本作者知道自己依赖了不存在的功能，而不是在半夜被玄学错误坑。

## 三、那个隐蔽的坑：bash 4.2 + set -u

第一版脚本我写了 `set -u`（未定义变量报错，好习惯），结果部署上去：

```text
[root@VM-0-14-centos ~]# docker
/usr/local/bin/docker: line 74: NS_ARGS[@]: unbound variable
```

`NS_ARGS` 明明在脚本开头初始化成了空数组 `NS_ARGS=()`，怎么会 unbound？

**根因**：CentOS 7 自带 bash **4.2**。bash 4.4 之前有个著名 bug——`set -u` 下，空数组的 `"${arr[@]}"` 展开会报 unbound variable。网上流传的 workaround `${arr[@]+"${arr[@]}"}` 在 bash 4.2 下**同样无效**（该修复 4.4 才合入）。

```bash
# 看起来没问题，bash 4.2 下照样炸
set -u
arr=()
echo "${arr[@]+"${arr[@]}"}"   # bash 4.2: unbound variable
```

**修法**：shim 的本质就是 exec 转发，用 `set -u` 收益极小，直接降级为 `set -o pipefail`。空数组展开在无 `set -u` 时天然安全。

这个坑提醒我：写跨机器部署的脚本，**永远要按目标机器最老的 bash 版本验证**，不能拿自己开发机的 bash 5.x 想当然。

## 四、部署与验证

```bash
# 1. 脚本传到节点
install -m 0755 docker-shim.sh /usr/local/bin/docker

# 2. 验证矩阵
docker                              # nerdctl help
docker ps                           # default 命名空间，无报错
DOCKER_NAMESPACE=k8s.io docker images   # 165 个集群镜像
docker compose version              # nerdctl Compose v2.3.5
docker buildx build --help          # 映射到 nerdctl build
docker swarm init                   # 明确报"不支持"
```

全部通过。之后 `docker login registry.d7kj.com` 这类操作在 worker 上也能直接用了。

## 五、小结

- 节点只有 nerdctl 时，一个 60 行 shim 就能让 docker 生态的命令全部可用，不动运行时、零依赖
- 命名空间差异用环境变量桥接，`k8s.io` 和 `default` 一键切换
- 不支持的子命令要响亮失败，不要静默
- 教训：跨机器脚本按最老 bash 验证，`set -u` + 空数组在 bash 4.2 是雷区

完整脚本已放进我的 Hermes skill，以后给新节点装就是一条命令的事。
