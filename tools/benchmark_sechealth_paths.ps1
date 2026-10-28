# tools/benchmark_sechealth_paths.ps1 - Benchmark for secHealthPaths collection in phases/05-appx.ps1
# Measures performance difference between array concatenation (+=) and List[T].Add()

param(
    [int]$Iterations = 1000
)

$scratchDir = "/tmp/benchmark_sechealth_scratch"
$pkgName = "Microsoft.SecHealthUI_8wekyb3d8bbwe"

# Set up dummy directories and files
$dirs = @(
    "$scratchDir/Program Files/WindowsApps",
    "$scratchDir/Windows/SystemApps",
    "$scratchDir/ProgramData/Microsoft/Windows/AppRepository/Packages"
)

foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    for ($i = 1; $i -le 20; $i++) {
        $dummy = Join-Path $d "Microsoft.SecHealthUI_1.0.${i}_x64__8wekyb3d8bbwe"
        if (-not (Test-Path -LiteralPath $dummy)) {
            New-Item -ItemType Directory -Path $dummy -Force | Out-Null
        }
        $other = Join-Path $d "Microsoft.OtherApp_1.0.${i}_x64__8wekyb3d8bbwe"
        if (-not (Test-Path -LiteralPath $other)) {
            New-Item -ItemType Directory -Path $other -Force | Out-Null
        }
    }
}

try {
    # 1. Baseline: Array concatenation (+=)
    $lastRes1 = @()
    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($iter = 0; $iter -lt $Iterations; $iter++) {
        $secHealthPaths1 = @(
            (Join-Path -Path "$scratchDir\Program Files\WindowsApps" -ChildPath $pkgName)
        )
        foreach ($globRoot in @(
            "$scratchDir\Program Files\WindowsApps",
            "$scratchDir\Windows\SystemApps",
            "$scratchDir\ProgramData\Microsoft\Windows\AppRepository\Packages"
        )) {
            if (Test-Path -LiteralPath $globRoot) {
                $secHealthPaths1 += @(Get-ChildItem -LiteralPath $globRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'SecHealthUI' } |
                    ForEach-Object { $_.FullName })
            }
        }
        $lastRes1 = $secHealthPaths1
    }
    $sw1.Stop()

    # 2. Optimized: List[string].Add()
    $lastRes2 = [System.Collections.Generic.List[string]]::new()
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    for ($iter = 0; $iter -lt $Iterations; $iter++) {
        $secHealthPaths2 = [System.Collections.Generic.List[string]]::new()
        $secHealthPaths2.Add((Join-Path -Path "$scratchDir\Program Files\WindowsApps" -ChildPath $pkgName))
        foreach ($globRoot in @(
            "$scratchDir\Program Files\WindowsApps",
            "$scratchDir\Windows\SystemApps",
            "$scratchDir\ProgramData\Microsoft\Windows\AppRepository\Packages"
        )) {
            if (Test-Path -LiteralPath $globRoot) {
                $foundItems = Get-ChildItem -LiteralPath $globRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'SecHealthUI' }
                foreach ($item in $foundItems) {
                    $secHealthPaths2.Add($item.FullName)
                }
            }
        }
        $lastRes2 = $secHealthPaths2
    }
    $sw2.Stop()

    $baselineMs = $sw1.ElapsedMilliseconds
    $optimizedMs = $sw2.ElapsedMilliseconds
    $speedup = if ($optimizedMs -gt 0) { [math]::Round($baselineMs / $optimizedMs, 2) } else { "N/A" }

    Write-Host "Benchmark secHealthPaths Collection ($Iterations iterations):"
    Write-Host "  Baseline (Array concatenation +=): $baselineMs ms"
    Write-Host "  Optimized (List[string].Add()):     $optimizedMs ms"
    Write-Host "  Speedup factor:                     ${speedup}x"
    Write-Host "  Counts match:                       $($lastRes1.Count -eq $lastRes2.Count)"
} finally {
    if (Test-Path -LiteralPath $scratchDir) {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
