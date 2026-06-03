# amd-mon

A tiny, dependency-free PowerShell tool to monitor **AMD (and any) GPU utilization and VRAM from a terminal on Windows** — built specifically to work over **SSH**, where every GUI tool is useless and the popular terminal monitors don't support AMD.

## The problem

I have a **Radeon RX 7900 XT (20 GB)** in a Windows 11 box that I manage headless over SSH, and there was no good way to watch GPU/VRAM usage:

- **`bottom` (`btm`) and `btop`** only read AMD GPUs on **Linux** (via `/sys/class/drm`). On Windows they support **NVIDIA only**, so the 7900 XT never shows up — and there's no setting that fixes it.
- **Task Manager, AMD Software: Adrenalin, HWiNFO, GPU-Z, MSI Afterburner** all need an interactive desktop session. Over SSH there's no desktop, so they're out.
- **`rocm-smi` / `nvtop`** are Linux tools.
- `Win32_VideoController.AdapterRAM` (the usual WMI query) **overflows for cards >4 GB**, reporting the 20 GB card as only ~4 GB.

So: a card that's well supported on Linux, in a Windows machine, accessed over a terminal, had effectively zero monitoring options.

## The solution

Windows exposes GPU utilization and VRAM through the **WDDM performance counters** (`GPU Engine`, `GPU Adapter Memory`), which are **vendor-agnostic** and fully readable from a headless terminal via `Get-Counter`. `amd-mon` reads those counters and renders a small live dashboard. To get the true total VRAM, it reads the driver's 64-bit `HardwareInformation.qwMemorySize` value from the registry instead of the overflow-prone WMI field.

No dependencies. No admin rights. No GUI session. Just PowerShell.

## Features

- GPU utilization — overall plus a per-engine breakdown (3D, compute, copy, video, …)
- Dedicated VRAM used / total / percent — correct on cards >4 GB
- Shared memory usage
- Live refreshing dashboard, or a single snapshot for logging/scripting
- Works over SSH on Windows for AMD, NVIDIA, and Intel GPUs

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- A GPU with an up-to-date WDDM driver (any vendor)

## Install

```powershell
git clone https://github.com/mikedelcastillo/amd-mon.git
cd amd-mon
```

## Usage

```powershell
# Live refreshing dashboard (1s refresh), Ctrl+C to quit
powershell -ExecutionPolicy Bypass -File gpumon.ps1

# Custom refresh interval (seconds)
powershell -File gpumon.ps1 -Interval 2

# Single snapshot (good for logging / scripting)
powershell -File gpumon.ps1 -Once
```

Tip: add a function to your PowerShell `$PROFILE` so you can just type `gpumon` after you SSH in:

```powershell
function gpumon { powershell -ExecutionPolicy Bypass -File "$HOME\Code\amd-mon\gpumon.ps1" @args }
```

### Example output

```
AMD GPU Monitor - 22:05:11   (Ctrl+C to quit)
------------------------------------------------------------
GPU Busy   [------------------------------]   0.0%
VRAM Used  [##############################]  99.5%   19.88 / 19.98 GB
Shared Mem 1.25 GB
Engines    copy=0%  timer=0%  compute=0%  security=0%  3d=0%  video=0%
```

## Notes & limitations

- **Temperature, power, and clock speeds are not exposed** by the Windows WDDM counters. Those live in AMD's ADL/ADLX libraries and would need a compiled helper — out of scope for this pure-PowerShell tool.
- The **GPU Busy** figure sums all engine instances, so under heavy mixed load it can read higher than Task Manager (which shows only the single busiest engine). Use the per-engine line for the real split.
- Tested on Windows 11 with a Radeon RX 7900 XT (20 GB).

## License

MIT — see [LICENSE](LICENSE).
