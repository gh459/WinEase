# WinEaseBenchmarks.ps1 - Benchmark statistics and comparison helpers
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).
# Statistical Analysis & Benchmark Comparison Utilities

function Get-WinEaseMetricStatistics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [double[]]$Values
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [PSCustomObject]@{
            Count  = 0
            Mean   = 0.0
            Median = 0.0
            Min    = 0.0
            Max    = 0.0
            StdDev = 0.0
            IQR    = 0.0
        }
    }

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    # Mean
    $sum = [System.Linq.Enumerable]::Sum([double[]]$sorted)
    $mean = [math]::Round($sum / $count, 3)

    # Median (p50)
    $median = if ($count % 2 -eq 1) {
        [double]$sorted[[math]::Floor($count / 2)]
    } else {
        $mid = [int]($count / 2)
        [double](([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0)
    }
    $median = [math]::Round($median, 3)

    # Min / Max
    $min = [double]$sorted[0]
    $max = [double]$sorted[$count - 1]

    # Sample StdDev (if count > 1, else 0)
    $stddev = 0.0
    if ($count -gt 1) {
        $sumSqDiff = 0.0
        foreach ($v in $sorted) {
            $diff = $v - $mean
            $sumSqDiff += ($diff * $diff)
        }
        $variance = $sumSqDiff / ($count - 1)
        $stddev = [math]::Round([math]::Sqrt($variance), 3)
    }

    # Interquartile Range (IQR) = Q3 - Q1
    $getPercentile = {
        param([double[]]$arr, [double]$p)
        if ($arr.Count -eq 1) { return [double]$arr[0] }
        $idx = ($arr.Count - 1) * $p
        $low = [int][math]::Floor($idx)
        $high = [int][math]::Ceiling($idx)
        if ($low -eq $high) { return [double]$arr[$low] }
        $weight = $idx - $low
        return [double]($arr[$low] * (1.0 - $weight) + $arr[$high] * $weight)
    }

    $q1 = & $getPercentile $sorted 0.25
    $q3 = & $getPercentile $sorted 0.75
    $iqr = [math]::Round(($q3 - $q1), 3)

    return [PSCustomObject]@{
        Count  = $count
        Mean   = $mean
        Median = $median
        Min    = $min
        Max    = $max
        StdDev = $stddev
        IQR    = $iqr
    }
}

function Compare-WinEaseBenchmarkSeries {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$BaselineRuns,

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$OptimizedRuns,

        [string]$OptimizedLabel = "WinEase Standard"
    )

    if ($null -eq $BaselineRuns -or $BaselineRuns.Count -eq 0 -or
        $null -eq $OptimizedRuns -or $OptimizedRuns.Count -eq 0) {
        return @{}
    }

    $extractValues = {
        param([PSCustomObject[]]$runs, [string]$metricName)
        $vals = [System.Collections.Generic.List[double]]::new()
        foreach ($r in $runs) {
            $val = $null
            if ($r.PSObject.Properties[$metricName]) {
                $val = $r.$metricName
            } elseif ($metricName -eq "CommittedMemoryMB" -and $r.Memory -and $r.Memory.CommittedMB) {
                $val = $r.Memory.CommittedMB
            } elseif ($metricName -eq "ProcessCount" -and $r.Memory -and $r.Memory.ProcessCount) {
                $val = $r.Memory.ProcessCount
            } elseif ($metricName -eq "ThreadCount" -and $r.Memory -and $r.Memory.ThreadCount) {
                $val = $r.Memory.ThreadCount
            } elseif ($metricName -eq "HandleCount" -and $r.Memory -and $r.Memory.HandleCount) {
                $val = $r.Memory.HandleCount
            } elseif ($metricName -eq "ColdCmdLatencyMs" -and $r.Probes -and $r.Probes.ColdLaunch -and $r.Probes.ColdLaunch.CmdExeMs) {
                $val = $r.Probes.ColdLaunch.CmdExeMs
            } elseif ($metricName -eq "WarmCmdLatencyMs" -and $r.Probes -and $r.Probes.WarmLaunch -and $r.Probes.WarmLaunch.CmdExeMs) {
                $val = $r.Probes.WarmLaunch.CmdExeMs
            } elseif ($metricName -eq "WindowsDirMB" -and $r.DiskFootprint -and $r.DiskFootprint.WindowsDirMB) {
                $val = $r.DiskFootprint.WindowsDirMB
            }

            if ($null -ne $val) {
                $num = 0.0
                if ([double]::TryParse([string]$val, [ref]$num)) {
                    $vals.Add($num)
                }
            }
        }
        return [double[]]$vals.ToArray()
    }

    $metricList = @(
        'CommittedMemoryMB',
        'ProcessCount',
        'ThreadCount',
        'HandleCount',
        'ColdCmdLatencyMs',
        'WarmCmdLatencyMs',
        'WindowsDirMB'
    )

    $comparison = [ordered]@{}

    foreach ($m in $metricList) {
        $baseVals = & $extractValues $BaselineRuns $m
        $optVals  = & $extractValues $OptimizedRuns $m

        if ($baseVals.Count -gt 0 -and $optVals.Count -gt 0) {
            $baseStats = Get-WinEaseMetricStatistics -Values $baseVals
            $optStats  = Get-WinEaseMetricStatistics -Values $optVals

            $pctImprovement = 0.0
            if ($baseStats.Median -gt 0) {
                $pctImprovement = [math]::Round((($baseStats.Median - $optStats.Median) / $baseStats.Median) * 100.0, 2)
            }

            $comparison[$m] = [PSCustomObject]@{
                Metric             = $m
                Baseline           = $baseStats
                Optimized          = $optStats
                OptimizedLabel     = $OptimizedLabel
                ImprovementPercent = $pctImprovement
            }
        }
    }

    return $comparison
}
