# tools/benchmark_plugin_inputs.ps1 - Benchmark for plugin inputs array creation vs List[object]
# Measures performance difference between array concatenation (+=) and List[object] (.Add / .AddRange)

param(
    [int]$Iterations = 1000
)

$libRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $libRoot -ChildPath 'lib\WinEasePlugins.ps1')

$paths = Get-WinEasePluginPaths -RepoRoot $libRoot
$srcDir = Join-Path -Path $paths.RepoRoot -ChildPath "src\WinEase.Plugins.Builtin.PostInstallTools"
$name = "PostInstallTools"

if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    Write-Error "Source directory $srcDir does not exist."
    exit 1
}

# 1. Baseline: Array concatenation (+=) with pipeline ForEach-Object
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$result1 = $null
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $inputs = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File)
    $resources = Get-WinEaseBuiltinPluginResources -Name $name -RepoRoot $paths.RepoRoot
    foreach ($res in $resources) {
        $inputs += Get-Item -LiteralPath ($res -split ',')[0]
    }
    $result1 = ($inputs | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
}
$sw1.Stop()

# 2. Optimized: List[object] with foreach loop
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$result2 = $null
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $inputs = [System.Collections.Generic.List[object]]::new()
    $csFiles = Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File
    if ($null -ne $csFiles) { $inputs.AddRange([object[]]@($csFiles)) }
    $resources = Get-WinEaseBuiltinPluginResources -Name $name -RepoRoot $paths.RepoRoot
    foreach ($res in $resources) {
        $resPath = ($res -split ',')[0]
        $inputs.Add((Get-Item -LiteralPath $resPath))
    }
    $result2 = ($inputs | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark Plugin Inputs Collection ($Iterations iterations):"
Write-Host "  Baseline (Array concatenation += & pipeline): $baselineMs ms"
Write-Host "  Optimized (List[object] & foreach loop):      $optimizedMs ms"
Write-Host "  Speedup factor:                               ${speedup}x"
Write-Host "  Outputs equal:                                $($result1 -eq $result2)"
