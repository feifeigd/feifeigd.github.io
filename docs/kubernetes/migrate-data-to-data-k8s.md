# Kubernetes 数据目录迁移到 /data/k8s（软链接方案）

> 场景：K8s 相关动态数据（containerd、etcd、kubelet、Pod 日志）占用系统盘（/dev/vda1），需要迁移到独立数据盘 /data（/dev/vdb1）。本文以双节点集群（1 master + 1 worker，K8s v1.31.14 + containerd 1.7.13，CentOS 7）为例，记录软链接迁移方案。

## 适用场景

- 系统盘空间不足，数据盘（如 /data）空间充裕
- 希望 K8s 动态数据与系统分离，便于扩容/备份
- 不想改动 systemd 单元文件或 containerd 配置（软链接零侵入）

## 迁移对象

| 目录 | 内容 | 说明 |
|------|------|------|
| `/var/lib/containerd` | 容器镜像、快照、元数据 | 最大头（1~2G+，随镜像增长） |
| `/var/lib/etcd` | etcd 数据（仅 master） | 集群状态，必须谨慎 |
| `/var/lib/kubelet` | kubelet 数据（pod 卷、插件） | 量小但重要 |
| `/var/log/pods` | Pod 日志 | 量小，随业务增长 |

> **不迁移**：`/opt/cni`（CNI 插件，静态文件非动态数据）、`/etc/kubernetes`（静态配置）、`/run`（运行时状态，本就是内存/临时盘）。

## 迁移方案：软链接

将 `/var/lib/containerd` 等目录替换为指向 `/data/k8s/<name>` 的软链接。

**优点**：零配置侵入，containerd/kubelet/etcd 无需改配置或重启参数，回滚只需恢复目录。
**缺点**：重装系统后软链接失效（重建节点时需重新建链或改为改配置方案）。

## 执行步骤

> 顺序：**先迁移 worker 节点，再迁移 master**。master 是单点控制面，停服期间集群短暂不可用（几分钟），worker 迁移不影响控制面。

### 0. 前置检查

```bash
# 确认数据盘已挂载且空间充足
df -h / /data

# 查看各目录大小
du -sh /var/lib/containerd /var/lib/etcd /var/lib/kubelet /var/log/pods

# 确认 containerd root（默认 /var/lib/containerd）
containerd config dump | grep -E '^(\s*)root'
```

### 1. 排空节点（仅 worker，master 跳过）

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force
```

> **坑**：drain 可能卡在 Terminating pod 上，常见原因：
> - 残留 webhook 拦截删除（如 OpenKruise 的 `vpod.kb.io`）→ 删除对应 validating/mutatingwebhookconfiguration
> - 网络命名空间残留（`failed to remove netns ... device or resource busy`）→ `kubectl delete pod --force --grace-period=0`，重启 containerd 后自动清理

### 2. 停止服务

```bash
systemctl stop kubelet
systemctl stop containerd
```

### 3. 复制数据到 /data/k8s

```bash
mkdir -p /data/k8s/containerd /data/k8s/kubelet /data/k8s/log/pods   # master 额外: /data/k8s/etcd

rsync -a /var/lib/containerd/ /data/k8s/containerd/
rsync -a /var/lib/kubelet/   /data/k8s/kubelet/
rsync -a /var/log/pods/      /data/k8s/log/pods/
rsync -a /var/lib/etcd/      /data/k8s/etcd/        # 仅 master

# 核对大小一致
du -sh /var/lib/containerd /data/k8s/containerd
```

> 用 rsync 而非 mv：跨文件系统复制可校验，且保留权限/属主。

### 4. 建软链接

```bash
mv /var/lib/containerd /var/lib/containerd.old
mv /var/lib/kubelet    /var/lib/kubelet.old
mv /var/log/pods       /var/log/pods.old
mv /var/lib/etcd       /var/lib/etcd.old        # 仅 master

ln -s /data/k8s/containerd /var/lib/containerd
ln -s /data/k8s/kubelet    /var/lib/kubelet
ln -s /data/k8s/log/pods   /var/log/pods
ln -s /data/k8s/etcd       /var/lib/etcd         # 仅 master
```

### 5. 启动并验证

```bash
systemctl start containerd
systemctl start kubelet

# 服务状态
systemctl is-active kubelet containerd

# 节点就绪（在 master 上执行）
kubectl get nodes

# etcd 健康（仅 master）
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# 全部 Pod 健康
kubectl get pods -A | grep -vE 'Running|Completed'
```

### 6. 解除节点隔离（worker）

```bash
kubectl uncordon <node>
```

### 7. 清理旧目录

```bash
rm -rf /var/lib/containerd.old /var/lib/kubelet.old /var/log/pods.old /var/lib/etcd.old
```

> **坑**：kubelet 旧目录可能有残留挂载（`Device or resource busy`），先卸载再删：
> ```bash
> mount | grep -E 'kubelet.old|pods.old' | awk '{print $3}' | while read m; do umount -l "$m"; done
> rm -rf /var/lib/kubelet.old /var/log/pods.old
> ```

## 验证结果（实测 2026-07-31）

| 节点 | 迁移数据 | 结果 |
|------|----------|------|
| k8s-master01 | containerd 1.9G + etcd 197M + kubelet + logs | ✅ Ready，etcd healthy |
| vm-0-14-centos | containerd 1.4G + kubelet + logs | ✅ Ready |

- 系统盘使用 16G → 14G，后续数据增长全部落在 /data（197G 数据盘）
- 集群控制面、weave、Kruise、OKG 全部正常运行

## 回滚方案

```bash
systemctl stop kubelet containerd
rm /var/lib/containerd /var/lib/kubelet /var/log/pods   # 删软链接
mv /var/lib/containerd.old /var/lib/containerd
mv /var/lib/kubelet.old    /var/lib/kubelet
mv /var/log/pods.old       /var/log/pods
systemctl start containerd kubelet
```

## 相关文章

- [KubeKey 安装 K8s（CentOS 7，最高版本方案）](./kubekey-centos7.md)
- [CentOS 7 手动安装 K8s v1.31](./centos7-manual-install.md)
- [Kubernetes 安装踩坑记录](./setup-troubleshooting.md)
