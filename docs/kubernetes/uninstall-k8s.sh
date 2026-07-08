#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*"; }

IS_MASTER=false
if [ -f /etc/kubernetes/admin.conf ]; then
  IS_MASTER=true
fi

echo "========================================"
echo " Kubernetes 卸载脚本"
echo " Role: $([ "$IS_MASTER" = true ] && echo 'Master + Worker' || echo 'Worker')"
echo "========================================"
echo ""
read -p "确认卸载 Kubernetes？这将删除所有集群数据 !!! (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  log_info "已取消"
  exit 0
fi

# ─── Step 1: 重置节点 ────────────────────────────────
log_info "[1/6] 重置 kubeadm..."
if command -v kubeadm &> /dev/null; then
  sudo kubeadm reset -f 2>/dev/null || true
  log_ok "kubeadm reset 完成"
fi

# ─── Step 2: 停止服务 ────────────────────────────────
log_info "[2/6] 停止 kubelet 和 containerd..."
sudo systemctl stop kubelet 2>/dev/null || true
# 不停止 containerd，只清除 k8s 相关数据

# ─── Step 3: 删除文件和数据 ──────────────────────────
log_info "[3/6] 删除集群数据..."
sudo rm -rf /etc/kubernetes/
sudo rm -rf "$HOME/.kube/"
if [ -n "${SUDO_USER:-}" ]; then
  ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  sudo rm -rf "$ORIG_HOME/.kube/"
fi
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /var/lib/cni/
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /var/run/cilium/
sudo rm -rf /opt/cni/bin/
log_ok "集群数据已删除"

# ─── Step 4: 卸载软件包 ──────────────────────────────
log_info "[4/6] 卸载 Kubernetes 组件..."
if command -v kubelet &> /dev/null; then
  sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  sudo apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
  sudo apt-get autoremove -y 2>/dev/null || true
  log_ok "软件包已卸载"
fi

sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update -qq 2>/dev/null || true
log_ok "APT 仓库已清理"

# ─── Step 5: 清理网络插件残留 ────────────────────────
log_info "[5/6] 清理网络插件残留..."
# 删除 flannel VXLAN 接口
if ip link show flannel.1 &>/dev/null; then
  sudo ip link delete flannel.1 2>/dev/null && log_ok "flannel.1 接口已删除" || log_warn "删除 flannel.1 失败"
fi

# 删除 flannel bridge
if ip link show cni0 &>/dev/null; then
  sudo ip link delete cni0 2>/dev/null && log_ok "cni0 接口已删除" || log_warn "删除 cni0 失败"
fi

# 清理 flannel iptables 链
if sudo iptables -L FLANNEL-FWD &>/dev/null; then
  sudo iptables -D FORWARD -j FLANNEL-FWD 2>/dev/null || true
  sudo iptables -X FLANNEL-FWD 2>/dev/null || true
  log_ok "FLANNEL-FWD iptables 链已清理"
fi

# 清理所有 flannel 引用
sudo iptables-save 2>/dev/null | grep -v flannel | sudo iptables-restore 2>/dev/null || true
log_ok "iptables flannel 规则已清理"

# ─── Step 6: 恢复系统配置 ────────────────────────────
log_info "[6/6] 恢复系统配置..."
# 恢复 swap
sudo sed -i '/swap/d' /etc/fstab 2>/dev/null || true
log_ok "swap 配置已恢复"

# 删除 k8s 内核模块配置
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/sysctl.d/k8s.conf
sudo sysctl --system > /dev/null 2>&1
log_ok "内核参数已恢复"

# 清理 Cilium VXLAN 接口（由 Cilium 管理，卸载后残留）
for iface in cilium_vxlan cilium_host cilium_net; do
  if ip link show "$iface" &>/dev/null; then
    sudo ip link delete "$iface" 2>/dev/null || true
  fi
done
log_ok "Cilium 虚拟接口已清理"

# ─── 完成 ─────────────────────────────────────────────
echo ""
echo "========================================"
echo -e "${GREEN}  卸载完成！${NC}"
echo "========================================"
echo ""
echo "  建议重启节点以完全清理:"
echo "    sudo reboot"
echo ""
