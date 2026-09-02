# closeout — user defaults (example)

Copy to `USER.md` on first install. **Upgrades must not overwrite `USER.md`.**  
Agent: read `USER.md` if present, else this file. Append under Corrections only after user confirms lasting preference changes.

Scripts (`status.ps1`, `prune_merged.ps1`) parse `never_delete_branches` and `default_branch_prefer` from this table. Other keys are agent-facing.

## Defaults (safe for new installs)

| Key | Value |
|-----|--------|
| `default_branch_prefer` | `main` (else detect via `gh` / `origin/HEAD`) |
| `prefer_pr` | `true` |
| `pr_draft_default` | `false` |
| `merge_strategy` | `squash` |
| `auto_merge_when_green` | `false` |
| `prune_remote_merged` | `false` — list only until user enables / confirms |
| `prune_local_merged` | `true` after list + Apply |
| `confirm_merge` | `true` |
| `confirm_push` | `true` — 收工 shows plan first; one OK covers verify→commit→push→PR |
| `confirm_delete_remote` | `true` — never implied by list-only or 收工 alone |
| `never_delete_branches` | `main`, `master`, `develop` |
| `branch_prefix_ok` | `codex/`, `fix/`, `feat/`, `chore/`, `hotfix/` |
| `commit_style` | conventional or one clear Chinese sentence (`fix:` / `feat:` preferred) |
| `push_main_direct` | `false` |
| `language` | 对用户报告用中文 |

## Authorization notes

- 「展示列表」≠ 删除授权。
- 合并、远程删支、force-with-lease 各自需要明确授权（除非本表关闭对应 confirm）。
- `/closeout --apply` 或用户书面确认执行清单后，才执行清单内写操作。

## Corrections

<!-- YYYY-MM-DD — note -->
