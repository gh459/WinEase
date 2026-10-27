# tools/benchmark_firstlogon_error_collection.ps1 - Benchmark for FirstLogon error string collection
# Measures performance difference between array concatenation (+=) and List[string] (.Add)

param(
    [int]$ErrorCount = 500,
    [int]$Iterations = 200
)

$mockErrors = 1..$ErrorCount | ForEach-Object {
    "Exception detail message $_ at stage block evaluation"
}

# 1. Baseline: Array concatenation (+=)
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $flErrors = @()
    foreach ($err in $mockErrors) {
        $flErrors += ("Script block failed: {0}" -f $err)
    }
    if ($flErrors.Count -gt 0) {
        $failedMsg1 = $flErrors -join "`r`n"
    }
}
$sw1.Stop()

# 2. Optimized: List[string] (.Add)
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $flErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($err in $mockErrors) {
        $flErrors.Add(("Script block failed: {0}" -f $err))
    }
    if ($flErrors.Count -gt 0) {
        $failedMsg2 = $flErrors -join "`r`n"
    }
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark FirstLogon Error String Collection ($ErrorCount errors, $Iterations iterations):"
Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
Write-Host "  Optimized (List[string] .Add):    $optimizedMs ms"
Write-Host "  Speedup factor:                   ${speedup}x"
Write-Host "  Outputs equal:                    $($failedMsg1 -eq $failedMsg2)"
