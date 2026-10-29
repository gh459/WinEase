# tools/benchmark_verify_sechealth_dirs.ps1 - Benchmark for SecHealthUI package directory scanning in phase 15
# Measures performance difference between Get-ChildItem and direct .NET EnumerateDirectories

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
    # 1. Baseline: Get-ChildItem with foreach double loop
    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $secHealthDirs1 = [System.Collections.Generic.List[string]]::new()
        foreach ($secRoot in $secRoots) {
            $fullRoot = Join-Path -Path $mockApply -ChildPath $secRoot
            if (Test-Path -LiteralPath $fullRoot) {
                foreach ($item in (Get-ChildItem -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue)) {
                    if ($item.Name -match 'SecHealthUI') {
                        $secHealthDirs1.Add((Join-Path -Path $secRoot -ChildPath $item.Name))
                    }
                }
            }
        }
        $lastResult1 = $secHealthDirs1
    }
    $sw1.Stop()

    # 2. Optimized: Direct .NET EnumerateDirectories
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $secHealthDirs2 = [System.Collections.Generic.List[string]]::new()
        foreach ($secRoot in $secRoots) {
            $fullRoot = Join-Path -Path $mockApply -ChildPath $secRoot
            if ([System.IO.Directory]::Exists($fullRoot)) {
                try {
                    foreach ($dirPath in [System.IO.Directory]::EnumerateDirectories($fullRoot, '*SecHealthUI*')) {
                        $dirName = [System.IO.Path]::GetFileName($dirPath)
                        $secHealthDirs2.Add((Join-Path -Path $secRoot -ChildPath $dirName))
                    }
                } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }
        $lastResult2 = $secHealthDirs2
    }
    $sw2.Stop()

    $baselineMs = $sw1.ElapsedMilliseconds
    $optimizedMs = $sw2.ElapsedMilliseconds
    $speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

    Write-Host "Benchmark SecHealthUI Directory Accumulation ($ItemCountPerDir items/dir, $Iterations iterations):"
    Write-Host "  Baseline (Get-ChildItem double loop):        $baselineMs ms"
    Write-Host "  Optimized (.NET EnumerateDirectories):      $optimizedMs ms"
    Write-Host "  Speedup factor:                              ${speedup}x"
    Write-Host "  Counts match:                                $($lastResult1.Count -eq $lastResult2.Count)"
} finally {
    Remove-Item $mockApply -Recurse -Force -ErrorAction SilentlyContinue
}
