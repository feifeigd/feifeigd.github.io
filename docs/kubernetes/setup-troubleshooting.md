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

## 快速参考

| 问题 | 检查命令 |
|------|---------|
| containerd 配置 | `sudo grep sandbox /etc/containerd/config.toml` |
| 镜像代理 | `ls -la /etc/containerd/certs.d/*/hosts.toml` |
| 已拉取的镜像 | `sudo crictl images` |
| kubelet 日志 | `sudo journalctl -u kubelet --no-pager -n 50` |
| pod 事件 | `sudo kubectl describe pod -n <ns> <pod>` |
| 节点状态 | `sudo kubectl describe node <node>` |
