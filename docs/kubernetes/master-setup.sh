#!/bin/bash
set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ─── 参数 ──────────────────────────────────────────────
APISERVER_ADDR="${1:-}"
K8S_VERSION="${2:-v1.36.2}"
IMAGE_REPO="${3:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
POD_CIDR="${4:-10.244.0.0/16}"
PAUSE_VERSION="${5:-3.10}"

# 从 v1.36.2 提取 v1.36（APT 仓库路径用）
K8S_MINOR="$(echo "$K8S_VERSION" | grep -oP 'v\d+\.\d+')"

echo "========================================"
echo " Kubernetes Master Node Setup"
echo " Version: $K8S_VERSION ($K8S_MINOR)"
echo " Image Repo: $IMAGE_REPO"
echo " Pod CIDR: $POD_CIDR"
echo " Pause: $PAUSE_VERSION"
echo "========================================"

# ─── Step 0: 清理已有集群 ─────────────────────────────
log_info "清理已有集群（如果存在）..."
if [ -f /etc/kubernetes/admin.conf ] && command -v kubeadm &> /dev/null; then
  sudo kubeadm reset -f 2>/dev/null || true
  sudo rm -rf /etc/kubernetes/ "$HOME/.kube"
  log_ok "已清理旧集群"
fi

# ─── Step 1: 系统前置 ────────────────────────────────
log_info "[1/8] 关闭 swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

log_info "[2/8] 加载内核模块..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay || true
sudo modprobe br_netfilter || true

log_info "[3/8] 设置 sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null 2>&1

# ─── Step 2: 修复主机名 ──────────────────────────────
log_info "[4/8] 修复主机名解析..."
HOST=$(hostname)
if ! grep -q "127.0.0.1.*$HOST" /etc/hosts; then
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts > /dev/null
fi
sudo systemctl restart systemd-resolved 2>/dev/null || true

# ─── Step 3: 安装并配置 containerd ─────────────────────
log_info "[5/8] 安装 containerd..."
sudo apt-get update -y
sudo apt-get install -y containerd

log_info "配置 containerd..."
sudo mkdir -p /etc/containerd

if [ ! -f /etc/containerd/config.toml ] || [ ! -s /etc/containerd/config.toml ]; then
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi

# 1) 替换 sandbox_image 为阿里云镜像（兼容 containerd v1 双引号和 v2 单引号格式）
sudo sed -i "s|sandbox_image = \"[^\"]*\"|sandbox_image = \"$IMAGE_REPO/pause:$PAUSE_VERSION\"|; s|sandbox = '[^']*'|sandbox = '$IMAGE_REPO/pause:$PAUSE_VERSION'|" /etc/containerd/config.toml

# 2) 启用 systemd cgroup
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# 3) 配置 registry.k8s.io 镜像代理（containerd v2 hosts.toml）
sudo mkdir -p /etc/containerd/certs.d/registry.k8s.io
sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml > /dev/null <<EOF
server = "https://registry.k8s.io"

[host."https://$IMAGE_REPO"]
  capabilities = ["pull", "resolve"]
EOF

# 4) 配置 Docker Hub 镜像代理（Flannel 等第三方镜像用）
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml > /dev/null <<EOF
server = "https://docker.io"

[host."https://mirror.ccs.tencentyun.com"]
  capabilities = ["pull", "resolve"]
EOF

# 5) 配置 ghcr.io 镜像代理（Flannel CNI 插件用）
sudo mkdir -p /etc/containerd/certs.d/ghcr.io
sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml > /dev/null <<EOF
server = "https://ghcr.io"

[host."https://ghcr.nju.edu.cn"]
  capabilities = ["pull", "resolve"]

[host."https://ghcr.dockerproxy.com"]
  capabilities = ["pull", "resolve"]
EOF

sudo systemctl restart containerd
sudo systemctl enable containerd

# 等待 containerd 就绪
for i in $(seq 1 12); do
  if sudo crictl info > /dev/null 2>&1; then
    log_ok "containerd 已就绪"
    break
  fi
  log_info "等待 containerd... ($i)"
  sleep 5
done

# ─── Step 4: 安装 kubeadm / kubelet / kubectl ───────────
log_info "[6/8] 安装 Kubernetes 组件 (${K8S_MINOR})..."

sudo mkdir -p /etc/apt/keyrings
K8S_KEY="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
APT_OPTS=""

K8S_KEY_ID="234654DA9A296436"

# 导入 Kubernetes 签名密钥（优先从 keyserver 通过 HTTPS 拉取指定 key）
if ! curl -fsSL --connect-timeout 10 \
       "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${K8S_KEY_ID}&options=mr" \
       | sudo gpg --yes --dearmor -o "$K8S_KEY" 2>/dev/null; then
  log_warn "keyserver 导入失败，尝试阿里云 Release.key..."
  if ! curl -fsSL --connect-timeout 10 \
         "https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_MINOR}/deb/Release.key" \
         | sudo gpg --yes --dearmor -o "$K8S_KEY" 2>/dev/null; then
    log_warn "阿里云 key 下载失败，尝试旧版阿里云 key..."
    if ! curl -fsSL --connect-timeout 10 \
           "https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg" \
           | sudo gpg --yes --dearmor -o "$K8S_KEY" 2>/dev/null; then
      log_warn "旧版阿里云 key 下载失败，尝试官方 key..."
      curl -fsSL --connect-timeout 10 \
        "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
        | sudo gpg --yes --dearmor -o "$K8S_KEY" 2>/dev/null || true
    fi
  fi
fi

# 验证 key 是否包含目标指纹
if [ -s "$K8S_KEY" ] && sudo gpg --no-default-keyring --keyring "$K8S_KEY" --list-keys "$K8S_KEY_ID" > /dev/null 2>&1; then
  log_ok "Kubernetes GPG key ($K8S_KEY_ID) 已导入"
  APT_OPTS="signed-by=$K8S_KEY"
else
  log_warn "Kubernetes GPG key ($K8S_KEY_ID) 导入失败，将使用 trusted=yes 绕过签名验证"
  APT_OPTS="trusted=yes"
fi

sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null <<EOF
deb [${APT_OPTS}] https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_MINOR}/deb/ /
EOF

sudo apt-get update -y
sudo apt-get install -y cri-tools netcat-openbsd
APT_K8S_VER="${K8S_VERSION#v}"
if ! sudo apt-get install -y kubelet="${APT_K8S_VER}"* kubectl="${APT_K8S_VER}"* kubeadm="${APT_K8S_VER}"*; then
  log_warn "版本 $APT_K8S_VER 未找到，尝试安装最新版..."
  sudo apt-get install -y kubelet kubectl kubeadm
fi
sudo apt-mark hold kubelet kubectl kubeadm
log_ok "kubelet/kubectl/kubeadm 已安装"

# ─── Step 5: 预拉取镜像 ────────────────────────────────
log_info "预拉取控制面镜像..."
sudo kubeadm config images pull \
  --image-repository="$IMAGE_REPO" \
  --kubernetes-version="$K8S_VERSION"

# 诊断
echo "=== 已拉取镜像 ==="
sudo crictl images 2>/dev/null || true
if ! sudo crictl images 2>/dev/null | grep -q kube-apiserver; then
  log_err "控制面镜像拉取失败，请检查网络"
  exit 1
fi

# ─── Step 6: 初始化集群 ────────────────────────────────
log_info "[7/8] 初始化集群..."

# 自动获取节点 IP（如果未指定 APISERVER_ADDR）
if [ -z "$APISERVER_ADDR" ]; then
  APISERVER_ADDR=$(ip route get 8.8.8.8 | grep -oP 'src \K[^ ]+' | head -1)
  log_info "自动检测节点 IP: $APISERVER_ADDR"
fi

sudo kubeadm init \
  --apiserver-advertise-address="$APISERVER_ADDR" \
  --image-repository="$IMAGE_REPO" \
  --kubernetes-version="$K8S_VERSION" \
  --pod-network-cidr="$POD_CIDR" \
  --v=5 2>&1 | tee /tmp/kubeadm-init.log

# ─── Step 7: 等待 API Server ──────────────────────────
log_info "[8/8] 等待 API Server 就绪..."
for i in $(seq 1 36); do
  if nc -zv 127.0.0.1 6443 2>/dev/null; then
    log_ok "API Server 已就绪"
    break
  fi
  if [ $((i % 6)) -eq 0 ]; then
    log_warn "kubelet 日志（最近 10 行）:"
    sudo journalctl -u kubelet --no-pager -n 10 2>/dev/null || true
    sudo crictl ps -a 2>/dev/null || true
  fi
  log_info "等待... ($((i*5))s)"
  sleep 5
done

# ─── 配置 kubectl ─────────────────────────────────────
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
# 同时为 sudo 调用者配置（如果存在）
if [ -n "${SUDO_USER:-}" ]; then
  ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$ORIG_HOME/.kube"
  sudo cp /etc/kubernetes/admin.conf "$ORIG_HOME/.kube/config"
  sudo chown "$SUDO_USER:$SUDO_USER" "$ORIG_HOME/.kube/config"
  log_ok "kubectl 已配置 (用户 $SUDO_USER)"
fi

# ─── 安装 CNI ─────────────────────────────────────────
log_info "安装 Flannel CNI..."
FLANNEL_URL="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

# 下载 Flannel YAML（多重代理）
for src in \
  "https://ghproxy.net/$FLANNEL_URL" \
  "https://ghproxy.com/$FLANNEL_URL" \
  "https://mirror.ghproxy.com/$FLANNEL_URL" \
  "https://raw.gitmirror.com/flannel-io/flannel/master/Documentation/kube-flannel.yml" \
  "$FLANNEL_URL"; do
  if curl -fsSL --connect-timeout 10 --max-time 30 "$src" -o /tmp/kube-flannel.yml; then
    log_ok "Flannel YAML 已下载"
    break
  fi
done

if [ ! -s /tmp/kube-flannel.yml ]; then
  log_err "Flannel YAML 下载失败！请手动安装:"
  log_err "  curl -L -o kube-flannel.yml $FLANNEL_URL"
  log_err "  sudo kubectl apply -f kube-flannel.yml"
  exit 1
fi

# 提取镜像并预拉取（保留原始 GHCR 地址，走 hosts.toml 代理）
FLANNEL_IMAGES=$(grep -oP '(?<=image: ).*' /tmp/kube-flannel.yml | sort -u)
log_info "预拉取 Flannel 镜像:"
echo "$FLANNEL_IMAGES"
for img in $FLANNEL_IMAGES; do
  sudo ctr -n k8s.io image pull "$img" --timeout 180s &
done
wait

# 清理旧 pod 并安装
sudo kubectl delete pods -n kube-flannel --all --ignore-not-found 2>/dev/null || true
sudo kubectl apply -f /tmp/kube-flannel.yml

echo ""
echo "========================================"
echo -e "${GREEN}  安装完成！${NC}"
echo "========================================"
echo ""
echo "  验证:"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo ""
echo "  添加 worker 节点:"
echo "    sudo kubeadm token create --print-join-command"
echo ""
