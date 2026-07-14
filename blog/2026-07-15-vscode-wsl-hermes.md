---
title: "Windows VSCode 调用 WSL 中的 Hermes Agent 实战"
date: 2026-07-15T12:00:00+08:00
draft: false
tags: ["vscode", "wsl", "hermes-agent", "ai", "workflow"]
categories: ["Tech"]
description: "在 Windows 上用 VSCode Remote - WSL 无缝调用 WSL 里的 Hermes Agent，打造 AI 原生编码体验"
---

## 背景

这套组合的出现有一个很现实的理由：

- **VSCode** 是 Windows 上最好的编辑器之一，生态丰富，Remote 插件体系成熟
- **WSL** 提供了完整的 Linux 开发环境，项目依赖、脚本、网络工具链都在 WSL 里
- **Hermes Agent** 跑在 Linux 上最顺畅，它需要访问项目的 Git 历史、文件结构、终端环境

所以很自然的，你会想让 VSCode 连进 WSL，然后在编辑器里直接和 Hermes 交互——写完代码让它审，遇到问题让它查，重构代码让它帮。

这篇文章就讲清楚这条路怎么打通，以及打通之后能怎么用。

{/* truncate */}

---

## 什么时候需要这套方案

先确认一下场景。如果你符合以下任意一条，这篇文章就是给你写的：

- **Windows 日常办公**，项目代码放在 WSL 文件系统（`~/projects/` 而非 `/mnt/c/`）
- **已经装了 Hermes Agent 在 WSL 里**，想在 VSCode 里方便地用它
- **不想为了 AI 辅助切换到完全不同的编辑器**（比如 Cursor），希望 VSCode 也能有类似的体验
- **想复用 VSCode 的插件生态**（GitLens、Error Lens、Live Share）同时享受 AI agent 能力

反之，如果你代码全在 Windows 原生盘（`C:\`）并且不打算搬，或者你已经在用 Cursor/VS Code Insiders with Copilot 且够用，那没必要折腾。

---

## 环境架构

```
┌─────────────────────────────────────────────┐
│  Windows 11/10                              │
│                                              │
│  ┌──────────────────┐   ┌─────────────────┐ │
│  │  VSCode (UI)     │   │  Edge / Chrome  │ │
│  │  Remote-WSL 插件  │   │  (Hermes 浏览器) │ │
│  └────────┬─────────┘   └─────────────────┘ │
│           │                                    │
├───────────┼─────────────────────────────────────┤
│  WSL (Ubuntu/Debian)                          │
│           │                                    │
│  ┌────────┴─────────┐                       │
│  │  VSCode Server   │                       │
│  │  (远程后端)       │                       │
│  └────────┬─────────┘                       │
│           │                                    │
│  ┌────────┴─────────┐  ┌──────────────────┐ │
│  │  Terminal        │  │  Hermes Agent    │ │
│  │  (zsh/bash)      │──│  (hermes 命令)    │ │
│  └─────────────────┘  └──────────────────┘ │
│                                              │
│  ┌──────────────────────────────────┐      │
│  │  项目代码 (~/projects/)          │      │
│  │  Git 历史 · 依赖 · 构建          │      │
│  └──────────────────────────────────┘      │
└─────────────────────────────────────────────┘
```

VSCode 通过 Remote - WSL 插件在 WSL 中启动一个后端 Server，UI 仍然在 Windows 上渲染。Terminal 自然也是 WSL 里的 shell。这时候在终端里敲 `hermes`，调的就是 WSL 里的 Hermes Agent。

---

## 安装与配置

### 1. WSL 里安装 Hermes Agent

假设 WSL 已经装好。在 WSL terminal 里：

```shell
# 安装 hermes CLI（以官方方式为准）
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | sh

# 确认安装成功
hermes --version

# 初始化配置（如果第一次用）
hermes setup
```

安装完成后，`hermes` 命令在 WSL 的 `$PATH` 中可用。建议加到 `~/.zshrc` 或 `~/.bashrc` 里。

### 2. VSCode 插件安装

Windows 上的 VSCode 装两个插件就够了：

| 插件 | 作用 |
|------|------|
| **Remote - WSL** (ms-vscode-remote.remote-wsl) | 连入 WSL 环境 |
| **Remote Explorer** (ms-vscode.remote-explorer) | 方便切换 WSL 实例 |

装好后，左下角状态栏应该有一个绿色的 `>< WSL: Ubuntu` 按钮，点它或者按 `Ctrl+Shift+P` → `Remote-WSL: Open Folder in WSL` 打开项目。

### 3. 确认连通

VSCode 终端 (`Ctrl+`` `) 里跑：

```shell
hermes --version
# 应该输出版本号，而不是 "command not found"

hermes --help
# 看到帮助信息即 OK
```

---

## 核心用法

### 基础：终端里直接调 Hermes

最直接的方式就是在 VSCode 终端里像用任何 CLI 工具一样用 Hermes：

```
# 让 Hermes 分析当前项目
hermes "分析一下这个项目的架构"

# 代码审查
hermes "帮我在 git diff 的基础上做 code review"
```

但这样每次都要切窗口打字，体验不够流畅。下面几个方法能大幅提升效率。

### 进阶一：VSCode Tasks 自动化

VSCode Tasks 允许你定义可重复执行的命令，绑定快捷键或通过命令面板触发。

在项目根目录创建 `.vscode/tasks.json`：

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Hermes: Code Review",
      "type": "shell",
      "command": "cd ${workspaceFolder} && git diff --cached | hermes 'Review this diff for bugs, security issues, and style problems. 用中文回复'",
      "group": "none",
      "problemMatcher": []
    },
    {
      "label": "Hermes: 分析当前文件",
      "type": "shell",
      "command": "hermes '分析 ${file} 的代码结构和潜在问题'",
      "group": "none",
      "problemMatcher": []
    },
    {
      "label": "Hermes: 项目架构总览",
      "type": "shell",
      "command": "hermes '阅读项目结构，给一份整体架构文档，包括目录设计、数据流、核心模块职责'",
      "group": "none",
      "problemMatcher": []
    },
    {
      "label": "Hermes: 生成单元测试",
      "type": "shell",
      "command": "hermes '为 ${file} 生成 pytest 单元测试'",
      "group": "none",
      "problemMatcher": []
    }
  ]
}
```

用法：`Ctrl+Shift+P` → `Tasks: Run Task` → 选一个即可。

### 进阶二：快捷键绑定

把常用的 Hermes 任务绑定到自定义快捷键。

在 `keybindings.json`（`Ctrl+Shift+P` → `Preferences: Open Keyboard Shortcuts (JSON)`）里加：

```json
[
  {
    "key": "ctrl+shift+h",
    "command": "workbench.action.tasks.runTask",
    "args": "Hermes: Code Review"
  },
  {
    "key": "alt+h",
    "command": "workbench.action.terminal.sendSequence",
    "args": {
      "text": "hermes '${selectedText}'\n"
    }
  }
]
```

第二个快捷键非常实用——**选中一段代码，按 `Alt+H`，自动把选中文本作为问题发给 Hermes**。比如选中一个函数签名，按 `Alt+H`，Hermes 会收到这条函数并分析它的设计。

### 进阶三：VSCode 命令面板集成

如果你想要更灵活的输入界面，可以装一个 **Command Variable** 或 **Multi Command** 插件来构建交互式任务，但个人体验下来，Tasks + 快捷键已经覆盖 90% 的需求——用快捷键直接发送选中文本是最顺手的。

---

## 高频实战场景

### 场景 1：Git commit 前自动审查

pre-commit hook 里调 Hermes 做代码审查：

```shell
# .git/hooks/pre-commit
#!/bin/bash
git diff --cached | head -c 8000 | hermes \
  'Review the following git diff for bugs and security issues. \
   Reply "OK" if clean, or list issues if found. 用中文回复。'
```

这适合单人项目或小团队。大项目建议只审查增量 DIFF 的前 8000 字符，避免卡死。

### 场景 2：重构辅助

在 VSCode 中选中要重构的代码段，按 `Alt+H`：

```
hermes '重构以下代码，提炼公共逻辑，减少重复，保持可读性'
```

Hermes 会给出重构后的代码，你可以直接复制粘贴验证。

### 场景 3：快速理解不熟悉的代码

打开一个陌生文件，用快捷键或 Tasks：

```
hermes '解释 ${file} 的核心逻辑和设计模式'
```

对于遗留系统或者同事写的代码，这比逐行读快得多。

### 场景 4：项目级技术债务分析

```shell
hermes '扫描项目，识别技术债务：过时的依赖、未使用的导入、潜在的性能瓶颈、违反单一职责的函数。'
```

Hermes 会基于项目文件树和代码内容给出全局视角的分析。

---

## 踩坑记录

### 1. 路径问题——代码放哪

**WSL 文件系统以外（`/mnt/c/`）性能差很多。** 跨文件系统的 IO 操作（`ext4 ←→ NTFS`）会走 DrvFS 翻译，git status 慢几倍，Hermes 读文件也会延迟。

**最佳实践：代码放在 `~/projects/`（WSL 原生 ext4），不要放在 `/mnt/c/Users/...`。**

但如果你需要在 Windows 上通过 Explorer 直接访问代码，可以在 Windows 里用 `\\wsl$\Ubuntu\home\用户名\projects\` 访问——这是 WSL 的 9P 协议网络共享路径。

### 2. 环境变量不一致

Windows 的 PATH 和 WSL 的 PATH 是独立的。在 VSCode 终端里能跑 `hermes` 不代表在所有 shell 里都能——确保：

```shell
# ~/.zshrc 或 ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
```

如果 Hermes 用了 `.env` 或者环境变量（API Key 等），也确认它们被加载。

### 3. 代理配置

Windows 的代理设置不会自动同步到 WSL。如果你在 Windows 上走代理：

```shell
# ~/.zshrc
export http_proxy="http://127.0.0.1:7890"
export https_proxy="http://127.0.0.1:7890"
```

注意 WSL 的 `127.0.0.1` 指向的是 WSL 自己的 loopback，不是 Windows 的。要连接 Windows 上的代理，需要用 Windows 的 WSL 虚拟网卡 IP：

```shell
# 在 WSL 里获取 Windows 的 WSL 网卡 IP
cat /etc/resolv.conf | grep nameserver | awk '{print $2}'
# 比如输出 172.x.x.x

# 然后在 .zshrc 里
export http_proxy="http://172.x.x.x:7890"
```

### 4. git 换行符

Windows 默认 `core.autocrlf=true`，WSL 里应该设 `input` 或 `false`，否则 git diff 会看到大量 `^M` 换行符，污染 Hermes 的 diff 输入：

```shell
git config --global core.autocrlf input
```

### 5. VSCode 终端类型

VSCode 内置终端默认继承 Windows 的环境变量。通过 Remote-WSL 连入后，它启动的是 WSL 的 shell，这时候 `echo $SHELL` 应该是 `/bin/zsh` 或 `/bin/bash`。如果发现 `hermes` 找不到，排查一下：

```shell
# 看看 PATH 对不对
echo $PATH | grep -o 'hermes\|\.local/bin'
```

### 6. Windows 下 VSCode 自体终端 vs Remote-WSL 终端

| 对比维度 | 原生 VSCode 终端 | Remote-WSL 终端 |
|---------|----------------|----------------|
| Shell 类型 | PowerShell / CMD | bash / zsh |
| Hermes 可用 | ❌ (除非你在 Windows 也装了) | ✅ |
| 文件路径 | `C:\...` | `/home/...` |
| git 行为 | Windows 换行符 | Linux 换行符 |

**一定要在 Remote-WSL 窗口中打开终端，而不是本地窗口。** 看左下角状态栏：绿色 `>< WSL: Ubuntu` 就是对的。

---

## 效果对比：有 / 没有这套方案

| 场景 | 之前 | 之后 |
|------|------|------|
| 做 code review | 手动逐行看 diff | `Ctrl+Shift+H` → Hermes 审完报结果 |
| 不熟悉的代码 | 打开文件逐行读 | 选中 → `Alt+H` → 问 Hermes |
| 写新模块 | 新建文件照着模板写 | 写接口签名 → Hermes 生成骨架 |
| 定位 bug | 加 print/log 跑几次 | 描述症状 → Hermes 给出怀疑位置 |
| 重构 | 手动梳理调用关系 | Hermes 先给依赖图和分析 |

核心变化不是 Hermes 替你写了多少代码，而是 **从"遇到问题自己查"变成"遇到问题问 Hermes"**，且整个交互不离开编辑器。

---

## 一张图总结

```
Windows
  └── VSCode (UI + 插件)
        │
    Remote-WSL 连接
        │
        ▼
WSL (Ubuntu)
  ├── VS Code Server (后端)
  ├── Hermes Agent (CLI)
  ├── Git / 构建工具
  └── 项目代码 (~/projects/)

快捷键:
  Ctrl+Shift+P → Tasks → 选 Hermes 任务
  Alt+H        → 选中代码直接问 Hermes
  Ctrl+Shift+H → 快捷 Code Review
```

这套方案最大的价值不是省了多少时间，而是**降低了使用 AI agent 的门槛**——不用切窗口、不用开网页、不用复制粘贴代码。Hermes 就在你的终端里，快捷键一按就能用。

如果你也在用 VSCode + WSL 的组合，不妨花十分钟配一下。之后每天写代码都会感觉顺手很多。
