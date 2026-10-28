# tools/benchmark_last_run_total_seconds.ps1 - Benchmark for Get-WinEaseLastRunTotalSeconds duration collection
# Measures performance difference between in-loop accumulator baseline vs assigning loop result + LINQ Sum

param(
    [int]$PhaseCount = 20,
    [int]$Iterations = 10000
)

# Setup mock phase timings object
$json = [ordered]@{}
for ($i = 1; $i -le $PhaseCount; $i++) {
    $json["Phase $i"] = [double]($i * 12.5)
}
$json["NonNumeric"] = "string"
$json["BoolVal"] = $true
$jsonObject = $json | ConvertTo-Json | ConvertFrom-Json

$totalSec1 = 0
$totalSec2 = 0

# 1. Baseline: In-loop accumulator
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $totalSec1 = 0
    foreach ($v in $jsonObject.PSObject.Properties.Value) {
        if ($v -is [double] -or $v -is [decimal] -or $v -is [int] -or $v -is [long]) { $totalSec1 += [double]$v }
    }
}
$sw1.Stop()

# 2. Optimized: Assign loop result and sum with LINQ Enumerable::Sum
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $durations = foreach ($v in $jsonObject.PSObject.Properties.Value) {
        if ($v -is [double] -or $v -is [decimal] -or $v -is [int] -or $v -is [long]) { [double]$v }
    }
    $totalSec2 = if ($null -ne $durations) { [System.Linq.Enumerable]::Sum([double[]]$durations) } else { 0 }
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark Get-WinEaseLastRunTotalSeconds ($PhaseCount phases, $Iterations iterations):"
Write-Host "  Baseline (In-loop accumulator):               $baselineMs ms"
Write-Host "  Optimized (Assign loop result + LINQ Sum):    $optimizedMs ms"
Write-Host "  Speedup factor:                               ${speedup}x"
Write-Host "  Sums match:                                    $($totalSec1 -eq $totalSec2) ($totalSec1)"
