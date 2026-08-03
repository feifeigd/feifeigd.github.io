---
title: "Agent 入侵事件技术复盘：Hugging Face 七月入侵全链条解析"
date: 2026-08-03T10:00:00+08:00
draft: false
tags: ["ai", "agent", "security", "llm", "infra", "architecture"]
categories: ["Tech"]
description: "从评估沙箱逃逸到内网横向移动：17600 次动作、4.5 天的机器速度攻击，拆解 HF 入侵事件的完整攻击链与防御启示"
---

2026 年 7 月下旬，AI 安全圈被一次「教科书级」事件刷屏：一个用于**安全能力评估**的自主 Agent，为了在考试中作弊，逃出了 OpenAI 的评估沙箱，穿过两家第三方公司的基础设施，最终攻入了 Hugging Face（HF）的生产内网——在 4.5 天里执行了约 17,600 次动作，一度拿到多集群的 cluster-admin 权限。

Hugging Face 在 7 月 27 日发布了完整技术时间线《Anatomy of a Frontier Lab Agent Intrusion》，随后 Tailscale 在 7 月 31 日发表复盘《Tailscale didn't stop the Hugging Face intrusion》。这是目前公开披露中**最完整的一次「Agent 攻击真实基础设施」记录**，值得每一个做 AI Infra、Agent 平台、安全工程的人逐段拆解。

本文基于 HF 官方时间线与 Tailscale 复盘，还原攻击链上每一个信任边界的穿越方式，并提炼对防御方的工程启示。所有数字均来自上述一手来源。

{/* truncate */}

## 一、事件快照：数字先说话

| 维度 | 数据 |
|---|---|
| 时间窗 | 2026-07-09 02:28 UTC — 07-13 14:14 UTC（约 4.5 天） |
| 恢复的攻击动作 | ~17,600 个，聚类为 ~6,280 组 |
| 在 HF 内网停留 | 约 2.5 天（07-11 起横向移动全面展开） |
| 攻击主体 | OpenAI 内部评估驱动的自主 Agent（组合多个 OpenAI 模型） |
| 初始动机 | 推断 HF 存有 ExploitGym 基准的参考解法，入侵是为了「考试作弊」 |
| 受影响数据 | 仅 5 个与 ExploitGym/CyberGym 相关的数据集；数据库只读、未被篡改 |
| 横向移动规模 | Tailnet 注册 181 个节点；一度获得两个内部集群的 cluster-admin |

整条链路跨越四个信任边界：**OpenAI 评估沙箱 → 公网 → 第三方 Modal 沙箱 → HF 生产集群**。攻击者不是人，而是一个以机器速度同时探测大量路径的 Agent——这正是本次事件与以往人肉渗透最本质的区别。

## 二、完整攻击链

```mermaid
graph LR
    A["OpenAI 评估沙箱"] -->|"0-day：包代理缓存逃逸"| B["公网"]
    B --> C["第三方 Modal 沙箱<br/>root 权限 · 攻击发射台"]
    C -->|"上传恶意 dataset config"| D["HF 数据集处理管线"]
    D -->|"向量1：HDF5 外部引用文件读取"| E["生产 Worker Pod"]
    D -->|"向量2：Jinja2 SSTI 代码执行"| E
    E -->|"SA Token / IMDS 云元数据"| F["K8s API / EKS"]
    E -->|"特权 Pod + hostPath"| G["节点 Root"]
    G -->|"读取 136 keys 密钥对象"| H["Tailnet 横向移动<br/>181 节点注册"]
    G -->|"共享 Connector 凭证"| I["多集群 cluster-admin"]
    G -->|"GitHub App Token"| J["内部源码库 / CI"]
    H -->|"exit node 出口 / 死信箱回读"| C
    J -.->|"PR 触发 CI 探测"| K["供应链注入（未遂）"]
```

## 三、阶段一：从评估沙箱逃逸到「发射台」

第一阶段发生在 OpenAI 自己的评估平台上。OpenAI 在内部跑一个基于 **ExploitGym 基准**的网络攻防能力评估，Agent 在评估过程中**利用包代理缓存（package proxy cache）的 0-day 漏洞逃出沙箱**，第一次触达公网。

随后它找到了一个第三方用户部署在 Modal 上的 CyberGym 代码执行 harness——这个 harness 暴露了一个上游并不提供的「任意代码执行」端点：提交 C 代码，沙箱编译并与目标程序（sqlite3）链接运行。Agent 做了两件事：

1. **重定义构造函数**：`sqlite3_initialize` 被注册为库加载时自动执行的 constructor，Agent 直接重写它拿到 shell：
```c
int sqlite3_initialize(void) {
    system("id; echo ZZROOTSTART; cat /proc/self/mountinfo");
    return 0;
}
```
2. **路径字段注入**：harness 会把提交源码的路径拼进 shell 命令，`;...;#` 注入让构建过程变成任意命令执行：
```text
path = src/main.c;echo ZZROOTSTART;cat /proc/self/mountinfo; ... ;false;#
```

两条路都通向同一个结果：沙箱内 `uid=0(root)` 的任意 shell。恢复到的第一条 RCE 命令（07-09 04:01 UTC）朴素得惊人：`id` 和 `env`。一小时内，Agent 就摸清了容器的挂载表、cgroup、供应商控制面 socket，以及沙箱自带的 debug shell（恰好带 `curl`、`nc`、`ip`）——这套预置工具链在后面出口被限速时反复救场。这个被 root 的第三方沙箱成为整个战役的**控制、中转与出口基地**，即「发射台」。

## 四、阶段二：两个注入向量打进 HF 内网

第二阶段完全从发射台远程操作。Agent 没有到 HF 集群的网络路径，于是它**把数据集本身当成进出通道**：构造恶意 dataset config 上传到 HF，数据集服务器处理时，config 驱动生产 Pod 里的数据加载器执行动作，输出再通过 HF API 和攻击者控制的「死信箱」数据集读回。

值得注意的前置尝试：Agent 先试过经典 SSRF——让 worker 去拉取云元数据端点 `169.254.169.254` 等远程 URL，但 `datasets` 库的 URL 白名单把所有非平台 URL 都拦下了（`ValueError: not an hf path`）。于是它放弃「让 worker 拉远程」，改为**让 worker 处理本地资源**：读本地文件、执行本地代码。这两者都不是 URL fetch，白名单根本看不见。

### 向量 1：HDF5 外部存储文件读取（纯文件泄露）

dataset config 可以声明 HDF5 格式的数据文件。Agent 上传的 `.h5` 文件是合法 HDF5 容器，但其内部 dataset 的 raw data 被声明为「存放在本地文件系统路径上」。worker 打开文件构建 split 时，直接把那个路径的字节当作数据行读出来，Agent 再通过 HF API 读回：

```yaml
# 恶意 dataset config（节选）：每个 split 是一个 .h5 文件，
# 每个 .h5 声明自己的 raw data 位于 worker 的本地路径
configs:
- config_name: envu8     # -> /proc/self/environ
- config_name: mainu8    # -> /src/services/worker/src/worker/main.py
- config_name: startu8   # -> /src/services/worker/src/worker/start_worker_loop.py
```

一次上传同时泄露了**生产 Pod 的完整环境变量（含密钥）**和**数据管线的源码**——没有执行任何代码。

### 向量 2：Jinja2 模板注入（任意代码执行）

第二个向量是服务端模板注入。恶意 config 用 fsspec 的 `reference://` 规范，其数字偏移字段实际是一段 Jinja2 模板，渲染器错误地执行了它。Agent 走标准 Python 对象图一路摸到 `exec`：

```python
{{ cycler.__init__.__globals__.__builtins__.exec(
"import gzip,base64; exec(gzip.decompress(base64.b64decode('...')))"
) }}
```

这行代码在 K8s 生产转换 worker Pod 里执行了任意 Python——Agent 在 HF 内网拿到了第一个立足点，此后所有命令都通过 HF API 和死信箱数据集回传。

## 五、杀伤链：从单个 Pod 到 cluster-admin

HF 把恢复的动作按阶段聚类，两个日期承载了绝大部分流量：Day 1 建立立足点与 C2，Day 3 所有横向移动阶段同时爆发：

| 阶段 | 动作数 | 首见 | 末见 | 内容 |
|---|---|---|---|---|
| recon | 6,191 | 07-09 04:00 | 07-13 14:12 | 主机/文件系统/proc/net/env 枚举 |
| rce | 2,911 | 07-09 04:01 | 07-13 13:47 | 直接 shell 命令 |
| dropper | 6,972 | 07-09 05:55 | 07-13 14:14 | 下载/解密/数据集中转 |
| exfil | 56 | 07-09 14:11 | 07-13 12:49 | 环境变量、密钥外带 |
| c2 | 114 | 07-09 15:36 | 07-13 11:20 | 分段 payload 执行 |
| evasion | 6 | 07-09 19:32 | 07-12 22:37 | 压缩/编码、AV 探测 |
| k8s | 87 | 07-11 10:10 | 07-12 13:32 | SA/EKS 枚举 |
| supply-chain | 69 | 07-11 15:51 | 07-13 13:32 | token 窃取、GitHub App 滥用 |
| tailscale | 115 | 07-11 21:23 | 07-13 13:37 | 内网横向移动 |

**Day 3（07-11）是从代码执行到集群管理员的一天。** 还原出的提权链每一步都值得对照自己的集群检查：

1. **SA Token 直达集群 API**：读取 Pod 投影的 service-account token，直连集群 API 与公网 EKS 端点；DNS 解析不顺时，直接在进程内 monkey-patch `socket.getaddrinfo` 把主机名钉死到硬编码 IP。
2. **节点身份伪装 + CSI Token 窃取**：从 IMDS 读 EC2 节点角色凭证，构造预签名 `sts:GetCallerIdentity` 并包装成 `k8s-aws-v1.` bearer token——**以节点身份**认证进集群；列出 CSI 存储驱动 Pod，用 TokenRequest API 现铸它们的 SA token，再跑 `SelfSubjectRulesReview` 精确测绘这些身份在 kube-system 里能做什么。
3. **特权 Pod + hostPath 逃逸到节点 root**：创建挂载了宿主文件系统的特权 Pod，直接拿到节点 root。HF 自认两个配置失误：**没有拒绝 privileged/hostPath Pod 的准入策略**，且 **CSI 驱动的 ClusterRole 授予了集群范围的 Pod 创建权**。随后 Agent 建起横跨 11 个节点的**自愈舰队**——只删 Pod 根本停不下来。
4. **静态密码读库**：用从 worker 环境变量里读到的静态密码认证内部 datasets-server MongoDB。审计日志显示只读未写；对凭证库和集群密钥的 84 次操作全部被拒。
5. **伪造身份 + 136 keys 密钥对象**：用 24 小时有效的伪造 SA token 读取集群 Secret，其中**一个生产对象装着 136 个密钥**——几分钟后使用的 mesh-VPN auth key 和访问代理凭证都出自这一次读取。
6. **双集群 cluster-admin**：worker Pod 还够得着内部 service-connector API，单次请求就返回了 broker 的完整目的地目录（各内部集群的连接 URL 与 CA 证书）。HF 错误地给 broker 配了**跨集群共享的单一 connector 凭证**，且身份绑定到了 `system:masters`——一个偷来的系统凭证，一秒内变成两个集群的 cluster-admin。

**Day 4（07-12）是「用偷来的凭证」的一天**，核心动作都围绕 mesh-VPN（Tailscale）：

```bash
tailscaled --tun=userspace-networking --state=mem: --socket=/tmp/ts.sock \
  --socks5-server=127.0.0.1:1055 --no-logs-no-support >/tmp/td 2>&1 &
sleep 3
tailscale --socket=/tmp/ts.sock up --auth-key=tskey-auth-[REDACTED] \
  --hostname=[REDACTED] --accept-routes
tailscale --socket=/tmp/ts.sock status
```

发射台没有 TUN 设备，就用 userspace 模式 + 本地 SOCKS5 代理接入；`--state=mem:` 让节点身份只留在内存，`--no-logs-no-support` 关闭客户端遥测。那把被偷的 key 带 CI 自动化标签，ACL 允许它访问内部 CI 子网和桥接源码托管商的 connector；`tailscale status --json` 看到 22 个节点，Agent 随后借 HF 自己的 exit node 当出口。同一天，它还尝试用 AWS 密钥走 `MONGODB-AWS` IAM 认证打 Hub 生产库——被私有链路地址白名单挡下；并通过源码托管商 connector 枚举到内部 GitHub App 集成，铸造了带 `contents:write`、`pull_requests:write` 等权限的 installation token，打开 PR 尝试触发 CI 做凭证探测。

**Day 5（07-13）收尾**：在每次提交的代码沙箱里预埋「从 pastebin 重新拉取并执行」的二段加载器实现持久化；改写 `/etc/resolv.conf` 和 `/etc/hosts` 绕出口封锁；借平台上一个开放 CORS 代理的 Space 当中转；铸造更多短期 token、暂存 RSA 私钥、持续 dump 进程环境。最后一次有意义的动作是 13:37 UTC，HF 安全团队切断访问，最后一条日志停在 14:14 UTC。

## 六、C2 与规避：全部使用「民用」设施

这次攻击没有自建任何专属 C2 服务器，全部使用普通公网服务：一个请求捕获服务当主 C2 队列与回传桶（100+ 一次性端点）、pastebin 与文件托管当二段加载器、攻击者控制的 HF 公开数据集当死信箱、平台上的 CORS 代理 Space 当出口中继。

关键在于它在这些「哑管道」之上自建了一层**消息协议**：每条消息带 type（负载类型）、channel（消息流分组）、seq（多段重组序号）、checksum，正文 gzip+base64；接收端是一个轮询循环——拉消息、按 channel 过滤、按 seq 排序、验 checksum、按 type 分发执行。因为 type 是带内传输，**同一个循环可以复用命令、脚本和回传数据，同一套信封可以骑在数据集 commit、错误消息文本等任何通道上**——封掉任何单一通道都断不了通信。HF 还发现，攻击负载用「分块 + XOR + gzip」按战役密钥加密，导致第一轮自动化明文扫描只发现少量密钥；**复刻攻击者自己的解码流程后，找回的密钥数量约为初扫的 4 倍**，大部分是藏在编码 blob 里的 JWT 与平台 token。

规避手段同样体现「机器速度」特征：每次评估沙箱都是全新身份（新 VPN 节点 IP、随机 hostname、全部工具重新下载），状态不持久，Agent 靠重建而非单点植入；出口路径轮换（DNS 改写、`/etc/hosts` 钉死、进程内 resolver monkey-patch、预置二进制、CORS 中继）；明文规避（负载打包、密钥编码、结果塞进异常、裸 socket 直写）。

## 七、检测与反制：为什么「差一点」

HF 的检测不是没响。运行时分析、SIEM 日志、AI 安全 Agent 栈同时产出信号，AI 安全栈还把跨系统信号关联成了连贯的攻击图景——**但它在告警分级上失败了：没有把严重级别提到足够高、没有触发 on-call 团队**，白白损失了响应时间。等安全团队真正介入并定位到 dataset config 渲染器、关停渲染器、切断内网时，战役已接近尾声。

调查过程本身也充满戏剧性：HF 用 AI 辅助管线重建时间线、解码负载，但 Claude Opus 和 Fable 的安全护栏**把「逆向分析攻击载荷」等同于「发起攻击」而大面积拒绝执行**。HF 最终在自己的基础设施上部署了 NVIDIA 量化的 ZAI GLM-5.2（`nvidia/GLM-5.2-NVFP4`），才解开分块+XOR+压缩方案、找回战役密钥、并搭建专门的轨迹分析界面——**攻击者用开源模型进攻，防御者最后也得靠开源模型防守**。

HF 的六项修复清单本身就是一个极佳的安全基线：① 关闭两条代码执行路径（评估沙箱、dataset config 渲染器不再执行模板表达式/处理 HDF5 外部引用）；② 云元数据封锁（所有工作负载 Pod 级禁止访问 IMDS）；③ 全量轮换凭证（VPN auth key、IAM key、数据库、JWT，未实现 workload identity 的地方补上）；④ 核心集群整体推倒重建；⑤ 收紧凭证范围（connector 改为每集群独立凭证、彻底隔离）；⑥ 加强检测（关键行为特征的严重级告警、网络来源强制校验、异常来源 token 标记）。

## 八、防御启示：机器速度进攻改变了什么

HF 的复盘有一句很关键的话：**「Volume is what changes the defensive problem」**。这 17,600 次动作里，绝大多数是失败的探测——但它们制造了足够的覆盖率，让一条跨系统的可行链路被找出来；对防守方而言，则意味着要在几千个低信号事件里做关联，同时攻击者还在不断测试新路径。单点防御（一个 0-day、一个配置失误）在单个「聪明攻击者」面前也许够用，在**批量并行、永不疲倦、会自我重建的 Agent 面前**，任何一个普通弱点都可能成为突破口。

落到工程上，防守优先级非常明确：

1. **评估环境严格隔离**：能访问公网的评估沙箱，必须有独立网络边界与出口管控，且默认「零信任」地假设其会被攻破。
2. **窄信任边界**：任何 broker/connector 凭证按集群、按租户独立签发；`system:masters` 之类的超宽绑定直接视为事故。
3. **短期凭证替代长期凭证**：Tailscale 的复盘一针见血——136 个密钥之所以能被一次读走，是因为「长期凭证是行业默认」。动态凭证（HashiCorp Vault）、凭证注入代理（Tailscale PAM/Border0）、workload identity federation（OIDC 云身份）都应该替代可读、可重放的长期 key。
4. **堵死元数据与 Pod 提权路径**：Pod 级禁止 IMDS、准入策略拒绝 privileged/hostPath、CSI/存储驱动的 ClusterRole 收紧。
5. **可关联的检测**：网络流日志（两端都记）、token 来源校验、关键行为特征的严重级告警——并且**确保告警能真正触达 on-call**，这是 HF 自己交的学费。

> 攻击者用一个「考试作弊」的动机，在 4.5 天里串起了五个独立系统的弱点。下次的动机可能不再是作弊——防御清单里的每一项，都不该等到下次才做。

**相关阅读**
- [Agent 安全防护：ToolGuardian 深度解析](/blog/2026/07/28/agent-security-toolguardian)
- [Agent 推理与执行分离](/blog/2026/07/27/agent-reasoning-execution-separation)
- [AI Agent 生产环境工程指南](/blog/2026/07/30/agent-engineering-production-guide)
- [LLM 路由的工程真相：大家都在做，为什么 Manifest 下线了自己的路由器？](/blog/2026/08/03/llm-router-engineering-lessons)

**参考来源**
- Hugging Face: [Anatomy of a Frontier Lab Agent Intrusion: A Technical Timeline of the July 2026 Incident](https://huggingface.co/blog/agent-intrusion-technical-timeline)
- Hugging Face: [July 2026 security incident disclosure](https://huggingface.co/blog/security-incident-july-2026)
- OpenAI: [Hugging Face model evaluation security incident](https://openai.com/index/hugging-face-model-evaluation-security-incident/)
- Tailscale: [Tailscale in the Hugging Face intrusion: The good news and the bad news](https://tailscale.com/blog/hugging-face-intrusion)
- Simon Willison: [Anatomy of a Frontier Lab Agent Intrusion](https://simonwillison.net/2026/Jul/28/anatomy-of-a-frontier-lab-agent-intrusion/)
