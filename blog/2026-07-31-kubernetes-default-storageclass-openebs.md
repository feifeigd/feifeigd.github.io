---
slug: /blog/2026/07/31/kubernetes-default-storageclass-openebs
title: Kubernetes 默认 StorageClass — OpenEBS 安装
date: 2026-07-31
tags: [kubernetes, openebs, storage]
---

K8s 集群起来后第一个要配的就是**默认 StorageClass**。没有它，PVC 不会自动绑定 PV，有状态应用（数据库、缓存、日志）都跑不起来。

这篇文章记录在 CentOS 7 + containerd 集群上安装 OpenEBS 作为默认存储后端的过程。

## 为什么 OpenEBS

OpenEBS 是一个 CNCF 沙箱项目，核心优势：

* 轻量：不需要外部存储阵列，直接用节点的本地磁盘
* CSI 驱动：原生支持 `WaitForFirstConsumer` 延迟绑定
* 简单：一条 yaml 搞定，不依赖 Helm

## 安装

```bash
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml
```

这个 yaml 会创建：

* `openebs-hostpath` — 基于节点本地路径的存储类
* `openebs-device` — 基于块设备的存储类
* `openebs-localpv-provisioner` — CSI provisioner
* `openebs-ndm` — 节点磁盘管理器

## 设为默认

K8s 集群可以有多个 StorageClass，但只有一个标记为默认：

```bash
kubectl patch storageclass openebs-hostpath \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

验证：

```bash
kubectl get sc
# openebs-hostpath (default)   openebs.io/local   Delete   WaitForFirstConsumer   13s
```

看到 `(default)` 标记就对了。

## 验证 PVC 自动绑定

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc
# test-pvc   Bound   pvc-xxxx   1Gi   RWO   openebs-hostpath
```

## 注意事项

1. **WaitForFirstConsumer**：PV 延迟绑定到使用它的 Pod 所在节点，这是最优行为
2. **回收策略**：默认 `Delete`，PVC 删除后 PV 和本地数据也会被删除。如需保留数据，改 `Retain`
3. **本地存储限制**：节点宕机后 Pod 漂移，无法访问原节点的本地数据。生产建议配合分布式存储使用

## 参考

* [OpenEBS 官方文档](https://openebs.io/docs/)
* [Kubernetes StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
