# Kubernetes v1.36 安装指南（Ubuntu 24.04）

## 📌 环境准备
```bash
sudo apt update
sudo apt install -y curl wget

# 配置 containerd 镜像代理（如遇 registry.k8s.io 超时）
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's|sandbox_image = "[^"]*"|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.10"|' /etc/containerd/config.toml
cat <<EOF | sudo tee -a /etc/containerd/config.toml

[plugins."io.containerd.cri.v1.images".registry.mirrors."registry.k8s.io"]
  endpoint = ["https://registry.aliyuncs.com/google_containers"]
EOF

# 禁用swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# 启用IP转发
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# 修复主机名 DNS 解析
HOST=$(hostname)
if ! grep -q "127.0.0.1.*$HOST" /etc/hosts; then
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts
fi
```

## 🚀 安装流程

### 1. 配置Kubernetes仓库
```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
```

### 2. 主控节点部署
<CodeBlock language="bash" source="./master-setup.sh" />

### 3. 工作节点部署
<CodeBlock language="bash" source="./worker-setup.sh" />

## 🔧 验证集群状态
```bash
kubectl get nodes --output=wide
kubectl get pods --all-namespaces
```

## 🛡️ 安全加固
```diff
sudo vi /etc/containerd/config.toml  # 添加以下配置
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."your-registry"]
    endpoint = ["https://your-registry"]
```

## 📝 注意事项
### 版本锁定配置
```bash
sudo bash -c 'cat > /etc/apt/preferences.d/kube.pref <<EOF
Package: kubelet kubeadm kubectl
Pin: version 1.36.0-00*
Pin-Priority: 1001
EOF'
```

## 📦 网络插件选项
```bash
sudo kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

## 🛠️ 常见问题
- **证书过期**：`sudo kubeadm alpha certs renew all`
- **节点无法连接**：检查防火墙规则 `sudo ufw allow from <node-ip>`

## 📝 版本说明
- Kubernetes v1.36.0-00
- containerd v1.7.6

---

### 脚本说明
- `master-setup.sh`：初始化集群并配置 containerd
- `worker-setup.sh`：预装必要组件等待集群加入