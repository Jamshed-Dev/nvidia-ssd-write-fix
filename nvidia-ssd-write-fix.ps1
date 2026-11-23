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
$ScriptUrl          = 'https://raw.githubusercontent.com/Jamshed-Dev/nvidia-ssd-write-fix/main/nvidia-ssd-write-fix.ps1'
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

function Get-Diagnosis {
    $gpu = Get-NvidiaGpu
    if (-not $gpu) { return $null }
    $nvVersion = ConvertTo-NvidiaVersion $gpu.DriverVersion
    Write-Status "  Scanning your PC, please wait $SampleSeconds seconds..." 'DarkGray'
    $rate = Measure-WriteRate
    return [pscustomobject]@{
        GpuName    = $gpu.Name
        Version    = $nvVersion
        IsAffected = $AffectedVersions -contains $nvVersion
        IsSafe     = $nvVersion -eq $SafeVersion
        Rate       = $rate
        IsHigh     = ($null -ne $rate) -and ($rate -ge $HighWriteMBps)
    }
}

function Write-Row([string]$Label, [string]$Value, [string]$Tag, [string]$TagColor) {
    Write-Host ('  {0,-12}' -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0,-34}' -f $Value) -NoNewline
    Write-Host $Tag -ForegroundColor $TagColor
}

function Show-Report($Diagnosis) {
    Write-Host ''
    if (-not $Diagnosis) {
        Write-Status '  No NVIDIA graphics card found. This tool is not needed on this PC.' 'Yellow'
        return
    }
    Write-Row 'GPU' $Diagnosis.GpuName '' 'Gray'
    if ($Diagnosis.IsAffected) {
        Write-Row 'Driver' $Diagnosis.Version '[HAS THE BUG]' 'Red'
    } else {
        Write-Row 'Driver' $Diagnosis.Version '[OK]' 'Green'
    }
    if ($null -eq $Diagnosis.Rate) {
        Write-Row 'SSD writes' "$ProcessName not running" '' 'Gray'
    } else {
        $perHourGB = [math]::Round($Diagnosis.Rate * 3600 / 1024, 1)
        $value = '{0} MB/s  (~{1} GB per hour)' -f $Diagnosis.Rate, $perHourGB
        if ($Diagnosis.IsHigh) { Write-Row 'SSD writes' $value '[TOO HIGH]' 'Red' }
        else { Write-Row 'SSD writes' $value '[NORMAL]' 'Green' }
    }
    Write-Host ''
    if ($Diagnosis.IsHigh) {
        Write-Status '  >> Your SSD is being worn out right now. Press Enter to stop it.' 'Red'
    } elseif ($Diagnosis.IsAffected) {
        Write-Status '  >> Writes are normal at the moment, but this driver has the bug.' 'Yellow'
        Write-Status "     Press Enter to fix it permanently (driver $SafeVersion)." 'Yellow'
    } else {
        Write-Status '  >> All good. Your SSD is safe. Nothing to fix.' 'Green'
    }
}

function Invoke-QuickFix {
    Write-Status '  Restarting the NVIDIA Display Container service...'
    Stop-Service -Name $ServiceName -Force
    Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
    Start-Service -Name $ServiceName
    Write-Status '  Done. The screen may have flickered - that is normal.' 'Green'
    Write-Status '  This is temporary: the bug can come back. Option 2 fixes it permanently.' 'Yellow'
    Start-Sleep -Seconds 5
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

function Show-Header {
    Write-Host ''
    Write-Host '  ==========================================================' -ForegroundColor Cyan
    Write-Host '    NVIDIA SSD Write Fix' -ForegroundColor Cyan
    Write-Host '    Stops NVDisplay.Container.exe from wearing out your SSD' -ForegroundColor DarkCyan
    Write-Host '  ==========================================================' -ForegroundColor Cyan
}

function Test-GuardInstalled {
    return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-RecommendedChoice($Diagnosis) {
    if ($Diagnosis -and $Diagnosis.IsHigh) { return '1' }
    if ($Diagnosis -and $Diagnosis.IsAffected) { return '2' }
    return 'Q'
}

function Show-Options([string]$Recommended, [bool]$GuardInstalled) {
    $guardLabel = if ($GuardInstalled) { 'Auto-protect is ON  (checks every hour)' } else { 'Turn on auto-protect (checks every hour)' }
    $options = @(
        @('1', 'Stop the SSD writes now', '10 sec, temporary'),
        @('2', 'Fix permanently', "installs driver $SafeVersion"),
        @('3', $guardLabel, 'runs in background'),
        @('4', 'Scan again', '10 sec')
    )
    if ($GuardInstalled) { $options += , @('5', 'Turn off auto-protect', '') }
    $options += , @('Q', 'Quit', '')

    Write-Host ''
    Write-Host '  What would you like to do?'
    foreach ($o in $options) {
        $marker = if ($o[0] -eq $Recommended) { '  <- recommended' } else { '' }
        $color = if ($o[0] -eq $Recommended) { 'Yellow' } else { 'Gray' }
        Write-Host ('    [{0}] {1,-42}' -f $o[0], $o[1]) -NoNewline -ForegroundColor $color
        Write-Host ('{0}' -f $o[2]) -NoNewline -ForegroundColor DarkGray
        Write-Host $marker -ForegroundColor Yellow
    }
    Write-Host ''
}

function Invoke-Choice([string]$Choice, [bool]$GuardInstalled) {
    switch ($Choice) {
        '1' { Invoke-QuickFix }
        '2' { Invoke-Rollback }
        '3' { if ($GuardInstalled) { Write-Status '  Auto-protect is already on.' 'Green' } else { Install-Guard } }
        '5' { Uninstall-Guard }
    }
}

function Show-Menu {
    Show-Header
    $diagnosis = Get-Diagnosis
    while ($true) {
        Show-Report $diagnosis
        $recommended = Get-RecommendedChoice $diagnosis
        $guardInstalled = Test-GuardInstalled
        Show-Options $recommended $guardInstalled

        $choice = Read-Host "  Type a number and press Enter (just Enter = $recommended)"
        if ($null -eq $choice) { return }
        $choice = $choice.Trim().ToUpper()
        if ($choice -eq '') { $choice = $recommended }
        if ($choice -eq 'Q') { Write-Status '  Bye!' 'Cyan'; return }
        $validChoices = if ($guardInstalled) { '1', '2', '3', '4', '5' } else { '1', '2', '3', '4' }
        if ($validChoices -notcontains $choice) {
            Write-Status '  Please type one of the numbers shown.' 'Yellow'
            continue
        }

        Write-Host ''
        try {
            if ($choice -ne '4') { Invoke-Choice $choice $guardInstalled }
        } catch {
            Write-Status "  Something went wrong: $($_.Exception.Message)" 'Red'
        }
        Write-Host ''
        $diagnosis = Get-Diagnosis
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
