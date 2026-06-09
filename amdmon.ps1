<#
  amdmon.ps1 - A btop-style, full-screen system monitor for Windows terminals.

  Shows CPU / RAM / GPU / VRAM usage, CPU & GPU temperatures, and network
  down/up throughput, each with a scrolling history graph (MSI Afterburner /
  RivaTuner style). Built to work headless over SSH, where GUI tools and
  btop/bottom can't read AMD GPUs.

  Usage/temps/VRAM come from LibreHardwareMonitorLib (auto-downloaded to .\lib
  on first run; needs admin for CPU/GPU temperatures, which load a signed kernel
  driver). If the library can't be loaded, it falls back to Windows performance
  counters for usage and shows temperatures as "n/a". Network throughput comes
  from the built-in Network Interface performance counters (no extra dependency).

  Usage:   amdmon                 # full-screen dashboard, ~100ms refresh (space toggles CPU view, q quits)
           amdmon -Interval 1     # slower refresh (seconds)
           amdmon -Once           # single text snapshot (good for logging)
           amdmon -NoTemp         # skip the temperature library entirely
           amdmon -EnsureDeps     # just download the libraries and exit
#>
param(
    [double]$Interval = 0.1,
    [switch]$Once,
    [switch]$NoTemp,
    [switch]$EnsureDeps,
    [switch]$SelfTest,
    [int]$TestW = 100,
    [int]$TestH = 30
)

$ErrorActionPreference = 'Stop'
$LibDir = Join-Path $PSScriptRoot 'lib'

# ----------------------------------------------------------------------------
# Dependency management: fetch LibreHardwareMonitorLib + deps from NuGet.
# ----------------------------------------------------------------------------
# Pinned versions known to load on Windows PowerShell 5.1 (.NET Framework 4.x).
$script:LhmPackages = @(
    @{ id = 'librehardwaremonitorlib';                    ver = '0.9.6'; entry = 'runtimes/win-x64/lib/net472/LibreHardwareMonitorLib.dll'; out = 'LibreHardwareMonitorLib.dll' }
    @{ id = 'hidsharp';                                   ver = '2.6.4'; entry = 'lib/net35/HidSharp.dll';                                    out = 'HidSharp.dll' }
    @{ id = 'system.memory';                              ver = '4.5.5'; entry = 'lib/net461/System.Memory.dll';                              out = 'System.Memory.dll' }
    @{ id = 'system.buffers';                             ver = '4.5.1'; entry = 'lib/netstandard2.0/System.Buffers.dll';                     out = 'System.Buffers.dll' }
    @{ id = 'system.numerics.vectors';                    ver = '4.5.0'; entry = 'lib/netstandard2.0/System.Numerics.Vectors.dll';            out = 'System.Numerics.Vectors.dll' }
    @{ id = 'system.runtime.compilerservices.unsafe';     ver = '6.0.0'; entry = 'lib/net461/System.Runtime.CompilerServices.Unsafe.dll';    out = 'System.Runtime.CompilerServices.Unsafe.dll' }
)

function Test-LhmPresent {
    foreach ($p in $script:LhmPackages) {
        if (-not (Test-Path -LiteralPath (Join-Path $LibDir $p.out))) { return $false }
    }
    return $true
}

function Install-LhmDeps {
    if (Test-LhmPresent) { return $true }
    Write-Host "amdmon: downloading hardware-monitoring libraries to $LibDir ..." -ForegroundColor Cyan
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('amdmon_dl_' + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            foreach ($p in $script:LhmPackages) {
                $dest = Join-Path $LibDir $p.out
                if (Test-Path -LiteralPath $dest) { continue }
                $pkg = Join-Path $tmp ($p.id + '.zip')
                $url = "https://api.nuget.org/v3-flatcontainer/$($p.id)/$($p.ver)/$($p.id).$($p.ver).nupkg"
                Invoke-WebRequest -Uri $url -OutFile $pkg
                $zip = [System.IO.Compression.ZipFile]::OpenRead($pkg)
                try {
                    $e = $zip.Entries | Where-Object { $_.FullName -eq $p.entry } | Select-Object -First 1
                    if (-not $e) { throw "Entry $($p.entry) not found in $($p.id) $($p.ver)." }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                } finally { $zip.Dispose() }
                Write-Host "  + $($p.out)" -ForegroundColor DarkGray
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Host "amdmon: failed to download libraries ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "        Continuing without temperatures (usage via performance counters)." -ForegroundColor Yellow
        return $false
    } finally {
        $ProgressPreference = $prev
    }
}

if ($EnsureDeps) {
    $ok = Install-LhmDeps
    if ($ok) { Write-Host "amdmon: libraries are ready." -ForegroundColor Green }
    return
}

# ----------------------------------------------------------------------------
# Hardware data source (LibreHardwareMonitor) with graceful fallback.
# ----------------------------------------------------------------------------
$script:Computer = $null
$script:CpuHw = $null; $script:GpuHw = $null
$script:S = @{}            # named sensor references

function Initialize-Lhm {
    if ($NoTemp) { return $false }
    if (-not (Install-LhmDeps)) { return $false }
    try {
        $global:AmdmonLibDir = $LibDir
        [System.AppDomain]::CurrentDomain.add_AssemblyResolve([System.ResolveEventHandler]{
            param($sender, $e)
            $name = ($e.Name -split ',')[0].Trim()
            $path = Join-Path $global:AmdmonLibDir "$name.dll"
            if (Test-Path -LiteralPath $path) { return [System.Reflection.Assembly]::LoadFrom($path) }
            return $null
        })
        # LoadFrom (not Add-Type) so we don't eagerly enumerate every type - some
        # optional ones can't resolve and would throw ReflectionTypeLoadException.
        # The types we use load fine, and the resolver supplies deps at runtime.
        [void][System.Reflection.Assembly]::LoadFrom((Join-Path $LibDir 'LibreHardwareMonitorLib.dll'))

        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true
        $c.IsGpuEnabled = $true
        $c.Open()
        foreach ($h in $c.Hardware) { $h.Update() }

        $script:Computer = $c
        $script:CpuHw = $c.Hardware | Where-Object { "$($_.HardwareType)" -eq 'Cpu' } | Select-Object -First 1
        $script:GpuHw = $c.Hardware | Where-Object { "$($_.HardwareType)" -like 'Gpu*' } | Select-Object -First 1

        $script:S.CpuLoad  = Find-Sensor $script:CpuHw 'Load'      @('CPU Total')
        $script:S.CpuCoreLoads = Find-CpuCoreLoadSensors $script:CpuHw
        $script:S.CpuTemp  = Find-Sensor $script:CpuHw 'Temperature' @('Core (Tctl/Tdie)','CPU Package','Core (Tctl)','CPU Cores')
        $script:S.GpuLoad  = Find-Sensor $script:GpuHw 'Load'      @('GPU Core','D3D 3D')
        $script:S.GpuTemp  = Find-Sensor $script:GpuHw 'Temperature' @('GPU Core','GPU Hot Spot')
        $script:S.GpuMemU  = Find-Sensor $script:GpuHw 'SmallData' @('GPU Memory Used','D3D Dedicated Memory Used')
        $script:S.GpuMemT  = Find-Sensor $script:GpuHw 'SmallData' @('GPU Memory Total','D3D Dedicated Memory Total')
        return $true
    } catch {
        Write-Host "amdmon: LibreHardwareMonitor unavailable ($($_.Exception.Message)); using counters." -ForegroundColor Yellow
        return $false
    }
}

function Find-Sensor($hw, [string]$type, [string[]]$names) {
    if (-not $hw) { return $null }
    foreach ($n in $names) {
        $s = $hw.Sensors | Where-Object { "$($_.SensorType)" -eq $type -and $_.Name -eq $n } | Select-Object -First 1
        if ($s) { return $s }
    }
    return $hw.Sensors | Where-Object { "$($_.SensorType)" -eq $type } | Select-Object -First 1
}

function Find-CpuCoreLoadSensors($hw) {
    if (-not $hw) { return @() }
    $sensors = @($hw.Sensors | Where-Object {
        "$($_.SensorType)" -eq 'Load' -and
        $_.Name -match 'Core' -and
        $_.Name -notmatch 'Total|Package|Max|Average'
    })
    return @($sensors | Sort-Object @{
        Expression = {
            if ($_.Name -match '#?\s*(\d+)') { [int]$matches[1] } else { [int]::MaxValue }
        }
    }, Name)
}

function Get-SensorValue($s) {
    if ($s -and $s.Value -ne $null) { return [double]$s.Value }
    return $null
}

$haveLhm = Initialize-Lhm

# Total VRAM via the driver's 64-bit registry value (WMI AdapterRAM overflows >4GB).
function Get-TotalVramBytes {
    $best = 0
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $v = (Get-ItemProperty $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
            if ($v -and $v -gt $best) { $best = $v }
        }
    return [int64]$best
}

# ---- Component names (read once) -------------------------------------------
$cpuName = try { ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name).Trim() } catch { 'CPU' }
if (-not $cpuName) { $cpuName = 'CPU' }

$gpuName = $null
if ($script:GpuHw) { $gpuName = $script:GpuHw.Name }
if (-not $gpuName) {
    $gpuName = try { (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.AdapterRAM -gt 0 } | Sort-Object AdapterRAM -Descending | Select-Object -First 1).Name } catch { 'GPU' }
}
if (-not $gpuName) { $gpuName = 'GPU' }

$totalRam = 0; $ramName = 'Memory'
try {
    $totalRam = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
    $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if ($mods.Count -gt 0) {
        $spd = $mods[0].Speed
        $ddr = switch ([int]$mods[0].SMBIOSMemoryType) { 26 {'DDR4'} 34 {'DDR5'} 24 {'DDR3'} 21 {'DDR2'} default {'RAM'} }
        $ramName = "{0:N0} GB {1}-{2} ({3}x)" -f ($totalRam/1GB), $ddr, $spd, $mods.Count
    }
} catch { }
if (-not $totalRam) { $totalRam = 1 }

$totalVram = if ($haveLhm) { 0 } else { Get-TotalVramBytes }   # LHM reports its own total

# ---- Performance counters (always for RAM; for usage in fallback) ----------
$memAvail = $null
try { $memAvail = New-Object System.Diagnostics.PerformanceCounter('Memory','Available Bytes'); [void]$memAvail.NextValue() } catch { }
$cpuCtr = $null
if (-not $haveLhm) {
    try { $cpuCtr = New-Object System.Diagnostics.PerformanceCounter('Processor','% Processor Time','_Total'); [void]$cpuCtr.NextValue() } catch { }
}
$script:CpuCoreCtrs = New-Object System.Collections.Generic.List[object]
if ((-not $haveLhm) -or @($script:S.CpuCoreLoads).Count -eq 0) {
    try {
        $cpuCat = New-Object System.Diagnostics.PerformanceCounterCategory('Processor')
        $instances = @($cpuCat.GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object @{
            Expression = {
                $n = 0
                if ([int]::TryParse($_, [ref]$n)) { $n } else { [int]::MaxValue }
            }
        }, { $_ })
        foreach ($inst in $instances) {
            try {
                $ctr = New-Object System.Diagnostics.PerformanceCounter('Processor','% Processor Time',$inst)
                [void]$ctr.NextValue()
                $script:CpuCoreCtrs.Add([pscustomobject]@{ Label = "C$inst"; Counter = $ctr })
            } catch { }
        }
    } catch { }
}

# ---- Network throughput counters (bytes/sec, summed across real adapters) ----
# These rate counters come straight from the Windows perf subsystem - no extra
# library needed - and work headless over SSH. We sum the real adapters and skip
# virtual/loopback/tunnel/bridge interfaces by name, so a Hyper-V/WSL vSwitch or
# a VPN doesn't double-count the traffic already seen on the underlying NIC.
$script:NetRxCtrs = New-Object System.Collections.Generic.List[object]
$script:NetTxCtrs = New-Object System.Collections.Generic.List[object]
# Name fragments of interfaces to exclude from the throughput sum: loopback,
# tunnels, and the common virtual/bridge/VPN/capture adapters.
$NetSkip = 'Loopback|isatap|Teredo|Pseudo|Kernel Debug|QoS|Virtual|vEthernet|Hyper-V|VMware|VirtualBox|Npcap|WAN Miniport|Wi-Fi Direct|TAP-|VPN|Bluetooth|Filter|Container|WFP'
try {
    $netCat = New-Object System.Diagnostics.PerformanceCounterCategory('Network Interface')
    foreach ($inst in $netCat.GetInstanceNames()) {
        if ($inst -match $NetSkip) { continue }
        try {
            $rx = New-Object System.Diagnostics.PerformanceCounter('Network Interface','Bytes Received/sec',$inst)
            $tx = New-Object System.Diagnostics.PerformanceCounter('Network Interface','Bytes Sent/sec',$inst)
            [void]$rx.NextValue(); [void]$tx.NextValue()   # prime (first read is always 0)
            $script:NetRxCtrs.Add($rx); $script:NetTxCtrs.Add($tx)
        } catch { }
    }
} catch { }
$haveNet = ($script:NetRxCtrs.Count -gt 0)

# Friendly name for the busiest/primary up adapter (best effort). Sort on the
# numeric .Speed (bits/sec); the LinkSpeed property is a formatted string and
# would sort lexicographically (e.g. '480 Mbps' above '10 Gbps').
$netName = $null
try {
    $netName = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property Speed -Descending |
        Select-Object -First 1).InterfaceDescription
} catch { }
if (-not $netName) { $netName = 'Network' }

$cpuTempLabel = if ($script:S.CpuTemp) { $script:S.CpuTemp.Name } else { 'Temperature' }
$gpuTempLabel = if ($script:S.GpuTemp) { $script:S.GpuTemp.Name } else { 'Temperature' }

# ----------------------------------------------------------------------------
# Sampling: returns one frame of numbers.
# ----------------------------------------------------------------------------
function Get-Frame {
    $cpu = $null; $cpuT = $null; $gpu = $null; $gpuT = $null
    $cpuCores = @()
    $vramUsedB = 0.0; $vramTotalB = [double]$totalVram

    if ($haveLhm) {
        if ($script:CpuHw) { $script:CpuHw.Update() }
        if ($script:GpuHw) { $script:GpuHw.Update() }
        $cpu  = Get-SensorValue $script:S.CpuLoad
        foreach ($s in @($script:S.CpuCoreLoads)) {
            $cpuCores += [pscustomobject]@{ Label = ($s.Name -replace '^CPU\s+', ''); Value = (Get-SensorValue $s) }
        }
        $cpuT = Get-SensorValue $script:S.CpuTemp
        $gpu  = Get-SensorValue $script:S.GpuLoad
        $gpuT = Get-SensorValue $script:S.GpuTemp
        $u = Get-SensorValue $script:S.GpuMemU   # MB
        $t = Get-SensorValue $script:S.GpuMemT   # MB
        if ($u -ne $null) { $vramUsedB  = $u * 1MB }
        if ($t -ne $null) { $vramTotalB = $t * 1MB }
    } else {
        if ($cpuCtr) { $cpu = [double]$cpuCtr.NextValue() }
        try {
            $eng = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
            $gpu = ($eng | Measure-Object -Property CookedValue -Sum).Sum
            if (-not $gpu) { $gpu = 0 }
            $mem = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue).CounterSamples
            $vramUsedB = ($mem | Measure-Object -Property CookedValue -Sum).Sum
            if (-not $vramUsedB) { $vramUsedB = 0 }
        } catch { }
    }
    if ($cpuCores.Count -eq 0 -and $script:CpuCoreCtrs.Count -gt 0) {
        foreach ($entry in $script:CpuCoreCtrs) {
            $v = $null
            try { $v = [double]$entry.Counter.NextValue() } catch { }
            $cpuCores += [pscustomobject]@{ Label = $entry.Label; Value = $v }
        }
    }

    $ramUsedB = $totalRam
    if ($memAvail) { $ramUsedB = $totalRam - [double]$memAvail.NextValue() }

    # Network: sum the per-adapter rate counters (bytes/sec). null when unavailable.
    $netRx = $null; $netTx = $null
    if ($haveNet) {
        $netRx = 0.0; $netTx = 0.0
        foreach ($c in $script:NetRxCtrs) { try { $netRx += [double]$c.NextValue() } catch { } }
        foreach ($c in $script:NetTxCtrs) { try { $netTx += [double]$c.NextValue() } catch { } }
    }

    [pscustomobject]@{
        Cpu        = $cpu
        CpuT       = $cpuT
        Gpu        = $gpu
        GpuT       = $gpuT
        MemPct     = if ($totalRam -gt 0) { 100.0 * $ramUsedB / $totalRam } else { 0 }
        MemUsedGB  = $ramUsedB / 1GB
        MemTotalGB = $totalRam / 1GB
        VramPct    = if ($vramTotalB -gt 0) { 100.0 * $vramUsedB / $vramTotalB } else { 0 }
        VramUsedGB = $vramUsedB / 1GB
        VramTotalGB= $vramTotalB / 1GB
        NetDown    = $netRx          # bytes/sec, or $null
        NetUp      = $netTx          # bytes/sec, or $null
        CpuCores   = $cpuCores
    }
}

# ----------------------------------------------------------------------------
# -Once : plain text snapshot.
# ----------------------------------------------------------------------------
function Format-Pct($v) { if ($v -eq $null) { 'n/a' } else { '{0:N1}%' -f $v } }
function Format-Temp($v) { if ($v -eq $null) { 'n/a' } else { '{0:N0}' -f $v + [char]0x00B0 + 'C' } }

# Human-readable transfer rate from bytes/sec (e.g. 1.2 MB/s). $null -> n/a.
function Format-Rate($bps) {
    if ($bps -eq $null) { return 'n/a' }
    if ($bps -lt 1KB)   { return ('{0:N0} B/s'  -f $bps) }
    if ($bps -lt 1MB)   { return ('{0:N1} KB/s' -f ($bps / 1KB)) }
    if ($bps -lt 1GB)   { return ('{0:N1} MB/s' -f ($bps / 1MB)) }
    return ('{0:N2} GB/s' -f ($bps / 1GB))
}

if ($Once) {
    $f = Get-Frame
    Write-Host ("CPU   {0,-30} {1,7}   {2}" -f $cpuName, (Format-Pct $f.Cpu), (Format-Temp $f.CpuT)) -ForegroundColor Cyan
    Write-Host ("GPU   {0,-30} {1,7}   {2}" -f $gpuName, (Format-Pct $f.Gpu), (Format-Temp $f.GpuT)) -ForegroundColor Green
    Write-Host ("MEM   {0,-30} {1,7}   {2:N1} / {3:N0} GB" -f $ramName, (Format-Pct $f.MemPct), $f.MemUsedGB, $f.MemTotalGB) -ForegroundColor Yellow
    Write-Host ("VRAM  {0,-30} {1,7}   {2:N1} / {3:N0} GB" -f 'Video Memory', (Format-Pct $f.VramPct), $f.VramUsedGB, $f.VramTotalGB) -ForegroundColor Magenta
    Write-Host ("DOWN  {0,-30} {1,11}" -f $netName, (Format-Rate $f.NetDown)) -ForegroundColor Cyan
    Write-Host ("UP    {0,-30} {1,11}" -f $netName, (Format-Rate $f.NetUp))   -ForegroundColor Blue
    return
}

# ----------------------------------------------------------------------------
# Full-screen renderer (ANSI true-color, btop-style).
# ----------------------------------------------------------------------------
$E = [char]27
$RESET = "$E[0m"
$BOLD  = "$E[1m"
$DIM   = "$E[2m"
$blocks = @(' ',[char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588)
$DEG = [char]0x00B0

function Fg($r,$g,$b) { "$E[38;2;$r;$g;${b}m" }
function FgRGB($c) { Fg $c[0] $c[1] $c[2] }

# Scale an RGB triple toward black (k<1) or white-ish (k>1, clamped). Used to
# derive a dim structural shade and a bright highlight from one accent colour.
function Scale-RGB($c, [double]$k) {
    @(
        [int][math]::Min(255, [math]::Max(0, $c[0] * $k)),
        [int][math]::Min(255, [math]::Max(0, $c[1] * $k)),
        [int][math]::Min(255, [math]::Max(0, $c[2] * $k))
    )
}

# Multi-stop colour ramp: $stops is an array of @(r,g,b); f in 0..1 picks a
# smoothly interpolated shade across them. Lets each panel carry its own
# meaning-coded gradient (load = green->red, thermal = cool->hot, net = mono).
function Ramp-Fg($stops, [double]$f) {
    if ($f -lt 0) { $f = 0 } elseif ($f -gt 1) { $f = 1 }
    $segs = $stops.Count - 1
    if ($segs -le 0) { return (FgRGB $stops[0]) }
    $pos = $f * $segs
    $i = [int][math]::Floor($pos)
    if ($i -ge $segs) { $i = $segs - 1 }
    $t = $pos - $i
    $a = $stops[$i]; $b = $stops[$i + 1]
    return (Fg ([int]($a[0] + ($b[0]-$a[0])*$t)) ([int]($a[1] + ($b[1]-$a[1])*$t)) ([int]($a[2] + ($b[2]-$a[2])*$t)))
}

# Meaning-coded vertical ramps (bottom shade -> top shade), built from layered
# mid-tones rather than flat primaries.
$RampLoad    = @( @(70,150,110), @(120,190,110), @(210,195,95),  @(226,150,74),  @(220,84,80) )   # cool green -> gold -> warm red
$RampThermal = @( @(74,116,196), @(82,178,205),  @(108,196,140), @(224,196,96),  @(226,140,74), @(220,80,72) ) # blue -> cyan -> green -> amber -> red
$RampNetDown = @( @(18,64,68),   @(34,120,120),  @(70,190,180),  @(150,240,225) )                 # deep teal -> bright aqua
$RampNetUp   = @( @(70,50,18),   @(150,110,38),  @(225,170,66),  @(252,222,150) )                 # dark amber -> bright gold

# Metric layout: order maps to grid (left,right per band, top to bottom):
#   row0: CPU      | MEM
#   row1: GPU      | VRAM
#   row2: CPU TEMP | GPU TEMP
#   row3: NET DOWN | NET UP
# Dynamic metrics (network) auto-scale the graph to their recent peak instead of
# using a fixed 0..Max range, since throughput has no natural ceiling.
$Metrics = @(
    @{ Key='CPU';     Label='CPU';      RGB=@(86,180,233);  Ramp=$RampLoad;    Min=0;  Max=100 }
    @{ Key='MEM';     Label='MEM';      RGB=@(120,140,235); Ramp=$RampLoad;    Min=0;  Max=100 }
    @{ Key='GPU';     Label='GPU';      RGB=@(80,200,140);  Ramp=$RampLoad;    Min=0;  Max=100 }
    @{ Key='VRAM';    Label='VRAM';     RGB=@(175,130,235); Ramp=$RampLoad;    Min=0;  Max=100 }
    @{ Key='CPUTEMP'; Label='CPU TEMP'; RGB=@(235,160,70);  Ramp=$RampThermal; Min=20; Max=100 }
    @{ Key='GPUTEMP'; Label='GPU TEMP'; RGB=@(232,110,90);  Ramp=$RampThermal; Min=20; Max=100 }
    @{ Key='NETDOWN'; Label='NET DOWN'; RGB=@(70,200,190);  Ramp=$RampNetDown; Min=0;  Max=100; Dynamic=$true; Floor=128KB }
    @{ Key='NETUP';   Label='NET UP';   RGB=@(238,180,90);  Ramp=$RampNetUp;   Min=0;  Max=100; Dynamic=$true; Floor=128KB }
)
# Derive each panel's bright accent (title text), a dim structural shade (box
# border, so frames recede behind the data), and its history buffer.
$Hist = @{}
foreach ($m in $Metrics) {
    $m.Accent    = (FgRGB $m.RGB)
    $m.AccentDim = (FgRGB (Scale-RGB $m.RGB 0.48))
    $Hist[$m.Key] = New-Object System.Collections.ArrayList
}
$script:CpuCoreHist = @()

function Ensure-CpuCoreHistory($cores) {
    $count = @($cores).Count
    while ($script:CpuCoreHist.Count -lt $count) {
        $script:CpuCoreHist += ,(New-Object System.Collections.ArrayList)
    }
}

function Add-History($f) {
    $vals = @{ CPU=$f.Cpu; CPUTEMP=$f.CpuT; GPU=$f.Gpu; GPUTEMP=$f.GpuT; MEM=$f.MemPct; VRAM=$f.VramPct; NETDOWN=$f.NetDown; NETUP=$f.NetUp }
    foreach ($m in $Metrics) {
        $v = $vals[$m.Key]
        if ($v -eq $null) { $v = [double]::NaN }
        [void]$Hist[$m.Key].Add([double]$v)
        $h = $Hist[$m.Key]
        if ($h.Count -gt 4000) { $h.RemoveRange(0, $h.Count - 4000) }
    }
    Ensure-CpuCoreHistory $f.CpuCores
    for ($i = 0; $i -lt @($f.CpuCores).Count; $i++) {
        $v = $f.CpuCores[$i].Value
        if ($v -eq $null) { $v = [double]::NaN }
        [void]$script:CpuCoreHist[$i].Add([double]$v)
        $h = $script:CpuCoreHist[$i]
        if ($h.Count -gt 4000) { $h.RemoveRange(0, $h.Count - 4000) }
    }
}

# Place text into a fixed-width dashed title bar; returns plain string of length w.
function Build-TitleBar([int]$w, [string]$left, [string]$right) {
    if ($w -lt 1) { return '' }
    $arr = New-Object 'char[]' $w
    for ($i = 0; $i -lt $w; $i++) { $arr[$i] = [char]0x2500 }  # ─
    $L = " $left "
    for ($i = 0; $i -lt $L.Length; $i++) { $p = 1 + $i; if ($p -lt $w) { $arr[$p] = $L[$i] } }
    if ($right) {
        $R = " $right "
        $start = $w - $R.Length - 1
        for ($i = 0; $i -lt $R.Length; $i++) { $p = $start + $i; if ($p -ge 0 -and $p -lt $w) { $arr[$p] = $R[$i] } }
    }
    return (-join $arr)
}

# Render one panel to an array of $h ANSI strings, each $w cells wide.
function Render-Panel($metric, [int]$w, [int]$h, [string]$detail, [string]$value) {
    $accent = $metric.Accent        # bright: title label
    $dim    = $metric.AccentDim     # dim: box frame, so the data reads above it
    $tl=[char]0x256D; $tr=[char]0x256E; $bl=[char]0x2570; $br=[char]0x256F; $vb=[char]0x2502
    $lines = New-Object System.Collections.Generic.List[string]
    if ($w -lt 2 -or $h -lt 1) { for ($i=0;$i -lt $h;$i++){ $lines.Add(' ' * $w) }; return $lines }

    $wi = $w - 2
    $left = "$($metric.Label)"
    if ($detail) { $left = "$($metric.Label)  $detail" }
    # Trim the detail so the title ALWAYS fits before the value and never overlaps
    # it - an overlap would make the label splice (below) cut through the value's
    # injected ANSI escapes, leaking raw escape bytes and breaking the width.
    $valPad  = " $value "
    $maxLeft = $wi - $valPad.Length - 4
    if ($maxLeft -lt 1) { $maxLeft = 1 }
    if ($left.Length -gt $maxLeft) { $left = $left.Substring(0, [math]::Max(1, $maxLeft - 1)) + [char]0x2026 }

    # --- top border with title; frame dim, label bright accent, value bright white ---
    $bar = Build-TitleBar $wi $left $value
    # Plain index where the value span begins (or bar end if no value). Both
    # overlays stay strictly left of this so neither reads the other's escapes.
    $valStart = if ($value) { $wi - $valPad.Length - 1 } else { $wi }
    # Overlay value (right side) first so the later left-side label splice keeps
    # its character indices valid.
    if ($value -and $valStart -ge 0 -and ($valStart + $valPad.Length) -le $bar.Length) {
        $bar = $bar.Substring(0,$valStart) + "$RESET$BOLD" + (Fg 245 245 245) + $bar.Substring($valStart,$valPad.Length) + $RESET + $dim + $bar.Substring($valStart + $valPad.Length)
    }
    # Overlay the title label span (sits at index 1) in the bright accent, clamped
    # so it can never reach into the value span's injected escapes.
    $Lstr = " $left "
    $lLen = [math]::Min($Lstr.Length, [math]::Max(0, $valStart - 1))
    if ($lLen -gt 0 -and (1 + $lLen) -le $bar.Length) {
        $bar = $bar.Substring(0,1) + $accent + $bar.Substring(1, $lLen) + $dim + $bar.Substring(1 + $lLen)
    }
    $lines.Add("$dim$tl$bar$tr$RESET")

    $hi = $h - 2
    if ($hi -lt 0) { $hi = 0 }

    # --- graph rows ---
    if ($hi -ge 1) {
        $hist = $Hist[$metric.Key]
        $n = $hist.Count
        $lvl = New-Object 'int[]' $wi     # -1 = no data, else 0..hi*8
        $scaleMin = [double]$metric.Min
        $scaleMax = [double]$metric.Max
        if ($metric.Dynamic) {
            # Auto-scale to the visible window's peak, with a floor so an idle
            # link doesn't amplify a few bytes of noise to full height.
            $peak = 0.0
            $vstart = [math]::Max(0, $n - $wi)
            for ($k = $vstart; $k -lt $n; $k++) {
                $val = $hist[$k]
                if (-not [double]::IsNaN($val) -and $val -gt $peak) { $peak = $val }
            }
            $floor = if ($null -ne $metric.Floor) { [double]$metric.Floor } else { 1 }
            if ($peak -lt $floor) { $peak = $floor }
            $scaleMax = $peak * 1.15   # a little headroom above the peak
        }
        $span = [double]($scaleMax - $scaleMin); if ($span -le 0) { $span = 1 }
        for ($c = 0; $c -lt $wi; $c++) {
            $idx = $n - $wi + $c
            if ($idx -lt 0) { $lvl[$c] = -1; continue }
            $val = $hist[$idx]
            if ([double]::IsNaN($val)) { $lvl[$c] = -1; continue }
            $fr = ($val - $scaleMin) / $span
            if ($fr -lt 0) { $fr = 0 } elseif ($fr -gt 1) { $fr = 1 }
            $lvl[$c] = [int][math]::Round($fr * $hi * 8)
        }
        for ($i = 0; $i -lt $hi; $i++) {
            $rowFromBottom = $hi - 1 - $i
            $rowBase = $rowFromBottom * 8
            $rowFg = Ramp-Fg $metric.Ramp ([double]($rowFromBottom + 1) / $hi)
            $sb = New-Object System.Text.StringBuilder $wi
            for ($c = 0; $c -lt $wi; $c++) {
                $L = $lvl[$c]
                if ($L -lt 0) { [void]$sb.Append(' '); continue }
                $cell = $L - $rowBase
                if ($cell -ge 8) { [void]$sb.Append($blocks[8]) }
                elseif ($cell -le 0) { [void]$sb.Append(' ') }
                else { [void]$sb.Append($blocks[$cell]) }
            }
            $lines.Add("$dim$vb$rowFg$($sb.ToString())$RESET$dim$vb$RESET")
        }
    }

    # --- bottom border ---
    if ($h -ge 2) {
        $lines.Add("$dim$bl$([string][char]0x2500 * $wi)$br$RESET")
    }
    # pad/truncate to exactly $h lines
    while ($lines.Count -lt $h) { $lines.Add("$dim$vb$(' ' * $wi)$vb$RESET") }
    if ($lines.Count -gt $h) { $lines = $lines.GetRange(0, $h) }
    return $lines
}

function Render-CoreCellLine($core, [int]$w, [int]$histIndex, [int]$line, [int]$cellH) {
    if ($w -lt 1) { return '' }
    if (-not $core) { return ' ' * $w }
    $label = [string]$core.Label
    if (-not $label) { $label = "C$histIndex" }
    $label = $label -replace '^CPU\s+', ''
    $label = $label -replace '^Core\s+', ''
    $label = $label -replace '^C(?=\d+$)', ''
    if ($label.Length -gt 3) { $label = $label.Substring(0, 3) }

    $pct = $core.Value
    $pctText = if ($pct -eq $null) { 'n/a' } else { '{0:N0}%' -f $pct }
    $prefix = $label.PadRight([math]::Max(2, $label.Length))
    $suffix = $pctText.PadLeft(4)
    $barW = if ($line -eq 0) { $w - $prefix.Length - $suffix.Length - 2 } else { $w }
    if ($barW -lt 1) {
        $plain = if ($line -eq 0) { ($prefix + ' ' + $suffix) } else { '' }
        if ($plain.Length -gt $w) { return $plain.Substring(0, $w) }
        return $plain.PadRight($w)
    }

    $bar = $null
    if ($histIndex -lt $script:CpuCoreHist.Count -and $script:CpuCoreHist[$histIndex].Count -gt 0) {
        $hist = $script:CpuCoreHist[$histIndex]
        $sb = New-Object System.Text.StringBuilder
        $cellH = [math]::Max(1, $cellH)
        $startOffset = ($cellH - 1 - $line) * $barW
        for ($i = 0; $i -lt $barW; $i++) {
            $idx = $hist.Count - $startOffset - $barW + $i
            if ($idx -lt 0 -or [double]::IsNaN([double]$hist[$idx])) {
                [void]$sb.Append(' ')
            } else {
                $fr = [math]::Max(0, [math]::Min(1, [double]$hist[$idx] / 100.0))
                $bi = [int][math]::Ceiling($fr * 8)
                if ($bi -lt 1) { $bi = 1 }
                [void]$sb.Append($blocks[$bi])
            }
        }
        $bar = $sb.ToString()
    } else {
        $fr = if ($pct -eq $null) { 0 } else { [math]::Max(0, [math]::Min(1, [double]$pct / 100.0)) }
        $fill = [int][math]::Round($fr * $barW)
        $bar = ([string][char]0x2588 * $fill).PadRight($barW)
    }
    $plain = if ($line -eq 0) { "$prefix $bar $suffix" } else { $bar }
    if ($plain.Length -gt $w) { $plain = $plain.Substring(0, $w) }
    return $plain.PadRight($w)
}

function Get-CoreGridLayout([int]$coreCount, [int]$innerWidth, [int]$innerHeight) {
    $best = $null
    $idealCellW = 16
    for ($cols = 1; $cols -le $coreCount; $cols++) {
        $rows = [int][math]::Ceiling($coreCount / [double]$cols)
        if ($rows -gt $innerHeight) { continue }
        if ((($cols - 1) * $rows) -ge $coreCount) { continue } # no fully empty trailing columns

        $gap = if ($cols -gt 1) { 1 } else { 0 }
        $contentW = $innerWidth - ($gap * ($cols - 1))
        if ($contentW -lt $cols) { $contentW = $cols; $gap = 0 }
        $colW = [int][math]::Floor($contentW / $cols)

        $rowCounts = @()
        for ($c = 0; $c -lt $cols; $c++) {
            $remaining = $coreCount - ($c * $rows)
            $rowCounts += [math]::Max(0, [math]::Min($rows, $remaining))
        }
        $balancePenalty = (($rowCounts | Measure-Object -Maximum).Maximum - ($rowCounts | Measure-Object -Minimum).Minimum) * 4
        $unusedPenalty = ($innerHeight - $rows) * 4
        $widthPenalty = [math]::Abs($colW - $idealCellW)
        $tooNarrowPenalty = if ($colW -lt 12) { (12 - $colW) * 8 } else { 0 }
        $score = $balancePenalty + $unusedPenalty + $widthPenalty + $tooNarrowPenalty

        if (-not $best -or $score -lt $best.Score -or ($score -eq $best.Score -and $cols -lt $best.Cols)) {
            $best = [pscustomobject]@{ Cols=$cols; Rows=$rows; Gap=$gap; ColW=$colW; Score=$score }
        }
    }
    if ($best) { return $best }
    return [pscustomobject]@{ Cols=$coreCount; Rows=1; Gap=0; ColW=[math]::Max(1, [int][math]::Floor($innerWidth / [math]::Max(1, $coreCount))); Score=[int]::MaxValue }
}

function Render-CorePanel($metric, [int]$w, [int]$h, [string]$detail, $cores) {
    $accent = $metric.Accent
    $dim    = $metric.AccentDim
    $tl=[char]0x256D; $tr=[char]0x256E; $bl=[char]0x2570; $br=[char]0x256F; $vb=[char]0x2502
    $lines = New-Object System.Collections.Generic.List[string]
    if ($w -lt 2 -or $h -lt 1) { for ($i=0;$i -lt $h;$i++){ $lines.Add(' ' * $w) }; return $lines }

    $wi = $w - 2
    $coreList = @($cores)
    $valid = @($coreList | Where-Object { $_.Value -ne $null })
    $value = if ($valid.Count -gt 0) { '{0:N0}% avg' -f (($valid | Measure-Object -Property Value -Average).Average) } else { 'n/a' }
    $left = 'CPU CORES'
    if ($detail) { $left = "CPU CORES  $detail" }

    $valPad  = " $value "
    $maxLeft = $wi - $valPad.Length - 4
    if ($maxLeft -lt 1) { $maxLeft = 1 }
    if ($left.Length -gt $maxLeft) { $left = $left.Substring(0, [math]::Max(1, $maxLeft - 1)) + [char]0x2026 }

    $bar = Build-TitleBar $wi $left $value
    $valStart = if ($value) { $wi - $valPad.Length - 1 } else { $wi }
    if ($value -and $valStart -ge 0 -and ($valStart + $valPad.Length) -le $bar.Length) {
        $bar = $bar.Substring(0,$valStart) + "$RESET$BOLD" + (Fg 245 245 245) + $bar.Substring($valStart,$valPad.Length) + $RESET + $dim + $bar.Substring($valStart + $valPad.Length)
    }
    $Lstr = " $left "
    $lLen = [math]::Min($Lstr.Length, [math]::Max(0, $valStart - 1))
    if ($lLen -gt 0 -and (1 + $lLen) -le $bar.Length) {
        $bar = $bar.Substring(0,1) + $accent + $bar.Substring(1, $lLen) + $dim + $bar.Substring(1 + $lLen)
    }
    $lines.Add("$dim$tl$bar$tr$RESET")

    $hi = $h - 2
    if ($hi -lt 0) { $hi = 0 }
    if ($hi -ge 1) {
        if ($coreList.Count -eq 0) {
            $msg = 'per-core data unavailable'
            if ($msg.Length -gt $wi) { $msg = $msg.Substring(0, $wi) }
            $pad = [int](($wi - $msg.Length) / 2); if ($pad -lt 0) { $pad = 0 }
            $line = (' ' * $pad) + $msg
            $line = $line.PadRight($wi)
            $lines.Add("$dim$vb$RESET$DIM$(Fg 160 170 180)$line$RESET$dim$vb$RESET")
            for ($i = 1; $i -lt $hi; $i++) { $lines.Add("$dim$vb$(' ' * $wi)$vb$RESET") }
        } else {
            $layout = Get-CoreGridLayout $coreList.Count $wi $hi
            $cols = $layout.Cols
            $rowsNeeded = $layout.Rows
            $gap = $layout.Gap
            $colW = $layout.ColW
            $visible = $rowsNeeded * $cols
            $baseCellH = [int][math]::Floor($hi / $rowsNeeded)
            if ($baseCellH -lt 1) { $baseCellH = 1 }
            $extraRows = $hi - ($baseCellH * $rowsNeeded)
            for ($r = 0; $r -lt $rowsNeeded; $r++) {
                $cellH = $baseCellH + $(if ($r -lt $extraRows) { 1 } else { 0 })
                for ($cellLine = 0; $cellLine -lt $cellH; $cellLine++) {
                $plainLen = 0
                $row = New-Object System.Text.StringBuilder
                for ($c = 0; $c -lt $cols; $c++) {
                    $idx = ($c * $rowsNeeded) + $r
                    $cw = if ($c -eq ($cols - 1)) { $wi - $plainLen } else { $colW }
                    if ($coreList.Count -gt $visible -and $idx -eq ($visible - 1) -and $cellLine -eq 0) {
                        $more = '+{0} more' -f ($coreList.Count - $visible + 1)
                        if ($more.Length -gt $cw) { $more = $more.Substring(0, $cw) }
                        [void]$row.Append($more.PadRight($cw))
                    } elseif ($idx -lt $coreList.Count) {
                        [void]$row.Append((Render-CoreCellLine $coreList[$idx] $cw $idx $cellLine $cellH))
                    } else {
                        [void]$row.Append(' ' * $cw)
                    }
                    $plainLen += $cw
                    if ($gap -gt 0 -and $c -lt ($cols - 1)) {
                        [void]$row.Append(' ' * $gap)
                        $plainLen += $gap
                    }
                }
                    $lines.Add("$dim$vb$(Ramp-Fg $metric.Ramp ([double]($r + 1) / [math]::Max(1, $rowsNeeded)))$($row.ToString())$RESET$dim$vb$RESET")
                }
            }
        }
    }

    if ($h -ge 2) {
        $lines.Add("$dim$bl$([string][char]0x2500 * $wi)$br$RESET")
    }
    while ($lines.Count -lt $h) { $lines.Add("$dim$vb$(' ' * $wi)$vb$RESET") }
    if ($lines.Count -gt $h) { $lines = $lines.GetRange(0, $h) }
    return $lines
}

function Draw-TooSmall([int]$w, [int]$h, [int]$minW, [int]$minH) {
    $msg = @(
        "$BOLD$(Fg 255 90 60)Terminal too small$RESET",
        "$(Fg 245 245 245)Need at least $minW x $minH$RESET",
        "$(Fg 200 200 60)Current: $w x $h$RESET",
        "$DIM(resize the window)$RESET"
    )
    $plain = @('Terminal too small', "Need at least $minW x $minH", "Current: $w x $h", '(resize the window)')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$E[H")
    $top = [int](($h - $msg.Count) / 2)
    for ($y = 0; $y -lt $h; $y++) {
        $mi = $y - $top
        if ($mi -ge 0 -and $mi -lt $msg.Count) {
            $pad = [int](($w - $plain[$mi].Length) / 2); if ($pad -lt 0) { $pad = 0 }
            $line = (' ' * $pad) + $msg[$mi]
            $tail = $w - $pad - $plain[$mi].Length; if ($tail -lt 0) { $tail = 0 }
            $line += (' ' * $tail)
        } else {
            $line = ' ' * $w
        }
        if ($y -lt $h - 1) { [void]$sb.Append($line + "`n") }
        else { [void]$sb.Append($line.Substring(0, [math]::Max(0, $w - 1))) }
    }
    [Console]::Out.Write($sb.ToString())
}

# Enable ANSI / virtual-terminal processing on legacy consoles.
function Enable-VT {
    try {
        Add-Type -Namespace Amdmon -Name VT -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int handle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr handle, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr handle, uint mode);
public static void Enable() {
    System.IntPtr h = GetStdHandle(-11);
    uint m;
    if (GetConsoleMode(h, out m)) { SetConsoleMode(h, m | 0x0004); }
}
'@ -ErrorAction SilentlyContinue
        [Amdmon.VT]::Enable()
    } catch { }
}

# Build the full frame (rows + status bar) as one string, no leading cursor move.
function Compose-Frame([int]$W, [int]$H, $f, [int]$targetMs, [string]$CpuMode) {
    $gridH = $H - 1
    # One band per metric pair, derived from $Metrics so adding/removing metrics
    # reflows automatically. Layout is left|right per band, top to bottom:
    # CPU|MEM, GPU|VRAM, CPU TEMP|GPU TEMP, NET DOWN|NET UP. Any leftover rows are
    # handed to the bottom bands so nothing is dropped.
    $bands = [int][math]::Ceiling($Metrics.Count / 2.0)
    $base = [int][math]::Floor($gridH / $bands)   # floor: [int] alone rounds, breaking the remainder math
    $rem  = $gridH - ($base * $bands)
    $bandH = @()
    for ($b = 0; $b -lt $bands; $b++) {
        $extra = if ($b -ge ($bands - $rem)) { 1 } else { 0 }
        $bandH += ($base + $extra)
    }
    $wL = [int]($W / 2); $wR = $W - $wL

    $tempUnit = "$DEG" + 'C'
    $details = @{
        CPU = $cpuName; CPUTEMP = $cpuTempLabel; GPU = $gpuName
        GPUTEMP = $gpuTempLabel; MEM = $ramName; VRAM = 'Video Memory'
        NETDOWN = $netName; NETUP = $netName
    }
    $values = @{
        CPU     = $(if ($f.Cpu  -eq $null) { 'n/a' } else { '{0:N0}%' -f $f.Cpu })
        CPUTEMP = $(if ($f.CpuT -eq $null) { 'n/a' } else { ('{0:N0}' -f $f.CpuT) + $tempUnit })
        GPU     = $(if ($f.Gpu  -eq $null) { 'n/a' } else { '{0:N0}%' -f $f.Gpu })
        GPUTEMP = $(if ($f.GpuT -eq $null) { 'n/a' } else { ('{0:N0}' -f $f.GpuT) + $tempUnit })
        MEM     = ('{0:N1}/{1:N0} GB  {2:N0}%' -f $f.MemUsedGB, $f.MemTotalGB, $f.MemPct)
        VRAM    = ('{0:N1}/{1:N0} GB  {2:N0}%' -f $f.VramUsedGB, $f.VramTotalGB, $f.VramPct)
        NETDOWN = (Format-Rate $f.NetDown)
        NETUP   = (Format-Rate $f.NetUp)
    }

    $rows = New-Object System.Collections.Generic.List[string]
    for ($band = 0; $band -lt $bands; $band++) {
        $bh = $bandH[$band]
        $mL = $Metrics[$band * 2]
        $mR = if (($band * 2 + 1) -lt $Metrics.Count) { $Metrics[$band * 2 + 1] } else { $null }
        if ($mL.Key -eq 'CPU' -and $CpuMode -eq 'Cores') {
            $pL = Render-CorePanel $mL $wL $bh $details[$mL.Key] $f.CpuCores
        } else {
            $pL = Render-Panel $mL $wL $bh $details[$mL.Key] $values[$mL.Key]
        }
        if ($mR) {
            if ($mR.Key -eq 'CPU' -and $CpuMode -eq 'Cores') {
                $pR = Render-CorePanel $mR $wR $bh $details[$mR.Key] $f.CpuCores
            } else {
                $pR = Render-Panel $mR $wR $bh $details[$mR.Key] $values[$mR.Key]
            }
        } else {
            # Odd metric count: pad the right half with an empty spacer column.
            $pR = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $bh; $i++) { $pR.Add(' ' * $wR) }
        }
        for ($i = 0; $i -lt $bh; $i++) { $rows.Add($pL[$i] + $pR[$i]) }
    }

    # status bar on the last row (skip the final cell to avoid auto-scroll)
    $tempState = if ($haveLhm) { 'LHM' } else { 'counters' }
    $netState  = if ($haveNet) { 'net' } else { 'net:off' }
    $cpuHint = if ($CpuMode -eq 'Cores') { 'space total' } else { 'space cores' }
    $statusPlain = " amdmon   {0}ms   {1}   src:{2}   {3}   cpu:{4}   {5}x{6}   {7}   q quit" -f $targetMs, (Get-Date -Format 'HH:mm:ss'), $tempState, $netState, $CpuMode.ToLowerInvariant(), $W, $H, $cpuHint
    if ($statusPlain.Length -gt ($W - 1)) { $statusPlain = $statusPlain.Substring(0, $W - 1) }
    else { $statusPlain = $statusPlain.PadRight($W - 1) }
    # Brand in a soft accent, the rest a calm slate, for a quieter footer.
    if ($statusPlain.Length -ge 7) {
        $status = "$BOLD$(Fg 130 205 235)$($statusPlain.Substring(0,7))$RESET$DIM$(Fg 120 134 150)$($statusPlain.Substring(7))$RESET"
    } else {
        $status = "$DIM$(Fg 120 134 150)$statusPlain$RESET"
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $rows) { [void]$sb.Append($r); [void]$sb.Append("`n") }
    [void]$sb.Append($status)
    return $sb.ToString()
}

# ----------------------------------------------------------------------------
# Self-test: render one frame at a fixed size with synthetic data, strip ANSI,
# and report per-line visible widths so layout can be checked without a console.
# ----------------------------------------------------------------------------
if ($SelfTest) {
    $rx = New-Object System.Text.RegularExpressions.Regex ([char]27 + '\[[0-9;?]*[A-Za-z]')
    foreach ($m in $Metrics) {
        for ($j = 0; $j -lt $TestW; $j++) {
            if ($m.Key -like 'NET*') {
                # Bytes/sec scale so the dynamic auto-scaling path is exercised.
                $base = if ($m.Key -eq 'NETDOWN') { 6MB } else { 1.5MB }
                $v = $base + ($base * 0.6) * [math]::Sin($j / 4.0)
            } else {
                $base = switch ($m.Key) { 'CPU'{40} 'GPU'{55} 'MEM'{30} 'VRAM'{80} 'CPUTEMP'{55} 'GPUTEMP'{48} default{50} }
                $v = $base + 25 * [math]::Sin($j / 4.0) + ($j % 7)
            }
            [void]$Hist[$m.Key].Add([double]$v)
        }
    }
    $fake = [pscustomobject]@{
        Cpu=42.7; CpuT=55; Gpu=63.0; GpuT=48; MemPct=31.4; MemUsedGB=20.1; MemTotalGB=64
        VramPct=80.2; VramUsedGB=16.0; VramTotalGB=20; NetDown=(6MB); NetUp=(1.5MB)
        CpuCores=@(
            [pscustomobject]@{ Label='C0';  Value=12.0 }, [pscustomobject]@{ Label='C1';  Value=24.0 }
            [pscustomobject]@{ Label='C2';  Value=36.0 }, [pscustomobject]@{ Label='C3';  Value=48.0 }
            [pscustomobject]@{ Label='C4';  Value=60.0 }, [pscustomobject]@{ Label='C5';  Value=72.0 }
            [pscustomobject]@{ Label='C6';  Value=84.0 }, [pscustomobject]@{ Label='C7';  Value=96.0 }
            [pscustomobject]@{ Label='C8';  Value=20.0 }, [pscustomobject]@{ Label='C9';  Value=40.0 }
            [pscustomobject]@{ Label='C10'; Value=60.0 }, [pscustomobject]@{ Label='C11'; Value=80.0 }
        )
    }
    Ensure-CpuCoreHistory $fake.CpuCores
    for ($i = 0; $i -lt $fake.CpuCores.Count; $i++) {
        for ($j = 0; $j -lt $TestW; $j++) {
            $v = [math]::Max(0, [math]::Min(100, $fake.CpuCores[$i].Value + 18 * [math]::Sin(($j + $i) / 5.0)))
            [void]$script:CpuCoreHist[$i].Add([double]$v)
        }
    }
    foreach ($mode in @('Total','Cores')) {
        $frame = Compose-Frame $TestW $TestH $fake 100 $mode
        $lines = $frame -split "`n"
        Write-Host "=== rendered ${TestW}x${TestH} mode=$mode (ANSI stripped) ===" -ForegroundColor Cyan
        $bad = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $plain = $rx.Replace($lines[$i], '')
            $len = $plain.Length
            $flag = if ($i -lt ($lines.Count - 1) -and $len -ne $TestW) { $bad++; " <-- WIDTH $len" } elseif ($i -eq ($lines.Count - 1) -and $len -ne ($TestW - 1)) { $bad++; " <-- STATUS $len" } else { '' }
            Write-Host ("{0,2}|{1}|{2}" -f $i, $plain, $flag)
        }
        Write-Host "mode=$mode lines=$($lines.Count) expected=$TestH  widthErrors=$bad" -ForegroundColor $(if ($bad -eq 0 -and $lines.Count -eq $TestH) { 'Green' } else { 'Red' })
    }
    return
}

# ----------------------------------------------------------------------------
# Main loop.
# ----------------------------------------------------------------------------
# MinH derives from the band count (~5 rows per band + 1 status row) so it stays
# coherent if metrics are added/removed; MinW is a fixed legibility floor.
$MinW = 56
$MinH = ([int][math]::Ceiling($Metrics.Count / 2.0)) * 5 + 1
$targetMs = [int]([math]::Max(16, $Interval * 1000))

Enable-VT
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$prevCursor = $true
try { $prevCursor = [Console]::CursorVisible } catch { }

[Console]::Out.Write("$E[?25l$E[2J$E[H")   # hide cursor, clear
$sw = New-Object System.Diagnostics.Stopwatch
$script:CpuMode = 'Total'
try {
    while ($true) {
        $sw.Restart()
        # q quits; space toggles the CPU panel between total and per-core views.
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q') { break 2 }
                if ($k.Key -eq [ConsoleKey]::Spacebar) {
                    $script:CpuMode = if ($script:CpuMode -eq 'Cores') { 'Total' } else { 'Cores' }
                }
            }
        } catch { }

        $W = [Console]::WindowWidth
        $H = [Console]::WindowHeight
        $f = Get-Frame
        Add-History $f

        if ($W -lt $MinW -or $H -lt $MinH) {
            Draw-TooSmall $W $H $MinW $MinH
            $rem = $targetMs - [int]$sw.ElapsedMilliseconds
            if ($rem -gt 0) { Start-Sleep -Milliseconds $rem }
            continue
        }

        [Console]::Out.Write("$E[H" + (Compose-Frame $W $H $f $targetMs $script:CpuMode))

        $rem = $targetMs - [int]$sw.ElapsedMilliseconds
        if ($rem -gt 0) { Start-Sleep -Milliseconds $rem }
    }
} finally {
    [Console]::Out.Write("$RESET$E[?25h")    # reset colors, show cursor
    try { [Console]::CursorVisible = $prevCursor } catch { }
    [Console]::Out.Write("$E[2J$E[H")
    if ($script:Computer) { try { $script:Computer.Close() } catch { } }
    # Release the unmanaged PDH handles held by the performance counters.
    foreach ($c in $script:NetRxCtrs) { try { $c.Dispose() } catch { } }
    foreach ($c in $script:NetTxCtrs) { try { $c.Dispose() } catch { } }
    foreach ($c in $script:CpuCoreCtrs) { try { $c.Counter.Dispose() } catch { } }
    if ($memAvail) { try { $memAvail.Dispose() } catch { } }
    if ($cpuCtr)   { try { $cpuCtr.Dispose() } catch { } }
}
