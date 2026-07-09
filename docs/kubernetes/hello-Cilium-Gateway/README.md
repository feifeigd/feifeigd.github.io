# Hello Cilium Gateway

最基本的 Cilium Gateway API 示例。

> 参考原文：[Kubernetes Gateway API Tutorial: Replace Ingress with Cilium Gateway for HTTP Traffic](https://www.digitalocean.com/community/tutorials/kubernetes-gateway-api-tutorial-cilium-ingress-alternative) (DigitalOcean Community, 2025-09-04)

## 前提

- Kubernetes 集群已安装 Cilium 并启用 Gateway API（`gatewayAPI.enabled=true`、`kubeProxyReplacement=true`）
- GatewayClass `cilium` 已就绪：`kubectl get gatewayclass`
- LoadBalancer 控制器，因为 Cilium Gateway 会创建 LoadBalancer 类型的 Service

## 部署方式选择

### 方案一：云上环境（推荐）

云上**不需要 MetalLB**。云厂商的 Cloud Controller Manager（CCM）会自动为 `type: LoadBalancer` 的 Service 创建云 SLB/ALB/NLB 并分配公网 IP。

Cilium Gateway API 会自动创建 LoadBalancer Service，CCM 检测到后：

1. 创建云 SLB（阿里云 SLB / AWS NLB / 腾讯云 CLB）
2. 分配公网 IP
3. 后端自动挂载到集群节点

流量链路：

```
用户 → 域名(公网IP) → 云SLB → 节点 → Cilium → Gateway → HTTPRoute → Service → Pod
```

部署 Gateway 时**无需手动指定 `addresses`**，自动分配 IP：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: hello-gateway
  namespace: hello-cilium
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    port: 80
    protocol: HTTP
```

查看分配的 IP：

```bash
kubectl get gateway -n hello-cilium
```

### 方案二：裸机/VM/内网环境

使用 MetalLB 作为 LoadBalancer 控制器。MetalLB 分配的是**内网 IP**，公网访问需配合路由器端口转发、Cloudflare Tunnel 或 FRP 等方式。

#### 安装 MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s
```

#### 配置 IP 地址池

`addresses` 必须是节点所在局域网内**未被占用的真实 IP 段**。MetalLB 不做在线检测，如果池中有已被其他机器使用的 IP，会导致 IP 冲突。

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.100-10.0.0.200   # 替换为你的实际子网范围
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
# L2Advertisement 通过 ARP/NDP 宣告 IP，让局域网知道该 IP 在此节点
EOF
```

> `avoidBuggyIPs` 与"避免已占用的 IP"无关；设为 `true` 只是跳过 `.0` 和 `.255` 结尾的地址（网络/广播地址）。

## 部署

```bash
kubectl apply -f all-in-one.yaml
```

## 验证

```bash
# 检查 Gateway 状态（Address 字段显示分配的 IP）
kubectl get gateway -n hello-cilium

# 获取 Gateway 的外部地址
GATEWAY_IP=$(kubectl get gateway hello-gateway -n hello-cilium -o jsonpath='{.status.addresses[0].value}')
echo $GATEWAY_IP

# 测试
curl http://$GATEWAY_IP
```

## 镜像说明

示例使用阿里云镜像 `registry.cn-hangzhou.aliyuncs.com/google_containers/echoserver:1.10`。如使用 Docker Hub 镜像，需先配置 containerd 镜像代理。

## 外部访问（域名）

### 自动更新 DNS（external-dns）

安装 external-dns 后，给 Gateway 加注解即可自动同步域名解析：

```bash
helm install external-dns bitnami/external-dns \
  --namespace external-dns --create-namespace \
  --set provider=cloudflare \              # 按你的 DNS 提供商改
  --set cloudflare.apiToken=<token> \
  --set sources[0]=service \
  --set sources[1]=gateway-httproute \
  --set policy=sync
```

Gateway 加注解：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: hello-gateway
  namespace: hello-cilium
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.example.com
```

external-dns 检测到 LoadBalancer IP 变化后，自动在 DNS 提供商创建/更新 A 记录。

### 手动 nginx 转发（内网环境）

如果 VM 只有内网 IP（如腾讯云 NAT 映射），LoadBalancer IP 只能在局域网内访问。可以通过宿主机 nginx 转发到 MetalLB IP，实现域名访问。

```bash
# 宿主机安装 nginx
apt install -y nginx

# 配置代理到 MetalLB IP（需先将域名 A 记录指向 VM 公网 IP）
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80;
    server_name hello.example.com;   # 替换为你的域名

    location / {
        proxy_pass http://10.0.0.100:80;   # MetalLB 分配的 Gateway IP
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

nginx -s reload
```

```bash
# 测试
curl http://hello.example.com
```

> 注意：如果使用其他端口（如 8080），将 `listen 80` 改为对应端口，并在云平台安全组放行。

## 清理

```bash
kubectl delete -f all-in-one.yaml
```
