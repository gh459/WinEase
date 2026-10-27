# tools/benchmark_custom_script_preview.ps1 - Benchmark for custom script preview lines generation
# Measures performance difference between array concatenation (+=) and List[string] (.Add)

param(
    [int]$RowCount = 1000,
    [int]$Iterations = 200
)

$rows = 1..$RowCount | ForEach-Object {
    [PSCustomObject]@{
        Stage     = "FirstLogon"
        ImagePath = "C:\Windows\Setup\Scripts\CustomScript.ps1"
        RunsAs    = "Administrator"
    }
}

# 1. Baseline: Array concatenation (+=)
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $lines = @()
    foreach ($r in $rows) { $lines += ("{0}  {1}  ({2})" -f $r.Stage, $r.ImagePath, $r.RunsAs) }
    if ($lines.Count -eq 0) { $lines = @("Empty") }
    $result1 = $lines -join "`r`n"
}
$sw1.Stop()

# 2. Optimized: List[string] (.Add)
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) { $lines.Add(("{0}  {1}  ({2})" -f $r.Stage, $r.ImagePath, $r.RunsAs)) }
    if ($lines.Count -eq 0) { $lines.Add("Empty") }
    $result2 = $lines -join "`r`n"
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark Custom Script Preview Generation ($RowCount rows, $Iterations iterations):"
Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
Write-Host "  Optimized (List[string] .Add):    $optimizedMs ms"
Write-Host "  Speedup factor:                   ${speedup}x"
Write-Host "  Outputs equal:                    $($result1 -eq $result2)"
