# closeout — user defaults (example)

Copy to `USER.md` on first install. **Upgrades must not overwrite `USER.md`.**  
Agent: read `USER.md` if present, else this file. Append under Corrections only after user confirms lasting preference changes.

Scripts parse the relevant keys from this table. `USER.md` is local and is
preserved during upgrades.

## Defaults (safe for new installs)

| Key | Value |
|-----|--------|
| `default_branch_prefer` | `main` (else detect via `gh` / `origin/HEAD`) |
| `prefer_pr` | `true` |
| `pr_draft_default` | `false` |
| `merge_strategy` | `squash` |
| `auto_merge_when_green` | `false` |
| `wait_for_checks` | `false` — attempt merge once; do not poll |
| `full_run_confirmation` | `true` — one approved plan covers its listed actions |
| `prune_remote_merged` | `true` — only plan-listed, SHA-confirmed branches |
| `prune_local_merged` | `true` after list + Apply |
| `confirm_merge` | `true` |
| `confirm_push` | `true` — 收工 shows plan first; full-run confirmation covers the listed lifecycle |
| `confirm_delete_remote` | `true` outside a confirmed full-run plan |
| `never_delete_branches` | `main`, `master`, `develop` |
| `branch_prefix` | `codex/` |
| `commit_style` | conventional or one clear Chinese sentence (`fix:` / `feat:` preferred) |
| `push_main_direct` | `false` |
| `auto_create_branch` | `true` |
| `cleanup_temp` | `true` |
| `cleanup_temp_dirs` | `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.nox`, `.hypothesis`, `htmlcov`, `*.egg-info` |
| `cleanup_temp_files` | `.coverage`, `*.pyc`, `*.pyo` |
| `allow_no_tests` | `false` |
| `max_untracked_file_mb` | `10` |
| `max_staged_file_mb` | `50` |
| `language` | 对用户报告用中文 |

## Authorization notes

- 「展示列表」≠ 删除授权。
- 一次 full-run 确认只覆盖已经列入 `plan.json` 的动作；计划外路径或分支必须重新计划。
- force-with-lease、reset --hard、clean -fdx 和 gh --admin 永不由 full-run 自动执行。
- `tmp`、`temp`、`build`、`dist` 不在默认临时目录白名单中。

## Corrections

<!-- YYYY-MM-DD — note -->
