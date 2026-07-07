#!/bin/bash
set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ─── 参数 ──────────────────────────────────────────────
K8S_VERSION="${1:-v1.36.2}"
IMAGE_REPO="${2:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
PAUSE_VERSION="${3:-3.10}"

K8S_MINOR="$(echo "$K8S_VERSION" | grep -oP 'v\d+\.\d+')"

echo "========================================"
echo " Kubernetes Worker Node Setup"
echo " Version: $K8S_VERSION ($K8S_MINOR)"
echo " Image Repo: $IMAGE_REPO"
echo " Pause: $PAUSE_VERSION"
echo "========================================"

# ─── Step 0: 清理已有节点 ─────────────────────────────
log_info "清理已有节点（如果存在）..."
if [ -f /etc/kubernetes/kubelet.conf ] && command -v kubeadm &> /dev/null; then
  sudo kubeadm reset -f 2>/dev/null || true
  sudo rm -rf /etc/kubernetes/ "$HOME/.kube"
  log_ok "已清理旧节点"
fi

# ─── Step 1: 系统前置 ────────────────────────────────
log_info "[1/6] 关闭 swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

log_info "[2/6] 加载内核模块..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay || true
sudo modprobe br_netfilter || true

log_info "[3/6] 设置 sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null 2>&1

# ─── Step 2: 修复主机名 ──────────────────────────────
log_info "修复主机名解析..."
HOST=$(hostname)
if ! grep -q "127.0.0.1.*$HOST" /etc/hosts; then
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts > /dev/null
fi
sudo systemctl restart systemd-resolved 2>/dev/null || true

# ─── Step 3: 安装并配置 containerd ─────────────────────
log_info "[4/6] 安装 containerd..."
sudo apt-get update -y
sudo apt-get install -y containerd

log_info "配置 containerd..."
sudo mkdir -p /etc/containerd

if [ ! -f /etc/containerd/config.toml ] || [ ! -s /etc/containerd/config.toml ]; then
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi

# sandbox_image（兼容 containerd v1 双引号和 v2 单引号格式）
sudo sed -i "s|sandbox_image = \"[^\"]*\"|sandbox_image = \"$IMAGE_REPO/pause:$PAUSE_VERSION\"|; s|sandbox = '[^']*'|sandbox = '$IMAGE_REPO/pause:$PAUSE_VERSION'|" /etc/containerd/config.toml

# systemd cgroup
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# registry.k8s.io 镜像代理
sudo mkdir -p /etc/containerd/certs.d/registry.k8s.io
sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml > /dev/null <<EOF
server = "https://registry.k8s.io"

[host."https://$IMAGE_REPO"]
  capabilities = ["pull", "resolve"]
EOF

# Docker Hub 镜像代理
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml > /dev/null <<EOF
server = "https://docker.io"

[host."https://mirror.ccs.tencentyun.com"]
  capabilities = ["pull", "resolve"]
EOF

# ghcr.io 镜像代理
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

for i in $(seq 1 12); do
  if sudo crictl info > /dev/null 2>&1; then
    log_ok "containerd 已就绪"
    break
  fi
  log_info "等待 containerd... ($i)"
  sleep 5
done

# ─── Step 4: 安装 kubeadm / kubelet / kubectl ───────────
log_info "[5/6] 安装 Kubernetes 组件 (${K8S_MINOR})..."

sudo mkdir -p /etc/apt/keyrings
K8S_KEY="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
APT_OPTS=""
K8S_KEY_ID="234654DA9A296436"

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

# ─── Step 5: 启动 kubelet ─────────────────────────────
log_info "[6/6] 启动 kubelet..."
sudo systemctl enable --now kubelet 2>/dev/null || true
log_ok "kubelet 已启动（等待 join 后才会正常运行）"

# ─── 预拉取 Flannel 镜像 ──────────────────────────
log_info "预拉取 Flannel 镜像（加速节点就绪）..."
FLANNEL_URL="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
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

if [ -s /tmp/kube-flannel.yml ]; then
  for img in $(grep -oP '(?<=image: ).*' /tmp/kube-flannel.yml | sort -u); do
    sudo ctr -n k8s.io image pull "$img" --timeout 180s &
  done
  wait
  log_ok "Flannel 镜像已预拉取"
fi

# ─── 完成 ─────────────────────────────────────────────
echo ""
echo "========================================"
echo -e "${GREEN}  节点安装完成！${NC}"
echo "========================================"
echo ""
echo "  在 master 节点上执行以下命令获取 join 命令:"
echo ""
echo "    sudo kubeadm token create --print-join-command"
echo ""
echo "  然后在当前 worker 节点执行 join 命令:"
echo ""
echo "    sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
echo ""
echo "  如果忘记了 master-ip，在 master 上执行:"
echo "    kubectl get nodes -o wide"
echo ""

# sudo kubeadm join 10.0.0.4:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
