<#
.SYNOPSIS
  Read-only self-check of closeout skill install layout and script parseability.
#>
param(
  [string]$SkillRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SkillRoot) {
  $SkillRoot = Split-Path -Parent $PSScriptRoot
}
$SkillRoot = (Resolve-Path -LiteralPath $SkillRoot).Path

$required = @(
  'SKILL.md',
  'USER.example.md',
  'VERSION',
  'CHANGELOG.md',
  'references\phases.md',
  'references\clean-desk.md',
  'references\scenario-matrix.md',
  'references\auth-matrix.md',
  'references\report-template.md',
  'scripts\common.ps1',
  'scripts\status.ps1',
  'scripts\prune_merged.ps1'
)
# README is required in the public git tree; optional for minimal skill-only copies
$optionalNice = @('README.md', 'LICENSE')

$failed = @()
Write-Output "# closeout self_check"
Write-Output "- skill_root: $SkillRoot"

foreach ($rel in $required) {
  $p = Join-Path $SkillRoot $rel
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Output "MISSING: $rel"
    $failed += $rel
  } else {
    Write-Output "OK: $rel"
  }
}

# parse scripts
foreach ($script in @('common.ps1', 'status.ps1', 'prune_merged.ps1', 'self_check.ps1')) {
  $path = Join-Path $SkillRoot "scripts\$script"
  if (-not (Test-Path $path)) { continue }
  $tokens = $null
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    Write-Output "PARSE_FAIL: $script — $($errors[0].Message)"
    $failed += "parse:$script"
  } else {
    Write-Output "PARSE_OK: $script"
  }
}

# USER.md optional (user-local)
$userLocal = Join-Path $SkillRoot 'USER.md'
if (Test-Path $userLocal) {
  Write-Output "OK: USER.md (local preferences present)"
} else {
  Write-Output "INFO: USER.md absent — copy from USER.example.md on first use"
}

# VERSION readable
$verPath = Join-Path $SkillRoot 'VERSION'
if (Test-Path $verPath) {
  Write-Output ("VERSION: {0}" -f (Get-Content $verPath -Raw).Trim())
}

if ($failed.Count -gt 0) {
  Write-Output "RESULT: FAIL ($($failed.Count) issues)"
  exit 1
}
Write-Output "RESULT: PASS"
exit 0
