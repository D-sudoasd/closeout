# Changelog

## 2.2.0 — 2026-09-02

### Added

- `scripts/closeout.ps1`: plan, apply, checkpoint, resume, and evidence-report orchestration for commit, push, PR, merge, cleanup, and branch pruning.
- `scripts/cleanup_temp.ps1`: repository-contained allowlisted cache cleanup with tracked-path, reparse-point, containment, fingerprint, and post-delete checks.
- `scripts/test_orchestrator.ps1`: local bare-remote integration fixtures for full lifecycle and resume behavior.

### Safety

- Apply requires an external plan file and rejects changed HEAD, branch, working-tree status, or file content.
- Full-run branch cleanup is limited to the plan-listed branch and confirmed merged SHA evidence; open and unmerged PRs are preserved.
- Merge is attempted once with `--match-head-commit`; no `--auto`, `--admin`, force-push, or broad `git clean` path is used.

## 2.1.0 — 2026-09-02

### Fixed

- `status.ps1` / `prune_merged.ps1` bind `gh` to `-RepoRoot` (`Set-Location` plus `gh -R` from upstream, then github, then origin), so squash detection and PR status work when process cwd is not the target repo.
- Authorized `-Apply` deletes squash-SAFE locals (`git branch -D` after classification). `git branch -d` alone cannot remove a non-ancestor squash tip.
- `prune_merged.ps1` reads USER `never_delete_branches` and `default_branch_prefer`.
- `install.ps1` refuses Source == Destination (and Source inside Destination) before any `Move-Item`.
- Phase 2 verify no longer requires a `check-work` skill.

### Changed

- Trigger / auth / verify text matches shipped `confirm_push=true` (plan first; one OK covers 2–5).
- Fixture tests in `scripts/test_fixtures.ps1` (cwd ≠ RepoRoot, squash Apply, USER never-delete, installer same-path).

## 2.0.0 — 2026-07-25

### Docs / packaging

- Public GitHub repo + Release + CI
- README hero / workflow / before-after SVG
- Bilingual README polish + `docs/PROMOTE.md` share kit

### Fixed (safety / correctness)

- **Squash/rebase merge detection** for prune: ancestor check + merged PR `headRefOid` vs branch tip; tip-moved branches are report-only.
- **Remote `origin/HEAD` symref** no longer treated as a deletable branch (`for-each-ref` + skip symref/HEAD).
- **Never delete** current branch (local or remote), default branch, `never_delete` list, or worktree-locked branches.
- **Exit codes**: all git calls go through `Invoke-Git`; failures no longer report success by default.
- **Post-delete recheck**: local/remote deletes verified before claiming success.
- **Verify-fail policy** unified in SKILL: fail stops push/PR unless user explicitly re-authorizes; accepted-fail allows local commit only.

### Changed (trust)

- Authorization matrix: 收工 defaults to plan-first where `confirm_push=true` (example); merge and remote delete always separate confirm unless USER opts out.
- Execution plan phase before write ops (files, message, will/won't).
- Evidence-based final report template (SHA, PR, recheck fields).
- `status.ps1`: staged/unstaged/untracked/conflicted, in-progress ops, redacted remotes, tools.
- Config split: `USER.example.md` (shipped) vs `USER.md` (local, preserved on upgrade).

### Packaging

- `PACK_INFO.txt` no longer embeds machine/user paths.
- `install.ps1` backs up previous install and preserves `USER.md`.
- Added `VERSION`, `CHANGELOG.md`, `self_check.ps1`.

## 1.0.0 — 2026-07-14

- Initial closeout skill: phases 0–7, status/prune scripts, USER defaults.
