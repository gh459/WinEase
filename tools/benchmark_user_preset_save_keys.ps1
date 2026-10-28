# tools/benchmark_user_preset_save_keys.ps1 - Benchmark for UserPresetSave missing key collection
# Measures performance difference between array concatenation (+=) and List[string] (.Add)

param(
    [int]$Iterations = 10000
)

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$en = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'config\ui-strings\en.json')) | ConvertFrom-Json
$ja = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'config\ui-strings\ja.json')) | ConvertFrom-Json
$keys = @('Button.SavePreset', 'Button.SavePreset.Tooltip', 'Dlg.SavePreset.Title', 'Dlg.SavePreset.Name', 'Dlg.SavePreset.Description',
    'Dlg.SavePreset.Save', 'Dlg.SavePreset.Overwrite', 'Msg.SavePreset.Success', 'Msg.SavePreset.Error',
    'SavePreset.Reason.InvalidName', 'SavePreset.Reason.Reserved', 'SavePreset.Reason.ConflictBuiltin',
    'SavePreset.Reason.Exists', 'SavePreset.Reason.Write', 'SavePreset.Reason.Readback')

# 1. Baseline: Array concatenation (+=)
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $missing1 = @()
    foreach ($k in $keys) {
        if (-not $en.PSObject.Properties[$k]) { $missing1 += "en $k" }
        if (-not $ja.PSObject.Properties[$k]) { $missing1 += "ja $k" }
    }
}
$sw1.Stop()

# 2. Optimized: List[string] (.Add)
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($iter = 0; $iter -lt $Iterations; $iter++) {
    $missing2 = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        if (-not $en.PSObject.Properties[$k]) { $missing2.Add("en $k") }
        if (-not $ja.PSObject.Properties[$k]) { $missing2.Add("ja $k") }
    }
}
$sw2.Stop()

$baselineMs = $sw1.ElapsedMilliseconds
$optimizedMs = $sw2.ElapsedMilliseconds
$speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

Write-Host "Benchmark UserPresetSave Missing Keys Collection ($($keys.Count) keys, $Iterations iterations):"
Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
Write-Host "  Optimized (List[string] .Add):    $optimizedMs ms"
Write-Host "  Speedup factor:                   ${speedup}x"
Write-Host "  Outputs equal:                    $($missing1 -join '; ' -eq ($missing2 -join '; '))"
