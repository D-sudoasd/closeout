<#
.SYNOPSIS
  Install or upgrade closeout skill into ~/.grok/skills/closeout.
  Preserves existing USER.md. Backs up previous install before replace.
#>
param(
  [string]$Source = '',
  [string]$Destination = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Source) {
  # When run from unpacked pack root or from skill root
  if (Test-Path (Join-Path $PSScriptRoot 'closeout\SKILL.md')) {
    $Source = Join-Path $PSScriptRoot 'closeout'
  } elseif (Test-Path (Join-Path $PSScriptRoot 'SKILL.md')) {
    $Source = $PSScriptRoot
  } else {
    throw "Cannot locate skill source. Pass -Source path to the closeout folder."
  }
}

$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not (Test-Path (Join-Path $Source 'SKILL.md'))) {
  throw "Source missing SKILL.md: $Source"
}

if (-not $Destination) {
  $Destination = Join-Path $env:USERPROFILE '.grok\skills\closeout'
}

function Get-NormalizedFullPath {
  param([Parameter(Mandatory)][string]$Path)
  return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/').ToLowerInvariant()
}

$srcN = Get-NormalizedFullPath -Path $Source
$dstN = Get-NormalizedFullPath -Path $Destination
if ($srcN -eq $dstN) {
  throw "Source and Destination are the same path ($Source). Refusing to move the only copy of the tree. Use git pull in the live install, or pass a different -Source (unpacked pack) than -Destination."
}
$sep = [IO.Path]::DirectorySeparatorChar
if ($srcN.StartsWith($dstN + $sep) -or $srcN.StartsWith($dstN + '/')) {
  throw "Source is inside Destination; refusing to install over a parent of the source tree."
}

$required = @(
  'SKILL.md',
  'scripts\status.ps1',
  'scripts\prune_merged.ps1',
  'scripts\cleanup_temp.ps1',
  'scripts\closeout.ps1',
  'scripts\common.ps1'
)
foreach ($rel in $required) {
  if (-not (Test-Path (Join-Path $Source $rel))) {
    throw "Source incomplete, missing: $rel"
  }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$Destination.backup-$stamp"
$staging = "$Destination.staging-$stamp"

Write-Host "Source:      $Source"
Write-Host "Destination: $Destination"

# Preserve USER.md from existing install
$userBackup = $null
if (Test-Path (Join-Path $Destination 'USER.md')) {
  $userBackup = Join-Path $env:TEMP "closeout-USER-$stamp.md"
  Copy-Item -LiteralPath (Join-Path $Destination 'USER.md') -Destination $userBackup -Force
  Write-Host "Preserved USER.md -> $userBackup"
}

if (Test-Path $Destination) {
  if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
  Move-Item -LiteralPath $Destination -Destination $backup
  Write-Host "Backed up previous install -> $backup"
}

try {
  if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
  Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force

  # Restore user config into staging
  if ($userBackup -and (Test-Path $userBackup)) {
    Copy-Item -LiteralPath $userBackup -Destination (Join-Path $staging 'USER.md') -Force
    Write-Host "Restored USER.md into new install"
  } elseif (-not (Test-Path (Join-Path $staging 'USER.md'))) {
    $example = Join-Path $staging 'USER.example.md'
    if (Test-Path $example) {
      Copy-Item -LiteralPath $example -Destination (Join-Path $staging 'USER.md') -Force
      Write-Host "Seeded USER.md from USER.example.md"
    }
  }

  Move-Item -LiteralPath $staging -Destination $Destination
  Write-Host "Installed to: $Destination"

  # Self-check
  $selfCheck = Join-Path $Destination 'scripts\self_check.ps1'
  if (Test-Path $selfCheck) {
    & pwsh -NoProfile -File $selfCheck -SkillRoot $Destination
    if ($LASTEXITCODE -ne 0) { throw "self_check failed after install" }
  }

  Write-Host "OK. Restart Grok session if skill was already loaded."
  exit 0
} catch {
  Write-Host "INSTALL FAILED: $_"
  if (Test-Path $Destination) {
    Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $staging) {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $backup) {
    Move-Item -LiteralPath $backup -Destination $Destination -Force
    Write-Host "Restored backup to $Destination"
  }
  exit 1
}
