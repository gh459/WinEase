# Phase 13: 13-export
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# The diagnostic directory can disappear while a build is running (for example when
# a concurrent test or dry run rotates build_diagnostics). Re-create it before DISM
# writes its /LogPath and before the integrity report is appended, so the export is
# not aborted by a missing directory.
if ($script:DiagDir -and -not (Test-Path -LiteralPath $script:DiagDir)) {
    New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
}

# 13. Export modified image
$finalEsd = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.esd"
$tempWim  = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install_export.wim"
$exportScratch = Join-Path -Path $baseWorkDir -ChildPath "dism_export_scratch"

# Clean up any leftover temporary/broken export files and scratch dir
Remove-Item -LiteralPath $finalEsd -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $exportScratch) {
    Remove-Item -LiteralPath $exportScratch -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $exportScratch -ErrorAction SilentlyContinue | Out-Null

# Flush memory and release native file handles prior to export
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Milliseconds 500

$exportSuccess = $false
$script:StreamIntegrityVerified = $false
$script:StreamIntegrityMethod = "NOT VERIFIED"
$dismExportLog = Join-Path -Path $script:DiagDir -ChildPath "dism_export.log"
$exportIntegrityReport = Join-Path -Path $script:DiagDir -ChildPath "dism_export_integrity_report.txt"

# Preserve pre-export original WIM backup (outside ISO input tree, uniquely keyed by BuildId) (Rule 5)
$destWimBackup = Join-Path -Path $baseWorkDir -ChildPath "install_pre_export_backup_$($script:BuildId).wim"
$tempExportWim = Join-Path -Path $baseWorkDir -ChildPath "install_export_temp_$($script:BuildId).wim"

if (Test-Path -LiteralPath $destWim) {
    $script:DiagnosticData.PreExportWimSha256 = (Get-FileHash -LiteralPath $destWim -Algorithm SHA256).Hash
}

# Standard WIM Export with Resilient Compression (/Compress:max -> /Compress:fast) with STRICT /CheckIntegrity (Rule 3)
# G2: outer retry loop (2 passes) for transient export glitches
$exportAttempt = 0
$exportMaxAttempts = 2
$minExportBytes = Get-WinEaseMinimumExportBytes -SourceBytes $(if (Test-Path -LiteralPath $destWim) { (Get-Item -LiteralPath $destWim).Length } else { 0 })
while (-not $exportSuccess -and $exportAttempt -lt $exportMaxAttempts) {
    $exportAttempt++
    if ($exportAttempt -gt 1) {
        Write-Host "Retrying export (pass $exportAttempt of $exportMaxAttempts) after cooldown..." -ForegroundColor Yellow
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 5
    }
    $compressModes = if ($fastExport) { @("/Compress:fast") } else { @("/Compress:max", "/Compress:fast") }
    foreach ($compMode in $compressModes) {
    Write-Host "Exporting modified image to single-edition install.wim ($compMode /CheckIntegrity)..." -ForegroundColor Green
    if (Test-Path -LiteralPath $tempExportWim) {
        Remove-Item -LiteralPath $tempExportWim -Force -ErrorAction Stop
    }

    $exportCmdStr = "dism.exe /English /Export-Image /SourceImageFile:`"$destWim`" /SourceIndex:$index /DestinationImageFile:`"$tempExportWim`" $compMode /ScratchDir:`"$exportScratch`" /CheckIntegrity /LogPath:`"$dismExportLog`""
    $script:DiagnosticData.ExportCommand = $exportCmdStr

    $exportOut = & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$tempExportWim" $compMode "/ScratchDir:$exportScratch" /CheckIntegrity "/LogPath:$dismExportLog" 2>&1
    $exportExit = $LASTEXITCODE
    $script:DiagnosticData.ExportExitCode = $exportExit

    $integrityEntry = @(
        "=== Phase 13 Export-Image ($compMode /CheckIntegrity) ===",
        "Timestamp:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Command:    $exportCmdStr",
        "ExitCode:   $exportExit",
        "Raw Output:",
        ($exportOut -join "`r`n"),
        "=========================================================="
    ) -join "`r`n"
    [System.IO.File]::AppendAllText($exportIntegrityReport, "$integrityEntry`r`n", [System.Text.Encoding]::UTF8)

    if ($exportExit -eq 0 -and (Test-Path -LiteralPath $tempExportWim) -and ((Get-Item -LiteralPath $tempExportWim).Length -gt $minExportBytes)) {
        $exportSuccess = $true
        break
    } else {
        Write-Host "Notice: Export with $compMode /CheckIntegrity failed (Exit code: $exportExit)." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $tempExportWim) {
            Remove-Item -LiteralPath $tempExportWim -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

}

if (-not $exportSuccess) {
    $script:ExportSucceeded = $false
    $script:DiagnosticData.ExportSucceeded = $false
    $script:DiagnosticData.FailurePhase = "Phase 13: Export Image"
    $script:DiagnosticData.FailureMessage = "Export-Image with /CheckIntegrity failed under all compression modes. Retaining original pre-export WIM for diagnosis."
    Write-WinEaseDiagnosticReport "Export failed"
    throw "Phase 13: Export-Image with /CheckIntegrity failed under all compression modes. Halting build to preserve pre-export WIM."
}

# Verify exported temporary WIM metadata before replacing original
$null = & dism.exe /English /Get-WimInfo "/WimFile:$tempExportWim" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Phase 13: Exported temporary WIM metadata inspection failed."
}

# Step 2: Move original WIM to unique backup outside ISO tree (Rule 5)
# Step 3: Move export output to final install.wim (restores the original if this step fails)
[void](Invoke-WinEasePromoteExportedWim -CurrentWim $destWim -ExportedWim $tempExportWim -BackupWim $destWimBackup)

# Step 4: Record final path existence, size, SHA256
$finalWimItem = Get-Item -LiteralPath $destWim -ErrorAction Stop
$script:DiagnosticData.ExportedWimSha256 = (Get-FileHash -LiteralPath $destWim -Algorithm SHA256).Hash
$script:ExportSucceeded = $true
$script:DiagnosticData.ExportSucceeded = $true
$script:StreamIntegrityVerified = $true
$script:StreamIntegrityMethod = "DISM /Export-Image /CheckIntegrity (ExitCode: 0)"
Write-Host "install.wim successfully exported with /CheckIntegrity ($([math]::Round($finalWimItem.Length / 1GB, 2)) GB)." -ForegroundColor Green

# Clean up export scratch directory
Remove-Item -LiteralPath $exportScratch -Recurse -Force -ErrorAction SilentlyContinue
