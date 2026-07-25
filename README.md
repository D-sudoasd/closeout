# closeout

[![CI](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml/badge.svg)](https://github.com/D-sudoasd/closeout/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/pwsh-7%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Release](https://img.shields.io/github/v/release/D-sudoasd/closeout)](https://github.com/D-sudoasd/closeout/releases)
[![Skill](https://img.shields.io/badge/agent-skill-0A7-blueviolet.svg)](SKILL.md)

**Ship the work. Leave a clean desk.**

An agent skill for **end-to-end git closeout**: status → verify → commit → push → PR → merge gate → prune — with **authorization boundaries**, **squash-merge awareness**, and an **evidence report** you can re-check.

[中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Install](INSTALL.md) · [Auth matrix](references/auth-matrix.md)

---

## Why closeout?

Unguarded “just commit and push” agents are great at shipping — and also great at:

| Risk | What closeout does |
|------|--------------------|
| Blind `git add -A` | Intentional stage; skip secrets / bulk raw data |
| Pushing red verify | Unified fail policy: stop, local-only, or explicit override |
| Squash merge → “no branches to prune” | Detect via **PR head SHA == branch tip** |
| Treating `origin/HEAD` as a branch | Structured `for-each-ref` (skip symrefs) |
| “I showed the list” = delete remote | **List ≠ authorize**; merge & remote delete are separate |
| “done” after a failed `git push --delete` | `Invoke-Git` exit codes + **post-delete recheck** |
| Overwriting your preferences on upgrade | `USER.example.md` shipped; **`USER.md` preserved** |

---

## What you get

```text
收工 / 收尾 / /closeout
  0  status      read-only one-pager
  0b plan        will / will-not execution list
  2  verify      commands + exit codes
  3  commit      intentional + pre/post HEAD
  4  push        local SHA == remote SHA
  5  PR          reuse or create; head SHA check
  6  merge       gated (ask first by default)
  7  prune       ancestor OR squash-PR match; recheck
```

Scripts (run without the agent if you want):

| Script | Role |
|--------|------|
| `scripts/status.ps1` | Dirty classification, in-progress ops, redacted remotes, PR |
| `scripts/prune_merged.ps1` | Safe candidate list / delete with evidence |
| `scripts/self_check.ps1` | Install layout + parse check |
| `install.ps1` | Upgrade with backup + keep `USER.md` |

---

## Install

### Grok

```powershell
$dst = Join-Path $env:USERPROFILE ".grok\skills\closeout"
git clone https://github.com/D-sudoasd/closeout.git $dst
# or upgrade an existing clone:
# git -C $dst pull
```

### Codex / other agents

```powershell
git clone https://github.com/D-sudoasd/closeout.git "$env:USERPROFILE\.codex\skills\closeout"
```

### Zip / copy install (preserves local prefs)

```powershell
# from a release asset or clone root:
pwsh -File .\install.ps1 -Source .
```

Then restart the agent session and say **收工**, **ship**, or **`/closeout`**.

Copy `USER.example.md` → `USER.md` only on first install if you need local overrides.

---

## Quick start

```powershell
$Skill = Join-Path $env:USERPROFILE ".grok\skills\closeout\scripts"
$Repo  = "D:\path\to\your\repo"

# Read-only status
pwsh -File "$Skill\status.ps1" -RepoRoot $Repo

# Dry-run prune (never deletes without -Apply)
pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo

# After you review SAFE lines:
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply
# Remote delete only with explicit OK:
# pwsh -File "$Skill\prune_merged.ps1" -RepoRoot $Repo -Apply -DeleteRemote
```

Requirements: **git**, **PowerShell 7+** (`pwsh`). **GitHub CLI (`gh`)** for PR/merge and squash-branch detection.

---

## Prune rules (v2)

```text
tip is ancestor of default     → SAFE (classic merge)
merged PR + headOid == tip     → SAFE (squash / rebase merge)
merged PR but tip moved        → HOLD (new commits after merge)
no gh / no PR                  → report only
origin/HEAD / current / default → never delete
```

---

## Authorization (short)

| You say | Default scope |
|---------|----------------|
| 收工 / `/closeout` | Status + verify + plan; push/PR per `USER.md` |
| 提交并推 | Verify + commit + push |
| 合并 | Merge after checks |
| 清分支 | **List only** |
| Explicit remote delete | Remote prune |

Showing a candidate list is **not** permission to delete remotes. Details: [references/auth-matrix.md](references/auth-matrix.md).

---

## Safety defaults

- No force-push of default branch  
- No `branch -D` / `reset --hard` / `clean -fdx` without explicit OK  
- No secrets / bulk scientific raw data in commits  
- Evidence report: SHA, PR, skip reasons, clean-desk YES/NO with basis  

---

## Project layout

```text
closeout/
  SKILL.md              # agent entry (Grok / compatible)
  USER.example.md       # shipped defaults template
  VERSION / CHANGELOG.md
  install.ps1 / INSTALL.md
  references/           # phases, auth, clean desk, report template
  scripts/              # status, prune, self_check, common
```

---

## Contributing

Issues and PRs welcome — especially:

- Cross-platform path / `pwsh` edge cases  
- Extra prune evidence sources  
- Pester fixtures for the scenario matrix in `CHANGELOG` / docs  

Please do **not** commit a real `USER.md` with personal tokens or machine paths.

---

## License

[MIT](LICENSE) © 2026 D-sudoasd
