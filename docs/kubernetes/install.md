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

```bash
sudo bash ./master-setup.sh
```

完整脚本内容见 [master-setup.sh](./master-setup.sh)。

### 3. 工作节点部署

```bash
sudo bash ./worker-setup.sh
```

完整脚本内容见 [worker-setup.sh](./worker-setup.sh)。

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

## 构建镜像
使用 containerd ，却不能使用 crictl 构建镜像。
此时，不要安装docker，有冲突，处理比较麻烦。
这要使用 nerdctl ， 安装：
```shell
cd /tmp
# 如果刚才的包还在就用现成的，不在了重新下
wget https://github.com/containerd/nerdctl/releases/download/v2.3.4/nerdctl-full-2.3.4-linux-amd64.tar.gz
tar xzf nerdctl-full-2.3.4-linux-amd64.tar.gz

# 只拷你要的，跳过 containerd 系列
sudo cp bin/nerdctl /usr/local/bin/
sudo cp bin/buildkitd bin/buildctl /usr/local/bin/

# （可选）CNI 如果节点上 /opt/cni/bin 已经有了可以跳过
sudo cp -r bin/cni /opt/cni/bin/ 2>/dev/null || true

# buildkit 服务起起来
sudo cp lib/systemd/system/buildkit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now buildkit

# 验证
sudo nerdctl version

# BuildKit 服务
sudo rm -f /etc/systemd/system/buildkit.service

sudo sh -c 'cat > /etc/systemd/system/buildkit.service <<EOF
[Unit]
Description=BuildKit daemon
After=network.target containerd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock --containerd-worker=true --containerd-worker-namespace=k8s.io  --oci-worker=false

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl restart buildkit
sudo systemctl status buildkit

```

测试 Dockerfile
```shell
mkdir -p ~/nerdctl-test && cd ~/nerdctl-test
cat > Dockerfile <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache curl
WORKDIR /app
COPY . .
CMD ["echo", "hello from nerdctl build"]
EOF

sudo nerdctl build -t nerdctl-test:v1 .

# 默认看 default namespace（nerdctl 自己的）
sudo nerdctl images | grep nerdctl-test

# 再看 K8s 侧（k8s.io namespace），此时还看不到，因为刚才没指定 -n
sudo nerdctl -n k8s.io images | grep nerdctl-test

# 跑一下确认镜像能起容器
sudo nerdctl run --rm nerdctl-test:v1
```
