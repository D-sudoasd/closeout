# Clean desk

Workspace is **clean desk** when all of the following hold (or are explicitly explained as exceptions):

1. **On default branch** (or intentional long-lived branch), or on feature branch with clear open PR.  
2. **Working tree clean** relative to HEAD (or only intentional untracked: local notes, `.env` ignored).  
3. **No leftover feature branches** that are fully merged into default — including **squash/rebase** merges confirmed by PR head SHA match (not only `git branch --merged`).  
4. **No default allowlisted temporary caches** remain inside the repository. Generic `tmp`, `temp`, `build`, and `dist` are not implied.
5. **No orphaned worktrees** for deleted branches.
6. **No debug instrumentation** left from this session (`[DEBUG-…]` tags).
7. **No secrets / bulk raw data** staged or committed this session.
8. **No in-progress** merge/rebase/cherry-pick/bisect.
9. Report evidence matches rechecked repo state (SHA, branch list).

If squash-merged branches were not evaluated (e.g. `gh` missing), **clean desk must be NO** or exception must say “squash detection skipped”.

## Never auto-delete

- Branches in USER `never_delete_branches` (scripts read the key; example default is main/master/develop)  
- Current branch (local **and** its remote)  
- Default branch remote  
- Branches with **unique unmerged commits**  
- Branches with **merged PR but tip moved** (new commits after merge)  
- Branches checked out in another worktree  
- Remote branches that are **not** confirmed merged and listed in the approved plan
- Symbolic refs (`origin/HEAD`)

## Prune order

1. `git fetch --prune` (check exit code)  
2. Enumerate local heads; classify ancestor vs squash-PR vs HOLD  
3. Enumerate remotes via `for-each-ref` (skip symref/HEAD)  
4. Show table: name, reason, evidence, SAFE/HOLD  
5. In full-run, pass `-OnlyBranches` and apply only the approved plan target after merge evidence is rechecked.
6. Recheck local and remote refs after deletion.
7. `git worktree list`, checkout default, `git status -sb`, emit evidence report.

## Dangerous commands (never implicit in full-run)

- `git reset --hard`
- `git branch -D` outside `prune_merged.ps1 -Apply` on a classified SAFE local / `git push --force` without lease
- `git clean -fdx`
- `gh pr merge --admin` or auto-merge enablement
- Amending published commits on shared branches
