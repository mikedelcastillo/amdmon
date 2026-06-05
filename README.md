# amdmon

A **btop-style, full-screen system monitor for Windows terminals** — CPU, RAM, GPU and VRAM usage, **CPU & GPU temperatures**, and **network up/down throughput**, each with a scrolling history graph (MSI Afterburner / RivaTuner style). Built specifically to work over **SSH**, where every GUI tool is useless and the popular terminal monitors don't support AMD.

![amdmon](https://img.shields.io/badge/platform-Windows-blue) ![shell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)

## The problem

I have a **Radeon RX 7900 XT (20 GB)** in a Windows 11 box that I manage headless over SSH, and there was no good way to watch GPU/VRAM/temps:

- **`bottom` (`btm`) and `btop`** only read AMD GPUs on **Linux** (via `/sys/class/drm`). On Windows they support **NVIDIA only**, so the 7900 XT never shows up.
- **Task Manager, AMD Software: Adrenalin, HWiNFO, GPU-Z, MSI Afterburner** all need an interactive desktop session. Over SSH there's no desktop, so they're out.
- **`rocm-smi` / `nvtop`** are Linux tools.
- `Win32_VideoController.AdapterRAM` (the usual WMI query) **overflows for cards >4 GB**, reporting the 20 GB card as only ~4 GB.
- **Temperatures aren't in the Windows performance counters at all** — on Ryzen they need a kernel-level driver to read.

So: a card that's well supported on Linux, in a Windows machine, accessed over a terminal, had effectively zero monitoring options.

## The solution

`amdmon` renders a full-screen dashboard with a 2×4 grid of panels, each showing a live value and a scrolling history graph:

```
CPU usage        │ RAM usage
GPU usage        │ VRAM usage
CPU temperature  │ GPU temperature
Network down     │ Network up
```

Data comes from **[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)** (the open-source library behind many Windows monitors), which reads CPU/GPU load, temperatures, and VRAM directly — including Ryzen CPU temps and AMD GPU temps that no standard Windows API exposes. The library is **downloaded automatically to `.\lib` on first run**; you don't check it in or install anything by hand. If it can't be loaded, `amdmon` falls back to Windows performance counters for usage and shows temperatures as `n/a`.

The rendering uses ANSI true-color and redraws in place, so it **fills the whole terminal and never flashes**, even at a 100 ms refresh.

## Features

- **Full-screen TUI** that uses the entire terminal width and height, with a warning when the window is too small
- **CPU / RAM / GPU / VRAM usage**, **CPU / GPU temperatures**, and **network down/up throughput**, each with a scrolling **history graph** and a green→yellow→red gradient
- **Auto-scaling network graphs** — the down/up panels scale to their recent peak (with a sensible floor), so both a trickle and a saturated link stay readable
- **Component names** shown inline — CPU model, GPU model, RAM size/type/speed, and the active network adapter
- **~100 ms refresh**, flicker-free (in-place ANSI redraw)
- Correct VRAM total on cards >4 GB
- Single-snapshot mode (`-Once`) for logging/scripting
- Works over SSH on Windows for AMD, NVIDIA, and Intel GPUs

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- A terminal that supports ANSI true-color (Windows Terminal, recent conhost, most SSH clients)
- **Administrator** for temperatures — they load a signed kernel driver. Without admin, usage still works and temps show `n/a`.
- Internet access on first run (to download the monitoring library, ~1.5 MB, from NuGet)

## Install

```powershell
git clone https://github.com/mikedelcastillo/amdmon.git
cd amdmon
```

## Usage

Run as **Administrator** to get temperatures:

```powershell
# Full-screen dashboard, ~100 ms refresh. Press q or Ctrl+C to quit.
powershell -ExecutionPolicy Bypass -File amdmon.ps1

# Slower refresh (seconds)
powershell -File amdmon.ps1 -Interval 1

# Single text snapshot (good for logging / scripting)
powershell -File amdmon.ps1 -Once

# Skip the temperature library entirely (usage only, via perf counters)
powershell -File amdmon.ps1 -NoTemp

# Just pre-download the libraries and exit
powershell -File amdmon.ps1 -EnsureDeps
```

### Run `amdmon` from anywhere

Install the `amdmon` command once and call it from any directory (handy after you SSH in):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
. $PROFILE   # reload the profile (or just open a new PowerShell window)
```

This pre-downloads the libraries and adds a small function to your PowerShell `$PROFILE` that runs `amdmon.ps1` **by path**, so:

- it works from any directory, and
- it always runs your current `amdmon.ps1` — edit the script and the change takes effect on the next run, no re-install needed (unless you move the repo, then just re-run `install.ps1`).

Then use it like the script itself:

```powershell
amdmon              # full-screen dashboard, q to quit
amdmon -Interval 1  # custom refresh interval
amdmon -Once        # single snapshot
```

Notes:

- PowerShell-only (works in any PowerShell session, including over SSH); not available from `cmd.exe`.
- Your execution policy must allow local scripts (`RemoteSigned` or `Unrestricted`).

To remove the command later:

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

### Example output (`-Once`)

```
CPU   AMD Ryzen 7 3700X 8-Core Processor    6.2%   53°C
GPU   AMD Radeon RX 7900 XT                 0.0%   41°C
MEM   64 GB DDR4-2667 (4x)                  9.9%   6.3 / 64 GB
VRAM  Video Memory                         21.4%   4.3 / 20 GB
NET   Realtek PCIe GbE Family Controller     7.5 KB/s   down
NET   Realtek PCIe GbE Family Controller   271.3 KB/s   up
```

The live dashboard shows the same data as eight bordered panels, each with a scrolling history graph filling the screen.

## How it works

- **Usage, temps, VRAM** come from `LibreHardwareMonitorLib` (CPU `CPU Total` load, `Core (Tctl/Tdie)` temp; GPU `GPU Core` load + temp; `GPU Memory Used/Total`).
- **System RAM** uses the `Memory\Available Bytes` performance counter plus total physical memory from WMI — this avoids pulling in LibreHardwareMonitor's extra SPD dependency.
- **Network down/up** come from the built-in `Network Interface\Bytes Received/sec` and `Bytes Sent/sec` performance counters, summed across all physical adapters (loopback/tunnel/virtual interfaces are filtered out). This is a native Windows data source, so the feature adds **no new dependency** — nothing extra to download or install.
- The library DLLs are fetched from NuGet on first run and cached in `.\lib` (git-ignored). Version mismatches between the library and Windows PowerShell's .NET Framework are bridged with an `AssemblyResolve` handler.

## Notes & limitations

- **Temperatures need Administrator.** LibreHardwareMonitor loads a signed kernel driver to read Ryzen/AMD sensors. Run the shell elevated, or accept `n/a` temps.
- If the library can't be downloaded or loaded, `amdmon` still runs: usage via WDDM performance counters, temperatures as `n/a`.
- The terminal must support ANSI true-color for the colored graphs to render correctly.
- Tested on Windows 11 with a Radeon RX 7900 XT (20 GB) and a Ryzen 7 3700X.

## License

MIT — see [LICENSE](LICENSE).
