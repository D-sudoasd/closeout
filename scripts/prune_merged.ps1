<#
.SYNOPSIS
  List or delete local/remote branches already merged into default.

  Detects:
  - ancestor merges via merge-base --is-ancestor
  - squash/rebase merges via merged PR head SHA == branch tip

  Default is dry-run. Use -Apply to delete local; -DeleteRemote for remotes
  (still requires explicit -DeleteRemote; never implied by -Apply alone).
  Use -OnlyBranches to restrict classification and deletion to plan-listed names.

  Every git command checks exit codes. Deletes are re-checked after execution.
#>
param(
  [string]$RepoRoot = '.',
  [string]$DefaultBranch = '',
  [string[]]$NeverDelete = @(),
  [string[]]$OnlyBranches = @(),
  [string]$UserConfigPath = '',
  [string]$MergedPrJson = '',
  [switch]$Apply,
  [switch]$DeleteRemote,
  [switch]$WhatIf,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')

trap {
  $message = Protect-CloseoutText "$($_)"
  if ($Json) {
    [ordered]@{
      status = 'FAILED'
      error_code = 'PRUNE_FAILED'
      error = $message
      default_branch = if ($DefaultBranch) { $DefaultBranch } else { $null }
      current = if ($current) { $current } else { $null }
      dry_run = [bool](-not $Apply -or $WhatIf)
      delete_remote = [bool]$DeleteRemote
      only_branches = @($OnlyBranches)
    } | ConvertTo-Json -Depth 8
    exit 1
  }
  throw
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$dry = -not $Apply
if ($WhatIf) { $dry = $true }

$probe = Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--git-dir') -AllowFailure
if ($probe.ExitCode -ne 0) { throw "Not a git repo: $RepoRoot" }

$skillRoot = Split-Path -Parent $here
$userCfg = Get-CloseoutUserConfig -SkillRoot $skillRoot -UserConfigPath $UserConfigPath
$protect = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($n in @($userCfg.never_delete_branches)) { if ($n) { [void]$protect.Add($n) } }
foreach ($n in @($NeverDelete)) { if ($n) { [void]$protect.Add($n) } }
$NeverDelete = @($protect)
$only = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($n in @($OnlyBranches)) {
  if ($n -and $n.Trim()) { [void]$only.Add($n.Trim()) }
}

$mergedPrStubs = $null
if ($MergedPrJson) {
  $rawPr = $MergedPrJson
  if (Test-Path -LiteralPath $MergedPrJson) {
    $rawPr = Get-Content -LiteralPath $MergedPrJson -Raw -Encoding utf8
  }
  $mergedPrStubs = $rawPr | ConvertFrom-Json
}

if (-not $DefaultBranch) {
  $DefaultBranch = Get-DefaultBranch -RepoRoot $RepoRoot -Prefer $userCfg.default_branch_prefer
}

$current = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', '--show-current') -AllowFailure).Output.Trim()
$fetch = Invoke-Git -RepoRoot $RepoRoot -Arguments @('fetch', '--prune', 'origin') -AllowFailure
$fetchFailed = ($fetch.ExitCode -ne 0)
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

function Get-OpenPrForHead {
  param([Parameter(Mandatory)][string]$HeadBranch)

  if (-not $ghOk) {
    return [pscustomobject]@{ status = 'unavailable'; pr = $null; detail = 'gh unavailable' }
  }
  $r = Invoke-Gh -RepoRoot $RepoRoot -Arguments @(
    'pr', 'list', '--state', 'all', '--head', $HeadBranch, '--limit', '20',
    '--json', 'number,url,state,baseRefName,headRefName,headRefOid'
  ) -AllowFailure
  if ($r.ExitCode -ne 0) {
    return [pscustomobject]@{ status = 'unavailable'; pr = $null; detail = (Protect-CloseoutText $r.Output) }
  }
  try { $items = @(($r.Output | ConvertFrom-Json)) } catch {
    return [pscustomobject]@{ status = 'unavailable'; pr = $null; detail = 'open PR response was not valid JSON' }
  }
  $open = @($items | Where-Object { $_.state -eq 'OPEN' -and $_.headRefName -eq $HeadBranch })
  if ($open.Count -gt 0) {
    return [pscustomobject]@{ status = 'open'; pr = $open[0]; detail = "open PR #$($open[0].number)" }
  }
  $closed = @($items | Where-Object { $_.state -eq 'CLOSED' -and $_.headRefName -eq $HeadBranch })
  if ($closed.Count -gt 0) {
    return [pscustomobject]@{ status = 'closed-unmerged'; pr = $closed[0]; detail = "closed unmerged PR #$($closed[0].number)" }
  }
  return [pscustomobject]@{ status = 'none'; pr = $null; detail = 'no open PR for head' }
}

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
  if ($wtBranches -contains $Name) {
    $result.reason = 'worktree-locked'
    $result.evidence += 'checked out in a worktree; keep both local and remote refs'
    return [pscustomobject]$result
  }
  if (-not $TipSha) {
    $result.reason = 'unresolved-tip'
    $result.evidence += 'could not resolve tip SHA'
    return [pscustomobject]$result
  }

  # 1) ancestor merge, but only after checking that no open PR still uses the
  # branch. An ancestor tip can still be the head of a follow-up PR.
  $isAncestor = Test-IsAncestor -RepoRoot $RepoRoot -PossibleAncestor $TipSha -Descendant $defaultTip
  $openCheck = Get-OpenPrForHead -HeadBranch $Name
  if ($openCheck.status -eq 'open') {
    $result.reason = 'open-pr'
    $result.pr_number = $openCheck.pr.number
    $result.pr_url = $openCheck.pr.url
    $result.evidence += "$($openCheck.detail); never delete a branch with an open PR"
    $result.action = 'report-only-open-pr'
    return [pscustomobject]$result
  }
  if ($openCheck.status -eq 'closed-unmerged') {
    $result.reason = 'closed-unmerged-pr'
    $result.pr_number = $openCheck.pr.number
    $result.pr_url = $openCheck.pr.url
    $result.evidence += "$($openCheck.detail); never reopen or delete its branch automatically"
    $result.action = 'report-only-closed-unmerged-pr'
    return [pscustomobject]$result
  }
  if ($openCheck.status -ne 'none') {
    $result.evidence += "open PR check unavailable: $($openCheck.detail)"
    if ($isAncestor) {
      $result.reason = 'ancestor-merged'
      $result.action = 'report-only-open-pr-unknown'
    } else {
      $result.reason = 'uncertain-open-pr'
      $result.action = 'report-only'
    }
    return [pscustomobject]$result
  }
  if ($isAncestor) {
    $result.reason = 'ancestor-merged'
    $result.safe_to_delete = $true
    $result.evidence += "tip $TipSha is ancestor of $DefaultBranch ($defaultTip)"
    $result.action = if ($dry) { "would-delete-$Scope" } else { "delete-$Scope" }
    return [pscustomobject]$result
  }
  $result.evidence += "tip $TipSha is NOT ancestor of $DefaultBranch (likely squash/rebase or unmerged)"

  # 2) squash/rebase via merged PR + tip match
  if (-not $ghOk -and $null -eq $mergedPrStubs) {
    $result.reason = 'uncertain-no-gh'
    $result.evidence += 'gh unavailable; cannot confirm squash/rebase PR merge'
    $result.action = 'report-only'
    return [pscustomobject]$result
  }

  $pr = Get-MergedPrForHead -HeadBranch $Name -RepoRoot $RepoRoot -BaseBranch $DefaultBranch -StubRecords $mergedPrStubs
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
  if ($only.Count -gt 0 -and -not $only.Contains($b)) { continue }
  $tip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $b
  $c = Classify-Branch -Name $b -TipSha $tip -Scope 'local'
  $localCandidates += $c
}

$remoteCandidates = @()
# always classify remotes for report; only delete when -DeleteRemote and -Apply
$remotes = Get-RemoteBranchNames -RepoRoot $RepoRoot -Remote 'origin'
foreach ($rb in $remotes) {
  if ($only.Count -gt 0 -and -not $only.Contains($rb.Name)) { continue }
  $c = Classify-Branch -Name $rb.Name -TipSha $rb.Sha -Scope 'remote'
  $remoteCandidates += $c
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
  $liveLocalTip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $c.name
  if (-not $liveLocalTip) {
    $c.action = 'already-absent-local'
    $skippedLocal += $c
    continue
  }
  if ($liveLocalTip -ne $c.tip_sha) {
    $c.action = 'tip-moved-before-delete'
    $c.safe_to_delete = $false
    $c.evidence += "local tip changed after classification ($($c.tip_sha) -> $liveLocalTip)"
    $skippedLocal += $c
    continue
  }
  $del = Remove-LocalSafeBranch -RepoRoot $RepoRoot -Name $c.name -Reason $c.reason
  if ($del.ExitCode -ne 0) {
    $c.action = 'delete-failed'
    $c.evidence += "local delete failed: $($del.Output)"
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
    if ($fetchFailed) {
      $c.action = 'fetch-failed-hold'
      $c.safe_to_delete = $false
      $c.reason = 'fetch-failed'
      $c.evidence += 'origin fetch failed; remote deletion is not authorized from stale refs'
      $skippedRemote += $c
      continue
    }
    $c.action = 'would-delete-remote'
    continue
  }
  if ($fetchFailed) {
    $c.action = 'fetch-failed'
    $c.safe_to_delete = $false
    $c.reason = 'fetch-failed'
    $c.evidence += 'origin fetch failed; remote deletion is blocked until refs are refreshed'
    $failedRemote += $c
    continue
  }
  # never delete remote of current branch (double-check)
  if ($c.name -eq $current) {
    $c.action = 'skip-current-remote'
    $c.safe_to_delete = $false
    $skippedRemote += $c
    continue
  }
  $liveRemote = Get-LiveRemoteBranchTip -RepoRoot $RepoRoot -Remote 'origin' -Name $c.name
  if ($liveRemote.status -eq 'error') {
    $c.action = 'remote-tip-recheck-failed'
    $c.evidence += "live remote tip query failed: $(Protect-CloseoutText $liveRemote.output)"
    $failedRemote += $c
    continue
  }
  if ($liveRemote.status -eq 'absent') {
    $c.action = 'already-absent-remote'
    $skippedRemote += $c
    continue
  }
  if ($liveRemote.sha -ne $c.tip_sha) {
    $c.action = 'tip-moved-before-delete'
    $c.safe_to_delete = $false
    $c.evidence += "live remote tip changed after classification ($($c.tip_sha) -> $($liveRemote.sha))"
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
    only_branches    = @($OnlyBranches)
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
  if ($c.safe_to_delete -or $c.reason -match 'uncertain|tip-moved|worktree|unmerged|no-gh|current|open-pr|closed-unmerged|fetch-failed') {
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
  if ($c.safe_to_delete -or $c.reason -match 'uncertain|tip-moved|worktree|unmerged|no-gh|current|open-pr|closed-unmerged|fetch-failed') {
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
