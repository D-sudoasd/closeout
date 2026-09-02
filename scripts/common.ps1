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

function Protect-CloseoutText {
  param([AllowEmptyString()][string]$Text = '')

  if (-not $Text) { return $Text }
  $redacted = $Text
  $redacted = $redacted -replace '(?i)\b(token|password|secret|api[_-]?key|authorization)\b\s*[:=]\s*[^\s,;]+', '$1=***'
  $redacted = $redacted -replace '(?i)\bBearer\s+[^\s,;]+', 'Bearer ***'
  $redacted = $redacted -replace '(?i)(https?://)(?:[^/\s:@]+):(?:[^@\s]+)@', '$1***@'
  $redacted = $redacted -replace '(?s)(-----BEGIN [^-]+ PRIVATE KEY-----).*?(-----END [^-]+ PRIVATE KEY-----)', '${1}***REDACTED***${2}'
  return $redacted
}

function Get-ConfiguredGitRemoteUrl {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Remote
  )

  # Read the configured URL before any url.*.insteadOf rewrite. This keeps
  # repository identity checks bound to the declared remote while Git may
  # still use a transport rewrite for local fixtures or mirrors.
  $configured = Invoke-Git -RepoRoot $RepoRoot -Arguments @('config', '--get', "remote.$Remote.url") -AllowFailure
  if ($configured.ExitCode -eq 0 -and $configured.Output.Trim()) { return $configured.Output.Trim() }
  $resolved = Invoke-Git -RepoRoot $RepoRoot -Arguments @('remote', 'get-url', $Remote) -AllowFailure
  if ($resolved.ExitCode -eq 0) { return $resolved.Output.Trim() }
  return ''
}

function Get-GitHubRepoSlug {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$PreferOrigin,
    [switch]$RequireOrigin
  )

  # Reads prefer upstream (forks keep merged PRs on the parent). Writes can opt
  # into origin first so a PR is never created or merged on the parent by
  # accident.
  $remotes = if ($RequireOrigin) {
    @('origin')
  } elseif ($PreferOrigin) {
    @('origin', 'github', 'upstream')
  } else {
    @('upstream', 'github', 'origin')
  }
  foreach ($remote in $remotes) {
    $url = Get-ConfiguredGitRemoteUrl -RepoRoot $RepoRoot -Remote $remote
    if (-not $url) { continue }
    if ($url -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$') {
      return ($Matches['owner'] + '/' + $Matches['repo'])
    }
  }
  return $null
}

function Test-CloseoutGhWriteOperation {
  param([Parameter(Mandatory)][string[]]$Arguments)

  if (@($Arguments).Count -lt 2) { return $false }
  $group = ([string]$Arguments[0]).ToLowerInvariant()
  $verb = ([string]$Arguments[1]).ToLowerInvariant()
  if ($group -ne 'pr') { return $false }
  return $verb -in @('create', 'merge', 'edit', 'close', 'reopen', 'ready', 'comment', 'review')
}

function Invoke-Gh {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure,
    [string]$RepoSlug = '',
    [switch]$PreferOrigin
  )

  if (-not (Test-CommandAvailable -Name 'gh')) {
    return [pscustomobject]@{
      ExitCode = 127
      Output   = 'gh not available'
      Lines    = @('gh not available')
    }
  }

  $ghArgs = @()
  $writeOperation = Test-CloseoutGhWriteOperation -Arguments $Arguments
  $preferOriginForSlug = [bool]$PreferOrigin -or $writeOperation
  if ($RepoSlug) {
    $slug = $RepoSlug.Trim()
    if ($slug -notmatch '^[^/\s]+/[^/\s]+$') {
      throw "invalid GitHub repository slug: $RepoSlug"
    }
  } elseif ($writeOperation) {
    $slug = Get-GitHubRepoSlug -RepoRoot $RepoRoot -RequireOrigin
  } elseif ($preferOriginForSlug) {
    $slug = Get-GitHubRepoSlug -RepoRoot $RepoRoot -PreferOrigin
  } else {
    $slug = Get-GitHubRepoSlug -RepoRoot $RepoRoot
  }
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
    throw "gh $($Arguments -join ' ') failed with exit code $exitCode`n$(Protect-CloseoutText $text)`n$(Protect-CloseoutText $errText)"
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $text
    StdErr   = $errText
    RepoSlug = $slug
    WriteOperation = $writeOperation
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
  ) -AllowFailure -PreferOrigin
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

  if (-not $name) {
    throw "DEFAULT_BRANCH_UNRESOLVED: could not determine a default branch from GitHub, origin/HEAD, or local main/master"
  }
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
    never_delete_branches   = @('main', 'master', 'develop')
    default_branch_prefer   = 'main'
    prefer_pr               = $true
    pr_draft_default        = $false
    merge_strategy          = 'squash'
    auto_merge_when_green   = $false
    wait_for_checks         = $false
    full_run_confirmation   = $true
    prune_remote_merged     = $true
    prune_local_merged      = $true
    cleanup_temp            = $true
    cleanup_temp_dirs       = @(
      '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache',
      '.tox', '.nox', '.hypothesis', 'htmlcov', '*.egg-info'
    )
    cleanup_temp_files      = @('.coverage', '*.pyc', '*.pyo')
    auto_create_branch      = $true
    push_main_direct        = $false
    allow_no_tests          = $false
    max_untracked_file_mb   = 10
    max_staged_file_mb      = 50
    branch_prefix           = 'codex/'
    source_path             = $path
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
      { $_ -in @('never_delete_branches', 'cleanup_temp_dirs', 'cleanup_temp_files') } {
        $values = @()
        $matches = [regex]::Matches($raw, '`([^`]+)`')
        if ($matches.Count -gt 0) {
          foreach ($m in $matches) { $values += $m.Groups[1].Value.Trim() }
        } else {
          foreach ($part in ($raw -split ',')) {
            $n = $part.Trim().Trim('`')
            if ($n) { $values += $n }
          }
        }
        if ($values.Count -gt 0) { $cfg[$key] = @($values) }
      }
      { $_ -in @(
          'default_branch_prefer', 'merge_strategy', 'branch_prefix', 'branch_prefix_ok'
        ) } {
        $value = $null
        if ($raw -match '`([^`]+)`') { $value = $Matches[1].Trim() }
        elseif ($raw -match '^(\S+)') { $value = $Matches[1].Trim('`', ',', ' ') }
        if ($value) {
          if ($key -eq 'branch_prefix_ok') { $cfg.branch_prefix = ($value -split ',')[0].Trim() }
          else { $cfg[$key] = $value }
        }
      }
      { $_ -in @(
          'prefer_pr', 'pr_draft_default', 'auto_merge_when_green',
          'wait_for_checks', 'full_run_confirmation', 'prune_remote_merged',
          'prune_local_merged', 'cleanup_temp', 'auto_create_branch',
          'push_main_direct', 'allow_no_tests'
        ) } {
        $value = $raw.Trim().Trim('`').Split(' ')[0].ToLowerInvariant()
        if ($value -in @('true', 'yes', 'on', '1')) { $cfg[$key] = $true }
        elseif ($value -in @('false', 'no', 'off', '0')) { $cfg[$key] = $false }
      }
      { $_ -in @('max_untracked_file_mb', 'max_staged_file_mb') } {
        if ($raw -match '(\d+(?:\.\d+)?)') {
          $cfg[$key] = [double]$Matches[1]
        }
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
    [string]$BaseBranch = '',
    $StubRecords = $null
  )

  if ($null -ne $StubRecords) {
    $hits = @($StubRecords | Where-Object {
        $_.state -eq 'MERGED' -and
        $_.headRefName -eq $HeadBranch -and
        (-not $BaseBranch -or $_.baseRefName -eq $BaseBranch)
      })
    if ($hits.Count -eq 0) { return $null }
    $sortedStubs = @($hits | Sort-Object { $_.mergedAt } -Descending)
    return $sortedStubs[0]
  }

  $r = Invoke-Gh -RepoRoot $RepoRoot -Arguments @(
    'pr', 'list',
    '--state', 'merged',
    '--head', $HeadBranch,
    '--limit', '5',
    '--json', 'number,url,state,baseRefName,headRefOid,headRefName,mergedAt'
  ) -AllowFailure
  if ($r.ExitCode -ne 0 -or -not $r.Output.Trim()) { return $null }
  try {
    $items = $r.Output | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $items -or @($items).Count -eq 0) { return $null }
  $hits = @($items | Where-Object {
      $_.state -eq 'MERGED' -and
      (-not $BaseBranch -or $_.baseRefName -eq $BaseBranch)
    })
  if ($hits.Count -eq 0) { return $null }
  $sorted = @($hits | Sort-Object { $_.mergedAt } -Descending)
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

function Get-LiveRemoteBranchTip {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$Name
  )

  $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @(
    'ls-remote', '--heads', $Remote, "refs/heads/$Name"
  ) -AllowFailure
  if ($r.ExitCode -ne 0) {
    return [pscustomobject]@{ status = 'error'; sha = $null; output = $r.Output }
  }
  $line = @($r.Lines | Where-Object { $_ -match '^\s*([0-9a-fA-F]{40})\s+refs/heads/' } | Select-Object -First 1)
  if (-not $line) {
    return [pscustomobject]@{ status = 'absent'; sha = $null; output = $r.Output }
  }
  [void]($line -match '^\s*([0-9a-fA-F]{40})\s+refs/heads/')
  return [pscustomobject]@{ status = 'present'; sha = $Matches[1].ToLowerInvariant(); output = $r.Output }
}

function Test-CommandAvailable {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CloseoutSha256Text {
  param([AllowEmptyString()][string]$Text = '')

  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Write-CloseoutJsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Object,
    [int]$Depth = 12
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $parent = [IO.Path]::GetDirectoryName($fullPath)
  if (-not $parent) { throw "cannot determine parent directory for JSON path: $Path" }
  [IO.Directory]::CreateDirectory($parent) | Out-Null
  $json = $Object | ConvertTo-Json -Depth $Depth
  $encoding = [Text.UTF8Encoding]::new($false)
  $bytes = $encoding.GetBytes($json)
  $tempPath = $null
  $backupPath = $null
  $stream = $null
  $moved = $false
  try {
    for ($attempt = 0; $attempt -lt 3 -and $null -eq $stream; $attempt++) {
      $tempName = '.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($fullPath)), ([guid]::NewGuid().ToString('n'))
      $tempPath = Join-Path $parent $tempName
      try {
        $stream = [IO.FileStream]::new(
          $tempPath,
          [IO.FileMode]::CreateNew,
          [IO.FileAccess]::Write,
          [IO.FileShare]::None,
          65536,
          [IO.FileOptions]::WriteThrough
        )
      } catch [IO.IOException] {
        if ($attempt -ge 2) { throw }
        $tempPath = $null
      }
    }
    if ($null -eq $stream) { throw "could not create sibling temporary JSON file for: $fullPath" }

    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
      $stream = $null
    }

    # File.Replace is atomic when the destination exists; File.Move is atomic
    # for this same-directory first write. Retry only the expected destination
    # race, never fall back to a truncating overwrite.
    for ($attempt = 0; $attempt -lt 3 -and -not $moved; $attempt++) {
      try {
        if ([IO.File]::Exists($fullPath)) {
          # Windows' File.Replace rejects a null/empty backup path on some
          # provider/runtime combinations. A unique sibling backup keeps the
          # replacement atomic while avoiding an overwrite fallback.
          $backupPath = Join-Path $parent ('.{0}.{1}.bak' -f ([IO.Path]::GetFileName($fullPath)), ([guid]::NewGuid().ToString('n')))
          [IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
          if ([IO.File]::Exists($backupPath)) {
            try { [IO.File]::Delete($backupPath) } catch { }
          }
          $backupPath = $null
        } else {
          [IO.File]::Move($tempPath, $fullPath)
        }
        $moved = $true
      } catch [IO.IOException] {
        if ($attempt -ge 2) { throw }
      }
    }
    if (-not $moved) { throw "could not atomically publish JSON file: $fullPath" }
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if ($tempPath -and [IO.File]::Exists($tempPath)) {
      try { [IO.File]::Delete($tempPath) } catch { }
    }
    if ($backupPath -and [IO.File]::Exists($backupPath)) {
      try { [IO.File]::Delete($backupPath) } catch { }
    }
  }
}

function Add-CloseoutJsonLine {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Object
  )

  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $json = $Object | ConvertTo-Json -Depth 12 -Compress
  Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function New-CloseoutRejection {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Reason,
    [bool]$Blocking = $true,
    [string]$Detail = ''
  )

  [pscustomobject]@{
    path = $Path
    reason = $Reason
    blocking = $Blocking
    detail = if ($Detail) { $Detail } else { $null }
  }
}

function Get-CloseoutRunRoot {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$RunId = ''
  )

  if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('n') }
  $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if (-not $local) { $local = [IO.Path]::GetTempPath() }
  $repoHash = (Get-CloseoutSha256Text -Text ([IO.Path]::GetFullPath($RepoRoot).ToLowerInvariant())).Substring(0, 16)
  $root = Join-Path (Join-Path $local 'closeout\runs') (Join-Path $repoHash $RunId)
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return $root
}

function Get-CloseoutRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path
  )

  $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $full = [IO.Path]::GetFullPath($Path)
  $relative = [IO.Path]::GetRelativePath($root, $full)
  if ($relative -eq '.') { return '' }
  return $relative.Replace('\', '/')
}

function Test-CloseoutPathInside {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path,
    [switch]$AllowRoot
  )

  try {
    $root = [IO.Path]::GetFullPath($RepoRoot)
    $full = [IO.Path]::GetFullPath($Path)
    $relative = [IO.Path]::GetRelativePath($root, $full)
  } catch {
    return $false
  }
  if ($relative -eq '.') { return [bool]$AllowRoot }
  if ([IO.Path]::IsPathRooted($relative)) { return $false }
  return $relative -ne '..' -and -not $relative.StartsWith('..\') -and -not $relative.StartsWith('../')
}

function Test-CloseoutPathSafe {
  <#
    Check the lexical path, every existing ancestor from RepoRoot to the
    target, and the provider-resolved final path. Reparse points are opaque;
    no cleanup target may traverse one, even when its final item is ordinary.
  #>
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path,
    [switch]$AllowRoot
  )

  $ancestors = New-Object 'System.Collections.Generic.List[string]'
  $rootFull = $null
  $full = $null
  try {
    $rootFull = [IO.Path]::GetFullPath($RepoRoot)
    $full = if ([IO.Path]::IsPathRooted($Path)) {
      [IO.Path]::GetFullPath($Path)
    } else {
      [IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    }
  } catch {
    return [pscustomobject]@{
      safe = $false
      reason = 'invalid-path'
      path = $Path
      final_path = $null
      reparse_path = $null
      ancestors = @()
    }
  }

  if (-not (Test-CloseoutPathInside -RepoRoot $rootFull -Path $full -AllowRoot:$AllowRoot)) {
    return [pscustomobject]@{
      safe = $false
      reason = 'outside-repo'
      path = $full
      final_path = $null
      reparse_path = $null
      ancestors = @()
    }
  }

  try {
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
  } catch {
    return [pscustomobject]@{
      safe = $false
      reason = 'repo-root-missing'
      path = $full
      final_path = $null
      reparse_path = $null
      ancestors = @()
    }
  }
  [void]$ancestors.Add($rootFull)
  if (-not $rootItem.PSIsContainer) {
    return [pscustomobject]@{
      safe = $false
      reason = 'repo-root-not-directory'
      path = $full
      final_path = $null
      reparse_path = $rootFull
      ancestors = $ancestors.ToArray()
    }
  }
  if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    return [pscustomobject]@{
      safe = $false
      reason = 'reparse-ancestor'
      path = $full
      final_path = $null
      reparse_path = $rootFull
      ancestors = $ancestors.ToArray()
    }
  }

  $relative = [IO.Path]::GetRelativePath($rootFull, $full)
  if ($relative -eq '.') {
    if (-not $AllowRoot) {
      return [pscustomobject]@{
        safe = $false
        reason = 'repo-root-not-allowed'
        path = $full
        final_path = $null
        reparse_path = $null
        ancestors = $ancestors.ToArray()
      }
    }
  } else {
    $parts = @($relative -split '[\\/]' | Where-Object { $_ })
    $current = $rootFull
    for ($index = 0; $index -lt $parts.Count; $index++) {
      $current = Join-Path $current $parts[$index]
      try {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      } catch {
        return [pscustomobject]@{
          safe = $false
          reason = 'path-missing'
          path = $full
          final_path = $null
          reparse_path = $null
          ancestors = $ancestors.ToArray()
        }
      }
      [void]$ancestors.Add($current)
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{
          safe = $false
          reason = if ($index -eq $parts.Count - 1) { 'reparse-point' } else { 'reparse-ancestor' }
          path = $full
          final_path = $null
          reparse_path = $current
          ancestors = $ancestors.ToArray()
        }
      }
      if ($index -lt $parts.Count - 1 -and -not $item.PSIsContainer) {
        return [pscustomobject]@{
          safe = $false
          reason = 'ancestor-not-directory'
          path = $full
          final_path = $null
          reparse_path = $current
          ancestors = $ancestors.ToArray()
        }
      }
    }
  }

  try {
    $resolved = @(Resolve-Path -LiteralPath $full -ErrorAction Stop)
    if ($resolved.Count -ne 1) { throw 'path did not resolve to exactly one item' }
    $finalPath = [IO.Path]::GetFullPath($resolved[0].Path)
  } catch {
    return [pscustomobject]@{
      safe = $false
      reason = 'final-path-unresolved'
      path = $full
      final_path = $null
      reparse_path = $null
      ancestors = $ancestors.ToArray()
    }
  }
  if (-not (Test-CloseoutPathInside -RepoRoot $rootFull -Path $finalPath -AllowRoot:$AllowRoot)) {
    return [pscustomobject]@{
      safe = $false
      reason = 'resolved-outside-repo'
      path = $full
      final_path = $finalPath
      reparse_path = $null
      ancestors = $ancestors.ToArray()
    }
  }
  [pscustomobject]@{
    safe = $true
    reason = $null
    path = $full
    final_path = $finalPath
    reparse_path = $null
    ancestors = $ancestors.ToArray()
  }
}

function Get-CloseoutItemSignature {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RelativePath
  )

  $full = Join-Path $RepoRoot ($RelativePath -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { return $null }
  $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $null }
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    return [pscustomobject]@{
      relative_path      = $RelativePath
      kind               = if ($item.PSIsContainer) { 'directory' } else { 'file' }
      reparse            = $true
      reparse_descendant = $false
      reparse_paths      = @($full)
      bytes              = 0
      file_count         = 0
      last_write_utc = $item.LastWriteTimeUtc.ToString('o')
      fingerprint        = Get-CloseoutSha256Text -Text "$RelativePath|reparse"
    }
  }

  if (-not $item.PSIsContainer) {
    return [pscustomobject]@{
      relative_path  = $RelativePath
      kind           = 'file'
      reparse        = $false
      reparse_descendant = $false
      reparse_paths  = @()
      bytes          = [long]$item.Length
      file_count     = 1
      last_write_utc = $item.LastWriteTimeUtc.ToString('o')
      fingerprint    = Get-CloseoutSha256Text -Text "$RelativePath|file|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    }
  }

  $bytes = [long]0
  $count = 0
  $lastWrite = $item.LastWriteTimeUtc
  $reparsePaths = New-Object 'System.Collections.Generic.List[string]'
  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $stack.Push($item)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [void]$reparsePaths.Add($child.FullName)
        continue
      }
      if ($child.PSIsContainer) {
        $stack.Push($child)
      } else {
        $bytes += [long]$child.Length
        $count++
        if ($child.LastWriteTimeUtc -gt $lastWrite) { $lastWrite = $child.LastWriteTimeUtc }
      }
    }
  }
  return [pscustomobject]@{
    relative_path  = $RelativePath
    kind           = 'directory'
    reparse        = $false
    reparse_descendant = ($reparsePaths.Count -gt 0)
    reparse_paths  = $reparsePaths.ToArray()
    bytes          = $bytes
    file_count     = $count
    last_write_utc = $lastWrite.ToString('o')
    fingerprint    = Get-CloseoutSha256Text -Text "$RelativePath|directory|$bytes|$count|$($lastWrite.Ticks)"
  }
}

function Test-CloseoutTrackedPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RelativePath
  )

  $r = Invoke-Git -RepoRoot $RepoRoot -Arguments @('ls-files', '--', $RelativePath) -AllowFailure
  return ($r.ExitCode -eq 0 -and [bool]$r.Output.Trim())
}

function Get-CloseoutTempCandidates {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string[]]$DirectoryPatterns = @(),
    [string[]]$FilePatterns = @(),
    [string[]]$ExplicitPaths = @()
  )

  try {
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
  } catch {
    return [pscustomobject]@{
      candidates = @()
      rejected = @(New-CloseoutRejection -Path $RepoRoot -Reason 'invalid-repo-root')
      blocking_rejected = @(New-CloseoutRejection -Path $RepoRoot -Reason 'invalid-repo-root')
      has_blocking_rejections = $true
      blocking = $true
      status = 'BLOCKED'
      patterns = [pscustomobject]@{ directories = @($DirectoryPatterns); files = @($FilePatterns) }
    }
  }
  $skipNames = @('.git')
  $dirs = @($DirectoryPatterns | Where-Object { $_ -and $_.Trim() })
  $files = @($FilePatterns | Where-Object { $_ -and $_.Trim() })
  $candidates = New-Object 'System.Collections.Generic.List[object]'
  $rejected = New-Object 'System.Collections.Generic.List[object]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

  $rootSafety = Test-CloseoutPathSafe -RepoRoot $RepoRoot -Path $RepoRoot -AllowRoot
  if (-not $rootSafety.safe) {
    $rootRejection = New-CloseoutRejection -Path $RepoRoot -Reason $rootSafety.reason -Detail $rootSafety.reparse_path
    return [pscustomobject]@{
      candidates = @()
      rejected = @($rootRejection)
      blocking_rejected = @($rootRejection)
      has_blocking_rejections = $true
      blocking = $true
      status = 'BLOCKED'
      patterns = [pscustomobject]@{ directories = $dirs; files = $files }
    }
  }

  function Add-TempItem {
    param([IO.FileSystemInfo]$Item, [string]$Pattern, [string]$FullPath = '')
    if (-not $Item) { return }
    $full = if ($FullPath) { [IO.Path]::GetFullPath($FullPath) } else { [IO.Path]::GetFullPath($Item.FullName) }
    if (-not (Test-CloseoutPathInside -RepoRoot $RepoRoot -Path $full)) {
      [void]$rejected.Add((New-CloseoutRejection -Path $full -Reason 'outside-repo'))
      return
    }
    $relative = Get-CloseoutRelativePath -RepoRoot $RepoRoot -Path $full
    if (-not $relative -or $relative.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not $seen.Add($relative)) { return }
    $safety = Test-CloseoutPathSafe -RepoRoot $RepoRoot -Path $full
    if (-not $safety.safe) {
      [void]$rejected.Add((New-CloseoutRejection -Path $relative -Reason $safety.reason -Detail $safety.reparse_path))
      return
    }
    $sig = Get-CloseoutItemSignature -RepoRoot $RepoRoot -RelativePath $relative
    if (-not $sig) { return }
    if ($sig.reparse) {
      [void]$rejected.Add((New-CloseoutRejection -Path $relative -Reason 'reparse-point'))
      return
    }
    if ($sig.reparse_descendant) {
      [void]$rejected.Add((New-CloseoutRejection -Path $relative -Reason 'reparse-descendant' -Detail ($sig.reparse_paths -join '; ')))
      return
    }
    if (Test-CloseoutTrackedPath -RepoRoot $RepoRoot -RelativePath $relative) {
      [void]$rejected.Add((New-CloseoutRejection -Path $relative -Reason 'tracked-by-git'))
      return
    }
    [void]$candidates.Add([pscustomobject]@{
      relative_path  = $relative
      full_path      = $full
      kind           = $sig.kind
      pattern        = $Pattern
      bytes          = $sig.bytes
      file_count     = $sig.file_count
      last_write_utc = $sig.last_write_utc
      fingerprint    = $sig.fingerprint
      action         = 'delete'
    })
  }

  foreach ($explicit in @($ExplicitPaths | Where-Object { $_ -and $_.Trim() })) {
    if ([IO.Path]::IsPathRooted($explicit) -or $explicit -match '(^|[\\/])\.\.([\\/]|$)' -or
      $explicit.Trim().TrimEnd('/', '\') -match '^(?:\.git|)$') {
      [void]$rejected.Add((New-CloseoutRejection -Path $explicit -Reason 'explicit-path-not-relative'))
      continue
    }
    $full = Join-Path $RepoRoot ($explicit -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item) { Add-TempItem -Item $item -Pattern 'explicit-path' -FullPath $full }
    else { [void]$rejected.Add((New-CloseoutRejection -Path $explicit -Reason 'explicit-path-missing' -Blocking $false)) }
  }

  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $rootItem = Get-Item -LiteralPath $RepoRoot -Force
  $stack.Push($rootItem)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $matchesPattern = $false
        foreach ($pattern in $dirs) {
          if ($child.Name -like $pattern) { $matchesPattern = $true; break }
        }
        if ($matchesPattern -or $child.Name -eq '.coverage') {
          [void]$rejected.Add((New-CloseoutRejection -Path (Get-CloseoutRelativePath -RepoRoot $RepoRoot -Path $child.FullName) -Reason 'reparse-point'))
        }
        continue
      }
      if ($child.Name -in $skipNames) { continue }
      if ($child.PSIsContainer) {
        $match = $false
        foreach ($pattern in $dirs) {
          if ($child.Name -like $pattern) { Add-TempItem -Item $child -Pattern $pattern; $match = $true; break }
        }
        if (-not $match) { $stack.Push($child) }
      } else {
        foreach ($pattern in $files) {
          if ($child.Name -like $pattern) { Add-TempItem -Item $child -Pattern $pattern; break }
        }
      }
    }
  }

  $rejectedItems = @($rejected.ToArray() | Sort-Object path, reason)
  $blockingRejected = @($rejectedItems | Where-Object { $_.blocking })
  [pscustomobject]@{
    candidates = @($candidates.ToArray() | Sort-Object relative_path)
    rejected = $rejectedItems
    blocking_rejected = $blockingRejected
    has_blocking_rejections = ($blockingRejected.Count -gt 0)
    blocking = ($blockingRejected.Count -gt 0)
    status = if ($blockingRejected.Count -gt 0) { 'BLOCKED' } else { 'READY' }
    patterns = [pscustomobject]@{ directories = $dirs; files = $files }
  }
}

function Invoke-CloseoutTempCleanup {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$Apply,
    $PlannedCandidates = $null,
    [switch]$AllowNewSafeCandidates,
    [string[]]$DirectoryPatterns = @(),
    [string[]]$FilePatterns = @(),
    [string[]]$ExplicitPaths = @()
  )

  $scan = Get-CloseoutTempCandidates -RepoRoot $RepoRoot -DirectoryPatterns $DirectoryPatterns -FilePatterns $FilePatterns -ExplicitPaths $ExplicitPaths
  $byPath = @{}
  foreach ($item in @($scan.candidates)) { $byPath[$item.relative_path] = $item }
  $targets = @()
  $stale = @()
  if ($null -ne $PlannedCandidates) {
    foreach ($planned in @($PlannedCandidates)) {
      $path = [string]$planned.relative_path
      if (-not $path) { continue }
      if ($byPath.ContainsKey($path)) {
        $current = $byPath[$path]
        if ($planned.fingerprint -and $current.fingerprint -ne $planned.fingerprint) {
          $current.action = 'stale-plan'
          $stale += $current
          continue
        }
        $targets += $current
      }
    }
    if ($AllowNewSafeCandidates) {
      $plannedPaths = @($PlannedCandidates | ForEach-Object { [string]$_.relative_path })
      foreach ($candidate in @($scan.candidates)) {
        if ($candidate.relative_path -notin $plannedPaths) { $targets += $candidate }
      }
    }
  } else {
    $targets = @($scan.candidates)
  }
  $targets = @($targets | Sort-Object relative_path -Unique)

  $deleted = @()
  $failed = @($stale)
  $skipped = @($scan.rejected)
  $blockingRejected = @($scan.rejected | Where-Object { $_.blocking })
  if ($Apply -and $blockingRejected.Count -gt 0) {
    $failed += $blockingRejected
  }
  foreach ($candidate in $targets) {
    if (-not $Apply) { continue }
    $full = Join-Path $RepoRoot ($candidate.relative_path -replace '/', '\')
    $safety = Test-CloseoutPathSafe -RepoRoot $RepoRoot -Path $full
    if (-not $safety.safe) {
      $candidate.action = "blocked-$($safety.reason)"
      $candidate.blocking = $true
      $candidate.detail = $safety.reparse_path
      $failed += $candidate
      continue
    }
    $fresh = Get-CloseoutItemSignature -RepoRoot $RepoRoot -RelativePath $candidate.relative_path
    if (-not $fresh -or $fresh.reparse -or $fresh.reparse_descendant -or $fresh.fingerprint -ne $candidate.fingerprint) {
      $candidate.action = 'stale-or-changed'
      $candidate.blocking = $true
      $failed += $candidate
      continue
    }
    try {
      Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    } catch {
      $candidate.action = 'delete-failed'
      $candidate.error = "$($_)"
      $failed += $candidate
      continue
    }
    if (Test-Path -LiteralPath $full) {
      $candidate.action = 'delete-failed-still-exists'
      $failed += $candidate
    } else {
      $candidate.action = 'deleted'
      $deleted += $candidate
    }
  }

  $status = if ($failed.Count -gt 0 -or $blockingRejected.Count -gt 0) { 'BLOCKED' } else { 'READY' }
  [pscustomobject]@{
    dry_run = (-not $Apply)
    applied = [bool]$Apply
    status = $status
    blocking = ($blockingRejected.Count -gt 0 -or $failed.Count -gt 0)
    has_blocking_rejections = ($blockingRejected.Count -gt 0)
    blocking_rejected = $blockingRejected
    patterns = $scan.patterns
    candidates = @($targets)
    rejected = @($skipped)
    deleted = @($deleted)
    failed = @($failed)
  }
}

function Invoke-CloseoutShellCommand {
  param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [switch]$AllowFailure
  )

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $stdoutParts = @()
  $stderrParts = @()
  $oldLocation = Get-Location
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $output = & pwsh -NoProfile -Command $Command 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($item in @($output)) {
      if ($item -is [System.Management.Automation.ErrorRecord]) { $stderrParts += "$item" }
      else { $stdoutParts += "$item" }
    }
  } catch {
    $stderrParts += "$($_)"
    $exitCode = 1
  } finally {
    Set-Location -LiteralPath $oldLocation
    $ErrorActionPreference = $prevEap
  }
  $result = [pscustomobject]@{
    command  = $Command
    exit_code = $exitCode
    stdout   = ($stdoutParts -join "`n")
    stderr   = ($stderrParts -join "`n")
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "verify command failed with exit code $exitCode`n$(Protect-CloseoutText $result.stdout)`n$(Protect-CloseoutText $result.stderr)"
  }
  return $result
}
