# Kubernetes 污点与容忍：避免普通 Pod 占用 GPU 节点

> GPU 节点很贵，别让跑 CPU 的 Pod 占了位置。

## 背景：为什么需要这个？

集群里 GPU 节点是稀缺资源 —— 一张 A100 每小时几美金，谁用谁心疼。但默认情况下，Kubernetes 调度器看到有空闲 GPU 节点就会往上丢 Pod，结果你的人工智能训练任务可能要排队等 —— 因为有个 sidecar 容器或日志收集 DaemonSet 占着那张卡没干活。

解决方案：**给 GPU 节点打污点（Taint），让只有明确声明容忍（Toleration）的 Pod 才能调度上去。**

## 污点（Taint）基础

污点有三要素：

```
key=value:Effect
```

Effect 有三种：

| Effect | 行为 |
|--------|------|
| `NoSchedule` | 没有对应 toleration 的 Pod **不会**被调度到该节点 |
| `PreferNoSchedule` | 尽量不调度，但如果没有其他可用节点，也会调度上去 |
| `NoExecute` | 没有 toleration 的 Pod 会被**驱逐**（已经在运行中的也会被赶走） |

## 实战：给 GPU 节点打污点

先给 GPU 节点加标签 + 污点：

```bash
# 给 GPU 节点打标签（方便后续管理）
kubectl label node gpu-node-1 accelerator=nvidia

# 打污点——只有声明了 toleration 的 Pod 才能调度
kubectl taint node gpu-node-1 nvidia.com/gpu=true:NoSchedule
```

Pod 没声明 toleration 时，调度器碰到这个节点直接跳过：

```
$ kubectl describe node gpu-node-1 | grep Taints
Taints:             nvidia.com/gpu=true:NoSchedule
```

现在跑一个普通 Pod 试试（没有 toleration）：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: innocent-busybox
spec:
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
```

它会一直 Pending，`kubectl describe pod` 能看到：

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  5s    default-scheduler   0/3 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true}
```

完美挡下。

## 容忍（Toleration）：谁可以上 GPU 节点？

需要 GPU 的工作负载在 Pod spec 里加 toleration：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-job
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  containers:
  - name: cuda
    image: nvidia/cuda:12.0-runtime
    command: ["nvidia-smi"]
  resources:
    limits:
      nvidia.com/gpu: 1
```

operator 支持两种：

- **Equal**：key + value 都匹配（最常用，精确控制）
- **Exists**：只看 key 是否存在，不看 value（宽松匹配）

Exists 写法更简洁，适合不想关心具体 value 的场景：

```yaml
tolerations:
- key: "nvidia.com/gpu"
  operator: "Exists"
  effect: "NoSchedule"
```

## 进阶模式

### 1. 多层污点 + 弹性容忍

混合资源类型的 GPU 节点可以用多层污点分层：

```bash
kubectl taint node a100-node-1 gpu-tier=a100:NoSchedule
kubectl taint node a100-node-1 reservation=spot:PreferNoSchedule
```

只有同时容忍 `gpu-tier=a100:NoSchedule` 的 Pod 能上去。而 `reservation=spot` 只是倾向性，没有容忍也能调度，但有容忍的 Pod 优先级更高。

### 2. NoExecute + tolerationSeconds 做优雅驱逐

```yaml
tolerations:
- key: "nvidia.com/gpu"
  operator: "Exists"
  effect: "NoExecute"
  tolerationSeconds: 300
```

这个 Pod 在 GPU 节点上只能待 5 分钟。适合**临时测试任务**，超时自动被驱离，节点资源回收给正式作业。

### 3. DaemonSet 如何绕过？

节点监控、日志采集等 DaemonSet 也要容忍，否则调不到 GPU 节点上。但大多数时候你**不希望** fluentd 在 GPU 节点上跑日志采集（浪费资源），所以可以给 DaemonSet 加 nodeSelector 或 affinity 锁定非 GPU 节点：

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: accelerator
          operator: NotIn
          values:
          - nvidia
```

如果**确实需要**（比如 GPU 监控），加容忍：

```yaml
tolerations:
- operator: "Exists"
```

operator 不写 key 时，容忍**所有污点**。谨慎使用 —— 副作用是你的 DaemonSet 可能会跑上 master 节点。

### 4. 自动给 Pod 注入 toleration

项目规模一大，人工给每个 GPU 负载加 toleration 容易漏。推荐用 Kyverno / OPA 做策略注入：

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-gpu-toleration
spec:
  rules:
  - name: add-toleration
    match:
      resources:
        kinds:
        - Pod
        selector:
          matchLabels:
            gpu: "true"
    mutate:
      patchStrategicMerge:
        spec:
          tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
```

## 最佳实践总结

| 场景 | 做法 |
|------|------|
| 纯 GPU 专用节点 | `nvidia.com/gpu=true:NoSchedule`，**不要用 Prefer** |
| 混合节点池 | 按 tier/卡型 做多层污点，配合 NodeAffinity 做亲和 |
| 临时任务 | `NoExecute` + `tolerationSeconds` |
| DaemonSet 管控 | 大部分 DaemonSet 加 NotIn nodeAffinity 跳过 GPU 节点 |
| 大规模集群 | 用 Kyverno 自动注入 toleration，别让人肉操作 |

## 踩坑记录

1. **先打污点再部署** —— 否则调度器已经在 GPU 节点上放了普通 Pod，你还得手动驱逐。
2. **NoExecute 会驱逐已有 Pod** —— 给生产节点打 NoExecute 前，确认上面跑的 Pod 都声明了 toleration，不然在线服务突然被干掉。
3. **!important** —— 装 Nvidia Device Plugin 后，GPU 资源还是"可请求"状态，污点才是真正的访问控制。两个一起用：
   - 污点控制 "谁可以上这个节点"
   - 资源限制控制 "谁可以拿 GPU 卡"

## 快速验证

```bash
# 打污点
kubectl taint node gpu-node-1 nvidia.com/gpu=true:NoSchedule

# 跑一个没有 toleration 的 Pod，确认 Pending
kubectl run test --image=busybox -- sleep 30
kubectl get pod test  # 应该是 Pending

# 跑一个有 toleration 的 Pod，确认 Running
kubectl run gpu-test --image=nvidia/cuda:12.0-runtime -- nvidia-smi \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]}}'
kubectl get pod gpu-test  # 应该是 Running
```
