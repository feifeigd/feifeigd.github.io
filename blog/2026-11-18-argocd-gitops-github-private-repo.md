---
title: "自建 k8s 上的 Argo CD 实战 — GitHub 私有仓库到公网 HTTPS，四个假象与四个真坑"
date: 2026-11-18T22:00:00+08:00
draft: false
tags: ["argocd", "gitops", "kubernetes", "cicd"]
categories: ["Tech"]
description: "在自建单 master 集群上用 Argo CD 打通 GitHub 私有仓库到公网 HTTPS：6443 不可达时怎么选架构、CRD 超限怎么装、私有库为什么报 Repository not found、以及 Synced/Healthy 为什么会骗你"
---

我在一台首尔的自建 k8s 上装了 Argo CD，目标很朴素：GitHub 里改代码，集群自动更新，公网 HTTPS 能访问。

结果这一路踩到的坑，全都不是「配置写错」这种低级的，而是**状态显示和真实情况不一致**的：

- `Synced / Healthy` 的绿色状态，实际一个资源都没部署
- 私有仓库报 `Repository not found`，但仓库好好的、key 也是对的
- UI 提示 `Select at least one resource`，看起来像操作错误，其实是没资源可勾
- 装进去了、pod 全 Running，CRD 少了一个

这篇把每个坑的证据链和判据都写下来，方便下次 5 分钟内定位。

{/* truncate */}

## 零、先看最终链路

```
你 git push → GitHub（私有仓库，SSH Deploy Key）
                  │
                  ▼  （pull 模式：集群主动去拉，入站端口 0）
        ┌──────────────────────────────────────────────┐
        │  k8s（1 master + 1 worker，ingress-nginx）    │
        │                                              │
        │  argocd-server ──► Deployment/Pod            │
        │      ▲                                       │
        │      │ http:80                                │
        │  ingress-nginx :30443                         │
        └──────┼───────────────────────────────────────┘
               │ https 回源（自签，verify off）
        ┌──────┴───────────────────────────────────────┐
        │  master 宿主机 nginx（宝塔）:443              │
        │  Let's Encrypt 证书（acme.sh HTTP-01）        │
        └──────▲───────────────────────────────────────┘
               │ https
           浏览器
```

关键点：**入口只有宿主机 443 这一条**，集群 API 的 6443 从公网根本连不上。

## 一、为什么选 pull 模式，而不是让 GitHub 直连集群

先做了一次外网探测，结果决定了架构：

```bash
# 从外部机器探测 Seoul master
curl -sk https://43.133.90.150:6443/version      # 连接失败
# 对照：80/443 正常
curl -s -o /dev/null -w '%{http_code}\n' https://go.d7kj.com/healthz   # 200
```

apiserver 虽然监听在 `*:6443`，但云安全组没有放行，外部 TCP 握手就失败。三条路对比：

| 方案 | 入站端口 | 需要给 CI 集群凭证 | 结论 |
|---|---|---|---|
| **Argo CD / Flux（pull）** | 0 | 不需要 | ✅ 选它 |
| 集群内 GitHub self-hosted runner | 0 | 不需要 | 可行，但要跑构建（dind 需 privileged） |
| 开放 6443 + GitHub IP 白名单 | 要开 | 要（公网可试错） | ❌ 不推荐 |

pull 模式额外的好处：**kubeconfig 完全不出集群**。Argo CD 用 in-cluster 身份，CI 那边只需要一个镜像仓库的 token。

顺带确认出站是通的（这是 pull 模式的前提）：

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://github.com
# 200 0.025s        ← 首尔到 GitHub 只有 25ms，比国内直连舒服多了
curl -s -o /dev/null -w '%{http_code}\n' https://ghcr.io/v2/
# 401               ← 401 就是可达（要认证），不是故障
```

## 二、安装：CRD 会撞上 256KB 的 annotation 上限

官方 install.yaml，不引 helm：

```bash
V=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$V/manifests/install.yaml
```

第一次装报了这么一条，而我差点以为要重装：

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

原因是客户端 apply 会把整份清单塞进 `last-applied-configuration` annotation，CRD 体积超过 256KB 就爆。**此时组件其实已经起来了**（6 个 Deployment 都在 Running），只有那一个 CRD 没落地。

修法不是重装，而是换 server-side apply：

```bash
kubectl apply --server-side --force-conflicts -n argocd -f .../install.yaml
```

装完核对三件事：

```bash
kubectl get crd -o name | grep argoproj
# applications / applicationsets / appprojects   ← 3 个，少一个就是没装全
kubectl -n argocd get deploy
# 6 个全 1/1
```

实测内存约 350MB（server + repo-server + application-controller + redis + dex + notifications + applicationset），在剩 60G 的 worker 上完全无感。

## 三、入口：两跳反代，别省任何一跳

TLS 交给宿主机 nginx，argocd-server 走明文：

```bash
kubectl -n argocd patch cm argocd-cmd-params-cm --type=merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy/argocd-server
```

vhost 里除了常规反代，Argo CD 有两个特殊要求：

```nginx
location / {
    proxy_pass https://127.0.0.1:30443;      # 必须是 https 的 NodePort（不是 30080）
    proxy_set_header Host $host;              # ingress 靠 Host 匹配路由
    proxy_ssl_verify off;                     # ingress 是自签证书

    # Argo CD UI 里有 pod 终端和日志流，都是 WebSocket 长连接
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

`Connection` 这一项普通站点习惯写 `""`，Argo CD 必须写 `upgrade`。不写的话：页面能开、应用能看，**但点进 pod 的 TERMINAL / LOGS 会一直转圈**，而且 nginx 日志里看不出任何异常。

为什么不能省掉宿主机这一跳：

| 方案 | 结果 |
|---|---|
| 浏览器直连 NodePort 30443 | 云 SG 只开 80/443，不可达 |
| Service 用 `type: LoadBalancer` | 自建集群没有云 LB，永久 `pending` |
| 宿主机 443 反向代理 NodePort | 唯一可行 |

证书就是老一套 acme.sh HTTP-01（先放 80-only vhost 验通再签）：

```bash
acme.sh --issue -d argocd.d7kj.com -w /www/wwwroot/argocd.d7kj.com \
  --keylength ec-256 --server letsencrypt
acme.sh --install-cert -d argocd.d7kj.com --ecc \
  --key-file       /www/server/panel/vhost/cert/argocd.d7kj.com/privkey.pem \
  --fullchain-file /www/server/panel/vhost/cert/argocd.d7kj.com/fullchain.pem \
  --reloadcmd "nginx -s reload"
```

## 四、坑 1：私有仓库报 Repository not found —— 是协议错配

把 GitHub 仓库从 public 改成 private 之后，Application 直接红：

```
ComparisonError: failed to generate manifest: failed to list refs:
  authentication required: Repository not found.
```

UI 上另一处表现是 `Unable to load data: revision HEAD must be resolved`。

这两句话都会把你往「仓库被删了 / key 没权限」上带。实际原因很蠢：**凭证配的协议和 Application 用的 URL 不是一个**。

```
你配的凭证 url : git@github.com:feifeigd/myapp.git     ← SSH Deploy Key
Application url: https://github.com/feifeigd/myapp.git  ← HTTPS
```

Argo CD 只在 URL **完全匹配**时才套用凭证。于是它走匿名 HTTPS 拉私有库，GitHub 对匿名访问私有库统一返回 `Repository not found`（故意不区分「不存在」和「无权限」，防信息泄露）。所以报错信息完全是误导性的。

matrix 结论：

| 凭证类型 | Application repoURL | 结果 |
|---|---|---|
| SSH Deploy Key | `git@github.com:o/r.git` | ✅ |
| SSH Deploy Key | `https://github.com/o/r.git` | ❌ Repository not found |
| HTTPS + PAT | `https://github.com/o/r.git` | ✅ |

排查三步，比在 UI 里猜快得多：

```bash
# 1) 到底在报什么
kubectl -n argocd get application myapp \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'

# 2) 凭证的 url 是什么协议
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
  -o jsonpath='{range .items[*]}{.metadata.name} {.data.url}{"\n"}{end}'

# 3) 把 key 拿出来直接测（key 用临时文件，测完立刻删）
kubectl -n argocd get secret repo-xxxx -o jsonpath='{.data.sshPrivateKey}' | base64 -d > /tmp/k
chmod 600 /tmp/k
ssh -i /tmp/k -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -T git@github.com
#   Hi feifeigd/myapp! You've successfully authenticated...   ← key 是好的
GIT_SSH_COMMAND="ssh -i /tmp/k -o StrictHostKeyChecking=no -o IdentitiesOnly=yes" \
  git ls-remote git@github.com:feifeigd/myapp.git
rm -f /tmp/k
```

第 3 步的 `Hi <owner>/<repo>!` 那句特别有用：deploy key 是**绑定到单个仓库**的，GitHub 会把仓库名回显出来，等于顺便验证了权限范围。

改完 URL，Argo CD 立刻恢复正常。

## 五、坑 2：Synced / Healthy 是假绿

这是本次最坑的一个。用户把清单写得残缺，Argo CD 的状态是这样：

```
Application myapp   Synced   Healthy
```

看起来完美。实际上：

```bash
kubectl -n argocd get application myapp -o jsonpath='{.status.resources}'
# （空）
kubectl get ns myapp
# Error from server (NotFound)      ← 连命名空间都没建
```

原因在清单里：

```yaml
apiVersion: apps/v1
king: Deployment          # ← kind 拼错
metadata:
  lables:                 # ← labels 拼错
    app: myapp
```

`kubectl` 会明说：

```bash
kubectl apply --dry-run=server -f bad.yaml
# error validating data: [apiVersion not set, kind not set]
```

**但 Argo CD 不会。** 它遇到无法识别 kind 的文档直接跳过，于是「Git 里没有可部署的东西」和「集群里没有东西」恰好一致 —— 对比结果就是 Synced。

这个陷阱的本质：**Argo CD 比较的是「Git 声明」与「集群现状」，当 Git 侧是垃圾时，两者的差异是 0。** 绿色只证明「没有漂移」，不证明「部署成功」。

所以判据必须换成资源清单：

| 判据 | 命令 | 正常信号 |
|---|---|---|
| 资源数（最硬） | `kubectl -n argocd get application <app> -o jsonpath='{.status.resources}'` | 非空，且列出预期的每个对象 |
| 实际 revision | `... -o jsonpath='{.status.sync.revision}'` | 等于 Git 最新 commit |
| 条件 | `... -o jsonpath='{.status.conditions}'` | 空或只有 warning |
| pod 事件 | `kubectl -n <ns> describe pod` | 无 ImagePullBackOff / 探针失败 |

配套的好习惯：**提交前先在服务器上 `kubectl apply --dry-run=server -f` 一遍**。这一步能把 `kind` 拼错、字段错位这类问题在 CI 之前挡住，比在 Argo UI 里翻半天强。

## 六、坑 3：Select at least one resource 是什么意思

Argo CD UI 里点 SYNC 弹这句，第一反应是「我哪里没选？」。实际意思是：**当前 revision 里没有任何资源可勾选**。

成因就三种：

1. 清单被跳过（上面那个 kind 拼错）
2. `path` 写错 —— 本次真实报错是 `k8s: app path does not exist`，因为仓库里根本没有 `k8s/` 目录，只有 `.gitignore` 和 `README.md`：

   ```bash
   curl -s "https://api.github.com/repos/<owner>/<repo>/git/trees/HEAD?recursive=1" \
     | python3 -c 'import sys,json;[print(t["path"]) for t in json.load(sys.stdin)["tree"]]'
   ```

3. 还没 refresh —— Argo CD 默认**每 3 分钟**轮询一次 Git，改了代码不点 REFRESH，它还在用旧 commit

第 3 条容易被误判成「配置没生效」。想立刻拉：

```bash
# UI 右上角点 REFRESH；或者直接打 API
curl -s "https://argocd.example.com/api/v1/applications/myapp?refresh=hard" \
  -H "Authorization: Bearer $TOKEN"
```

本次实测：refresh 前记录 revision 是 `30cc9d3`（旧的坏清单），refresh 后变成 `e46f398`（新 commit），资源数从 0 变 1。

## 七、坑 4：Ingress 少写 http 段 + targetPort 对不上

Application 终于 Synced 了，3 个资源都在，pod 也 Running，但外网 404。两个独立的错误叠在一起：

**错误 A：Ingress 只有 host，没有路由**

```yaml
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.d7kj.com        # 到这里就结束了
```

正确写法必须有 `http: paths:`：

```yaml
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.d7kj.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
```

**错误 B：Service 转发到 8080，应用却在 80 监听**

```bash
kubectl -n myapp get endpoints myapp -o wide
# 10.244.2.95:8080,10.244.2.96:8080     ← endpoints 端口就是证据
kubectl -n myapp exec <pod> -- wget -qO- http://127.0.0.1:80/
# Server address: ...                   ← 应用在 80
```

`targetPort` 必须等于容器实际监听端口。这个错误不会让 pod 起不来，只会让流量 502/503，最容易被「pod 是 Running」骗过去。

**一个特别好用的自查手段**：`kubectl get endpoints` 里显示的端口是 Service 真正往 pod 打的端口，和 `kubectl get svc` 里的 `port` 不是一回事。

## 八、镜像：GitHub Actions 构建 → 推到自建 Gitea Registry → Argo CD 同步

Argo CD 只认 Git，不认镜像仓库。所以闭环必须包含「把新 tag 写回清单」这一步。

先验证 GitHub Runner 的视角能访问自建 registry：

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://git.d7kj.com/v2/
# 401   ← 正常，要登录
curl -s -o /dev/null -w '%{http_code}\n' -u "user:$TOKEN" https://git.d7kj.com/v2/
# 200   ← 凭证有效
```

workflow 的关键三段：

```yaml
permissions:
  contents: write          # 要 commit 回仓库

steps:
  - run: |
      echo "${{ secrets.GITEA_TOKEN }}" | \
        docker login git.d7kj.com -u "${{ secrets.GITEA_USER }}" --password-stdin

  - run: |
      TAG=${GITHUB_SHA::7}
      docker build -t git.d7kj.com/feifeigd/myapp:$TAG -t git.d7kj.com/feifeigd/myapp:latest .
      docker push git.d7kj.com/feifeigd/myapp:$TAG

  - run: |
      TAG=${GITHUB_SHA::7}
      sed -i "s|image: .*feifeigd/myapp:.*|image: git.d7kj.com/feifeigd/myapp:$TAG|" k8s/deployment.yaml
      git commit -am "ci: bump image to $TAG" && git push
```

三个约束，违反了就出事：

| 约束 | 原因 |
|---|---|
| 镜像路径必须 `域名/用户名/仓库:tag` | 少一层会 `denied: requested access to the resource is denied` |
| GitOps 用 commit sha 做 tag，别用 `latest` | Argo CD 只比对 Git 文本，`latest` 不变等于「没变化」，永远不触发同步 |
| 私有 registry 要 `imagePullSecrets` | 否则 `ErrImagePull / 401 Unauthorized`，而 Deployment 本身看起来一切正常 |

另外 `GITHUB_TOKEN` 推的 commit 不会再次触发 workflow（GitHub 防循环），所以不用担心死循环。

## 九、selfHeal 才是买 Argo CD 的理由

最后必须实测一把，否则等于只装了个 UI：

```bash
kubectl -n myapp delete deploy myapp --wait=false
sleep 30 && kubectl -n myapp get deploy
# myapp   2/2   2   2   31s        ← age 很小 = 被拉回来了
```

同理，手工 `kubectl scale --replicas=5` 会在下一轮对比里被改回 Git 里的 `replicas: 2`。**集群开始以 Git 为准**，这才是 GitOps 的意义。

## 十、这次学到的四句话

1. **绿色不代表部署成功。** `Synced` 只说明「Git 声明」等于「集群现状」；Git 侧是垃圾时照样是绿的。判据永远是 `status.resources` 非空。
2. **私有仓库的 `Repository not found` 几乎总是协议错配。** SSH 凭证配 `git@...`，HTTPS 凭证配 `https://...`，混用就报这个，别去查仓库权限。
3. **自建集群的入口只能靠宿主机反代。** NodePort 对外不通、LoadBalancer 没有云 LB，`宿主机 443 → ingress NodePort` 是唯一解；带 WebSocket 的应用还要记得 `Connection "upgrade"`。
4. **Argo CD 只认 Git。** 镜像推送完必须把 tag 写回清单，否则它永远看不到新版本——这是 pull 模式的设计前提，不是 bug。

装完之后整个体验是顺的：改代码 → CI 构建推送 → 自动改清单 → 集群滚动更新 → 公网 HTTPS 200。中间那堆坑，基本都集中在「相信了错误的状态显示」上。
