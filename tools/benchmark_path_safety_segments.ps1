# tools/benchmark_path_safety_segments.ps1 - Benchmark for relative path segment parsing in Resolve-WinEaseSafeRelativePath
# Measures performance difference between array concatenation (+=) inside loop and array subexpression (@(...))

param(
    [int]$PathCount = 1000,
    [int]$Iterations = 200
)

$paths = 1..$PathCount | ForEach-Object {
    "folder$_/subfolder$_/deep$_/deeper$_/file$_.txt"
}

# 1. Baseline: Array concatenation (+=)
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    foreach ($p in $paths) {
        $clean = $p.Replace('/', '\')
        $segments1 = @()
        foreach ($seg in ($clean -split '\\')) { if ($seg -ne '' -and $seg -ne '.') { $segments1 += $seg } }
    }
}
$sw1.Stop()

# 2. Optimized: Array subexpression (@(...))
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    foreach ($p in $paths) {
        $clean = $p.Replace('/', '\')
        $segments2 = @(foreach ($seg in ($clean -split '\\')) { if ($seg -ne '' -and $seg -ne '.') { $seg } })
    }
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark Path Safety Segment Collection ($PathCount paths, $Iterations iterations):"
Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
Write-Host "  Optimized (Array subexpression @): $optimizedMs ms"
Write-Host "  Speedup factor:                   ${speedup}x"
