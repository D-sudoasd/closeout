# Closeout 结果（证据报告）

Agent: fill every field; use `(n/a)` or explicit skip reason. Prefer this over a bare YES/NO.

```markdown
## Closeout 结果

### 初始状态
- 仓库：
- 初始分支：
- 初始 HEAD：
- 工作区：staged / unstaged / untracked / conflicted
- 进行中操作：

### 执行清单（写操作前已展示）
- 将执行：
- 不会执行：
- 用户确认：是/否/按 USER 默认授权

### 验证
| 命令 | 退出码 | 结果 | 摘要 |
|------|--------|------|------|
| git diff --check | | | |
| … | | | |

### 提交
- commit：
- message：
- files：
- pre_HEAD → post_HEAD：

### 推送
- remote / branch：
- local SHA：
- remote SHA：
- synchronized：是/否

### PR
- number / URL：
- base / head：
- head SHA：
- state / checks：

### 合并
- 状态：未请求 / 已合并 / 跳过
- 方式：
- 证据：

### 清理
- 已删除本地：
- 已删除远程：
- 跳过及原因：（ancestor / squash-PR-match / tip-moved / worktree / uncertain）

### 工作区复查
- 工作树干净：
- 当前分支：
- 默认分支与远程同步：
- 无进行中 Git 操作：
- 无可确认已合并遗留支：

### 未完成事项
- 

### 结论
- clean desk：YES / NO
- 判定依据：
```
