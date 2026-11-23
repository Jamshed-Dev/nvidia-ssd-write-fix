# NVIDIA SSD Write Fix — Stop NVDisplay.Container.exe High Disk Usage (Driver 621.24 / 621.14)

<p>
  <img alt="Windows 10 | 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6">
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE">
  <img alt="No download" src="https://img.shields.io/badge/install-one%20line%2C%20no%20download-brightgreen">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

**One-line fix for the NVIDIA GeForce driver bug that makes `NVDisplay.Container.exe` write tens of gigabytes per hour to your SSD — even when your PC is idle.**

If Task Manager or Resource Monitor shows **NVDisplay.Container.exe with high disk usage**, constantly rewriting `nvlog.nvlgstg`, your SSD's write endurance (TBW) is being burned in the background. This free, open-source tool measures it on your PC, fixes it in about 30 seconds **without changing your driver**, proves the fix worked, and keeps it fixed after driver updates.

> Not affiliated with NVIDIA. No driver files are hosted here. Nothing is sent anywhere.

## ⚡ Quick start

Press **Win + X → Terminal (Admin)** and paste:

```powershell
irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1 | iex
```

That's it. The tool scans your PC, tells you in plain words whether your SSD is at risk, and recommends a fix — **just press Enter**. Not running as Administrator? It opens an elevated window for you.

Prefer to read the code first? It is [one plain-text PowerShell file](nvidia-ssd-write-fix.ps1).

---

## Contents

- [Why this tool](#why-this-tool)
- [The bug](#the-bug)
- [Am I affected?](#am-i-affected)
- [What you will see](#what-you-will-see)
- [The three fixes](#the-three-fixes)
- [How the fix works](#how-the-fix-works)
- [Safety and undo](#safety-and-undo)
- [Command-line usage](#command-line-usage)
- [Manual fix without the tool](#manual-fix-without-the-tool)
- [FAQ](#faq)
- [Sources](#sources)

## Why this tool

| | |
|---|---|
| **One line, nothing to download** | Runs straight from PowerShell. No .exe, no ZIP, no SmartScreen warning. |
| **Measures, doesn't guess** | Not every PC on 621.14 / 621.24 is affected. It measures the real write rate of `NVDisplay.Container.exe` on *your* machine, with a live progress bar. |
| **Fix in 30 seconds, keep your driver** | Turns off only the buggy logging plugin. No driver reinstall needed. |
| **Proves the fix** | Re-measures after fixing and shows **Before → After**, and checks NVIDIA's own service log to confirm the plugin is no longer loaded. |
| **Stays fixed** | Driver updates silently undo the fix. Auto-protect re-applies it at startup and every hour. |
| **Full rollback option** | Downloads the clean driver from nvidia.com, verifies NVIDIA's digital signature, creates a restore point. |
| **One-key undo** | `U` removes every change and returns to NVIDIA defaults. |
| **Scriptable** | `-Scan`, `-Fix` and `-Undo` switches for IT admins and multiple PCs. |

## The bug

- **Process:** `NVDisplay.Container.exe`, run by the Windows service **NVIDIA Display Container LS** (`NVDisplay.ContainerLocalSystem`), which powers NVIDIA Control Panel and the NVIDIA App.
- **File:** `C:\ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg`. The file stays around 20 MB, but it is **rewritten over and over** instead of being appended to.
- **Culprit:** the optional `_nvtopps.dll` plugin ("NvTopps_Plugin") of the Display Container.
- **Drivers:** GeForce **621.14** and **621.24** (November 2026). **621.01** is reported clean.
- **Scale:** reports range from ~4 to 30+ GB per hour at idle; one PC we tested measured **~48 GB/hour — 796 GB in 12 hours**. The rate grows with uptime, and a reboot resets it.
- **NVIDIA status:** not publicly acknowledged at the time of writing.

## Am I affected?

| Driver | Windows shows | Status |
|---|---|---|
| 621.24 | 32.0.16.2124 | ⚠️ Reported affected |
| 621.14 | 32.0.16.2114 | ⚠️ Reported affected |
| 621.01 | 32.0.16.2101 | ✅ Reported clean |

**Symptoms**

- Resource Monitor (`Win + R` → `resmon` → Disk) shows `NVDisplay.Container.exe` writing `nvlog.nvlgstg` every few seconds while idle
- Task Manager → Details (add the *I/O write bytes* column) shows gigabytes written by `NVDisplay.Container.exe`
- SSD "Total Host Writes" / "Data Units Written" in CrystalDiskInfo climbs unusually fast

The tool checks all of this for you in 20 seconds.

## What you will see

```
  ==================================================================
    NVIDIA SSD Write Fix  v2.0
    Stops NVDisplay.Container.exe from wearing out your SSD
  ==================================================================

  GPU             NVIDIA GeForce RTX 3060
  Driver          621.24                                  [HAS THE BUG]
  Logging plugin  _nvtopps enabled (driver default)
  Auto-protect    Off
  SSD writes      47.1 GB/hour  (~1,131 GB/day)           [TOO HIGH]

  >> Your SSD is being worn out right now.
     Press Enter to fix it in about 30 seconds. You keep your current driver.

  What would you like to do?
    [1] Fix now (turn off the buggy logging plugin)   ~30 s, keeps driver, undoable  <- recommended
    [2] Roll back driver to 621.01                    ~10 min, zero side effects
    [3] Turn on auto-protect                          re-applies fix after updates
    [4] Scan again                                    20 s
    [5] Long scan                                     5 min, most accurate
    [Q] Quit
```

After the fix:

```
  Logging plugin  _nvtopps disabled                       [FIX APPLIED]
  SSD writes      0 MB/hour  (~0.0 GB/day)                [NORMAL]
  Before          47.1 GB/hour  (~1,131 GB/day)

  >> Fixed. Note: an NVIDIA driver update can silently undo this fix.
     Press Enter to turn on auto-protect, which re-applies it for you.
```

**Verdicts:** 500 MB/hour or more = bug; 50–500 MB/hour = above normal; below 50 MB/hour = normal.

## The three fixes

| | Fix now (plugin) | Roll back driver | Auto-protect |
|---|---|---|---|
| **What it does** | Sets `DisableLoad = 1` for the `_nvtopps` plugin, restarts the service, re-measures | Restore point → downloads **621.01** from nvidia.com → verifies signature → opens installer | Scheduled task (SYSTEM) at startup + hourly: re-applies the plugin fix if a driver update removed it; restarts the service if writes spike |
| **Time** | ~30 seconds | ~10 minutes + restart | Runs in background |
| **Keeps your driver** | ✅ | ❌ (goes to 621.01) | ✅ |
| **Side effects** | `_nvtopps` features are undocumented; NVIDIA App and Control Panel reported working | None | None |
| **Undo** | `U` in the menu | Install a newer driver | `3` or `U` in the menu |

Recommended path: **Fix now → Auto-protect**. If writes stay high with the fix on, the tool recommends the rollback.

## How the fix works

The NVIDIA Display Container loads a set of plugins and honours a per-plugin `DisableLoad` registry value — NVIDIA's own driver already uses it to keep other plugins (for example `NvcDispWatchdog` and `NvXDCore`) switched off. The tool sets the same value for `_nvtopps`:

```text
Key    HKLM\SYSTEM\CurrentControlSet\Services\NVDisplay.ContainerLocalSystem\Parameters\LocalSystem\_nvtopps
Value  DisableLoad   REG_DWORD   1
```

After the service restarts, NVIDIA's log `C:\ProgramData\NVIDIA\NVDisplay.ContainerLocalSystem.log` shows `Disable loading of plugin ... _nvtopps.dll`, `nvlog.nvlgstg` is no longer created, and writes drop to near zero. The tool checks that log line for you.

## Safety and undo

- **Minimal change.** One registry value. The key is only created if missing (never recreated, which would wipe its values), and the value is read back to confirm.
- **One-key undo.** `U` removes `DisableLoad`, deletes the `_nvtopps` key only if it is then empty, removes auto-protect, restarts the service and re-measures.
- **Does not** disable or remove the NVIDIA service, delete driver files, lock files, change Control Panel settings, or send any data.
- **Screen flicker.** Restarting the Display Container can make the screen flicker once. Save your work first.
- **Driver rollback** downloads only from `download.nvidia.com` and refuses to run anything not signed by NVIDIA Corporation.
- **When NVIDIA ships a fixed driver,** update and press `U` to return to defaults.

## Command-line usage

```powershell
# Report only
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1))) -Scan

# Apply the fix without prompts, then verify
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1))) -Fix

# Remove every change
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1))) -Undo

# From a downloaded copy, with a 5-minute scan
.\nvidia-ssd-write-fix.ps1 -Scan -Seconds 300
```

Or download the repository and double-click **`fix.bat`**.

## Manual fix without the tool

PowerShell **as Administrator**:

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\NVDisplay.ContainerLocalSystem\Parameters\LocalSystem\_nvtopps'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
New-ItemProperty -Path $key -Name DisableLoad -PropertyType DWord -Value 1 -Force | Out-Null
Restart-Service NVDisplay.ContainerLocalSystem -Force
```

Undo:

```powershell
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NVDisplay.ContainerLocalSystem\Parameters\LocalSystem\_nvtopps' -Name DisableLoad
Restart-Service NVDisplay.ContainerLocalSystem -Force
```

Measure how much the process has written since it started:

```powershell
Get-CimInstance Win32_Process -Filter "Name='NVDisplay.Container.exe'" |
  Select-Object ProcessId, @{n='Written GB';e={[math]::Round($_.WriteTransferCount/1GB,2)}}
```

Or roll back: download **621.01** from [NVIDIA Advanced Driver Search](https://www.nvidia.com/en-us/drivers/) → Custom (Advanced) → *Perform a clean installation*.

## FAQ

**Will NVDisplay.Container.exe actually kill my SSD?**
Not overnight. A typical 1 TB SSD is rated for 300–600 TBW. At ~48 GB/hour, a PC on 8 hours a day writes ~140 TB a year to one useless log file — enough to reach the warranty limit years early.

**Can I just delete nvlog.nvlgstg or make it read-only?**
Deleting it helps only until it grows back. Read-only does not work: the container renames the file and creates a new one.

**Can I disable the NVIDIA Display Container LS service?**
You can, but NVIDIA Control Panel and the NVIDIA App stop working. Disabling only the `_nvtopps` plugin keeps the service running.

**Does turning off logging or the overlay in the NVIDIA App help?**
It helped a few users and did nothing for others. The plugin fix stops the writes at the source.

**The tool says "All good" but I'm on 621.24.**
Some PCs are not affected, and the bug grows with uptime. If the PC was just started, use **5. Long scan** later, or apply the fix anyway — the tool recommends it for affected drivers.

**Is the write counter accurate?**
It reads `WriteTransferCount` per process — the same number Task Manager shows as *I/O write bytes*. It counts what the process asks Windows to write; in public reports it matched the SSD's own counter closely.

**Does it work on laptops, Studio drivers, RTX / Quadro professional cards?**
Yes — anywhere the NVIDIA Display Container LS service exists. Laptops get the notebook driver package for rollback.

**Does AMD have the same problem?**
AMD had a similar SSD-write bug in Adrenalin and fixed it in 26.11.1 / 26.11.2. This tool is for NVIDIA only.

**Does it send data anywhere?**
No. The only network access is the optional driver download from `download.nvidia.com` and, for auto-protect when started via the one-liner, fetching this script from GitHub.

## Compatibility

- Windows 10 and 11, x64
- Windows PowerShell 5.1 (built in) or PowerShell 7
- Any NVIDIA GPU whose driver installs NVIDIA Display Container LS

## Sources

- [Guru3D forums — root cause and `_nvtopps` DisableLoad workaround](https://www.guru3d.com/publish/comments/reports-indicate-recent-nvidia-geforce-drivers-may-generate-heavy-ssd-writes/)
- [Guru3D — driver 621.24 writes up to 30 GB per hour at idle](https://www.guru3d.com/story/reports-indicate-recent-nvidia-geforce-drivers-may-generate-heavy-ssd-writes/)
- [Windows Latest — NVDisplay.Container rewrites a log file while Windows 11 is idle](https://www.windowslatest.com/2026/11/20/first-amd-now-nvidia-your-gpu-driver-could-be-quietly-wearing-out-your-windows-11-pcs-ssd-and-nvidia-hasnt-even-admitted-it/)
- [TechPowerUp — latest NVIDIA drivers might cause excessive SSD writing](https://www.techpowerup.com/354996/latest-nvidia-drivers-might-cause-excessive-ssd-writing)
- [Wccftech — NVIDIA drivers reportedly writing up to 30 GB per hour](https://wccftech.com/nvidia-gpu-drivers-reportedly-writing-up-to-30gb-per-hour-to-ssds-echoing-amds-recent-driver-bug/)
- [The FPS Review — how to check](https://www.thefpsreview.com/?p=157530)
- [Level1Techs forum discussion](https://forum.level1techs.com/t/fyi-there-are-reports-that-recent-nvidia-windows-drivers-seems-to-be-writing-to-disk-constantly-up-to-30gb-per-hour/260813)

## Contributing

Issues and pull requests are welcome. For bug reports, include the full scan output, GPU, driver version and Windows build. If NVIDIA releases a fixed driver, please open an issue so the version list can be updated.

## License

[MIT](LICENSE). Use at your own risk. NVIDIA, GeForce and related names are trademarks of NVIDIA Corporation; this project is independent and not endorsed by NVIDIA.

<sub>Keywords: NVDisplay.Container.exe high disk usage, NVDisplay.Container.exe constant writes, NVIDIA driver SSD writes, nvlog.nvlgstg, _nvtopps, NvTopps plugin, NVIDIA Display Container LS disk usage, GeForce 621.24 SSD bug, GeForce 621.14 SSD bug, NVIDIA driver killing SSD, NVIDIA driver writing to SSD at idle, NVIDIA container 100% disk Windows 11, rollback NVIDIA driver 621.01, SSD wear TBW.</sub>
