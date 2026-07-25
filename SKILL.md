---
name: closeout
description: >
  End-to-end dev closeout: status, optional bug diagnosis, verify, commit, push,
  PR, merge gate, and prune merged branches to a clean desk. Use when the user
  says 收工, 收尾, 提交并推, 合并并清理, 清分支, 剪枝, ship, close out, clean
  workspace after coding, or runs /closeout. Prefer this over repeating git/PR
  instructions; delegate diagnosing-bugs, check-work, yeet, gh-fix-ci when needed.
---

# Closeout

**closeout** = ship the work and leave a **clean desk**.  
**phase** = one step; **gate** = must pass before the next; **delegate** = call an existing skill instead of reinventing it.

Read [USER.md](USER.md) if present, else [USER.example.md](USER.example.md).  
Details: [references/phases.md](references/phases.md), [references/clean-desk.md](references/clean-desk.md), [references/scenario-matrix.md](references/scenario-matrix.md), [references/auth-matrix.md](references/auth-matrix.md), [references/report-template.md](references/report-template.md).

Version: see [VERSION](VERSION). Changelog: [CHANGELOG.md](CHANGELOG.md).  
Public repo: https://github.com/D-sudoasd/closeout

Scripts (prefer over ad-hoc):

```text
~/.grok/skills/closeout/scripts/status.ps1
~/.grok/skills/closeout/scripts/prune_merged.ps1
~/.grok/skills/closeout/scripts/self_check.ps1
```

## Triggers → mode

| User says | Mode |
|-----------|------|
| 收工 / 收尾 / `/closeout` / ship it | **full** |
| 先查状态 / 现在怎样 | **0** |
| 排 bug / 还坏 / debug then closeout | **1** then full |
| 验一下 / check | **2** |
| 提交 / commit | **3** |
| 提交并推 | **2–4** |
| 开 PR | **5** (do 3–4 if needed) |
| 合并 / merge | **6** |
| 合并并清理 | **6–7** |
| 清分支 / 剪枝 | **7** list; delete only after OK |
| `/closeout --apply` | execute previously shown plan |

## Phases (summary)

| # | Name | Action | Gate |
|---|------|--------|------|
| 0 | status | `status.ps1` (read-only) | report |
| 0b | plan | show will/won't execution list | user OK or USER allows |
| 1 | diagnose | **delegate** `diagnosing-bugs` if hard | symptom fixed or deferred |
| 2 | verify | **delegate** `check-work` and/or repo tests; record exit codes | see Verify outcomes |
| 3 | commit | intentional stage + message; record pre/post HEAD | intended work committed |
| 4 | push | `git push -u`; verify local SHA == remote SHA | synced (or no remote) |
| 5 | pr | reuse open PR or create; check head SHA | URL or skipped |
| 6 | land | `gh pr merge` per USER | **ask first** unless auto_merge |
| 7 | prune | `prune_merged.ps1` list → confirm → apply; recheck | clean desk |

**full:** `0 → 0b → 2 → 3 → 4 → 5 → ask merge → 6? → 7 list → ask remote delete`.  
Insert **1** if bugs remain.

## Verify outcomes (unified)

| Result | Next |
|--------|------|
| **Pass** | May commit / push / PR per mode |
| **Fail, no override** | **Stop**. No push. No PR of broken work. |
| **Fail, user accepts local only** | Optional local commit; **no** push/PR |
| **Fail, user explicitly allows push** | Push/PR only with second clear OK; PR body must list failing command, exit code, impact |

Do **not** treat vague “accepted fail” as push permission.

## Execution plan (before write ops)

Show once after status:

```text
本次将执行：
1. …
2. …

本次不会执行：
- 合并 PR（除非已授权）
- 删除远程分支（除非已授权）
- 强制推送
```

One confirmation covers the listed items. Merge and remote delete stay separate ([auth-matrix.md](references/auth-matrix.md)).

## Delegate map

| Need | Skill / tool |
|------|----------------|
| Hard bug loop | `diagnosing-bugs` |
| Session verification | `check-work` |
| User said yeet only | `yeet` OK for 3–5 |
| CI red on PR | `gh-fix-ci` (plan + approve) |
| Review threads | `gh-address-comments` |
| Long PR babysit | `pr-babysit` (does **not** merge) |
| Data folder tidy | `tidy-data-folders` — not this skill |

## Safety (non-negotiable)

1. No `--no-verify` / skip hooks unless user insists.  
2. Never force-push default branch (`main`/`master`/detected default).  
3. Feature force only `--force-with-lease` when required + confirmed.  
4. Never delete default, current branch, unmerged unique work, tip-moved-after-PR, or worktree-locked branches.  
5. Do not commit secrets, `.env`, bulk raw scientific data, or obvious `tmp/` junk.  
6. No `reset --hard` / `clean -fdx` / `branch -D` without explicit OK.  
7. Unexpected dirty files → report; do not clobber.  
8. **Merge** and **delete remote branches**: confirm unless USER disables the matching key. Showing a prune list is **not** delete authorization.  
9. Push + open PR on full/收工: follow `confirm_push` in USER (this install may set false for 收工).  
10. If on default with local commits and `push_main_direct=false`, branch off or ask before push.  
11. Every external git command: check exit code; report failure; do not claim success from invocation alone.  
12. After delete: recheck ref absence before reporting deleted.

## Prune rules (v2)

```text
tip is ancestor of default
  → SAFE candidate (classic merge)

not ancestor, but merged PR exists AND pr.headRefOid == branch tip
  → SAFE candidate (squash/rebase)

merged PR but tip differs
  → HOLD: merged-pr-but-tip-moved (no auto-delete)

cannot confirm (no gh / no PR)
  → report-only, no delete

remote enum via for-each-ref; skip symref and HEAD
```

Prefer `prune_merged.ps1` over ad-hoc `git branch --merged`.

## Commit / PR quality

- Message: USER `commit_style` — prefer `fix:` / `feat:` / `chore:` or one clear Chinese sentence.  
- PR body: problem → cause → fix → how verified (commands + exit codes).  
- Multi-topic changes → split commits when cheap.

## Final report

Use [report-template.md](references/report-template.md) (evidence fields).  
Minimum fallback:

```markdown
## Closeout 结果
- branch / SHA:
- verified: (commands + exit codes)
- commits:
- remote / PR:
- merged: yes/no
- pruned: deleted + skipped reasons
- remaining dirty / exceptions:
- clean desk: YES/NO + 依据
```

## Anti-patterns

- Re-implementing diagnosing-bugs or pr-babysit inside this skill  
- Blind `git add -A` then push without reading diff  
- Merging without gate  
- Prune with `-D` / deleting unmerged or tip-moved branches  
- Pushing red verify without explicit second authorization  
- Claiming clean desk when squash-merged branches were not considered  
- Using closeout for folder data reorg  
- Overwriting `USER.md` on skill upgrade  
- Editing USER preferences without showing proposed text first  

## Config / install

- Shipped template: `USER.example.md`  
- Local prefs: `USER.md` (preserve across upgrades)  
- Installer: pack `install.ps1` backs up previous tree and keeps `USER.md`  
- Self-check: `pwsh -File scripts/self_check.ps1`

## Completion

Mode deliverable done; gates respected; user has evidence report; full mode aims at **clean desk** ([clean-desk.md](references/clean-desk.md)).
