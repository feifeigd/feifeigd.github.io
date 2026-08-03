---
slug: /blog/2026/08/03/harbor-registry-install
title: Harbor 私有镜像仓库搭建 — k8s + 宝塔 + ingress-nginx 完整实录
date: 2026-08-03
draft: false
tags: [kubernetes, harbor, docker, devops, registry]
categories: ["Tech"]
description: "在 KubeKey 搭建的 k8s 集群上部署 Harbor 2.15 的完整过程：Helm 安装、宝塔 TLS 终结、ingress-nginx 路由、acme.sh 签发证书，以及 push 401 等三个真实踩坑的修复方案"
---

团队需要一个私有 Docker 镜像仓库。选型上考虑过 Harbor 和轻量 Docker Registry：最终选了 **Harbor 2.15**——Web UI、项目隔离、RBAC、镜像复制，跟自建的 Gitea 天然组成一套开发基础设施。这篇记录完整安装过程，包括三个真实踩过的坑和修复方案。

{/* truncate */}

## 一、架构设计

集群是 KubeKey 搭的 2 节点（master + worker，containerd 1.7 + ingress-nginx + local-path 存储）。公网入口走的是服务器上的宝塔面板 nginx，已有 Gitea、Grafana、Rancher 的成熟反代模式。

最终流量路径：

```
用户 ──https──▶ 宝塔 nginx (443, Let's Encrypt 证书)
                 │  resolver 10.233.0.10 (CoreDNS)
                 └─ proxy_pass http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
                              │
                        ingress-nginx 按 Host 路由
                              │
                        harbor-ingress (class: nginx)
                        ├─ /v2/ /api/ /service/ → harbor-core:80
                        └─ /                        → harbor-portal:80 (Web UI)
                              │
                        Harbor pods (worker 节点)
```

几个关键决策：

* **宝塔只做 TLS 终结 + 转发**：证书在宝塔（Let's Encrypt），集群内部走 HTTP，`externalURL` 显式设为 `https://registry.d7kj.com`，保证 Harbor 生成的 token / 重定向 URL 是 https。
* **宝塔反代目标用 DNS 名 + CoreDNS resolver**，不写死 ClusterIP——Service 重建后 IP 会变，DNS 名永不变，配置零维护。
* **Harbor 的 Ingress 走标准 nginx class**，/v2/ 和 /api/ 路由到 core，/ 路由到 portal。
* **所有组件钉到 worker 节点**：worker 内存充足（30G），master 只有 7G 且已跑 Rancher 等。

## 二、前置条件

1. DNS：`registry.d7kj.com` A 记录指向服务器公网 IP（我用 `43.130.14.242`）
2. Helm 3 + 能访问 helm.goharbor.io
3. StorageClass（local-path 即可）

## 三、Helm 安装 Harbor

```bash
helm repo add harbor https://helm.goharbor.io
helm repo update harbor
helm search repo harbor/harbor
# 当前版本: 1.19.1 / app 2.15.1
```

核心 values（完整版存服务器 `/root/harbor-values.yaml`）：

```yaml
externalURL: https://registry.d7kj.com

harborAdminPassword: "********"          # 注意键名是 harborAdminPassword 不是 adminPassword
secretKey: "****************"            # 随机生成，勿用默认值

expose:
  type: ingress
  tls:
    enabled: false                       # TLS 由宝塔终结
  ingress:
    hosts:
      core: registry.d7kj.com
    className: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
      nginx.ingress.kubernetes.io/proxy-body-size: "0"

persistence:
  persistentVolumeClaim:
    registry:
      storageClass: local-path
      size: 200Gi
    database: { storageClass: local-path, size: 5Gi }
    redis:    { storageClass: local-path, size: 1Gi }
    jobservice:
      jobLog:                            # 注意嵌套在 jobLog 下！
        storageClass: local-path
        size: 1Gi

# 关键！registry 返回相对 URL，否则 push 会 401（见踩坑一）
registry:
  relativeurls: true

# 2 节点小集群：关掉扫描/导出省资源
trivy:
  enabled: false
exporter:
  enabled: false
metrics:
  enabled: false

# 全部组件钉到 worker
core:      { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
portal:    { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
registry:  { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
jobservice:{ nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
database:  { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
redis:     { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
nginx:     { nodeSelector: { kubernetes.io/hostname: vm-0-14-centos } }
```

安装：

```bash
helm install harbor harbor/harbor -f harbor-values.yaml --namespace harbor --create-namespace
```

新版 chart（1.19+）内置 PostgreSQL 和 Redis（`goharbor/harbor-db`、`redis-photon`），不再依赖 bitnami 子 chart，装起来干净很多。

## 四、宝塔反代配置

在 `/www/server/panel/vhost/nginx/registry.d7kj.com.conf` 添加（结构照抄 gitea 的 conf）：

```nginx
server
{
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name registry.d7kj.com;
    root /www/wwwroot/registry.d7kj.com;

    # ... 宝塔 SSL 证书路径、HTTP_TO_HTTPS 跳转、well-known 等标准段落 ...

    resolver 10.233.0.10 valid=30s ipv6=off;
    location / {
        set $harbor_backend "ingress-nginx-controller.ingress-nginx.svc.cluster.local:80";
        proxy_pass http://$harbor_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        # 大镜像 push/pull 必需
        proxy_request_buffering off;
        proxy_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
```

注意 `resolver` 必须配，`proxy_pass` 用变量 + DNS 名，这样 ClusterIP 怎么变都不用改配置。

## 五、SSL 证书（acme.sh）

宝塔自带的 `createSsl.py` 是 aapanel 国际版专用，国内宝塔用不了。直接上 acme.sh（webroot 模式，依赖上一步 conf 里的 `well-known` 目录）：

```bash
curl https://get.acme.sh | sh -s email=you@example.com

~/.acme.sh/acme.sh --issue -d registry.d7kj.com \
  -w /www/wwwroot/registry.d7kj.com --server letsencrypt

# 安装到宝塔证书目录（布局与宝塔 UI 一致），并配置续期后 reload nginx
mkdir -p /www/server/panel/vhost/cert/registry.d7kj.com
~/.acme.sh/acme.sh --install-cert -d registry.d7kj.com \
  --key-file /www/server/panel/vhost/cert/registry.d7kj.com/privkey.pem \
  --fullchain-file /www/server/panel/vhost/cert/registry.d7kj.com/fullchain.pem \
  --reloadcmd 'nginx -s reload'
```

acme.sh 自带 cron 自动续期，证书到期前自动换新并 reload nginx。

## 六、验证

```bash
# 健康检查
curl https://registry.d7kj.com/api/v2.0/health
# {"components":[{"name":"core","status":"healthy"},...],"status":"healthy"}

# 客户端登录（证书有效，零配置）
nerdctl login registry.d7kj.com -u admin

# 真实 push / pull 测试
nerdctl pull busybox:1.36
nerdctl tag busybox:1.36 registry.d7kj.com/library/busybox:test
nerdctl push registry.d7kj.com/library/busybox:test
nerdctl rmi registry.d7kj.com/library/busybox:test
nerdctl pull registry.d7kj.com/library/busybox:test
```

## 七、踩坑记录

### 坑一：push 时 blob 上传 commit 401（最隐蔽）

**现象**：`docker login` 成功、pull 成功、layer 上传进度条走完，最后 commit 报 `401 Unauthorized`。

**根因**：宝塔在外面终结 TLS，Harbor 的 registry 内部收到的是 http 请求，于是它生成的 upload `Location` 头是 `http://registry.d7kj.com/v2/.../blobs/uploads/...`。客户端拿 http 地址去请求 → 宝塔 301 跳 https → 上传状态机错乱 → commit 401。

**修复**：`registry.relativeurls: true`，让 registry 返回相对路径 Location，客户端用自己的 https 基址拼接。这是「Harbor 挂在外部 TLS 代理后面」的必配项。

### 坑二：jobservice PVC 一直 Pending

**现象**：其他组件 PVC 都正常绑定，只有 `harbor-jobservice` Pending，报 `no storage class is set`。

**根因**：chart 里 jobservice 的 PVC 配置嵌套在 `persistence.persistentVolumeClaim.jobservice.jobLog` 下，我写在了 `jobservice` 直接下级，storageClass 没生效。

**修复**：删掉坏 PVC（`kubectl delete pvc harbor-jobservice -n harbor`），按正确路径 `--set persistence.persistentVolumeClaim.jobservice.jobLog.storageClass=local-path` 重新 upgrade。

### 坑三：YAML 重复键导致 trivy 没关掉

**现象**：values 里 `trivy:` 写了两次（`enabled: false` 一处、`nodeSelector` 一处），trivy 还是被装上了。

**根因**：YAML 重复键**后者完全覆盖前者**，`enabled: false` 被吞掉。

**修复**：合并成同一个 `trivy:` 块。教训：写 values 前先 `helm template` 干跑 + 检查渲染结果。

## 八、运维要点

* **升级**：`helm upgrade harbor harbor/harbor -f /root/harbor-values.yaml -n harbor`（values 已归档在服务器）
* **存储位置**：PV 落在 worker 的 `/data/k8s/local-path/`，registry 卷 200Gi
* **客户端使用**：证书有效，containerd/docker 直接 `docker login registry.d7kj.com`，**不需要** 配 insecure-registries 或 certs.d
* **项目规划**：默认 `library` 是公开项目；多团队建议建私有项目 + 独立账号，CI 用 robot account
* **备份**：数据库 PVC（5Gi）建议定期备份；镜像数据量大的话用 Harbor 的复制策略同步到异地
