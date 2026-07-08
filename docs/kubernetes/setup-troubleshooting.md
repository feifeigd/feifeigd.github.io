# Kubernetes 安装踩坑记录

## 1. GPG 签名密钥不可用

**现象:** `apt update` 报 `NO_PUBKEY 234654DA9A296436`

**原因:** Aliyun 镜像的 `Release.key` 文件内容不正确，且 `pkgs.k8s.io` 也被墙。

**解决:** 通过 keyserver.ubuntu.com 的 HTTPS API 直接拉取指定 key ID：
```bash
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x234654DA9A296436&options=mr" \
  | sudo gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

## 2. APT 仓库 URL 用了完整版本号

**现象:** `apt update` 报 404

**原因:** sources.list 中 URL 为 `.../stable/v1.36.2/deb/`，但 Aliyun 镜像路径只到小版本 `v1.36`。

**解决:** 从完整版本中提取小版本：
```bash
K8S_MINOR="$(echo "$K8S_VERSION" | grep -oP 'v\d+\.\d+')"
# URL 用 $K8S_MINOR 而非 $K8S_VERSION
```

## 3. sources.list 缺少 signed-by

**现象:** GPG key 已导入但 `apt update` 仍报 `NO_PUBKEY`

**原因:** key 导入了自定义路径 `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`，但 sources.list 未指定 `signed-by`，apt 只看默认路径找不到。

**解决:**
```
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://...
```

## 4. APT 包版本号带 v 前缀

**现象:** `apt-get install -y kubelet=v1.36.2*` 报 `Version not found`

**原因:** APT 包版本号不带 `v` 前缀，应为 `1.36.2`。

**解决:** 去掉 `v` 前缀：
```bash
APT_K8S_VER="${K8S_VERSION#v}"
sudo apt-get install -y kubelet="${APT_K8S_VER}"*
```

## 5. sandbox_image 只改了 tag 没改 registry

**现象:** pause 镜像仍从 `registry.k8s.io` 拉取（被墙）

**原因:** sed 只替换了 tag（`3.9` → `3.10`），registry 没改：
```bash
# 错误：只改了 tag
s|sandbox_image = "registry.k8s.io/pause:3.9"|sandbox_image = "registry.k8s.io/pause:3.10"|
```

**解决:** 一起替换 registry：
```bash
s|sandbox_image = "[^"]*"|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.10"|
```

## 6. containerd v2 配置格式变更

**现象:** sed 匹配不到 `sandbox_image`，config.toml 被清空

**原因:** containerd v2 使用 `sandbox = '...'`（单引号，字段名不同），非 v1 的 `sandbox_image = "..."`。

**解决:** 同时匹配两种格式：
```bash
sudo sed -i \
  "s|sandbox_image = \"[^\"]*\"|sandbox_image = \"$REPO/pause:$VER\"|; \
   s|sandbox = '[^']*'|sandbox = '$REPO/pause:$VER'|" /etc/containerd/config.toml
```

## 7. config.toml 空文件跳过配置生成

**现象:** `/etc/containerd/config.toml` 为 0 字节，containerd 用默认值

**原因:** 脚本只检查 `-f`（文件存在）但空文件也算存在，导致跳过 `containerd config default` 生成。

**解决:** 加上非空检查 `-s`：
```bash
if [ ! -f /etc/containerd/config.toml ] || [ ! -s /etc/containerd/config.toml ]; then
  containerd config default | sudo tee /etc/containerd/config.toml
fi
```

## 8. GHCR 镜像拉取超时

**现象:** Flannel pod 卡在 `Init:0/2`，describe 看到 `TLS handshake timeout`

**原因:** `ghcr.io` 在国内被墙。

**尝试过的方案:**
- `ghcr.dockerproxy.com` — 不可靠
- 替换 YAML 中 `ghcr.io/flannel-io/` 为 `docker.io/flannel/` — `flannel-cni-plugin` 镜像不存在于 Docker Hub

**最终方案:** 使用南京大学 GHCR 镜像代理 `ghcr.nju.edu.cn`：
```toml
# /etc/containerd/certs.d/ghcr.io/hosts.toml
server = "https://ghcr.io"

[host."https://ghcr.nju.edu.cn"]
  capabilities = ["pull", "resolve"]

[host."https://ghcr.dockerproxy.com"]
  capabilities = ["pull", "resolve"]
```

## 9. Flannel 镜像版本写死导致与实际不符

**现象:** 预拉取版本与实际 pod 请求版本不一致

**原因:** 手动写了 `v0.28.6`，但新版 Flannel YAML 已更新到 `v0.28.7`。

**解决:** 从下载的 YAML 中动态提取镜像版本：
```bash
grep -oP '(?<=image: ).*' /tmp/kube-flannel.yml | sort -u
```

## 10. sudo 下运行脚本 kubeconfig 只配了 root

**现象:** `kubectl` 不带 sudo 报证书错误

**原因:** 脚本用 `sudo bash setup.sh` 运行，`$HOME` 为 `/root`，kubeconfig 配到了 root 用户。

**解决:** 检测 `SUDO_USER` 并同时配到原用户：
```bash
if [ -n "${SUDO_USER:-}" ]; then
  ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$ORIG_HOME/.kube"
  cp /etc/kubernetes/admin.conf "$ORIG_HOME/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "$ORIG_HOME/.kube/config"
fi
```

## 11. containerd 未安装就执行 config 命令

**现象:** `containerd: command not found`

**原因:** 脚本假设 containerd 已安装，但新系统默认未安装。

**解决:** 先安装 containerd：
```bash
sudo apt-get install -y containerd
```

## 12. kubeadm 未安装就调用 reset

**现象:** `sudo: kubeadm: command not found`

**原因:** 清理步骤先于安装步骤执行。

**解决:** 调用 `kubeadm` 前检查命令是否存在：
```bash
if command -v kubeadm &> /dev/null; then
  sudo kubeadm reset -f
fi
```

## 13. 切换 CNI 时 Flannel 残留导致 Cilium 异常

**现象:**
- Cilium pod 反复重启，`cilium status` 报 `cilium-health daemon unreachable`
- 新建 Pod 卡在 `ContainerCreating`，CNI 报 `Cilium API client timeout exceeded`
- kubelet 日志报 `Error updating node status`，节点变为 `NotReady`

**根因:** 从 Flannel 切换到 Cilium 时，Flannel 的虚拟接口、路由、iptables 规则未清理干净，导致 Cilium 无法正常工作。

### 13a. flannel.1 VXLAN 接口占用端口 8472

**现象:**
```
cilium status 反复报：
  "failed to setup vxlan tunnel device: address already in use"
```

**原因:** `flannel.1` 接口仍在运行，占用了 VXLAN 端口 8472，Cilium 无法创建自己的 `cilium_vxlan` 隧道。

**检查:**
```bash
ip -d link show type vxlan
# 输出中 flannel.1 仍存在即有问题
```

**解决:**
```bash
sudo ip link delete flannel.1
sudo ip link delete cilium_vxlan  # 如果卡在 DOWN 状态也删掉重建
```

### 13b. 路由表错误 — Pod CIDR 覆盖了节点子网

**现象:**
```
ping 10.0.0.4 (API Server)
From 10.0.1.121 icmp_seq=1 Time to live exceeded
```

**原因:** 路由表中 `10.0.0.0/24` 被指向 `cilium_host` 隧道接口（属于 Cilium Pod CIDR），但 API Server IP `10.0.0.4` 也在这个子网内。kubelet 发往 API Server 的流量被错误封装进 VXLAN 隧道，而非走物理网卡。

**检查:**
```bash
ip route get 10.0.0.4
# 正常应走 eth0, 错误时走 cilium_host
```

**解决:**
```bash
# 添加节点 IP 的直达路由，绕过隧道
sudo ip route add <api-server-ip>/32 via <gateway> dev eth0
# 例如:
sudo ip route add 10.0.0.4/32 via 10.0.0.1 dev eth0  # vm-0-7 到 master
sudo ip route add 10.0.0.7/32 via 10.0.0.1 dev eth0  # master 回 vm-0-7
```

**根本方案:** Cilium 的 Pod CIDR (`10.0.0.0/24`) 与节点子网 (`10.0.0.0/22`) 重叠导致路由冲突。应在安装 Cilium 时指定不与节点子网重叠的 Pod CIDR。

### 13c. cni0 bridge 残留

**现象:** `ip link show` 仍能看到 `cni0`（Flannel 创建的 bridge）

**解决:**
```bash
sudo ip link delete cni0
```

### 13d. FLANNEL-FWD iptables 链残留

**现象:** `sudo iptables -L FORWARD -n -v` 中仍有 `FLANNEL-FWD` 链引用

**解决:**
```bash
sudo iptables -D FORWARD -j FLANNEL-FWD
sudo iptables -X FLANNEL-FWD
# 全量清理
sudo iptables-save | grep -v flannel | sudo iptables-restore
```

### 13e. 节点 NotReady 但 kubelet 还在跑

**现象:** `kubectl get nodes` 状态为 `NotReady`，`Conditions` 显示 `Kubelet stopped posting node status`

**排查思路:**
1. 检查 kubelet 是否在运行：`sudo systemctl status kubelet`
2. 检查 kubelet 能否连到 API Server：
   - `curl -k -v https://<api-server-ip>:6443`
   - 如果卡住 → 路由问题（见 13b）
   - 如果能通 → 检查 kubelet 日志 `sudo journalctl -u kubelet -n 50 --no-pager`
3. ping 不通 API Server 时，用 tcpdump 抓包定位：
   ```bash
   sudo tcpdump -i eth0 -c 3 -n host <api-server-ip> and port 6443
   ```

### 13f. Cilium agent 卡在 Terminating 无法删除

**现象:** 旧的 Cilium pod 状态为 `Terminating`，新的无法调度

**解决:**
```bash
kubectl delete pod -n kube-system <cilium-pod> --force --grace-period=0
```

## 快速参考

| 问题 | 检查命令 |
|------|---------|
| containerd 配置 | `sudo grep sandbox /etc/containerd/config.toml` |
| 镜像代理 | `ls -la /etc/containerd/certs.d/*/hosts.toml` |
| 已拉取的镜像 | `sudo crictl images` |
| kubelet 日志 | `sudo journalctl -u kubelet --no-pager -n 50` |
| pod 事件 | `sudo kubectl describe pod -n <ns> <pod>` |
| 节点状态 | `sudo kubectl describe node <node>` |
| VXLAN 接口冲突 | `ip -d link show type vxlan` |
| CNI 残留接口 | `ip link show \| grep -E "flannel\|cni0\|cilium"` |
| 路由是否异常 | `ip route get <api-server-ip>` |
| Flannel iptables | `sudo iptables -L FORWARD -n \| grep FLANNEL` |
| API Server 连通性 | `curl -k -v https://<api-server-ip>:6443` |
| 抓包调试 | `sudo tcpdump -i eth0 -c 5 -n host <ip> and port 6443` |
| Cilium agent 状态 | `kubectl exec -n kube-system <cilium-pod> -- cilium status` |
| Cilium endpoint | `kubectl exec -n kube-system <cilium-pod> -- cilium endpoint list` |
