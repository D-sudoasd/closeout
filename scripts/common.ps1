<#
.SYNOPSIS
  Shared helpers for closeout scripts (git invoke, redaction, default branch).
#>

function Invoke-Git {
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string[]]$Arguments,

    [switch]$AllowFailure,

    [switch]$Quiet
  )

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & git -C $RepoRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }

  $text = if ($null -eq $output) {
    ''
  } elseif ($output -is [System.Array]) {
    ($output | ForEach-Object { "$_" }) -join "`n"
  } else {
    "$output"
  }

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $exitCode`n$text"
  }

  if (-not $Quiet -and $text) {
    # callers decide whether to Write-Output; return object only
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $text
    Lines    = @(if ($text) { $text -split "`r?`n" } else { @() })
  }
}

function Protect-RemoteUrl {
  param([string]$Url)
  if (-not $Url) { return $Url }
  # strip credentials: https://user:token@host -> https://***@host
  return ($Url -replace '://([^/@]+)@', '://***@' -replace '://([^:]+):([^@]+)@', '://***@')
}

function Get-DefaultBranch {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Prefer = 'main'
  )

  $name = $null
  try {
    $name = (gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>$null)
    if ($name) { $name = $name.Trim() }
  } catch {}

  if (-not $name) {
    $sym = Invoke-Git -RepoRoot $RepoRoot -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD') -AllowFailure
    if ($sym.ExitCode -eq 0 -and $sym.Output -match 'origin/(\S+)') {
      $name = $Matches[1].Trim()
    }
  }

  if (-not $name) {
    foreach ($c in @($Prefer, 'main', 'master')) {
      if (-not $c) { continue }
      $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$c") -AllowFailure
      if ($r.ExitCode -eq 0) { $name = $c; break }
    }
  }

  if (-not $name) { $name = 'main' }
  return $name
}

function Get-InProgressGitOps {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $gitDir = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--git-dir')).Output.Trim()
  if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
    $gitDir = Join-Path $RepoRoot $gitDir
  }

  $ops = @()
  if (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) { $ops += 'merge' }
  $rebaseMarkers = @(
    (Join-Path $gitDir 'REBASE_HEAD'),
    (Join-Path $gitDir 'rebase-merge'),
    (Join-Path $gitDir 'rebase-apply')
  )
  foreach ($m in $rebaseMarkers) {
    if (Test-Path -LiteralPath $m) { $ops += 'rebase'; break }
  }
  if (Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')) { $ops += 'cherry-pick' }
  if (Test-Path -LiteralPath (Join-Path $gitDir 'REVERT_HEAD')) { $ops += 'revert' }
  if (Test-Path -LiteralPath (Join-Path $gitDir 'BISECT_LOG')) { $ops += 'bisect' }
  return $ops
}

function Get-WorktreeLockedBranches {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $branches = @()
  $wt = Invoke-Git -RepoRoot $RepoRoot -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
  if ($wt.ExitCode -ne 0) { return @() }
  foreach ($line in $wt.Lines) {
    if ($line -match '^branch refs/heads/(.+)$') {
      $branches += $Matches[1]
    }
  }
  return $branches
}

function Test-IsAncestor {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PossibleAncestor,
    [Parameter(Mandatory)][string]$Descendant
  )
  $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @('merge-base', '--is-ancestor', $PossibleAncestor, $Descendant) -AllowFailure
  return ($r.ExitCode -eq 0)
}

function Get-BranchTipSha {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Ref
  )
  $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', $Ref) -AllowFailure
  if ($r.ExitCode -ne 0) { return $null }
  return $r.Output.Trim()
}

function Get-MergedPrForHead {
  <#
    Returns latest merged PR for a head branch name, or $null.
    Uses gh. Fields: number, url, headRefOid, headRefName, state, mergedAt
  #>
  param(
    [Parameter(Mandatory)][string]$HeadBranch
  )

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = gh pr list --state merged --head $HeadBranch --limit 5 --json number,url,state,headRefOid,headRefName,mergedAt 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $items = $json | ConvertFrom-Json
    if (-not $items -or @($items).Count -eq 0) { return $null }
    # most recently merged first if available
    $sorted = @($items | Sort-Object { $_.mergedAt } -Descending)
    return $sorted[0]
  } catch {
    return $null
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

function Get-RemoteBranchNames {
  <#
    Structured remote branch enum; skips symbolic HEAD and empty names.
    Returns list of @{ Name; FullRef; Sha; IsSymref }
  #>
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Remote = 'origin'
  )

  $fmt = '%(refname:strip=3)|%(symref)|%(objectname)'
  $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @(
    'for-each-ref',
    "--format=$fmt",
    "refs/remotes/$Remote"
  ) -AllowFailure

  $list = @()
  if ($r.ExitCode -ne 0) { return $list }

  foreach ($line in $r.Lines) {
    if (-not $line.Trim()) { continue }
    $parts = $line -split '\|', 3
    if ($parts.Count -lt 3) { continue }
    $name = $parts[0].Trim()
    $symref = $parts[1].Trim()
    $sha = $parts[2].Trim()
    if (-not $name -or $name -eq 'HEAD') { continue }
    if ($symref) { continue }
    $list += [pscustomobject]@{
      Name     = $name
      FullRef  = "$Remote/$name"
      Sha      = $sha
      IsSymref = $false
    }
  }
  return $list
}

function Test-CommandAvailable {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}
