# tools/benchmark_profile_type_errors.ps1 - Benchmark for Import-WinEaseProfile type errors collection
# Measures performance difference between array concatenation (+=) and List[string] (.Add)

param(
    [int]$ComponentCount = 100,
    [int]$TweakCount = 100,
    [int]$Iterations = 500
)

# Setup mock component definitions and invalid settings
$components = 1..$ComponentCount | ForEach-Object {
    @{ Key = "Comp$_"; Type = "Bool" }
}
$settingsProps = [ordered]@{}
foreach ($c in $components) {
    $settingsProps[$c.Key] = "invalid_string_value"
}
$tweakProps = [ordered]@{}
1..$TweakCount | ForEach-Object {
    $tweakProps["Tweak$_"] = "invalid_string_value"
}

# 1. Baseline: Array concatenation (+=)
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $typeErrors1 = @()
    foreach ($cd in $components) {
        if ($cd.Type -ne 'Bool') { continue }
        $prop = $settingsProps[$cd.Key]
        if ($prop -and $null -ne $prop -and $prop -isnot [bool]) { $typeErrors1 += "$($cd.Key) (expected true/false, got '$prop')" }
    }
    foreach ($propName in $tweakProps.Keys) {
        $propVal = $tweakProps[$propName]
        if ($null -ne $propVal -and $propVal -isnot [bool]) { $typeErrors1 += "TweakSettings.$propName (expected true/false, got '$propVal')" }
    }
}
$sw1.Stop()

# 2. Optimized: List[string] (.Add)
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $typeErrors2 = [System.Collections.Generic.List[string]]::new()
    foreach ($cd in $components) {
        if ($cd.Type -ne 'Bool') { continue }
        $prop = $settingsProps[$cd.Key]
        if ($prop -and $null -ne $prop -and $prop -isnot [bool]) { $typeErrors2.Add("$($cd.Key) (expected true/false, got '$prop')") }
    }
    foreach ($propName in $tweakProps.Keys) {
        $propVal = $tweakProps[$propName]
        if ($null -ne $propVal -and $propVal -isnot [bool]) { $typeErrors2.Add("TweakSettings.$propName (expected true/false, got '$propVal')") }
    }
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark Profile Type Errors Collection ($ComponentCount components, $TweakCount tweaks, $Iterations iterations):"
Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
Write-Host "  Optimized (List[string] .Add):    $optimizedMs ms"
Write-Host "  Speedup factor:                   ${speedup}x"
Write-Host "  Counts match:                     $($typeErrors1.Count -eq $typeErrors2.Count)"
