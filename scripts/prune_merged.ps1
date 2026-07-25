<#
.SYNOPSIS
  List or delete local/remote branches already merged into default.

  Detects:
  - ancestor merges via merge-base --is-ancestor
  - squash/rebase merges via merged PR head SHA == branch tip

  Default is dry-run. Use -Apply to delete local; -DeleteRemote for remotes
  (still requires explicit -DeleteRemote; never implied by -Apply alone).

  Every git command checks exit codes. Deletes are re-checked after execution.
#>
param(
  [string]$RepoRoot = '.',
  [string]$DefaultBranch = '',
  [string[]]$NeverDelete = @('main', 'master', 'develop'),
  [switch]$Apply,
  [switch]$DeleteRemote,
  [switch]$WhatIf,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$dry = -not $Apply
if ($WhatIf) { $dry = $true }

$probe = Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--git-dir') -AllowFailure
if ($probe.ExitCode -ne 0) { throw "Not a git repo: $RepoRoot" }

if (-not $DefaultBranch) {
  $DefaultBranch = Get-DefaultBranch -RepoRoot $RepoRoot
}

$current = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', '--show-current') -AllowFailure).Output.Trim()
$fetch = Invoke-Git -RepoRoot $RepoRoot -Arguments @('fetch', '--prune', 'origin') -AllowFailure
if ($fetch.ExitCode -ne 0) {
  Write-Output "WARN: git fetch --prune origin failed (exit $($fetch.ExitCode)); continuing with local state"
  Write-Output $fetch.Output
}

$wtBranches = @(Get-WorktreeLockedBranches -RepoRoot $RepoRoot)
$defaultTip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $DefaultBranch
if (-not $defaultTip) {
  $defaultTip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref "origin/$DefaultBranch"
}
if (-not $defaultTip) {
  throw "Cannot resolve tip of default branch '$DefaultBranch'"
}

$ghOk = Test-CommandAvailable -Name 'gh'

function Get-LocalBranchNames {
  param([string]$Root)
  $r = Invoke-Git -RepoRoot $Root -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads') -AllowFailure
  if ($r.ExitCode -ne 0) { return @() }
  return @($r.Lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Classify-Branch {
  param(
    [string]$Name,
    [string]$TipSha,
    [string]$Scope  # local | remote
  )

  $result = [ordered]@{
    name            = $Name
    scope           = $Scope
    tip_sha         = $TipSha
    reason          = ''
    action          = 'skip'
    safe_to_delete  = $false
    pr_number       = $null
    pr_url          = $null
    pr_head_oid     = $null
    evidence        = @()
  }

  if (-not $Name) {
    $result.reason = 'empty-name'
    $result.evidence += 'empty branch name'
    return [pscustomobject]$result
  }
  if ($Name -eq $DefaultBranch -or ($NeverDelete -contains $Name)) {
    $result.reason = 'protected'
    $result.evidence += "protected name or default ($Name)"
    return [pscustomobject]$result
  }
  if ($Name -eq $current) {
    $result.reason = 'current-branch'
    $result.evidence += 'is current branch'
    return [pscustomobject]$result
  }
  if ($Scope -eq 'local' -and ($wtBranches -contains $Name)) {
    $result.reason = 'worktree-locked'
    $result.evidence += 'checked out in another worktree'
    return [pscustomobject]$result
  }
  if (-not $TipSha) {
    $result.reason = 'unresolved-tip'
    $result.evidence += 'could not resolve tip SHA'
    return [pscustomobject]$result
  }

  # 1) ancestor merge
  $isAncestor = Test-IsAncestor -RepoRoot $RepoRoot -PossibleAncestor $TipSha -Descendant $defaultTip
  if ($isAncestor) {
    $result.reason = 'ancestor-merged'
    $result.safe_to_delete = $true
    $result.evidence += "tip $TipSha is ancestor of $DefaultBranch ($defaultTip)"
    $result.action = if ($dry) { "would-delete-$Scope" } else { "delete-$Scope" }
    return [pscustomobject]$result
  }
  $result.evidence += "tip $TipSha is NOT ancestor of $DefaultBranch (likely squash/rebase or unmerged)"

  # 2) squash/rebase via merged PR + tip match
  if (-not $ghOk) {
    $result.reason = 'uncertain-no-gh'
    $result.evidence += 'gh unavailable; cannot confirm squash/rebase PR merge'
    $result.action = 'report-only'
    return [pscustomobject]$result
  }

  $pr = Get-MergedPrForHead -HeadBranch $Name
  if (-not $pr) {
    $result.reason = 'unmerged-or-unknown'
    $result.evidence += 'no merged PR found for this head; not auto-deleting'
    $result.action = 'report-only'
    return [pscustomobject]$result
  }

  $result.pr_number = $pr.number
  $result.pr_url = $pr.url
  $result.pr_head_oid = $pr.headRefOid
  $result.evidence += "merged PR #$($pr.number) headRefOid=$($pr.headRefOid)"

  if ($pr.headRefOid -and $TipSha -and ($pr.headRefOid -eq $TipSha)) {
    $result.reason = 'squash-or-rebase-merged'
    $result.safe_to_delete = $true
    $result.evidence += 'PR head SHA matches current branch tip'
    $result.action = if ($dry) { "would-delete-$Scope" } else { "delete-$Scope" }
    return [pscustomobject]$result
  }

  $result.reason = 'merged-pr-but-tip-moved'
  $result.evidence += "PR merged but tip moved (pr=$($pr.headRefOid) tip=$TipSha); refuse auto-delete"
  $result.action = 'report-only-new-commits'
  return [pscustomobject]$result
}

$localCandidates = @()
foreach ($b in (Get-LocalBranchNames -Root $RepoRoot)) {
  if ($b -eq $DefaultBranch) { continue }
  $tip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $b
  $c = Classify-Branch -Name $b -TipSha $tip -Scope 'local'
  $localCandidates += $c
}

$remoteCandidates = @()
if ($DeleteRemote -or $true) {
  # always classify remotes for report; only delete when -DeleteRemote and -Apply
  $remotes = Get-RemoteBranchNames -RepoRoot $RepoRoot -Remote 'origin'
  foreach ($rb in $remotes) {
    $c = Classify-Branch -Name $rb.Name -TipSha $rb.Sha -Scope 'remote'
    $remoteCandidates += $c
  }
}

# --- execute local deletes ---
$deletedLocal = @()
$failedLocal = @()
$skippedLocal = @()

foreach ($c in $localCandidates) {
  if (-not $c.safe_to_delete) {
    $skippedLocal += $c
    continue
  }
  if ($dry) { continue }
  $del = Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', '-d', $c.name) -AllowFailure
  if ($del.ExitCode -ne 0) {
    $c.action = 'delete-failed'
    $c.evidence += "git branch -d failed: $($del.Output)"
    $failedLocal += $c
    continue
  }
  # recheck
  $still = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $c.name
  if ($still) {
    $c.action = 'delete-failed-still-exists'
    $c.evidence += "after branch -d, tip still resolves to $still"
    $failedLocal += $c
  } else {
    $c.action = 'deleted-local'
    $deletedLocal += $c
  }
}

# --- execute remote deletes (only if both Apply and DeleteRemote) ---
$deletedRemote = @()
$failedRemote = @()
$skippedRemote = @()

foreach ($c in $remoteCandidates) {
  if (-not $c.safe_to_delete) {
    $skippedRemote += $c
    continue
  }
  if (-not $DeleteRemote) {
    $c.action = 'listed-safe-need-DeleteRemote-and-Apply'
    continue
  }
  if ($dry) {
    $c.action = 'would-delete-remote'
    continue
  }
  # never delete remote of current branch (double-check)
  if ($c.name -eq $current) {
    $c.action = 'skip-current-remote'
    $c.safe_to_delete = $false
    $skippedRemote += $c
    continue
  }
  $del = Invoke-Git -RepoRoot $RepoRoot -Arguments @('push', 'origin', '--delete', $c.name) -AllowFailure
  if ($del.ExitCode -ne 0) {
    $c.action = 'delete-remote-failed'
    $c.evidence += "git push --delete failed (exit $($del.ExitCode)): $($del.Output)"
    $failedRemote += $c
    continue
  }
  # recheck remote ref
  $still = Get-BranchTipSha -RepoRoot $RepoRoot -Ref "origin/$($c.name)"
  # after delete, fetch may still show until prune; try show-ref
  $show = Invoke-Git -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$($c.name)") -AllowFailure
  if ($show.ExitCode -eq 0) {
    # refresh
    Invoke-Git -RepoRoot $RepoRoot -Arguments @('fetch', '--prune', 'origin') -AllowFailure | Out-Null
    $show2 = Invoke-Git -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$($c.name)") -AllowFailure
    if ($show2.ExitCode -eq 0) {
      $c.action = 'delete-remote-failed-still-exists'
      $c.evidence += 'remote ref still present after delete+fetch --prune'
      $failedRemote += $c
      continue
    }
  }
  $c.action = 'deleted-remote'
  $deletedRemote += $c
}

# --- report ---
if ($Json) {
  $payload = [ordered]@{
    default_branch   = $DefaultBranch
    current          = $current
    dry_run          = $dry
    apply            = (-not $dry)
    delete_remote    = [bool]$DeleteRemote
    default_tip      = $defaultTip
    local            = $localCandidates
    remote           = $remoteCandidates
    deleted_local    = @($deletedLocal | ForEach-Object { $_.name })
    deleted_remote   = @($deletedRemote | ForEach-Object { $_.name })
    failed_local     = @($failedLocal | ForEach-Object { $_.name })
    failed_remote    = @($failedRemote | ForEach-Object { $_.name })
  }
  $payload | ConvertTo-Json -Depth 8
  if ($failedLocal.Count -gt 0 -or $failedRemote.Count -gt 0) { exit 1 }
  exit 0
}

Write-Output "# prune_merged default=$DefaultBranch current=$current dry_run=$dry apply=$(-not $dry) delete_remote=$DeleteRemote"
Write-Output "# default_tip=$defaultTip gh=$ghOk"
Write-Output ""
Write-Output "## local candidates"
$anyLocal = $false
foreach ($c in $localCandidates) {
  if ($c.reason -eq 'protected' -and $c.name -eq $DefaultBranch) { continue }
  # show interesting ones: safe, uncertain, tip-moved, worktree
  if ($c.safe_to_delete -or $c.reason -match 'uncertain|tip-moved|worktree|unmerged|no-gh|current') {
    $anyLocal = $true
    $safe = if ($c.safe_to_delete) { 'SAFE' } else { 'HOLD' }
    Write-Output ("- {0}  [{1}] reason={2} action={3}" -f $c.name, $safe, $c.reason, $c.action)
    foreach ($e in $c.evidence) { Write-Output "    · $e" }
    if ($c.pr_number) { Write-Output ("    · PR #{0} {1}" -f $c.pr_number, $c.pr_url) }
  }
}
if (-not $anyLocal) {
  $safeLocal = @($localCandidates | Where-Object { $_.safe_to_delete })
  if ($safeLocal.Count -eq 0) {
    Write-Output "- (none safe to delete)"
  }
}

Write-Output ""
Write-Output "## remote candidates (origin)"
$anyRemote = $false
foreach ($c in $remoteCandidates) {
  if ($c.name -eq $DefaultBranch) { continue }
  if ($c.safe_to_delete -or $c.reason -match 'uncertain|tip-moved|worktree|unmerged|no-gh|current') {
    $anyRemote = $true
    $safe = if ($c.safe_to_delete) { 'SAFE' } else { 'HOLD' }
    Write-Output ("- origin/{0}  [{1}] reason={2} action={3}" -f $c.name, $safe, $c.reason, $c.action)
    foreach ($e in $c.evidence) { Write-Output "    · $e" }
    if ($c.pr_number) { Write-Output ("    · PR #{0} {1}" -f $c.pr_number, $c.pr_url) }
  }
}
if (-not $anyRemote) {
  Write-Output "- (none interesting / none safe)"
}

Write-Output ""
Write-Output "## result"
Write-Output ("- deleted_local: {0}" -f $(if ($deletedLocal.Count) { ($deletedLocal.name -join ', ') } else { '(none)' }))
Write-Output ("- deleted_remote: {0}" -f $(if ($deletedRemote.Count) { ($deletedRemote.name -join ', ') } else { '(none)' }))
Write-Output ("- failed_local: {0}" -f $(if ($failedLocal.Count) { ($failedLocal.name -join ', ') } else { '(none)' }))
Write-Output ("- failed_remote: {0}" -f $(if ($failedRemote.Count) { ($failedRemote.name -join ', ') } else { '(none)' }))
Write-Output ""
Write-Output "done. dry_run=$dry apply=$(-not $dry) delete_remote=$DeleteRemote"
if ($dry) {
  Write-Output "Re-run with -Apply to delete local SAFE branches; add -DeleteRemote only after explicit user OK."
}
if ($failedLocal.Count -gt 0 -or $failedRemote.Count -gt 0) {
  Write-Output "FAILURES detected — report based on recheck, not command invocation alone."
  exit 1
}
exit 0
