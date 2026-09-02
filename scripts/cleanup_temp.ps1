<#
.SYNOPSIS
  List or delete safe, regenerable temporary files inside a repository.

  Default is a dry-run. Only exact configured cache/build metadata names are
  considered. The scanner never follows reparse points, deletes tracked paths,
  or leaves the repository root.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$UserConfigPath = '',
  [string[]]$DirectoryPattern = @(),
  [string[]]$FilePattern = @(),
  [string[]]$Path = @(),
  [switch]$Apply,
  [switch]$WhatIf,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$probe = Invoke-Git -RepoRoot $RepoRoot -Arguments @('rev-parse', '--git-dir') -AllowFailure
if ($probe.ExitCode -ne 0) { throw "Not a git repo: $RepoRoot" }

$skillRoot = Split-Path -Parent $here
$userCfg = Get-CloseoutUserConfig -SkillRoot $skillRoot -UserConfigPath $UserConfigPath
if ($DirectoryPattern.Count -eq 0) { $DirectoryPattern = @($userCfg.cleanup_temp_dirs) }
if ($FilePattern.Count -eq 0) { $FilePattern = @($userCfg.cleanup_temp_files) }

$dry = -not $Apply
if ($WhatIf) { $dry = $true }
$result = Invoke-CloseoutTempCleanup -RepoRoot $RepoRoot -Apply:(-not $dry) -DirectoryPatterns $DirectoryPattern -FilePatterns $FilePattern -ExplicitPaths $Path

if ($Json) {
  $result | ConvertTo-Json -Depth 12
  if (@($result.failed).Count -gt 0) { exit 1 }
  exit 0
}

Write-Output "# cleanup_temp repo=$RepoRoot dry_run=$dry"
Write-Output "- directories: $($DirectoryPattern -join ', ')"
Write-Output "- files: $($FilePattern -join ', ')"
Write-Output ""
Write-Output "## candidates"
if (@($result.candidates).Count -eq 0) {
  Write-Output "- (none)"
} else {
  foreach ($item in @($result.candidates)) {
    Write-Output ("- {0} [{1}] bytes={2} files={3} action={4}" -f $item.relative_path, $item.kind, $item.bytes, $item.file_count, $item.action)
  }
}
if (@($result.rejected).Count -gt 0) {
  Write-Output ""
  Write-Output "## rejected"
  foreach ($item in @($result.rejected)) {
    Write-Output "- $($item.path) reason=$($item.reason)"
  }
}
Write-Output ""
Write-Output "## result"
Write-Output "- deleted: $(@($result.deleted).Count)"
Write-Output "- failed: $(@($result.failed).Count)"
if ($dry) {
  Write-Output "Re-run with -Apply only after reviewing the candidate list."
}
if (@($result.failed).Count -gt 0) { exit 1 }
exit 0
