<#
  gpumon.ps1 - AMD/any-vendor GPU + VRAM monitor for Windows over SSH/terminal.
  Uses Windows WDDM performance counters (vendor-agnostic), so it works for the
  AMD Radeon RX 7900 XT where bottom/btop cannot read AMD GPUs on Windows.

  Usage:   pwsh -File gpumon.ps1            # refresh every 1s
           pwsh -File gpumon.ps1 -Interval 2
           pwsh -File gpumon.ps1 -Once      # single snapshot (good for scripting)
#>
param(
    [double]$Interval = 1,
    [switch]$Once
)

# Total dedicated VRAM (bytes) from the registry - Win32_VideoController.AdapterRAM
# overflows for >4GB cards, so read the 64-bit value the driver publishes instead.
function Get-TotalVram {
    $best = 0
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $v = (Get-ItemProperty $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
            if ($v -and $v -gt $best) { $best = $v }
        }
    return [int64]$best
}

$totalVram = Get-TotalVram

function Get-Snapshot {
    $engines = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
    $mem     = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue).CounterSamples
    $shared  = (Get-Counter '\GPU Adapter Memory(*)\Shared Usage' -ErrorAction SilentlyContinue).CounterSamples

    # Per-engine-type breakdown (3D, Compute, Copy, VideoDecode, ...)
    $byType = @{}
    foreach ($s in $engines) {
        if ($s.InstanceName -match 'engtype_(\w+)') {
            $t = $matches[1]
            $byType[$t] = [double]($byType[$t]) + $s.CookedValue
        }
    }
    $totalBusy = (($engines | Measure-Object -Property CookedValue -Sum).Sum) ; if (-not $totalBusy) { $totalBusy = 0 }
    $vramUsed  = (($mem      | Measure-Object -Property CookedValue -Sum).Sum) ; if (-not $vramUsed)  { $vramUsed  = 0 }
    $sharedUsed= (($shared   | Measure-Object -Property CookedValue -Sum).Sum) ; if (-not $sharedUsed){ $sharedUsed= 0 }

    [pscustomobject]@{
        Busy   = $totalBusy
        ByType = $byType
        Vram   = $vramUsed
        Shared = $sharedUsed
    }
}

function Bar([double]$pct, [int]$width = 30) {
    if ($pct -gt 100) { $pct = 100 }
    $fill = [int]([math]::Round($width * $pct / 100))
    ('#' * $fill) + ('-' * ($width - $fill))
}

function Show-Snapshot {
    $s = Get-Snapshot
    $vramPct = if ($totalVram -gt 0) { 100 * $s.Vram / $totalVram } else { 0 }

    Write-Host ("GPU Busy   [{0}] {1,5:N1}%" -f (Bar $s.Busy), $s.Busy) -ForegroundColor Cyan
    if ($totalVram -gt 0) {
        Write-Host ("VRAM Used  [{0}] {1,5:N1}%   {2:N2} / {3:N2} GB" -f (Bar $vramPct), $vramPct, ($s.Vram/1GB), ($totalVram/1GB)) -ForegroundColor Green
    } else {
        Write-Host ("VRAM Used  {0:N2} GB" -f ($s.Vram/1GB)) -ForegroundColor Green
    }
    Write-Host ("Shared Mem {0:N2} GB" -f ($s.Shared/1GB)) -ForegroundColor DarkGray
    if ($s.ByType.Count -gt 0) {
        $parts = $s.ByType.GetEnumerator() | Sort-Object Value -Descending |
                 ForEach-Object { "{0}={1:N0}%" -f $_.Key, $_.Value }
        Write-Host ("Engines    " + ($parts -join '  ')) -ForegroundColor DarkYellow
    }
}

if ($Once) {
    Show-Snapshot
    return
}

try {
    while ($true) {
        Clear-Host
        Write-Host ("AMD GPU Monitor - {0}   (Ctrl+C to quit)" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor White
        Write-Host ("-" * 60)
        Show-Snapshot
        Start-Sleep -Seconds $Interval
    }
} finally {
    Write-Host ""
}
