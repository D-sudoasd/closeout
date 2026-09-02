---
name: closeout
description: >
  End-to-end dev closeout: status, optional bug diagnosis, verify, commit, push,
  PR, merge gate, and prune merged branches to a clean desk. Use when the user
  says 收工, 收尾, 提交并推, 合并并清理, 清分支, 剪枝, ship, close out, clean
  workspace after coding, or runs /closeout. Prefer this over repeating git/PR
  instructions; delegate diagnosing-bugs, yeet, gh-fix-ci when needed.
---

# Closeout

**closeout** = ship the work and leave a **clean desk**.  
**phase** = one step; **gate** = must pass before the next; **delegate** = call an existing skill instead of reinventing it.

Read [USER.md](USER.md) if present, else [USER.example.md](USER.example.md).  
Scripts also load `never_delete_branches` and `default_branch_prefer` from that file.

Version: see [VERSION](VERSION). Changelog: [CHANGELOG.md](CHANGELOG.md).  
Public repo: https://github.com/D-sudoasd/closeout

Always pass an **absolute `-RepoRoot`** for the target git repo (cwd is not enough; `git` and `gh` both follow that root):

```text
pwsh -File <skill>/scripts/status.ps1 -RepoRoot <repo>
pwsh -File <skill>/scripts/prune_merged.ps1 -RepoRoot <repo>
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
| 收工 / 收尾 / `/closeout` / ship it | **0 → 0b**; after **one OK** of the plan: **2–5**. Never merge or remote-delete from this verb. |
| 先查状态 / 现在怎样 | **0** |
| 排 bug / 还坏 / debug then closeout | **1** then 收工 |
| 验一下 / check | **2** |
| 提交 / commit | **2–3** |
| 提交并推 | **2–4** |
| 开 PR | **5** (do 3–4 if needed) |
| 合并 / merge | **6** |
| 合并并清理 | **6–7** local prune after list; remote delete still separate |
| 清分支 / 剪枝 | **7** list; delete only after OK |
| confirmed plan / `/closeout --apply` | listed write ops only — **not** `prune_merged.ps1 -Apply` |

Shipped `confirm_push=true`: 收工 shows the plan first; **one OK** covers verify→commit→push→PR. Merge and remote delete stay separate.

## Phases (summary)

Commands and gates: [phases.md](references/phases.md).

| # | Name | Action | Gate |
|---|------|--------|------|
| 0 | status | `status.ps1` (read-only) | report |
| 0b | plan | show will/won't execution list | user OK or USER allows |
| 1 | diagnose | **delegate** `diagnosing-bugs` if hard | symptom fixed or deferred |
| 2 | verify | repo tests (see below); record exit codes | [auth-matrix.md](references/auth-matrix.md) |
| 3 | commit | intentional stage + message; record pre/post HEAD | intended work committed |
| 4 | push | `git push -u`; verify local SHA == remote SHA | synced (or no remote) |
| 5 | pr | reuse open PR or create; check head SHA | URL or skipped |
| 6 | land | `gh pr merge` per USER | **ask first** unless auto_merge |
| 7 | prune | `prune_merged.ps1` list → confirm → apply; recheck | [clean-desk.md](references/clean-desk.md) |

**After plan OK:** `2 → 3 → 4 → 5` only. Then **ask** merge (`6?`) and prune list (`7`) — those asks are **not** covered by the plan OK.  
Insert **1** if bugs remain.

## Verify (phase 2)

Do **not** require a skill named `check-work`. Record command + exit code for each step:

1. If this session already has an installed verify skill, delegate it.
2. Else discover tests in order: `AGENTS.md` → package scripts → CI workflow → README.
3. Always run `git diff --check` and `git diff --cached --check`.

Outcomes: [auth-matrix.md](references/auth-matrix.md) (Verify outcomes).

## Execution plan (before write ops)

Shape: [phases.md](references/phases.md) §0b (files, `diff --stat`, secrets/large paths, message, remote, PR).  
One confirmation covers the listed items. Merge and remote delete stay outside that OK ([auth-matrix.md](references/auth-matrix.md)).

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
8. **Merge** and **delete remote branches**: confirm unless USER disables the matching key. Showing a prune list is **not** delete authorization.  
9. Push + open PR on 收工: follow `confirm_push` in USER (shipped example is `true`: plan first, one OK covers 2–5).  
10. If on default with local commits and `push_main_direct=false`, branch off or ask before push.  
11. Every external git command: check exit code; report failure; do not claim success from invocation alone.  
12. After delete: recheck ref absence before reporting deleted.

## Prune

Classification lives in `scripts/prune_merged.ps1` (ancestor **or** merged PR `headRefOid == tip`). Policy: [clean-desk.md](references/clean-desk.md).  
After authorized `-Apply`, squash-SAFE locals are removed even when `git branch -d` would refuse a non-ancestor. USER `never_delete_branches` is read by the script.

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
- Pushing red verify without explicit second authorization  
- Claiming clean desk when squash-merged branches were not considered  
- Using closeout for folder data reorg  
- Overwriting `USER.md` on skill upgrade  
- Editing USER preferences without showing proposed text first  
- Invoking status/prune without `-RepoRoot` of the **target** repo  

## Config / install

- Shipped template: `USER.example.md`  
- Local prefs: `USER.md` (preserve across upgrades)  
- Installer: `install.ps1` backs up previous tree and keeps `USER.md`; refuses Source == Destination  
- Self-check: `pwsh -File scripts/self_check.ps1`

## Completion

Each phase gate in [phases.md](references/phases.md) has evidence; report-template fields filled; full mode aims at **clean desk** ([clean-desk.md](references/clean-desk.md)).
