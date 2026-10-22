# Helper function: Write telemetry JSON to disk at the end of the build
function Save-WinEaseTelemetry {
    [CmdletBinding()]
    param(
        [string]$OutputDirectory,
        [string]$BuildId
    )
    if (-not $script:WinEaseBuildTelemetry) { return }

    try {
        if (-not $OutputDirectory) {
            $OutputDirectory = Join-Path -Path $PSScriptRoot -ChildPath '..\logs'
        }
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory -ErrorAction Stop | Out-Null
        }

        $fileName = if ($BuildId) { "telemetry_$BuildId.json" } else { "telemetry_$(Get-Date -Format 'yyyyMMdd_HHmmss').json" }
        $outputPath = Join-Path -Path $OutputDirectory -ChildPath $fileName

        $json = $script:WinEaseBuildTelemetry | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($outputPath, $json, [System.Text.Encoding]::UTF8)
        return $outputPath
    } catch {
        Write-Warning "Could not save telemetry JSON: $_"
        return $null
    }
}
