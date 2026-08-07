---
title: "用 Git 备份 Hermes Agent 的所有数据：Skills、Memory、Cron 与配置"
date: 2026-08-08T12:00:00+08:00
draft: false
tags: ["hermes", "git", "backup", "devops", "tooling"]
categories: ["Tech"]
description: "Hermes Agent 的 skills、memory、cron 和配置分散在 ~/.hermes 下。用 Git + .gitignore 精准备份核心数据，配合 cron 自动 push，告别『重装系统丢配置』的恐惧。"
---

Hermes Agent 用久了，积累的东西其实不少：几十个 skill、累积的 memory、多个 cron 定时任务、多个 profile 的 SOUL 定义。这些东西全放在 `~/.hermes/` 下面，重装系统或者换机器时，如果没备份，就得从头再来。

用 Git 做备份，比手动 `cp -r` 靠谱得多：有版本历史、能增量同步、还能推送到 GitHub 私有仓库做异地容灾。

{/* truncate */}

## 一、Hermes 哪些数据值得备份？

先看一眼 `~/.hermes/` 的结构和体积：

```
~/.hermes/
├── skills/         49M    ← 核心：所有 skill 定义
├── memories/       12K    ← 核心：跨会话持久记忆
├── cron/           3.5M   ← 核心：定时任务
├── profiles/       1011M  ← 谨慎：含 venv，不能全备
│   ├── coder/
│   ├── researcher/
│   ├── video-worker/
│   └── writer/
├── config.yaml     15K    ← 核心：主配置（含 API key！）
├── SOUL.md         513B   ← 核心：人格定义
├── auth.json       2.5K   ← 敏感：OAuth token
├── .env            20K    ← 敏感：环境变量
├── cache/                 ← 缓存，不备份
├── audio_cache/          ← 缓存，不备份
├── checkpoints/          ← 运行时，不备份
└── .hermes_history       ← 会话历史，太大了
```

结论很清楚：

| 备份 | 不备份 |
|------|--------|
| `skills/` | `profiles/*/venv/` |
| `memories/` | `cache/`, `audio_cache/` |
| `cron/` | `checkpoints/` |
| `config.yaml` | `.hermes_history`（189KB） |
| `SOUL.md` | `auth.lock` |
| profiles 下的 `SOUL.md`、skills、cron | 日志、临时文件 |

> ⚠️ **特别提醒**：`config.yaml` 和 `.env` 包含 API key，推送前务必确认仓库是**私有**的，或者用 `.gitignore` 排掉它们、单独用其他方式加密备份。

## 二、初始化 Git 仓库

直接在 `~/.hermes/` 下建仓库，用 `.gitignore` 精确控制：

```bash
cd ~/.hermes
git init
```

写 `.gitignore`：

```gitignore
# ===== 敏感文件 =====
config.yaml        # 含 API key，单独备份
.env               # 环境变量
auth.json          # OAuth token
auth.lock

# ===== 缓存 / 临时文件 =====
cache/
audio_cache/
checkpoints/
*.log
__pycache__/
*.pyc

# ===== 大体积运行时数据 =====
.hermes_history
.npm_lock_hash_*
.update_check
.skills_prompt_snapshot.json

# ===== Profiles 里的 venv（必须排除）=====
profiles/*/venv/
profiles/*/node_modules/
profiles/*/__pycache__/
profiles/*/cache/

# ===== 平台连接状态 =====
channel_directory.json
feishu_seen_message_ids.json
```

首次提交：

```bash
git add -A
git commit -m "init: Hermes data backup"
```

## 三、只备份 Profiles 的「灵魂」

`profiles/` 目录 1GB，但 99% 是 venv。真正值得备份的是每个 profile 的「元数据」：

```bash
# 每个 profile 下需要备份的文件
profiles/<name>/SOUL.md          # 人格定义
profiles/<name>/skills/          # profile 专属 skills
profiles/<name>/cron/            # profile 专属定时任务
profiles/<name>/memories/        # profile 专属记忆
```

venv 不需要备份——`requirements.txt` 或 `pip freeze` 就够了，换环境重新装比备份二进制文件快得多。

## 四、自动化：Cron 定时 Push

在 `~/.hermes/cron/` 下放一个脚本 `hermes-backup.sh`：

```bash
#!/bin/bash
cd ~/.hermes

# 自动提交所有变更
git add -A
git commit -m "auto backup $(date '+%Y-%m-%d %H:%M')" 2>/dev/null

# 推送到远程
git push origin main 2>&1
```

然后用 Hermes 自己的 cron 能力来定时执行：

```
每天 23:00 执行：bash ~/.hermes/cron/hermes-backup.sh
```

或者更简单，用 Linux cron：

```bash
# crontab -e
0 23 * * * cd ~/.hermes && git add -A && git commit -m "daily backup" && git push
```

## 五、远程备份：推送到 GitHub 私有仓库

本地 Git 只是版本历史，硬盘坏了照样丢。推到 GitHub 私有仓库才是真正的异地容灾：

```bash
# 在 GitHub 上创建一个 PRIVATE 仓库，比如 hermes-backup
git remote add origin git@github.com:you/hermes-backup.git
git push -u origin main
```

> 如果你已经把 `config.yaml` 放进了 `.gitignore`（推荐），那它的备份需要另一条路。我个人的做法是把 `config.yaml` 和 `.env` 放到一个单独的加密压缩包里，存到云盘。

## 六、恢复：在新机器上拉回来

```bash
# 1. 安装 Hermes（按官方文档）
# 2. 拉取备份
mv ~/.hermes ~/.hermes.old   # 备份旧的（如果有）
git clone git@github.com:you/hermes-backup.git ~/.hermes

# 3. 恢复敏感文件（手动放入 config.yaml, .env, auth.json）

# 4. 重建 venv（如果 profiles 里有 requirements.txt）
cd ~/.hermes
# pip install -r profiles/coder/requirements.txt  # etc.

# 5. 验证
hermes skills list
hermes cronjob list
```

搞定。所有 skills、memory、cron 和 SOUL 全部归位。

## 七、一个真实的数据量参考

我的 Hermes 实例运行了 3 个月后的备份体积：

| 内容 | 大小 |
|------|------|
| skills/ (20+ 个) | 49 MB |
| memories/ | 12 KB |
| cron/ | 3.5 MB |
| profiles/ (4 个，排掉 venv) | ~200 KB |
| SOUL.md + 其他 | ~10 KB |
| **合计** | **~53 MB** |

53MB，GitHub 私有仓库完全免费，push/pull 只要几秒。

## 总结

Git 备份 Hermes 数据的核心原则就三条：

1. **精准白名单**：只备份核心元数据（skills/memories/cron/SOUL/config），不备份运行时垃圾
2. **推远程**：本地 `.git` 不够，推到 GitHub 私有仓库才叫备份
3. **自动化**：用 cron 定时 `commit + push`，别指望自己记着

花 10 分钟搭好，换电脑重装系统就不用从头教 Hermes 做人。
