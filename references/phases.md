# Phases — commands and gates

Resolve default branch:

```powershell
# prefer gh, then origin/HEAD, then main/master
# or: Get-DefaultBranch in scripts/common.ps1
gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>$null
git symbolic-ref refs/remotes/origin/HEAD 2>$null  # -> origin/main
```

## 0 status

```powershell
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot .
# optional machine-readable:
pwsh -File "...\closeout\scripts\status.ps1" -RepoRoot . -Json
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

**Gate:** user confirms, or USER `confirm_push=false` and mode is full/收工 for the listed push/PR items only.

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

Plus repo tests from AGENTS.md / README / CI / package scripts.  
Scientific repos: staged size, raw data paths, binary accidents.

Outcomes: [auth-matrix.md](auth-matrix.md) / SKILL Verify outcomes.  
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
pwsh -File "...\prune_merged.ps1" -RepoRoot .           # dry-run list + evidence
# after user OK for local:
pwsh -File "...\prune_merged.ps1" -RepoRoot . -Apply
# remote only after separate OK:
pwsh -File "...\prune_merged.ps1" -RepoRoot . -Apply -DeleteRemote
```

Detection: ancestor **or** merged PR with matching head SHA.  
Tip-moved after merge → HOLD.  
Remote list via `for-each-ref` (skip HEAD/symref).  
Each delete rechecked.  
**Gate:** [clean-desk.md](clean-desk.md) or exceptions listed with reasons.

## full order

`0 → 0b → 2 → 3 → 4 → 5 → [ask merge] → 6? → 7 list → [ask remote delete]`.  
Insert **1** when bugs remain.  
Verify fail without override: **stop**, no push of broken work.
