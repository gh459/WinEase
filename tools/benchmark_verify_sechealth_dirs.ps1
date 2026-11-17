# tools/benchmark_verify_sechealth_dirs.ps1 - Benchmark for SecHealthUI package directory scanning in phase 15
# Measures performance difference between array concatenation (+=) with pipeline and Generic List with foreach

param(
    [int]$ItemCountPerDir = 100,
    [int]$Iterations = 100
)

$testDir = [System.IO.Path]::GetTempPath()
$mockApply = Join-Path $testDir "mock_verify_apply_$([guid]::NewGuid().ToString('N'))"
$secRoots = @("Program Files\WindowsApps", "Windows\SystemApps", "ProgramData\Microsoft\Windows\AppRepository\Packages")

# Setup mock directories
foreach ($sr in $secRoots) {
    $p = Join-Path $mockApply $sr
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    1..$ItemCountPerDir | ForEach-Object {
        $name = if ($_ % 10 -eq 0) { "Microsoft.SecHealthUI_10.0.$_" } else { "OtherPackage_10.0.$_" }
        New-Item -ItemType Directory -Path (Join-Path $p $name) -Force | Out-Null
    }
}

$lastResult1 = $null
$lastResult2 = $null

try {
    # 1. Baseline: Array concatenation (+=) with pipeline
    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $secHealthDirs1 = @()
        foreach ($secRoot in $secRoots) {
            $fullRoot = Join-Path -Path $mockApply -ChildPath $secRoot
            if (Test-Path -LiteralPath $fullRoot) {
                $secHealthDirs1 += @(Get-ChildItem -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'SecHealthUI' } |
                    ForEach-Object { Join-Path -Path $secRoot -ChildPath $_.Name })
            }
        }
        $lastResult1 = $secHealthDirs1
    }
    $sw1.Stop()

    # 2. Optimized: Generic List with foreach and cached root paths
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $validRoots = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($secRoot in $secRoots) {
        $fullRoot = Join-Path -Path $mockApply -ChildPath $secRoot
        if (Test-Path -LiteralPath $fullRoot) {
            $validRoots.Add([PSCustomObject]@{ SecRoot = $secRoot; FullRoot = $fullRoot })
        }
    }

    for ($i = 0; $i -lt $Iterations; $i++) {
        $secHealthDirs2 = [System.Collections.Generic.List[string]]::new()
        foreach ($vr in $validRoots) {
            foreach ($item in (Get-ChildItem -LiteralPath $vr.FullRoot -Force -ErrorAction SilentlyContinue)) {
                if ($item.Name -match 'SecHealthUI') {
                    $secHealthDirs2.Add((Join-Path -Path $vr.SecRoot -ChildPath $item.Name))
                }
            }
        }
        $lastResult2 = $secHealthDirs2
    }
    $sw2.Stop()

    $baselineMs = $sw1.ElapsedMilliseconds
    $optimizedMs = $sw2.ElapsedMilliseconds
    $speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

    Write-Host "Benchmark SecHealthUI Directory Accumulation ($ItemCountPerDir items/dir, $Iterations iterations):"
    Write-Host "  Baseline (Array concatenation += & pipeline): $baselineMs ms"
    Write-Host "  Optimized (List[string] & foreach loop):     $optimizedMs ms"
    Write-Host "  Speedup factor:                              ${speedup}x"
    Write-Host "  Counts match:                                $($lastResult1.Count -eq $lastResult2.Count)"
} finally {
    Remove-Item $mockApply -Recurse -Force -ErrorAction SilentlyContinue
}
