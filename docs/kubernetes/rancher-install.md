# Rancher 部署指南（Helm + 宝塔 nginx 反代）

> 目标：在已有 Kubernetes 集群上部署 **Rancher**（企业级 Kubernetes 管理平台 / Web 控制台），并通过宿主机宝塔（BT Panel）nginx 反向代理对外提供 HTTPS 访问。

---

## 为什么选 Rancher

对比主流 K8s 看板方案：

| 方案 | 安装复杂度 | 说明 |
|------|-----------|------|
| **Rancher** | ★☆☆ 极简 | 官方 Helm chart，镜像齐全，自带完整 Web 控制台 + 多集群管理 |
| KubeSphere v4 | ★★★ 复杂 | ks-core chart 需从源码打包，ks-console 镜像在 Docker Hub 缺失（`repository does not exist`），依赖组件多 |
| Kubernetes Dashboard | ★☆☆ 简单 | 功能弱，仅单集群资源查看，无多集群/项目管理 |

**结论**：Rancher 是功能与安装成本平衡最好的选择。本文基于 K8s v1.31.14 + containerd 1.7.13（CentOS 7，双节点）实测。

---

## 架构

```
浏览器
  │ https://rancher.d7kj.com:443
  ▼
宿主机 宝塔 OpenResty nginx（:80 → 301 → :443，TLS 证书在此）
  │ 反代 https://127.0.0.1:31242（NodePort）
  ▼
集群 ingress-nginx controller（NodePort 31242 = 443）
  │ 按 Host: rancher.d7kj.com 路由
  ▼
Rancher v2.15.0（namespace: cattle-system，ClusterIP 443）
```

关键点：
- **入口网关 = 宿主机宝塔 nginx**（已经装好的，不用集群内 Gateway API/额外入口）
- **集群内路由 = ingress-nginx**（Rancher 的 Ingress 对象依赖它）
- **证书链**：宝塔 nginx 持有对外证书 → 反代时 `proxy_ssl_name` 指向 Rancher 内部证书

---

## 第一步：安装 cert-manager

Rancher 依赖 cert-manager 签发内部证书：

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml

# 验证（3 个 pod 全部 Running）
kubectl get pods -n cert-manager
# cert-manager-xxx          1/1     Running
# cert-manager-cainjector   1/1     Running
# cert-manager-webhook      1/1     Running
```

## 第二步：安装 ingress-nginx

Rancher 的 Ingress 需要集群内有 ingress controller。KubeKey 基础集群**不含**它，需单独装：

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml

# 验证
kubectl get pods -n ingress-nginx
# ingress-nginx-controller-xxx   1/1     Running

# 查看 NodePort（443 映射的端口，反代要用）
kubectl get svc -n ingress-nginx
# ingress-nginx-controller   LoadBalancer   80:32707/TCP, 443:31242/TCP
```

> 裸金属集群无云 LB，Service 的 EXTERNAL-IP 显示 `<pending>` 属正常，NodePort 可用。

## 第三步：安装 Rancher

```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update rancher-latest

# 查看版本
helm search repo rancher-latest/rancher
# rancher-latest/rancher  2.15.0  v2.15.0

# 安装（hostname 必须填 DNS 域名，不能是 IP）
helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.d7kj.com \
  --set bootstrapPassword=admin12345 \
  --set replicas=1 \
  --set ingress.tls.source=rancher
```

验证：

```bash
kubectl get pods -n cattle-system
# rancher-xxx   1/1     Running

# 等待 Rancher 装完系统 chart（fleet、provisioning 等，约 2-5 分钟）
kubectl logs -n cattle-system rancher-xxx --tail=10
```

> **坑**：首次启动会并行执行多个 `helm-operation-*` pod 安装系统组件（fleet 等），期间日志可能出现 `Failed to install system chart fleet`，多为初始化未完成，等 pod Ready 即可。

## 第四步：宝塔 nginx 反向代理

### 4.1 域名解析

确保 `rancher.d7kj.com` 解析到宿主机公网 IP：

```bash
getent hosts rancher.d7kj.com
# 43.130.14.242   rancher.d7kj.com
```

### 4.2 证书

在宝塔面板 → 网站 → 添加站点 `rancher.d7kj.com` → SSL 申请 Let's Encrypt 免费证书（域名已解析可直接申请）；或先用自签证书跑通（见下）。

### 4.3 站点配置

宝塔 vhost 配置 `/www/server/panel/vhost/nginx/rancher.d7kj.com.conf`：

```nginx
server
{
    listen 80;
    server_name rancher.d7kj.com;
    return 301 https://$host$request_uri;
}
server
{
    listen 443 ssl;
    server_name rancher.d7kj.com;
    ssl_certificate /www/server/panel/vhost/cert/rancher.d7kj.com/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/rancher.d7kj.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    location / {
        proxy_pass https://127.0.0.1:31242;          # ingress-nginx NodePort
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_ssl_server_name on;                     # 上游 TLS SNI
        proxy_ssl_name rancher.d7kj.com;              # 匹配上游证书
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;       # WebSocket 支持
        proxy_set_header Connection 'upgrade';
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

生效并验证：

```bash
# 宝塔 nginx 路径（OpenResty）
/www/server/nginx/sbin/nginx -t
/www/server/nginx/sbin/nginx -s reload

# 本地验证
curl -sk https://127.0.0.1/healthz -H 'Host: rancher.d7kj.com'
# ok
curl -sk https://127.0.0.1/v3 -H 'Host: rancher.d7kj.com'
# {"type":"collection",...}
```

## 第五步：登录

浏览器打开 `https://rancher.d7kj.com`：

- 用户名：`admin`
- 密码：`admin12345`（helm 安装时 `bootstrapPassword` 指定的初始密码，首次登录强制修改）

登录后可：导入现有集群（local）、查看节点/Pod/工作负载、项目管理、RBAC、监控告警等。

---

## 常见问题

### Q：Rancher 的 Ingress 一直没生效（页面 502）

Rancher helm 默认给 Ingress 指定的 `ingressClassName=rancher`，但集群只有 `nginx` 这个 IngressClass。手动改：

```bash
kubectl patch ingress -n cattle-system rancher \
  --type=merge -p '{"spec":{"ingressClassName":"nginx"}}'
```

### Q：反代后浏览器提示证书不受信任

宝塔层用的是自签证书。到宝塔面板 → 网站 → rancher.d7kj.com → SSL → 申请 Let's Encrypt 免费证书即可（前提：域名已解析到本机、80 端口可被验证）。

### Q：curl 本地 IP + Host 头能通，但外网打不开

检查腾讯云安全组是否放行 **443**（宝塔一般已自动放行 80/443）。

### Q：Rancher 日志反复报 helm-operation 失败

首次初始化要安装 fleet / rancher-provisioning-capi 等系统组件，会生成多个 `helm-operation-*` pod。等待 2-5 分钟，`kubectl get pods -n cattle-system` 全部 Running 后恢复正常。

---

## 参考链接

- [Rancher 官方 Helm 安装文档](https://docs.rancher.com/rancher/v2.8/en/installation/install-rancher-on-k8s/)
- [Rancher Helm chart 仓库](https://releases.rancher.com/server-charts/latest)
- [ingress-nginx 部署文档](https://kubernetes.github.io/ingress-nginx/deploy/)
- [KubeKey 安装 K8s 指南](./kubekey-centos7.md)
- [CentOS 7 手动安装 K8s v1.31](./centos7-manual-install.md)
- [K8s 数据目录迁移到 /data/k8s](./migrate-data-to-data-k8s.md)
