# Changelog

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
