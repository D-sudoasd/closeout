# closeout 技能安装说明

Grok 的「收工 / 收尾 / ship」skill。版本见 `VERSION`。  
源码：https://github.com/D-sudoasd/closeout

## 需要环境

- 已安装 **Grok**（带 skills 的客户端）
- **git**；做 PR / 合并需要 **GitHub CLI (`gh`)** 且已登录
- **PowerShell 7+**（`pwsh`）以运行 `status.ps1` / `cleanup_temp.ps1` / `closeout.ps1`
- Windows 优先；其他平台需自备 `pwsh`

## 推荐：git clone（便于更新）

```powershell
$dst = Join-Path $env:USERPROFILE ".grok\skills\closeout"
git clone https://github.com/D-sudoasd/closeout.git $dst
# 升级：
# git -C $dst pull
```

首次使用可复制 `USER.example.md` → `USER.md` 再按需改偏好（`USER.md` 已被 `.gitignore`，不会进仓库）。

## 备选：install.ps1（保留用户配置）

1. clone 或解压得到本仓库根目录（含 `SKILL.md`、`scripts/`、`references/`）。
2. 运行：

```powershell
pwsh -File .\install.ps1 -Source .
# 默认安装到:
#   $env:USERPROFILE\.grok\skills\closeout
```

安装器会：

1. 校验源目录必要文件  
2. 将旧版本移到 `closeout.backup-<时间>`  
3. 复制新版本  
4. **保留已有 `USER.md`**（不覆盖个人偏好）  
5. 若无 `USER.md`，从 `USER.example.md` 复制  
6. 运行 `scripts/self_check.ps1`  
7. 失败时尝试恢复 backup  

**不要**再使用旧文档里的 `Remove-Item $dst -Recurse -Force` 整目录硬删（会丢掉 USER 配置）。

## 手动复制（不推荐）

若必须手动复制，请先备份：

```powershell
$dst = Join-Path $env:USERPROFILE ".grok\skills\closeout"
# 先备份 USER.md，再覆盖其他文件
```

## 目录结构

```text
closeout/
  SKILL.md
  USER.example.md         # 随包发布，可被升级覆盖
  USER.md                 # 本机偏好，升级保留
  VERSION
  CHANGELOG.md
  install.ps1
  PACK_INFO.txt
  INSTALL.md
  references/
  scripts/
    common.ps1
    status.ps1
    prune_merged.ps1
    cleanup_temp.ps1
    closeout.ps1
    self_check.ps1
```

## 安装后自检

```powershell
$root = Join-Path $env:USERPROFILE ".grok\skills\closeout"
pwsh -File (Join-Path $root "scripts\self_check.ps1")
# 在任意目录，对目标仓库传绝对路径：
# pwsh -File (Join-Path $root "scripts\status.ps1") -RepoRoot D:\path\to\repo
# 完整流程：先生成外部计划，确认后 Apply；失败后使用 state.json 续跑：
# pwsh -File (Join-Path $root "scripts\closeout.ps1") -RepoRoot D:\path\to\repo -Plan
# pwsh -File (Join-Path $root "scripts\closeout.ps1") -RepoRoot D:\path\to\repo -Apply -PlanFile <plan.json>
# pwsh -File (Join-Path $root "scripts\closeout.ps1") -RepoRoot D:\path\to\repo -Resume -StateFile <state.json>
# 或在目标仓库放置 closeout.verify.json：{"commands":["pwsh -NoProfile -File .\\scripts\\self_check.ps1 -SkillRoot ."]}
```

## 可选委托 skill

| 场景 | skill |
|------|--------|
| 硬 bug | diagnosing-bugs |
| 提交前自检 | 仓库测试（AGENTS.md → 包脚本 → CI → README） |
| 只 yeet 提交开 PR | yeet |
| PR CI 修红 | gh-fix-ci |
| 处理 review 评论 | gh-address-comments |

## 版本

见同目录 `VERSION` 与 `CHANGELOG.md`。分发包元数据见 `PACK_INFO.txt`（不含本机用户名/路径）。
