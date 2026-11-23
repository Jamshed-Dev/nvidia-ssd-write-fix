#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the README screenshots (SVG) from the tool's real UI functions.
.DESCRIPTION
    Loads the functions of ..\nvidia-ssd-write-fix.ps1 without running it, replaces
    Write-Host with a recorder, draws sample screens and writes them as SVG files that
    look like Windows Terminal. Nothing on the PC is changed: every system call used
    by the screens is mocked below.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File docs\render-screenshots.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = $here }
$ToolPath   = Join-Path $here '..\nvidia-ssd-write-fix.ps1'
$CharWidth  = 8.4
$LineHeight = 19
$FontSize   = 14
$PadX       = 18
$TitleBarH  = 34
$Columns    = 80

# Windows Terminal "Campbell" scheme
$Palette = @{
    Black = '#0C0C0C'; DarkBlue = '#0037DA'; DarkGreen = '#13A10E'; DarkCyan = '#3A96DD'
    DarkRed = '#C50F1F'; DarkMagenta = '#881798'; DarkYellow = '#C19C00'; Gray = '#CCCCCC'
    DarkGray = '#767676'; Blue = '#3B78FF'; Green = '#16C60C'; Cyan = '#61D6D6'
    Red = '#E74856'; Magenta = '#B4009E'; Yellow = '#F9F1A5'; White = '#F2F2F2'
}

# ---- Load the tool's functions and settings (the entry block is skipped) ----
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ToolPath), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Tool script has parse errors: $($parseErrors[0].Message)" }
$ast.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                   $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$Seconds = 20

# ---- Recorder: replaces Write-Host for every function loaded above ----------
$script:Lines = New-Object System.Collections.Generic.List[object]
$script:Current = New-Object System.Collections.Generic.List[object]

function Write-Host {
    param([Parameter(Position = 0)][object]$Object = '', [switch]$NoNewline,
          [string]$ForegroundColor = 'Gray', [string]$BackgroundColor = '')
    $parts = "$Object" -split "`n", -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { Complete-Line }
        $text = $parts[$i]
        if ($text.Contains("`r")) { $script:Current.Clear(); $text = $text.Substring($text.LastIndexOf("`r") + 1) }
        if ($text) { $script:Current.Add([pscustomobject]@{ Text = $text; Fg = $ForegroundColor; Bg = $BackgroundColor }) }
    }
    if (-not $NoNewline) { Complete-Line }
}

function Complete-Line {
    $script:Lines.Add(@($script:Current.ToArray()))
    $script:Current.Clear()
}

function Reset-Screen { $script:Lines.Clear(); $script:Current.Clear() }

# ---- Mocks: keep the fix flow from touching the system ----------------------
function Enable-PluginFix { }
function Restart-Service { }
function Start-Sleep { }
function Remove-Item { }
function Get-NvProcess { return @(1) }
function Test-PluginSkippedInLog { return $true }

# ---- SVG writer ---------------------------------------------------------------
function ConvertTo-XmlText([string]$Text) {
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-SegmentSvg($Segment, [int]$Column, [double]$Y) {
    $x = $PadX + $Column * $CharWidth
    $w = $Segment.Text.Length * $CharWidth
    $svg = ''
    if ($Segment.Bg) {
        $svg += '<rect x="{0:0.#}" y="{1:0.#}" width="{2:0.#}" height="{3}" fill="{4}"/>' -f $x, ($Y - 14), $w, $LineHeight, $Palette[$Segment.Bg]
    }
    # SVG collapses leading, trailing and repeated spaces, so place each run of words
    # (separated by single spaces) at its exact column instead of relying on spacing.
    foreach ($run in [regex]::Matches($Segment.Text, '\S+(?: \S+)*')) {
        $runX = $x + $run.Index * $CharWidth
        $svg += '<text x="{0:0.#}" y="{1:0.#}" textLength="{2:0.#}" lengthAdjust="spacingAndGlyphs" fill="{3}">{4}</text>' -f `
            $runX, $Y, ($run.Length * $CharWidth), $Palette[$Segment.Fg], (ConvertTo-XmlText $run.Value)
    }
    return $svg
}

function Save-Svg([string]$FileName) {
    if ($script:Current.Count -gt 0) { Complete-Line }
    $width = [int]($PadX * 2 + $Columns * $CharWidth)
    $height = [int]($TitleBarH + 14 + $script:Lines.Count * $LineHeight + 14)
    $body = New-Object System.Text.StringBuilder
    $y = $TitleBarH + 14 + 14
    foreach ($line in $script:Lines) {
        $column = 0
        foreach ($segment in $line) {
            [void]$body.Append((Get-SegmentSvg $segment $column $y))
            $column += $segment.Text.Length
        }
        $y += $LineHeight
    }
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height">
<rect width="$width" height="$height" rx="10" fill="#0C0C0C"/>
<path d="M0 10a10 10 0 0 1 10-10h$($width - 20)a10 10 0 0 1 10 10v$($TitleBarH - 10)h-$width z" fill="#2B2B2B"/>
<g font-family="Segoe UI, Arial, sans-serif" font-size="12" fill="#CCCCCC">
<text x="18" y="22">Administrator: Windows PowerShell</text>
<text x="$($width - 92)" y="22">&#x2014;</text><text x="$($width - 58)" y="22">&#x25A1;</text><text x="$($width - 26)" y="22">&#x2715;</text>
</g>
<g font-family="Cascadia Mono, Consolas, 'DejaVu Sans Mono', Menlo, monospace" font-size="$FontSize" xml:space="preserve">
$($body.ToString())
</g>
</svg>
"@
    $path = Join-Path $OutDir $FileName
    [IO.File]::WriteAllText($path, $svg, (New-Object Text.UTF8Encoding $false))
    Write-Output "wrote $path ($($script:Lines.Count) lines)"
    Reset-Screen
}

# ---- Sample machine states ------------------------------------------------------
function New-SampleState([hashtable]$Override) {
    $state = @{ HasGpu = $true; GpuName = 'NVIDIA GeForce RTX 3060'; Version = '621.24'; IsAffected = $true
                HasService = $true; PluginDisabled = $false; LogExists = $true; GuardInstalled = $false; UptimeHours = 11.8 }
    foreach ($key in $Override.Keys) { $state[$key] = $Override[$key] }
    return [pscustomobject]$state
}

$bugRate = 48240.0    # measured on a real affected PC: 13.4 MB/s
$bug     = New-Diagnosis (New-SampleState @{}) $bugRate
$fixed   = New-Diagnosis (New-SampleState @{ PluginDisabled = $true; LogExists = $false }) 0
$guarded = New-Diagnosis (New-SampleState @{ PluginDisabled = $true; LogExists = $false; GuardInstalled = $true }) 0

# 1. Scan finds the bug
Show-Header
Write-Host ''
Write-Step 'Measuring SSD writes for 20 seconds - keep the PC idle' DarkGray
Write-ScanProgress 20 20 268.0
Write-Host ''
Show-Report $bug
Show-Options (Get-RecommendedChoice $bug) $bug.State
Save-Svg 'screen-bug-detected.svg'

# 2. Fix applied and verified
Invoke-PluginFix
Write-Host ''
Write-Step 'Measuring SSD writes for 20 seconds - keep the PC idle' DarkGray
Write-ScanProgress 20 20 0.0
Write-Host ''
Show-Report $fixed $bug
Show-Options (Get-RecommendedChoice $fixed) $fixed.State
Save-Svg 'screen-fix-verified.svg'

# 3. Auto-protect on
Show-Header
Show-Report $guarded
Show-Options (Get-RecommendedChoice $guarded) $guarded.State
Save-Svg 'screen-all-good.svg'
