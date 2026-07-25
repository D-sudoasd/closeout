# closeout 推广文案（可直接转发）

仓库：https://github.com/D-sudoasd/closeout  
Release：https://github.com/D-sudoasd/closeout/releases/tag/v2.0.0

---

## 一句话

把 agent 的「收工」做成可授权、可核验、能清掉 squash 分支的 git 收尾技能。

---

## 中文短帖（X / 微信 / 飞书）

Agent 说「提交并推」很爽，也容易翻车：盲 `git add -A`、验证红了还推、squash 合完清不掉分支、删远程当展示列表就行。

**closeout** 把收工拆成固定门禁：

状态 → 执行清单 → 验证（记退出码）→ 提交 → 推送核验 SHA → PR → 合并需确认 → 清分支（祖先 **或** PR head SHA 对齐）

列表 ≠ 删远程。失败不会假装成功。升级不冲掉 `USER.md`。

开源 MIT：https://github.com/D-sudoasd/closeout

```powershell
git clone https://github.com/D-sudoasd/closeout.git "$env:USERPROFILE\.grok\skills\closeout"
```

对 Grok / Codex 说：**收工** 或 `/closeout`。

---

## English short post

Shipping agents love `git add -A && push`. They also love committing secrets, pushing red tests, and leaving squash-merged branches forever.

**closeout** is an agent skill for a real clean desk:

status → plan → verify (exit codes) → commit → push SHA check → PR → merge gate → prune (ancestor **or** merged PR headOid == tip)

List is not authorization to delete remotes. Failed git commands don't report success. Installer keeps your `USER.md`.

MIT: https://github.com/D-sudoasd/closeout

---

## 对比表（可截图）

| 场景 | 裸 agent | closeout |
|------|----------|----------|
| 暂存 | 常 `add -A` | 有意识 stage |
| 验证失败 | 仍可能推 | 默认停推；仅本地或二次授权 |
| squash 后清分支 | `branch --merged` 漏掉 | PR head SHA 对齐才 SAFE |
| `origin/HEAD` | 可能当分支名 | 结构化枚举，跳过 |
| 删远程 | 「看过列表」就算确认 | 单独授权 + 删除复查 |
| 结果 | “done” | 证据报告 + clean desk YES/NO |

---

## Issue / Discussion 钩子（可选发）

欢迎反馈：

1. 你最常在哪一步翻车：verify / push / prune？  
2. 需要 macOS/Linux 默认路径示例吗？  
3. 想要 JSON 输出给 CI 吗？

---

## 维护者自检清单

- [ ] README badges 绿  
- [ ] Release 指向 v2.0.0  
- [ ] Topics 已设  
- [ ] 本机 `git pull` 后 self_check PASS  
- [ ] 未提交 `USER.md`
