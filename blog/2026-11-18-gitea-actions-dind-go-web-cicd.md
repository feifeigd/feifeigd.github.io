---
title: "自建 Gitea Actions 跑通实录 — act_runner + dind，从 git push 到公网发布"
date: 2026-11-18T15:30:00+08:00
draft: false
tags: ["gitea", "cicd", "kubernetes", "docker", "go"]
categories: ["Tech"]
description: "在自建 k8s 上用 act_runner + dind 搭 Gitea Actions，配合 Gitea 内置镜像仓库和最小权限 ServiceAccount，实现 git push 后 20 秒自动构建镜像并滚动发布到公网（Go Web 全链路实测，含 4 个真实踩坑）"
---

团队需要一个不依赖 GitHub 的 CI：代码托管、镜像仓库、构建执行、发布到 k8s，全在自己机器上。前几篇写完了 Gitea 和集群，这篇把最后一环补上 —— **Actions Runner**，并且用一个 Go Web 服务把整条链路跑通：`git push` 之后 20 秒，公网域名上已经是新版本。

本文所有数字和输出都来自真实环境（首尔 2 节点 k8s、TencentOS，Gitea 28.4 + act_runner 0.6.1），踩到的 4 个坑也都原样记录。

{/* truncate */}

## 一、最终形态

```
git push
   │
   ▼
Gitea Actions（act_runner 0.6.1-dind，跑在 worker 上的 privileged pod）
   ├─ ① docker build      多阶段构建 Go 二进制，版本号用 commit 短 sha 注入
   ├─ ② docker push       → git.d7kj.com/feifeigd/go-web-demo:<sha>
   └─ ③ kubectl set image → rollout status（用 namespace 级 SA，改不了别的东西）
             │
             ▼
      k8s namespace=demo
      ├─ Deployment go-web（imagePullSecrets 拉私有镜像）
      ├─ Service go-web:80
      └─ Ingress go.d7kj.com
             │
             ▼
      宿主机 nginx（443，Let's Encrypt）+ ingress NodePort 30443
             │
             ▼
      https://go.d7kj.com  ← 公网
```

几个设计取舍先说清楚：

- **不用 Harbor**：Gitea 1.17 起自带 OCI 仓库，`/v2/` 就是标准 Docker Registry V2 接口。单节点、自己用的规模，上 Harbor 要多花 4~6G 内存和 200G 盘，收益只有漏洞扫描和项目级 RBAC。
- **dind 而不是挂宿主的 docker.sock**：CI 构建不污染宿主 docker，代价是 runner 容器要 `privileged: true`。
- **发布权限最小化**：CI 里能改的只有一个命名空间的 Deployment，拿不到集群管理员权限。

## 二、Runner 怎么装

镜像 `docker.io/gitea/act_runner:0.6.1-dind`，**必须 `privileged: true`**（容器内要起 dockerd）。

注册 token 在 Gitea 后台 `管理后台 → Actions → Runners → 创建 Runner` 取，**一次性**，存进 Secret：

```bash
kubectl -n gitea create secret generic act-runner-token --from-literal=token='xxxxx'
```

Deployment 的关键项：

```yaml
env:
  - name: GITEA_INSTANCE_URL
    value: http://gitea.gitea.svc.cluster.local:3000   # 集群内走 Service，不绕公网
  - name: GITEA_RUNNER_REGISTRATION_TOKEN
    valueFrom: { secretKeyRef: { name: act-runner-token, key: token } }
  - name: CONFIG_FILE
    value: /config/config.yml
volumeMounts:
  - { name: config, mountPath: /config }     # ConfigMap 里的 config.yml
  - { name: data,   mountPath: /data }       # PVC，存 .runner 注册身份
  - { name: docker-data, mountPath: /var/lib/docker }   # hostPath，存镜像层缓存
securityContext:
  privileged: true
```

`config.yml`：

```yaml
log:
  level: info
runner:
  file: /data/.runner
  capacity: 2
  timeout: 3h
  labels:
    - "ubuntu-latest:docker://catthehacker/ubuntu:act-22.04"
    - "ubuntu-22.04:docker://catthehacker/ubuntu:act-22.04"
container:
  valid_volumes: []     # 千万别在这里写 docker.sock，见坑一
```

两个存储位置别搞混：

| 卷 | 存什么 | 丢了会怎样 |
|---|---|---|
| PVC（2Gi） | `/data/.runner` 注册身份 | pod 重启要重新申请一次性 token |
| hostPath（`/data/k8s/act-runner/docker`） | dind 的镜像层 | 每次重建都要重拉 1.54G runner 镜像 |

> 为什么 docker 数据用 hostPath 而不是扩 PVC：静态 local PV **不支持 resize**，`kubectl edit pvc` 会直接报 `only dynamically provisioned pvc can be resized`。runner 已经 `nodeSelector` 钉死单节点，hostPath 反而最干净。

持久化必须实测（别看 pod Running 就算完）：

```bash
kubectl -n gitea exec deploy/act-runner -- docker info --format '{{.DockerRootDir}} {{.Driver}}'
# /var/lib/docker overlay2

kubectl -n gitea exec deploy/act-runner -- docker pull -q alpine:3.20
kubectl -n gitea rollout restart deploy/act-runner
kubectl -n gitea exec deploy/act-runner -- docker images    # alpine 还在 = 生效
```

## 三、四个坑（都实测踩过）

### 坑一：手动挂 docker.sock，job 容器直接建不出来

act_runner 检测到 docker 时会**自动**把 `/var/run/docker.sock` 挂进 job 容器。你若"想当然"在 `container.options` 里再写一次：

```
Binds:[/var/run/docker.sock:/var/run/docker.sock /var/run/docker.sock:/var/run/docker.sock]
```

Docker 报 duplicate mount point → **job 容器根本没被创建**，而 Gitea 页面上显示的是「**所有步骤 cancelled**」，一条错误都不给你。

诊断入口：

```bash
kubectl -n gitea exec deploy/act-runner -- docker ps -a   # 空 = 容器没建成
kubectl -n gitea logs deploy/act-runner | grep "HostConfig from options"
```

### 坑二：job 镜像里没有 docker CLI

`node:20-bookworm` 这类镜像没有 `docker` 命令。现象是 `docker version` 报 `command not found`，但很容易误判成"dind 坏了"。

换自带 CLI 的 runner 镜像即可：

```yaml
labels:
  - "ubuntu-latest:docker://catthehacker/ubuntu:act-22.04"   # 1.54GB，含 docker/git/node/构建工具
```

### 坑三：`| head` 让整个步骤失败（exit 141）

CI 日志里报 `exitcode '141': failure`，看起来莫名其妙 —— 141 = 128 + 13（SIGPIPE）。原因是 act 用 `bash -e -o pipefail` 执行 run 步骤，`docker images | head -5` 里 `head` 提前退出，`docker images` 收到 SIGPIPE，pipefail 把这个信号当成步骤失败。

```bash
docker images | head -5        # ❌ 141
docker images | grep go-web    # ✅
```

### 坑四：catthehacker 镜像里没有 kubectl

要"顺手上 k8s 发布"，得自己带一个 kubectl。加一步自举（每个 job 多花几秒，稳定）：

```yaml
      - name: 准备 kubectl
        run: |
          if ! command -v kubectl >/dev/null 2>&1; then
            curl -sSLo /tmp/kubectl "https://dl.k8s.io/release/v1.34.13/bin/linux/amd64/kubectl"
            chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
          fi
          kubectl version --client
```

## 四、镜像仓库：Gitea 内置的就够

验证它开着：

```bash
curl -i https://git.d7kj.com/v2/
# HTTP/2 401
# docker-distribution-api-version: registry/2.0     ← 401 才是对的，代表要登录
```

推拉流程：

```bash
echo "$TOKEN" | docker login git.d7kj.com -u feifeigd --password-stdin
docker tag go-web-demo:dev git.d7kj.com/feifeigd/go-web-demo:v1
docker push git.d7kj.com/feifeigd/go-web-demo:v1
```

三个实测细节：

1. **路径必须是 `域名/用户/包名:tag`**，只写 `域名/用户:tag` 不行（Gitea 用第二段当包名）。
2. **同 layer 跨包复用**：push 时日志出现 `Mounted from feifeigd/alpine`，说明 blob 挂载复用，同基础层只存一份。
3. **容器包不会按名字自动关联仓库**：建了同名仓库 `img-demo`，push `.../img-demo:1` 之后 API 的 `repository` 字段仍是 `null`，DB 里 `package.repo_id = 0`。要关联就手动调：

```bash
curl -X POST -u user:tok \
  "https://git.d7kj.com/api/v1/packages/feifeigd/container/img-demo/-/link/img-demo"
```

### 顺手配个自动清理

镜像天天推，磁盘会慢慢被吃掉。Gitea 有「包清理规则」，但**没有 API**（`POST /-/admin/packages/cleanup` 只收表单提交，GET 返回 405），只能在 `管理后台 → Packages` 里点，或者直接写 DB（`package_cleanup_rule` 表，`type` 是 TEXT，值 `container`）：

```sql
insert into package_cleanup_rule
  (enabled,owner_id,type,keep_count,keep_pattern,remove_days,remove_pattern,match_full_name,created_unix,updated_unix)
values (1,1,'container',10,'',30,'',0,<now>,<now>);
```

配合 `app.ini`：

```ini
[cron.cleanup_packages]
ENABLED = true
RUN_AT_START = false
SCHEDULE = @midnight
OLDER_THAN = 24h
```

语义实测确认：`remove_days` 删超过 N 天的版本，`keep_count` 保护最新 N 个。验证方法也简单 —— 把某个版本的 `created_unix` 回填成 40 天前，临时把 `RUN_AT_START` 设 true 重启，看它是不是真被删掉。

> 改 DB 必须在 Gitea 停止状态下做（`scale --replicas=0` 并等 pod 退出），因为 rootless 镜像里既没有 sqlite3 也没有 python，得用临时 pod 挂 hostPath 进去改。

## 五、CI 需要两个 secret

| secret | 值 | 权限 |
|---|---|---|
| `REGISTRY_TOKEN` | access token | `write:package` |
| `KUBECONFIG` | 一份 kubeconfig | 只能改 `demo` 命名空间的 Deployment |

kubeconfig 对应的最小权限 SA：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: deployer, namespace: demo }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: deployer, namespace: demo }
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]
```

生成 kubeconfig 时有个技巧：**server 直接写集群内域名**，runner 本身就在集群里，不依赖公网入口：

```bash
SATOK=$(kubectl create token deployer -n demo --duration=87600h)
CA=$(base64 -w0 /etc/kubernetes/pki/ca.crt)
# server: https://kubernetes.default.svc
# certificate-authority-data: $CA
# users[0].user.token: $SATOK
```

写进 Gitea secrets 用 API 就行（`PUT /repos/{owner}/{repo}/actions/secrets/{name}`，body 是 `{"data": "..."}`），不用点 UI。

镜像拉取还得单独配：`imagePullSecret` 用一个只有 `read:package` 的 token，**别拿推送 token 复用**。

## 六、Go Web 示例

工程很小，但每个细节都有用。

`main.go`（版本号由构建时注入）：

```go
var (
	version   = "dev"
	buildTime = "unknown"
)

mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
})

mux.HandleFunc("/api/info", func(w http.ResponseWriter, r *http.Request) {
	host, _ := os.Hostname()
	json.NewEncoder(w).Encode(map[string]string{
		"service": "go-web-demo", "version": version,
		"build": buildTime, "host": host,
	})
})
```

`Dockerfile`（多阶段 + ldflags 注入）：

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X main.version=${VERSION} -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -o /out/app .

FROM alpine:3.20
RUN adduser -D -u 10001 app && apk add --no-cache ca-certificates
COPY --from=build /out/app /app
USER 10001
ENTRYPOINT ["/app"]
```

`.gitea/workflows/ci.yml` 全文：

```yaml
name: ci
on:
  push:
    branches: [main]

env:
  IMAGE: git.d7kj.com/feifeigd/go-web-demo
  NS: demo
  APP: go-web

jobs:
  build-push-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 构建镜像
        run: |
          SHA=${GITHUB_SHA::7}
          echo "SHA=$SHA" >> $GITHUB_ENV
          docker build --build-arg VERSION=$SHA -t $IMAGE:$SHA -t $IMAGE:latest .

      - name: 推送到 Gitea 内置仓库
        run: |
          echo "${{ secrets.REGISTRY_TOKEN }}" | docker login git.d7kj.com -u feifeigd --password-stdin
          docker push $IMAGE:$SHA
          docker push $IMAGE:latest

      - name: 滚动发布
        run: |
          mkdir -p ~/.kube && echo "${{ secrets.KUBECONFIG }}" > ~/.kube/config && chmod 600 ~/.kube/config
          kubectl -n $NS set image deploy/$APP app=$IMAGE:$SHA
          kubectl -n $NS rollout status deploy/$APP --timeout=180s
```

k8s 侧就三件套（Deployment / Service / Ingress），重点是 `imagePullSecrets` 和探针：

```yaml
spec:
  imagePullSecrets: [{ name: gitea-registry }]
  containers:
    - name: app
      image: git.d7kj.com/feifeigd/go-web-demo:latest
      readinessProbe:  { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 5 }
      livenessProbe:   { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 10 }
      resources:
        requests: { cpu: 20m, memory: 32Mi }
        limits:   { cpu: 300m, memory: 128Mi }
```

## 七、公网入口：宝塔 nginx + Let's Encrypt

集群内的 ingress 只监听 NodePort（30080 HTTP / 30443 HTTPS），公网入口统一交给宿主机 nginx。**关键是用 HTTPS 回源**，否则应用会以为外部是 http：

```nginx
location / {
    proxy_pass https://127.0.0.1:30443;      # 注意是 https
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_ssl_server_name on;
    proxy_ssl_verify      off;               # ingress 是自签
    client_max_body_size 0;
    proxy_buffering off;
}
```

证书用 acme.sh 的 webroot 方式（HTTP-01），签完装到宝塔目录并挂上 reload：

```bash
/root/.acme.sh/acme.sh --issue -d go.d7kj.com -w /www/wwwroot/go.d7kj.com --server letsencrypt
/root/.acme.sh/acme.sh --install-cert -d go.d7kj.com --ecc \
  --key-file       /www/server/panel/vhost/cert/go.d7kj.com/privkey.pem \
  --fullchain-file /www/server/panel/vhost/cert/go.d7kj.com/fullchain.pem \
  --reloadcmd      "nginx -s reload"
```

落地上有个顺序问题：先只写 **80 端口的 server 块**（含 `^~ /.well-known/acme-challenge/`），签出证书后再加 `listen 443 ssl`。否则 nginx -t 会因为证书文件不存在直接失败。改完永远 `nginx -t` 再 reload，失败就回滚备份。

## 八、实测数据

| 项 | 实测值 |
|---|---|
| CI 全流程（构建 + 推送 + 发布） | **20 秒**（runner 镜像已缓存） |
| 首次构建（含拉 golang:1.22-alpine） | 约 75 秒 |
| 单 job 峰值内存 | 约 1.9G（dind + buildkit 常驻） |
| runner 空闲 RSS | 1.95G（1.54G 是镜像层缓存） |
| Go 镜像大小 | 约 9MB（alpine + 静态二进制） |
| 公网响应 | `HTTP/2 200`，TLS 由 Let's Encrypt 签发 |
| pod 资源 | requests 20m/32Mi，limits 300m/128Mi |

闭环验证，改一个接口再 push：

```bash
$ curl -s https://go.d7kj.com/api/hello?name=feifeigd
{"hello":"feifeigd","version":"decfe64"}

$ kubectl -n demo get deploy go-web -o jsonpath='{.spec.template.spec.containers[0].image}'
git.d7kj.com/feifeigd/go-web-demo:decfe64
```

版本号就是 commit 短 sha，一眼能对上"线上跑的是哪次提交"。

## 九、什么时候才该上 Harbor

| | Gitea 内置 | Harbor |
|---|---|---|
| 新增组件 | 0 | core + portal + db + redis + jobservice + registry |
| 内存 | 0（共用 Gitea 的 134MB） | 最小 4~6G（关掉 trivy/exporter） |
| 项目级 RBAC / 机器人账号 | 弱 | 强 |
| 漏洞扫描 / 签名 | 无 | Trivy / cosign |
| 多站复制 | 无 | 有 |

单节点、自己或小团队用，内置仓库完全够。真需要扫描报告交付客户、或者多团队隔离配额时再上 Harbor，那时候也值得多花那 6G 内存。

## 十、小结

这套组合的价值不在"省钱"，而在于**链路短**：代码、镜像、CI、发布绕着同一个域名和同一套 token 转，出问题只有四个地方可查（Gitea / runner pod / registry / k8s）。

四个坑里最阴的是第一个 —— 手动挂 socket 导致 **job 容器没创建、页面却只显示"步骤 cancelled"**。遇到"什么都没跑就全取消"，第一反应应该是去 runner 里 `docker ps -a`，而不是重跑。

仓库：`git.d7kj.com/feifeigd/go-web-demo`（含 Dockerfile / workflow / k8s manifests，可直接 copy 到自己的项目）。
