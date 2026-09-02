---
name: closeout
description: >
  End-to-end dev closeout: plan, verify, commit, push, PR, immediate merge,
  allowlisted temp cleanup, checkpoint resume, and merged-branch pruning. Use when the user
  says 收工, 收尾, 提交并推, 合并并清理, 清分支, 剪枝, ship, close out, clean
  workspace after coding, or runs /closeout. Prefer this over repeating git/PR
  instructions; delegate diagnosing-bugs, yeet, gh-fix-ci when needed.
---

# Closeout

**closeout** = ship the work and leave a **clean desk**.  
**phase** = one step; **gate** = must pass before the next; **delegate** = call an existing skill instead of reinventing it.

Read [USER.md](USER.md) if present, else [USER.example.md](USER.example.md).  
Scripts also load the closeout defaults from that file, including PR/merge,
verification, temporary-cleanup, staging limits, and branch-protection keys.

Version: see [VERSION](VERSION). Changelog: [CHANGELOG.md](CHANGELOG.md).  
Public repo: https://github.com/D-sudoasd/closeout

Always pass an **absolute `-RepoRoot`** for the target git repo (cwd is not enough; `git` and `gh` both follow that root):

```text
pwsh -File <skill>/scripts/status.ps1 -RepoRoot <repo>
pwsh -File <skill>/scripts/prune_merged.ps1 -RepoRoot <repo>
pwsh -File <skill>/scripts/cleanup_temp.ps1 -RepoRoot <repo>
pwsh -File <skill>/scripts/closeout.ps1 -RepoRoot <repo> -Plan
pwsh -File <skill>/scripts/closeout.ps1 -RepoRoot <repo> -Apply -PlanFile <plan.json>
pwsh -File <skill>/scripts/closeout.ps1 -RepoRoot <repo> -Resume -StateFile <state.json>
pwsh -File <skill>/scripts/self_check.ps1
```

Load extra docs only for the mode you are in:

| Mode | Read |
|------|------|
| any write / 收工 plan | [auth-matrix.md](references/auth-matrix.md) |
| commands + gates | [references/phases.md](references/phases.md) |
| prune / clean desk | [references/clean-desk.md](references/clean-desk.md) |
| odd repo states | [references/scenario-matrix.md](references/scenario-matrix.md) |
| final report | [references/report-template.md](references/report-template.md) |

## Triggers → mode

Canonical scope is [auth-matrix.md](references/auth-matrix.md). This index matches it:

| User says | Mode |
|-----------|------|
| 收工 / 收尾 / `/closeout` / ship it | **0 → 0b**; after one confirmation of the external plan: **2–7 + final**. |
| 先查状态 / 现在怎样 | **0** |
| 排 bug / 还坏 / debug then closeout | **1** then 收工 |
| 验一下 / check | **2** |
| 提交 / commit | **2–3** |
| 提交并推 | **2–4** |
| 开 PR | **5** (do 3–4 if needed) |
| 合并 / merge | **6** |
| 合并并清理 | **6–7**; only plan-listed SAFE local/remote cleanup |
| 清分支 / 剪枝 | **7** list; delete only after OK |
| confirmed plan / `/closeout --apply` | only listed `plan.json` write ops; use `-Resume` after failure |

Shipped full-run mode: 收工 shows an external plan first; **one OK** covers only its listed verify→commit→push→PR→merge→cleanup actions. Plan changes require a new confirmation.

## Phases (summary)

Commands and gates: [phases.md](references/phases.md).

| # | Name | Action | Gate |
|---|------|--------|------|
| 0 | status | `status.ps1` plus candidate scan | external plan |
| 0b | plan | `closeout.ps1 -Plan` will/won't list | one explicit plan confirmation |
| 1 | diagnose | **delegate** `diagnosing-bugs` if hard | symptom fixed or deferred |
| 2 | verify | configured/discovered commands plus diff checks | pass or explicit no-test override |
| 3 | commit | smart allowlist + explicit stage; record SHAs | intended work committed |
| 4 | push | `git push -u`; verify local SHA == remote SHA | synchronized |
| 5 | pr | reuse/create and verify base/head/head SHA | PR evidence |
| 6 | land | one immediate configured merge (default `--squash`) with `--match-head-commit` | merged or checkpointed failure |
| 7 | cleanup | allowlisted temp cleanup and `prune_merged.ps1 -OnlyBranches` | refs and paths rechecked |
| final | report | switch/pull default and recheck clean desk | external report |

**After plan OK:** `2 → 3 → 4 → 5 → 6 → 7 → final`. Merge and plan-listed remote deletion are covered only when they appear in the approved full-run plan.
Insert **1** if bugs remain.

## Verify (phase 2)

Do **not** require a skill named `check-work`. Record command + exit code for each step:

1. If this session already has an installed verify skill, delegate it.
2. Else discover tests in order: `AGENTS.md` → package scripts → CI workflow → README.
   Pass the selected commands to `closeout.ps1 -VerifyCommand`, or configure `closeout.verify.json` with a `commands` array.
3. Always run `git diff --check` and `git diff --cached --check`; no repository-specific command means BLOCKED unless `allow_no_tests` is explicit.

Outcomes: [auth-matrix.md](references/auth-matrix.md) (Verify outcomes).

## Execution plan (before write ops)

Shape: [phases.md](references/phases.md) §0b (files, temp candidates, diff stat, message, remote, PR, prune target, and will/won't list).
`-Apply` requires the external plan file; `-Resume` reads its state checkpoint. One confirmation covers only the listed actions ([auth-matrix.md](references/auth-matrix.md)).

## Delegate map

| Need | Skill / tool |
|------|----------------|
| Hard bug loop | `diagnosing-bugs` |
| Session verification | repo tests (phase 2); optional installed verify skill |
| User said yeet only | `yeet` OK for 3–5 |
| CI red on PR | `gh-fix-ci` (plan + approve) |
| Review threads | `gh-address-comments` |
| Long PR babysit | `pr-babysit` if installed (does **not** merge) |
| Data folder tidy | `tidy-data-folders` — not this skill |

## Safety (non-negotiable)

1. No `--no-verify` / skip hooks unless user insists.  
2. Never force-push default branch (`main`/`master`/detected default).  
3. Feature force only `--force-with-lease` when required + confirmed.  
4. Never delete default, current branch, USER `never_delete_branches`, unmerged unique work, tip-moved-after-PR, worktree-locked, or `origin/HEAD`.  
5. Do not commit secrets, `.env`, bulk raw scientific data, or obvious `tmp/` junk.  
6. No `reset --hard` / `clean -fdx` without explicit OK. Do not `git branch -D` except via `prune_merged.ps1 -Apply` on a classified SAFE local (squash, or ancestor when `-d` refuses because HEAD is not default).  
7. Unexpected dirty files → report; do not clobber.  
8. Full-run merge and plan-listed remote deletion are allowed only after the external plan is explicitly confirmed; targeted commands retain separate authorization.
9. Push + open PR + merge on 收工 follow the full-run plan and checkpoint policy.
10. If on default with local commits and `push_main_direct=false`, branch off or ask before push.  
11. Every external git command: check exit code; report failure; do not claim success from invocation alone.  
12. After delete: recheck ref absence before reporting deleted.

## Cleanup and prune

Classification lives in `scripts/prune_merged.ps1` (ancestor **or** merged PR `headRefOid == tip`). Policy: [clean-desk.md](references/clean-desk.md).  
Full-run adds `-OnlyBranches` so unrelated safe branches are not deleted.
After authorized `-Apply`, squash-SAFE locals are removed even when `git branch -d` would refuse a non-ancestor. USER `never_delete_branches` is read by the script.

`cleanup_temp.ps1` only deletes plan-listed or allowlist-matched regenerable caches inside the repository. It never follows reparse points or deletes tracked paths. Generic `tmp`, `temp`, `build`, and `dist` are not defaults.

## Commit / PR quality

- Message: USER `commit_style` — prefer `fix:` / `feat:` / `chore:` or one clear Chinese sentence.  
- PR body: problem → cause → fix → how verified (commands + exit codes).  
- Multi-topic changes → split commits when cheap.

## Final report

Fill every field in [report-template.md](references/report-template.md) (value or `(n/a)` / skip reason). Do not substitute a shorter stub.

## Anti-patterns

- Re-inventing diagnosing-bugs or PR babysit inside this skill  
- Blind `git add -A` then push without reading diff  
- Merging without gate  
- `git branch -D` on unclassified, unmerged, or tip-moved branches  
- Pushing red verify without an approved fail policy
- Claiming clean desk when squash-merged branches were not considered  
- Using closeout for folder data reorg  
- Overwriting `USER.md` on skill upgrade  
- Editing USER preferences without showing proposed text first  
- Invoking status/prune without `-RepoRoot` of the **target** repo  

## Config / install

- Shipped template: `USER.example.md`  
- Local prefs: `USER.md` (preserve across upgrades)  
- Installer: `install.ps1` backs up previous tree and keeps `USER.md`; refuses Source == Destination  
- `scripts/closeout.ps1` — full plan/apply/resume orchestrator
- `scripts/cleanup_temp.ps1` — allowlisted cache cleanup
- Self-check: `pwsh -File scripts/self_check.ps1`

## Completion

Each phase gate in [phases.md](references/phases.md) has evidence; report-template fields filled; full mode aims at **clean desk** ([clean-desk.md](references/clean-desk.md)).
