# NVIDIA SSD Write Fix — Stop NVDisplay.Container.exe High Disk Usage (Driver 621.24 / 621.14)

**One-click fix for the NVIDIA GeForce driver bug that makes `NVDisplay.Container.exe` write up to 30–50 GB per hour to your SSD, even when your PC is idle.**

If Resource Monitor or Task Manager shows **NVDisplay.Container.exe with high disk usage**, constantly writing to `nvlog.nvlgstg`, your SSD is being worn out in the background. This free, open-source PowerShell tool checks your PC, stops the writes in seconds, and can safely roll your driver back to a version without the bug.

> Not affiliated with NVIDIA. No driver files are hosted here — the driver is downloaded directly from NVIDIA's official servers and its digital signature is verified.

## ⚡ Quick start — one line, nothing to download

Press **Win + X → Terminal (Admin)** (or Windows PowerShell (Admin)) and paste:

```powershell
irm https://raw.githubusercontent.com/USERNAME/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1 | iex
```

The menu opens instantly. Choose **1** to check, **2** to stop the writes now, **3** for the permanent fix. If you are not running as Administrator, the tool opens an elevated window for you.

Prefer to read the code first? [View the script](nvidia-ssd-write-fix.ps1) — it is a single plain-text PowerShell file.

---

## Table of contents

- [Quick start (one line)](#-quick-start--one-line-nothing-to-download)
- [Symptoms](#symptoms)
- [Am I affected?](#am-i-affected)
- [One-click fix](#one-click-fix)
- [What each option does](#what-each-option-does)
- [Manual fix (without the tool)](#manual-fix-without-the-tool)
- [FAQ](#faq)

---

## Symptoms

- `NVDisplay.Container.exe` (service **NVIDIA Display Container LS**) shows constant disk writes in Resource Monitor → Disk tab
- The file being written is `C:\ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg`
- Writes continue while the PC is idle — reported at **4–30 GB/hour**; one tested PC measured **~48 GB/hour** (796 GB in 12 hours)
- SSD "Data Units Written" / TBW in CrystalDiskInfo climbs unusually fast
- Started after installing **GeForce Game Ready / Studio driver 621.14 or 621.24** (November 2026)

## Am I affected?

| Driver version | Windows shows | Status |
|---|---|---|
| 621.24 | 32.0.16.2124 | ⚠️ Affected |
| 621.14 | 32.0.16.2114 | ⚠️ Affected |
| 621.01 | 32.0.16.2101 | ✅ Reported OK |

Fastest check: run `fix.bat` and choose **1. Check**. It measures the real write rate of `NVDisplay.Container.exe` over 10 seconds and tells you if it is excessive.

## One-click fix

Alternative to the one-line command above:

1. Download this repository: **Code → Download ZIP**, then extract it
2. Double-click **`fix.bat`** (click **Yes** on the administrator prompt)
3. Pick an option:

```
=== NVIDIA SSD Write Fix ===
1. Check (driver version + live SSD write rate)
2. Quick fix (restart service, stop writes now)
3. Permanent fix (roll back to driver 621.01)
4. Install auto-guard (hourly check, auto-restart)
5. Remove auto-guard
```

Recommended: **1 → 2 → 3**.

## What each option does

| Option | What happens | Permanent? |
|---|---|---|
| **1. Check** | Shows GPU, driver version, and live MB/s written by NVDisplay.Container.exe | — |
| **2. Quick fix** | Restarts *NVIDIA Display Container LS* and resets the runaway `nvlog.nvlgstg` log. Writes drop immediately (tested: 13.4 MB/s → 0.27 MB/s) | No — the bug can return |
| **3. Permanent fix** | Creates a System Restore Point, downloads driver **621.01** from `download.nvidia.com` (desktop or laptop package auto-detected), verifies the NVIDIA digital signature, and opens the installer | Yes |
| **4. Auto-guard** | Scheduled task that checks every hour and restarts the service if writes exceed 2 MB/s. Log: `C:\ProgramData\nvidia-ssd-write-fix\guard.log` | Yes, while installed |
| **5. Remove auto-guard** | Deletes the scheduled task and its files | — |

In the NVIDIA installer choose **Custom (Advanced) → Perform a clean installation**, then restart. Afterwards **turn off automatic driver updates in the NVIDIA App** so 621.24 is not reinstalled, and update again only once NVIDIA's release notes mention a fix.

## Manual fix (without the tool)

Open PowerShell **as Administrator**:

```powershell
# Check driver version
Get-CimInstance Win32_VideoController | Where-Object Name -like '*NVIDIA*' | Select-Object Name, DriverVersion

# Temporary fix: restart the service
Stop-Service NVDisplay.ContainerLocalSystem -Force
Remove-Item "$env:ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg" -ErrorAction SilentlyContinue
Start-Service NVDisplay.ContainerLocalSystem
```

Permanent fix: download **621.01** from [NVIDIA Advanced Driver Search](https://www.nvidia.com/en-us/drivers/) and do a clean installation.

Turning off NVIDIA App overlay / Instant Replay has reduced writes for some users. Disabling the NVIDIA Display Container service entirely is **not** recommended: it breaks NVIDIA Control Panel and the NVIDIA App.

## FAQ

**Will NVDisplay.Container.exe actually kill my SSD?**
A typical 1 TB SSD is rated for 300–600 TBW. At ~48 GB/hour and 8 hours a day, that is ~140 TB per year, which uses up the rated endurance years early. Nothing breaks overnight, but it is real wear.

**Is it safe to roll back the driver?**
Yes. 621.01 is an official, WHQL-signed NVIDIA driver. The tool also creates a restore point first.

**Does this work on laptops?**
Yes. The tool detects a battery and downloads the notebook package.

**Does this affect AMD?**
AMD had a similar SSD-write bug in Adrenalin, fixed in 26.11.1 / 26.11.2. This tool is for NVIDIA only.

**When will NVIDIA fix it?**
At the time of writing NVIDIA has not acknowledged the bug. When a fixed driver is released, this repo will be updated.

**Is this related to `nvcontainer.exe` high CPU or NVIDIA Container high disk usage?**
This tool targets the **disk write** bug in `NVDisplay.Container.exe` specifically, though the check will show you whether it is the cause.

---

## Sources

- [Windows Latest — NVDisplay.Container rewrites a log file while Windows 11 is idle](https://www.windowslatest.com/2026/11/20/first-amd-now-nvidia-your-gpu-driver-could-be-quietly-wearing-out-your-windows-11-pcs-ssd-and-nvidia-hasnt-even-admitted-it/)
- [Guru3D — driver 621.24 writes up to 30 GB per hour at idle](https://www.guru3d.com/story/reports-indicate-recent-nvidia-geforce-drivers-may-generate-heavy-ssd-writes/)
- [TechPowerUp — latest NVIDIA drivers might cause excessive SSD writing](https://www.techpowerup.com/354996/latest-nvidia-drivers-might-cause-excessive-ssd-writing)
- [The FPS Review — how to check](https://www.thefpsreview.com/?p=157530)

## License

[MIT](LICENSE). Use at your own risk. NVIDIA, GeForce and related names are trademarks of NVIDIA Corporation; this project is independent and not endorsed by NVIDIA.

<!-- Keywords: NVDisplay.Container.exe high disk usage, NVIDIA driver SSD writes, nvlog.nvlgstg, NVIDIA Display Container LS disk usage, GeForce 621.24 bug, GeForce 621.14 SSD, NVIDIA driver killing SSD, NVIDIA container 100% disk Windows 11, rollback NVIDIA driver 621.01 -->
