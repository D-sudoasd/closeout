# Authorization matrix

「展示」≠「授权」。清单展示后，只有用户确认的操作可执行。Full-run 的一次确认只覆盖外部 `plan.json` 中列出的动作。

| User says | Default authorized scope |
|-----------|--------------------------|
| 先查状态 / 现在怎样 | Read-only status |
| 收工 / 收尾 / `/closeout` | Status + external plan; one OK covers the listed verify→commit→push→PR→immediate squash merge→temp/branch cleanup actions. |
| `/closeout --apply` + plan | Write ops listed in the confirmed plan only |
| 提交 | Verify + commit (no push unless also asked) |
| 提交并推 | Verify + commit + push |
| 开 PR | Commit/push if needed + create/reuse PR |
| 合并 / merge | Targeted merge checks then merge; full-run uses its confirmed plan |
| 清分支 / 剪枝 | **List** candidates only |
| 合并并清理 | Full-run plan may include local and remote cleanup; only plan-listed SAFE branches are eligible |
| Explicit 「删除远程 xxx」 | Remote delete for named/safe branches only |

## Always separate confirm

- Force push with lease (always ask; never on default branch).
- `reset --hard`, `clean -fdx`, and `gh --admin` (never part of full-run automation).
- Merge and remote deletion outside a confirmed full-run plan.

## Verify outcomes

| Result | Commit | Push / PR |
|--------|--------|-----------|
| Green | yes | yes (if mode allows) |
| Fail, no user override | stop | **no** |
| No repository test discovered | local cleanup/commit may be planned; push/PR/merge is blocked unless `allow_no_tests` is explicit |
| Fail, user accepts for local only | optional local commit | **no** unless second explicit push/PR OK |
| Fail, user explicitly allows push with known red | rare | PR body **must** document failing command + impact |

Do not treat “user accepted known failure” as blanket push authorization.
