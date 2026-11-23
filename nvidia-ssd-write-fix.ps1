#Requires -Version 5.1
<#
.SYNOPSIS
    Detects and fixes the NVIDIA GeForce driver bug where NVDisplay.Container.exe
    writes tens of GB per hour to the system SSD (nvlog.nvlgstg), even at idle.

.DESCRIPTION
    Menu-driven tool (run via fix.bat):
      1. Check      - driver version + live write rate of NVDisplay.Container.exe
      2. Quick fix  - restart NVIDIA Display Container service, reset runaway log
      3. Rollback   - restore point, download known-good driver from nvidia.com,
                      verify NVIDIA signature, launch installer
      4. Auto-guard - hourly scheduled task that restarts the service if writes spike
      5. Remove auto-guard

    Not affiliated with NVIDIA. No driver files are redistributed; the driver is
    downloaded straight from NVIDIA's official servers.

.PARAMETER Guard
    Non-interactive mode used by the scheduled task.
#>
[CmdletBinding()]
param(
    [switch]$Guard
)

$ErrorActionPreference = 'Stop'

# ---- Configuration: update when NVIDIA ships a fixed driver -----------------
$AffectedVersions   = @('621.14', '621.24')
$SafeVersion        = '621.01'
$DownloadBase       = 'https://us.download.nvidia.com/Windows'
$ServiceName        = 'NVDisplay.ContainerLocalSystem'
$ProcessName        = 'NVDisplay.Container.exe'
$LogFile            = Join-Path $env:ProgramData 'NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg'
$SampleSeconds      = 10
$HighWriteMBps      = 2.0
$InstallDir         = Join-Path $env:ProgramData 'nvidia-ssd-write-fix'
$GuardLog           = Join-Path $InstallDir 'guard.log'
$TaskName           = 'NVIDIA SSD Write Guard'
$ScriptUrl          = 'https://raw.githubusercontent.com/USERNAME/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1'
# ------------------------------------------------------------------------------

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Status([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
}

function Get-NvidiaGpu {
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*NVIDIA*' } | Select-Object -First 1
}

# Windows driver version 32.0.16.2124 -> NVIDIA version 621.24
function ConvertTo-NvidiaVersion([string]$WindowsVersion) {
    $parts = $WindowsVersion.Split('.')
    if ($parts.Count -lt 4) { return $null }
    $digits = ($parts[2] + $parts[3].PadLeft(4, '0'))
    $digits = $digits.Substring($digits.Length - 5)
    return '{0}.{1}' -f $digits.Substring(0, 3), $digits.Substring(3, 2)
}

function Measure-WriteRate {
    $filter = "Name='$ProcessName'"
    $before = @{}
    Get-CimInstance Win32_Process -Filter $filter | ForEach-Object { $before[$_.ProcessId] = $_.WriteTransferCount }
    if ($before.Count -eq 0) { return $null }

    Start-Sleep -Seconds $SampleSeconds

    $bytes = 0
    Get-CimInstance Win32_Process -Filter $filter | ForEach-Object {
        if ($before.ContainsKey($_.ProcessId)) { $bytes += $_.WriteTransferCount - $before[$_.ProcessId] }
    }
    return [math]::Round($bytes / 1MB / $SampleSeconds, 2)
}

function Invoke-Check {
    $gpu = Get-NvidiaGpu
    if (-not $gpu) {
        Write-Status 'No NVIDIA GPU found. This tool does not apply to this PC.' 'Yellow'
        return
    }
    $nvVersion = ConvertTo-NvidiaVersion $gpu.DriverVersion
    Write-Status ("GPU            : {0}" -f $gpu.Name)
    Write-Status ("Driver version : {0} ({1})" -f $nvVersion, $gpu.DriverVersion)

    $isAffected = $AffectedVersions -contains $nvVersion
    if ($isAffected) {
        Write-Status 'Driver status  : AFFECTED version (reported SSD write bug)' 'Red'
    } else {
        Write-Status 'Driver status  : not on the known-affected list' 'Green'
    }

    Write-Status "Measuring $ProcessName writes for $SampleSeconds seconds..."
    $rate = Measure-WriteRate
    if ($null -eq $rate) {
        Write-Status "$ProcessName is not running." 'Yellow'
        return
    }
    $perHourGB = [math]::Round($rate * 3600 / 1024, 1)
    $color = if ($rate -ge $HighWriteMBps) { 'Red' } else { 'Green' }
    Write-Status ("Write rate     : {0} MB/s  (~{1} GB per hour)" -f $rate, $perHourGB) $color

    if ($rate -ge $HighWriteMBps) {
        Write-Status 'Result: excessive SSD writes detected. Use option 2 now, option 3 for a permanent fix.' 'Red'
    } else {
        Write-Status 'Result: write rate looks normal.' 'Green'
    }
}

function Invoke-QuickFix {
    Write-Status "Restarting $ServiceName..."
    Stop-Service -Name $ServiceName -Force
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
        Write-Status "Removed runaway log: $LogFile"
    }
    Start-Service -Name $ServiceName
    Write-Status 'Service restarted. Re-measuring...'
    Start-Sleep -Seconds 5
    $rate = Measure-WriteRate
    Write-Status ("Write rate now: {0} MB/s" -f $rate) 'Green'
    Write-Status 'Note: this is temporary. The bug can return; use option 3 for a permanent fix.' 'Yellow'
}

function Test-IsLaptop {
    return [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
}

function Get-DriverUrl {
    $formFactor = if (Test-IsLaptop) { 'notebook' } else { 'desktop' }
    $file = "$SafeVersion-$formFactor-win10-win11-64bit-international-dch-whql.exe"
    return "$DownloadBase/$SafeVersion/$file"
}

function New-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Before NVIDIA $SafeVersion rollback" -RestorePointType MODIFY_SETTINGS
        Write-Status 'System Restore Point created.' 'Green'
    } catch {
        Write-Status "Could not create a restore point ($($_.Exception.Message)). Continuing." 'Yellow'
    }
}

function Invoke-Rollback {
    $gpu = Get-NvidiaGpu
    if (-not $gpu) { Write-Status 'No NVIDIA GPU found.' 'Yellow'; return }
    if ((ConvertTo-NvidiaVersion $gpu.DriverVersion) -eq $SafeVersion) {
        Write-Status "Driver $SafeVersion is already installed." 'Green'
        return
    }

    $url = Get-DriverUrl
    try {
        Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null
    } catch {
        Write-Status "Driver package not found at $url" 'Red'
        Write-Status "Download $SafeVersion manually: https://www.nvidia.com/en-us/drivers/" 'Yellow'
        return
    }

    New-RestorePoint

    $downloadDir = Join-Path $env:USERPROFILE "Downloads\nvidia-$SafeVersion"
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
    $installer = Join-Path $downloadDir (Split-Path $url -Leaf)

    if (-not (Test-Path $installer)) {
        Write-Status "Downloading NVIDIA $SafeVersion (about 1 GB)..."
        Start-BitsTransfer -Source $url -Destination $installer
    }

    $signature = Get-AuthenticodeSignature $installer
    $signer = $signature.SignerCertificate.Subject
    if ($signature.Status -ne 'Valid' -or $signer -notlike '*O=NVIDIA Corporation*') {
        Remove-Item $installer -Force
        throw "Signature check failed ($($signature.Status), $signer). File deleted."
    }
    Write-Status 'Signature verified: NVIDIA Corporation.' 'Green'

    Write-Status ''
    Write-Status 'The NVIDIA installer will open now. In the installer choose:' 'Cyan'
    Write-Status '  NVIDIA Graphics Driver -> Agree -> Custom (Advanced)' 'Cyan'
    Write-Status '  -> tick "Perform a clean installation" -> Next -> Restart' 'Cyan'
    Write-Status 'Afterwards, turn off automatic driver updates in the NVIDIA App.' 'Cyan'
    Start-Process -FilePath $installer
}

function Install-Guard {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir 'nvidia-ssd-write-fix.ps1'
    # Run from a file: copy it. Run via "irm | iex": there is no file, so fetch it.
    if ($PSCommandPath) {
        Copy-Item -Path $PSCommandPath -Destination $target -Force
    } else {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $target -UseBasicParsing
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Guard"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Force | Out-Null
    Write-Status "Auto-guard installed. Checks every hour; log: $GuardLog" 'Green'
}

function Uninstall-Guard {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status 'Auto-guard removed.' 'Green'
}

function Invoke-Guard {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $rate = Measure-WriteRate
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($null -ne $rate -and $rate -ge $HighWriteMBps) {
        Stop-Service -Name $ServiceName -Force
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
        Start-Service -Name $ServiceName
        Add-Content $GuardLog "$stamp  $rate MB/s -> service restarted"
    } else {
        Add-Content $GuardLog "$stamp  $rate MB/s ok"
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '=== NVIDIA SSD Write Fix ===' -ForegroundColor Cyan
        Write-Host '1. Check (driver version + live SSD write rate)'
        Write-Host '2. Quick fix (restart service, stop writes now)'
        Write-Host "3. Permanent fix (roll back to driver $SafeVersion)"
        Write-Host '4. Install auto-guard (hourly check, auto-restart)'
        Write-Host '5. Remove auto-guard'
        Write-Host 'Q. Quit'
        $choice = Read-Host 'Choose'
        if ($null -eq $choice) { return }
        try {
            switch ($choice.ToUpper()) {
                '1' { Invoke-Check }
                '2' { Invoke-QuickFix }
                '3' { Invoke-Rollback }
                '4' { Install-Guard }
                '5' { Uninstall-Guard }
                'Q' { return }
                default { Write-Status 'Invalid choice.' 'Yellow' }
            }
        } catch {
            Write-Status "Error: $($_.Exception.Message)" 'Red'
        }
    }
}

function Start-Elevated {
    $source = if ($PSCommandPath) { "-File `"$PSCommandPath`"" } else { "-Command `"irm '$ScriptUrl' | iex`"" }
    Write-Status 'Administrator rights are required. Opening an elevated PowerShell window...' 'Yellow'
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit $source"
    } catch {
        Write-Status 'Elevation was cancelled. Run PowerShell as Administrator and try again.' 'Red'
    }
}

# 'return' rather than 'exit' so "irm | iex" never closes the user's console.
if (-not (Test-IsAdmin)) {
    Start-Elevated
    return
}

if ($Guard) { Invoke-Guard } else { Show-Menu }
