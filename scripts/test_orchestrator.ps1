<#
.SYNOPSIS
  Integration fixtures for closeout.ps1 and cleanup_temp.ps1.

  Uses a local bare remote and a fake gh executable. No network or real
  repository is mutated.
#>
[CmdletBinding()]
param(
  [string]$SkillRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SkillRoot) { $SkillRoot = Split-Path -Parent $PSScriptRoot }
$SkillRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$closeoutScript = Join-Path $SkillRoot 'scripts\closeout.ps1'
$cleanupScript = Join-Path $SkillRoot 'scripts\cleanup_temp.ps1'

$failed = New-Object 'System.Collections.Generic.List[string]'
$skipped = New-Object 'System.Collections.Generic.List[string]'
function Assert-Step {
  param([string]$Name, [scriptblock]$Body)
  Write-Output "ASSERT $Name"
  try {
    & $Body
    Write-Output "PASS $Name"
  } catch {
    Write-Output "FAIL $Name : $($_)"
    [void]$failed.Add($Name)
  }
}

function New-LocalFixtureRepo {
  param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$ForkRemotes
  )

  $fixtureRemote = Join-Path $work "$Name-remote.git"
  $fixtureRepo = Join-Path $work $Name
  $null = & git init --bare $fixtureRemote 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git init --bare failed for $fixtureRemote" }
  New-Item -ItemType Directory -Path $fixtureRepo | Out-Null
  $null = & git -C $fixtureRepo init -b main 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git init failed for $fixtureRepo" }
  $null = & git -C $fixtureRepo config user.email 'ci@example.com' 2>&1
  $null = & git -C $fixtureRepo config user.name 'Closeout CI' 2>&1
  'base' | Set-Content -LiteralPath (Join-Path $fixtureRepo 'README.md') -Encoding utf8
  $null = Invoke-GitText -Root $fixtureRepo -Arguments @('add', 'README.md')
  $null = Invoke-GitText -Root $fixtureRepo -Arguments @('commit', '-m', 'init')

  if ($ForkRemotes) {
    $originUrl = 'https://github.com/fork-owner/fork-repo.git'
    $null = Invoke-GitText -Root $fixtureRepo -Arguments @('remote', 'add', 'origin', $originUrl)
    $null = Invoke-GitText -Root $fixtureRepo -Arguments @('config', "url.$fixtureRemote.insteadOf", $originUrl)
    $null = Invoke-GitText -Root $fixtureRepo -Arguments @('remote', 'add', 'upstream', 'https://github.com/parent-owner/parent-repo.git')
  } else {
    $null = Invoke-GitText -Root $fixtureRepo -Arguments @('remote', 'add', 'origin', $fixtureRemote)
  }
  $null = Invoke-GitText -Root $fixtureRepo -Arguments @('push', '-u', 'origin', 'main')
  [pscustomobject]@{ Root = $fixtureRepo; Remote = $fixtureRemote }
}

function Set-FakeGhState {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
  $State | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Try-NewFixtureJunction {
  param(
    [Parameter(Mandatory)][string]$Link,
    [Parameter(Mandatory)][string]$Target
  )
  try {
    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
      throw "created item is not a reparse point: $Link"
    }
    [pscustomobject]@{ created = $true; error = '' }
  } catch {
    if (Test-Path -LiteralPath $Link) {
      Remove-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ created = $false; error = "$($_)" }
  }
}

function Add-DirtyFixtureBranch {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$RelativePath,
    [string]$Content = 'fixture change'
  )
  $null = Invoke-GitText -Root $Root -Arguments @('switch', '-c', $Branch)
  $full = Join-Path $Root ($RelativePath -replace '/', '\')
  $parent = Split-Path -Parent $full
  if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $Content | Set-Content -LiteralPath $full -Encoding utf8
}

function Get-FullRunReportText {
  param(
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$ApplyOutput
  )
  $reportPath = Join-Path $RunRoot 'report.md'
  if (Test-Path -LiteralPath $reportPath) {
    return Get-Content -LiteralPath $reportPath -Raw
  }
  try {
    $json = $ApplyOutput | ConvertFrom-Json
    if ($json.report -and (Test-Path -LiteralPath $json.report)) {
      return Get-Content -LiteralPath $json.report -Raw
    }
  } catch {}
  return ''
}

function Invoke-PwshFile {
  param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory)][string]$WorkingDirectory
  )
  $old = Get-Location
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $output = & pwsh -NoProfile -File $File @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    Set-Location -LiteralPath $old
  }
  [pscustomobject]@{
    ExitCode = $code
    Output = [string]$output
  }
}

function Invoke-GitText {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )
  $output = & git -C $Root @Arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  if ($code -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $output" }
  [pscustomobject]@{ ExitCode = $code; Output = [string]$output }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('closeout-orchestrator-' + [guid]::NewGuid().ToString('n'))
$otherCwd = Join-Path $work 'other-cwd'
$fakeBin = Join-Path $work 'fake-bin'
$remote = Join-Path $work 'remote.git'
$repo = Join-Path $work 'repo'
$ghState = Join-Path $work 'gh-state.json'
$ghLog = Join-Path $work 'gh.log'
New-Item -ItemType Directory -Path $otherCwd, $fakeBin | Out-Null

$oldPath = $env:PATH
$oldState = $env:CLOSEOUT_FAKE_GH_STATE
$oldRemote = $env:CLOSEOUT_FAKE_REMOTE
$oldLog = $env:CLOSEOUT_FAKE_GH_LOG
$oldFail = $env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE
$oldRequireChecks = $env:CLOSEOUT_FAKE_REQUIRE_CHECKS
$oldPendingChecks = $env:CLOSEOUT_FAKE_CHECK_PENDING

try {
  Write-Output "# closeout test_orchestrator"
  Write-Output "- skill_root: $SkillRoot"
  Write-Output "- work: $work"

  git init --bare $remote | Out-Null
  New-Item -ItemType Directory -Path $repo | Out-Null
  Push-Location $repo
  try {
    git init -b main | Out-Null
    git config user.email 'ci@example.com'
    git config user.name 'Closeout CI'
    'base' | Set-Content -LiteralPath (Join-Path $repo 'README.md') -Encoding utf8
    git add README.md
    git commit -m 'init' | Out-Null
    $originUrl = 'https://github.com/fixture-owner/fixture-repo.git'
    git remote add origin $originUrl
    git config url.$remote.insteadOf $originUrl
    $configuredOrigin = (git config --get remote.origin.url).Trim()
    if ($configuredOrigin -ne $originUrl) { throw "fixture origin config changed unexpectedly: $configuredOrigin" }
    git push -u origin main | Out-Null
  } finally {
    Pop-Location
  }

  $ghScript = Join-Path $fakeBin 'gh-impl.ps1'
  @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
$log = $env:CLOSEOUT_FAKE_GH_LOG
if ($log) { Add-Content -LiteralPath $log -Value (($GhArgs -join ' ')) }
$statePath = $env:CLOSEOUT_FAKE_GH_STATE
$repoRoot = (Get-Location).Path
$remotePath = $env:CLOSEOUT_FAKE_REMOTE

function Read-State {
  if (-not (Test-Path -LiteralPath $statePath)) {
    return [pscustomobject]@{ state = 'NONE'; number = 1; merge_attempts = 0 }
  }
  return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
}
function Save-State($value) {
  $value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8
}
function Write-Array($items) {
  ConvertTo-Json -InputObject ([object[]]@($items)) -Depth 12
}

$joined = $GhArgs -join ' '
if ($joined -match 'repo view') { Write-Output 'main'; exit 0 }

$state = Read-State
if ($joined -match 'pr view') {
  if ($state.state -eq 'NONE') { exit 1 }
  $state | ConvertTo-Json -Depth 12
  exit 0
}
if ($joined -match 'pr list') {
  if ($state.state -eq 'NONE') { Write-Array @(); exit 0 }
  if ($joined -match '--state merged' -and $state.state -ne 'MERGED') { Write-Array @(); exit 0 }
  if ($joined -match '--state closed' -and $state.state -ne 'CLOSED') { Write-Array @(); exit 0 }
  Write-Array @($state)
  exit 0
}
if ($joined -match 'pr checks') {
  $observed = if ($state.checks_observed) { [int]$state.checks_observed } else { 0 }
  $state.checks_observed = $observed + 1
  Save-State $state
  Write-Output 'checks passed'
  exit 0
}
if ($joined -match 'pr create') {
  $headIndex = [Array]::IndexOf($GhArgs, '--head')
  $baseIndex = [Array]::IndexOf($GhArgs, '--base')
  $head = if ($headIndex -ge 0) { $GhArgs[$headIndex + 1] } else { (git branch --show-current).Trim() }
  $base = if ($baseIndex -ge 0) { $GhArgs[$baseIndex + 1] } else { 'main' }
  $headSha = (git rev-parse HEAD).Trim()
  $requireChecks = ($env:CLOSEOUT_FAKE_REQUIRE_CHECKS -eq '1')
  $checkRollup = if ($env:CLOSEOUT_FAKE_CHECK_PENDING -eq '1') {
    @([pscustomobject]@{ name = 'fixture-check'; status = 'IN_PROGRESS'; conclusion = ''; state = 'PENDING' })
  } else {
    @([pscustomobject]@{ name = 'fixture-check'; status = 'COMPLETED'; conclusion = 'SUCCESS'; state = 'SUCCESS' })
  }
  $state = [pscustomobject]@{
    state = 'OPEN'
    number = 1
    url = 'https://example.test/pr/1'
    title = 'fixture closeout'
    mergeable = 'MERGEABLE'
    isDraft = $false
    baseRefName = $base
    headRefName = $head
    headRefOid = $headSha
    mergedAt = $null
    mergeCommit = $null
    reviewDecision = 'APPROVED'
    mergeStateStatus = 'CLEAN'
    statusCheckRollup = $checkRollup
    require_checks = $requireChecks
    checks_observed = 0
    merge_attempts = 0
  }
  Save-State $state
  Write-Output $state.url
  exit 0
}
if ($joined -match 'pr merge') {
  $number = $GhArgs | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
  if (-not $number) { exit 1 }
  if ([bool]$state.require_checks -and [int]$state.checks_observed -lt 1) {
    [Console]::Error.WriteLine('required checks were not observed')
    exit 1
  }
  if ($env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE -eq '1' -and [int]$state.merge_attempts -eq 0) {
    $state.merge_attempts = 1
    Save-State $state
    [Console]::Error.WriteLine('required checks are not complete')
    exit 1
  }
  $headSha = $state.headRefOid
  $mergeRoot = Join-Path ([IO.Path]::GetTempPath()) ('closeout-fake-merge-' + [guid]::NewGuid().ToString('n'))
  git clone $remotePath $mergeRoot | Out-Null
  git -C $mergeRoot config user.email 'ci@example.com'
  git -C $mergeRoot config user.name 'Closeout CI'
  git -C $mergeRoot checkout main | Out-Null
  if ($joined -match '--merge(?:\s|$)') {
    git -C $mergeRoot merge --no-ff $headSha -m 'Merge fixture PR #1' | Out-Null
  } elseif ($joined -match '--rebase(?:\s|$)') {
    git -C $mergeRoot merge --ff-only $headSha | Out-Null
  } else {
    git -C $mergeRoot merge --squash $headSha | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $mergeRoot -Recurse -Force; exit 1 }
  if ($joined -notmatch '--merge(?:\s|$)' -and $joined -notmatch '--rebase(?:\s|$)') {
    git -C $mergeRoot commit -m 'Merge fixture PR #1' | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $mergeRoot -Recurse -Force; exit 1 }
  }
  git -C $mergeRoot push origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $mergeRoot -Recurse -Force; exit 1 }
  $mergeSha = (git -C $mergeRoot rev-parse HEAD).Trim()
  Remove-Item -LiteralPath $mergeRoot -Recurse -Force
  $state.state = 'MERGED'
  $state.mergedAt = '2026-01-01T00:00:00Z'
  $state.mergeCommit = [pscustomobject]@{ oid = $mergeSha }
  Save-State $state
  Write-Output 'merged'
  exit 0
}
exit 1
'@ | Set-Content -LiteralPath $ghScript -Encoding utf8
  @(
    '@echo off'
    'pwsh -NoProfile -File "%~dp0gh-impl.ps1" %*'
  ) | Set-Content -LiteralPath (Join-Path $fakeBin 'gh.cmd') -Encoding ascii
  @{ state = 'NONE'; number = 1; merge_attempts = 0 } | ConvertTo-Json | Set-Content -LiteralPath $ghState -Encoding utf8

  $env:CLOSEOUT_FAKE_GH_STATE = $ghState
  $env:CLOSEOUT_FAKE_REMOTE = $remote
  $env:CLOSEOUT_FAKE_GH_LOG = $ghLog
  $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath

  Assert-Step 'plan detects branch, stage policy, and temp policy' {
    Push-Location $repo
    try {
      New-Item -ItemType Directory -Path (Join-Path $repo '__pycache__') | Out-Null
      'cache' | Set-Content -LiteralPath (Join-Path $repo '__pycache__\generated.pyc') -Encoding utf8
      'safe code' | Set-Content -LiteralPath (Join-Path $repo 'change.ps1') -Encoding utf8
      'secret' | Set-Content -LiteralPath (Join-Path $repo '.env') -Encoding utf8
      'raw' | Set-Content -LiteralPath (Join-Path $repo 'scan.cbf') -Encoding utf8
      New-Item -ItemType Directory -Path (Join-Path $repo 'tmp') | Out-Null
      'keep' | Set-Content -LiteralPath (Join-Path $repo 'tmp\keep.txt') -Encoding utf8
    } finally {
      Pop-Location
    }
    $r = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Plan', '-Json', '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($r.ExitCode -ne 3) { throw "classification plan should require review: exit $($r.ExitCode): $($r.Output)" }
    $plan = $r.Output | ConvertFrom-Json
    if ($plan.status -ne 'BLOCKED') { throw "classification plan should be blocked: $($plan.status)" }
    if (-not $plan.branch.create -or $plan.branch.initial -ne 'main') { throw 'default branch was not converted to a feature plan' }
    if ('change.ps1' -notin @($plan.staging.include)) { throw 'safe code was not selected' }
    $envFile = @($plan.staging.exclude | Where-Object { $_.path -eq '.env' })
    if ($envFile.Count -ne 1 -or $envFile[0].reason -ne 'sensitive-path') { throw 'secret exclusion missing' }
    $rawFile = @($plan.staging.exclude | Where-Object { $_.path -eq 'scan.cbf' })
    if ($rawFile.Count -ne 1 -or $rawFile[0].reason -ne 'raw-data-like') { throw 'raw data exclusion missing' }
    if (@($plan.temp_cleanup.candidates | Where-Object { $_.relative_path -eq '__pycache__' }).Count -ne 1) { throw 'cache candidate missing' }
    if (@($plan.temp_cleanup.candidates | Where-Object { $_.relative_path -eq 'tmp' }).Count -ne 0) { throw 'generic tmp was included by default' }
    if (@($plan.blockers | Where-Object { $_ -match 'sensitive-path' }).Count -ne 1) { throw 'sensitive path was not a blocker' }
  }

  Assert-Step 'stale plan refuses apply without mutation' {
    Remove-Item -LiteralPath (Join-Path $repo '.env'), (Join-Path $repo 'scan.cbf'), (Join-Path $repo 'tmp') -Recurse -Force
    $validPlanCall = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Plan', '-Json', '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($validPlanCall.ExitCode -ne 0) { throw "valid plan exit $($validPlanCall.ExitCode): $($validPlanCall.Output)" }
    $validPlan = $validPlanCall.Output | ConvertFrom-Json
    $planPath = Join-Path $validPlan.run_root 'plan.json'
    'changed after plan' | Set-Content -LiteralPath (Join-Path $repo 'change.ps1') -Encoding utf8
    $r = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Apply', '-PlanFile', $planPath
    )
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'STALE_PLAN') { throw "stale apply was not rejected: $($r.Output)" }
    if (Test-Path -LiteralPath (Join-Path $validPlan.run_root 'state.json')) { throw 'stale apply created a state file' }
    'safe code' | Set-Content -LiteralPath (Join-Path $repo 'change.ps1') -Encoding utf8
  }

  Assert-Step 'cleanup rejects tracked and outside paths' {
    $trackedCache = Join-Path $work 'tracked-cache-repo'
    New-Item -ItemType Directory -Path $trackedCache | Out-Null
    git init -b main $trackedCache | Out-Null
    git -C $trackedCache config user.email 'ci@example.com'
    git -C $trackedCache config user.name 'Closeout CI'
    New-Item -ItemType Directory -Path (Join-Path $trackedCache '__pycache__') | Out-Null
    'tracked' | Set-Content -LiteralPath (Join-Path $trackedCache '__pycache__\tracked.pyc') -Encoding utf8
    git -C $trackedCache add . | Out-Null
    git -C $trackedCache commit -m init | Out-Null
    $outside = Join-Path $work 'outside.txt'
    'outside' | Set-Content -LiteralPath $outside -Encoding utf8
    $r = Invoke-PwshFile -File $cleanupScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $trackedCache, '-Path', '..\outside.txt', '-Json'
    )
    if ($r.ExitCode -ne 0) { throw "cleanup dry-run exit $($r.ExitCode): $($r.Output)" }
    $result = $r.Output | ConvertFrom-Json
    if (Test-Path -LiteralPath (Join-Path $trackedCache '__pycache__\tracked.pyc')) { } else { throw 'tracked cache was removed' }
    if (@($result.rejected | Where-Object { $_.reason -eq 'tracked-by-git' }).Count -eq 0) { throw 'tracked path was not rejected' }
    if (@($result.rejected | Where-Object { $_.reason -eq 'explicit-path-not-relative' }).Count -eq 0) { throw 'outside path was not rejected' }
  }

  Assert-Step 'config is applied and origin changes are rejected' {
    $config = Join-Path $work 'USER-config.md'
    @(
      '| Key | Value |'
      '|-----|-------|'
      '| `prefer_pr` | `true` |'
      '| `merge_strategy` | `merge` |'
      '| `wait_for_checks` | `true` |'
      '| `full_run_confirmation` | `true` |'
      '| `prune_local_merged` | `false` |'
      '| `prune_remote_merged` | `false` |'
    ) | Set-Content -LiteralPath $config -Encoding utf8
    $planned = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Plan', '-Json', '-UserConfigPath', $config, '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($planned.ExitCode -ne 0) { throw "config plan exit $($planned.ExitCode): $($planned.Output)" }
    $plan = $planned.Output | ConvertFrom-Json
    if ($plan.pr.merge_strategy -ne 'merge' -or -not $plan.pr.wait_for_checks) { throw 'merge/check configuration was not persisted in plan' }
    if ($plan.pr.required -ne $true -or $plan.prune.delete_local -ne $false -or $plan.prune.delete_remote -ne $false) {
      throw 'PR/prune configuration was not persisted in plan'
    }
    if (@($plan.will_execute | Where-Object { $_ -match '--merge' }).Count -ne 1) { throw 'configured merge action missing from plan' }

    $originalOrigin = (Invoke-GitText -Root $repo -Arguments @('config', '--get', 'remote.origin.url')).Output.Trim()
    $alternateOrigin = Join-Path $work 'alternate-origin.git'
    $null = Invoke-GitText -Root $repo -Arguments @('remote', 'set-url', 'origin', $alternateOrigin)
    try {
      $apply = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
        '-RepoRoot', $repo, '-Apply', '-PlanFile', (Join-Path $plan.run_root 'plan.json'), '-Json'
      )
      if ($apply.ExitCode -eq 0 -or $apply.Output -notmatch 'origin remote changed since plan') {
        throw "origin change was accepted: $($apply.Output)"
      }
    } finally {
      $null = Invoke-GitText -Root $repo -Arguments @('remote', 'set-url', 'origin', $originalOrigin)
    }
  }

  Assert-Step 'cleanup holds a reparse-point ancestor' {
    $junctionRepo = New-LocalFixtureRepo -Name 'junction'
    $junctionTarget = Join-Path $work 'junction-target'
    New-Item -ItemType Directory -Path (Join-Path $junctionTarget '__pycache__') -Force | Out-Null
    'keep' | Set-Content -LiteralPath (Join-Path $junctionTarget '__pycache__\keep.pyc') -Encoding utf8
    $junction = Join-Path $junctionRepo.Root 'cache-link'
    $created = Try-NewFixtureJunction -Link $junction -Target $junctionTarget
    if (-not $created.created) {
      [void]$skipped.Add('junction fixture unavailable')
      return
    }
    $r = Invoke-PwshFile -File $cleanupScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $junctionRepo.Root, '-Path', 'cache-link\__pycache__', '-Json'
    )
    if ($r.ExitCode -ne 0) { throw "junction dry-run unexpectedly failed: $($r.Output)" }
    $result = $r.Output | ConvertFrom-Json
    if (@($result.rejected | Where-Object { $_.reason -in @('reparse-ancestor', 'reparse-point') }).Count -eq 0) {
      throw "reparse ancestor was not rejected: $($r.Output)"
    }
    if (-not (Test-Path -LiteralPath $junction)) { throw 'junction was removed during dry-run' }
  }

  Assert-Step 'worktree lock protects local and remote branch pruning' {
    $lockedBranch = 'fixture/locked'
    $lockedWorktree = Join-Path $work 'locked-worktree'
    $null = Invoke-GitText -Root $repo -Arguments @('branch', $lockedBranch)
    $null = Invoke-GitText -Root $repo -Arguments @('worktree', 'add', $lockedWorktree, $lockedBranch)
    $null = Invoke-GitText -Root $repo -Arguments @('push', '-u', 'origin', $lockedBranch)
    try {
      $r = Invoke-PwshFile -File (Join-Path $SkillRoot 'scripts\prune_merged.ps1') -WorkingDirectory $otherCwd -Arguments @(
        '-RepoRoot', $repo, '-OnlyBranches', $lockedBranch, '-Apply', '-DeleteRemote', '-Json'
      )
      if ($r.ExitCode -ne 0) { throw "worktree-lock prune failed: $($r.Output)" }
      $json = $r.Output | ConvertFrom-Json
      if (@($json.deleted_local).Count -ne 0 -or @($json.deleted_remote).Count -ne 0) { throw 'worktree-locked branch was deleted' }
      if (@($json.local | Where-Object { $_.reason -eq 'worktree-locked' }).Count -ne 1 -or
        @($json.remote | Where-Object { $_.reason -eq 'worktree-locked' }).Count -ne 1) {
        throw "worktree lock evidence missing: $($r.Output)"
      }
    } finally {
      $null = Invoke-GitText -Root $repo -Arguments @('worktree', 'remove', '--force', $lockedWorktree) -AllowFailure
      $null = Invoke-GitText -Root $repo -Arguments @('branch', '-D', '--', $lockedBranch) -AllowFailure
      $null = Invoke-GitText -Root $repo -Arguments @('push', 'origin', '--delete', $lockedBranch) -AllowFailure
      $null = Invoke-GitText -Root $repo -Arguments @('fetch', '--prune', 'origin') -AllowFailure
    }
  }

  Assert-Step 'explicit direct delivery does not create a PR' {
    $directRepo = New-LocalFixtureRepo -Name 'direct'
    'direct delivery' | Set-Content -LiteralPath (Join-Path $directRepo.Root 'direct.ps1') -Encoding utf8
    $directConfig = Join-Path $work 'USER-direct.md'
    @(
      '| Key | Value |'
      '|-----|-------|'
      '| `prefer_pr` | `false` |'
      '| `push_main_direct` | `true` |'
      '| `full_run_confirmation` | `true` |'
      '| `prune_local_merged` | `false` |'
      '| `prune_remote_merged` | `false` |'
    ) | Set-Content -LiteralPath $directConfig -Encoding utf8
    $planned = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $directRepo.Root, '-Plan', '-Json', '-UserConfigPath', $directConfig, '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($planned.ExitCode -ne 0) { throw "direct plan exit $($planned.ExitCode): $($planned.Output)" }
    $plan = $planned.Output | ConvertFrom-Json
    if (-not $plan.pr.direct_delivery -or $plan.pr.required) { throw 'direct delivery plan still requires PR flow' }
    $applied = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $directRepo.Root, '-Apply', '-PlanFile', (Join-Path $plan.run_root 'plan.json'), '-Json'
    )
    if ($applied.ExitCode -ne 0) { throw "direct apply failed: $($applied.Output)" }
    $done = $applied.Output | ConvertFrom-Json
    if ($done.status -ne 'COMPLETED') { throw "direct delivery did not complete: $($applied.Output)" }
    $branch = (Invoke-GitText -Root $directRepo.Root -Arguments @('branch', '--show-current')).Output.Trim()
    if ($branch -ne 'main') { throw "direct delivery changed branch: $branch" }
    $status = Invoke-GitText -Root $directRepo.Root -Arguments @('status', '--porcelain')
    if ($status.Output.Trim()) { throw "direct delivery left dirty state: $($status.Output)" }
  }

  Assert-Step 'resume rejects changed planned content before commit' {
    $scopeRepo = New-LocalFixtureRepo -Name 'resume-scope' -ForkRemotes
    $plannedPath = Join-Path $scopeRepo.Root 'resume.ps1'
    'planned content' | Set-Content -LiteralPath $plannedPath -Encoding utf8
    $planCall = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $scopeRepo.Root, '-Plan', '-Json', '-VerifyCommand', "throw 'verify-fail'"
    )
    if ($planCall.ExitCode -ne 0) { throw "resume-scope plan failed: $($planCall.Output)" }
    $plan = $planCall.Output | ConvertFrom-Json
    $first = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $scopeRepo.Root, '-Apply', '-PlanFile', (Join-Path $plan.run_root 'plan.json'), '-Json'
    )
    if ($first.ExitCode -eq 0) { throw 'verify-failing apply unexpectedly succeeded' }
    'changed after failure' | Set-Content -LiteralPath $plannedPath -Encoding utf8
    $statePath = Join-Path $plan.run_root 'state.json'
    $resume = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $scopeRepo.Root, '-Resume', '-StateFile', $statePath, '-Json'
    )
    if ($resume.ExitCode -eq 0 -or $resume.Output -notmatch 'STALE_SCOPE') {
      throw "resume accepted changed planned content: $($resume.Output)"
    }
  }

  Assert-Step 'wait-for-checks blocks pending merge but preserves branch' {
    $waitRepo = New-LocalFixtureRepo -Name 'wait-for-checks' -ForkRemotes
    'waited change' | Set-Content -LiteralPath (Join-Path $waitRepo.Root 'wait.ps1') -Encoding utf8
    New-Item -ItemType Directory -Path (Join-Path $waitRepo.Root '__pycache__') | Out-Null
    'cache' | Set-Content -LiteralPath (Join-Path $waitRepo.Root '__pycache__\wait.pyc') -Encoding utf8
    $waitConfig = Join-Path $work 'USER-wait.md'
    @(
      '| Key | Value |'
      '|-----|-------|'
      '| `prefer_pr` | `true` |'
      '| `wait_for_checks` | `true` |'
      '| `full_run_confirmation` | `true` |'
      '| `prune_local_merged` | `false` |'
      '| `prune_remote_merged` | `false` |'
    ) | Set-Content -LiteralPath $waitConfig -Encoding utf8
    $waitState = Join-Path $work 'gh-wait-state.json'
    @{ state = 'NONE'; number = 1; merge_attempts = 0 } | ConvertTo-Json | Set-Content -LiteralPath $waitState -Encoding utf8
    $previousState = $env:CLOSEOUT_FAKE_GH_STATE
    $previousRemote = $env:CLOSEOUT_FAKE_REMOTE
    $previousPending = $env:CLOSEOUT_FAKE_CHECK_PENDING
    try {
      $env:CLOSEOUT_FAKE_GH_STATE = $waitState
      $env:CLOSEOUT_FAKE_REMOTE = $waitRepo.Remote
      $env:CLOSEOUT_FAKE_CHECK_PENDING = '1'
      $planCall = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
        '-RepoRoot', $waitRepo.Root, '-Plan', '-Json', '-UserConfigPath', $waitConfig, '-VerifyCommand', 'Write-Output verify-ok'
      )
      if ($planCall.ExitCode -ne 0) { throw "wait plan failed: $($planCall.Output)" }
      $plan = $planCall.Output | ConvertFrom-Json
      $apply = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
        '-RepoRoot', $waitRepo.Root, '-Apply', '-PlanFile', (Join-Path $plan.run_root 'plan.json'), '-Json'
      )
      if ($apply.ExitCode -ne 3 -or $apply.Output -notmatch 'WAIT_FOR_CHECKS') {
        throw "pending checks were not held: $($apply.Output)"
      }
      $state = Get-Content -LiteralPath (Join-Path $plan.run_root 'state.json') -Raw | ConvertFrom-Json
      if ($state.status -ne 'BLOCKED' -or $state.failed_phase -ne 'merge') { throw 'pending checks did not checkpoint a blocked merge' }
      $branch = [string]$plan.branch.target
      if ((Invoke-GitText -Root $waitRepo.Root -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch") -AllowFailure).ExitCode -ne 0) {
        throw 'pending merge unexpectedly removed local feature branch'
      }
      if (Test-Path -LiteralPath (Join-Path $waitRepo.Root '__pycache__')) { throw 'planned cache was not cleaned before the blocked merge' }
    } finally {
      if ($null -eq $previousState) { Remove-Item Env:CLOSEOUT_FAKE_GH_STATE -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_GH_STATE = $previousState }
      if ($null -eq $previousRemote) { Remove-Item Env:CLOSEOUT_FAKE_REMOTE -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_REMOTE = $previousRemote }
      if ($null -eq $previousPending) { Remove-Item Env:CLOSEOUT_FAKE_CHECK_PENDING -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_CHECK_PENDING = $previousPending }
    }
  }

  Assert-Step 'full run resumes after merge failure and closes clean desk' {
    $planCall = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Plan', '-Json', '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($planCall.ExitCode -ne 0) { throw "full plan exit $($planCall.ExitCode): $($planCall.Output)" }
    $plan = $planCall.Output | ConvertFrom-Json
    $planPath = Join-Path $plan.run_root 'plan.json'
    $env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE = '1'
    $first = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Apply', '-PlanFile', $planPath
    )
    if ($first.ExitCode -eq 0) { throw 'first apply unexpectedly merged' }
    $statePath = Join-Path $plan.run_root 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'failed apply did not write state' }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.status -ne 'FAILED' -or $state.failed_phase -ne 'merge') { throw "unexpected failed state: $($state.status) $($state.failed_phase); failure=$($state.failure)" }
    if (Test-Path -LiteralPath (Join-Path $repo '__pycache__')) { throw 'safe cache was not deleted before merge' }
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    [IO.File]::WriteAllText($planPath, $planRaw + ' ', [Text.UTF8Encoding]::new($false))
    $tampered = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Resume', '-StateFile', $statePath
    )
    if ($tampered.ExitCode -eq 0 -or $tampered.Output -notmatch 'PLAN_CHANGED') { throw "tampered plan was accepted: $($tampered.Output)" }
    [IO.File]::WriteAllText($planPath, $planRaw, [Text.UTF8Encoding]::new($false))
    $env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE = '1'
    $resume = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Resume', '-StateFile', $statePath, '-Json'
    )
    if ($resume.ExitCode -ne 0) { throw "resume exit $($resume.ExitCode): $($resume.Output)" }
    $done = $resume.Output | ConvertFrom-Json
    if ($done.status -ne 'COMPLETED') { throw "resume not completed: $($resume.Output)" }
    if (-not (Test-Path -LiteralPath $done.report)) { throw 'final report missing' }
    $report = Get-Content -LiteralPath $done.report -Raw
    if ($report -notmatch 'clean desk: YES') { throw "report did not claim clean desk: $report" }
    $branch = ($plan.branch.target)
    if ((Invoke-GitText -Root $repo -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch") -AllowFailure).ExitCode -eq 0) { throw 'local feature branch remains' }
    if ((Invoke-GitText -Root $repo -Arguments @('ls-remote', '--exit-code', '--heads', 'origin', $branch) -AllowFailure).ExitCode -eq 0) { throw 'remote feature branch remains' }
    $status = Invoke-GitText -Root $repo -Arguments @('status', '--porcelain')
    if ($status.Output.Trim()) { throw "working tree is dirty: $($status.Output)" }
    $divergence = (Invoke-GitText -Root $repo -Arguments @('rev-list', '--left-right', '--count', 'main...origin/main')).Output.Trim()
    if ($divergence -ne '0	0' -and $divergence -ne '0 0') { throw "default branch is not synchronized: $divergence" }
    $ghText = Get-Content -LiteralPath $ghLog -Raw
    if ($ghText -notmatch 'pr create' -or $ghText -notmatch 'pr merge') { throw "fake gh did not observe PR lifecycle: $ghText" }
    if ($ghText -match '--auto' -or $ghText -match '--admin') { throw "merge bypass flag observed: $ghText" }
  }

  Assert-Step 'clean default branch is a resumable no-op' {
    $planCall = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Plan', '-Json', '-VerifyCommand', 'Write-Output verify-ok'
    )
    if ($planCall.ExitCode -ne 0) { throw "no-op plan exit $($planCall.ExitCode): $($planCall.Output)" }
    $plan = $planCall.Output | ConvertFrom-Json
    if ($plan.delivery_required) { throw 'clean default branch unexpectedly requires delivery' }
    $apply = Invoke-PwshFile -File $closeoutScript -WorkingDirectory $otherCwd -Arguments @(
      '-RepoRoot', $repo, '-Apply', '-PlanFile', (Join-Path $plan.run_root 'plan.json'), '-Json'
    )
    if ($apply.ExitCode -ne 0) { throw "no-op apply exit $($apply.ExitCode): $($apply.Output)" }
    $done = $apply.Output | ConvertFrom-Json
    if ($done.status -ne 'COMPLETED') { throw "no-op was not completed: $($apply.Output)" }
    $branch = (Invoke-GitText -Root $repo -Arguments @('branch', '--show-current')).Output.Trim()
    if ($branch -ne 'main') { throw "no-op changed branch: $branch" }
    $status = Invoke-GitText -Root $repo -Arguments @('status', '--porcelain')
    if ($status.Output.Trim()) { throw "no-op left dirty state: $($status.Output)" }
  }
}
finally {
  $env:PATH = $oldPath
  if ($null -eq $oldState) { Remove-Item Env:CLOSEOUT_FAKE_GH_STATE -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_GH_STATE = $oldState }
  if ($null -eq $oldRemote) { Remove-Item Env:CLOSEOUT_FAKE_REMOTE -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_REMOTE = $oldRemote }
  if ($null -eq $oldLog) { Remove-Item Env:CLOSEOUT_FAKE_GH_LOG -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_GH_LOG = $oldLog }
  if ($null -eq $oldFail) { Remove-Item Env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_MERGE_FAIL_ONCE = $oldFail }
  if ($null -eq $oldRequireChecks) { Remove-Item Env:CLOSEOUT_FAKE_REQUIRE_CHECKS -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_REQUIRE_CHECKS = $oldRequireChecks }
  if ($null -eq $oldPendingChecks) { Remove-Item Env:CLOSEOUT_FAKE_CHECK_PENDING -ErrorAction SilentlyContinue } else { $env:CLOSEOUT_FAKE_CHECK_PENDING = $oldPendingChecks }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failed.Count -gt 0) {
  Write-Output "RESULT: FAIL ($($failed.Count) assertions; $($skipped.Count) skipped): $($failed -join ', ')"
  exit 1
}
if ($skipped.Count -gt 0) {
  Write-Output "RESULT: PASS ($($skipped.Count) skipped): $($skipped -join ', ')"
} else {
  Write-Output 'RESULT: PASS'
}
exit 0
