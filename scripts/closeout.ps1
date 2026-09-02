<#
.SYNOPSIS
  Plan, apply, or resume a complete closeout run.

  The default mode is read-only planning. Apply requires a plan file produced
  by this script. Resume continues from the external checkpoint written by a
  previous apply. Repository state, command results, and evidence stay outside
  the target repository.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [switch]$Plan,
  [switch]$Apply,
  [switch]$Resume,
  [string]$PlanFile = '',
  [string]$StateFile = '',
  [string]$Message = '',
  [string[]]$VerifyCommand = @(),
  [string]$UserConfigPath = '',
  [switch]$AllowNoTests,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')

function Get-CanonicalPath {
  param([Parameter(Mandatory)][string]$Path)
  return (Resolve-Path -LiteralPath $Path).Path
}

function Get-CloseoutMergeStrategy {
  param([AllowEmptyString()][string]$Value = '')

  $normalized = if ($null -eq $Value) { '' } else { $Value.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'squash' { return [pscustomobject]@{ name = 'squash'; flag = '--squash' } }
    'merge'  { return [pscustomobject]@{ name = 'merge'; flag = '--merge' } }
    'rebase' { return [pscustomobject]@{ name = 'rebase'; flag = '--rebase' } }
    default  { throw "CONFIG_INVALID: unsupported merge_strategy '$Value'; expected squash, merge, or rebase" }
  }
}

function Get-CloseoutFunctionParameter {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [Parameter(Mandatory)][string[]]$Candidates
  )

  $command = Get-Command -Name $CommandName -CommandType Function -ErrorAction SilentlyContinue
  if (-not $command) { return $null }
  foreach ($candidate in $Candidates) {
    if ($command.Parameters.ContainsKey($candidate)) { return $candidate }
  }
  return $null
}

function Get-OriginGitHubRepoSlug {
  param([Parameter(Mandatory)][string]$Root)

  # Newer common.ps1 versions expose an explicit remote selector. Use it when
  # present; older versions are bypassed below because they prefer upstream.
  $remoteParameter = Get-CloseoutFunctionParameter -CommandName 'Get-GitHubRepoSlug' -Candidates @(
    'RequireOrigin', 'OriginOnly', 'RemoteName', 'Remote', 'PreferredRemote', 'PreferRemote', 'GitRemote',
    'OriginRemote', 'OriginPreferred', 'PreferOrigin'
  )
  if ($remoteParameter) {
    $slugArgs = @{ RepoRoot = $Root }
    if ($remoteParameter -in @('RequireOrigin', 'OriginOnly', 'OriginPreferred', 'PreferOrigin')) { $slugArgs[$remoteParameter] = $true }
    else { $slugArgs[$remoteParameter] = 'origin' }
    $slug = & Get-GitHubRepoSlug @slugArgs
    if ($slug) { return ([string]$slug).Trim() }
  }

  $url = Get-ConfiguredGitRemoteUrl -RepoRoot $Root -Remote 'origin'
  if (-not $url) { return $null }
  if ($url -and $url -match '(?i)github\.com[:/](?<owner>[^/]+)/(?<repo>[^/?#]+?)(?:\.git)?(?:[/?#].*)?$') {
    return ($Matches['owner'] + '/' + $Matches['repo'])
  }
  return $null
}

function Invoke-ExternalGitHub {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  if (-not (Test-CommandAvailable -Name 'gh')) {
    $missing = [pscustomobject]@{
      ExitCode = 127
      Output = ''
      StdErr = 'gh not available'
      Lines = @()
    }
    if (-not $AllowFailure) { throw 'gh not available' }
    return $missing
  }

  $slug = Get-OriginGitHubRepoSlug -Root $Root
  $ghArgs = @()
  if ($slug) { $ghArgs += @('-R', $slug) }
  $ghArgs += $Arguments
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevLoc = Get-Location
  $stdoutParts = @()
  $stderrParts = @()
  try {
    Set-Location -LiteralPath $Root
    $output = & gh @ghArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($item in @($output)) {
      if ($item -is [System.Management.Automation.ErrorRecord]) { $stderrParts += "$item" }
      else { $stdoutParts += "$item" }
    }
  } catch {
    $stderrParts += "$($_)"
    $exitCode = 1
  } finally {
    Set-Location -LiteralPath $prevLoc
    $ErrorActionPreference = $prevEap
  }
  $result = [pscustomobject]@{
    ExitCode = $exitCode
    Output = ($stdoutParts -join "`n")
    StdErr = ($stderrParts -join "`n")
    Lines = @($stdoutParts)
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "gh $($Arguments -join ' ') failed with exit code $exitCode`n$($result.Output)`n$($result.StdErr)"
  }
  return $result
}

function Invoke-OriginGitHub {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  # Prefer an origin-aware shared helper if another agent has already added
  # one. The fallback explicitly binds gh to origin's GitHub slug.
  $remoteParameter = Get-CloseoutFunctionParameter -CommandName 'Invoke-Gh' -Candidates @(
    'RemoteName', 'Remote', 'PreferredRemote', 'PreferRemote', 'GitRemote',
    'OriginRemote', 'OriginPreferred', 'PreferOrigin'
  )
  if ($remoteParameter) {
    $ghArgs = @{ RepoRoot = $Root; Arguments = $Arguments }
    if ($AllowFailure) { $ghArgs.AllowFailure = $true }
    if ($remoteParameter -in @('OriginPreferred', 'PreferOrigin')) { $ghArgs[$remoteParameter] = $true }
    else { $ghArgs[$remoteParameter] = 'origin' }
    return (& Invoke-Gh @ghArgs)
  }
  return Invoke-ExternalGitHub -Root $Root -Arguments $Arguments -AllowFailure:$AllowFailure
}

function Get-LatestMergedPrForTip {
  param(
    [Parameter(Mandatory)]$Context,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$TipSha
  )

  if (-not $Context -or -not $TipSha) { return $null }
  $all = @($Context.merged)
  if ($Context.current -and $Context.current.state -eq 'MERGED') { $all += $Context.current }
  $hits = @($all | Where-Object {
      $_.state -eq 'MERGED' -and
      $_.baseRefName -eq $Base -and
      $_.headRefName -eq $Branch -and
      $_.headRefOid -eq $TipSha
    })
  if ($hits.Count -eq 0) { return $null }
  return @($hits | Sort-Object { $_.mergedAt } -Descending)[0]
}

function Get-CloseoutCheckReadiness {
  param([Parameter(Mandatory)]$Pr)

  $checks = @($Pr.statusCheckRollup | Where-Object { $_ })
  if ($checks.Count -eq 0) {
    return [pscustomobject]@{ state = 'unknown'; checks = @(); detail = 'statusCheckRollup unavailable' }
  }
  $pending = @()
  $failed = @()
  $unknown = @()
  $readyConclusions = @('SUCCESS', 'NEUTRAL', 'SKIPPED', 'EXPECTED')
  $failedConclusions = @('FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STALE')
  foreach ($check in $checks) {
    $status = ([string]$check.status).Trim().ToUpperInvariant()
    $conclusion = ([string]$check.conclusion).Trim().ToUpperInvariant()
    $state = ([string]$check.state).Trim().ToUpperInvariant()
    $label = if ($check.name) { [string]$check.name } elseif ($check.context) { [string]$check.context } else { 'unnamed-check' }
    if ($status -in @('QUEUED', 'IN_PROGRESS', 'PENDING', 'REQUESTED', 'WAITING') -or
      $state -in @('PENDING', 'EXPECTED') -or
      (-not $conclusion -and $status -and $status -ne 'COMPLETED')) {
      $pending += $label
    } elseif ($conclusion -in $failedConclusions -or $state -in @('FAILURE', 'ERROR')) {
      $failed += $label
    } elseif ($conclusion -in $readyConclusions -or $state -eq 'SUCCESS' -or $status -eq 'COMPLETED') {
      continue
    } else {
      $unknown += $label
    }
  }
  if ($failed.Count -gt 0) {
    return [pscustomobject]@{ state = 'failed'; checks = $checks; detail = ($failed -join ', ') }
  }
  if ($pending.Count -gt 0) {
    return [pscustomobject]@{ state = 'pending'; checks = $checks; detail = ($pending -join ', ') }
  }
  if ($unknown.Count -gt 0) {
    return [pscustomobject]@{ state = 'unknown'; checks = $checks; detail = ($unknown -join ', ') }
  }
  return [pscustomobject]@{ state = 'ready'; checks = $checks; detail = 'all reported checks complete' }
}

function Get-RepoStatusRecords {
  param([Parameter(Mandatory)][string]$Root)

  $r = Invoke-Git -RepoRoot $Root -Arguments @('-c', 'core.quotePath=false', 'status', '--porcelain=v1', '-uall') -AllowFailure
  if ($r.ExitCode -ne 0) { throw "git status failed: $($r.Output)" }
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in @($r.Lines)) {
    if (-not $line -or $line.Length -lt 3) { continue }
    $x = $line.Substring(0, 1)
    $y = $line.Substring(1, 1)
    $path = $line.Substring(3)
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
    $path = $path.Trim().TrimEnd('/', '\')
    $conflict = ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D'))
    [void]$records.Add([pscustomobject]@{
      path       = $path.Replace('\', '/')
      index      = $x
      worktree   = $y
      untracked  = ($x -eq '?' -and $y -eq '?')
      conflicted = $conflict
    })
  }
  return $records.ToArray()
}

function Get-WorkingTreeContentFingerprint {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$Records
  )
  $tokens = New-Object 'System.Collections.Generic.List[string]'
  foreach ($record in @($Records | Sort-Object path)) {
    $relative = [string]$record.path
    $full = Join-Path $Root ($relative -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    $content = 'missing'
    if ($item -and -not $item.PSIsContainer) {
      try {
        $content = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
      } catch {
        $content = "unreadable|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
      }
    } elseif ($item) {
      $signature = Get-CloseoutItemSignature -RepoRoot $Root -RelativePath $relative
      if ($signature) { $content = $signature.fingerprint }
    }
    [void]$tokens.Add("$($record.index)$($record.worktree)|$relative|$content")
  }
  return Get-CloseoutSha256Text -Text ($tokens.ToArray() -join ([Environment]::NewLine))
}

function Get-UpstreamCounts {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Upstream = ''
  )

  if (-not $Upstream) { return [pscustomobject]@{ ahead = $null; behind = $null } }
  $r = Invoke-Git -RepoRoot $Root -Arguments @('rev-list', '--left-right', '--count', "HEAD...$Upstream") -AllowFailure
  if ($r.ExitCode -ne 0 -or $r.Output.Trim() -notmatch '^\s*(\d+)\s+(\d+)\s*$') {
    return [pscustomobject]@{ ahead = $null; behind = $null }
  }
  return [pscustomobject]@{
    ahead  = [int]$Matches[1]
    behind = [int]$Matches[2]
  }
}

function Get-RepoSnapshot {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$DefaultBranch
  )

  $branch = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
  $head = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD') -AllowFailure).Output.Trim()
  $upstreamProbe = Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', '--abbrev-ref', '@{upstream}') -AllowFailure
  $upstream = if ($upstreamProbe.ExitCode -eq 0 -and $upstreamProbe.Output.Trim() -match '^[^\s]+$') {
    $upstreamProbe.Output.Trim()
  } else { '' }
  $records = @(Get-RepoStatusRecords -Root $Root)
  $statusCanonical = @($records | Sort-Object path | ForEach-Object {
    "$($_.index)$($_.worktree) $($_.path)"
  }) -join ([Environment]::NewLine)
  $counts = Get-UpstreamCounts -Root $Root -Upstream $upstream
  $defaultTip = Get-BranchTipSha -RepoRoot $Root -Ref $DefaultBranch
  if (-not $defaultTip) { $defaultTip = Get-BranchTipSha -RepoRoot $Root -Ref "origin/$DefaultBranch" }
  $remotes = @()
  foreach ($name in @((Invoke-Git -RepoRoot $Root -Arguments @('remote')).Lines)) {
    if (-not $name.Trim()) { continue }
    $url = Get-ConfiguredGitRemoteUrl -RepoRoot $Root -Remote $name.Trim()
    $remotes += [pscustomobject]@{ name = $name.Trim(); url = Protect-RemoteUrl $url }
  }
  $worktrees = (Invoke-Git -RepoRoot $Root -Arguments @('worktree', 'list') -AllowFailure).Output.Trim()
  $payload = [ordered]@{
    root                = $Root
    branch              = $branch
    detached_head       = (-not $branch)
    head                = $head
    default_branch      = $DefaultBranch
    default_tip         = $defaultTip
    upstream            = $upstream
    ahead               = $counts.ahead
    behind              = $counts.behind
    status_records      = $records
    status_fingerprint  = Get-CloseoutSha256Text -Text $statusCanonical
    content_fingerprint = Get-WorkingTreeContentFingerprint -Root $Root -Records $records
    staged_count        = @($records | Where-Object { $_.index -ne ' ' -and -not $_.untracked }).Count
    unstaged_count      = @($records | Where-Object { $_.worktree -ne ' ' -and -not $_.untracked }).Count
    untracked_count     = @($records | Where-Object { $_.untracked }).Count
    conflicted_count    = @($records | Where-Object { $_.conflicted }).Count
    in_progress_ops     = @(Get-InProgressGitOps -RepoRoot $Root)
    remotes             = $remotes
    worktrees           = $worktrees
    tools               = [ordered]@{
      git  = Test-CommandAvailable 'git'
      gh   = Test-CommandAvailable 'gh'
      pwsh = Test-CommandAvailable 'pwsh'
    }
  }
  return [pscustomobject]$payload
}

function Get-JsonItems {
  param([string]$Text)
  if (-not $Text.Trim()) { return @() }
  try { $value = $Text | ConvertFrom-Json } catch { return @() }
  return @($value)
}

function Get-PrView {
  param([Parameter(Mandatory)][string]$Root)

  $fields = 'number,url,state,title,mergeable,isDraft,baseRefName,headRefName,headRefOid,mergedAt,mergeCommit,reviewDecision,mergeStateStatus,statusCheckRollup'
  $branch = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current') -AllowFailure).Output.Trim()
  if (-not $branch) { return $null }
  $r = Invoke-OriginGitHub -Root $Root -Arguments @('pr', 'view', $branch, '--json', $fields) -AllowFailure
  if ($r.ExitCode -ne 0 -or -not $r.Output.Trim()) { return $null }
  try { return ($r.Output | ConvertFrom-Json) } catch { return $null }
}

function Get-PrListForHead {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Head,
    [string]$State = 'all'
  )

  $fields = 'number,url,state,title,mergeable,isDraft,baseRefName,headRefName,headRefOid,mergedAt,mergeCommit'
  $r = Invoke-OriginGitHub -Root $Root -Arguments @(
    'pr', 'list', '--state', $State, '--head', $Head, '--limit', '20', '--json', $fields
  ) -AllowFailure
  if ($r.ExitCode -ne 0) { return @() }
  return @(Get-JsonItems -Text $r.Output)
}

function Get-PrContext {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Branch
  )

  if (-not (Test-CommandAvailable 'gh')) {
    return [pscustomobject]@{ current = $null; open = @(); closed = @(); merged = @(); error = 'gh unavailable' }
  }
  $current = Get-PrView -Root $Root
  $all = @(Get-PrListForHead -Root $Root -Head $Branch -State 'all')
  $open = @($all | Where-Object { $_.state -eq 'OPEN' })
  $closed = @($all | Where-Object { $_.state -eq 'CLOSED' })
  $merged = @($all | Where-Object { $_.state -eq 'MERGED' })
  return [pscustomobject]@{
    current = $current
    open    = $open
    closed  = $closed
    merged  = $merged
    error   = $null
  }
}

function Get-GeneratedBranchName {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Prefix = 'codex/'
  )

  if (-not $Prefix) { $Prefix = 'codex/' }
  if ($Prefix -notmatch '^[A-Za-z0-9._/-]+$') { $Prefix = 'codex/' }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $base = "$Prefix" + "closeout-$stamp"
  $candidate = $base
  $counter = 0
  while ((Get-BranchTipSha -RepoRoot $Root -Ref $candidate) -or
    (Get-BranchTipSha -RepoRoot $Root -Ref "origin/$candidate")) {
    $counter++
    $candidate = "$base-$counter"
  }
  return $candidate
}

function Test-SensitivePath {
  param([Parameter(Mandatory)][string]$Path)
  $normalized = $Path.Replace('\', '/')
  $leaf = Split-Path -Leaf $normalized
  if ($normalized -match '(^|/)(\.closeout|USER\.md)(/|$)') { return $true }
  if ($leaf -match '^(?:\.env(?:\..*)?|credentials(?:\..*)?|secrets?(?:\..*)?)$') { return $true }
  if ($leaf -match '^(?:id_rsa|id_ed25519|.*\.(?:pem|key|p12|pfx|kdbx))$') { return $true }
  return $false
}

function Test-RawDataPath {
  param([Parameter(Mandatory)][string]$Path)
  return ($Path.ToLowerInvariant() -match '\.(cbf|h5|hdf|hdf5|nxs|edf|mrc|npy|npz|tif|tiff|mda|raw|dat|bin|zip|tar|gz)$')
}

function Test-ConfiguredTempPath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$TempScan
  )

  $normalized = $Path.Replace('\', '/')
  $parts = @($normalized -split '/' | Where-Object { $_ })
  $directories = @($TempScan.patterns.directories)
  foreach ($part in @($parts | Select-Object -SkipLast 1)) {
    foreach ($pattern in $directories) {
      if ($part -like [string]$pattern) { return $true }
    }
  }
  $leaf = if ($parts.Count -gt 0) { [string]$parts[-1] } else { $normalized }
  foreach ($pattern in @($TempScan.patterns.files)) {
    if ($leaf -like [string]$pattern) { return $true }
  }
  return $false
}

function Get-FileSizeBytes {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$RelativePath
  )
  $full = Join-Path $Root ($RelativePath -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return 0L }
  try { return [long](Get-Item -LiteralPath $full -Force).Length } catch { return 0L }
}

function Get-StagePlan {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$Records,
    [Parameter(Mandatory)]$TempScan,
    [double]$MaxUntrackedMb = 10,
    [double]$MaxStagedMb = 50
  )

  $safeExtensions = @(
    '.ps1', '.psm1', '.py', '.pyi', '.js', '.jsx', '.ts', '.tsx', '.json',
    '.toml', '.yaml', '.yml', '.md', '.txt', '.rst', '.c', '.cc', '.cpp',
    '.h', '.hpp', '.cs', '.java', '.go', '.rs', '.sh', '.bat', '.cmd',
    '.html', '.css', '.scss', '.svg', '.tex', '.bib', '.ini', '.cfg'
  )
  $tempPaths = @($TempScan.candidates | ForEach-Object { $_.relative_path })
  # A matching temp root can be rejected because it is tracked or contains a
  # reparse point. Keep those paths out of the commit plan as well; the plan
  # is already blocked by the rejection and must not smuggle the path into a
  # commit while reporting it as cleanup-only.
  $tempPaths += @($TempScan.rejected | Where-Object {
      $_.reason -in @('tracked-by-git', 'reparse-point', 'reparse-descendant') -and
      $_.path -and -not [IO.Path]::IsPathRooted([string]$_.path)
    } | ForEach-Object { ([string]$_.path).Replace('\', '/') })
  $tempPaths = @($tempPaths | Where-Object { $_ } | Sort-Object -Unique)
  $include = New-Object 'System.Collections.Generic.List[string]'
  $exclude = New-Object 'System.Collections.Generic.List[object]'
  $blocked = New-Object 'System.Collections.Generic.List[object]'
  foreach ($record in @($Records)) {
    $path = [string]$record.path
    if (-not $path) { continue }
    $isTrackedChange = -not $record.untracked
    $isUnderTemp = $false
    foreach ($tempPath in $tempPaths) {
      if ($path.Equals($tempPath, [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith("$tempPath/", [StringComparison]::OrdinalIgnoreCase)) {
        $isUnderTemp = $true
        break
      }
    }
    $matchesTempPattern = Test-ConfiguredTempPath -Path $path -TempScan $TempScan
    $reason = $null
    if ($record.conflicted) { $reason = 'conflicted' }
    elseif (Test-SensitivePath -Path $path) { $reason = 'sensitive-path' }
    elseif (Test-RawDataPath -Path $path) { $reason = 'raw-data-like' }
    elseif ($isUnderTemp) { $reason = 'safe-temp-cleanup' }
    elseif ($matchesTempPattern) { $reason = 'unlisted-temp-path' }
    else {
      $size = Get-FileSizeBytes -Root $Root -RelativePath $path
      if ($isTrackedChange) {
        if ($size -gt ($MaxStagedMb * 1MB)) { $reason = 'over-max-staged-size' }
      } else {
        $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($size -gt ($MaxUntrackedMb * 1MB)) { $reason = 'over-max-untracked-size' }
        elseif ($ext -notin $safeExtensions) { $reason = 'unknown-untracked-type' }
      }
    }
    if ($reason) {
      $item = [pscustomobject]@{
        path = $path
        reason = $reason
        staged = ($record.index -ne ' ' -and -not $record.untracked)
      }
      [void]$exclude.Add($item)
      if ($item.staged -and $reason -ne 'safe-temp-cleanup') { [void]$blocked.Add($item) }
    } else {
      [void]$include.Add($path)
    }
  }
  return [pscustomobject]@{
    include = @($include.ToArray() | Sort-Object -Unique)
    exclude = $exclude.ToArray()
    blocked = $blocked.ToArray()
  }
}

function Get-VerifyCommands {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string[]]$Explicit = @()
  )

  $commands = New-Object 'System.Collections.Generic.List[object]'
  foreach ($command in @($Explicit | Where-Object { $_ -and $_.Trim() })) {
    [void]$commands.Add([pscustomobject]@{
      name = "explicit-$($commands.Count + 1)"
      command = $command
      source = 'argument'
    })
  }
  if ($commands.Count -gt 0) { return $commands.ToArray() }

  $configPath = Join-Path $Root 'closeout.verify.json'
  if (Test-Path -LiteralPath $configPath) {
    try {
      $verifyConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($command in @($verifyConfig.commands)) {
        if ($command -is [string] -and $command.Trim()) {
          [void]$commands.Add([pscustomobject]@{
            name = "config-$($commands.Count + 1)"
            command = $command
            source = 'closeout.verify.json'
          })
        } elseif ($command.command) {
          [void]$commands.Add([pscustomobject]@{
            name = if ($command.name) { [string]$command.name } else { "config-$($commands.Count + 1)" }
            command = [string]$command.command
            source = 'closeout.verify.json'
          })
        }
      }
    } catch {
      throw "Invalid closeout.verify.json: $($_)"
    }
  }
  if ($commands.Count -gt 0) { return $commands.ToArray() }

  if ((Test-Path (Join-Path $Root 'scripts\self_check.ps1')) -and
    (Test-Path (Join-Path $Root 'scripts\test_fixtures.ps1'))) {
    [void]$commands.Add([pscustomobject]@{
      name = 'closeout-self-check'
      command = 'pwsh -NoProfile -File .\scripts\self_check.ps1 -SkillRoot .'
      source = 'closeout-layout'
    })
    [void]$commands.Add([pscustomobject]@{
      name = 'closeout-fixtures'
      command = 'pwsh -NoProfile -File .\scripts\test_fixtures.ps1 -SkillRoot .'
      source = 'closeout-layout'
    })
    if (Test-Path (Join-Path $Root 'scripts\test_orchestrator.ps1')) {
      [void]$commands.Add([pscustomobject]@{
        name = 'closeout-orchestrator'
        command = 'pwsh -NoProfile -File .\scripts\test_orchestrator.ps1 -SkillRoot .'
        source = 'closeout-layout'
      })
    }
    return $commands.ToArray()
  }

  $packagePath = Join-Path $Root 'package.json'
  if (Test-Path -LiteralPath $packagePath) {
    try {
      $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($name in @('test', 'check', 'lint')) {
        if ($package.scripts.$name) {
          [void]$commands.Add([pscustomobject]@{
            name = "npm-$name"
            command = "npm run $name"
            source = 'package.json'
          })
          break
        }
      }
    } catch {
      throw "Invalid package.json: $($_)"
    }
  }
  if ($commands.Count -eq 0 -and ((Test-Path (Join-Path $Root 'pyproject.toml')) -or
      (Test-Path (Join-Path $Root 'pytest.ini')) -or (Test-Path (Join-Path $Root 'tox.ini')))) {
    [void]$commands.Add([pscustomobject]@{
      name = 'python-pytest'
      command = 'python -m pytest'
      source = 'python-layout'
    })
  }
  if ($commands.Count -eq 0 -and (Test-Path (Join-Path $Root 'Cargo.toml'))) {
    [void]$commands.Add([pscustomobject]@{
      name = 'cargo-test'
      command = 'cargo test'
      source = 'Cargo.toml'
    })
  }
  if ($commands.Count -eq 0 -and (Test-Path (Join-Path $Root 'go.mod'))) {
    [void]$commands.Add([pscustomobject]@{
      name = 'go-test'
      command = 'go test ./...'
      source = 'go.mod'
    })
  }
  if ($commands.Count -eq 0 -and
    (@(Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue).Count -gt 0 -or
     @(Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue).Count -gt 0)) {
    [void]$commands.Add([pscustomobject]@{
      name = 'dotnet-test'
      command = 'dotnet test'
      source = 'dotnet-layout'
    })
  }
  return $commands.ToArray()
}

function Add-PlanSection {
  param(
   [Parameter(Mandatory)]$Lines,
   [Parameter(Mandatory)][string]$Title,
    [string[]]$Values = @()
 )
  [void]$Lines.Add("")
  [void]$Lines.Add("## $Title")
  if ($Values.Count -eq 0) { [void]$Lines.Add("- (none)") }
  else { foreach ($value in $Values) { [void]$Lines.Add("- $value") } }
}

function Get-PlanSummaryLines {
  param([Parameter(Mandatory)]$PlanObject)

  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add("# closeout plan")
  [void]$lines.Add("- run_id: $($PlanObject.run_id)")
  [void]$lines.Add("- repository: $($PlanObject.repo_root)")
  [void]$lines.Add("- branch: $($PlanObject.branch.initial) -> $($PlanObject.branch.target)")
  [void]$lines.Add("- default: $($PlanObject.default_branch)")
  [void]$lines.Add("- head: $($PlanObject.snapshot.head)")
  [void]$lines.Add("- confirmation: full plan applies to listed actions only")
  Add-PlanSection -Lines $lines -Title 'will execute' -Values @($PlanObject.will_execute) | Out-Null
  Add-PlanSection -Lines $lines -Title 'will not execute' -Values @($PlanObject.will_not_execute) | Out-Null
  Add-PlanSection -Lines $lines -Title 'stage include' -Values @($PlanObject.staging.include) | Out-Null
  Add-PlanSection -Lines $lines -Title 'stage exclude' -Values @($PlanObject.staging.exclude | ForEach-Object { "$($_.path) ($($_.reason))" }) | Out-Null
  Add-PlanSection -Lines $lines -Title 'temp candidates' -Values @($PlanObject.temp_cleanup.candidates | ForEach-Object {
      "$($_.relative_path) bytes=$($_.bytes) files=$($_.file_count)"
    }) | Out-Null
  Add-PlanSection -Lines $lines -Title 'blockers' -Values @($PlanObject.blockers) | Out-Null
  return $lines.ToArray()
}

function New-CloseoutPlan {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$Config,
    [string]$MessageText = '',
    [string[]]$ExplicitVerify = @(),
    [switch]$AllowNoTests
  )

  $probe = Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', '--git-dir') -AllowFailure
  if ($probe.ExitCode -ne 0) { throw "Not a git repo: $Root" }
  $mergeSpec = Get-CloseoutMergeStrategy -Value ([string]$Config.merge_strategy)
  $default = Get-DefaultBranch -RepoRoot $Root -Prefer $Config.default_branch_prefer
  $snapshot = Get-RepoSnapshot -Root $Root -DefaultBranch $default
  $prContext = $null
  $branchTarget = $snapshot.branch
  $createBranch = $false
  $records = @($snapshot.status_records)
  $hasChanges = $records.Count -gt 0
  $defaultAhead = if ($snapshot.branch -eq $default -and $null -ne $snapshot.ahead) { [int]$snapshot.ahead } else { 0 }
  $blockers = New-Object 'System.Collections.Generic.List[string]'
  if ($snapshot.detached_head) { [void]$blockers.Add('detached HEAD requires an explicit branch') }
  if ($snapshot.conflicted_count -gt 0) { [void]$blockers.Add('conflicted files present') }
  if (@($snapshot.in_progress_ops).Count -gt 0) { [void]$blockers.Add("in-progress git operation: $($snapshot.in_progress_ops -join ', ')") }

  if (($hasChanges -or $defaultAhead -gt 0) -and $snapshot.branch -eq $default -and $Config.auto_create_branch -and -not $Config.push_main_direct) {
    $candidateBranch = Get-GeneratedBranchName -Root $Root -Prefix $Config.branch_prefix
    $branchTarget = $candidateBranch
  }
  if (-not $branchTarget) { $branchTarget = $default }

  $tempScan = if ($Config.cleanup_temp) {
    Get-CloseoutTempCandidates -RepoRoot $Root -DirectoryPatterns $Config.cleanup_temp_dirs -FilePatterns $Config.cleanup_temp_files
  } else {
    [pscustomobject]@{
      candidates = @()
      rejected = @()
      patterns = [pscustomobject]@{ directories = @(); files = @() }
    }
  }
  $stage = Get-StagePlan -Root $Root -Records $records -TempScan $tempScan -MaxUntrackedMb $Config.max_untracked_file_mb -MaxStagedMb $Config.max_staged_file_mb
  foreach ($item in @($stage.blocked)) {
    [void]$blockers.Add("already-staged protected path: $($item.path)")
  }
  foreach ($item in @($tempScan.rejected)) {
    if ($item.blocking -ne $false) {
      [void]$blockers.Add("cleanup candidate rejected: $($item.path) ($($item.reason))")
    }
  }
  $stageContent = @($stage.include | ForEach-Object {
      [pscustomobject]@{
        path = [string]$_
        fingerprint = Get-CloseoutPathContentToken -Root $Root -RelativePath ([string]$_)
        git_blob = Get-CloseoutGitBlobToken -Root $Root -RelativePath ([string]$_)
      }
    })
  $stage | Add-Member -NotePropertyName 'content_fingerprints' -NotePropertyValue $stageContent -Force

  $verify = @(Get-VerifyCommands -Root $Root -Explicit $ExplicitVerify)
  $originUrl = Get-ConfiguredGitRemoteUrl -RepoRoot $Root -Remote 'origin'
  if ($branchTarget -and (Test-CommandAvailable 'gh')) {
    $prContext = Get-PrContext -Root $Root -Branch $branchTarget
    if ($branchTarget -ne $snapshot.branch) { $prContext.current = $null }
  }
  $openPrCount = if ($prContext) { @($prContext.open).Count } else { 0 }
  $aheadCount = if ($null -ne $snapshot.ahead) { [int]$snapshot.ahead } else { 0 }
  $featureHasLocalHistory = $snapshot.branch -and $snapshot.branch -ne $default -and
    $snapshot.head -and $snapshot.default_tip -and $snapshot.head -ne $snapshot.default_tip
  $deliveryRequired = ($stage.include.Count -gt 0) -or
    ($defaultAhead -gt 0) -or
    ($snapshot.branch -and $snapshot.branch -ne $default -and ($aheadCount -gt 0 -or $openPrCount -gt 0 -or $featureHasLocalHistory))
  if ($createBranch -eq $false -and $branchTarget -ne $snapshot.branch -and $stage.include.Count -gt 0) {
    $createBranch = $true
  } elseif ($branchTarget -eq $snapshot.branch) {
    $createBranch = $false
  } else {
    $branchTarget = $snapshot.branch
  }
  $directDelivery = $deliveryRequired -and $branchTarget -eq $default -and [bool]$Config.push_main_direct
  $prRequired = $deliveryRequired -and [bool]$Config.prefer_pr -and -not $directDelivery
  if (-not $Config.full_run_confirmation) {
    [void]$blockers.Add('full_run_confirmation must be true; closeout requires one approved plan for the listed lifecycle')
  }
  if ($deliveryRequired -and -not $Config.prefer_pr -and -not $directDelivery) {
    [void]$blockers.Add('prefer_pr=false is unsupported for feature delivery; enable prefer_pr or explicitly use direct delivery from the default branch')
  }
  if ($prRequired -and $Config.pr_draft_default) {
    [void]$blockers.Add('pr_draft_default=true is incompatible with immediate merge; set it to false for full closeout')
  }
  $nonTempExcluded = @($stage.exclude | Where-Object { $_.reason -ne 'safe-temp-cleanup' })
  foreach ($item in $nonTempExcluded) {
    [void]$blockers.Add("excluded path requires review: $($item.path) ($($item.reason))")
  }
  if ($deliveryRequired -and -not $originUrl) { [void]$blockers.Add('origin remote is missing') }
  if ($deliveryRequired -and $branchTarget -eq $default -and -not $Config.push_main_direct) {
    [void]$blockers.Add("refusing direct delivery from default branch: $default")
  }
  if ($prRequired -and -not (Test-CommandAvailable 'gh')) {
    [void]$blockers.Add('gh is required for the configured PR-first flow')
  }
  if ($prRequired -and $originUrl -and -not (Get-OriginGitHubRepoSlug -Root $Root)) {
    [void]$blockers.Add('origin must resolve to the target GitHub repository for PR writes; upstream fallback is disabled')
  }
  $alreadyMergedPr = $null
  if ($prRequired -and $stage.include.Count -eq 0 -and
    $branchTarget -eq $snapshot.branch -and $prContext) {
    $alreadyMergedPr = Get-LatestMergedPrForTip -Context $prContext -Branch $branchTarget -Base $default -TipSha $snapshot.head
  }
  $allowNoTestsEffective = [bool]($AllowNoTests -or $Config.allow_no_tests -or -not $deliveryRequired)
  if ($deliveryRequired -and $verify.Count -eq 0 -and -not $allowNoTestsEffective) {
    [void]$blockers.Add('no repository-specific verification command discovered; pass -AllowNoTests or configure closeout.verify.json')
  }
  $messageValue = if ($MessageText.Trim()) { $MessageText.Trim() } else { "chore: closeout $branchTarget" }
  $title = ($messageValue -split '[\r\n]')[0]
  if ($title.Length -gt 72) { $title = $title.Substring(0, 69) + '...' }
  $runId = [guid]::NewGuid().ToString('n')
  $runRoot = Get-CloseoutRunRoot -RepoRoot $Root -RunId $runId
  [string[]]$branchCleanup = if ($prRequired -and $branchTarget -and $branchTarget -ne $default) { @($branchTarget) } else { @() }
  $will = New-Object 'System.Collections.Generic.List[string]'
  if ($createBranch) { [void]$will.Add("create local branch $branchTarget") }
  [void]$will.Add('run verification commands and git diff checks')
  if ($Config.cleanup_temp) { [void]$will.Add('delete only listed safe temporary candidates after verification') }
  if ($stage.include.Count -gt 0) { [void]$will.Add("stage and commit $($stage.include.Count) selected path(s)") }
  if ($originUrl -and $deliveryRequired -and -not $alreadyMergedPr) { [void]$will.Add("push $branchTarget to origin") }
  if ($prRequired -and $alreadyMergedPr) {
    [void]$will.Add("reuse already-merged PR #$($alreadyMergedPr.number); skip PR creation and merge")
  } elseif ($prRequired) {
    [void]$will.Add('create or reuse one PR with the expected base/head')
    if ($Config.wait_for_checks) {
      [void]$will.Add("merge with --$($mergeSpec.name) only after checks are explicitly complete; block if check state is unknown or pending")
    } else {
      [void]$will.Add("attempt one --$($mergeSpec.name) merge immediately; do not wait or bypass protection")
    }
  }
  if ($branchCleanup.Count -gt 0) { [void]$will.Add("delete only merged-SHA-matched local/remote branch $branchTarget") }
  [void]$will.Add('write external checkpoint and final evidence report')
  $wont = @(
    'force-push, reset --hard, clean -fdx, or gh --admin',
    'close, reopen, or delete an open/closed-unmerged PR',
    'delete current/default/worktree-locked/never-delete/unmerged/tip-moved branches',
    'delete generic tmp, temp, build, or dist directories by default',
    'stage secrets, USER.md, raw-like data, unknown files, or oversized files',
    $(if ($Config.wait_for_checks) { 'poll remote checks beyond the configured readiness check or enable auto-merge' } else { 'wait for remote checks or enable auto-merge' })
  )

  $plan = [ordered]@{
    schema_version = 'closeout-plan/v1'
    run_id = $runId
    created_at_utc = [DateTime]::UtcNow.ToString('o')
    repo_root = $Root
    run_root = $runRoot
   default_branch = $default
    config = $Config
    has_changes = $hasChanges
    delivery_required = [bool]$deliveryRequired
    confirmation_scope = 'full-run-listed-actions'
    snapshot = $snapshot
    branch = [ordered]@{
      initial = $snapshot.branch
      target = $branchTarget
      create = $createBranch
      prefix = $Config.branch_prefix
    }
    origin = [ordered]@{
      url = Protect-RemoteUrl $originUrl
      name = 'origin'
      available = [bool]$originUrl
    }
    message = $messageValue
    pr_title = $title
    staging = $stage
    temp_cleanup = [ordered]@{
      enabled = [bool]$Config.cleanup_temp
      patterns = $tempScan.patterns
      candidates = @($tempScan.candidates)
      rejected = @($tempScan.rejected)
    }
    verification = [ordered]@{
      commands = @($verify)
      mandatory = @('git diff --check', 'git diff --cached --check')
      allow_no_tests = $allowNoTestsEffective
    }
     pr = [ordered]@{
       prefer = [bool]$Config.prefer_pr
       required = [bool]$prRequired
       existing = $prContext
       base = $default
       head = $branchTarget
       merge_strategy = $mergeSpec.name
       merge_flag = $mergeSpec.flag
       wait_for_checks = [bool]$Config.wait_for_checks
       already_merged = [bool]$alreadyMergedPr
       already_merged_number = if ($alreadyMergedPr) { $alreadyMergedPr.number } else { $null }
       already_merged_head_sha = if ($alreadyMergedPr) { $alreadyMergedPr.headRefOid } else { $null }
       already_merged_commit = if ($alreadyMergedPr) { $alreadyMergedPr.mergeCommit } else { $null }
       direct_delivery = [bool]$directDelivery
     }
     prune = [ordered]@{
       only_branches = $branchCleanup
       delete_local = [bool]$Config.prune_local_merged
       delete_remote = [bool]$Config.prune_remote_merged
       predicate = 'merged PR headRefOid equals current branch tip, or ancestor of default'
     }
    will_execute = $will.ToArray()
    will_not_execute = $wont
    blockers = $blockers.ToArray()
    status = if ($blockers.Count -gt 0) { 'BLOCKED' } else { 'READY' }
  }
  Write-CloseoutJsonFile -Path (Join-Path $runRoot 'plan.json') -Object $plan -Depth 24
  [IO.File]::WriteAllLines((Join-Path $runRoot 'plan.md'), (Get-PlanSummaryLines -PlanObject $plan), [Text.UTF8Encoding]::new($false))
  return [pscustomobject]$plan
}

function Assert-PlanPathExternal {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Path
  )
  $full = [IO.Path]::GetFullPath($Path)
  if (Test-CloseoutPathInside -RepoRoot $Root -Path $full) {
    throw 'Plan and state files must be outside the target repository'
  }
  return $full
}

function Get-PlanFileObject {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Path
  )
  $full = Assert-PlanPathExternal -Root $Root -Path (Get-CanonicalPath $Path)
  try {
    $planRaw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    $plan = $planRaw | ConvertFrom-Json
  } catch { throw "Invalid plan JSON: $($_)" }
  if ($plan.schema_version -ne 'closeout-plan/v1') { throw "Unsupported plan schema: $($plan.schema_version)" }
  $planRoot = [IO.Path]::GetFullPath([string]$plan.repo_root)
  $rootFull = [IO.Path]::GetFullPath($Root)
  if (-not $planRoot.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Plan repository does not match RepoRoot' }
  return [pscustomobject]@{ object = $plan; path = $full; sha256 = Get-CloseoutSha256Text -Text $planRaw }
}

function Get-StateObject {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Path
  )
  $full = Assert-PlanPathExternal -Root $Root -Path (Get-CanonicalPath $Path)
  try { $state = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "Invalid state JSON: $($_)" }
  if ($state.schema_version -ne 'closeout-state/v1') { throw "Unsupported state schema: $($state.schema_version)" }
  $planInfo = Get-PlanFileObject -Root $Root -Path ([string]$state.plan_file)
  if ($state.plan_sha256 -and $state.plan_sha256 -ne $planInfo.sha256) {
    throw "PLAN_CHANGED: plan file hash no longer matches the approved run"
  }
  return [pscustomobject]@{ object = $state; path = $full; plan = $planInfo.object; plan_path = $planInfo.path }
}

function Get-PhaseMap {
  param([Parameter(Mandatory)]$PlanObject)
  $map = [ordered]@{}
  foreach ($name in @('preflight', 'branch', 'verify', 'cleanup_temp', 'commit', 'push', 'pr', 'merge', 'sync_default', 'prune', 'final')) {
    $map[$name] = [ordered]@{ status = 'pending'; started_at_utc = $null; finished_at_utc = $null; result = $null; error = $null }
  }
  return $map
}

function Save-RunState {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Path
  )
  Write-CloseoutJsonFile -Path $Path -Object $State -Depth 24
}

function Add-RunEvent {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)]$Data
  )
  Add-CloseoutJsonLine -Path $State.events_file -Object ([ordered]@{
    time_utc = [DateTime]::UtcNow.ToString('o')
    type = $Type
    data = $Data
  })
}

function New-CloseoutBlockedException {
  param(
    [Parameter(Mandatory)][string]$ErrorCode,
    [Parameter(Mandatory)][string]$Message,
    $Result = $null
  )

  $exception = [InvalidOperationException]::new($Message)
  $exception.Data['closeout_blocked'] = $true
  $exception.Data['error_code'] = $ErrorCode
  if ($null -ne $Result) { $exception.Data['result'] = $Result }
  return $exception
}

function Get-CloseoutErrorCode {
  param([Parameter(Mandatory)]$ErrorRecord)

  $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
    $ErrorRecord.Exception
  } elseif ($ErrorRecord -is [Exception]) {
    $ErrorRecord
  } else {
    $null
  }
  if ($exception -and $exception.Data -and $exception.Data.Contains('error_code')) {
    return [string]$exception.Data['error_code']
  }
  $message = [string]$ErrorRecord
  foreach ($code in @(
      'CONFIG_INVALID', 'DEFAULT_BRANCH_UNRESOLVED', 'PLAN_CHANGED', 'STALE_PLAN', 'STALE_SCOPE',
      'WAIT_FOR_CHECKS', 'CHECKS_FAILED', 'VERIFY_FAILED', 'CLEANUP_BLOCKED',
      'PRUNE_FAILED', 'PR_GUARD', 'INVALID_ARGUMENTS'
    )) {
    if ($message -match [regex]::Escape($code)) { return $code }
  }
  if ($message -match '(?i)verification failed|diff --check failed') { return 'VERIFY_FAILED' }
  if ($message -match '(?i)temporary cleanup|cleanup') { return 'CLEANUP_BLOCKED' }
  if ($message -match '(?i)branch prune') { return 'PRUNE_FAILED' }
  if ($message -match '(?i)PR |PR$|PR\b|merge') { return 'PR_GUARD' }
  return 'CLOSEOUT_FAILED'
}

function Invoke-RunGit {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )
  $result = Invoke-Git -RepoRoot $State.repo_root -Arguments $Arguments -AllowFailure
  Add-RunEvent -State $State -Type 'git' -Data ([ordered]@{
    args = @($Arguments)
    exit_code = $result.ExitCode
    output = Protect-CloseoutText $result.Output
  })
  if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $($result.ExitCode)$( [Environment]::NewLine )$(Protect-CloseoutText $result.Output)"
  }
  return $result
}

function Invoke-RunGh {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )
  $result = Invoke-OriginGitHub -Root $State.repo_root -Arguments $Arguments -AllowFailure
  Add-RunEvent -State $State -Type 'gh' -Data ([ordered]@{
    args = @($Arguments)
    exit_code = $result.ExitCode
    output = Protect-CloseoutText $result.Output
    stderr = Protect-CloseoutText $result.StdErr
  })
  if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "gh $($Arguments -join ' ') failed with exit code $($result.ExitCode)$( [Environment]::NewLine )$(Protect-CloseoutText $result.Output)$( [Environment]::NewLine )$(Protect-CloseoutText $result.StdErr)"
  }
  return $result
}

function Convert-CommandForLog {
  param([string]$Command)
  if (-not $Command) { return '' }
  return ($Command -replace '(?i)(token|password|secret|authorization)\s*=\s*\S+', '$1=***')
}

function Invoke-RunVerify {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Command
  )
  $result = Invoke-CloseoutShellCommand -Command $Command -WorkingDirectory $State.repo_root -AllowFailure
  [pscustomobject]$safeResult = [pscustomobject]@{
    command = Convert-CommandForLog $Command
    exit_code = $result.exit_code
    stdout = Protect-CloseoutText $result.stdout
    stderr = Protect-CloseoutText $result.stderr
  }
  Add-RunEvent -State $State -Type 'verify' -Data $safeResult
  return $safeResult
}

function Set-PhaseRunning {
  param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
  $phase = $State.phases.$Name
  $phase.status = 'running'
  $phase.started_at_utc = [DateTime]::UtcNow.ToString('o')
  $phase.error = $null
  $State.status = 'RUNNING'
  $State.failed_phase = $null
  $State.failure = $null
  $State.error_code = $null
  Save-RunState -State $State -Path $State.state_file
}

function Complete-Phase {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Name,
    $Result = $null,
    [string]$Status = 'completed'
  )
  $phase = $State.phases.$Name
  $phase.status = $Status
  $phase.finished_at_utc = [DateTime]::UtcNow.ToString('o')
  $phase.result = $Result
  Save-RunState -State $State -Path $State.state_file
  Add-RunEvent -State $State -Type 'phase-complete' -Data @{ phase = $Name; status = $Status }
}

function Fail-Phase {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ErrorText
  )
  $phase = $State.phases.$Name
  $phase.status = 'failed'
  $phase.finished_at_utc = [DateTime]::UtcNow.ToString('o')
  $phase.error = $ErrorText
  $State.status = 'FAILED'
  $State.failed_phase = $Name
  $State.failure = $ErrorText
  $State.error_code = Get-CloseoutErrorCode -ErrorRecord $ErrorText
  Save-RunState -State $State -Path $State.state_file
  Add-RunEvent -State $State -Type 'phase-failed' -Data @{ phase = $Name; error = $ErrorText }
}

function Test-PhaseDone {
  param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
  return ($State.phases.$Name.status -eq 'completed')
}

function Invoke-PlanBoundTempCleanup {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$PlanObject,
    [switch]$Apply
  )

  if (-not $PlanObject.temp_cleanup.enabled) {
    return [pscustomobject]@{
      dry_run = (-not $Apply)
      applied = [bool]$Apply
      status = 'DISABLED'
      blocking = $false
      candidates = @()
      rejected = @()
      blocking_rejected = @()
      plan_unlisted = @()
      deleted = @()
      failed = @()
      delete_failures = @()
    }
  }

  $patterns = $PlanObject.temp_cleanup.patterns
  $scan = Get-CloseoutTempCandidates -RepoRoot $Root -DirectoryPatterns @($patterns.directories) -FilePatterns @($patterns.files)
  $planned = @($PlanObject.temp_cleanup.candidates)
  $plannedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($item in $planned) {
    if ($item.relative_path) { [void]$plannedPaths.Add([string]$item.relative_path) }
  }

  $unlisted = @($scan.candidates | Where-Object { -not $plannedPaths.Contains([string]$_.relative_path) })
  $unlistedEvidence = @($unlisted | ForEach-Object {
      [pscustomobject]@{
        path = [string]$_.relative_path
        relative_path = [string]$_.relative_path
        reason = 'not-listed-in-approved-plan'
        action = 'hold'
        blocking = $true
        fingerprint = $_.fingerprint
      }
    })
  $rejected = @($scan.rejected)
  $blockingRejected = @($rejected | Where-Object { $_.blocking -ne $false })
  $rejectedEvidence = @($blockingRejected | ForEach-Object {
      [pscustomobject]@{
        path = [string]$_.path
        relative_path = [string]$_.path
        reason = [string]$_.reason
        detail = $_.detail
        action = 'hold'
        blocking = $true
      }
    })
  $blocked = @($unlistedEvidence + $rejectedEvidence)

  # Deliberately omit -AllowNewSafeCandidates: one confirmation covers only
  # the frozen candidate list above.
  $result = Invoke-CloseoutTempCleanup -RepoRoot $Root -Apply:$Apply -PlannedCandidates $planned -DirectoryPatterns @($patterns.directories) -FilePatterns @($patterns.files)
  $resultFailed = @($result.failed)
  $status = if ($resultFailed.Count -gt 0 -or $blocked.Count -gt 0) { 'BLOCKED' } else { 'READY' }
  [pscustomobject]@{
    dry_run = (-not $Apply)
    applied = [bool]$Apply
    status = $status
    blocking = ($status -eq 'BLOCKED')
    candidates = @($result.candidates)
    rejected = @($rejected)
    blocking_rejected = @($blockingRejected)
    plan_unlisted = @($unlistedEvidence)
    blocked = @($blocked)
    deleted = @($result.deleted)
    failed = @($resultFailed + $blocked)
    delete_failures = @($resultFailed)
  }
}

function Invoke-CloseoutPhase {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )
  if (Test-PhaseDone -State $State -Name $Name) { return $State.phases.$Name.result }
  Set-PhaseRunning -State $State -Name $Name
  try {
    $result = & $Body
    Complete-Phase -State $State -Name $Name -Result $result
    return $result
  } catch {
    $errorText = "$($_)"
    $isBlocked = $false
    try { $isBlocked = [bool]$_.Exception.Data['closeout_blocked'] } catch { $isBlocked = $false }
    if ($isBlocked) {
      $phase = $State.phases.$Name
      $phase.status = 'blocked'
      $phase.finished_at_utc = [DateTime]::UtcNow.ToString('o')
      $phase.error = $errorText
      if ($_.Exception.Data.Contains('result')) { $phase.result = $_.Exception.Data['result'] }
      $State.status = 'BLOCKED'
      $State.failed_phase = $Name
      $State.failure = $errorText
      $State.error_code = if ($_.Exception.Data.Contains('error_code')) {
        [string]$_.Exception.Data['error_code']
      } else { 'CLOSEOUT_BLOCKED' }
      Save-RunState -State $State -Path $State.state_file
      Add-RunEvent -State $State -Type 'phase-blocked' -Data @{
        phase = $Name
        error = $errorText
        error_code = $State.error_code
      }
    } else {
      Fail-Phase -State $State -Name $Name -ErrorText $errorText
    }
    throw
  }
}

function Assert-PlanFresh {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$PlanObject
  )
  $current = Get-RepoSnapshot -Root $Root -DefaultBranch $PlanObject.default_branch
  $old = $PlanObject.snapshot
  $mismatches = New-Object 'System.Collections.Generic.List[string]'
  if ($current.head -ne $old.head) { [void]$mismatches.Add("HEAD changed: $($old.head) -> $($current.head)") }
  if ($current.branch -ne $old.branch) { [void]$mismatches.Add("branch changed: $($old.branch) -> $($current.branch)") }
  if ($current.status_fingerprint -ne $old.status_fingerprint) { [void]$mismatches.Add('working-tree status changed') }
  if ($current.content_fingerprint -ne $old.content_fingerprint) { [void]$mismatches.Add('working-tree content changed') }
  if ($old.default_tip -and $current.default_tip -and $current.default_tip -ne $old.default_tip) {
    [void]$mismatches.Add('default branch tip changed')
  }
  if ($mismatches.Count -gt 0) { throw "STALE_PLAN: $($mismatches -join '; ')" }
  return $current
}

function Get-CloseoutPathContentToken {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$RelativePath
  )

  $full = Join-Path $Root ($RelativePath -replace '/', '\')
  $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  if (-not $item) { return 'missing' }
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    return "reparse|$RelativePath"
  }
  if ($item.PSIsContainer) {
    $signature = Get-CloseoutItemSignature -RepoRoot $Root -RelativePath $RelativePath
    return if ($signature) { [string]$signature.fingerprint } else { 'missing' }
  }
  try { return (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() } catch {
    return "unreadable|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
  }
}

function Get-CloseoutGitBlobToken {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$RelativePath
  )

  $result = Invoke-Git -RepoRoot $Root -Arguments @('hash-object', '--', $RelativePath) -AllowFailure
  if ($result.ExitCode -ne 0) { return '' }
  return $result.Output.Trim()
}

function Test-CloseoutRelativePathUnder {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$RootPath
  )

  $normalizedPath = $Path.Replace('\', '/')
  $normalizedRoot = $RootPath.Replace('\', '/').TrimEnd('/')
  return $normalizedPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $normalizedPath.StartsWith("$normalizedRoot/", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CloseoutOriginUnchanged {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$PlanObject
  )

  if (-not $PlanObject.origin.available) { return }
  $currentOrigin = Get-ConfiguredGitRemoteUrl -RepoRoot $Root -Remote 'origin'
  if (-not $currentOrigin) { throw 'STALE_SCOPE: origin disappeared since plan' }
  $expectedOrigin = [string]$PlanObject.origin.url
  if ($expectedOrigin -and
    -not (Protect-RemoteUrl $currentOrigin).Equals($expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
    throw "STALE_SCOPE: origin remote changed since plan: expected=$expectedOrigin current=$(Protect-RemoteUrl $currentOrigin)"
  }
  if ($PlanObject.pr.required -and -not (Get-OriginGitHubRepoSlug -Root $Root)) {
    throw 'PR_GUARD: origin no longer resolves to a GitHub repository; refusing PR write on another remote'
  }
}

function Assert-ResumeInputScope {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$PlanObject
  )

  # Once commit is checkpointed, later phases own the repository state. Final
  # verification still rejects any dirty or unplanned changes.
  if (Test-PhaseDone -State $State -Name 'commit') { return }

  $currentBranch = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current') -AllowFailure).Output.Trim()
  $allowedBranches = @([string]$PlanObject.branch.initial)
  if ($PlanObject.branch.create) { $allowedBranches += [string]$PlanObject.branch.target }
  if ($currentBranch -notin $allowedBranches) {
    throw "STALE_SCOPE: resume branch changed unexpectedly: $currentBranch"
  }

  $initialHead = [string]$PlanObject.snapshot.head
  $currentHead = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD') -AllowFailure).Output.Trim()
  if (-not $initialHead -or -not $currentHead) { throw 'STALE_SCOPE: cannot resolve resume HEAD' }

  $stagePaths = @($PlanObject.staging.include | ForEach-Object { [string]$_ })
  $stageFingerprints = @{}
  $stageBlobs = @{}
  foreach ($item in @($PlanObject.staging.content_fingerprints)) {
    if ($item.path) {
      $stageFingerprints[[string]$item.path] = [string]$item.fingerprint
      $stageBlobs[[string]$item.path] = [string]$item.git_blob
    }
  }
  $tempCandidates = @($PlanObject.temp_cleanup.candidates)
  $cleanupDone = Test-PhaseDone -State $State -Name 'cleanup_temp'
  $currentRecords = @(Get-RepoStatusRecords -Root $Root)
  $currentByPath = @{}
  foreach ($record in $currentRecords) { $currentByPath[[string]$record.path] = $record }

  foreach ($record in $currentRecords) {
    $path = [string]$record.path
    if ($path -in $stagePaths) { continue }
    $underPlannedTemp = $false
    foreach ($candidate in $tempCandidates) {
      if (Test-CloseoutRelativePathUnder -Path $path -RootPath ([string]$candidate.relative_path)) {
        $underPlannedTemp = $true
        break
      }
    }
    if ($underPlannedTemp -and -not $cleanupDone) { continue }
    throw "STALE_SCOPE: unplanned or post-cleanup working-tree path appeared during resume: $path"
  }

  if ($currentHead -ne $initialHead) {
    $history = Invoke-Git -RepoRoot $Root -Arguments @('diff', '--name-only', "$initialHead..$currentHead") -AllowFailure
    if ($history.ExitCode -ne 0) { throw 'STALE_SCOPE: resume HEAD moved in an uninspectable way' }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $stagePaths) { [void]$allowed.Add($path) }
    foreach ($name in @($history.Lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().Replace('\', '/') })) {
      if (-not $allowed.Contains($name)) { throw "STALE_SCOPE: resume HEAD contains an unplanned committed path: $name" }
    }
  }

  $fallbackContentMismatch = $false
  foreach ($path in $stagePaths) {
    $current = $currentByPath[$path]
    if (-not $current) {
      if ($currentHead -eq $initialHead) {
        throw "STALE_SCOPE: planned staged path changed or disappeared during resume: $path"
      }
      # A path may be absent because a partially completed commit already
      # recorded it. The history allowlist above prevents unrelated commits.
      if ($stageBlobs.ContainsKey($path) -and $stageBlobs[$path]) {
        $committedRef = '{0}:{1}' -f $currentHead, $path
        $committed = Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', $committedRef) -AllowFailure
        if ($committed.ExitCode -ne 0 -or $committed.Output.Trim() -ne $stageBlobs[$path]) {
          throw "STALE_SCOPE: committed planned path content changed during resume: $path"
        }
      }
      continue
    }
    if ($stageFingerprints.ContainsKey($path)) {
      $currentToken = Get-CloseoutPathContentToken -Root $Root -RelativePath $path
      if ($currentToken -ne $stageFingerprints[$path]) {
        throw "STALE_SCOPE: planned file content changed during resume: $path"
      }
    } else {
      $fallbackContentMismatch = $true
    }
  }
  if ($fallbackContentMismatch) {
    $planCurrent = Get-RepoSnapshot -Root $Root -DefaultBranch $PlanObject.default_branch
    if ($planCurrent.content_fingerprint -ne $PlanObject.snapshot.content_fingerprint) {
      throw 'STALE_SCOPE: planned working-tree content changed during resume'
    }
  }

  if (-not $cleanupDone) {
    foreach ($candidate in $tempCandidates) {
      $path = [string]$candidate.relative_path
      $current = Get-CloseoutItemSignature -RepoRoot $Root -RelativePath $path
      if ($current -and $candidate.fingerprint -and $current.fingerprint -ne $candidate.fingerprint) {
        throw "STALE_SCOPE: planned cleanup candidate changed during resume: $path"
      }
    }
  }
}

function Assert-ScopedWorkingTree {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$PlanObject
  )
  $current = @(Get-RepoStatusRecords -Root $Root)
  $allowed = @($PlanObject.staging.include)
  foreach ($item in @($PlanObject.staging.content_fingerprints)) {
    if (-not $item.path -or -not $item.fingerprint) { continue }
    $currentToken = Get-CloseoutPathContentToken -Root $Root -RelativePath ([string]$item.path)
    if ($currentToken -ne [string]$item.fingerprint) {
      throw "STALE_SCOPE: planned file content changed during verification or resume: $($item.path)"
    }
  }
  $tempPaths = @($PlanObject.temp_cleanup.candidates | ForEach-Object { $_.relative_path })
  foreach ($record in $current) {
    $path = [string]$record.path
    if ($path -in $allowed) { continue }
    $underTemp = $false
    foreach ($temp in $tempPaths) {
      if ($path.Equals($temp, [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith("$temp/", [StringComparison]::OrdinalIgnoreCase)) {
        $underTemp = $true
        break
      }
    }
    if ($underTemp) { continue }
    if ($record.untracked -and (Test-SensitivePath -Path $path)) {
      throw "STALE_SCOPE: sensitive untracked path appeared: $path"
    }
    throw "STALE_SCOPE: unplanned working-tree path appeared: $path"
  }
}

function Get-CommitBodyText {
  param(
    [Parameter(Mandatory)]$PlanObject,
    [Parameter(Mandatory)]$State
  )
  $lines = @(
    $PlanObject.message
    ''
    'Closeout evidence:'
    "- repository: $($PlanObject.repo_root)"
    "- branch: $($PlanObject.branch.target)"
    "- verification: $(@($PlanObject.verification.commands | ForEach-Object { $_.name }) -join ', ')"
    "- verification policy: git diff checks always run; no-test override=$($PlanObject.verification.allow_no_tests)"
    "- temp cleanup candidates: $(@($PlanObject.temp_cleanup.candidates).Count)"
    ''
    'The full command evidence is stored in the external closeout run report.'
  )
  return ($lines -join ([Environment]::NewLine))
}

function Get-ExternalReportLines {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$PlanObject,
    [string]$Conclusion = ''
  )

  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add('# Closeout result')
  [void]$lines.Add("")
  [void]$lines.Add("## Initial state")
  [void]$lines.Add("- repository: $($PlanObject.repo_root)")
  [void]$lines.Add("- initial branch: $($PlanObject.snapshot.branch)")
  [void]$lines.Add("- initial HEAD: $($PlanObject.snapshot.head)")
  [void]$lines.Add("- initial status: staged=$($PlanObject.snapshot.staged_count) unstaged=$($PlanObject.snapshot.unstaged_count) untracked=$($PlanObject.snapshot.untracked_count) conflicted=$($PlanObject.snapshot.conflicted_count)")
  [void]$lines.Add("- in-progress operations: $(if (@($PlanObject.snapshot.in_progress_ops).Count) { $PlanObject.snapshot.in_progress_ops -join ', ' } else { '(none)' })")
  [void]$lines.Add("")
  [void]$lines.Add("## Execution plan")
  [void]$lines.Add("- confirmation scope: $($PlanObject.confirmation_scope)")
  [void]$lines.Add("- plan file: $($State.plan_file)")
  [void]$lines.Add("- state file: $($State.state_file)")
  [void]$lines.Add("- will execute: $($PlanObject.will_execute -join '; ')")
  [void]$lines.Add("- will not execute: $($PlanObject.will_not_execute -join '; ')")
  [void]$lines.Add("")
  [void]$lines.Add("## Phase results")
  foreach ($name in @('preflight', 'branch', 'verify', 'cleanup_temp', 'commit', 'push', 'pr', 'merge', 'sync_default', 'prune', 'final')) {
    $phase = $State.phases.$name
    [void]$lines.Add("- $($name): $($phase.status)$(if ($phase.error) { " - $($phase.error)" } else { '' })")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Verification")
  $verifyPhase = $State.phases.verify.result
  if ($verifyPhase) {
    foreach ($item in @($verifyPhase)) {
      [void]$lines.Add("- $($item.command): exit=$($item.exit_code)")
    }
  } else {
    [void]$lines.Add("- not completed")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Commit")
  $commitPhase = $State.phases.commit.result
  if ($commitPhase) {
    [void]$lines.Add("- action: $($commitPhase.action)")
    [void]$lines.Add("- files: $(@($commitPhase.files).Count)")
    [void]$lines.Add("- pre_HEAD -> post_HEAD: $($commitPhase.pre_head) -> $($commitPhase.post_head)")
  } else {
    [void]$lines.Add("- not completed")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Push and PR")
  $pushPhase = $State.phases.push.result
  if ($pushPhase) {
    [void]$lines.Add("- push: $($pushPhase.branch) local=$($pushPhase.local_sha) remote=$($pushPhase.remote_sha) synchronized=$($pushPhase.synchronized)")
  } else {
    [void]$lines.Add("- push: not completed")
  }
  $prPhase = $State.phases.pr.result
  if ($prPhase) {
    [void]$lines.Add("- PR: action=$($prPhase.action) number=$($prPhase.number) url=$($prPhase.url) head=$($prPhase.head_sha)")
  } else {
    [void]$lines.Add("- PR: not completed")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Merge")
  [void]$lines.Add("- configured strategy: $($PlanObject.pr.merge_strategy) wait_for_checks=$($PlanObject.pr.wait_for_checks)")
  $mergePhase = $State.phases.merge.result
  if ($mergePhase) {
    [void]$lines.Add("- action: $($mergePhase.action) number=$($mergePhase.number)")
    [void]$lines.Add("- merge commit: $($mergePhase.merge_commit.oid)")
  } else {
    [void]$lines.Add("- not completed")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Cleanup")
  $cleanupPhase = $State.phases.cleanup_temp.result
  if ($cleanupPhase) {
    [void]$lines.Add("- deleted temporary paths: $(@($cleanupPhase.deleted).Count)")
    foreach ($item in @($cleanupPhase.deleted)) { [void]$lines.Add("  - $($item.relative_path)") }
    [void]$lines.Add("- cleanup failures: $(@($cleanupPhase.failed).Count)")
    [void]$lines.Add("- cleanup rejected/HOLD: $(@($cleanupPhase.blocked).Count)")
    foreach ($item in @($cleanupPhase.blocked)) {
      [void]$lines.Add("  - $($item.path) reason=$($item.reason) action=$($item.action)")
    }
  } else {
    [void]$lines.Add("- temporary cleanup: not completed")
  }
  $finalPhase = $State.phases.final.result
  if ($finalPhase -and $finalPhase.final_cleanup) {
    $finalCleanup = $finalPhase.final_cleanup
    [void]$lines.Add("- final cleanup deleted: $(@($finalCleanup.deleted).Count)")
    [void]$lines.Add("- final cleanup rejected/HOLD: $(@($finalCleanup.blocked).Count)")
    foreach ($item in @($finalCleanup.blocked)) {
      [void]$lines.Add("  - $($item.path) reason=$($item.reason) action=$($item.action)")
    }
  }
  $prunePhase = $State.phases.prune.result
  if ($prunePhase) {
    [void]$lines.Add("- branch prune exit: $($prunePhase.exit_code)")
    [void]$lines.Add("- branch prune output: $($prunePhase.summary)")
  } else {
    [void]$lines.Add("- branch prune: not completed")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Final state")
  if ($State.final_snapshot) {
    [void]$lines.Add("- branch: $($State.final_snapshot.branch)")
    [void]$lines.Add("- HEAD: $($State.final_snapshot.head)")
    [void]$lines.Add("- ahead/behind: $($State.final_snapshot.ahead)/$($State.final_snapshot.behind)")
    [void]$lines.Add("- dirty files: $($State.final_snapshot.status_records.Count)")
    [void]$lines.Add("- in-progress operations: $(if (@($State.final_snapshot.in_progress_ops).Count) { $State.final_snapshot.in_progress_ops -join ', ' } else { '(none)' })")
  } else {
    [void]$lines.Add("- final snapshot: unavailable")
  }
  [void]$lines.Add("- conclusion: $Conclusion")
  return $lines.ToArray()
}

function Write-RunReport {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$PlanObject,
    [string]$Conclusion = ''
  )
  $reportPath = Join-Path $State.run_root 'report.md'
  [IO.File]::WriteAllLines($reportPath, (Get-ExternalReportLines -State $State -PlanObject $PlanObject -Conclusion $Conclusion), [Text.UTF8Encoding]::new($false))
  $State.report_file = $reportPath
  Save-RunState -State $State -Path $State.state_file
  return $reportPath
}

function New-RunState {
  param(
    [Parameter(Mandatory)]$PlanObject,
    [Parameter(Mandatory)][string]$PlanPath
  )
  $runRoot = [string]$PlanObject.run_root
  $statePath = Join-Path $runRoot 'state.json'
  $state = [ordered]@{
    schema_version = 'closeout-state/v1'
    run_id = $PlanObject.run_id
    repo_root = $PlanObject.repo_root
    run_root = $runRoot
    plan_file = $PlanPath
    plan_sha256 = (Get-PlanFileObject -Root $PlanObject.repo_root -Path $PlanPath).sha256
    state_file = $statePath
    events_file = (Join-Path $runRoot 'events.jsonl')
    report_file = (Join-Path $runRoot 'report.md')
    status = 'RUNNING'
    failed_phase = $null
    failure = $null
    error_code = $null
    phases = Get-PhaseMap -PlanObject $PlanObject
    final_snapshot = $null
  }
  Save-RunState -State $state -Path $statePath
  return [pscustomobject]$state
}

function Invoke-CloseoutRun {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$PlanObject
  )

  $Root = [string]$PlanObject.repo_root
  $Config = [pscustomobject]$PlanObject.config

  Assert-CloseoutOriginUnchanged -Root $Root -PlanObject $PlanObject
  Assert-ResumeInputScope -Root $Root -State $State -PlanObject $PlanObject

  $null = Invoke-CloseoutPhase -State $State -Name 'preflight' -Body {
    $probe = Invoke-RunGit -State $State -Arguments @('rev-parse', '--git-dir') -AllowFailure
    if ($probe.ExitCode -ne 0) { throw "Not a git repo: $Root" }
    $snapshot = Get-RepoSnapshot -Root $Root -DefaultBranch $PlanObject.default_branch
    if (@($snapshot.in_progress_ops).Count -gt 0) { throw "in-progress git operation: $($snapshot.in_progress_ops -join ', ')" }
    if ($snapshot.conflicted_count -gt 0) { throw 'conflicted files present' }
    if (-not $snapshot.branch) { throw 'detached HEAD requires explicit branch' }
    if ($PlanObject.pr.required -and -not (Test-CommandAvailable -Name 'gh')) {
      throw 'gh disappeared since plan; PR-first delivery cannot continue'
    }
    if ($PlanObject.pr.required -and -not (Get-OriginGitHubRepoSlug -Root $Root)) {
      throw 'origin no longer resolves to a GitHub repository; refusing PR write on another remote'
    }
    if ($PlanObject.origin.available) {
      $currentOrigin = Get-ConfiguredGitRemoteUrl -RepoRoot $Root -Remote 'origin'
      if (-not $currentOrigin) { throw 'origin disappeared since plan' }
      $expectedOrigin = [string]$PlanObject.origin.url
      if ($expectedOrigin -and
        -not (Protect-RemoteUrl $currentOrigin).Equals($expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
        throw "origin remote changed since plan: expected=$expectedOrigin current=$(Protect-RemoteUrl $currentOrigin)"
      }
    }
    $snapshot
  }

  $null = Invoke-CloseoutPhase -State $State -Name 'branch' -Body {
    $target = [string]$PlanObject.branch.target
    if (-not $PlanObject.branch.create) {
      if ($target -and $target -ne $PlanObject.default_branch -and $target -ne (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()) {
        throw "current branch does not match planned target: $target"
      }
      return [pscustomobject]@{ action = 'reuse'; branch = $target }
    }
    $current = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
    if ($current -eq $target) { return [pscustomobject]@{ action = 'already-created'; branch = $target } }
    $existing = Get-BranchTipSha -RepoRoot $Root -Ref $target
    if ($existing) {
      throw "planned branch already exists at unexpected tip: $target ($existing)"
    }
    $created = Invoke-RunGit -State $State -Arguments @('switch', '-c', $target)
    $after = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
    if ($after -ne $target) { throw "branch creation recheck failed: $after" }
    [pscustomobject]@{ action = 'created'; branch = $target; output = $created.Output }
  }

  $null = Invoke-CloseoutPhase -State $State -Name 'verify' -Body {
    $results = New-Object 'System.Collections.Generic.List[object]'
    $mandatory = @(
      [pscustomobject]@{ name = 'git diff --check'; args = @('diff', '--check') }
      [pscustomobject]@{ name = 'git diff --cached --check'; args = @('diff', '--cached', '--check') }
    )
    foreach ($item in $mandatory) {
      $result = Invoke-RunGit -State $State -Arguments $item.args -AllowFailure
      $entry = [pscustomobject]@{
        command = $item.name
        exit_code = $result.ExitCode
        stdout = $result.Output
        stderr = ''
      }
      [void]$results.Add($entry)
      if ($result.ExitCode -ne 0) { throw "$($item.name) failed with exit code $($result.ExitCode): $($result.Output)" }
    }
    foreach ($command in @($PlanObject.verification.commands)) {
      $result = Invoke-RunVerify -State $State -Command ([string]$command.command)
      [void]$results.Add($result)
      if ($result.exit_code -ne 0) {
        throw "verification failed: $($command.name) exit $($result.exit_code)"
      }
    }
    if (@($PlanObject.verification.commands).Count -eq 0 -and -not $PlanObject.verification.allow_no_tests) {
      throw 'no repository-specific verification command; no-test override was not enabled'
    }
    $results.ToArray()
  }

  $cleanupResult = Invoke-CloseoutPhase -State $State -Name 'cleanup_temp' -Body {
    if (-not $PlanObject.temp_cleanup.enabled) {
      return [pscustomobject]@{
        dry_run = $false
        candidates = @()
        deleted = @()
        failed = @()
        delete_failures = @()
        rejected = @()
        blocked = @()
        plan_unlisted = @()
        skipped = 'disabled'
      }
    }
    $result = Invoke-PlanBoundTempCleanup -Root $Root -PlanObject $PlanObject -Apply
    if (@($result.delete_failures).Count -gt 0) {
      throw "temporary cleanup failed for $(@($result.delete_failures).Count) path(s)"
    }
    if (@($result.blocked).Count -gt 0) {
      $paths = @($result.blocked | ForEach-Object { "$($_.path) ($($_.reason))" }) -join ', '
      throw (New-CloseoutBlockedException -ErrorCode 'CLEANUP_BLOCKED' -Message "CLEANUP_BLOCKED: cleanup candidate is not covered by the approved plan: $paths" -Result $result)
    }
    $result
  }

  $commitResult = Invoke-CloseoutPhase -State $State -Name 'commit' -Body {
    Assert-ScopedWorkingTree -Root $Root -PlanObject $PlanObject
    $include = @($PlanObject.staging.include)
    if ($include.Count -gt 0) {
      $args = @('add', '--')
      $args += $include
      $null = Invoke-RunGit -State $State -Arguments $args
    }
    $cachedResult = Invoke-RunGit -State $State -Arguments @('diff', '--cached', '--name-only')
    $cachedNames = @($cachedResult.Lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().Replace('\', '/') })
    $allowed = @($include)
    foreach ($name in $cachedNames) {
      if ($name -notin $allowed) { throw "staged path is outside plan: $name" }
    }
    $check = Invoke-RunGit -State $State -Arguments @('diff', '--cached', '--check') -AllowFailure
    if ($check.ExitCode -ne 0) { throw "cached diff check failed: $($check.Output)" }
    if ($cachedNames.Count -eq 0) {
      $head = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD')).Output.Trim()
      return [pscustomobject]@{ action = 'skipped-no-staged-changes'; pre_head = $head; post_head = $head; files = @() }
    }
    $pre = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD')).Output.Trim()
    $commit = Invoke-RunGit -State $State -Arguments @('commit', '-m', [string]$PlanObject.message)
    $post = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD')).Output.Trim()
    if (-not $post -or $post -eq $pre) { throw 'commit recheck did not advance HEAD' }
    [pscustomobject]@{ action = 'committed'; pre_head = $pre; post_head = $post; files = $cachedNames; output = $commit.Output }
  }

  $pushResult = Invoke-CloseoutPhase -State $State -Name 'push' -Body {
    if (-not $PlanObject.delivery_required) { return [pscustomobject]@{ action = 'skipped-no-delivery' } }
    if (-not $PlanObject.origin.available) { throw 'origin is required for full closeout' }
    $branch = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
    if ($branch -eq $PlanObject.default_branch -and -not $Config.push_main_direct) {
      throw "refusing direct push to default branch: $branch"
    }
    if ($PlanObject.pr.already_merged -and $commitResult.action -eq 'skipped-no-staged-changes') {
      $local = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD')).Output.Trim()
      $remote = Get-BranchTipSha -RepoRoot $Root -Ref "origin/$branch"
      [pscustomobject]@{
        action = 'skipped-already-merged'
        branch = $branch
        local_sha = $local
        remote_sha = $remote
        synchronized = [bool]($remote -and $remote -eq $local)
      }
      return
    }
    $push = Invoke-RunGit -State $State -Arguments @('push', '-u', 'origin', 'HEAD')
    $local = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', 'HEAD')).Output.Trim()
    $remote = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', '@{upstream}')).Output.Trim()
    if (-not $local -or $local -ne $remote) { throw "push SHA mismatch local=$local upstream=$remote" }
    [pscustomobject]@{ branch = $branch; local_sha = $local; remote_sha = $remote; synchronized = $true; output = $push.Output }
  }

  $prResult = Invoke-CloseoutPhase -State $State -Name 'pr' -Body {
    if (-not $PlanObject.delivery_required -or -not $PlanObject.pr.required) { return [pscustomobject]@{ action = 'skipped-no-delivery' } }
    $branch = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
    $context = Get-PrContext -Root $Root -Branch $branch
    if ($context.error) { throw $context.error }
    $matchingMerged = Get-LatestMergedPrForTip -Context $context -Branch $branch -Base $PlanObject.default_branch -TipSha $pushResult.local_sha
    if ($PlanObject.pr.already_merged) {
      if (-not $matchingMerged) {
        throw 'planned already-merged PR no longer matches the pushed branch tip; refusing duplicate PR creation'
      }
      return [pscustomobject]@{
        action = 'already-merged'
        number = $matchingMerged.number
        url = $matchingMerged.url
        head_sha = $matchingMerged.headRefOid
        base = $matchingMerged.baseRefName
        head = $matchingMerged.headRefName
        merge_commit = $matchingMerged.mergeCommit
      }
    }
    if ($matchingMerged) {
      return [pscustomobject]@{
        action = 'already-merged'
        number = $matchingMerged.number
        url = $matchingMerged.url
        head_sha = $matchingMerged.headRefOid
        base = $matchingMerged.baseRefName
        head = $matchingMerged.headRefName
        merge_commit = $matchingMerged.mergeCommit
      }
    }
    $pr = $context.current
    if (-not $pr -and @($context.open).Count -gt 0) { $pr = @($context.open)[0] }
    if ($pr -and $pr.state -eq 'OPEN') {
      if ($pr.baseRefName -ne $PlanObject.default_branch) { throw "open PR base mismatch: $($pr.baseRefName)" }
      if ($pr.headRefName -ne $branch) { throw "open PR head mismatch: $($pr.headRefName)" }
      if ($pr.headRefOid -ne $pushResult.local_sha) { throw "open PR head SHA mismatch: $($pr.headRefOid) vs $($pushResult.local_sha)" }
      if ($pr.isDraft) { throw "open PR is draft: #$($pr.number)" }
      return [pscustomobject]@{ action = 'reused'; number = $pr.number; url = $pr.url; head_sha = $pr.headRefOid; base = $pr.baseRefName; head = $pr.headRefName }
    }
    $closedUnmerged = @($context.closed | Where-Object { $_.state -eq 'CLOSED' })
    if ($closedUnmerged.Count -gt 0) {
      throw "closed unmerged PR exists for $branch; refusing to reopen or duplicate"
    }
    $bodyPath = Join-Path $State.run_root 'pr-body.md'
    [IO.File]::WriteAllText($bodyPath, (Get-CommitBodyText -PlanObject $PlanObject -State $State), [Text.UTF8Encoding]::new($false))
    $title = [string]$PlanObject.pr_title
    $created = Invoke-RunGh -State $State -Arguments @(
      'pr', 'create', '--base', $PlanObject.default_branch, '--head', $branch,
      '--title', $title, '--body-file', $bodyPath
    )
    $createdUrl = ($created.Output -split '[\r\n]' | Where-Object { $_ -match '^https?://' } | Select-Object -First 1)
    $pr = Get-PrView -Root $Root
    if (-not $pr -and $createdUrl) { $pr = [pscustomobject]@{ url = $createdUrl; number = $null; state = 'OPEN'; baseRefName = $PlanObject.default_branch; headRefName = $branch; headRefOid = $pushResult.local_sha; isDraft = $false } }
    if (-not $pr) { throw 'PR create succeeded but PR recheck returned no object' }
    if ($pr.state -ne 'OPEN' -or $pr.baseRefName -ne $PlanObject.default_branch -or $pr.headRefOid -ne $pushResult.local_sha) {
      throw 'created PR failed base/head/state recheck'
    }
    [pscustomobject]@{ action = 'created'; number = $pr.number; url = $pr.url; head_sha = $pr.headRefOid; base = $pr.baseRefName; head = $pr.headRefName }
  }

  $mergeResult = Invoke-CloseoutPhase -State $State -Name 'merge' -Body {
    if (-not $PlanObject.delivery_required -or -not $PlanObject.pr.required) { return [pscustomobject]@{ action = 'skipped-no-delivery' } }
    if ($prResult.action -eq 'already-merged') {
      return [pscustomobject]@{
        action = 'already-merged'
        number = $prResult.number
        merge_commit = $prResult.merge_commit
      }
    }
    $mergeSpec = Get-CloseoutMergeStrategy -Value ([string]$PlanObject.pr.merge_strategy)
    $number = $prResult.number
    if (-not $number) { throw 'PR number unavailable for merge' }
    $pr = Get-PrView -Root $Root
    if (-not $pr) { throw 'PR disappeared before merge' }
    if ($pr.state -eq 'MERGED') {
      return [pscustomobject]@{ action = 'already-merged'; number = $number; merge_commit = $pr.mergeCommit }
    }
    if ($pr.state -ne 'OPEN') { throw "PR is not open before merge: $($pr.state)" }
    if ($pr.isDraft) { throw 'draft PR cannot be merged automatically' }
    if ($pr.baseRefName -ne $PlanObject.default_branch -or $pr.headRefName -ne $pushResult.branch) { throw 'PR base/head changed before merge' }
    if ($pr.headRefOid -ne $pushResult.local_sha) { throw "PR head changed before merge: $($pr.headRefOid)" }
    if ($pr.mergeable -eq 'CONFLICTING' -or $pr.mergeStateStatus -in @('DIRTY', 'BLOCKED') -or $pr.reviewDecision -eq 'CHANGES_REQUESTED') {
      throw "PR is not immediately mergeable: mergeable=$($pr.mergeable) mergeState=$($pr.mergeStateStatus) review=$($pr.reviewDecision)"
    }
    if ($PlanObject.pr.wait_for_checks) {
      $checkReadiness = Get-CloseoutCheckReadiness -Pr $pr
      if ($checkReadiness.state -eq 'failed') {
        throw "CHECKS_FAILED: required checks are not green: $($checkReadiness.detail)"
      }
      if ($checkReadiness.state -ne 'ready') {
        $blockedResult = [pscustomobject]@{
          action = 'blocked-wait-for-checks'
          number = $number
          merge_strategy = $mergeSpec.name
          head_sha = $pushResult.local_sha
          check_state = $checkReadiness.state
          check_detail = $checkReadiness.detail
          checks = $checkReadiness.checks
        }
        throw (New-CloseoutBlockedException -ErrorCode 'WAIT_FOR_CHECKS' -Message "WAIT_FOR_CHECKS: checks are $($checkReadiness.state) ($($checkReadiness.detail)); rerun -Resume after checks are complete" -Result $blockedResult)
      }
    }
    $merge = Invoke-RunGh -State $State -Arguments @(
      'pr', 'merge', "$number", $mergeSpec.flag, '--match-head-commit', $pushResult.local_sha
    )
    $after = Get-PrView -Root $Root
    if (-not $after -or $after.state -ne 'MERGED') {
      throw 'merge command returned but PR is not confirmed MERGED; no cleanup performed'
    }
    [pscustomobject]@{ action = 'merged'; number = $number; merge_strategy = $mergeSpec.name; merge_commit = $after.mergeCommit; output = $merge.Output }
  }

  $syncResult = Invoke-CloseoutPhase -State $State -Name 'sync_default' -Body {
    if (-not $PlanObject.delivery_required -or -not $PlanObject.pr.required -or -not $mergeResult -or $mergeResult.action -eq 'disabled' -or $mergeResult.action -eq 'skipped-no-delivery') {
      return [pscustomobject]@{ action = if ($PlanObject.delivery_required -and $PlanObject.pr.direct_delivery) { 'skipped-direct-delivery' } else { 'skipped-no-delivery' } }
    }
    $fetch = Invoke-RunGit -State $State -Arguments @('fetch', '--prune', 'origin')
    $current = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
    $switchOutput = ''
    if ($current -ne $PlanObject.default_branch) {
      $switch = Invoke-RunGit -State $State -Arguments @('switch', $PlanObject.default_branch)
      $switchOutput = $switch.Output
    }
    $pull = Invoke-RunGit -State $State -Arguments @('pull', '--ff-only', 'origin', $PlanObject.default_branch)
    $tip = (Invoke-Git -RepoRoot $Root -Arguments @('rev-parse', $PlanObject.default_branch)).Output.Trim()
    if (-not $tip) { throw 'default branch tip unavailable after merge' }
    $mergeOid = $mergeResult.merge_commit.oid
    if ($mergeOid -and -not (Test-IsAncestor -RepoRoot $Root -PossibleAncestor $mergeOid -Descendant $tip)) {
      throw "merged PR commit $mergeOid is not an ancestor of $($PlanObject.default_branch)"
    }
    [pscustomobject]@{ action = 'synced-default'; branch = $PlanObject.default_branch; tip = $tip; fetch = $fetch.Output; switch = $switchOutput; pull = $pull.Output }
  }

  $pruneResult = Invoke-CloseoutPhase -State $State -Name 'prune' -Body {
    $pruneTargets = @($PlanObject.prune.only_branches | Where-Object { $_ -and ([string]$_).Trim() })
    if ($pruneTargets.Count -eq 0) { return [pscustomobject]@{ action = 'none'; exit_code = 0; summary = 'no feature branch target' } }
    $deleteLocal = [bool]$PlanObject.prune.delete_local
    $deleteRemote = [bool]$PlanObject.prune.delete_remote
    if (-not $deleteLocal -and -not $deleteRemote) {
      return [pscustomobject]@{ action = 'disabled-by-config'; exit_code = 0; summary = 'local and remote pruning disabled' }
    }

    # Bind the PR evidence used by prune_merged.ps1 to origin. This keeps a
    # fork/upstream remote from changing the classification during Resume.
    $mergedPrPath = Join-Path $State.run_root 'merged-prs.json'
    $targetContext = Get-PrContext -Root $Root -Branch ([string]$PlanObject.branch.target)
    $mergedPrs = if ($targetContext) { @($targetContext.merged) } else { @() }
    Write-CloseoutJsonFile -Path $mergedPrPath -Object $mergedPrs -Depth 12

    # prune_merged.ps1 cannot apply remote-only pruning without also applying
    # local pruning. Keep the configured local branch when that option is off
    # and repeat its merge-proof predicate for the plan-listed remote branch.
    if (-not $deleteLocal -and $deleteRemote) {
      $target = [string]$pruneTargets[0]
      if ($target -eq $PlanObject.default_branch -or $target -in @($PlanObject.config.never_delete_branches)) {
        throw "PRUNE_FAILED: protected branch cannot be pruned: $target"
      }
      $current = (Invoke-Git -RepoRoot $Root -Arguments @('branch', '--show-current')).Output.Trim()
      if ($current -eq $target) { throw "PRUNE_FAILED: refusing to delete current branch remote: $target" }
      $remoteTip = Get-BranchTipSha -RepoRoot $Root -Ref "origin/$target"
      if (-not $remoteTip) {
        return [pscustomobject]@{ action = 'already-clean'; exit_code = 0; summary = 'remote branch already absent'; remote = $target }
      }
      $liveRemote = Get-LiveRemoteBranchTip -RepoRoot $Root -Remote 'origin' -Name $target
      if ($liveRemote.status -eq 'error') {
        throw "PRUNE_FAILED: live remote tip query failed for ${target}: $(Protect-CloseoutText $liveRemote.output)"
      }
      if ($liveRemote.status -eq 'absent') {
        return [pscustomobject]@{ action = 'already-clean'; exit_code = 0; summary = 'remote branch disappeared before delete'; remote = $target }
      }
      if ($liveRemote.sha -ne $remoteTip) {
        throw "PRUNE_FAILED: remote branch tip moved before delete: ${target} ($remoteTip -> $($liveRemote.sha))"
      }
      $defaultTip = Get-BranchTipSha -RepoRoot $Root -Ref $PlanObject.default_branch
      $safe = $defaultTip -and (Test-IsAncestor -RepoRoot $Root -PossibleAncestor $remoteTip -Descendant $defaultTip)
      $matched = Get-LatestMergedPrForTip -Context $targetContext -Branch $target -Base $PlanObject.default_branch -TipSha $remoteTip
      if (-not $safe -and $matched) { $safe = $true }
      if (-not $safe) {
        throw "PRUNE_FAILED: remote branch is not proven merged at its current tip: $target ($remoteTip)"
      }
      $delete = Invoke-RunGit -State $State -Arguments @('push', 'origin', '--delete', $target) -AllowFailure
      if ($delete.ExitCode -ne 0) { throw "PRUNE_FAILED: remote delete failed for $target (exit $($delete.ExitCode)): $(Protect-CloseoutText $delete.Output)" }
      $null = Invoke-RunGit -State $State -Arguments @('fetch', '--prune', 'origin') -AllowFailure
      if (Get-BranchTipSha -RepoRoot $Root -Ref "origin/$target") {
        throw "PRUNE_FAILED: remote branch still exists after deletion: $target"
      }
      return [pscustomobject]@{
        action = 'pruned-remote-only'
        exit_code = 0
        summary = 'remote pruned; local retained by config'
        deleted_remote = @($target)
        remote_tip = $remoteTip
        merged_pr = if ($matched) { $matched.number } else { $null }
      }
    }

    $args = @(
      '-NoProfile', '-File', (Join-Path $here 'prune_merged.ps1'),
      '-RepoRoot', $Root, '-DefaultBranch', $PlanObject.default_branch,
      '-NeverDelete'
    )
    $args += @($PlanObject.config.never_delete_branches)
    $args += @('-MergedPrJson', $mergedPrPath)
    $args += @('-OnlyBranches')
    $args += $pruneTargets
    $args += @('-Apply')
    if ($deleteRemote) { $args += '-DeleteRemote' }
    $args += '-Json'
    $raw = & pwsh @args 2>&1 | Out-String
    $code = $LASTEXITCODE
    Add-RunEvent -State $State -Type 'prune' -Data @{ args = $args; exit_code = $code; output = $raw }
    try {
      $json = $raw | ConvertFrom-Json
      if ($code -ne 0) { throw "branch prune exited $code" }
      if ($deleteLocal -and @($json.failed_local).Count -gt 0) { throw 'branch prune reported local deletion failures' }
      if ($deleteRemote -and @($json.failed_remote).Count -gt 0) { throw 'branch prune reported remote deletion failures' }
      $deleted = if ($deleteLocal) { @($json.deleted_local).Count } else { 0 }
      if ($deleteRemote) { $deleted += @($json.deleted_remote).Count }
      if ($deleted -eq 0) {
        $localStill = Get-BranchTipSha -RepoRoot $Root -Ref $PlanObject.branch.target
        $remoteStill = Get-BranchTipSha -RepoRoot $Root -Ref "origin/$($PlanObject.branch.target)"
        if (($deleteLocal -and $localStill) -or ($deleteRemote -and $remoteStill)) {
          throw 'configured merged branch remains after prune without a deletion result'
        }
        $summary = 'already-clean'
      } else {
        $summary = 'pruned'
      }
      [pscustomobject]@{ action = 'pruned'; exit_code = $code; summary = $summary; json = $json }
    } catch {
      throw "branch prune failed: $($_) args=$($args -join '|') output=$(Protect-CloseoutText $raw)"
    }
  }

  $null = Invoke-CloseoutPhase -State $State -Name 'final' -Body {
    $finalCleanup = if ($PlanObject.temp_cleanup.enabled) {
      Invoke-PlanBoundTempCleanup -Root $Root -PlanObject $PlanObject -Apply
    } else {
      [pscustomobject]@{ failed = @(); delete_failures = @(); blocked = @(); candidates = @(); deleted = @() }
    }
    if (@($finalCleanup.delete_failures).Count -gt 0) { throw 'final temporary cleanup left failures' }
    if (@($finalCleanup.blocked).Count -gt 0) {
      $paths = @($finalCleanup.blocked | ForEach-Object { "$($_.path) ($($_.reason))" }) -join ', '
      throw (New-CloseoutBlockedException -ErrorCode 'CLEANUP_BLOCKED' -Message "CLEANUP_BLOCKED: final cleanup found plan-unlisted or rejected candidates: $paths" -Result ([pscustomobject]@{ final_cleanup = $finalCleanup }))
    }
    $finalSnapshot = Get-RepoSnapshot -Root $Root -DefaultBranch $PlanObject.default_branch
    $State.final_snapshot = $finalSnapshot
    $expectedFinalBranch = if ($PlanObject.delivery_required) { $PlanObject.default_branch } else { $PlanObject.snapshot.branch }
    if ($finalSnapshot.branch -ne $expectedFinalBranch) { throw "final branch is not expected target: $($finalSnapshot.branch) expected=$expectedFinalBranch" }
    if ($finalSnapshot.staged_count -ne 0 -or $finalSnapshot.unstaged_count -ne 0 -or $finalSnapshot.untracked_count -ne 0 -or $finalSnapshot.conflicted_count -ne 0) {
      throw 'final working tree is not clean'
    }
    if (@($finalSnapshot.in_progress_ops).Count -gt 0) { throw 'final state has in-progress git operation' }
    if ($finalSnapshot.upstream -and ($finalSnapshot.ahead -ne 0 -or $finalSnapshot.behind -ne 0)) {
      throw "final default branch is not synchronized: ahead=$($finalSnapshot.ahead) behind=$($finalSnapshot.behind)"
    }
    [pscustomobject]@{ final_cleanup = $finalCleanup; final_snapshot = $finalSnapshot }
  }

  $State.status = 'COMPLETED'
  $State.failed_phase = $null
  $State.failure = $null
  $State.error_code = $null
  Save-RunState -State $State -Path $State.state_file
  $report = Write-RunReport -State $State -PlanObject $PlanObject -Conclusion 'clean desk: YES'
  [pscustomobject]@{ status = $State.status; report = $report; state = $State.state_file; run_root = $State.run_root }
}

try {
  $modeCount = 0
  if ($Plan) { $modeCount++ }
  if ($Apply) { $modeCount++ }
  if ($Resume) { $modeCount++ }
  if ($modeCount -gt 1) { throw 'INVALID_ARGUMENTS: choose only one of -Plan, -Apply, or -Resume' }
  $RepoRoot = Get-CanonicalPath -Path $RepoRoot
  $skillRoot = Split-Path -Parent $here
  $config = Get-CloseoutUserConfig -SkillRoot $skillRoot -UserConfigPath $UserConfigPath
  if (-not $Plan -and -not $Apply -and -not $Resume) { $Plan = $true }

  if ($Plan) {
    $planObject = New-CloseoutPlan -Root $RepoRoot -Config $config -MessageText $Message -ExplicitVerify $VerifyCommand -AllowNoTests:$AllowNoTests
    if ($Json) {
      $planObject | ConvertTo-Json -Depth 24
    } else {
      Get-PlanSummaryLines -PlanObject $planObject
      Write-Output ""
      Write-Output "plan_file: $(Join-Path $planObject.run_root 'plan.json')"
      Write-Output "plan_status: $($planObject.status)"
    }
    if ($planObject.status -eq 'BLOCKED') { exit 3 }
    exit 0
  }

  if ($Apply) {
    if (-not $PlanFile) { throw '-Apply requires -PlanFile' }
    $planInfo = Get-PlanFileObject -Root $RepoRoot -Path $PlanFile
    $planObject = $planInfo.object
    if ($planObject.status -eq 'BLOCKED') { throw 'Cannot apply a BLOCKED plan; create a new plan after resolving blockers' }
    $null = Assert-PlanFresh -Root $RepoRoot -PlanObject $planObject
    $state = New-RunState -PlanObject $planObject -PlanPath $planInfo.path
    $StateFile = $state.state_file
    $result = Invoke-CloseoutRun -State $state -PlanObject $planObject
    if ($Json) { $result | ConvertTo-Json -Depth 24 } else {
      Write-Output "status: $($result.status)"
      Write-Output "report: $($result.report)"
      Write-Output "state: $($result.state)"
    }
    if ($result.status -eq 'BLOCKED') { exit 3 }
    exit 0
  }

  if ($Resume) {
    if (-not $StateFile) { throw '-Resume requires -StateFile' }
    $stateInfo = Get-StateObject -Root $RepoRoot -Path $StateFile
    $state = $stateInfo.object
    $planObject = $stateInfo.plan
    if ($state.status -eq 'COMPLETED') {
      if ($Json) { [pscustomobject]@{ status = $state.status; error_code = $null; failed_phase = $null; report = $state.report_file; state = $state.state_file; run_root = $state.run_root } | ConvertTo-Json -Depth 24 }
      else { Write-Output "status: COMPLETED"; Write-Output "report: $($state.report_file)" }
      exit 0
    }
    $result = Invoke-CloseoutRun -State $state -PlanObject $planObject
    if ($Json) { $result | ConvertTo-Json -Depth 24 } else {
      Write-Output "status: $($result.status)"
      Write-Output "report: $($result.report)"
      Write-Output "state: $($result.state)"
    }
    if ($result.status -eq 'BLOCKED') { exit 3 }
    exit 0
  }
} catch {
  $messageText = "$($_)"
  $errorCode = Get-CloseoutErrorCode -ErrorRecord $_
  $blockedException = $false
  try { $blockedException = [bool]$_.Exception.Data['closeout_blocked'] } catch { $blockedException = $false }
  $failedPhase = if ($Resume) { 'resume' } elseif ($Apply) { 'apply' } else { 'plan' }
  $staleGuard = $errorCode -in @('PLAN_CHANGED', 'STALE_PLAN', 'STALE_SCOPE')
  $status = if ($blockedException -or $staleGuard) { 'BLOCKED' } else { 'FAILED' }
  $statePathOut = $null
  $reportPathOut = $null
  $runRootOut = $null
  $stateLoaded = $null
  $planLoaded = $null

  if ($state -and $state.state_file) {
    $statePathOut = [string]$state.state_file
    $runRootOut = [string]$state.run_root
    try { $stateLoaded = $state; $planLoaded = $planObject } catch {}
  } elseif ($StateFile) {
    try {
      $statePathCandidate = [IO.Path]::GetFullPath($StateFile)
      if (Test-Path -LiteralPath $statePathCandidate) {
        $statePathOut = $statePathCandidate
        $rawState = Get-Content -LiteralPath $statePathCandidate -Raw -Encoding UTF8 | ConvertFrom-Json
        $runRootOut = [string]$rawState.run_root
        if ($rawState.report_file) { $reportPathOut = [string]$rawState.report_file }
        try {
          $stateInfo = Get-StateObject -Root $RepoRoot -Path $statePathCandidate
          $stateLoaded = $stateInfo.object
          $planLoaded = $stateInfo.plan
        } catch {}
      }
    } catch {}
  }

  if ($stateLoaded -and $planLoaded) {
    try {
      $stateStatus = if ($blockedException -or $staleGuard -or $stateLoaded.status -eq 'BLOCKED') { 'BLOCKED' } else { 'FAILED' }
      $stateLoaded.status = $stateStatus
      $stateLoaded.failure = $messageText
      $stateLoaded.error_code = $errorCode
      if (-not $stateLoaded.failed_phase) { $stateLoaded.failed_phase = $failedPhase }
      $failedPhase = [string]$stateLoaded.failed_phase
      $status = $stateStatus
      Save-RunState -State $stateLoaded -Path $stateLoaded.state_file
      $reportPathOut = Write-RunReport -State $stateLoaded -PlanObject $planLoaded -Conclusion "clean desk: NO; $messageText"
      $statePathOut = [string]$stateLoaded.state_file
      $runRootOut = [string]$stateLoaded.run_root
    } catch {}
  }

  if ($Json) {
    [ordered]@{
      status = $status
      error_code = $errorCode
      failed_phase = $failedPhase
      error = $messageText
      state = $statePathOut
      report = $reportPathOut
      run_root = $runRootOut
    } | ConvertTo-Json -Depth 24
  } else {
    Write-Output "ERROR: $messageText"
    Write-Output "ERROR_CODE: $errorCode"
    Write-Output "FAILED_PHASE: $failedPhase"
    if ($statePathOut) { Write-Output "state: $statePathOut" }
    if ($reportPathOut) { Write-Output "report: $reportPathOut" }
    Write-Output "ERROR_TYPE: $($_.Exception.GetType().FullName)"
    Write-Output "ERROR_STACK: $($_.ScriptStackTrace)"
  }
  if ($status -eq 'BLOCKED') { exit 3 }
  exit 1
}
