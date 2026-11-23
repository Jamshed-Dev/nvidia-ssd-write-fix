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
$AppVersion       = '2.0'
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

# ============================== Output helpers ==============================

function Write-Status([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
}

function Write-Row([string]$Label, [string]$Value, [string]$Tag = '', [string]$TagColor = 'Gray') {
    Write-Host ('  {0,-16}' -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0,-40}' -f $Value) -NoNewline
    Write-Host $Tag -ForegroundColor $TagColor
}

function Format-Rate([double]$MBh) {
    $perDayGB = $MBh * 24 / 1024
    if ($MBh -ge 1024) { return '{0:N1} GB/hour  (~{1:N0} GB/day)' -f ($MBh / 1024), $perDayGB }
    return '{0:N0} MB/hour  (~{1:N1} GB/day)' -f $MBh, $perDayGB
}

function Show-Header {
    Write-Host ''
    Write-Host '  ==================================================================' -ForegroundColor Cyan
    Write-Host "    NVIDIA SSD Write Fix  v$AppVersion" -ForegroundColor Cyan
    Write-Host '    Stops NVDisplay.Container.exe from wearing out your SSD' -ForegroundColor DarkCyan
    Write-Host '  ==================================================================' -ForegroundColor Cyan
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

function Write-ScanProgress([double]$Elapsed, [int]$Total, [double]$WrittenMB) {
    $ratio = [math]::Min(1.0, $Elapsed / $Total)
    $filled = [int][math]::Floor($ratio * 30)
    $rateMBh = if ($Elapsed -gt 0) { $WrittenMB / $Elapsed * 3600 } else { 0 }
    $color = if ($rateMBh -ge $BugMBh) { 'Red' } elseif ($rateMBh -ge $WarnMBh) { 'Yellow' } else { 'Green' }
    $left = [int][math]::Ceiling([math]::Max(0, $Total - $Elapsed))
    Write-Host ("`r  [") -NoNewline
    Write-Host ('#' * $filled) -NoNewline -ForegroundColor $color
    Write-Host ('.' * (30 - $filled)) -NoNewline -ForegroundColor DarkGray
    Write-Host ('] {0,3}%  {1,4}s left  {2,9:N1} MB written ' -f [int]($ratio * 100), $left, $WrittenMB) -NoNewline
}

# ================================ Diagnosis =================================

function Get-Diagnosis([int]$DurationSeconds) {
    $state = Get-SystemState
    $rate = $null
    if ($state.HasGpu -and $state.HasService) {
        Write-Status "`n  Measuring SSD writes for $DurationSeconds seconds. Keep the PC idle..." 'DarkGray'
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
    Write-Host ''
    Write-Row 'GPU' $State.GpuName
    if ($State.IsAffected) { Write-Row 'Driver' $State.Version '[HAS THE BUG]' 'Red' }
    elseif ($State.Version -eq $SafeVersion) { Write-Row 'Driver' $State.Version '[CLEAN]' 'Green' }
    else { Write-Row 'Driver' $State.Version '[NOT REPORTED]' 'DarkGray' }
    if ($State.PluginDisabled) { Write-Row 'Logging plugin' '_nvtopps disabled' '[FIX APPLIED]' 'Green' }
    else { Write-Row 'Logging plugin' '_nvtopps enabled (driver default)' }
    if ($State.GuardInstalled) { Write-Row 'Auto-protect' 'On' '[ON]' 'Green' }
    else { Write-Row 'Auto-protect' 'Off' }
}

function Show-Report($Diagnosis, $Before = $null) {
    $s = $Diagnosis.State
    if (-not $s.HasGpu) { Write-Status "`n  No NVIDIA graphics card found. This tool is not needed on this PC." 'Yellow'; return }
    Show-StateRows $s
    if ($null -ne $Diagnosis.Rate) {
        $tag, $color = switch ($Diagnosis.Verdict) {
            { $_ -in 'Bug', 'StillHigh' } { '[TOO HIGH]', 'Red'; break }
            'Elevated' { '[ABOVE NORMAL]', 'Yellow'; break }
            default { '[NORMAL]', 'Green' }
        }
        Write-Row 'SSD writes' (Format-Rate $Diagnosis.Rate) $tag $color
        if ($null -ne $Before -and $null -ne $Before.Rate) {
            Write-Row 'Before' (Format-Rate $Before.Rate) '' 'DarkGray'
        }
    }
    Write-Host ''
    Show-Advice $Diagnosis
}

function Show-Advice($Diagnosis) {
    $s = $Diagnosis.State
    switch ($Diagnosis.Verdict) {
        'NotRunning' {
            Write-Status '  >> NVIDIA Display Container is not running, so there is nothing to measure.' 'Yellow' }
        'Bug' {
            Write-Status '  >> Your SSD is being worn out right now.' 'Red'
            Write-Status '     Press Enter to fix it in about 30 seconds. You keep your current driver.' 'Red' }
        'StillHigh' {
            Write-Status '  >> The plugin fix is on, but writes are still high.' 'Red'
            Write-Status "     Press Enter to roll back to driver $SafeVersion - this fixes it for sure." 'Red' }
        'Elevated' {
            Write-Status '  >> Writes are above normal. The bug grows the longer the PC stays on.' 'Yellow'
            if ($s.PluginDisabled) { Write-Status '     Press Enter for a 5-minute scan to be sure.' 'Yellow' }
            else { Write-Status '     Press Enter to apply the fix now.' 'Yellow' } }
        'AtRisk' {
            Write-Status '  >> Normal right now, but your driver has the bug and it builds up over time.' 'Yellow'
            if ($s.UptimeHours -lt 2) { Write-Status "     (PC was started $($s.UptimeHours) h ago, so the bug may not show yet.)" 'DarkGray' }
            Write-Status '     Press Enter to fix it before it starts.' 'Yellow' }
        'FixedUnguarded' {
            Write-Status '  >> Fixed. Note: an NVIDIA driver update can silently undo this fix.' 'Green'
            Write-Status '     Press Enter to turn on auto-protect, which re-applies it for you.' 'Green' }
        default {
            Write-Status '  >> All good. Your SSD is safe.' 'Green' }
    }
}

# ================================= Actions ==================================

function Restart-NvService {
    Write-Status '  Restarting NVIDIA Display Container (the screen may flicker)...'
    Restart-Service -Name $ServiceName -Force
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 15) {
        if ((Get-NvProcess).Count -gt 0) { Start-Sleep -Seconds 2; return }
        Start-Sleep -Milliseconds 500
    }
    Write-Status '  Warning: the service restarted but its process did not come back within 15 s.' 'Yellow'
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
    Write-Status '  Turning off the _nvtopps logging plugin (one registry value)...'
    Enable-PluginFix
    Restart-NvService
    Remove-Item $NvLogFile -Force -ErrorAction SilentlyContinue
    if (Test-PluginSkippedInLog) { Write-Status '  Confirmed: NVIDIA service log reports the plugin is no longer loaded.' 'Green' }
    Write-Status '  Fix applied. Measuring again to verify...' 'Green'
}

function Invoke-UndoAll {
    Write-Status '  Removing all changes made by this tool...'
    Uninstall-Guard
    Disable-PluginFix
    Restart-NvService
    Write-Status '  Done. Everything is back to the NVIDIA defaults.' 'Green'
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
        Write-Status '  System Restore Point created.' 'Green'
    } catch {
        Write-Status "  Could not create a restore point ($($_.Exception.Message)). Continuing." 'Yellow'
    }
}

function Get-VerifiedInstaller([string]$Url) {
    $dir = Join-Path $env:USERPROFILE "Downloads\nvidia-$SafeVersion"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $installer = Join-Path $dir (Split-Path $Url -Leaf)
    if (-not (Test-Path $installer)) {
        Write-Status "  Downloading NVIDIA $SafeVersion from nvidia.com (about 1 GB)..."
        Start-BitsTransfer -Source $Url -Destination $installer
    }
    $signature = Get-AuthenticodeSignature $installer
    $signer = "$($signature.SignerCertificate.Subject)"
    if ($signature.Status -ne 'Valid' -or $signer -notlike '*O=NVIDIA Corporation*') {
        Remove-Item $installer -Force
        throw "Signature check failed ($($signature.Status)). The file was deleted."
    }
    Write-Status '  Signature verified: NVIDIA Corporation.' 'Green'
    return $installer
}

function Invoke-Rollback {
    if ((Get-SystemState).Version -eq $SafeVersion) { Write-Status "  Driver $SafeVersion is already installed." 'Green'; return }
    $url = Get-DriverUrl
    try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null }
    catch {
        Write-Status "  Driver package not found at $url" 'Red'
        Write-Status "  Download $SafeVersion manually: https://www.nvidia.com/en-us/drivers/" 'Yellow'
        return
    }
    New-RestorePoint
    $installer = Get-VerifiedInstaller $url
    Write-Status ''
    Write-Status '  The NVIDIA installer opens now. In it choose:' 'Cyan'
    Write-Status '    NVIDIA Graphics Driver -> Agree -> Custom (Advanced)' 'Cyan'
    Write-Status '    -> tick "Perform a clean installation" -> Next -> Restart' 'Cyan'
    Write-Status '  Then turn off automatic driver updates in the NVIDIA App.' 'Cyan'
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
    Write-Status '  Auto-protect is on. It runs at startup and every hour.' 'Green'
    Write-Status "  Log: $GuardLog" 'DarkGray'
}

function Uninstall-Guard {
    if (-not (Test-GuardInstalled)) { return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status '  Auto-protect is off.' 'Green'
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

function Show-Options([string]$Recommended, $State) {
    $guardLabel = if ($State.GuardInstalled) { 'Turn off auto-protect' } else { 'Turn on auto-protect' }
    $options = @(
        @('1', 'Fix now (turn off the buggy logging plugin)', '~30 s, keeps driver, undoable'),
        @('2', "Roll back driver to $SafeVersion", '~10 min, zero side effects'),
        @('3', $guardLabel, 're-applies fix after updates'),
        @('4', 'Scan again', "$Seconds s"),
        @('5', 'Long scan', "$([int]($LongScanSeconds / 60)) min, most accurate")
    )
    if ($State.PluginDisabled -or $State.GuardInstalled) { $options += , @('U', 'Undo all changes', 'back to NVIDIA defaults') }
    $options += , @('Q', 'Quit', '')

    Write-Host ''
    Write-Host '  What would you like to do?'
    foreach ($o in $options) {
        $isRecommended = $o[0] -eq $Recommended
        $color = if ($isRecommended) { 'Yellow' } else { 'Gray' }
        Write-Host ('    [{0}] {1,-46}' -f $o[0], $o[1]) -NoNewline -ForegroundColor $color
        Write-Host ('{0,-30}' -f $o[2]) -NoNewline -ForegroundColor DarkGray
        if ($isRecommended) { Write-Host '<- recommended' -ForegroundColor Yellow } else { Write-Host '' }
    }
    Write-Host ''
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

function Show-Menu {
    Show-Header
    $diagnosis = Get-Diagnosis $Seconds
    $before = $null
    while ($true) {
        Show-Report $diagnosis $before
        if (-not $diagnosis.State.HasGpu) { return }
        $recommended = Get-RecommendedChoice $diagnosis
        Show-Options $recommended $diagnosis.State

        $choice = Read-Host "  Type a choice and press Enter (just Enter = $recommended)"
        if ($null -eq $choice) { return }
        $choice = $choice.Trim().ToUpper()
        if ($choice -eq '') { $choice = $recommended }
        if ($choice -eq 'Q') { Write-Status '  Bye!' 'Cyan'; return }
        if ((Get-ValidChoices $diagnosis.State) -notcontains $choice) {
            Write-Status '  Please type one of the choices shown.' 'Yellow'
            continue
        }

        Write-Host ''
        $before = if ($choice -in '1', 'U') { $diagnosis } else { $null }
        try { $diagnosis = Invoke-MenuAction $choice $diagnosis }
        catch { Write-Status "  Something went wrong: $($_.Exception.Message)" 'Red'; $before = $null }
    }
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
