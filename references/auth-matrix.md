# Authorization matrix

「展示」≠「授权」。清单展示后，只有用户确认的操作可执行。

| User says | Default authorized scope |
|-----------|--------------------------|
| 先查状态 / 现在怎样 | Read-only status |
| 收工 / 收尾 / `/closeout` | Status + verify + **execution plan**. If `confirm_push=false` (this install): also commit→push→PR. **Never** auto merge or remote delete. |
| `/closeout --apply` + plan | Write ops listed in the confirmed plan only |
| 提交 | Verify + commit (no push unless also asked) |
| 提交并推 | Verify + commit + push |
| 开 PR | Commit/push if needed + create/reuse PR |
| 合并 / merge | Merge checks then merge (if `confirm_merge` already satisfied by this verb) |
| 清分支 / 剪枝 | **List** candidates only |
| 合并并清理 | Merge + local prune after list; **remote delete still separate confirm** |
| Explicit 「删除远程 xxx」 | Remote delete for named/safe branches only |

## Always separate confirm (unless USER disables the matching key)

- Merge PR (`confirm_merge`)
- Delete remote branch (`confirm_delete_remote`)
- Force push with lease (always ask; never on default branch)
- `git branch -D`, `reset --hard`, `clean -fdx`

## Verify outcomes

| Result | Commit | Push / PR |
|--------|--------|-----------|
| Green | yes | yes (if mode allows) |
| Fail, no user override | stop | **no** |
| Fail, user accepts for local only | optional local commit | **no** unless second explicit push/PR OK |
| Fail, user explicitly allows push with known red | rare | PR body **must** document failing command + impact |

Do not treat “user accepted known failure” as blanket push authorization.
