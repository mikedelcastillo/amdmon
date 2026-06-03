# amd-mon

Terminal GPU + VRAM monitor for **AMD (and any) GPUs on Windows** — designed to work over **SSH** where GUI tools (Task Manager, AMD Adrenalin, HWiNFO) and `bottom`/`btop` can't help.

`bottom` and `btop` only read AMD GPUs on **Linux** (via `/sys/class/drm`); on Windows they support NVIDIA only. `amd-mon` instead reads the **Windows WDDM performance counters** (`GPU Engine`, `GPU Adapter Memory`), which are vendor-agnostic and fully available from a headless terminal session.

## Features

- GPU utilization (overall + per-engine: 3D, compute, copy, video, …)
- Dedicated VRAM used / total / percent (reads the driver's 64-bit registry value, so cards >4 GB report correctly — no WMI overflow)
- Shared memory usage
- Live refreshing dashboard or single snapshot for scripting
- Pure PowerShell, no dependencies, no admin rights, no GUI session

## Usage

```powershell
# Live refreshing dashboard (1s refresh), Ctrl+C to quit
powershell -ExecutionPolicy Bypass -File gpumon.ps1

# Custom refresh interval (seconds)
powershell -File gpumon.ps1 -Interval 2

# Single snapshot (good for logging / scripting)
powershell -File gpumon.ps1 -Once
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

- **Temperature, power, and clock speeds are not exposed** by the Windows WDDM counters. Those live in AMD's ADL/ADLX libraries and would require a compiled helper — out of scope for this pure-PowerShell tool.
- The "GPU Busy" figure sums all engine instances, so under heavy mixed load it can read higher than Task Manager (which shows only the single busiest engine). Use the per-engine line for the real split.
- Tested on Windows 11 with a Radeon RX 7900 XT (20 GB).

## License

MIT
