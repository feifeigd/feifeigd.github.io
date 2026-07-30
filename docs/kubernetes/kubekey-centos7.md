# 使用 KubeKey 在 CentOS 7 上部署 Kubernetes（最高版本选择方案）

> 目标：部署一套可用于生产环境、各组件版本最高的 Kubernetes 集群，后续安装 **OpenKruiseGame**。

---

## 1. 环境概览

| 项目 | 值 |
|------|-----|
| OS | CentOS 7.9 （kernel 3.10.0-xxx） |
| KubeKey | v4.0.5 |
| K8s | v1.34.x（**需升级内核**） / v1.27.x（兼容原内核） |
| CRI | containerd |
| CNI | Calico v3.31 |
| etcd | v3.6.5 |
| CoreDNS | v1.12.1 |
| Helm | v3.18.5 |
| Kruise | v1.8.0（含 OKG v1.1.0） |

### 为什么需要关注内核版本？

CentOS 7 默认内核 3.10.0 缺少 Kubernetes 依赖的部分内核特性（如 `tcp_cork` 优化、cgroup v2 支持等）。**K8s v1.28+ 官方建议内核 >= 4.x**，生产环境建议升级到 **5.4+**。

| 场景 | K8s 版本 | 内核要求 | 操作量 |
|------|----------|---------|--------|
| 保守 | v1.27.x | 3.10 即可（需确认 containerd 兼容） | 少 |
| 最优（推荐） | v1.34.x | 升级到 5.4+ | 中等 |
| 激进 | v1.34.x + Cilium eBPF | 5.10+ | 较多 |

---

## 2. 环境准备 — CentOS 7 基础配置

以下步骤在所有节点上执行（master + worker）。

### 2.1 处理 CentOS 7 EOL（End of Life）仓库问题

CentOS 7 已于 2024-06-30 停止维护，原有 `baseurl` 失效，需切换到 **vault.centos.org**：

```bash
# 切换 base 仓库到 vault 镜像
sudo sed -i 's|mirror.centos.org/centos|vault.centos.org/centos|g' \
  /etc/yum.repos.d/CentOS-*.repo
sudo sed -i 's|#baseurl=|baseurl=|g' \
  /etc/yum.repos.d/CentOS-*.repo
sudo sed -i 's|mirrorlist=|#mirrorlist=|g' \
  /etc/yum.repos.d/CentOS-*.repo

# 或直接使用阿里云 vault 镜像（国内推荐）
sudo sed -e 's|^mirrorlist=|#mirrorlist=|g' \
         -e 's|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009|g' \
         -i.bak /etc/yum.repos.d/CentOS-*.repo

# 安装基础工具
sudo yum install -y yum-utils epel-release
sudo yum makecache
```

### 2.2 升级内核（推荐：K8s v1.34 必需）

通过 ELRepo 安装 **kernel-lt**（长期支持版 5.4+）或 **kernel-ml**（主线最新）：

```bash
# 导入 ELRepo GPG 并启用仓库
sudo rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
sudo rpm -Uvh https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm

# 安装 kernel-lt（推荐，5.4 LTS，稳定）
sudo yum --enablerepo=elrepo-kernel install -y kernel-lt

# 或安装 kernel-ml（最新主线，风险略高）
# sudo yum --enablerepo=elrepo-kernel install -y kernel-ml

# 查看已安装的内核
rpm -qa | grep kernel

# 设置新内核为默认启动项
sudo grub2-set-default 0
# 确认当前默认启动项
sudo grub2-editenv list

# 重启使用新内核
sudo reboot
```

**重启后验证：**

```bash
uname -r
# 期望输出：5.4.xxx-xxx.el7.x86_64（或更新的主线版本）
```

### 2.3 通用系统优化（无论是否升级内核都需要）

```bash
# 1. 禁用 SWAP（K8s 硬性要求）
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 2. 禁用 SELinux（或设为 permissive）
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# 3. 关闭防火墙（或开放 K8s 所需端口）
sudo systemctl stop firewalld
sudo systemctl disable firewalld

# 4. 启用 IP 转发和 bridge netfilter
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl --system

# 5. 加载内核模块
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# 6. 安装 K8s 依赖工具
sudo yum install -y socat conntrack-tools ipset ebtables chrony ipvsadm

# 7. 时间同步
sudo systemctl enable --now chronyd
sudo chronyc sources -v
```

### 2.4 设置主机名和 /etc/hosts

```bash
# master 节点
sudo hostnamectl set-hostname k8s-master01
# worker 节点
# sudo hostnamectl set-hostname k8s-worker01

# 统一写入 /etc/hosts（所有节点都要）
cat <<'EOF' | sudo tee -a /etc/hosts
# K8s cluster nodes
<master-ip>  k8s-master01
<worker01-ip> k8s-worker01
<worker02-ip> k8s-worker02

# 若使用 local HA 模式，还需在此加入域名解析
# <master-ip>  lb.kubesphere.local
EOF
```

### 2.5 验证系统兼容性

```bash
# 检查内核版本（>= 3.10 可跑 K8s v1.27，>= 5.4 推荐跑 K8s v1.34）
uname -r

# 验证内核模块已加载
lsmod | grep -E '^overlay|^br_netfilter'
# 应看到 overlay 和 br_netfilter

# 验证 IP 转发已启用
sysctl net.ipv4.ip_forward
# 应返回 net.ipv4.ip_forward = 1
```

---

## 3. 安装 KubeKey

在所有**控制平面节点**上执行（KubeKey 只需要一个执行起点，它会通过 SSH 操作所有节点）。

### 3.1 下载 KubeKey（国内推荐设置 CN Zone）

```bash
# 如果 GitHub / GoogleAPIs 访问受限，设置国内下载源
export KKZONE=cn

# 下载最新版 KubeKey（只下载 kk 二进制，跳过 Web Installer 和离线包）
curl -sfL https://get-kk.kubesphere.io | SKIP_WEB_INSTALLER=true SKIP_PACKAGE=true sh -

# 验证
./kk version
# 输出应包含 >= v4.0.5

# 移动到 PATH
sudo mv kk /usr/local/bin/
kk version
```

### 3.2 生成集群配置文件

```bash
# 生成节点清单
kk create inventory -o .

# 生成安装配置（指定 K8s 版本）
# === 保守方案（CentOS 7 原内核）===
kk create config --with-kubernetes v1.27.16 -o .

# === 推荐方案（已升级内核）===
kk create config --with-kubernetes v1.34.3 -o .
```

执行后会生成两个文件：

```
inventory.yaml          # 节点清单
config-v1.34.3.yaml    # 集群配置（版本号视所选版本而定）
```

---

## 4. 配置 inventory.yaml（节点清单）

编辑 `inventory.yaml`，**按实际环境填写**节点信息：

```yaml
apiVersion: kubekey.kubesphere.io/v1
kind: Inventory
metadata:
  name: default
spec:
  hosts:
    k8s-master01:
      connector:
        type: ssh
        host: 192.168.1.10         # 替换为实际 IP
        port: 22
        user: root
        password: YourPassword      # 或使用 private_key
      internal_ipv4: 192.168.1.10
    k8s-worker01:
      connector:
        type: ssh
        host: 192.168.1.11
        port: 22
        user: root
        password: YourPassword
      internal_ipv4: 192.168.1.11
    k8s-worker02:
      connector:
        type: ssh
        host: 192.168.1.12
        port: 22
        user: root
        password: YourPassword
      internal_ipv4: 192.168.1.12
  groups:
    k8s_cluster:
      groups:
        - kube_control_plane
        - kube_worker
    kube_control_plane:
      hosts:
        - k8s-master01
        # - k8s-master02    # 多 master 高可用时启用
        # - k8s-master03
    kube_worker:
      hosts:
        - k8s-worker01
        - k8s-worker02
    etcd:
      hosts:
        - k8s-master01
    image_registry:
      hosts:
        - k8s-master01
        # 如需私有镜像仓库，在对应节点部署
```

> **注意**：`internal_ipv4` 需填写集群内部通信 IP（通常是内网 IP）。SSH 连接支持 `password` 或 `private_key` 两种认证方式。

---

## 5. 配置 config.yaml（组件版本最高方案）

编辑 `config-v1.34.3.yaml`，**这是选择最高版本的核心步骤**。KubeKey v4.0.5 的 v1.34 默认配置已包含当下最高版本，但我们可以手动确认和覆盖：

```yaml
apiVersion: kubekey.kubesphere.io/v1
kind: Config
spec:
  zone: "cn"                       # 国内节点建议设为 cn

  kubernetes:
    kube_version: v1.34.3          # ← 当前最新稳定版
    helm_version: v3.18.5          # ← Helm 最新
    sandbox_image:
      tag: "3.10.1"                # ← pause 镜像最新
    control_plane_endpoint:
      type: local                  # 单节点 or kube-vip（高可用）+ keepalived
    # type: kube-vip               # 多 master 高可用方案
    # kube_vip:
    #   image:
    #     tag: v0.7.2              # kube-vip 最新

  etcd:
    etcd_version: v3.6.5           # ← etcd 最新（K8s v1.34.2+ 推荐）

  cri:
    container_manager: containerd  # 首选 containerd
    # containerd 版本由 KubeKey 自动选配，通常为 v1.7.x 系列
    # 如需显式指定：
    # containerd_version: v1.7.25  # 含 runc v1.2.x
    # runc_version: v1.2.5

  cni:
    type: calico                    # 可改为 cilium（需内核 >= 5.8）
    calico_version: v3.31.3        # ← Calico 最新
    # cilium_version: 1.18.5       # 若选 Cilium

  storage_class:
    local:
      enabled: true
      default: true
    localpv_provisioner_version: 4.4.0   # ← OpenEBS LocalPV 最新

  dns:
    coredns:
      image:
        tag: v1.12.1               # ← CoreDNS 最新（K8s v1.34 匹配）
    nodelocaldns:
      enabled: true
      image:
        tag: 1.26.4               # ← NodeLocalDNS 最新
```

### Cilium CNI 方案（可选，需内核 >= 5.8）

如果已从 ELRepo 安装 **kernel-ml**（主线内核）得到 5.8+ 内核，可以启用 **Cilium** 以获得 eBPF 的高性能网络：

```yaml
spec:
  cni:
    type: cilium
    cilium_version: 1.18.5          # ← Cilium 最新
```

> Cilium 的 eBPF 数据面需要内核 >= 5.8（部分功能需 5.10+）。CentOS 7 用 kernel-ml 可以达到。

---

## 6. 执行安装

### 6.1 一键安装

```bash
# 如果 kk 在当前目录
./kk create cluster -i inventory.yaml -c config-v1.34.3.yaml

# 如果 kk 在 PATH 中
kk create cluster -i inventory.yaml -c config-v1.34.3.yaml
```

安装过程将自动完成：

1. ✅ **系统依赖检查** — socat、conntrack、ipset 等
2. ✅ **Docker 移除**（如有冲突则清理）
3. ✅ **containerd 安装与配置**
4. ✅ **etcd 集群部署**
5. ✅ **K8s 控制平面初始化**（kubeadm 驱动）
6. ✅ **CNI 网络插件安装**（Calico / Cilium 等）
7. ✅ **CoreDNS + NodeLocalDNS**
8. ✅ **LocalPV 存储类**
9. ✅ **追加节点加入集群**

整个过程约 **10-30 分钟**，取决于网络速度。

### 6.2 安装进度查看

KubeKey 的实时日志会输出到终端，内容类似：

```
[INFO] [k8s-master01] KubeKey v4.0.5 starting
[INFO] [k8s-master01] Dependency check passed
[INFO] [k8s-master01] Installing containerd...
[INFO] [k8s-master01] Installing Kubernetes...
[INFO] [k8s-master01] Node k8s-master01 joined cluster
[INFO] [LocalHost] Installing Calico v3.31.3...
[INFO] [LocalHost] Installing CoreDNS v1.12.1...
[SUCCESS] Cluster creation completed
```

---

## 7. 验证集群

### 7.1 基本验证

```bash
# 检查节点状态（所有节点应为 Ready）
kubectl get nodes --output=wide

# 检查系统 Pod 状态（全部应为 Running）
kubectl get pods --all-namespaces -o wide

# 检查 CoreDNS 解析
kubectl run test-dns --image=busybox:1.36.1 --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local

# 检查存储类
kubectl get sc
```

### 7.2 IPVS 模式验证

KubeKey 默认启用 IPVS 模式：

```bash
# 验证 kube-proxy 模式
kubectl get configmap -n kube-system kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode

# 查看 IPVS 转发规则
ipvsadm -Ln
```

### 7.3 组件版本确认

```bash
# K8s 版本
kubectl version --short

# 各组件版本
kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# etcd 版本
kubectl exec -n kube-system etcd-k8s-master01 -- etcd --version

# containerd 版本
sudo ctr version
```

---

## 8. 后续：安装 OpenKruiseGame + Kruise

集群就绪后，安装 **OpenKruiseGame（OKG）**（游戏服管理套件，v1.1.0）及其底层依赖 **OpenKruise**（v1.8.0）。

```bash
# ── 1. 安装 OpenKruise（底层工作负载扩展） ──
helm repo add openkruise https://openkruise.github.io/charts/
helm repo update
helm install kruise openkruise/kruise --version 1.8.0 \
  --namespace kruise-system --create-namespace

# ── 2. 安装 OpenKruiseGame ──
helm repo add openkruisegame https://openkruise.github.io/openkruisegame/
helm repo update
helm install kruise-game openkruisegame/kruise-game --version 1.1.0 \
  --namespace kruise-game-system --create-namespace

# ── 3. 验证 ──
kubectl get pods -n kruise-system
kubectl get pods -n kruise-game-system
kubectl get crd | grep -E 'kruise|game'
```

> 详细配置（GameServerSet 部署、热更新、网络模式等）见 [OpenKruiseGame 安装与配置指南](./openkruise-game.md)。

---

## 9. 常见问题与排错

### 9.1 kk 下载失败

```bash
# 手动指定版本
curl -sfL https://get-kk.kubesphere.io | KKZONE=cn SKIP_WEB_INSTALLER=true SKIP_PACKAGE=true sh -s -- v4.0.5
```

### 9.2 SSH 连接失败

```bash
# 确保目标节点 SSH 可用
ssh root@<node-ip>

# 如果使用密码认证报错：Permission denied (publickey,gssapi-keyex,gssapi-with-mic)
# 编辑 /etc/ssh/sshd_config，确保
# PasswordAuthentication yes
# 然后重启 sshd
sudo systemctl restart sshd
```

### 9.3 containerd 报错 sandbox_image 拉取失败

`registry.k8s.io` 在国内可能超时。KubeKey 已对 `zone: cn` 自动配置阿里云镜像，如仍有问题：

```bash
# 手动配置 containerd 镜像代理
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# 替换 sandbox_image
sudo sed -i 's|sandbox_image = "[^"]*"|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.10.1"|' /etc/containerd/config.toml

sudo systemctl restart containerd
```

### 9.4 crictl 无法连接 containerd

KubeKey 默认配置了 containerd 的 CRI socket（`/run/containerd/containerd.sock`），
但如果手动调试时遇到权限问题：

```bash
sudo crictl images                    # 用 sudo
# 或配置 crictl
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
```

### 9.5 重启后 kubelet 报错

```bash
# 检查 kubelet 状态
sudo journalctl -u kubelet -f --no-pager

# 重启 kubelet
sudo systemctl restart kubelet
```

---

## 10. 版本选择参考

### KubeKey v4.0.5 — 默认组件版本（K8s v1.34 配置）

| 组件 | 版本 |
|------|------|
| Kubernetes | v1.34.3 |
| containerd | v1.7.x（自动匹配） |
| runc | v1.1.12 |
| crictl | v1.34.0 |
| etcd | v3.6.5 |
| Calico | v3.31.3 |
| Cilium | 1.18.5（可选） |
| Flannel | v0.27.4（可选） |
| CoreDNS | v1.12.1 |
| NodeLocalDNS | 1.26.4 |
| pause | 3.10.1 |
| Helm | v3.18.5 |
| LocalPV | 4.4.0 |
| kube-vip | v0.7.2（可选 HA） |

### CentOS 7 内核与 K8s 版本对照

| K8s 版本 | 最低内核 | 推荐内核 | 备注 |
|----------|---------|---------|------|
| v1.27.x | 3.10 | 3.10 | 最后原生兼容 CentOS 7 的版本 |
| v1.28.x | 3.10 | 4.x+ | 部分新特性需新内核 |
| v1.29.x | 3.10 | 4.x+ | |
| v1.30.x | 3.10 | 4.x+ | |
| v1.31.x | 3.10 | 4.x+ | |
| v1.32.x | 3.10 | 4.x+ | |
| v1.33.x | 4.x | 5.x+ | Cgroup v2 等特性需要 |
| v1.34.x | 4.x | 5.4+ | 推荐使用最新 |

> **建议**：在 CentOS 7 上部署 K8s v1.34.x，**务必先升级内核至 5.4+**。如果不想升级内核，选择 K8s v1.27.x 配合 `kk create config --with-kubernetes v1.27.16`。

---

## 11. 清理集群

如需重新部署：

```bash
# 删除集群
kk delete cluster -i inventory.yaml -c config-v1.34.3.yaml

# 或直接清理残留
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet
sudo systemctl restart containerd
# 清理 CNI
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
```
