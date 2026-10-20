#Requires -Version 5.1
<#
.SYNOPSIS
    WinEase Benchmark Statistical Comparison Tool
.DESCRIPTION
    Compares multi-run benchmark datasets (N >= 5 recommended) across Windows configurations:
    Baseline (Stock Windows 11) vs WinEase Standard vs WinEase Experimental.
    Computes rigorous statistical measures: Count, Mean, Median (p50), Min, Max, StdDev, IQR,
    and percentage improvement.
.PARAMETER BaselineHistoryPath
    Path to JSON file containing Baseline benchmark runs (single object or array).
.PARAMETER OptimizedHistoryPath
    Path to JSON file containing WinEase Standard benchmark runs.
.PARAMETER ExperimentalHistoryPath
    Optional path to JSON file containing WinEase Experimental benchmark runs.
.PARAMETER OptimizedLabel
    Display label for the optimized configuration (Default: 'WinEase Standard').
.PARAMETER ExperimentalLabel
    Display label for experimental configuration (Default: 'WinEase Experimental').
.PARAMETER OutputPath
    Optional output file path for Markdown comparison report.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaselineHistoryPath,

    [Parameter(Mandatory = $true)]
    [string]$OptimizedHistoryPath,

    [string]$ExperimentalHistoryPath = "",
    [string]$OptimizedLabel = "WinEase Standard",
    [string]$ExperimentalLabel = "WinEase Experimental",
    [string]$OutputPath = ""
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$helpersPath = Join-Path (Split-Path -Parent $scriptDir) "WinEasehelpers.ps1"
if (Test-Path -LiteralPath $helpersPath) {
    . $helpersPath
} else {
    Write-Error "Could not find WinEasehelpers.ps1 at: $helpersPath"
    exit 1
}

function Load-BenchmarkRuns {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Benchmark history file not found: $Path"
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
        foreach ($item in $obj) { $list.Add($item) }
    } else {
        $list.Add($obj)
    }
    return [PSCustomObject[]]$list.ToArray()
}

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "   WinEase Multi-Run Benchmark Statistical Comparison Suite                     " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

try {
    $baselineRuns  = Load-BenchmarkRuns -Path $BaselineHistoryPath
    $optimizedRuns = Load-BenchmarkRuns -Path $OptimizedHistoryPath
    $experimentalRuns = if ($ExperimentalHistoryPath) { Load-BenchmarkRuns -Path $ExperimentalHistoryPath } else { $null }
} catch {
    Write-Error "Error loading benchmark runs: $_"
    exit 1
}

Write-Host "Loaded Runs:" -ForegroundColor Gray
Write-Host "  - Baseline ($BaselineHistoryPath): $($baselineRuns.Count) runs" -ForegroundColor Gray
Write-Host "  - $OptimizedLabel ($OptimizedHistoryPath): $($optimizedRuns.Count) runs" -ForegroundColor Gray
if ($experimentalRuns) {
    Write-Host "  - $ExperimentalLabel ($ExperimentalHistoryPath): $($experimentalRuns.Count) runs" -ForegroundColor Gray
}

# Compare Baseline vs Optimized
$compStandard = Compare-WinEaseBenchmarkSeries -BaselineRuns $baselineRuns -OptimizedRuns $optimizedRuns -OptimizedLabel $OptimizedLabel

# Compare Baseline vs Experimental if available
$compExperimental = if ($experimentalRuns) {
    Compare-WinEaseBenchmarkSeries -BaselineRuns $baselineRuns -OptimizedRuns $experimentalRuns -OptimizedLabel $ExperimentalLabel
} else { $null }

# Build Markdown Report
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# WinEase Multi-Run Benchmark Statistical Comparison Report")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Generated on: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Sample Sizes")
[void]$sb.AppendLine("- **Baseline**: $($baselineRuns.Count) run(s)")
[void]$sb.AppendLine("- **$OptimizedLabel**: $($optimizedRuns.Count) run(s)")
if ($experimentalRuns) {
    [void]$sb.AppendLine("- **$ExperimentalLabel**: $($experimentalRuns.Count) run(s)")
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("## Comparison: Baseline vs $OptimizedLabel")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Metric | Baseline Median | $OptimizedLabel Median | Improvement (%) | Baseline IQR | $OptimizedLabel IQR | Baseline StdDev |")
[void]$sb.AppendLine("|---|---|---|---|---|---|---|")

foreach ($key in $compStandard.Keys) {
    $c = $compStandard[$key]
    $mName = $c.Metric
    $bMed  = $c.Baseline.Median
    $oMed  = $c.Optimized.Median
    $imp   = "$($c.ImprovementPercent)%"
    $bIqr  = $c.Baseline.IQR
    $oIqr  = $c.Optimized.IQR
    $bStd  = $c.Baseline.StdDev
    [void]$sb.AppendLine("| $mName | $bMed | $oMed | $imp | $bIqr | $oIqr | $bStd |")
}

if ($compExperimental) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Comparison: Baseline vs $ExperimentalLabel")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Metric | Baseline Median | $ExperimentalLabel Median | Improvement (%) | Baseline IQR | $ExperimentalLabel IQR | Baseline StdDev |")
    [void]$sb.AppendLine("|---|---|---|---|---|---|---|")

    foreach ($key in $compExperimental.Keys) {
        $c = $compExperimental[$key]
        $mName = $c.Metric
        $bMed  = $c.Baseline.Median
        $oMed  = $c.Optimized.Median
        $imp   = "$($c.ImprovementPercent)%"
        $bIqr  = $c.Baseline.IQR
        $oIqr  = $c.Optimized.IQR
        $bStd  = $c.Baseline.StdDev
        [void]$sb.AppendLine("| $mName | $bMed | $oMed | $imp | $bIqr | $oIqr | $bStd |")
    }
}

$markdownReport = $sb.ToString()
Write-Host ""
Write-Host $markdownReport

if ($OutputPath) {
    try {
        $outDir = Split-Path -Path $OutputPath -Parent
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            [void][System.IO.Directory]::CreateDirectory($outDir)
        }
        [System.IO.File]::WriteAllText($OutputPath, $markdownReport, [System.Text.Encoding]::UTF8)
        Write-Host "Report exported to: $OutputPath" -ForegroundColor Green
    } catch {
        Write-Warning "Could not export report to ${OutputPath}. Error: $_"
    }
}

return [PSCustomObject]@{
    StandardComparison     = $compStandard
    ExperimentalComparison = $compExperimental
    Markdown               = $markdownReport
}
