<#
.SYNOPSIS
  One-page closeout status for a git repo (read-only).
  Evidence-oriented: classified dirty files, in-progress ops, redacted remote.
#>
param(
  [string]$RepoRoot = '.',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')

try {
  $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
} catch {
  Write-Output "not_a_git_repo: $RepoRoot (path missing)"
  exit 2
}

$probe = Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--git-dir') -AllowFailure
if ($probe.ExitCode -ne 0) {
  Write-Output "not_a_git_repo: $RepoRoot"
  exit 2
}

$branch = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', '--show-current') -AllowFailure).Output.Trim()
$shaShort = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--short', 'HEAD') -AllowFailure).Output.Trim()
$shaFull = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', 'HEAD') -AllowFailure).Output.Trim()
$statusSb = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('status', '-sb') -AllowFailure).Output
$porcelain = Invoke-Git -RepoRoot $RepoRoot -Arguments @('status', '--porcelain') -AllowFailure
$stashCount = 0
$stashList = Invoke-Git -RepoRoot $RepoRoot -Arguments @('stash', 'list') -AllowFailure
if ($stashList.ExitCode -eq 0 -and $stashList.Output.Trim()) {
  $stashCount = @($stashList.Lines | Where-Object { $_.Trim() }).Count
}

$skillRoot = Split-Path -Parent $here
$userCfg = Get-CloseoutUserConfig -SkillRoot $skillRoot
$default = Get-DefaultBranch -RepoRoot $RepoRoot -Prefer $userCfg.default_branch_prefer

# classified dirty
$staged = @()
$unstaged = @()
$untracked = @()
$conflicted = @()
foreach ($line in $porcelain.Lines) {
  if (-not $line -or $line.Length -lt 2) { continue }
  $x = $line[0]
  $y = $line[1]
  $path = if ($line.Length -gt 3) { $line.Substring(3).Trim() } else { '' }
  if ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) {
    $conflicted += $path
    continue
  }
  if ($x -eq '?' -and $y -eq '?') {
    $untracked += $path
    continue
  }
  if ($x -ne ' ' -and $x -ne '?') { $staged += $path }
  if ($y -ne ' ' -and $y -ne '?') { $unstaged += $path }
}

$inProgress = @(Get-InProgressGitOps -RepoRoot $RepoRoot)

$upstream = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--abbrev-ref', '@{upstream}') -AllowFailure).Output.Trim()
$ahead = $null
$behind = $null
if ($upstream) {
  $counts = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', $upstream) -AllowFailure)
  if ($counts.ExitCode -eq 0) {
    $lr = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}') -AllowFailure).Output.Trim()
    # left = commits on HEAD not in upstream (ahead); right = commits on upstream not in HEAD (behind)
    if ($lr -match '^\s*(\d+)\s+(\d+)\s*$') {
      $ahead = [int]$Matches[1]
      $behind = [int]$Matches[2]
    }
  }
}

# remotes (redacted)
$remotes = @()
$remoteNames = Invoke-Git -RepoRoot $RepoRoot -Arguments @('remote') -AllowFailure
foreach ($rn in $remoteNames.Lines) {
  if (-not $rn.Trim()) { continue }
  $url = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('remote', 'get-url', $rn.Trim()) -AllowFailure).Output.Trim()
  $remotes += [pscustomobject]@{
    name = $rn.Trim()
    url  = (Protect-RemoteUrl $url)
  }
}

# PR (bound to RepoRoot, not process cwd)
$pr = $null
$prView = Invoke-Gh -RepoRoot $RepoRoot -Arguments @(
  'pr', 'view', '--json', 'number,url,state,title,mergeable,isDraft,baseRefName,headRefName,headRefOid'
) -AllowFailure
if ($prView.ExitCode -eq 0 -and $prView.Output.Trim()) {
  try { $pr = $prView.Output | ConvertFrom-Json } catch { $pr = $null }
}

# merged locals (ancestor only — prune script does squash)
$mergedLocal = @()
$localBranches = Invoke-Git -RepoRoot $RepoRoot -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads') -AllowFailure
$defaultTip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $default
if (-not $defaultTip) {
  $defaultTip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref "origin/$default"
}
foreach ($b in $localBranches.Lines) {
  $name = $b.Trim()
  if (-not $name -or $name -eq $default) { continue }
  $tip = Get-BranchTipSha -RepoRoot $RepoRoot -Ref $name
  if ($tip -and $defaultTip -and (Test-IsAncestor -RepoRoot $RepoRoot -PossibleAncestor $tip -Descendant $defaultTip)) {
    $mergedLocal += $name
  }
}

$worktrees = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('worktree', 'list') -AllowFailure).Output

$tools = [ordered]@{
  git  = Test-CommandAvailable 'git'
  gh   = Test-CommandAvailable 'gh'
  pwsh = Test-CommandAvailable 'pwsh'
}

$detached = -not $branch

$payload = [ordered]@{
  root              = $RepoRoot
  branch            = $branch
  detached_head     = $detached
  head_short        = $shaShort
  head_full         = $shaFull
  default_branch    = $default
  default_tip       = $defaultTip
  upstream          = $upstream
  ahead             = $ahead
  behind            = $behind
  staged_files      = @($staged | Select-Object -Unique)
  unstaged_files    = @($unstaged | Select-Object -Unique)
  untracked_files   = @($untracked | Select-Object -Unique)
  conflicted_files  = @($conflicted | Select-Object -Unique)
  stash_entries     = $stashCount
  in_progress_ops   = $inProgress
  remotes           = $remotes
  pr                = $pr
  ancestor_merged_local = $mergedLocal
  worktrees         = $worktrees.Trim()
  tools             = $tools
  status_sb         = $statusSb.TrimEnd()
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 6
  exit 0
}

Write-Output "# closeout status"
Write-Output "- root: $RepoRoot"
Write-Output "- branch: $(if ($branch) { $branch } else { '(detached)' }) @ $shaShort"
Write-Output "- head_full: $shaFull"
Write-Output "- default: $default"
Write-Output "- default_tip: $defaultTip"
Write-Output "- upstream: $upstream"
Write-Output "- ahead: $ahead  behind: $behind"
Write-Output "- staged_files: $($payload.staged_files.Count)"
Write-Output "- unstaged_files: $($payload.unstaged_files.Count)"
Write-Output "- untracked_files: $($payload.untracked_files.Count)"
Write-Output "- conflicted_files: $($payload.conflicted_files.Count)"
Write-Output "- stash_entries: $stashCount"
Write-Output "- in_progress_ops: $(if ($inProgress.Count) { $inProgress -join ', ' } else { '(none)' })"
Write-Output "- tools: git=$($tools.git) gh=$($tools.gh) pwsh=$($tools.pwsh)"
Write-Output ""
Write-Output "## remotes (credentials redacted)"
if ($remotes.Count -eq 0) { Write-Output "- (none)" }
else { foreach ($r in $remotes) { Write-Output "- $($r.name): $($r.url)" } }
Write-Output ""
Write-Output "## status -sb"
Write-Output $statusSb.TrimEnd()
Write-Output ""
if ($payload.staged_files.Count) {
  Write-Output "## staged"
  $payload.staged_files | ForEach-Object { Write-Output "- $_" }
  Write-Output ""
}
if ($payload.conflicted_files.Count) {
  Write-Output "## conflicted"
  $payload.conflicted_files | ForEach-Object { Write-Output "- $_" }
  Write-Output ""
}
Write-Output "## pr"
if ($pr) {
  Write-Output ("- #{0} {1} ({2}) draft={3} mergeable={4}" -f $pr.number, $pr.title, $pr.state, $pr.isDraft, $pr.mergeable)
  Write-Output ("- base={0} head={1} headOid={2}" -f $pr.baseRefName, $pr.headRefName, $pr.headRefOid)
  Write-Output ("- {0}" -f $pr.url)
} else {
  Write-Output "- (none for current branch or gh unavailable)"
}
Write-Output ""
Write-Output "## local branches ancestor-merged into $default"
if ($mergedLocal.Count -eq 0) { Write-Output "- (none; squash-merged may still exist — use prune_merged.ps1)" }
else { $mergedLocal | ForEach-Object { Write-Output "- $_" } }
Write-Output ""
Write-Output "## worktrees"
Write-Output $worktrees.TrimEnd()
exit 0
