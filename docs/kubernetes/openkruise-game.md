---
title: "OpenKruiseGame 安装与配置指南（Helm + CNCF 子项目）"
description: "基于 Helm 安装 OpenKruiseGame 游戏服管理套件，包含 Kruise 底层依赖安装、OKG 核心 CRD 部署、GameServerSet 示例与生产配置要点"
---

# OpenKruiseGame 安装与配置指南

> 目标：在已有的 Kubernetes 集群上安装 **OpenKruiseGame（OKG）** —— CNCF 孵化项目 OpenKruise 的游戏服管理子项目，用于云原生游戏服务器编排与生命周期管理。

## 前提条件

| 条件 | 要求 | 说明 |
|------|------|------|
| Kubernetes 版本 | ≥ 1.18 | 推荐 1.24+（已验证 v1.26 ~ v1.36） |
| Helm 版本 | ≥ 3.5 | 推荐 v3.18+ |
| 集群资源 | 预留 500m CPU / 256Mi 内存 | OKG Controller Manager 调度开销 |

如果你还没有 K8s 集群，请先参考[《KubeKey 安装 K8s（CentOS 7，最高版本方案）》](./kubekey-centos7.md)部署一套。

## 架构概览

OpenKruiseGame 由两层构成：

```
┌─────────────────────────────────────┐
│          OpenKruiseGame             │  ← 游戏服 CRD 层
│  GameServerSet / GameServer / ...   │     (当前版本 v1.1.0)
├─────────────────────────────────────┤
│           OpenKruise                │  ← 基础工作负载层
│  CloneSet / SidecarSet / ...        │     (当前版本 v1.8.0)
├─────────────────────────────────────┤
│           Kubernetes                │  ← 集群层
│  Deployment / StatefulSet / ...     │
└─────────────────────────────────────┘
```

**OKG 依赖 Kruise 运行**——Kruise 提供 CloneSet、SidecarSet 等底层工作负载扩展，OKG 在其上封装面向游戏服的 GameServerSet CRD。

---

## 第一步：安装 OpenKruise

添加 Helm 仓库并安装 Kruise（OKG 底层依赖）：

```bash
# 添加仓库（如未添加过）
helm repo add openkruise https://openkruise.github.io/charts/

# 更新仓库
helm repo update

# 安装 Kruise v1.8.0
helm install kruise openkruise/kruise --version 1.8.0 \
  --namespace kruise-system \
  --create-namespace
```

验证安装：

```bash
kubectl get pods -n kruise-system
# NAME                                         READY   STATUS
# kruise-controller-manager-xxxxxxxxxx-yyyyy   1/1     Running

kubectl get crd | grep kruise
# clonesets.apps.kruise.io
# sidecarsets.apps.kruise.io
# ...
```

> **版本说明**：Kruise v1.8.0 是 2026 年中的稳定版本。OpenKruiseGame v1.1.0 对 Kruise 版本的兼容范围参见 [OKG 官方文档](https://openkruise.io/en-US/docs/game/installation)。
---

## 第二步：安装 OpenKruiseGame

```bash
# 注意：OKG 的 chart 已并入 openkruise 主仓库，无需单独添加仓库
# （旧的独立仓库 https://openkruise.github.io/openkruisegame/ 已废弃，返回 404）

# 更新仓库（openkruise 仓库已包含 kruise-game chart）
helm repo update openkruise

# 安装 OKG v1.1.0
helm install kruise-game openkruise/kruise-game --version 1.1.0 \
  --namespace kruise-game-system \
  --create-namespace
```

验证安装：

```bash
kubectl get pods -n kruise-game-system
# NAME                                                 READY   STATUS
# kruise-game-controller-manager-xxxxxxxxxx-yyyyyy     1/1     Running

kubectl get crd | grep game
# gameservers.game.kruise.io
# gameserversets.game.kruise.io
```

> **注意**：如果你的 KubeKey 部署文档中现有命令使用 `--version 0.22.0`，那是旧版。建议升级到 v1.1.0，CRD 和 API 有显著演进。

---

## 第三步：部署第一个 GameServerSet

创建一个最简单的 GameServerSet（Nginx 模拟游戏服进程）：

```yaml
# gameserverset-demo.yaml
apiVersion: game.kruise.io/v1alpha1
kind: GameServerSet
metadata:
  name: gss-demo
  namespace: default
spec:
  replicas: 3
  gameServerTemplate:
    spec:
      containers:
        - name: gameserver
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: game-port
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

```bash
kubectl apply -f gameserverset-demo.yaml
```

验证 GameServer 状态：

```bash
kubectl get gss
# NAME       DESIRED   CURRENT   UPDATED   READY   AGE
# gss-demo   3         3         3          3       30s

kubectl get gs
# NAME             STATE      OPSSTATE   AGE
# gss-demo-0       Ready      None       30s
# gss-demo-1       Ready      None       30s
# gss-demo-2       Ready      None       30s
```

GS（GameServer）的核心状态字段：

| 状态 | 含义 |
|------|------|
| `Ready` | 游戏服就绪，可分配玩家 |
| `NotReady` | Pod 未就绪或探测失败 |
| `WaitToBeDeleted` | 等待优雅删除（无玩家时再清理） |
| `Maintaining` | 运维模式（主动设置，跳过自动变更） |

---

## 第四步：生产配置要点

### 4.1 资源配额与调度

GameServerSet 支持通过 `spec.schedule` 字段控制调度策略，推荐配置：

```yaml
spec:
  schedule:
    # 优先分散调度到不同节点
    podDistribution:
      - type: SpreadByPods
        policy:
          - key: kubernetes.io/hostname
    # 设置 Pod 间亲和/反亲和
    tolerations:
      - key: "game-server"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
```

### 4.2 网络模式

对于需要固定 IP 或固定端口的游戏服，OKG 支持 Network 插件化接入：

```yaml
spec:
  network:
    networkType: "hostPort"
    networkConf:
      - name: "GamePorts"
        value: '[{"name":"game","port":7777,"protocol":"UDP","fixed":true}]'
```

常见网络方案：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `hostPort` | 宿主机端口映射 | 小规模、测试环境 |
| `internal` | 仅 ClusterIP | 内网直连 |
| `alibabacloud` | 阿里云 ENI 直挂 | 阿里云生产 |
| `tencentcloud` | 腾讯云 ENI | 腾讯云生产 |
| `custom` | 自定义 CNI 插件 | 私有云/自建 |

### 4.3 热更新配置（Hot Update）

OKG 核心价值之一是热更新——不重建 Pod 的情况下替换容器镜像：

```yaml
spec:
  updateStrategy:
    type: InPlaceIfPossible
    inPlaceUpdateStrategy:
      gracePeriodSeconds: 30
```

热更新依赖 Kruise 的 `InPlaceIfPossible` 能力，需确保容器启动命令支持 **reload 信号**（如 `SIGHUP` 或自定义健康检查）。

### 4.4 GameServer 运维状态管理

手动控制单个 GameServer 的运维状态：

```bash
# 标记某台游戏服为维护模式（控制器将跳过其自动变更）
kubectl patch gs gss-demo-1 --type='merge' -p '{"spec":{"opsState":"Maintaining"}}'

# 恢复正常
kubectl patch gs gss-demo-1 --type='merge' -p '{"spec":{"opsState":"None"}}'

# 标记为等待删除（仅无玩家时才会被删除）
kubectl patch gs gss-demo-1 --type='merge' -p '{"spec":{"opsState":"WaitToBeDeleted"}}'
```

OPS 状态变更不影响 Pod 生命周期，只影响控制器对 Pod 的编排决策——这是 OKG 区别于原生 Deployment 的关键能力。

---

## 升级与运维

### 升级 OKG

```bash
helm upgrade kruise-game openkruise/kruise-game --version 1.1.0 --namespace kruise-game-system
```

### 升级 Kruise

```bash
helm upgrade kruise openkruise/kruise --version 1.8.0
```

### 卸载

```bash
# 先删除所有 GameServerSet（清理 GS 资源）
kubectl delete gss --all --all-namespaces

# 卸载 OKG
helm uninstall kruise-game -n kruise-game-system

# 卸载 Kruise
helm uninstall kruise -n kruise-system
```

---

## 常见问题

### Q：安装后 CRD 未创建

检查 Helm 是否正确拉取 chart：

```bash
helm list -A
helm status kruise-game -n kruise-game-system
```

### Q：安装报 `namespaces "... already exists"` 且 release 显示 failed

这是 **Helm 3.13 的已知竞态**：`--create-namespace` 创建了 namespace，但随后的资源创建又误判它已存在。实际资源（Deployment、CRD）通常已创建成功。

```bash
# 确认资源实际已就绪
kubectl get pods -n kruise-game-system
kubectl get crd | grep game

# 刷新 release 状态为 deployed（无需重装）
helm upgrade kruise-game openkruise/kruise-game --version 1.1.0 --namespace kruise-game-system
```

### Q：安装后 Kruise controller 一直 CrashLoopBackOff（webhook 引导死锁）

首次安装时 Kruise 的 webhook（`mpod.kb.io`）会拦截**所有** Pod 创建，包括它自己的 controller —— 形成死锁：Pod 起不来 → webhook service 无 endpoint → 所有 Pod 创建失败。事件报错形如：

```
Error creating: ... failed calling webhook "mpod.kb.io": Post "https://kruise-webhook-service.kruise-system.svc:443/mutate-pod...": connection refused
```

解法（分两步）：

```bash
# 1. 临时删掉 webhook 配置，放行 controller Pod 创建
kubectl delete validatingwebhookconfiguration kruise-validating-webhook-configuration
kubectl delete mutatingwebhookconfiguration kruise-mutating-webhook-configuration

# 等待 controller 起来（kubectl get pods -n kruise-system 全部 Running）

# 2. 用 helm upgrade 重建 webhook 配置（此时 service 已有 endpoint，不再死锁）
helm upgrade kruise openkruise/kruise --version 1.8.0 --namespace kruise-system
```

> 注意：Kruise 的 webhook controller 只**更新**配置、不**创建**，所以删掉的配置必须靠 helm 重新渲染，不能只等 controller 自愈。

### Q：GameServer 始终 NotReady

常见原因：
1. **Pod 未完全启动**：`kubectl describe gs <name>` 查看事件
2. **网络插件未配置**：未指定 `network.networkType` 时默认为 `internal`，需要进行端口探测
3. **Kruise 版本不兼容**：OKG v1.1.0 推荐 Kruise ≥ 1.8.0

### Q：热更新不生效

确认：
- Kruise 已安装且版本正确
- GameServerSet 的 `updateStrategy.type` 为 `InPlaceIfPossible`
- 镜像 tag 已更新且 pullPolicy 允许拉取

---

## 参考链接

- [OpenKruiseGame 官方文档](https://openkruise.io/en-US/docs/game/introduction)
- [GitHub: openkruise/kruise-game](https://github.com/openkruise/kruise-game)
- [GameServerSet API 参考](https://openkruise.io/en-US/docs/game/manual/gameserverset)
- [KubeKey 安装 K8s 指南](./kubekey-centos7.md)
