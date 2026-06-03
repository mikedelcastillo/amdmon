<#
  uninstall.ps1 - Remove the `amdmon` command from your PowerShell profile.

  Strips the `function amdmon` line that install.ps1 added to your $PROFILE.
  Leaves the profile file (and any unrelated content) in place. Idempotent:
  running it when nothing is installed simply reports that. Does not touch
  gpumon.ps1 or anything else.

  Usage:  powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>

$ErrorActionPreference = 'Stop'

$profilePath = $PROFILE
if (-not (Test-Path -LiteralPath $profilePath)) {
    Write-Host "No profile found at $profilePath - nothing to remove." -ForegroundColor DarkGray
    return
}

$lines = @(Get-Content -LiteralPath $profilePath)
$kept  = @($lines | Where-Object { $_ -notmatch '^\s*function\s+amdmon\b' })
$removed = $lines.Count - $kept.Count

if ($removed -le 0) {
    Write-Host "'amdmon' is not installed in $profilePath - nothing to remove." -ForegroundColor DarkGray
    return
}

# Trim a single trailing blank line left behind, for tidiness.
while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[-1])) {
    $kept = $kept[0..($kept.Count - 2)]
}

Set-Content -LiteralPath $profilePath -Value $kept -Encoding UTF8

Write-Host "Removed 'amdmon' from your profile." -ForegroundColor Green
Write-Host "Profile: $profilePath" -ForegroundColor DarkGray
Write-Host "The command stays active in this session until you run '. `$PROFILE' or open a new shell." -ForegroundColor Cyan
