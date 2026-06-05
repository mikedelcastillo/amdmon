<#
  install.ps1 - Register the `amdmon` command in your PowerShell profile.

  Adds a function to your $PROFILE that runs amdmon.ps1 (in this folder) by path,
  so you can type `amdmon` from any directory. Because it points at the live file,
  edits to amdmon.ps1 take effect immediately - no re-install needed unless the
  repo moves. Re-running this script just updates/repairs the entry (idempotent).

  It also pre-downloads the hardware-monitoring libraries (LibreHardwareMonitor)
  so the first `amdmon` run doesn't have to. (CPU/GPU/RAM/VRAM/temperatures use
  these libs; network down/up throughput uses built-in Windows performance
  counters and needs nothing extra downloaded.)

  Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
#>

$ErrorActionPreference = 'Stop'

# Live script path, resolved from this installer's own location so it works
# regardless of where the repo is cloned.
$target = Join-Path $PSScriptRoot 'amdmon.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Error "Cannot find amdmon.ps1 next to this installer (looked for: $target)."
    return
}
$target = (Resolve-Path -LiteralPath $target).Path

# Pre-fetch the monitoring libraries (best effort; amdmon downloads them on
# demand too, so a failure here is not fatal).
try {
    & $target -EnsureDeps
} catch {
    Write-Host "Note: could not pre-download libraries now ($($_.Exception.Message)); amdmon will retry on first run." -ForegroundColor Yellow
}

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
