# Phases — commands and gates

Resolve default branch via `Get-DefaultBranch` in `scripts/common.ps1` (pass `-Prefer` from USER `default_branch_prefer`). That helper binds `gh` to `-RepoRoot`, not process cwd.

## 0 status / plan discovery

```powershell
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot <absolute-repo>
# optional machine-readable:
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot <absolute-repo> -Json
```

Report must include: root, branch, full/short HEAD, default, upstream, ahead/behind, staged/unstaged/untracked/conflicted counts, in-progress ops, redacted remotes, PR, tools, worktrees.
`closeout.ps1 -Plan` additionally records selected/excluded files, safe temp candidates, verification commands, PR context, and plan-listed prune targets in an external `plan.json`.

**Gate:** report exists. Read-only — no writes.

## 0b plan

Before any write op, `closeout.ps1 -Plan` shows:

```text
准备提交的文件 + diff --stat
可能密钥/大文件路径
提交信息草案
将推送的 remote/branch
将创建或复用的 PR
本次不会执行：force-push / reset --hard / clean -fdx / gh --admin / 计划外对象
计划外路径、分支、PR 和临时目录不会执行；full-run 的一次确认只覆盖这份计划。
```

**Gate:** user confirms the external plan. The confirmation covers only the listed actions; plan-listed merge and remote cleanup are included in full-run mode.

## 1 diagnose

**Delegate** skill `diagnosing-bugs` for hard/repro bugs.  
Light fix: tight repro → fix → re-run once.  
**Gate:** symptom gone or user defers.

## 2 verify

Record for each command: command, exit code, duration if known, pass/fail/skip, failure summary.

Minimum:

```powershell
git diff --check
git diff --cached --check
```

Do **not** require a `check-work` skill. Discover tests: AGENTS.md → package scripts → CI → README.  
The agent passes discovered commands through `-VerifyCommand`; standalone repositories may use `closeout.verify.json` with a `commands` array.
Scientific repos: staged size, raw data paths, binary accidents.

Outcomes: [auth-matrix.md](auth-matrix.md).  
**Gate:** all discovered commands and diff checks pass. If no repository-specific command exists, the plan is BLOCKED unless `-AllowNoTests` or USER `allow_no_tests=true` is present.

## 3 commit

```text
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
# stage intentionally — not blind secrets/raw
git add <paths>
git commit -m "<style from USER>"
```

Record: commit SHA, file count, message, pre_HEAD, post_HEAD.  
No `--no-verify` unless user insists.  
**Gate:** no intended changes left uncommitted (or listed as deferred).

## 4 push

```text
git push -u origin HEAD
# then verify:
git rev-parse HEAD
git rev-parse @{upstream}
```

Rebase path if needed; feature force only `--force-with-lease` + reason.  
Never force default branch.  
**Gate:** local HEAD SHA == remote tracking SHA (or no remote explained).

## 5 pr

Do **not** only `gh pr view || gh pr create`. Check:

```text
open PR for head?
closed-unmerged old PR?
base/head correct?
draft?
PR head SHA == just-pushed SHA?
```

```text
gh pr view --json number,url,state,baseRefName,headRefName,headRefOid,isDraft
# or create with body: problem → cause → fix → verify evidence
```

**Gate:** PR URL + recorded head SHA, or user skipped.

## 6 land (merge)

In full-run mode, merge is part of the confirmed plan. Targeted merge commands still honor `confirm_merge`.

Pre-merge checks:

```text
not draft
correct base
remote checks are recorded but are not polled in the selected fail-fast mode
reviewDecision per repo rules
mergeStateStatus allows merge
PR head SHA == expected
```

```text
gh pr view --json number,state,baseRefName,headRefName,headRefOid,mergeCommit
gh pr merge <number> --squash --match-head-commit <expected-head>
git fetch origin
git switch <default>
git pull --ff-only
```

**Gate:** default contains the change; evidence recorded.

## 7 prune

```powershell
pwsh -File "...\prune_merged.ps1" -RepoRoot <absolute-repo>           # dry-run list + evidence
# after user OK for local:
pwsh -File "...\prune_merged.ps1" -RepoRoot <absolute-repo> -Apply
# targeted remote cleanup needs a separate OK; full-run uses only plan-listed remote branches:
pwsh -File "...\prune_merged.ps1" -RepoRoot <absolute-repo> -Apply -DeleteRemote
```

The script reads USER `never_delete_branches` / `default_branch_prefer`. Classification is in `Classify-Branch` (ancestor **or** merged PR head SHA == tip).  
After `-Apply`, squash-SAFE locals are deleted even when `git branch -d` would refuse.  
Tip-moved after merge → HOLD.  
Remote list via `for-each-ref` (skip HEAD/symref).  
Each delete rechecked.  
Full-run passes `-OnlyBranches` so only the plan-listed branch is eligible for deletion. Open, closed-unmerged, tip-moved, current, default, never-delete, and worktree-locked branches remain untouched.
**Gate:** [clean-desk.md](clean-desk.md) or exceptions listed with reasons.

## full order

收工: `0 → 0b`; after one confirmation of the external plan: `2 → 3 → 4 → 5 → 6 → 7 → final`. Merge and plan-listed remote branch deletion are included only because they are explicitly listed in that plan.
Insert **1** when bugs remain.  
Verify fail without override: **stop**, no push of broken work.
