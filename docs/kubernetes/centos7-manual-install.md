# CentOS 7 手动安装 Kubernetes v1.31.x + containerd

> KubeKey v4.x 在 CentOS 7（kernel 3.10）上有多个已知 bug。本文档记录经过验证的手动安装方案，作为 KubeKey 不可用时的备选。

---

## 1. 环境概览

| 项目 | 值 |
|------|-----|
| OS | CentOS 7.9 (kernel 3.10.0-1160) |
| K8s | v1.31.x |
| CRI | containerd 1.7.13 |
| CNI | Weave Net 2.8.1 |
| kube-proxy | iptables 模式 |

### 节点规划

| 角色 | 内网 IP | 公网 IP | 主机名 |
|------|---------|---------|--------|
| control-plane | 172.26.16.15 | 43.130.14.242 | k8s-master01 |
| worker | 172.26.0.14 | - | vm-0-14-centos |

---

## 2. KubeKey 已知问题速查

如果坚持使用 KubeKey v4.x 自动安装，CentOS 7 上会遇到以下问题。以下解决方案已在本环境实测通过。

### 问题 1：`systemctl --value` 报错

```text
Error: task [Defaults | Get kubelet.service LoadState] run failed:
systemctl: unrecognized option '--value'
```

**根因**：CentOS 7 的 systemd 219 不支持 `systemctl show --value`，KubeKey 的 playbook 在 pre-check 阶段使用了此参数。

**解决**：替换 `/usr/bin/systemctl` 为 wrapper：

```bash
cp /usr/bin/systemctl /usr/bin/systemctl.real
cat > /usr/bin/systemctl <<'WRAP'
#!/bin/bash
if [[ "$@" == *"--value"* ]]; then
  /usr/bin/systemctl.real $(echo "$@" | sed 's/--value //g') | awk -F= '{print $2}'
else
  /usr/bin/systemctl.real "$@"
fi
WRAP
chmod +x /usr/bin/systemctl
```

### 问题 2：内核版本检查不通过

```text
The kernel version "3.10.0-1160" is too old. Minimum required version: 4.9.17.
```

**根因**：KubeKey v4.x 对所有 K8s 版本统一要求内核 >= 4.9.17。

**解决**：替换 `/usr/bin/uname` 为 wrapper，让 pre-check 看到假内核版本：

```bash
cp /usr/bin/uname /usr/bin/uname.real
cat > /usr/bin/uname <<'WRAP'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "-r" ]; then
    echo "5.4.278-1.el7.elrepo.x86_64"
    exit 0
  fi
done
exec /usr/bin/uname.real "$@"
WRAP
chmod +x /usr/bin/uname
```

### 问题 3：`init_kubernetes_node` nil pointer

```text
error calling index: index of nil pointer
```

**根因**：KubeKey v4.x 的 Go 模板在部分场景下无法正确设置 `init_kubernetes_node` 变量。

**解决**：放弃 KubeKey，改用手动 `kubeadm init`。

### 问题 4：Docker 二进制缺失

```text
stat /root/kubekey/kubekey/docker/25.0.5/amd64/docker-25.0.5.tgz: no such file
```

**根因**：即使配置了 `container_manager: containerd`，KubeKey 仍尝试部署 Docker。

**解决**：手动下载 Docker 二进制放到缓存路径，或使用空文件占位。

```bash
mkdir -p ~/kubekey/kubekey/docker/25.0.5/amd64/
curl -Lo ~/kubekey/kubekey/docker/25.0.5/amd64/docker-25.0.5.tgz \
  https://download.docker.com/linux/static/stable/x86_64/docker-25.0.5.tgz
```

---

## 3. Master 节点安装

### 3.1 通用初始化

```bash
# 关 swap
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

# 内核参数
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
modprobe br_netfilter && sysctl --system

# conntrack
yum install -y conntrack
```

### 3.2 安装 containerd 1.7.13

```bash
# 下载二进制
cd /tmp
curl -LO https://github.com/containerd/containerd/releases/download/v1.7.13/containerd-1.7.13-linux-amd64.tar.gz
tar xzf containerd-1.7.13-linux-amd64.tar.gz -C /usr/local/

# 创建 containerd service
cat > /etc/systemd/system/containerd.service <<'SVC'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
SVC

# 配置
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's|sandbox_image = "registry.k8s.io/pause:3.9"|sandbox_image = "hub.kubesphere.com.cn/kubernetes/pause:3.10"|' /etc/containerd/config.toml

systemctl daemon-reload && systemctl enable containerd --now
```

### 3.3 安装 kubelet / kubeadm / kubectl

```bash
# 方式 A：官方 yum 源（CN 节点可能 403）
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=0
EOF

yum makecache && yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

# 方式 B：下载二进制（yum 源 403 时的备选）
# curl -LO https://dl.k8s.io/v1.31.0/kubernetes-node-linux-amd64.tar.gz
# tar xzf kubernetes-node-linux-amd64.tar.gz
# cp kubernetes/node/bin/{kubelet,kubeadm,kubectl} /usr/local/bin/

# kubelet drop-in 配置
mkdir -p /var/lib/kubelet /usr/lib/systemd/system/kubelet.service.d
cat > /var/lib/kubelet/kubeadm-flags.env <<'EOF'
KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

cat > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf <<'EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload && systemctl enable kubelet
```

### 3.4 初始化集群

```yaml
# /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 172.26.16.15   # 替换为你的内网 IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: k8s-master01               # 替换为你的主机名
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.14
controlPlaneEndpoint: 172.26.16.15:6443
apiServer:
  certSANs:
    - 127.0.0.1
    - 172.26.16.15    # 内网 IP
    - 43.130.14.242   # 公网 IP
    - lb.kubernetes.local
networking:
  podSubnet: 10.233.64.0/18
  serviceSubnet: 10.233.0.0/18
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

```bash
kubeadm init --config=/tmp/kubeadm-config.yaml --ignore-preflight-errors=SystemVerification
```

> **注意**：`--ignore-preflight-errors=SystemVerification` 用于绕过 kernel 3.10 的 kernel config 模块缺失检查。

### 3.5 部署后置组件

```bash
# 配置 kubectl
mkdir -p ~/.kube && cp /etc/kubernetes/super-admin.conf ~/.kube/config

# 补 kube-proxy（kubeadm init 超时中断时可能漏掉）
kubeadm init phase addon kube-proxy --config=/tmp/kubeadm-config.yaml

# 补 bootstrap-token + cluster-info ConfigMap
kubeadm init phase bootstrap-token --config=/tmp/kubeadm-config.yaml

# 安装 CNI
kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml

# 检查 CNI 配置残留（重要！）
rm -f /etc/cni/net.d/10-flannel.conflist
```

### 3.6 验证

```bash
kubectl get nodes -o wide
NAME           STATUS   ROLES           VERSION    INTERNAL-IP    CONTAINER-RUNTIME
k8s-master01   Ready    control-plane   v1.31.14   172.26.16.15   containerd://1.7.13
```

---

## 4. Worker 节点安装

### 4.1 初始化（同 master 3.1 节）

```bash
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
modprobe br_netfilter && sysctl --system
yum install -y conntrack
```

### 4.2 安装 containerd（版本与 master 一致）

```bash
# 从 master 拷贝二进制（推荐，确保版本一致）
ssh root@k8s-master01 \
  'tar czf - -C /usr/local/bin containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 ctr runc' \
  | tar xzf - -C /usr/local/bin

# 创建 service + 配置（同 master 3.2 节）

systemctl daemon-reload && systemctl enable containerd --now
```

### 4.3 安装 kubelet / kubeadm

```bash
# yum 源安装（同 master 3.3 节）
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=0
EOF

yum makecache && yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable kubelet
```

### 4.4 加入集群

在 master 上获取 join 命令：

```bash
kubeadm token create --print-join-command
```

在 worker 上执行：

```bash
kubeadm join 172.26.16.15:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --ignore-preflight-errors=SystemVerification
```

---

## 5. 常见问题

### 5.1 CoreDNS 一直 ContainerCreating

**原因**：CNI 配置文件冲突（多个 `.conflist` 文件并存）。

**解决**：
```bash
ls /etc/cni/net.d/   # 确认有旧 conflist
rm -f /etc/cni/net.d/10-flannel.conflist   # 删掉 flannel 残留
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

### 5.2 kubeadm join 卡在 preflight

**原因**：`cluster-info` ConfigMap 缺失（kubeadm init 中断导致）。

**解决**：
```bash
# 在 master 上执行
kubeadm init phase bootstrap-token --config=/tmp/kubeadm-config.yaml
```

### 5.3 kube-apiserver 无法启动（containerd RuntimeConfig）

```text
RuntimeConfig from runtime service failed: unknown method RuntimeConfig
```

**原因**：containerd 1.6.x 不实现 `RuntimeConfig` RPC，kubelet 预期升级到 1.7.x。

**解决**：将 worker 的 containerd 升级到 1.7.x。

### 5.4 Flannel/Weave 报 "ID cannot be empty"

**原因**：kube-proxy 未部署，Service IP 不可达，CNI 无法通过 API Server 注册节点。

**解决**：
```bash
kubeadm init phase addon kube-proxy --config=/tmp/kubeadm-config.yaml
```

---

## 6. 参考

- [KubeKey on CentOS 7](./kubekey-centos7.md) — KubeKey 自动安装方案
- [OpenKruiseGame 安装指南](./openkruise-game.md) — 集群就绪后的应用部署
