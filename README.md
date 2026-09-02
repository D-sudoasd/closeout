# closeout

[![CI](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml/badge.svg)](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/pwsh-7%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Release](https://img.shields.io/github/v/release/D-sudoasd/closeout)](https://github.com/D-sudoasd/closeout/releases)
[![Skill](https://img.shields.io/badge/agent-skill-0A7-blueviolet.svg)](SKILL.md)

**Ship the work. Leave a clean desk.**

Agent skill for end-to-end git closeout: status → verify → commit → push → PR → merge gate → prune — with **authorization boundaries**, **squash-merge awareness**, and an **evidence report** you can re-check.

[中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Install](INSTALL.md) · [Auth matrix](references/auth-matrix.md) · [Promote kit](docs/PROMOTE.md)

<p align="center">
  <img src="assets/readme/hero.svg" width="100%" alt="closeout hero: ship work, leave a clean desk, with evidence report card" />
</p>

---

## Why not “just let the agent push”?

| Risk with unguarded agents | What closeout does |
|----------------------------|--------------------|
| Blind `git add -A` | Intentional stage; skip secrets / bulk raw data |
| Pushing red verify | Fail stops push unless you re-authorize |
| Squash merge → “nothing to prune” | SAFE when **PR head SHA == branch tip**; authorized `-Apply` actually deletes the local ref |
| Treating `origin/HEAD` as a branch | Structured `for-each-ref` (skip symrefs) |
| “I showed the list” = delete remote | **List ≠ authorize** |
| “done” after a failed delete | Exit codes + **post-delete recheck** |
| Upgrade wipes preferences | `USER.example.md` ships; **`USER.md` stays** |
| Scripts run from another directory | Pass an **absolute `-RepoRoot`**; `git` and `gh` follow that repo (not process cwd) |

<p align="center">
  <img src="assets/readme/before-after.svg" width="100%" alt="Before unguarded agent push versus after closeout evidence-based clean desk" />
</p>

---

## How it works

Say **收工**, **ship**, or **`/closeout`** to a compatible agent (Grok / Codex).

<p align="center">
  <img src="assets/readme/workflow.svg" width="100%" alt="closeout workflow: status, plan, verify, commit push PR, merge ask, prune with SAFE and HOLD gates" />
</p>

| Phase | Action | Gate |
|------:|--------|------|
| 0 | `status.ps1` one-pager | report only |
| 0b | will / will-not plan | user OK or USER default |
| 2 | verify + exit codes (repo tests; no required extra skill) | green, or explicit fail policy |
| 3–5 | commit · push · PR | SHA + PR head checks |
| 6 | merge | **ask first** by default |
| 7 | prune | list → confirm; remote separate |

**Scripts alone** (no agent required). Always pass the **target repo** as `-RepoRoot` — cwd can be anywhere:

```powershell
$Skill = Join-Path $env:USERPROFILE ".grok\skills\closeout\scripts"
$Repo  = "D:\path\to\your\repo"   # absolute path

pwsh -File "$Skill\status.ps1" -RepoRoot $Repo
pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo          # dry-run
# after you confirm the SAFE list:
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply -DeleteRemote
```

`prune_merged.ps1` reads `never_delete_branches` and `default_branch_prefer` from `USER.md` (else `USER.example.md`). Squash-SAFE locals are removed on `-Apply` even when `git branch -d` would refuse.

---

## Install (≈30 seconds)

### Grok

```powershell
git clone https://github.com/D-sudoasd/closeout.git "$env:USERPROFILE\.grok\skills\closeout"
# upgrade later:
# git -C "$env:USERPROFILE\.grok\skills\closeout" pull
```

### Codex / other agents

```powershell
git clone https://github.com/D-sudoasd/closeout.git "$env:USERPROFILE\.codex\skills\closeout"
```

### Copy install (keeps local `USER.md`)

```powershell
pwsh -File .\install.ps1 -Source . -Destination "$env:USERPROFILE\.grok\skills\closeout"
```

Do **not** run the installer with Source and Destination the same folder (that would be the live clone). Upgrade an existing clone with `git pull`.

Needs: **git**, **pwsh 7+**, and **`gh`** for PR/merge + squash detection.  
Restart the agent session, then say **收工**.

---

## Prune rules (v2)

```text
tip is ancestor of default     → SAFE (classic merge)
merged PR + headOid == tip     → SAFE (squash / rebase)
merged PR but tip moved        → HOLD (new commits after merge)
no gh / no PR                  → report only
origin/HEAD · current · default → never delete
```

---

## Authorization (short)

| You say | Default scope |
|---------|----------------|
| 收工 / `/closeout` | Status + verify + **plan**; shipped `confirm_push=true` → one OK covers commit→push→PR. Never auto-merge or remote-delete. |
| 提交并推 | Verify + commit + push |
| 合并 | Merge after checks |
| 清分支 | **List only** |
| Explicit remote delete | Remote prune |

Details: [references/auth-matrix.md](references/auth-matrix.md).

---

## Project layout

```text
closeout/
  SKILL.md              agent entry
  USER.example.md       shipped defaults (copy → USER.md locally)
  assets/readme/        hero · workflow · before-after
  references/           phases · auth · clean desk · report
  scripts/              status · prune · self_check · common · fixture tests
  docs/PROMOTE.md       shareable posts
```

---

## Contributing

Issues and PRs welcome — especially cross-platform path edges, extra prune evidence sources, and more fixture cases (`scripts/test_fixtures.ps1`).

Please **do not** commit a real `USER.md`.

---

## License

[MIT](LICENSE) © 2026 D-sudoasd
