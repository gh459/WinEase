#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the WinUI 3 window (WinEaseGui.exe) used by WinEasebuilder.ps1 -GUI.
.DESCRIPTION
    Publishes gui\winui\WinEaseGui as an unpackaged, self-contained app (.NET and the Windows App SDK
    runtime included) into gui\winui\bin. WinEasebuilder.ps1 uses it from there; without it (or with
    -ClassicGui) the builder shows the classic WinForms window.
    Needs the .NET 8 SDK (https://dot.net). The first build downloads the NuGet packages.
.PARAMETER Architecture
    x64 (default) or arm64.
.PARAMETER IfStale
    Skips the build (exit 0, nothing written) when bin\WinEaseGui.exe already exists and is newer
    than every source file under gui\winui\WinEaseGui (bin and obj excluded). The launchers use this
    so a rebuilt checkout refreshes the window instead of silently running an outdated exe.
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$IfStale
)
$ErrorActionPreference = 'Stop'

$project = Join-Path -Path $PSScriptRoot -ChildPath 'WinEaseGui\WinEaseGui.csproj'
$outDir = Join-Path -Path $PSScriptRoot -ChildPath 'bin'
$exe = Join-Path -Path $outDir -ChildPath 'WinEaseGui.exe'

# Sources are everything under the project except the bin/obj build outputs (the same rule as
# LauncherLogic.NewestSourceWriteTimeUtc in src\WinEase.Launcher).
if ($IfStale -and (Test-Path -LiteralPath $exe)) {
    $exeTimeUtc = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
    $newerSource = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'WinEaseGui') -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.LastWriteTimeUtc -gt $exeTimeUtc } |
        Select-Object -First 1
    if (-not $newerSource) {
        Write-Host "WinEaseGui.exe is up to date ($exe); nothing to build." -ForegroundColor Green
        return
    }
    Write-Host "WinEaseGui.exe is older than its sources (e.g. $($newerSource.Name)); rebuilding..." -ForegroundColor Yellow
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet was not found. Install the .NET 8 SDK (https://dot.net) and run this script again.'
}

$platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
& dotnet publish $project -c $Configuration -r "win-$Architecture" -p:Platform=$platform -o $outDir --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

if (-not (Test-Path -LiteralPath $exe)) { throw "Build finished but $exe is missing." }
Write-Host "Built $exe" -ForegroundColor Green
