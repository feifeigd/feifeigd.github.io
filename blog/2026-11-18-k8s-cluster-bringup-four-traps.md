---
title: "从裸机到双节点 K8s v1.34 集群 — 四个把人卡住的坑"
date: 2026-11-18T01:00:00+08:00
draft: false
tags: ["kubernetes", "linux", "deployment", "infra"]
categories: ["Tech"]
description: "在一台跑着生产数据库的 RHEL8 系老机器上用 kubeadm 搭 v1.34 集群，记录版本天花板怎么算、CNI 怎么选，以及 join worker 时踩到的四个坑。"
---

手上有两台机器，一台跑着线上的 Web 站点和数据库，一台跑着游戏后端和 MySQL。想把它们组成一个 k8s 集群。

整个过程最耗时的不是 `kubeadm init`，而是**worker join 之后那一段**——节点显示 `Ready`，pod 却全部 `ContainerCreating`，日志里一堆看起来无关的错误。这篇文章把踩到的四个坑完整记下来，每个都给现象、根因、修法。

IP、域名、业务名全部替换过，但技术细节一个没删。

{/* truncate */}

## 一、先算版本天花板，别急着装

大部分人上来就 `curl` 装最新版，然后被 cgroup 打脸。装之前先看这三样：

```bash
stat -fc %T /sys/fs/cgroup/     # tmpfs = cgroup v1；cgroup2fs = v2
systemctl --version | head -1   # systemd 版本
uname -r
```

我这边的结果是：

| 项 | 实测值 | 含义 |
|---|---|---|
| OS | RHEL8 系（内核 5.4） | 包管理走 dnf，兼容 el8 仓库 |
| `/sys/fs/cgroup` | `tmpfs` | **cgroup v1** |
| systemd | **239** | 对 cgroup v2 支持不完整（要 247 以上才成熟） |
| iptables | v1.8.5 **nf_tables** 后端 | 会影响 CNI 选型 |

结论链条很清晰：

```
systemd 239 → 不能可靠跑 cgroup v2
           → 只能留在 cgroup v1
           → k8s 1.35 起移除 cgroup v1 支持
           → 版本天花板 = 1.34.x
```

所以我装的是 **v1.34.13**，不是当时最新的 1.36。想升到 1.35 以上，前提是换系统（RHEL9 / Ubuntu 24.04 系）。

这一步花五分钟，能省掉后面几小时的排查。

## 二、环境画像决定 CNI 选型

同一台机器上还有这些信息，直接影响决策：

| 项 | 值 | 影响 |
|---|---|---|
| 磁盘 | 系统盘 50G，数据盘 400G 挂在 `/data` | etcd 和镜像不能塞系统盘 |
| 已有负载 | 面板、MySQL、Redis、Nginx | 端口和 iptables 会被占用 |
| 现有 iptables 规则 | **1100 条**（面板防火墙） | kube-proxy 要和它们共存 |
| 后端 | **nf_tables** | Calico 在 nft 下是实验性支持 |
| 空闲内存 | 61G / 8 核 | master 放这台也够 |

因为 iptables 是 **nf_tables** 后端，我选了 **Flannel v0.25.7**（VXLAN backend）而不是 Calico。Calico 要用 `FELIX_IPTABLESBACKEND=NFT` 打开实验开关，在已经有一千多条规则的机器上加这个变量，风险不划算。

Flannel 只依赖 UDP 8472 和一组标准的 nat 规则，行为可预测。

## 三、master：用 YAML 而不是长命令行

`kubeadm init` 从 1.31 起废弃了一大批命令行 flag，长命令会直接报错。写成配置文件更稳：

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.0.0.4
  bindPort: 6443
nodeRegistration:
  name: k8s-master
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: demo
kubernetesVersion: v1.34.13
controlPlaneEndpoint: 10.0.0.4:6443
imageRepository: registry.k8s.io
apiServer:
  certSANs:
    - 198.51.100.10
    - 10.0.0.4
    - 127.0.0.1
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
etcd:
  local:
    dataDir: /data/k8s/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

三个细节值得说：

**1. `certSANs` 必须包含你可能用来访问 apiserver 的所有地址。** 我只把内网 IP 作为 `controlPlaneEndpoint`，但把公网 IP 塞进了 SAN，这样从外网 `kubectl` 也能通过 TLS 校验。这一步做漏了，后面想改只能重新签发证书。

**2. `etcd.dataDir` 指到数据盘。** 默认在 `/var/lib/etcd`（系统盘），系统盘只剩 26G，etcd 加上镜像很快会撑爆。

**3. containerd 的 root 也要挪。** 改 `/etc/containerd/config.toml`：

```toml
root = "/data/k8s/containerd"
```

注意这里有个坑：**Docker 官方 RPM 自带的 `config.toml` 只有 31 行，全是注释**，`root` 那行是 `#root = "..."`。直接 `sed 's/^root = ...'` 会静默匹配失败，你以为改了其实没改。正确做法是先重建完整配置再打补丁：

```bash
containerd config default > /etc/containerd/config.toml
sed -i 's#^root = "/var/lib/containerd"#root = "/data/k8s/containerd"#' /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -nE '^root =|SystemdCgroup' /etc/containerd/config.toml
```

顺带说一句：`/var/lib/containerd` 当时只有 160K，因为 Docker 用的是自己的 `/var/lib/docker`。所以改 root 是零迁移成本。

## 四、坑 1：改节点名，光重启 kubelet 是不够的

**现象**：把 worker 的主机名改掉，`kubectl delete node` 删掉旧记录，`systemctl restart kubelet`。然后节点再也没回来：

```
nodes "k8s-worker-01" is forbidden:
User "system:node:old-hostname" cannot get resource "nodes"
node 'old-hostname' cannot read 'k8s-worker-01', only its own Node object
```

**根因**：kubelet 的客户端证书是在 join 时由 apiserver 签发的，CN 直接写死成当时的节点名：

```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject
# subject=O = system:nodes, CN = system:node:old-hostname
```

Node authorizer 只允许 kubelet 操作 CN 对应的那一个 Node 对象。新名字意味着越权，请求被直接拒。**这不是重启能解决的，改配置也救不回来**——身份是签在证书里的。

**修法**：清掉旧身份，重新 bootstrap，拿一张新证书。

```bash
systemctl stop kubelet
rm -f  /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf
rm -f  /var/lib/kubelet/config.yaml
rm -rf /var/lib/kubelet/pki /etc/kubernetes/pki /etc/cni/net.d

# master 上出 token
kubeadm token create --print-join-command --ttl 1h

# worker 上重新 join
kubeadm join 10.0.0.4:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name k8s-worker-01 \
  --cri-socket unix:///var/run/containerd/containerd.sock
```

这里是**手删文件**而不是 `kubeadm reset`，因为 reset 可能连带 flush iptables——这台机器上有一千多条面板防火墙规则，碰不得。

顺便修正一个常见误解：主机名有**大写字母不会导致注册失败**，kubelet 会自动转小写。真正的问题是"改了名字但证书还是老名字"。

## 五、坑 2：删 `/etc/cni/net.d` 会把 containerd 弄卡死

**现象**：重新 join 后节点显示 `Ready`，但条件里有这样一条：

```
Ready=False (KubeletNotReady)
container runtime network not ready:
NetworkReady=false reason:NetworkPluginNotReady
message=Network plugin returns error: cni plugin not initialized
```

而 flannel 的 pod 明明是 `Running`，`/etc/cni/net.d/10-flannel.conflist` 也确实写回去了。

**根因**：在 containerd 日志里：

```
04:02:07  failed to reload cni configuration after receiving fs change event
          ("/etc/cni/net.d/10-flannel.conflist": REMOVE)
          error="cni config load failed: no network config found"

04:04:07  No cni config template is specified,
          wait for other system components to drop the config.
```

我们清理时删掉了整个 `/etc/cni/net.d` 目录，containerd 收到 REMOVE 事件后尝试重载失败，之后就一直停在"等别人放配置"的状态。**即使 flannel 后来把 conflist 写回去了，它也不会自动重新加载**——那个文件系统 watcher 已经死了。

kubelet 每次问运行时"网络就绪了吗"，containerd 都答"没就绪"，于是节点永远是 `NetworkPluginNotReady`。

**修法**：重启 containerd，让它重新读一次 CNI 目录。

```bash
systemctl restart containerd
sleep 5
systemctl restart kubelet
```

这个坑最阴的地方是**节点状态和实际情况不一致**：`Ready` 条件里 `NetworkUnavailable=False`（因为 flannel 自己会去改这个 condition），但 `Ready=False`。两个 condition 冲突时，以 `Ready` 为准。

## 六、坑 3：`cni0` 网桥的残留 IP

**现象**：节点 `Ready=True` 稳定了，但所有 pod 卡在 `ContainerCreating`：

```
FailedCreatePodSandBox: flannel failed (add):
failed to set bridge addr: "cni0" already has an IP address different from 10.244.2.1/24
```

**根因**：第一次 join 时这个节点分到的 pod 网段是 `10.244.1.0/24`，`cni0` 网桥上挂了 `10.244.1.1`。重新 join 后 controller-manager 分配的 podCIDR 变成了 `10.244.2.0/24`，但**网桥是内核对象，不在 `/var/lib/kubelet` 里，清身份时删不掉**。

flannel 的 CNI 插件启动时会检查网桥地址，发现不一致就拒绝继续。

**修法**：

```bash
ip -4 addr show cni0          # 确认是旧网段
ip link set cni0 down
ip link del cni0
```

删掉之后下一次创建 pod 时 flannel 会用正确网段重建：

```bash
ip -4 addr show cni0
# inet 10.244.2.1/24 brd 10.244.2.255 scope global cni0
```

**教训**：`cni0`、`flannel.1`、`veth*` 这些是内核网络对象，`kubeadm reset` 或手删文件都清不掉。重建节点身份时要么用 reset，要么记得手动检查这三类残留。

## 七、坑 4：10248 撞上业务进程

**现象**：kubelet 日志每隔 5 秒刷一次：

```
Failed to start healthz server
err="listen tcp 127.0.0.1:10248: bind: address already in use"
```

**根因**：10248 是 kubelet healthz 的默认端口。这台机器上一个跑了 24 天的业务进程恰好监听 `0.0.0.0:10248`：

```bash
ss -lntp | grep 10248
# LISTEN 0 128 0.0.0.0:10248 users:(("python",pid=2434731,fd=11))
```

**这里绝对不能杀业务进程。**

**修法**：让 kubelet 换端口，`0` 表示关闭本地 healthz：

```bash
sed -i '/^healthzPort:/d' /var/lib/kubelet/config.yaml
printf '\nhealthzPort: 0\n' >> /var/lib/kubelet/config.yaml
systemctl restart kubelet
```

关掉是安全的——控制面对节点的健康检查走 **10250**（`/healthz`），不依赖 10248。只是本地日志不再刷错误。

## 八、顺带一个 192G 的教训

排查端口时顺手 `du` 了一下数据盘，发现 `/data` 用了 72%，其中：

| 目录 | 占用 |
|---|---|
| MySQL 数据目录 | 218G |
| ├─ **binlog** | **192G**（193 个文件） |
| └─ 实际库数据 | **27G** |

binlog 只保留 5 天（`expire_logs_days=5`），但每天生成 **38G**——每 37 分钟就写满一个 1.1G 的文件。

清理收益很直接：

| 保留 | 释放 | 数据盘使用率 |
|---|---|---|
| 5 天（原始） | — | 72% |
| 3 天 | 77G | **51%** |
| 2 天 | 115G | 43% |

清理是安全的，因为 PITR（按时间点恢复）**本来就已经断了**——唯一一份全量备份是两个月前的，binlog 只有 5 天，中间补不回来。清到 3 天不增加任何新损失。

但这里有个必须先想清楚的问题：**清 binlog 之前应该先有备份**。这台机器的 MySQL 完全没有任何自动备份任务，唯一一份 dump 是两个月前手动跑的。27G 的库裸奔两个月，比 binlog 占空间严重得多。

我最后加了两层定时：

- **etcd 快照 + 证书打包**：每天 03:30，保留 14 天，快照用 `etcdutl snapshot status` 真校验（不是只看文件大小）
- **磁盘水位**：每天检查两台机器的挂载点，超过 80% 才告警

etcd 备份有个小细节：`etcdctl snapshot status` 在 3.6 里已经移到 `etcdutl` 了，脚本体里如果还写 `etcdctl snapshot status`，它会打印一段帮助文本并且**退出码是 0**——你会得到一个假的"校验通过"。必须改用 `etcdutl`，并且检查输出里有没有 `totalKey` 字段。

## 九、收尾检查清单

集群建完之后，这几条必须全过才算真完成：

```bash
kubectl get nodes -o wide                    # 全部 Ready
kubectl get pods -A | grep -vE "Running|Completed"   # 无输出
kubectl get --raw='/readyz?verbose' | tail -3

# 跨节点网络：pod 强制落 worker，解析 master 上的 CoreDNS
kubectl run t --image=busybox:1.36 --rm -i --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-worker-01"}}}' \
  -- nslookup kubernetes.default.svc.cluster.local

# pod 出公网（验证 MTU 没问题）
kubectl run t2 --image=busybox:1.36 --rm -i --restart=Never \
  -- wget -q -T 8 -O- https://example.com
```

最后一条容易被忽略：这台机器的 `eth0` MTU 是 **8500**（云厂商内网巨型帧），flannel 算出来的 pod MTU 是 8450。这个值不常见，必须实测 pod 能不能访问公网——如果 PMTU 发现有问题，现象是"DNS 通但 HTTPS 卡住"，修法是在 flannel 的 ConfigMap 里显式写 `"MTU": 1450`。

## 十、总结

四个坑里，三个都跟"**重新 join**"有关：

| 坑 | 误判 | 真相 |
|---|---|---|
| 改节点名失效 | 以为重启 kubelet 就行 | 证书 CN 写死，必须重新 bootstrap |
| 假 Ready | 以为 flannel 没起来 | containerd 的 CNI watcher 死了 |
| pod 全 Pending | 以为 CNI 配置不对 | `cni0` 网桥残留旧网段 |

共同点是**日志里的报错都不是真正的原因**，根因要看 containerd 日志和内核网络对象，而不是只看 kubelet 和 pod 事件。

另外两个可以省下的时间：

1. **先算版本天花板**（cgroup 版本 + systemd 版本），别装完再发现卡住
2. **iptables 后端决定 CNI 选型**，nf_tables 环境下 Flannel 比 Calico 省心

至于单 master 的取舍：这台 master 带 `control-plane` 污点不跑业务 pod，etcd 单副本没有高可用，挂了集群就不可用。对内部工具够用，对生产核心业务不够。要 HA 就是三台 master 加一个 LB，成本翻三倍——这个决定应该在开工前做，不是装完再补。
