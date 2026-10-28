# tools/benchmark_custom_script_inventory.ps1 - Benchmark for custom script inventory array collection
# Measures performance difference between array concatenation ($files += ...) and List[object] (.Add)

param(
    [int]$FileCount = 200,
    [int]$Iterations = 100
)

# Create a temporary directory structure mimicking repo structure
$tempRepo = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winease_bench_inv_" + [Guid]::NewGuid().ToString("N"))
$stageDir = Join-Path -Path $tempRepo -ChildPath "tools/custom-scripts/FirstLogon"
$legacyDir = Join-Path -Path $tempRepo -ChildPath "tools/custom-scripts"
$null = New-Item -ItemType Directory -Path $stageDir -Force
$null = New-Item -ItemType Directory -Path $legacyDir -Force

# Create dummy files
1..$FileCount | ForEach-Object {
    $file = Join-Path -Path $legacyDir -ChildPath ("script_$_.ps1")
    Set-Content -LiteralPath $file -Value "# @WinEase-Stage: FirstLogon`r`nWrite-Host 'Test $_'"
}

try {
    # 1. Baseline: Array concatenation ($files += ...)
    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($iter = 0; $iter -lt $Iterations; $iter++) {
        $files = @()
        if (Test-Path -LiteralPath $legacyDir) {
            $files += @(Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'README.md' -and $_.Name -ne '.gitkeep' })
        }
        $count1 = $files.Count
    }
    $sw1.Stop()

    # 2. Optimized: Generic List[object] (.Add)
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($iter = 0; $iter -lt $Iterations; $iter++) {
        $files = [System.Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $legacyDir) {
            foreach ($file in @(Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'README.md' -and $_.Name -ne '.gitkeep' })) {
                $files.Add($file)
            }
        }
        $count2 = $files.Count
    }
    $sw2.Stop()

    $baselineMs = $sw1.ElapsedMilliseconds
    $optimizedMs = $sw2.ElapsedMilliseconds
    $speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

    Write-Host "Benchmark Custom Script Inventory Collection ($FileCount files, $Iterations iterations):"
    Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
    Write-Host "  Optimized (List[object] .Add):     $optimizedMs ms"
    Write-Host "  Speedup factor:                    ${speedup}x"
    Write-Host "  Count matching:                    $($count1 -eq $count2)"
} finally {
    if (Test-Path -LiteralPath $tempRepo) {
        Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}
