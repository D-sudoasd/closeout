# closeout 推广文案（可直接转发）

仓库：https://github.com/D-sudoasd/closeout  
Release：https://github.com/D-sudoasd/closeout/releases/tag/v2.2.0

---

## 一句话

把 agent 的「收工」做成一次确认、可续跑、可核验的完整 git 收尾技能：提交、推送、PR、合并、缓存和分支清理。

---

## 中文短帖（X / 微信 / 飞书）

Agent 说「提交并推」很爽，也容易翻车：盲 `git add -A`、验证红了还推、squash 合完清不掉分支、删远程当展示列表就行。

**closeout** 把收工拆成固定门禁，并把执行状态保存为外部 checkpoint：

计划 → 验证（记退出码）→ 智能暂存 → 提交 → 推送核验 SHA → PR → 立即 squash merge → 白名单缓存清理 → 合并分支清理 → 外部证据报告

计划外对象不会执行；失败会停在 checkpoint，下一次可 `-Resume`。默认不碰密钥、原始数据、通用 `tmp`/`temp`，升级不冲掉 `USER.md`。

开源 MIT：https://github.com/D-sudoasd/closeout

```powershell
git clone https://github.com/D-sudoasd/closeout.git "$env:USERPROFILE\.grok\skills\closeout"
```

对 Grok / Codex 说：**收工** 或 `/closeout`。

---

## English short post

Shipping agents love `git add -A && push`. They also love committing secrets, pushing red tests, and leaving squash-merged branches forever.

**closeout** is an agent skill for a real clean desk:

plan → verify (exit codes) → intentional stage → commit → push SHA check → PR → immediate squash merge → allowlisted temp cleanup → prune (ancestor **or** merged PR headOid == tip) → report

The approved external plan covers only its listed actions. Failed commands stop the run; `-Resume` continues from the checkpoint. The installer keeps your `USER.md`.

MIT: https://github.com/D-sudoasd/closeout

---

## 对比表（可截图）

| 场景 | 裸 agent | closeout |
|------|----------|----------|
| 暂存 | 常 `add -A` | 有意识 stage |
| 验证失败 | 仍可能推 | 默认停推；记录失败并可续跑 |
| squash 后清分支 | `branch --merged` 漏掉 | PR head SHA 对齐才 SAFE |
| `origin/HEAD` | 可能当分支名 | 结构化枚举，跳过 |
| 删远程 | 「看过列表」就算确认 | full-run 计划列出 + SAFE 判定 + 删除复查 |
| 结果 | “done” | 证据报告 + clean desk YES/NO |

---

## Issue / Discussion 钩子（可选发）

欢迎反馈：

1. 你最常在哪一步翻车：verify / push / merge / cleanup？
2. 需要 macOS/Linux 默认路径示例吗？  
3. 想要外部 plan/state/report 接入 CI 吗？

---

## 维护者自检清单

- [ ] README badges 绿  
- [ ] Release 指向 v2.2.0
- [ ] Topics 已设  
- [ ] 本机 `git pull` 后 self_check PASS  
- [ ] 未提交 `USER.md`
