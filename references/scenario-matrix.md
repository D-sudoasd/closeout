# Scenario matrix

| Scenario | Phases | Notes |
|----------|--------|-------|
| No git repo | stop | Offer init only if user asks; closeout of skill-only tree = install/pack, no git ship |
| No `origin` | 0–3 | Full-run is BLOCKED after local verification; no push/PR/merge |
| origin, no GitHub / no `gh` | 0–4 | Full PR-first run is BLOCKED; squash detection is report-only |
| Feature branch, dirty tree | 0→0b; after one plan confirmation: 2–7 | Commit/push/PR/merge/target cleanup with checkpoint resume |
| On default + local commits | 0→0b; after confirmation: 2–7 | Create `codex/closeout-<timestamp>` before staging |
| Already pushed, open PR | 0→2→6→7 | Skip commit/push if SHA is already synchronized; verify PR head SHA |
| Squash-merged feature still present | 7 | Detect via PR headOid == tip; then delete after OK |
| Squash-merged + new commits on branch | 7 | HOLD tip-moved; no auto-delete |
| `origin/HEAD -> origin/main` | 7 | Must not appear as deletable remote |
| Merge refused or checks pending | pause at 6 | No cleanup; keep state.json and use `-Resume` after the external condition changes |
| Plan snapshot changed | stop before writes | Recreate plan; never apply a stale plan |
| Safe cache directories | 2→7 | Delete only listed allowlisted regenerable paths; generic `tmp`/`temp`/`build`/`dist` are not defaults |
| CI red | pause at 6 | No wait/auto-merge; resume after the external condition changes |
| Verify red, user silent | stop | No push |
| Verify red, user “先提交不推” | 3 only | No push/PR |
| Review comments | optional | Point to `gh-address-comments` or `/pr-babysit` |
| Long-lived PR babysit | out of scope | Use `pr-babysit`, not closeout loop |
| Scientific data repo | 0→2'→3→… | Verify = smoke; never commit bulk raw |
| Multi-worktree | 7 careful | Skip branches locked by other worktrees |
| User: only 清分支 | 0 + 7 list | `prune_merged.ps1` dry-run; Apply only after explicit cleanup authorization |
| User: 提交并推 | 2–4 | No merge/prune unless asked |
| User: 排完 bug 再收工 | 1 → 收工 (0→0b, then 2–7 after plan OK) | |
| User said yeet only | 3–5 | May delegate `yeet` if exact match |
| Skill upgrade install | n/a | Preserve USER.md; backup old tree |
| Data folder reorg | out | `tidy-data-folders` |

## Conflict with other skills

- **yeet**: one-shot commit+push+PR when user says yeet; closeout is broader and merge/prune-aware.  
- **pr-babysit**: never merges; closeout may merge once with gate.  
- **phase 2 verify**: repo tests (AGENTS.md → package scripts → CI → README); optional installed verify skill. Not a substitute for push.  
- **diagnosing-bugs**: phase 1 only.  
