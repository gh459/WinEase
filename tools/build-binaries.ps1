#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the .NET parts of WinEase (shared by CI and local use).
.DESCRIPTION
    Runs one build step per component for the chosen architecture: the launcher (WinEase.exe), the WinUI 3
    window (gui\winui\build.ps1, output in gui\winui\bin) and the built-in plugins (src\WinEase.Plugins.Builtin.*,
    output in plugins\builtin together with plugins\builtin\builtin.lock.psd1, the SHA256 allow list the builder
    checks before it loads a plugin). New components are added to the $components table below; each one is a
    name plus a script block that builds it. Needs the .NET 8 SDK (https://dot.net).
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

# Component name -> build step.
$components = [ordered]@{
    Plugins = {
        # The built-in plugins are architecture independent (netstandard2.0). plugins\builtin holds only the plugin
        # DLLs and the lock file: the builder refuses a DLL that is not listed with its SHA256, and the contract
        # assembly goes to plugins\bin (gitignored, loaded by the builder before the plugins).
        $builtinDir = Join-Path -Path $repoRoot -ChildPath 'plugins\builtin'
        $binDir = Join-Path -Path $repoRoot -ChildPath 'plugins\bin'
        New-Item -ItemType Directory -Force -Path $builtinDir, $binDir | Out-Null
        Get-ChildItem -LiteralPath $builtinDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
        # No -o: it would also redirect the build of the referenced contract project into the plugin folder.
        # The DLLs are taken from the default output folder of each project.
        $pluginArgs = @('-c', $Configuration, '--nologo', '-p:DebugType=none', '-p:DebugSymbols=false', '-p:ContinuousIntegrationBuild=true')
        $contractProject = Join-Path -Path $repoRoot -ChildPath 'src\WinEase.Plugins.Abstractions\WinEase.Plugins.Abstractions.csproj'
        & dotnet build $contractProject @pluginArgs
        if ($LASTEXITCODE -ne 0) { throw "dotnet build (plugin contract) failed with exit code $LASTEXITCODE" }
        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "src\WinEase.Plugins.Abstractions\bin\$Configuration\netstandard2.0\WinEase.Plugins.Abstractions.dll") -Destination $binDir -Force
        $pluginNames = @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'src') -Directory -Filter 'WinEase.Plugins.Builtin.*' | ForEach-Object { $_.Name } | Sort-Object)
        if ($pluginNames.Count -eq 0) { throw 'No built-in plugin project found in src\.' }
        foreach ($pluginName in $pluginNames) {
            & dotnet build (Join-Path -Path $repoRoot -ChildPath "src\$pluginName\$pluginName.csproj") @pluginArgs
            if ($LASTEXITCODE -ne 0) { throw "dotnet build ($pluginName) failed with exit code $LASTEXITCODE" }
            Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "src\$pluginName\bin\$Configuration\netstandard2.0\$pluginName.dll") -Destination $builtinDir -Force
        }
        # the allow list: one entry per DLL, written with the writer of the plugin host
        . (Join-Path -Path $repoRoot -ChildPath 'lib\WinEasePlugins.ps1')
        $entries = foreach ($dll in (Get-ChildItem -LiteralPath $builtinDir -Filter '*.dll' -File | Sort-Object -Property Name)) {
            [PSCustomObject]@{
                File = $dll.Name; Sha256 = (Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes($dll.FullName)))
                OnError = 'Warn'; Description = "Built by tools\build-binaries.ps1 from src\$($dll.BaseName)"; Enabled = $true
            }
        }
        Write-WinEasePluginLock -Path (Join-Path -Path $builtinDir -ChildPath 'builtin.lock.psd1') -Entries @($entries) -Header @(
            '# WinEase built-in plugin allow list (generated by tools\build-binaries.ps1 or CI).',
            '# A DLL in plugins\builtin is only loaded when it is listed here with its SHA256. Not committed.')
        Write-Host "  $(@($entries).Count) built-in plugin(s) and builtin.lock.psd1 written to plugins\builtin" -ForegroundColor Green
    }
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
