# benchmark_winui_init.ps1 - Benchmark WinUI Host init message generation
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Benchmark timing variables')]
param(
    [int]$Iterations = 1000
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repoRoot "config\schema.psd1"
$winUiHostPath = Join-Path $repoRoot "gui\WinEaseWinUiHost.ps1"

if (-not (Test-Path -LiteralPath $schemaPath)) {
    Write-Error "schema.psd1 not found at $schemaPath"
    throw "schema.psd1 not found"
}

# Load schema definitions into script scope as the builder does
$settingsDef = Import-PowerShellDataFile -LiteralPath $schemaPath
$script:AllTweakDefs = [ordered]@{}
foreach ($td in $settingsDef.Tweaks) {
    $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description; DescriptionJa = "ja" }
}
$script:ComponentDefs = [ordered]@{}
foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
$script:BuiltInPresets = [ordered]@{ extreme = @{ PayloadFormat = 'ESD'; TweakSettings = @{} } }
# The host needs only the GUI core (language tables, debloat items, migration helpers)
. (Join-Path $repoRoot "lib\WinEaseGuiCore.ps1")
$script:WinEaseGuiRepoRoot = $repoRoot
function Get-WinEasePreset { param($Name) if ($Name -eq 'extreme') { $script:BuiltInPresets['extreme'] } else { $null } }
# Keep the benchmark independent of the machine's drives
function Get-WinEaseGuiSourceCandidates { @() }
. $winUiHostPath

Write-Host "=== WinEase WinUI Host Benchmark (Optimized) ==="
Write-Host "Loaded AllTweakDefs count: $($script:AllTweakDefs.Count)"
Write-Host "Loaded ComponentDefs count: $($script:ComponentDefs.Count)"
Write-Host "Running $Iterations iterations of New-WinEaseWinUiInitMessage..."

# Warmup
[void](New-WinEaseWinUiInitMessage -InitialSettings @{} -Language "en")

$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Iterations; $i++) {
    [void](New-WinEaseWinUiInitMessage -InitialSettings @{} -Language "en")
}
$sw.Stop()

$ms = $sw.ElapsedMilliseconds
$avgMs = $ms / $Iterations

Write-Host "Total time: $ms ms"
Write-Host "Average time per call: $([math]::Round($avgMs, 4)) ms"

# Comparison test between baseline += and optimized @(foreach ...)
Write-Host "`n--- Synthetic Scaling Comparison (Baseline += vs Optimized @(foreach)) ---"
foreach ($count in @(1000, 5000, 10000)) {
    $defs = [ordered]@{}
    1..$count | ForEach-Object {
        $defs["Key$_"] = @{ Category = "Cat$_"; Default = $true; Description = "Desc$_"; DescriptionJa = "DescJa$_" }
    }

    # Measure baseline +=
    $swBaseline = [System.Diagnostics.Stopwatch]::StartNew()
    $tweaks1 = @()
    foreach ($tk in $defs.Keys) {
        $d = $defs[$tk]
        $tweaks1 += , [ordered]@{ Key = $tk; Category = "$($d.Category)"; Default = [bool]$d.Default; Description = "$($d.Description)"; DescriptionJa = "$($d.DescriptionJa)" }
    }
    $swBaseline.Stop()

    # Measure optimized @(foreach ...)
    $swOptimized = [System.Diagnostics.Stopwatch]::StartNew()
    $tweaks2 = @(
        foreach ($tk in $defs.Keys) {
            $d = $defs[$tk]
            [ordered]@{ Key = $tk; Category = "$($d.Category)"; Default = [bool]$d.Default; Description = "$($d.Description)"; DescriptionJa = "$($d.DescriptionJa)" }
        }
    )
    $swOptimized.Stop()

    $tBase = $swBaseline.ElapsedMilliseconds
    $tOpt = $swOptimized.ElapsedMilliseconds
    $ratio = if ($tOpt -gt 0) { [math]::Round($tBase / $tOpt, 1) } else { "N/A" }

    Write-Host "Count = $count items (Items: $($tweaks1.Count) vs $($tweaks2.Count)) -> Baseline (+=): $tBase ms | Optimized (@(foreach)): $tOpt ms | Speedup: ${ratio}x"
}
