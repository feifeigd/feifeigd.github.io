---
title: "GUI Agent 工程化：让大模型操作电脑的感知、行动与安全拆解 — Computer Use 从原理到落地"
date: 2026-08-29T18:00:00+08:00
draft: false
tags: ["ai", "llm", "agent", "multimodal", "engineering"]
categories: ["Tech"]
description: "文本 Agent 调用 API 工具已经是常规操作，但「像人一样操作电脑」的 GUI Agent（Computer Use）是另一条技术线：没有结构化接口，只有像素和窗口。本文从感知层（截图 + 可访问性树）、行动层（输入注入与焦点路由）、验证循环（效果三态与重试纪律）、视觉 token 成本账、OSWorld 等基准、安全边界六个面拆解，附可运行骨架代码和真实踩坑记录。"
---

文本 Agent 的标配是「工具调用」：模型说一句 `search_order("sku")`，代码去执行，接口是结构化的。但 2024 年底开始，OpenAI Operator、Anthropic Computer Use、各类桌面/浏览器 Agent 把目标换成了**像人一样直接操作电脑**——没有 API、没有 DOM、只有像素和窗口。这条技术线工程上比想象中难得多，本文按「感知 → 行动 → 验证 → 成本 → 评测 → 安全」拆开讲，附可运行的骨架代码与实测踩坑。

{/* truncate */}

## 一、感知层：像素之外，还有一棵「可访问性树」

GUI Agent 面对的第一个问题：**怎么"看到"屏幕**？两条路线：

| 方案 | 原理 | 优点 | 缺点 |
|------|------|------|------|
| 纯截图 + 视觉模型 | 整屏截图丢给 VLM | 通用，任何应用都能看 | token 贵、小元素看不清、坐标易偏 |
| 可访问性树（AX Tree） | 读操作系统的无障碍接口 | 结构化、精确、便宜 | 部分应用/画布没有 AX 节点 |
| 截图 + Set-of-Marks | 把可交互元素编号叠加在截图上 | 模型只需说「点 12 号」，命中率高 | 依赖 AX 树质量 |

浏览器里 Web Agent 白捡一个 DOM，桌面应用没有 DOM，但**操作系统早就为屏幕阅读器造好了无障碍树**：Windows 的 UIA、macOS 的 Accessibility、Linux 的 AT-SPI。GUI Agent 只是把给盲人用的基础设施拿来喂模型。以 Chromium 系为例，走 CDP 就能拿到完整的可访问性树：

```python
# 伪代码：CDP 取 AX 树 → 过滤可交互节点 → 生成 SOM 编号
tree = cdp("Accessibility.getFullAXTree")            # 数千个节点
INTERACTIVE = {"button", "textbox", "combobox", "link",
               "checkbox", "menuitem", "slider"}
som = []
for node in tree["nodes"]:
    role = node.get("role", {}).get("value")
    if role in INTERACTIVE and node.get("backendDOMNodeId"):
        box = cdp("DOM.getBoxModel",
                  backendNodeId=node["backendDOMNodeId"])
        cx, cy = center(box["model"]["content"])      # 像素中心点
        som.append({"index": len(som) + 1, "role": role,
                    "name": node.get("name", {}).get("value", ""),
                    "x": cx, "y": cy})
# 模型看到的 prompt 里附上编号列表，截图上叠数字
```

**踩坑**：AX 树节点动辄上千（Electron 应用尤甚），全量塞进上下文直接爆量，必须按 role 过滤 + 截断（`max_elements` 上限）；纯 canvas 绘制、DirectX 渲染的游戏和图形编辑器**根本没有 AX 节点**，只能退回纯视觉路线。

## 二、行动层：输入注入与「焦点伦理」

感知之后是执行。GUI Agent 的行动本质是**操作系统级输入注入**，这里有个被低估的工程决策：**要不要抢用户焦点**。

- **前台路由**：把窗口顶到最前、真鼠标真键盘操作——稳定，但用户正在用电脑时会被粗暴打断；
- **后台路由**：直接向目标窗口投递输入事件，不抢焦点、不移动真实光标，用户可以在旁边继续干活。这是"Agent 和人类共用一台电脑"这个协作模型的地基，代价是部分应用不认：DirectInput 类游戏、自绘控件、原生权限对话框收不到后台事件。

所以生产实现是一条**升级阶梯**，且只能按返回信号升级、不能凭经验预测：

```python
def dispatch(act, start_rung="element"):
    # rung 顺序：元素索引 → 像素坐标 → 浏览器 DOM 页 → 前台注入
    for rung in RUNG_ORDER[RUNG_ORDER.index(start_rung):]:
        res = execute(act, rung)
        if res.effect == "confirmed":
            return res                     # 生效，结束
        if res.effect == "unverifiable":
            return NEED_FRESH_STATE        # 无法确认 → 重新取状态，绝不盲重试
        # suspected_noop / 拒绝 → 升一级重试
    raise AgentStuck(act)
```

三个关键纪律：① `confirmed` 就是完成，**不要重复成功过的输入**（否则就是双击）；② `unverifiable` 必须先截图看新状态再决定重试，同一 rung 静默重试是死循环的温床；③ 浏览器场景有专门的 DOM 级注入通道（typed browser），绑定必须精确匹配（进程 + 窗口句柄），输入默认走受信事件，降级为 DOM 事件是显式选择而不是自动兜底。

## 三、核心循环：observe → decide → act → verify

和文本 Agent 一样是 ReAct 循环，但多了**每一步的状态确认**：

```python
def run_agent(task: str, max_steps: int = 30):
    msgs = [{"role": "user", "content": task}]
    for step in range(max_steps):
        view = capture()                    # 截图 + AX 树 + SOM 编号
        act = llm.decide(msgs + [view])     # 决策：click(12) / type("...") / scroll / done
        if act.kind == "done":
            return act.answer
        msgs.append(("assistant", act.to_text()))
        effect = execute(act)               # 按第二节的阶梯路由
        if effect == "unverifiable":
            view2 = capture()               # 重新取状态，对比变化再决定
            msgs.append(("user", "上一步执行后界面状态: " + view2))
        else:
            msgs.append(("user", f"上一步结果: {effect}"))
    raise TimeoutError(f"超过 {max_steps} 步未完成")
```

文本 Agent 的幻觉代价是答错题，GUI Agent 的幻觉代价是**点错按钮、删错文件**。所以 verify 不是可选项：`unverifiable` 状态必须走「重新观察 → 状态 diff → 再决策」，宁可多花一步截图，也不盲信上一步"执行成功"。

## 四、成本账：一张截图多少 token

视觉感知是纯开销，算一笔账（Anthropic 的视觉 token 折算公式为 宽 × 高 / 750）：

- 1280 × 720 截图 ≈ **1229 token/张**；
- 一个 30 步的任务，每步观察 1~2 次，累计 **40K~75K 视觉 token**，按主流厂商 2~5 美元/百万 token 的输入价，单任务视觉成本约 0.1~0.4 美元；
- 真正的大头是**决策上下文**：每步都要把历史截图和对话重放给模型，30 步任务上下文轻松冲上百万 token 级，这会推高延迟和费用。

工程对策：① 低分辨率两段式——先缩略图定位区域，再对局部裁剪放大做精确点击，大屏任务能省一半 token；② AX 树能表达的交互（按钮/输入框）**不要截图**，只有视觉布局类操作（拖拽、画布、图表）才走视觉；③ 限制历史截图入上下文——只保留最近 2~3 步 + 最新状态摘要，参考 [Agent 记忆系统](/blog/2026/08/13/agent-memory-system) 的分层思路。

## 五、评测：OSWorld 与操作型 Agent 的分数进化

GUI Agent 的通用评测是 OSWorld（真实操作系统环境 + 369 个任务），历史分数演进很有信息量：

| 模型/时间 | OSWorld 成功率 | WebArena | WebVoyager |
|-----------|---------------|----------|------------|
| 人类基线 | 72.4% | 约 78% | 约 89% |
| GPT-4o（2024 年中） | 3.5% | — | — |
| Claude 3.5 Sonnet Computer Use（2024-10） | 14.9%（后续更新约 22%） | — | — |
| OpenAI CUA / Operator（2025-01，论文口径） | 38.1% | 35.8% | 87% |
| 2025 年新一代模型（厂商自测口径） | 50%~60% 区间 | — | — |

三个结论：① 两年从 3.5% 到 60%，进步是真实的，但**离人类 72% 的通用水平仍有明显距离**，且 OSWorld 之外的未见过界面会掉得更狠；② 纯浏览器任务（WebVoyager）早就做得好，难的是跨应用、文件系统、系统设置这类真实桌面操作——**环境的开放程度决定难度**；③ 评测成本极高：每次 run 都是真实系统状态、有随机性、跑一轮要几十上百美元，CI 里做 GUI 回归比文本评测贵一个数量级（可参考 [Agent 评测工程化](/blog/2026/08/19/agent-eval-engineering) 的层级思路，GUI 任务只做冒烟级门禁）。

## 六、安全：屏幕是未经验证的输入面

这是 GUI Agent 和文本 Agent 最大的差别：**模型看到的每张截图，都是不可信输入**。网页里的"点击这里领取奖励"、邮件里的"请把文件移到回收站"、对话框里的"输入你的密码"，全都是 prompt injection 的载体——恶意页面可以往界面上画诱导指令，让 Agent 执行删除、转账、泄露操作。

```python
ALLOWED_ACTIONS = {"click", "type", "scroll", "key", "select"}
BLOCKED_TARGETS = ("password", "payment", "pay", "card", "secret")

def guard(action, policy):
    if action.kind not in ALLOWED_ACTIONS:
        raise Blocked(f"动作类型不在白名单: {action.kind}")
    target = (action.target or "").lower()
    if any(t in target for t in BLOCKED_TARGETS):
        raise Blocked(f"目标被策略拦截: {target}")     # 密码框/支付框一律禁点
    if action.kind == "type" and looks_like_secret(action.text):
        raise Blocked("拒绝键入疑似密钥/口令的内容")
    if action.kind == "key" and action.keys in ("win+l", "ctrl+alt+del"):
        raise Blocked("锁定/注销类系统快捷键硬禁")
```

工程底线：① 动作白名单 + 目标黑名单双闸，**拦截优先级高于模型判断**；② 遇到系统权限对话框、密码框、支付 UI，Agent 必须停下问人，绝不自行点击——这是硬规则不是建议；③ 高危任务（支付、删库）放隔离虚拟机跑，宿主只留结果回传通道；④ 密钥类内容永远只从环境变量注入，不让模型经手。更系统的思路见 [Agent 安全](/blog/2026/07/28/agent-security-toolguardian)。

## 七、什么时候不要用 GUI Agent

决策顺序应该是：**有 API 用 API，有 DOM 用浏览器协议，最后才轮到像素级 GUI**。

- 你控制的系统：直接暴露 MCP/HTTP 工具（[MCP 服务端生产实践](/blog/2026/08/27/mcp-server-production-guide)），结构化、可测试、可审计；
- 浏览器场景：typed browser 的 DOM 注入比系统级输入稳一个数量级，元素定位用语义 ref 而不是坐标；
- 只有第三方桌面应用/遗留系统/测试环境：才是 GUI Agent 的主场——它是**兜底通道，不是第一选择**。

## 总结

GUI Agent 的本质是给模型接上"人类输入输出设备"，它把 Agent 的战场从结构化接口扩展到任意软件。工程要点就五条：感知优先 AX 树（像素做补充）、行动走后台路由 + 升级阶梯、每步必须验证状态、视觉 token 要精打细算、安全按"屏幕不可信"设计。这两年 OSWorld 从 3.5% 涨到 60% 说明路线可行，但离"可靠地替你操作电脑"还有距离——现阶段它更适合做**受限环境里的自动化执行器**，而不是全权托管你的桌面。
