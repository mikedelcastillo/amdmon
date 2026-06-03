<#
  install.ps1 - Register the `amdmon` command in your PowerShell profile.

  Adds a function to your $PROFILE that runs gpumon.ps1 (in this folder) by path,
  so you can type `amdmon` from any directory. Because it points at the live file,
  edits to gpumon.ps1 take effect immediately - no re-install needed unless the
  repo moves. Re-running this script just updates/repairs the entry (idempotent).

  Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
#>

$ErrorActionPreference = 'Stop'

# Live script path, resolved from this installer's own location so it works
# regardless of where the repo is cloned.
$target = Join-Path $PSScriptRoot 'gpumon.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Error "Cannot find gpumon.ps1 next to this installer (looked for: $target)."
    return
}
$target = (Resolve-Path -LiteralPath $target).Path

# The function line we manage. A leading marker comment isn't needed - we match
# on `function amdmon` so we can find/replace our own entry.
$funcLine = "function amdmon { & `"$target`" @args }"

# Ensure the profile file (and its directory) exist without clobbering existing content.
$profilePath = $PROFILE
$profileDir  = Split-Path -Parent $profilePath
if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $profilePath)) {
    New-Item -ItemType File -Path $profilePath | Out-Null
}

# Idempotent install: replace an existing `amdmon` definition, else append.
$lines = @(Get-Content -LiteralPath $profilePath)
$replaced = $false
$newLines = foreach ($line in $lines) {
    if ($line -match '^\s*function\s+amdmon\b') {
        $replaced = $true
        $funcLine
    } else {
        $line
    }
}
if (-not $replaced) {
    $newLines = @($newLines) + $funcLine
}

Set-Content -LiteralPath $profilePath -Value $newLines -Encoding UTF8

if ($replaced) {
    Write-Host "Updated 'amdmon' in your profile -> $target" -ForegroundColor Green
} else {
    Write-Host "Installed 'amdmon' -> $target" -ForegroundColor Green
}
Write-Host "Profile: $profilePath" -ForegroundColor DarkGray
Write-Host "Run '. `$PROFILE' (or open a new PowerShell window), then try: amdmon -Once" -ForegroundColor Cyan
