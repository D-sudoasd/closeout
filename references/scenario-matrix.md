# Scenario matrix

| Scenario | Phases | Notes |
|----------|--------|-------|
| No git repo | stop | Offer init only if user asks; closeout of skill-only tree = install/pack, no git ship |
| No `origin` | 0–3 | Skip push/PR/merge/remote prune |
| origin, no GitHub / no `gh` | 0–4 | Push only; skip PR/merge; prune squash-detection = report-only |
| Feature branch, dirty tree | 0→0b→2→3→4→5→… | Standard full |
| On default + local commits | 0–3 | Prefer new branch before push if `push_main_direct=false` |
| Already pushed, open PR | 0→2→6?→7 | Skip commit/push if clean; verify PR head SHA |
| Squash-merged feature still present | 7 | Detect via PR headOid == tip; then delete after OK |
| Squash-merged + new commits on branch | 7 | HOLD tip-moved; no auto-delete |
| `origin/HEAD -> origin/main` | 7 | Must not appear as deletable remote |
| CI red | pause at 5/6 | **Delegate `gh-fix-ci`**; re-verify then land |
| Verify red, user silent | stop | No push |
| Verify red, user “先提交不推” | 3 only | No push/PR |
| Review comments | optional | Point to `gh-address-comments` or `/pr-babysit` |
| Long-lived PR babysit | out of scope | Use `pr-babysit`, not closeout loop |
| Scientific data repo | 0→2'→3→… | Verify = smoke; never commit bulk raw |
| Multi-worktree | 7 careful | Skip branches locked by other worktrees |
| User: only 清分支 | 0 + 7 list | WhatIf/list then Apply after OK |
| User: 提交并推 | 2–4 | No merge/prune unless asked |
| User: 排完 bug 再收工 | 1 → full | |
| User said yeet only | 3–5 | May delegate `yeet` if exact match |
| Skill upgrade install | n/a | Preserve USER.md; backup old tree |
| Data folder reorg | out | `tidy-data-folders` |

## Conflict with other skills

- **yeet**: one-shot commit+push+PR when user says yeet; closeout is broader and merge/prune-aware.  
- **pr-babysit**: never merges; closeout may merge once with gate.  
- **check-work**: use inside phase 2; not a substitute for push.  
- **diagnosing-bugs**: phase 1 only.  
