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

function Get-GitHubRepoSlug {
  param([Parameter(Mandatory)][string]$RepoRoot)

  # Prefer upstream (forks keep merged PRs on the parent), then github, then origin.
  foreach ($remote in @('upstream', 'github', 'origin')) {
    $url = (Invoke-Git -RepoRoot $RepoRoot -Arguments @('remote', 'get-url', $remote) -AllowFailure).Output.Trim()
    if (-not $url) { continue }
    if ($url -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$') {
      return ($Matches['owner'] + '/' + $Matches['repo'])
    }
  }
  return $null
}

function Invoke-Gh {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  if (-not (Test-CommandAvailable -Name 'gh')) {
    return [pscustomobject]@{
      ExitCode = 127
      Output   = 'gh not available'
      Lines    = @('gh not available')
    }
  }

  $ghArgs = @()
  $slug = Get-GitHubRepoSlug -RepoRoot $RepoRoot
  if ($slug) { $ghArgs += @('-R', $slug) }
  $ghArgs += $Arguments

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevLoc = Get-Location
  $stdoutParts = @()
  $stderrParts = @()
  try {
    Set-Location -LiteralPath $RepoRoot
    $output = & gh @ghArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($item in @($output)) {
      if ($item -is [System.Management.Automation.ErrorRecord]) {
        $stderrParts += "$item"
      } else {
        $stdoutParts += "$item"
      }
    }
  } catch {
    $stderrParts += "$_"
    $exitCode = 1
  } finally {
    Set-Location $prevLoc
    $ErrorActionPreference = $prevEap
  }

  $text = $stdoutParts -join "`n"
  $errText = $stderrParts -join "`n"

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "gh $($Arguments -join ' ') failed with exit code $exitCode`n$text`n$errText"
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $text
    StdErr   = $errText
    Lines    = @(if ($text) { $text -split "`r?`n" } else { @() })
  }
}

function Get-DefaultBranch {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Prefer = 'main'
  )

  $name = $null
  $view = Invoke-Gh -RepoRoot $RepoRoot -Arguments @(
    'repo', 'view', '--json', 'defaultBranchRef', '-q', '.defaultBranchRef.name'
  ) -AllowFailure
  if ($view.ExitCode -eq 0) {
    $token = $view.Output.Trim()
    if ($token -match '^[A-Za-z0-9._/-]+$') { $name = $token }
  }

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

function Get-CloseoutUserConfig {
  param(
    [string]$SkillRoot = '',
    [string]$UserConfigPath = ''
  )

  $path = $UserConfigPath
  if (-not $path -and $SkillRoot) {
    foreach ($name in @('USER.md', 'USER.example.md')) {
      $candidate = Join-Path $SkillRoot $name
      if (Test-Path -LiteralPath $candidate) {
        $path = $candidate
        break
      }
    }
  }

  $cfg = [ordered]@{
    never_delete_branches = @('main', 'master', 'develop')
    default_branch_prefer = 'main'
    source_path           = $path
  }

  if (-not $path -or -not (Test-Path -LiteralPath $path)) {
    return [pscustomobject]$cfg
  }

  $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -notmatch '^\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|') { continue }
    $key = $Matches[1].Trim()
    $raw = $Matches[2].Trim()
    $raw = $raw -replace '\s+[—–]\s+.*$', ''
    switch ($key) {
      'never_delete_branches' {
        $names = @()
        foreach ($part in ($raw -split ',')) {
          $n = $part.Trim().Trim('`')
          if ($n) { $names += $n }
        }
        if ($names.Count -gt 0) { $cfg.never_delete_branches = $names }
      }
      'default_branch_prefer' {
        $prefer = $null
        if ($raw -match '`([^`]+)`') { $prefer = $Matches[1].Trim() }
        elseif ($raw -match '^(\S+)') { $prefer = $Matches[1].Trim('`', ',', ' ') }
        if ($prefer) { $cfg.default_branch_prefer = $prefer }
      }
    }
  }

  return [pscustomobject]$cfg
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
    Uses gh against RepoRoot (not process cwd). Fields: number, url, headRefOid, headRefName, state, mergedAt
    StubRecords: optional injected list for tests (same shape as gh JSON objects).
  #>
  param(
    [Parameter(Mandatory)][string]$HeadBranch,
    [Parameter(Mandatory)][string]$RepoRoot,
    $StubRecords = $null
  )

  if ($null -ne $StubRecords) {
    $hits = @($StubRecords | Where-Object { $_.headRefName -eq $HeadBranch })
    if ($hits.Count -eq 0) { return $null }
    $sortedStubs = @($hits | Sort-Object { $_.mergedAt } -Descending)
    return $sortedStubs[0]
  }

  $r = Invoke-Gh -RepoRoot $RepoRoot -Arguments @(
    'pr', 'list',
    '--state', 'merged',
    '--head', $HeadBranch,
    '--limit', '5',
    '--json', 'number,url,state,headRefOid,headRefName,mergedAt'
  ) -AllowFailure
  if ($r.ExitCode -ne 0 -or -not $r.Output.Trim()) { return $null }
  try {
    $items = $r.Output | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $items -or @($items).Count -eq 0) { return $null }
  $sorted = @($items | Sort-Object { $_.mergedAt } -Descending)
  return $sorted[0]
}

function Remove-LocalSafeBranch {
  <#
    Delete a local branch already classified SAFE.
    ancestor-merged: try -d, then -D if git refuses because HEAD is not default.
    squash-or-rebase-merged: -D (tip is not an ancestor; -d cannot succeed).
  #>
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Reason
  )

  $useForce = ($Reason -eq 'squash-or-rebase-merged')
  $flag = if ($useForce) { '-D' } else { '-d' }
  $del = Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', $flag, '--', $Name) -AllowFailure
  if ($del.ExitCode -ne 0 -and -not $useForce -and $Reason -eq 'ancestor-merged') {
    $del = Invoke-Git -RepoRoot $RepoRoot -Arguments @('branch', '-D', '--', $Name) -AllowFailure
  }
  return $del
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
