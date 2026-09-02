<#
.SYNOPSIS
  Fixture tests for shipped closeout scripts (cwd ≠ RepoRoot, squash-SAFE Apply,
  USER never-delete, installer Source==Destination fail-closed).
  Drives scripts/status.ps1, prune_merged.ps1, common.ps1, install.ps1 — not copies.
#>
param(
  [string]$SkillRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SkillRoot) {
  $SkillRoot = Split-Path -Parent $PSScriptRoot
}
$SkillRoot = (Resolve-Path -LiteralPath $SkillRoot).Path

$statusScript = Join-Path $SkillRoot 'scripts\status.ps1'
$pruneScript = Join-Path $SkillRoot 'scripts\prune_merged.ps1'
$installScript = Join-Path $SkillRoot 'install.ps1'

$failed = @()
function Assert-Step {
  param([string]$Name, [scriptblock]$Body)
  Write-Output "ASSERT $Name"
  try {
    & $Body
    Write-Output "PASS $Name"
  } catch {
    Write-Output "FAIL $Name : $_"
    $script:failed += $Name
  }
}

function Invoke-PwshFile {
  param([string]$File, [string[]]$Arguments, [string]$WorkingDirectory)
  $old = Get-Location
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $output = & pwsh -NoProfile -File $File @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    Set-Location $old
  }
  [pscustomobject]@{
    ExitCode = $code
    StdOut   = [string]$output
    StdErr   = ''
    Combined = [string]$output
  }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("closeout-fixtures-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work | Out-Null
$otherCwd = Join-Path $work 'other-cwd'
New-Item -ItemType Directory -Path $otherCwd | Out-Null

Write-Output "# closeout test_fixtures"
Write-Output "- skill_root: $SkillRoot"
Write-Output "- work: $work"
Write-Output "- other_cwd: $otherCwd"

$oldPath = $env:PATH
try {
  $repo = Join-Path $work 'repo'
  New-Item -ItemType Directory -Path $repo | Out-Null
  Push-Location $repo
  try {
    git init -b main | Out-Null
    git config user.email "ci@example.com"
    git config user.name "CI"
    "a" | Set-Content file.txt
    git add file.txt
    git commit -m "init" | Out-Null

    git branch feat/demo
    git checkout feat/demo | Out-Null
    "b" | Set-Content file.txt
    git add file.txt
    git commit -m "feat" | Out-Null
    git checkout main | Out-Null
    git merge --no-ff feat/demo -m "merge feat" | Out-Null

    git branch release
    git checkout release | Out-Null
    "r" | Set-Content release.txt
    git add release.txt
    git commit -m "release" | Out-Null
    git checkout main | Out-Null
    git merge --no-ff release -m "merge release" | Out-Null

    git checkout -b feat/squash | Out-Null
    "s" | Set-Content squash.txt
    git add squash.txt
    git commit -m "squash-only" | Out-Null
    $squashTip = (git rev-parse feat/squash).Trim()
    git checkout main | Out-Null
    git remote add origin https://github.com/example-org/fixture-repo.git
  } finally {
    Pop-Location
  }

  $fakeBin = Join-Path $work 'fake-bin'
  New-Item -ItemType Directory -Path $fakeBin | Out-Null
  $ghLog = Join-Path $work 'fake-gh.log'
  $ghImpl = Join-Path $fakeBin 'gh-impl.ps1'
  @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
$log = $env:CLOSEOUT_FAKE_GH_LOG
if ($log) {
  Add-Content -LiteralPath $log -Value ("PWD=" + (Get-Location).Path)
  Add-Content -LiteralPath $log -Value ("ARGS=" + ($GhArgs -join ' '))
}
$joined = ($GhArgs -join ' ')
if ($joined -match 'repo view') { Write-Output 'main'; exit 0 }
if ($joined -match 'pr view') { exit 1 }
if ($joined -match 'pr list') {
  $prFile = $env:CLOSEOUT_FAKE_PR_JSON
  if ($prFile -and (Test-Path -LiteralPath $prFile)) {
    Get-Content -LiteralPath $prFile -Raw
    exit 0
  }
  Write-Output '[]'
  exit 0
}
exit 1
'@ | Set-Content -LiteralPath $ghImpl -Encoding utf8
  @(
    '@echo off'
    'pwsh -NoProfile -File "%~dp0gh-impl.ps1" %*'
  ) | Set-Content -LiteralPath (Join-Path $fakeBin 'gh.cmd') -Encoding ascii

  $userCfg = Join-Path $work 'USER.md'
  @(
    '| Key | Value |'
    '|-----|--------|'
    '| `default_branch_prefer` | `main` |'
    '| `never_delete_branches` | `main`, `master`, `develop`, `release` |'
  ) | Set-Content -LiteralPath $userCfg -Encoding utf8

  $mergedPrPath = Join-Path $work 'merged-pr.json'
  @(
    [ordered]@{
      headRefName = 'feat/squash'
      headRefOid  = $squashTip
      number      = 1
      url         = 'https://example.test/pr/1'
      state       = 'MERGED'
      mergedAt    = '2026-01-01T00:00:00Z'
    }
  ) | ConvertTo-Json | Set-Content -LiteralPath $mergedPrPath -Encoding utf8
  $mergedPrJson = $mergedPrPath
  $env:CLOSEOUT_FAKE_GH_LOG = $ghLog
  $env:CLOSEOUT_FAKE_PR_JSON = $mergedPrPath
  $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH

  Assert-Step 'cwd!=RepoRoot status classifies fixture' {
    $r = Invoke-PwshFile -File $statusScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo
    )
    if ($r.ExitCode -ne 0) { throw "status exit $($r.ExitCode)`n$($r.Combined)" }
    if ($r.Combined -notmatch [regex]::Escape($repo)) {
      throw "status did not print fixture root. output:`n$($r.Combined)"
    }
    if ($r.Combined -notmatch 'branch: main') {
      throw "status did not report fixture branch main. output:`n$($r.Combined)"
    }
    if ($r.Combined -match [regex]::Escape($otherCwd)) {
      throw "status printed other-cwd as root"
    }
    if ($r.Combined -notmatch 'feat/demo') {
      throw "status did not classify ancestor-merged feat/demo"
    }
    if (-not (Test-Path -LiteralPath $ghLog)) { throw "fake gh did not log (GitHub context unused)" }
    $ghText = Get-Content -LiteralPath $ghLog -Raw
    $repoNorm = $repo.Replace('\', '/')
    $pwdOk = ($ghText -replace '\\', '/') -match [regex]::Escape($repoNorm)
    if (-not $pwdOk) { throw "fake gh cwd was not RepoRoot. log:`n$ghText" }
    if ($ghText -notmatch '-R example-org/fixture-repo') {
      throw "fake gh was not invoked with -R example-org/fixture-repo. log:`n$ghText"
    }
    if (($ghText -replace '\\', '/') -match [regex]::Escape($otherCwd.Replace('\', '/'))) {
      throw "fake gh ran in other-cwd. log:`n$ghText"
    }
  }

  Assert-Step 'cwd!=RepoRoot prune classifies fixture' {
    $r = Invoke-PwshFile -File $pruneScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo,
      '-UserConfigPath', $userCfg,
      '-MergedPrJson', $mergedPrJson,
      '-Json'
    )
    if ($r.ExitCode -ne 0) { throw "prune dry-run exit $($r.ExitCode)`n$($r.Combined)" }
    $jsonText = $r.StdOut
    if ($jsonText -notmatch 'feat/squash') { throw "prune JSON missing feat/squash`n$jsonText" }
    if ($jsonText -notmatch 'squash-or-rebase-merged') { throw "prune JSON missing squash-or-rebase-merged`n$jsonText" }
    if ($jsonText -notmatch 'feat/demo') { throw "prune JSON missing feat/demo`n$jsonText" }
    if ($jsonText -notmatch 'ancestor-merged') { throw "prune JSON missing ancestor-merged`n$jsonText" }
  }

  Assert-Step 'squash-SAFE absent after Apply' {
    $r = Invoke-PwshFile -File $pruneScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo,
      '-UserConfigPath', $userCfg,
      '-MergedPrJson', $mergedPrJson,
      '-Apply',
      '-Json'
    )
    if ($r.ExitCode -ne 0) { throw "prune -Apply exit $($r.ExitCode)`n$($r.Combined)" }
    Push-Location $repo
    try {
      $squashStill = git rev-parse --verify --quiet refs/heads/feat/squash 2>$null
      if ($LASTEXITCODE -eq 0 -and $squashStill) {
        throw "feat/squash still exists after Apply (tip $squashStill)"
      }
      $demoStill = git rev-parse --verify --quiet refs/heads/feat/demo 2>$null
      if ($LASTEXITCODE -eq 0 -and $demoStill) {
        throw "feat/demo still exists after Apply"
      }
    } finally {
      Pop-Location
    }
    Write-Output "squash-SAFE and ancestor-merged locals removed"
  }

  Assert-Step 'never-delete extra name not deleted' {
    Push-Location $repo
    try {
      git rev-parse --verify --quiet refs/heads/release | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "release branch missing after Apply (never_delete should keep it)" }
      git rev-parse --verify --quiet refs/heads/main | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "main missing after Apply" }
    } finally {
      Pop-Location
    }
    Write-Output "USER never-delete extra name 'release' kept"
  }

  Assert-Step 'installer Source==Destination fail-closed SKILL.md at dest root' {
    $pack = Join-Path $work 'pack'
    New-Item -ItemType Directory -Path (Join-Path $pack 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'SKILL.md') -Destination (Join-Path $pack 'SKILL.md')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'USER.example.md') -Destination (Join-Path $pack 'USER.example.md')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'VERSION') -Destination (Join-Path $pack 'VERSION')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\common.ps1') -Destination (Join-Path $pack 'scripts\common.ps1')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\status.ps1') -Destination (Join-Path $pack 'scripts\status.ps1')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\prune_merged.ps1') -Destination (Join-Path $pack 'scripts\prune_merged.ps1')
    $sentinel = 'sentinel-user-config'
    $sentinel | Set-Content -LiteralPath (Join-Path $pack 'USER.md') -Encoding utf8

    $r = Invoke-PwshFile -File $installScript -WorkingDirectory $otherCwd -Arguments @(
      '-Source', $pack,
      '-Destination', $pack
    )
    if ($r.ExitCode -eq 0) { throw "install succeeded for Source==Destination; must fail closed`n$($r.Combined)" }
    # pwsh ErrorRecord wrapping inserts "|" between words; match tokens that survive that.
    if ($r.Combined -notmatch 'same path' -or $r.Combined -notmatch 'Refusing') {
      throw "install did not fail on the Source==Destination guard. output:`n$($r.Combined)"
    }
    if ($r.Combined -match 'Backed up previous install' -or $r.Combined -match 'INSTALL FAILED') {
      throw "install reached Move-Item/catch instead of fail-closed guard. output:`n$($r.Combined)"
    }
    $skillAtRoot = Join-Path $pack 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillAtRoot)) {
      throw "SKILL.md missing at destination root after failed install"
    }
    $userAfter = Get-Content -LiteralPath (Join-Path $pack 'USER.md') -Raw
    if ($userAfter -notmatch 'sentinel-user-config') {
      throw "USER.md was overwritten or nested during Source==Destination install"
    }
    $backups = @(Get-ChildItem -LiteralPath $work -Directory -Filter 'pack.backup-*' -ErrorAction SilentlyContinue)
    if ($backups.Count -gt 0) {
      throw "backup dir created despite Source==Destination guard: $($backups.Name -join ',')"
    }
    Write-Output "installer refused same-path install; SKILL.md remains at dest root"
  }

  Assert-Step 'installer Source-inside-Destination fail-closed' {
    $parent = Join-Path $work 'install-parent'
    $child = Join-Path $parent 'src'
    New-Item -ItemType Directory -Path (Join-Path $child 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'SKILL.md') -Destination (Join-Path $child 'SKILL.md')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\common.ps1') -Destination (Join-Path $child 'scripts\common.ps1')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\status.ps1') -Destination (Join-Path $child 'scripts\status.ps1')
    Copy-Item -LiteralPath (Join-Path $SkillRoot 'scripts\prune_merged.ps1') -Destination (Join-Path $child 'scripts\prune_merged.ps1')
    $r = Invoke-PwshFile -File $installScript -WorkingDirectory $otherCwd -Arguments @(
      '-Source', $child,
      '-Destination', $parent
    )
    if ($r.ExitCode -eq 0) { throw "nested Source should fail`n$($r.Combined)" }
    $nestedFlat = ($r.Combined -replace '\s+', ' ')
    if ($nestedFlat -notmatch 'Source is inside Destination') {
      throw "missing nested-source guard. output:`n$($r.Combined)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $child 'SKILL.md'))) {
      throw "nested source SKILL.md was removed"
    }
  }
}
finally {
  $env:PATH = $oldPath
  Remove-Item Env:CLOSEOUT_FAKE_GH_LOG -ErrorAction SilentlyContinue
  Remove-Item Env:CLOSEOUT_FAKE_PR_JSON -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($failed.Count -gt 0) {
  Write-Output "RESULT: FAIL ($($failed.Count) assertions): $($failed -join ', ')"
  exit 1
}
Write-Output "RESULT: PASS"
exit 0
