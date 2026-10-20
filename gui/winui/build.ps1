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
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'

$project = Join-Path -Path $PSScriptRoot -ChildPath 'WinEaseGui\WinEaseGui.csproj'
$outDir = Join-Path -Path $PSScriptRoot -ChildPath 'bin'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet was not found. Install the .NET 8 SDK (https://dot.net) and run this script again.'
}

$platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
& dotnet publish $project -c $Configuration -r "win-$Architecture" -p:Platform=$platform -o $outDir --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$exe = Join-Path -Path $outDir -ChildPath 'WinEaseGui.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Build finished but $exe is missing." }
Write-Host "Built $exe" -ForegroundColor Green
