# closeout

[![CI](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml/badge.svg)](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/pwsh-7%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)

**把活收完，桌子收拾干净。**

面向 AI agent 的 **git 收工技能**：状态 → 验证 → 提交 → 推送 → PR → 合并门禁 → 清分支。强调 **授权边界**、**squash 合并可识别**、以及可复核的 **证据报告**。

[English](README.md) · [变更记录](CHANGELOG.md) · [安装说明](INSTALL.md) · [授权矩阵](references/auth-matrix.md)

---

## 解决什么问题？

| 常见翻车 | closeout 的做法 |
|----------|-----------------|
| 盲 `git add -A` | 有意识暂存；跳过密钥 / 大批原始数据 |
| 验证红了还推 | 三态：停 / 只本地提交 / 二次明确授权才推 |
| squash 后清不掉分支 | PR `headRefOid` 与 tip 一致才可删 |
| 把 `origin/HEAD` 当分支名删 | `for-each-ref`，跳过符号引用 |
| 「展示了列表」= 授权删远程 | **展示 ≠ 授权**；合并与远程删除单独确认 |
| 命令失败却报告成功 | 检查退出码 + 删除后复查 |
| 升级技能冲掉个人配置 | 保留 `USER.md`，模板用 `USER.example.md` |

---

## 触发方式

对 agent 说：

- **收工** / **收尾** / **ship** / `/closeout` — 全流程  
- **提交并推** / **开 PR** / **合并** / **清分支** — 按模式子集  

---

## 安装

### Grok

```powershell
$dst = Join-Path $env:USERPROFILE ".grok\skills\closeout"
git clone https://github.com/D-sudoasd/closeout.git $dst
```

已有目录且是 git clone：在目录内 `git pull`。  
若本机已有非 git 安装，建议先备份 `USER.md`，再换成 clone，或使用：

```powershell
pwsh -File .\install.ps1 -Source .
```

重启会话后即可使用。

### 依赖

- **git**
- **PowerShell 7+**（`pwsh`）
- **GitHub CLI (`gh`)**（PR / 合并 / squash 分支识别）

---

## 脚本速用

```powershell
$Skill = Join-Path $env:USERPROFILE ".grok\skills\closeout\scripts"
$Repo  = "D:\path\to\repo"

pwsh -File "$Skill\status.ps1" -RepoRoot $Repo
pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo          # 默认 dry-run
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply -DeleteRemote
```

---

## 清分支判定（v2）

```text
tip 是默认分支祖先          → 可删候选（普通 merge）
已合并 PR 且 headOid == tip → 可删候选（squash/rebase）
PR 已合但 tip 已变          → 禁止自动删
无法确认                    → 只报告
当前分支 / 默认分支 / HEAD  → 永不删
```

---

## 许可

[MIT](LICENSE) © 2026 D-sudoasd
