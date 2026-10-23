#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the .NET parts of WinEase (shared by CI and local use).
.DESCRIPTION
    Runs one build step per component for the chosen architecture. Today the only component is the
    WinUI 3 window (gui\winui\build.ps1, output in gui\winui\bin). New components (launcher, plugins)
    are added to the $components table below; each one is a name plus a script block that builds it.
    Needs the .NET 8 SDK (https://dot.net).
.PARAMETER Architecture
    x64 (default on x64 hosts) or arm64.
.PARAMETER Configuration
    Release (default) or Debug.
.PARAMETER Component
    Builds only the named components (default: all).
.PARAMETER Version
    Version stamped into WinEase.exe (release tag such as v2.1.0 or 2.1.0-fork.1). Default: the nearest git tag, else left at the project default.
.PARAMETER Test
    Runs dotnet test on src\WinEase.sln after the build (a solution without test projects passes).
.EXAMPLE
    .\tools\build-binaries.ps1 -Architecture arm64 -Test
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string[]]$Component,
    [string]$Version,
    [switch]$Test
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet was not found. Install the .NET 8 SDK (https://dot.net) and run this script again.'
}

# Version for the launcher's file properties: -Version, else the nearest git tag (leading v removed).
if (-not $Version -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $described = & git -C $repoRoot describe --tags --abbrev=0 2>$null
    if ($LASTEXITCODE -eq 0) { $Version = "$described" }
}
$Version = "$Version".TrimStart('v')
$versionArgs = @()
if ($Version -match '^\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$') { $versionArgs = @("-p:Version=$Version") }

# Component name -> build step. Add the plugins here.
$components = [ordered]@{
    Launcher = {
        # WinEase.exe goes next to WinEasebuilder.ps1 (gitignored), like gui\winui\bin.
        $outDir = Join-Path -Path $repoRoot -ChildPath 'src\WinEase.Launcher\bin\out'
        & dotnet build (Join-Path -Path $repoRoot -ChildPath 'src\WinEase.Launcher\WinEase.Launcher.csproj') -c $Configuration -o $outDir --nologo @versionArgs
        if ($LASTEXITCODE -ne 0) { throw "dotnet build (launcher) failed with exit code $LASTEXITCODE" }
        Copy-Item -LiteralPath (Join-Path -Path $outDir -ChildPath 'WinEase.exe') -Destination (Join-Path -Path $repoRoot -ChildPath 'WinEase.exe') -Force
    }
    WinUI = {
        & (Join-Path -Path $repoRoot -ChildPath 'gui\winui\build.ps1') -Architecture $Architecture -Configuration $Configuration
    }
}

$unknown = @($Component | Where-Object { $_ -and -not $components.Contains($_) })
if ($unknown.Count -gt 0) { throw "Unknown component(s): $($unknown -join ', '). Known: $($components.Keys -join ', ')" }

foreach ($name in $components.Keys) {
    if ($Component -and $Component -notcontains $name) { continue }
    Write-Host "== Building $name ($Architecture, $Configuration)" -ForegroundColor Cyan
    & $components[$name]
}

if ($Test) {
    $platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
    Write-Host '== dotnet test' -ForegroundColor Cyan
    & dotnet test (Join-Path -Path $repoRoot -ChildPath 'src\WinEase.sln') -c $Configuration -p:Platform=$platform --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet test failed with exit code $LASTEXITCODE" }
}
