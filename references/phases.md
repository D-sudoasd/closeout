# Phases — commands and gates

Resolve default branch via `Get-DefaultBranch` in `scripts/common.ps1` (pass `-Prefer` from USER `default_branch_prefer`). That helper binds `gh` to `-RepoRoot`, not process cwd.

## 0 status

```powershell
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot <absolute-repo>
# optional machine-readable:
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot <absolute-repo> -Json
```

Report must include: root, branch, full/short HEAD, default, upstream, ahead/behind, staged/unstaged/untracked/conflicted counts, in-progress ops, redacted remotes, PR, tools, worktrees.

**Gate:** report exists. Read-only — no writes.

## 0b plan

Before any write op, show:

```text
准备提交的文件 + diff --stat
可能密钥/大文件路径
提交信息草案
将推送的 remote/branch
将创建或复用的 PR
本次不会执行：merge / remote delete / force
```

**Gate:** user confirms the plan, or USER `confirm_push=false` and the mode is 收工 for the listed push/PR items only. Merge and remote delete are never in that OK.

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
Scientific repos: staged size, raw data paths, binary accidents.

Outcomes: [auth-matrix.md](auth-matrix.md).  
**Gate:** pass, or explicit user policy for fail (local-only vs push override).

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

Only if `confirm_merge` false **or** user said 合并/merge, or `auto_merge_when_green` and checks green.

Pre-merge checks:

```text
not draft
correct base
required checks finished, none failing
reviewDecision per repo rules
mergeStateStatus allows merge
PR head SHA == expected
```

```text
gh pr checks
gh pr merge --squash   # or --merge / --rebase per USER
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
# remote only after separate OK:
pwsh -File "...\prune_merged.ps1" -RepoRoot <absolute-repo> -Apply -DeleteRemote
```

The script reads USER `never_delete_branches` / `default_branch_prefer`. Classification is in `Classify-Branch` (ancestor **or** merged PR head SHA == tip).  
After `-Apply`, squash-SAFE locals are deleted even when `git branch -d` would refuse.  
Tip-moved after merge → HOLD.  
Remote list via `for-each-ref` (skip HEAD/symref).  
Each delete rechecked.  
**Gate:** [clean-desk.md](clean-desk.md) or exceptions listed with reasons.

## full order

收工: `0 → 0b`; after one OK of the plan: `2 → 3 → 4 → 5`. Then ask merge (`6?`) and prune list (`7`); remote delete is a separate ask.  
Insert **1** when bugs remain.  
Verify fail without override: **stop**, no push of broken work.
