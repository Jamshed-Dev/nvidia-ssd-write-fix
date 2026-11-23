#Requires -Version 5.1
<#
.SYNOPSIS
    Detects and fixes the NVIDIA GeForce driver bug where NVDisplay.Container.exe
    rewrites nvlog.nvlgstg and writes gigabytes per hour to the system SSD at idle.

.DESCRIPTION
    Interactive by default: scans, explains the result and recommends a fix.
      Fix now       - disables the optional _nvtopps logging plugin (DisableLoad = 1),
                      restarts the service and re-measures. Keeps your driver. Reversible.
      Roll back     - restore point, downloads driver 621.01 from nvidia.com,
                      verifies NVIDIA's signature, opens the installer.
      Auto-protect  - scheduled task that re-applies the fix after driver updates
                      and restarts the service if writes spike.
      Undo all      - removes every change this tool made.

    Not affiliated with NVIDIA. No driver files are redistributed.

.PARAMETER Seconds   Scan length in seconds (5-3600). Default 20.
.PARAMETER Scan      Print a report and exit.
.PARAMETER Fix       Apply the plugin fix without prompts, verify, exit.
.PARAMETER Undo      Remove all changes without prompts, exit.
.PARAMETER Guard     Used by the auto-protect scheduled task.

.EXAMPLE
    irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1))) -Fix
#>
[CmdletBinding()]
param(
    [int]$Seconds = 20,
    [switch]$Scan,
    [switch]$Fix,
    [switch]$Undo,
    [switch]$Guard
)

$ErrorActionPreference = 'Stop'

# ---- Configuration: update when NVIDIA ships a fixed driver -----------------
$AppVersion       = '2.1'
$AffectedVersions = @('621.14', '621.24')
$SafeVersion      = '621.01'
$DownloadBase     = 'https://us.download.nvidia.com/Windows'
$ScriptUrl        = 'https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1'
$ServiceName      = 'NVDisplay.ContainerLocalSystem'
$ProcessName      = 'NVDisplay.Container.exe'
$PluginKey        = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters\LocalSystem\_nvtopps"
$NvLogFile        = Join-Path $env:ProgramData 'NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg'
$ServiceLogFile   = Join-Path $env:ProgramData "NVIDIA\$ServiceName.log"
$BugMBh           = 500     # MB per hour at or above: bug pattern
$WarnMBh          = 50      # MB per hour at or above: elevated
$LongScanSeconds  = 300
$GuardScanSeconds = 60
$InstallDir       = Join-Path $env:ProgramData 'nvidia-ssd-write-fix'
$GuardLog         = Join-Path $InstallDir 'guard.log'
$TaskName         = 'NVIDIA SSD Write Guard'
# ------------------------------------------------------------------------------

$Seconds = [math]::Min(3600, [math]::Max(5, $Seconds))

# ================================ UI toolkit ================================
# Glyphs are built from code points so the file stays pure ASCII (safe for
# Windows PowerShell 5.1, which reads BOM-less scripts in the ANSI code page).

$UiWidth = 72
$Glyph = @{
    H  = [string][char]0x2500; V  = [string][char]0x2502
    TL = [string][char]0x250C; TR = [string][char]0x2510
    BL = [string][char]0x2514; BR = [string][char]0x2518
    DH = [string][char]0x2550; DV = [string][char]0x2551
    DTL = [string][char]0x2554; DTR = [string][char]0x2557
    DBL = [string][char]0x255A; DBR = [string][char]0x255D
    Full = [string][char]0x2588; Shade = [string][char]0x2591
    Arrow = [string][char]0x25BA; Back = [string][char]0x25C4; Dot = [string][char]0x25CF
    Up = [string][char]0x2191; Down = [string][char]0x2193; Mid = [string][char]0x00B7
}
$MenuRowWidth = 79

function Write-Seg([string]$Text, [string]$Fg = 'Gray', [string]$Bg = '') {
    if ($Bg) { Write-Host $Text -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg }
    else { Write-Host $Text -NoNewline -ForegroundColor $Fg }
}

function Get-Fitted([string]$Text, [int]$Length) {
    if ($Text.Length -gt $Length) { return $Text.Substring(0, $Length - 3) + '...' }
    return $Text.PadRight($Length)
}

function Write-Status([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
}

function Write-Step([string]$Text, [string]$Color = 'Gray') {
    $arrowColor = if ($Color -eq 'Gray') { 'Cyan' } else { $Color }
    Write-Seg ('  ' + $Glyph.Arrow + ' ') $arrowColor
    Write-Host $Text -ForegroundColor $Color
}

function Format-Rate([double]$MBh) {
    $perDayGB = $MBh * 24 / 1024
    if ($MBh -ge 1024) { return '{0:N1} GB/hour  (~{1:N0} GB/day)' -f ($MBh / 1024), $perDayGB }
    return '{0:N0} MB/hour  (~{1:N1} GB/day)' -f $MBh, $perDayGB
}

function Show-Header {
    $version = "v$AppVersion  "
    Write-Host ''
    Write-Seg ('  ' + $Glyph.DTL + ($Glyph.DH * $UiWidth) + $Glyph.DTR) Cyan; Write-Host ''
    Write-Seg ('  ' + $Glyph.DV) Cyan
    Write-Seg ('  NVIDIA SSD WRITE FIX'.PadRight($UiWidth - $version.Length)) White
    Write-Seg $version DarkGray
    Write-Seg $Glyph.DV Cyan; Write-Host ''
    Write-Seg ('  ' + $Glyph.DV) Cyan
    Write-Seg ('  Stops NVDisplay.Container.exe from wearing out your SSD'.PadRight($UiWidth)) DarkCyan
    Write-Seg $Glyph.DV Cyan; Write-Host ''
    Write-Seg ('  ' + $Glyph.DBL + ($Glyph.DH * $UiWidth) + $Glyph.DBR) Cyan; Write-Host ''
}

function Write-CardTop([string]$Title) {
    Write-Host ''
    Write-Seg ('  ' + $Glyph.TL + $Glyph.H + ' ') DarkGray
    Write-Seg $Title White
    Write-Seg (' ' + ($Glyph.H * ($UiWidth - $Title.Length - 3)) + $Glyph.TR) DarkGray
    Write-Host ''
}

function Write-CardBottom {
    Write-Seg ('  ' + $Glyph.BL + ($Glyph.H * $UiWidth) + $Glyph.BR) DarkGray
    Write-Host ''
}

# Row layout inside the card: 2 margin + 16 label + 38 value + 14 badge + 2 margin = 72
function Write-CardRow([string]$Label, [string]$Value, [string]$Badge = '', [string]$Fg = 'Black', [string]$Bg = '') {
    Write-Seg ('  ' + $Glyph.V + '  ') DarkGray
    Write-Seg $Label.PadRight(16) DarkGray
    Write-Seg (Get-Fitted $Value 38) White
    if ($Badge) {
        $padLeft = [int][math]::Floor((12 - $Badge.Length) / 2)
        Write-Seg (' ' * ($padLeft + 1) + $Badge).PadRight(14) $Fg $Bg
    } else {
        Write-Seg (' ' * 14)
    }
    Write-Seg ('  ' + $Glyph.V) DarkGray
    Write-Host ''
}

function Write-Banner([string]$Title, [string]$Fg, [string]$Bg, [string[]]$Lines = @()) {
    Write-Host ''
    Write-Seg '  '
    Write-Seg ((' ' + $Glyph.Dot + '  ' + $Title).PadRight($UiWidth + 2)) $Fg $Bg
    Write-Host ''
    foreach ($line in $Lines) { Write-Status "     $line" 'Gray' }
}

# Every row is padded to the same width so redrawing in place leaves no leftovers.
function Write-MenuItem([string]$Key, [string]$Label, [string]$Hint, [bool]$IsRecommended, [bool]$IsSelected) {
    if ($IsSelected) {
        Write-Seg ('  ' + $Glyph.Arrow) Cyan
        Write-Seg " $Key " Black Cyan
        Write-Seg ('  ' + (Get-Fitted $Label 38) + ' ') Black Cyan
    } else {
        Write-Seg '   '
        if ($IsRecommended) { Write-Seg " $Key " Black Yellow } else { Write-Seg " $Key " White DarkGray }
        $labelColor = if ($IsRecommended) { 'Yellow' } else { 'White' }
        Write-Seg ('  ' + (Get-Fitted $Label 38) + ' ') $labelColor
    }
    Write-Seg (' ' + (Get-Fitted $Hint 24)) DarkGray
    $suffix = if ($IsRecommended) { ' ' + $Glyph.Back + ' BEST' } else { '' }
    Write-Seg $suffix.PadRight($MenuRowWidth - 72) Yellow
    Write-Host ''
}

function Write-ScanProgress([double]$Elapsed, [int]$Total, [double]$WrittenMB) {
    $barWidth = 26
    $ratio = [math]::Min(1.0, $Elapsed / $Total)
    $filled = [int][math]::Floor($ratio * $barWidth)
    $rateMBh = if ($Elapsed -gt 0) { $WrittenMB / $Elapsed * 3600 } else { 0 }
    $color = if ($rateMBh -ge $BugMBh) { 'Red' } elseif ($rateMBh -ge $WarnMBh) { 'Yellow' } else { 'Green' }
    $left = [int][math]::Ceiling([math]::Max(0, $Total - $Elapsed))
    Write-Seg "`r  "
    Write-Seg 'SCANNING ' White
    Write-Seg ($Glyph.Full * $filled) $color
    Write-Seg ($Glyph.Shade * ($barWidth - $filled)) DarkGray
    Write-Seg (' {0,3}%  {1,4}s left  {2,8:N1} MB written ' -f [int]($ratio * 100), $left, $WrittenMB)
}

function Set-WindowTitle([string]$Title) {
    try { $Host.UI.RawUI.WindowTitle = $Title } catch { Write-Verbose 'Console title not supported.' }
}

# ============================== System probes ===============================

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Windows driver version 32.0.16.2124 -> NVIDIA version 621.24
function ConvertTo-NvidiaVersion([string]$WindowsVersion) {
    $parts = "$WindowsVersion".Split('.')
    if ($parts.Count -lt 4) { return $null }
    $digits = ($parts[2] + $parts[3].PadLeft(4, '0'))
    $digits = $digits.Substring($digits.Length - 5)
    return '{0}.{1}' -f $digits.Substring(0, 3), $digits.Substring(3, 2)
}

function Get-NvProcess {
    return @(Get-CimInstance Win32_Process -Filter "Name='$ProcessName'" -ErrorAction SilentlyContinue)
}

function Test-PluginDisabled {
    $value = Get-ItemProperty -Path $PluginKey -Name DisableLoad -ErrorAction SilentlyContinue
    return ($null -ne $value) -and ($value.DisableLoad -eq 1)
}

function Test-GuardInstalled {
    return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-SystemState {
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*NVIDIA*' } | Select-Object -First 1
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $version = if ($gpu) { ConvertTo-NvidiaVersion $gpu.DriverVersion } else { $null }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    return [pscustomobject]@{
        HasGpu         = [bool]$gpu
        GpuName        = if ($gpu) { $gpu.Name } else { 'Not found' }
        Version        = $version
        IsAffected     = $AffectedVersions -contains $version
        HasService     = [bool]$service
        PluginDisabled = Test-PluginDisabled
        LogExists      = Test-Path $NvLogFile
        GuardInstalled = Test-GuardInstalled
        UptimeHours    = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    }
}

# Sums per-process logical write bytes; PIDs that appear mid-scan count from zero.
function Measure-WriteRate([int]$DurationSeconds, [switch]$Quiet) {
    $start = @{}; $last = @{}
    foreach ($p in Get-NvProcess) {
        $start[[int]$p.ProcessId] = [double]$p.WriteTransferCount
        $last[[int]$p.ProcessId] = [double]$p.WriteTransferCount
    }
    if ($start.Count -eq 0) { return $null }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Milliseconds 1000
        foreach ($p in Get-NvProcess) {
            $id = [int]$p.ProcessId
            if (-not $start.ContainsKey($id)) { $start[$id] = 0.0 }
            $last[$id] = [double]$p.WriteTransferCount
        }
        if (-not $Quiet) { Write-ScanProgress $timer.Elapsed.TotalSeconds $DurationSeconds (Get-WrittenMB $start $last) }
    }
    if (-not $Quiet) { Write-Host '' }

    $mb = Get-WrittenMB $start $last
    return [math]::Round($mb / $timer.Elapsed.TotalSeconds * 3600, 1)
}

function Get-WrittenMB($Start, $Last) {
    $bytes = 0.0
    foreach ($id in $Last.Keys) { $bytes += [math]::Max(0.0, $Last[$id] - $Start[$id]) }
    return $bytes / 1MB
}

# ================================ Diagnosis =================================

function Get-Diagnosis([int]$DurationSeconds) {
    $state = Get-SystemState
    $rate = $null
    if ($state.HasGpu -and $state.HasService) {
        Write-Host ''
        Write-Step "Measuring SSD writes for $DurationSeconds seconds - keep the PC idle" DarkGray
        $rate = Measure-WriteRate $DurationSeconds
    }
    return New-Diagnosis $state $rate
}

function New-Diagnosis($State, $Rate) {
    $verdict = Get-Verdict $State $Rate
    return [pscustomobject]@{ State = $State; Rate = $Rate; Verdict = $verdict }
}

function Get-Verdict($State, $Rate) {
    if (-not $State.HasGpu) { return 'NoGpu' }
    if (-not $State.HasService -or $null -eq $Rate) { return 'NotRunning' }
    if ($Rate -ge $BugMBh) { if ($State.PluginDisabled) { return 'StillHigh' } else { return 'Bug' } }
    if ($Rate -ge $WarnMBh) { return 'Elevated' }
    if ($State.IsAffected -and -not $State.PluginDisabled) { return 'AtRisk' }
    if ($State.IsAffected -and -not $State.GuardInstalled) { return 'FixedUnguarded' }
    return 'Clean'
}

function Get-RecommendedChoice($Diagnosis) {
    $s = $Diagnosis.State
    switch ($Diagnosis.Verdict) {
        'Bug'            { return '1' }
        'AtRisk'         { return '1' }
        'StillHigh'      { return '2' }
        'Elevated'       { if ($s.PluginDisabled) { return '5' } else { return '1' } }
        'FixedUnguarded' { return '3' }
        default          { return 'Q' }
    }
}

function Show-StateRows($State) {
    Write-CardRow 'GPU' $State.GpuName
    if ($State.IsAffected -and $State.PluginDisabled) { Write-CardRow 'Driver' $State.Version 'BUG BLOCKED' Black DarkYellow }
    elseif ($State.IsAffected) { Write-CardRow 'Driver' $State.Version 'HAS THE BUG' White DarkRed }
    elseif ($State.Version -eq $SafeVersion) { Write-CardRow 'Driver' $State.Version 'CLEAN' Black Green }
    else { Write-CardRow 'Driver' $State.Version 'NOT REPORTED' Gray DarkGray }
    if ($State.PluginDisabled) { Write-CardRow 'Logging plugin' '_nvtopps disabled' 'FIX APPLIED' Black Green }
    else { Write-CardRow 'Logging plugin' '_nvtopps enabled (driver default)' }
    if ($State.GuardInstalled) { Write-CardRow 'Auto-protect' 'Watching in the background' 'ON' Black Green }
    else { Write-CardRow 'Auto-protect' 'Off' }
}

function Show-RateRows($Diagnosis, $Before) {
    if ($null -eq $Diagnosis.Rate) { Write-CardRow 'SSD writes' "$ProcessName not running"; return }
    switch ($Diagnosis.Verdict) {
        { $_ -in 'Bug', 'StillHigh' } { Write-CardRow 'SSD writes' (Format-Rate $Diagnosis.Rate) 'TOO HIGH' White Red; break }
        'Elevated' { Write-CardRow 'SSD writes' (Format-Rate $Diagnosis.Rate) 'ABOVE NORMAL' Black Yellow; break }
        default { Write-CardRow 'SSD writes' (Format-Rate $Diagnosis.Rate) 'NORMAL' Black Green }
    }
    if ($null -ne $Before -and $null -ne $Before.Rate) { Write-CardRow 'Before' (Format-Rate $Before.Rate) }
}

function Show-Report($Diagnosis, $Before = $null) {
    if ($Diagnosis.State.HasGpu) {
        Write-CardTop 'YOUR PC'
        Show-StateRows $Diagnosis.State
        Show-RateRows $Diagnosis $Before
        Write-CardBottom
    }
    Show-Advice $Diagnosis
}

function Show-Advice($Diagnosis) {
    $s = $Diagnosis.State
    switch ($Diagnosis.Verdict) {
        'NoGpu' { Write-Banner 'NO NVIDIA GRAPHICS CARD FOUND' White DarkGray @('This tool is not needed on this PC.') }
        'NotRunning' { Write-Banner 'NOTHING TO MEASURE' White DarkGray @('NVIDIA Display Container is not running on this PC.') }
        'Bug' { Write-Banner 'YOUR SSD IS BEING WORN OUT RIGHT NOW' White DarkRed @(
                'Press Enter to fix it in about 30 seconds. You keep your current driver.') }
        'StillHigh' { Write-Banner 'WRITES ARE STILL HIGH WITH THE FIX ON' White DarkRed @(
                "Press Enter to roll back to driver $SafeVersion - this fixes it for sure.") }
        'Elevated' {
            $next = if ($s.PluginDisabled) { 'Press Enter for a 5-minute scan to be sure.' } else { 'Press Enter to apply the fix now.' }
            Write-Banner 'WRITES ARE ABOVE NORMAL' Black DarkYellow @('The bug grows the longer the PC stays on.', $next) }
        'AtRisk' {
            $lines = @('Writes are normal right now, but the bug builds up over time.')
            if ($s.UptimeHours -lt 2) { $lines += "This PC was started $($s.UptimeHours) h ago, so the bug may not show yet." }
            Write-Banner 'YOUR DRIVER HAS THE BUG' Black DarkYellow ($lines + 'Press Enter to fix it before it starts.') }
        'FixedUnguarded' { Write-Banner 'FIXED - YOUR SSD IS SAFE' Black Green @(
                'An NVIDIA driver update can silently undo this fix.',
                'Press Enter to turn on auto-protect, which re-applies it for you.') }
        default {
            $lines = if ($s.GuardInstalled) { @('Auto-protect keeps it that way, even after driver updates.') } else { @() }
            Write-Banner 'ALL GOOD - YOUR SSD IS SAFE' Black Green $lines }
    }
}

# ================================= Actions ==================================

function Restart-NvService {
    Write-Step 'Restarting NVIDIA Display Container (the screen may flicker)'
    Restart-Service -Name $ServiceName -Force
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 15) {
        if ((Get-NvProcess).Count -gt 0) { Start-Sleep -Seconds 2; return }
        Start-Sleep -Milliseconds 500
    }
    Write-Step 'The service restarted but its process did not come back within 15 s.' Yellow
}

function Enable-PluginFix {
    if (-not (Test-Path $PluginKey)) {
        # Only create when missing: -Force on an existing key would wipe its values.
        New-Item -Path $PluginKey -Force | Out-Null
    }
    New-ItemProperty -Path $PluginKey -Name DisableLoad -PropertyType DWord -Value 1 -Force | Out-Null
    if (-not (Test-PluginDisabled)) { throw 'Could not write the registry value (read-back failed).' }
}

function Disable-PluginFix {
    if (-not (Test-Path $PluginKey)) { return }
    Remove-ItemProperty -Path $PluginKey -Name DisableLoad -ErrorAction SilentlyContinue
    $key = Get-Item -Path $PluginKey
    if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -Path $PluginKey }
}

function Test-PluginSkippedInLog {
    if (-not (Test-Path $ServiceLogFile)) { return $false }
    # Only the latest _nvtopps line counts; older runs may have left a stale "Disable" line.
    $last = Get-Content $ServiceLogFile -Tail 3000 -ErrorAction SilentlyContinue |
        Select-String -Pattern '_nvtopps\.dll' | Select-Object -Last 1
    return ($null -ne $last) -and ($last.Line -match 'Disable loading of plugin')
}

function Invoke-PluginFix {
    Write-Step 'Turning off the _nvtopps logging plugin (one registry value)'
    Enable-PluginFix
    Restart-NvService
    Remove-Item $NvLogFile -Force -ErrorAction SilentlyContinue
    if (Test-PluginSkippedInLog) { Write-Step "Confirmed by NVIDIA's own service log: plugin no longer loaded" Green }
    Write-Step 'Fix applied. Measuring again to verify...' Green
}

function Invoke-UndoAll {
    Write-Step 'Removing all changes made by this tool'
    Uninstall-Guard
    Disable-PluginFix
    Restart-NvService
    Write-Step 'Done. Everything is back to the NVIDIA defaults.' Green
}

function Test-IsLaptop {
    return [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
}

function Get-DriverUrl {
    $formFactor = if (Test-IsLaptop) { 'notebook' } else { 'desktop' }
    return "$DownloadBase/$SafeVersion/$SafeVersion-$formFactor-win10-win11-64bit-international-dch-whql.exe"
}

function New-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Before NVIDIA $SafeVersion rollback" -RestorePointType MODIFY_SETTINGS
        Write-Step 'System Restore Point created.' Green
    } catch {
        Write-Step "Could not create a restore point ($($_.Exception.Message)). Continuing." Yellow
    }
}

function Get-VerifiedInstaller([string]$Url) {
    $dir = Join-Path $env:USERPROFILE "Downloads\nvidia-$SafeVersion"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $installer = Join-Path $dir (Split-Path $Url -Leaf)
    if (-not (Test-Path $installer)) {
        Write-Step "Downloading NVIDIA $SafeVersion from nvidia.com (about 1 GB)"
        Start-BitsTransfer -Source $Url -Destination $installer
    }
    $signature = Get-AuthenticodeSignature $installer
    $signer = "$($signature.SignerCertificate.Subject)"
    if ($signature.Status -ne 'Valid' -or $signer -notlike '*O=NVIDIA Corporation*') {
        Remove-Item $installer -Force
        throw "Signature check failed ($($signature.Status)). The file was deleted."
    }
    Write-Step 'Signature verified: NVIDIA Corporation.' Green
    return $installer
}

function Invoke-Rollback {
    if ((Get-SystemState).Version -eq $SafeVersion) { Write-Step "Driver $SafeVersion is already installed." Green; return }
    $url = Get-DriverUrl
    try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null }
    catch {
        Write-Step "Driver package not found at $url" Red
        Write-Step "Download $SafeVersion manually: https://www.nvidia.com/en-us/drivers/" Yellow
        return
    }
    New-RestorePoint
    $installer = Get-VerifiedInstaller $url
    Write-Banner 'THE NVIDIA INSTALLER OPENS NOW' Black Cyan @(
        'NVIDIA Graphics Driver -> Agree -> Custom (Advanced)',
        '-> tick "Perform a clean installation" -> Next -> Restart',
        'Then turn off automatic driver updates in the NVIDIA App.')
    Start-Process -FilePath $installer
}

# =============================== Auto-protect ===============================

function Install-Guard {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir 'nvidia-ssd-write-fix.ps1'
    # Run from a file: copy it. Run via "irm | iex": there is no file, so fetch it.
    if ($PSCommandPath) { Copy-Item -Path $PSCommandPath -Destination $target -Force }
    else { Invoke-WebRequest -Uri $ScriptUrl -OutFile $target -UseBasicParsing }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Guard"
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $atStartup.Delay = 'PT2M'
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStartup, $hourly) `
        -Principal $principal -Force | Out-Null
    Write-Step 'Auto-protect is on. It runs at startup and every hour.' Green
    Write-Step "Log: $GuardLog" DarkGray
}

function Uninstall-Guard {
    if (-not (Test-GuardInstalled)) { return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step 'Auto-protect is off.' Green
}

function Write-GuardLog([string]$Message) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Add-Content $GuardLog ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Invoke-Guard {
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { Write-GuardLog 'service missing, skipped'; return }
    if (-not (Test-PluginDisabled)) {
        Enable-PluginFix
        Restart-NvService
        Write-GuardLog 'fix was missing (driver update?) -> re-applied'
    }
    $rate = Measure-WriteRate $GuardScanSeconds -Quiet
    if ($null -ne $rate -and $rate -ge $BugMBh) {
        Restart-NvService
        Remove-Item $NvLogFile -Force -ErrorAction SilentlyContinue
        Write-GuardLog "$rate MB/h -> service restarted"
    } else {
        Write-GuardLog "$rate MB/h ok"
    }
}

# =================================== Menu ===================================

function Get-MenuOptions($State) {
    $guardLabel = if ($State.GuardInstalled) { 'Turn off auto-protect' } else { 'Turn on auto-protect' }
    $options = @(
        @('1', 'Fix now (turn off the buggy plugin)', '~30 s, keeps your driver'),
        @('2', "Roll back driver to $SafeVersion", 'clean driver, ~10 min'),
        @('3', $guardLabel, 'survives driver updates'),
        @('4', 'Scan again', "$Seconds s"),
        @('5', 'Long scan', "$([int]($LongScanSeconds / 60)) min, most accurate")
    )
    if ($State.PluginDisabled -or $State.GuardInstalled) { $options += , @('U', 'Undo all changes', 'back to NVIDIA defaults') }
    $options += , @('Q', 'Quit', '')
    return , $options
}

function Get-OptionIndex($Options, [string]$Key) {
    for ($i = 0; $i -lt $Options.Count; $i++) { if ($Options[$i][0] -eq $Key) { return $i } }
    return 0
}

function Write-MenuItems($Options, [string]$Recommended, [int]$SelectedIndex) {
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        Write-MenuItem $o[0] $o[1] $o[2] ($o[0] -eq $Recommended) ($i -eq $SelectedIndex)
    }
}

function Show-Options([string]$Recommended, $State) {
    $options = Get-MenuOptions $State
    Write-Host ''
    Write-Status '  WHAT WOULD YOU LIKE TO DO?' White
    Write-Host ''
    Write-MenuItems $options $Recommended (Get-OptionIndex $options $Recommended)
    Write-Host ''
    $keys = ($options | ForEach-Object { $_[0] } | Where-Object { $_ -match '\d' }) -join ''
    Write-Status ("  {0}{1} move  {2}  Enter select  {2}  {3}-{4} or letter shortcut  {2}  Esc quit" -f `
        $Glyph.Up, $Glyph.Down, $Glyph.Mid, $keys[0], $keys[-1]) DarkGray
}

# Runs one menu action; returns the new diagnosis (rescans only when writes may have changed).
function Invoke-MenuAction([string]$Choice, $Diagnosis) {
    switch ($Choice) {
        '1' { Invoke-PluginFix; return Get-Diagnosis $Seconds }
        '2' { Invoke-Rollback }
        '3' { if ($Diagnosis.State.GuardInstalled) { Uninstall-Guard } else { Install-Guard } }
        '4' { return Get-Diagnosis $Seconds }
        '5' { return Get-Diagnosis $LongScanSeconds }
        'U' { Invoke-UndoAll; return Get-Diagnosis $Seconds }
    }
    return New-Diagnosis (Get-SystemState) $Diagnosis.Rate
}

function Get-ValidChoices($State) {
    $valid = @('1', '2', '3', '4', '5', 'Q')
    if ($State.PluginDisabled -or $State.GuardInstalled) { $valid += 'U' }
    return $valid
}

# Typed fallback for hosts without key-by-key input (redirected stdin, ISE).
function Read-Choice([string]$Recommended) {
    Write-Host ''
    Write-Seg ('  ' + $Glyph.Arrow + ' ') Yellow
    Write-Seg 'Your choice ' White
    Write-Seg "(Enter = $Recommended): " DarkGray
    $choice = Read-Host
    if ($null -eq $choice) { return 'Q' }
    $choice = $choice.Trim().ToUpper()
    if ($choice -eq '') { return $Recommended }
    return $choice
}

function Test-ArrowKeysSupported {
    try { return ($Host.Name -eq 'ConsoleHost') -and -not [Console]::IsInputRedirected }
    catch { return $false }
}

# Pure key handling: returns @{ Index = new highlight } or @{ Choice = key to run }.
function Resolve-MenuKey($Options, [int]$Selected, [string]$KeyName, [string]$KeyChar) {
    $count = $Options.Count
    switch ($KeyName) {
        'UpArrow'   { return @{ Index = ($Selected - 1 + $count) % $count } }
        'DownArrow' { return @{ Index = ($Selected + 1) % $count } }
        'Home'      { return @{ Index = 0 } }
        'End'       { return @{ Index = $count - 1 } }
        'Enter'     { return @{ Choice = $Options[$Selected][0] } }
        'Escape'    { return @{ Choice = 'Q' } }
    }
    $typed = "$KeyChar".ToUpper()
    if ($typed -and $Options[(Get-OptionIndex $Options $typed)][0] -eq $typed) { return @{ Choice = $typed } }
    return @{ Index = $Selected }
}

# Arrow-key selection over the menu that Show-Options just drew (rows end 2 lines above the cursor).
function Select-MenuOption($Options, [string]$Recommended) {
    $selected = Get-OptionIndex $Options $Recommended
    $bottom = [Console]::CursorTop
    $top = $bottom - 2 - $Options.Count
    $cursorWasVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $result = Resolve-MenuKey $Options $selected "$($key.Key)" "$($key.KeyChar)"
            if ($result.ContainsKey('Choice')) { return $result.Choice }
            if ($result.Index -eq $selected) { continue }
            $selected = $result.Index
            [Console]::SetCursorPosition(0, $top)
            Write-MenuItems $Options $Recommended $selected
            [Console]::SetCursorPosition(0, $bottom)
        }
    } finally {
        [Console]::CursorVisible = $cursorWasVisible
    }
}

function Get-MenuChoice($State, [string]$Recommended) {
    if (-not (Test-ArrowKeysSupported)) { return Read-Choice $Recommended }
    $options = Get-MenuOptions $State
    $choice = Select-MenuOption $options $Recommended
    $label = $options[(Get-OptionIndex $options $choice)][1]
    Write-Host ''
    Write-Step "Selected: $label" Cyan
    return $choice
}

function Show-Menu {
    $originalTitle = $Host.UI.RawUI.WindowTitle
    Set-WindowTitle "NVIDIA SSD Write Fix v$AppVersion"
    Clear-Host
    Show-Header
    $diagnosis = Get-Diagnosis $Seconds
    $before = $null
    while ($true) {
        Show-Report $diagnosis $before
        if (-not $diagnosis.State.HasGpu) { break }
        $recommended = Get-RecommendedChoice $diagnosis
        Show-Options $recommended $diagnosis.State
        $choice = Get-MenuChoice $diagnosis.State $recommended
        if ($choice -eq 'Q') { Write-Step 'Bye! Your SSD thanks you.' Cyan; break }
        if ((Get-ValidChoices $diagnosis.State) -notcontains $choice) {
            Write-Step 'Please type one of the keys shown.' Yellow
            continue
        }
        Write-Host ''
        $before = if ($choice -in '1', 'U') { $diagnosis } else { $null }
        try { $diagnosis = Invoke-MenuAction $choice $diagnosis }
        catch { Write-Step "Something went wrong: $($_.Exception.Message)" Red; $before = $null }
    }
    Set-WindowTitle $originalTitle
}

# ============================ Non-interactive CLI ===========================

function Invoke-Cli {
    Show-Header
    $diagnosis = Get-Diagnosis $Seconds
    if ($Fix -and $diagnosis.State.HasService) {
        $before = $diagnosis
        Invoke-PluginFix
        $diagnosis = Get-Diagnosis $Seconds
        Show-Report $diagnosis $before
    } elseif ($Undo) {
        Invoke-UndoAll
        Show-Report (Get-Diagnosis $Seconds)
    } else {
        Show-Report $diagnosis
    }
}

# =================================== Entry ==================================

function Start-Elevated {
    $flags = (@('Scan', 'Fix', 'Undo') | Where-Object { (Get-Variable $_ -ValueOnly).IsPresent } | ForEach-Object { "-$_" }) -join ' '
    $source = if ($PSCommandPath) { "-File `"$PSCommandPath`" $flags" }
              else { "-Command `"& ([scriptblock]::Create((irm '$ScriptUrl'))) $flags`"" }
    Write-Status 'Administrator rights are required. Opening an elevated PowerShell window...' 'Yellow'
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit $source" }
    catch { Write-Status 'Elevation was cancelled. Run PowerShell as Administrator and try again.' 'Red' }
}

# 'return' rather than 'exit' so "irm | iex" never closes the user's console.
if (-not (Test-IsAdmin)) { Start-Elevated; return }

if ($Guard) { Invoke-Guard }
elseif ($Scan -or $Fix -or $Undo) { Invoke-Cli }
else { Show-Menu }
