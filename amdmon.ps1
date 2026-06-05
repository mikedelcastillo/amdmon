<#
  amdmon.ps1 - A btop-style, full-screen system monitor for Windows terminals.

  Shows CPU / RAM / GPU / VRAM usage plus CPU & GPU temperatures, each with a
  scrolling history graph (MSI Afterburner / RivaTuner style). Built to work
  headless over SSH, where GUI tools and btop/bottom can't read AMD GPUs.

  Data comes from LibreHardwareMonitorLib (auto-downloaded to .\lib on first
  run; needs admin for CPU/GPU temperatures, which load a signed kernel driver).
  If the library can't be loaded, it falls back to Windows performance counters
  for usage and shows temperatures as "n/a".

  Usage:   amdmon                 # full-screen dashboard, ~100ms refresh (q or Ctrl+C to quit)
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

$cpuTempLabel = if ($script:S.CpuTemp) { $script:S.CpuTemp.Name } else { 'Temperature' }
$gpuTempLabel = if ($script:S.GpuTemp) { $script:S.GpuTemp.Name } else { 'Temperature' }

# ----------------------------------------------------------------------------
# Sampling: returns one frame of numbers.
# ----------------------------------------------------------------------------
function Get-Frame {
    $cpu = $null; $cpuT = $null; $gpu = $null; $gpuT = $null
    $vramUsedB = 0.0; $vramTotalB = [double]$totalVram

    if ($haveLhm) {
        if ($script:CpuHw) { $script:CpuHw.Update() }
        if ($script:GpuHw) { $script:GpuHw.Update() }
        $cpu  = Get-SensorValue $script:S.CpuLoad
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

    $ramUsedB = $totalRam
    if ($memAvail) { $ramUsedB = $totalRam - [double]$memAvail.NextValue() }

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
    }
}

# ----------------------------------------------------------------------------
# -Once : plain text snapshot.
# ----------------------------------------------------------------------------
function Format-Pct($v) { if ($v -eq $null) { 'n/a' } else { '{0:N1}%' -f $v } }
function Format-Temp($v) { if ($v -eq $null) { 'n/a' } else { '{0:N0}' -f $v + [char]0x00B0 + 'C' } }

if ($Once) {
    $f = Get-Frame
    Write-Host ("CPU   {0,-30} {1,7}   {2}" -f $cpuName, (Format-Pct $f.Cpu), (Format-Temp $f.CpuT)) -ForegroundColor Cyan
    Write-Host ("GPU   {0,-30} {1,7}   {2}" -f $gpuName, (Format-Pct $f.Gpu), (Format-Temp $f.GpuT)) -ForegroundColor Green
    Write-Host ("MEM   {0,-30} {1,7}   {2:N1} / {3:N0} GB" -f $ramName, (Format-Pct $f.MemPct), $f.MemUsedGB, $f.MemTotalGB) -ForegroundColor Yellow
    Write-Host ("VRAM  {0,-30} {1,7}   {2:N1} / {3:N0} GB" -f 'Video Memory', (Format-Pct $f.VramPct), $f.VramUsedGB, $f.VramTotalGB) -ForegroundColor Magenta
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

# Vertical gradient green -> yellow -> red by height fraction f (0..1).
function Grad-Fg([double]$f) {
    if ($f -lt 0) { $f = 0 } elseif ($f -gt 1) { $f = 1 }
    if ($f -lt 0.5) {
        $t = $f / 0.5
        $r = [int](46  + (241 - 46)  * $t)
        $g = [int](204 + (196 - 204) * $t)
        $b = [int](113 + (15  - 113) * $t)
    } else {
        $t = ($f - 0.5) / 0.5
        $r = [int](241 + (231 - 241) * $t)
        $g = [int](196 + (76  - 196) * $t)
        $b = [int](15  + (60  - 15)  * $t)
    }
    return (Fg $r $g $b)
}

# Metric layout: order maps to grid (row0: 0,1  row1: 2,3  row2: 4,5).
$Metrics = @(
    @{ Key='CPU';     Label='CPU';      Accent=(Fg 0 200 255);   Min=0;  Max=100 }
    @{ Key='CPUTEMP'; Label='CPU TEMP'; Accent=(Fg 255 150 40);  Min=20; Max=100 }
    @{ Key='GPU';     Label='GPU';      Accent=(Fg 90 220 120);  Min=0;  Max=100 }
    @{ Key='GPUTEMP'; Label='GPU TEMP'; Accent=(Fg 255 90 60);   Min=20; Max=100 }
    @{ Key='MEM';     Label='MEM';      Accent=(Fg 100 150 255); Min=0;  Max=100 }
    @{ Key='VRAM';    Label='VRAM';     Accent=(Fg 185 120 255); Min=0;  Max=100 }
)
$Hist = @{}
foreach ($m in $Metrics) { $Hist[$m.Key] = New-Object System.Collections.ArrayList }

function Add-History($f) {
    $vals = @{ CPU=$f.Cpu; CPUTEMP=$f.CpuT; GPU=$f.Gpu; GPUTEMP=$f.GpuT; MEM=$f.MemPct; VRAM=$f.VramPct }
    foreach ($m in $Metrics) {
        $v = $vals[$m.Key]
        if ($v -eq $null) { $v = [double]::NaN }
        [void]$Hist[$m.Key].Add([double]$v)
        $h = $Hist[$m.Key]
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
function Render-Panel($metric, [int]$w, [int]$h, [string]$detail, [string]$value, [double]$cur) {
    $accent = $metric.Accent
    $tl=[char]0x256D; $tr=[char]0x256E; $bl=[char]0x2570; $br=[char]0x256F; $vb=[char]0x2502
    $lines = New-Object System.Collections.Generic.List[string]
    if ($w -lt 2 -or $h -lt 1) { for ($i=0;$i -lt $h;$i++){ $lines.Add(' ' * $w) }; return $lines }

    $wi = $w - 2
    $left = "$($metric.Label)"
    if ($detail) { $left = "$($metric.Label)  $detail" }
    # Trim the detail if the title would overflow.
    $maxLeft = $wi - (" $value ".Length) - 4
    if ($maxLeft -gt 4 -and $left.Length -gt $maxLeft) { $left = $left.Substring(0, $maxLeft - 1) + [char]0x2026 }

    # --- top border with title; value highlighted bright white ---
    $bar = Build-TitleBar $wi $left $value
    if ($value) {
        $R = " $value "
        $vs = $wi - $R.Length - 1
        if ($vs -ge 0 -and ($vs + $R.Length) -le $bar.Length) {
            $bar = $bar.Substring(0,$vs) + "$RESET$BOLD" + (Fg 245 245 245) + $bar.Substring($vs,$R.Length) + $RESET + $accent + $bar.Substring($vs + $R.Length)
        }
    }
    $lines.Add("$accent$tl$bar$tr$RESET")

    $hi = $h - 2
    if ($hi -lt 0) { $hi = 0 }

    # --- graph rows ---
    if ($hi -ge 1) {
        $hist = $Hist[$metric.Key]
        $n = $hist.Count
        $lvl = New-Object 'int[]' $wi     # -1 = no data, else 0..hi*8
        $span = [double]($metric.Max - $metric.Min); if ($span -le 0) { $span = 1 }
        for ($c = 0; $c -lt $wi; $c++) {
            $idx = $n - $wi + $c
            if ($idx -lt 0) { $lvl[$c] = -1; continue }
            $val = $hist[$idx]
            if ([double]::IsNaN($val)) { $lvl[$c] = -1; continue }
            $fr = ($val - $metric.Min) / $span
            if ($fr -lt 0) { $fr = 0 } elseif ($fr -gt 1) { $fr = 1 }
            $lvl[$c] = [int][math]::Round($fr * $hi * 8)
        }
        for ($i = 0; $i -lt $hi; $i++) {
            $rowFromBottom = $hi - 1 - $i
            $rowBase = $rowFromBottom * 8
            $rowFg = Grad-Fg ([double]($rowFromBottom + 1) / $hi)
            $sb = New-Object System.Text.StringBuilder $wi
            for ($c = 0; $c -lt $wi; $c++) {
                $L = $lvl[$c]
                if ($L -lt 0) { [void]$sb.Append(' '); continue }
                $cell = $L - $rowBase
                if ($cell -ge 8) { [void]$sb.Append($blocks[8]) }
                elseif ($cell -le 0) { [void]$sb.Append(' ') }
                else { [void]$sb.Append($blocks[$cell]) }
            }
            $lines.Add("$accent$vb$rowFg$($sb.ToString())$RESET$accent$vb$RESET")
        }
    }

    # --- bottom border ---
    if ($h -ge 2) {
        $lines.Add("$accent$bl$([string][char]0x2500 * $wi)$br$RESET")
    }
    # pad/truncate to exactly $h lines
    while ($lines.Count -lt $h) { $lines.Add("$accent$vb$(' ' * $wi)$vb$RESET") }
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
function Compose-Frame([int]$W, [int]$H, $f, [int]$targetMs) {
    $gridH = $H - 1
    $h0 = [int]($gridH / 3); $h1 = [int]($gridH / 3); $h2 = $gridH - $h0 - $h1
    $wL = [int]($W / 2); $wR = $W - $wL
    $bandH = @($h0, $h1, $h2)

    $tempUnit = "$DEG" + 'C'
    $details = @{
        CPU = $cpuName; CPUTEMP = $cpuTempLabel; GPU = $gpuName
        GPUTEMP = $gpuTempLabel; MEM = $ramName; VRAM = 'Video Memory'
    }
    $values = @{
        CPU     = $(if ($f.Cpu  -eq $null) { 'n/a' } else { '{0:N0}%' -f $f.Cpu })
        CPUTEMP = $(if ($f.CpuT -eq $null) { 'n/a' } else { ('{0:N0}' -f $f.CpuT) + $tempUnit })
        GPU     = $(if ($f.Gpu  -eq $null) { 'n/a' } else { '{0:N0}%' -f $f.Gpu })
        GPUTEMP = $(if ($f.GpuT -eq $null) { 'n/a' } else { ('{0:N0}' -f $f.GpuT) + $tempUnit })
        MEM     = ('{0:N1}/{1:N0} GB  {2:N0}%' -f $f.MemUsedGB, $f.MemTotalGB, $f.MemPct)
        VRAM    = ('{0:N1}/{1:N0} GB  {2:N0}%' -f $f.VramUsedGB, $f.VramTotalGB, $f.VramPct)
    }

    $rows = New-Object System.Collections.Generic.List[string]
    for ($band = 0; $band -lt 3; $band++) {
        $bh = $bandH[$band]
        $mL = $Metrics[$band * 2]
        $mR = $Metrics[$band * 2 + 1]
        $pL = Render-Panel $mL $wL $bh $details[$mL.Key] $values[$mL.Key] 0
        $pR = Render-Panel $mR $wR $bh $details[$mR.Key] $values[$mR.Key] 0
        for ($i = 0; $i -lt $bh; $i++) { $rows.Add($pL[$i] + $pR[$i]) }
    }

    # status bar on the last row (skip the final cell to avoid auto-scroll)
    $tempState = if ($haveLhm) { 'LHM' } else { 'counters' }
    $statusPlain = " amdmon   {0}ms   {1}   src:{2}   {3}x{4}   q quit" -f $targetMs, (Get-Date -Format 'HH:mm:ss'), $tempState, $W, $H
    if ($statusPlain.Length -gt ($W - 1)) { $statusPlain = $statusPlain.Substring(0, $W - 1) }
    else { $statusPlain = $statusPlain.PadRight($W - 1) }
    $status = "$DIM$(Fg 150 150 160)$statusPlain$RESET"

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
            $base = switch ($m.Key) { 'CPU'{40} 'GPU'{55} 'MEM'{30} 'VRAM'{80} 'CPUTEMP'{55} 'GPUTEMP'{48} default{50} }
            $v = $base + 25 * [math]::Sin($j / 4.0) + ($j % 7)
            [void]$Hist[$m.Key].Add([double]$v)
        }
    }
    $fake = [pscustomobject]@{
        Cpu=42.7; CpuT=55; Gpu=63.0; GpuT=48; MemPct=31.4; MemUsedGB=20.1; MemTotalGB=64
        VramPct=80.2; VramUsedGB=16.0; VramTotalGB=20
    }
    $frame = Compose-Frame $TestW $TestH $fake 100
    $lines = $frame -split "`n"
    Write-Host "=== rendered ${TestW}x${TestH} (ANSI stripped) ===" -ForegroundColor Cyan
    $bad = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $plain = $rx.Replace($lines[$i], '')
        $len = $plain.Length
        $flag = if ($i -lt ($lines.Count - 1) -and $len -ne $TestW) { $bad++; " <-- WIDTH $len" } elseif ($i -eq ($lines.Count - 1) -and $len -ne ($TestW - 1)) { $bad++; " <-- STATUS $len" } else { '' }
        Write-Host ("{0,2}|{1}|{2}" -f $i, $plain, $flag)
    }
    Write-Host "lines=$($lines.Count) expected=$TestH  widthErrors=$bad" -ForegroundColor $(if ($bad -eq 0 -and $lines.Count -eq $TestH) { 'Green' } else { 'Red' })
    return
}

# ----------------------------------------------------------------------------
# Main loop.
# ----------------------------------------------------------------------------
$MinW = 56; $MinH = 16
$targetMs = [int]([math]::Max(16, $Interval * 1000))

Enable-VT
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$prevCursor = $true
try { $prevCursor = [Console]::CursorVisible } catch { }

[Console]::Out.Write("$E[?25l$E[2J$E[H")   # hide cursor, clear
$sw = New-Object System.Diagnostics.Stopwatch
try {
    while ($true) {
        $sw.Restart()
        # quit on 'q'
        try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q') { break } } } catch { }

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

        [Console]::Out.Write("$E[H" + (Compose-Frame $W $H $f $targetMs))

        $rem = $targetMs - [int]$sw.ElapsedMilliseconds
        if ($rem -gt 0) { Start-Sleep -Milliseconds $rem }
    }
} finally {
    [Console]::Out.Write("$RESET$E[?25h")    # reset colors, show cursor
    try { [Console]::CursorVisible = $prevCursor } catch { }
    [Console]::Out.Write("$E[2J$E[H")
    if ($script:Computer) { try { $script:Computer.Close() } catch { } }
}
