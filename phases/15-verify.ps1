# Phase 15: 15-verify
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 15. Verify final installation payload
$wimCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"

if (-not (Test-Path -LiteralPath $wimCheck) -or ((Get-Item -LiteralPath $wimCheck).Length -lt 500MB)) {
    $script:DiagnosticData.FailurePhase = "Phase 15: Payload Verification"
    $script:DiagnosticData.FailureMessage = "No valid install.wim found in $nano11Dir\sources"
    Write-Nano11DiagnosticReport "Missing install.wim"
    throw "CRITICAL ERROR: No valid installation payload (install.wim) found in $nano11Dir\sources!"
}

$wimSizeGB = [math]::Round((Get-Item -LiteralPath $wimCheck).Length / 1GB, 2)
Write-Host "Final installation image confirmed: install.wim ($wimSizeGB GB)" -ForegroundColor Green

# 1. Metadata Verification & Dynamic Capacity Assessment via DISM /Get-WimInfo (Rule 8)
Write-Host "Verifying install.wim metadata structure and target capacity..." -ForegroundColor Cyan
$verifyApply = Join-Path -Path $baseWorkDir -ChildPath "deep_apply_verification_$($script:BuildId)"
$verifyScratch = Join-Path -Path $baseWorkDir -ChildPath "deep_apply_scratch_$($script:BuildId)"
$verifyLog = Join-Path -Path $script:DiagDir -ChildPath "dism_deep_apply.log"
$verifyReport = Join-Path -Path $script:DiagDir -ChildPath "final_apply_report.txt"

$metaCapInfo = Test-Nano11MetadataAndCapacity `
    -WimPath $wimCheck `
    -ExpectedEdition $targetEditionName `
    -ExpectedArch $architecture `
    -VerifyApplyDir $verifyApply `
    -VhdxFilePath $vhdxPath `
    -IsVhdx $script:IsVhdxMounted

$metadataStatus = "PASS"
Write-Host "  - Verified Edition:     $($metaCapInfo.EditionName)" -ForegroundColor Green
Write-Host "  - Verified Arch:        $($metaCapInfo.Architecture)" -ForegroundColor Green
Write-Host "  - Expanded Image Size:  $($metaCapInfo.ExpandedSizeGB) GB" -ForegroundColor Green
Write-Host "  - Required Space:       $($metaCapInfo.RequiredSpaceGB) GB" -ForegroundColor Green
Write-Host "  - Available Free Space: $($metaCapInfo.TargetFreeGB) GB" -ForegroundColor Green

# 2. Mandatory Deep Apply Verification of Final Payload with Automatic Self-Healing (Rule 6)
Write-Host "Performing mandatory deep apply verification of install.wim via DISM..." -ForegroundColor Cyan

$maxApplyAttempts = 5
$applySuccess = $false
$currentAttempt = 0

while (-not $applySuccess -and $currentAttempt -lt $maxApplyAttempts) {
    $currentAttempt++
    if (Test-Path -LiteralPath $verifyApply) {
        Remove-Item -LiteralPath $verifyApply -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $verifyScratch) {
        Remove-Item -LiteralPath $verifyScratch -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $verifyApply -Force | Out-Null
    New-Item -ItemType Directory -Path $verifyScratch -Force | Out-Null

    $applyCmdStr = "dism.exe /English /Apply-Image /ImageFile:`"$wimCheck`" /Index:1 /ApplyDir:`"$verifyApply`" /CheckIntegrity /Verify /ScratchDir:`"$verifyScratch`" /LogPath:`"$verifyLog`""
    $script:DiagnosticData.FinalApplyCommand = $applyCmdStr

    Write-Host "  Executing: $applyCmdStr (Attempt $currentAttempt of $maxApplyAttempts)" -ForegroundColor Cyan
    $applyOut = & dism.exe /English /Apply-Image "/ImageFile:$wimCheck" "/Index:1" "/ApplyDir:$verifyApply" /CheckIntegrity /Verify "/ScratchDir:$verifyScratch" "/LogPath:$verifyLog" 2>&1
    $applyExit = $LASTEXITCODE
    $script:DiagnosticData.FinalApplyExitCode = $applyExit

    $applyReportEntry = @(
        "=== Phase 15 Final Payload Deep Apply Verification (Attempt $currentAttempt) ===",
        "Timestamp:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Command:    $applyCmdStr",
        "ExitCode:   $applyExit",
        "Raw Output:",
        ($applyOut -join "`r`n"),
        "======================================================="
    ) -join "`r`n"
    [System.IO.File]::AppendAllText($verifyReport, "$applyReportEntry`r`n", [System.Text.Encoding]::UTF8)

    if ($applyExit -eq 0) {
        $applySuccess = $true
        break
    }

    Write-Warning "DISM /Apply-Image /Verify returned ExitCode: $applyExit on attempt $currentAttempt."

    # Parse failed files from DISM log
    $failedFiles = Get-Nano11DeepApplyFailedFiles -LogPath $verifyLog -ApplyDir $verifyApply
    Write-Host "  Detected $($failedFiles.Count) failing file path(s) in DISM log:" -ForegroundColor Yellow
    foreach ($ff in $failedFiles) {
        Write-Host "    - $ff" -ForegroundColor Yellow
    }

    # Reference images to search for verified clean replacements
    $refList = @()
    if ($destWimBackup -and (Test-Path -LiteralPath $destWimBackup)) {
        $refList += [PSCustomObject]@{ Path = $destWimBackup; PreferredIndex = $index }
    }
    if ($sourceWim -and (Test-Path -LiteralPath $sourceWim)) {
        $refList += [PSCustomObject]@{ Path = $sourceWim; PreferredIndex = $index }
    }
    if ($sourceEsd -and (Test-Path -LiteralPath $sourceEsd)) {
        $refList += [PSCustomObject]@{ Path = $sourceEsd; PreferredIndex = $index }
    }

    $repairs = [System.Collections.Generic.List[object]]::new()
    $transientCount = 0

    foreach ($ff in $failedFiles) {
        Write-Host "  Investigating file integrity in WIM: $ff..." -ForegroundColor Cyan
        $fp = Get-Nano11WimFileFingerprint -WimPath $wimCheck -Index 1 -ImagePath $ff -WorkDir $baseWorkDir
        if ($fp -and $fp.StableRead -and $fp.Signature -eq 'Valid') {
            # File inside WIM is stable and digitally valid. DISM hit transient decompression glitch in RAM/cache.
            Write-Host "    [TRANSIENT] $ff stream in WIM is valid (SHA1: $($fp.Sha1), Sig: $($fp.Signature)). DISM hit transient decompression glitch." -ForegroundColor Yellow
            $transientCount++
        } else {
            # Stream inside WIM is corrupted or invalid. Find a clean replacement and repair.
            Write-Host "    [CORRUPTED] $ff stream in WIM is invalid or modified. Searching reference media for clean original..." -ForegroundColor Red
            $goodCopy = Find-Nano11ReferenceWimFile -ImagePath $ff -References $refList -WorkDir $baseWorkDir
            if ($goodCopy) {
                Write-Host "    [FOUND] Clean replacement found in $($goodCopy.Source) (SHA1: $($goodCopy.Sha1))" -ForegroundColor Green
                $repairs.Add([PSCustomObject]@{
                    ImagePath = $ff
                    GoodFile  = $goodCopy.File
                    GoodSha1  = $goodCopy.Sha1
                    Source    = $goodCopy.Source
                    RunDir    = $goodCopy.RunDir
                })
            } else {
                Write-Warning "    Could not find a valid reference copy for $ff."
            }
        }
    }

    if ($repairs.Count -gt 0) {
        Write-Host "Self-Healing: Repairing $($repairs.Count) corrupted stream(s) in install.wim..." -ForegroundColor Green
        try {
            $repairCompMode = if ($fastExport) { '/Compress:fast' } else { '/Compress:max' }
            Repair-Nano11WimFiles -WimPath $wimCheck -Repairs $repairs -WorkDir $baseWorkDir -CompressMode $repairCompMode -LogPath (Join-Path -Path $script:DiagDir -ChildPath "dism_repair_export.log")
            Write-Host "  Self-Healing repair and re-export succeeded! Re-running verification..." -ForegroundColor Green
        } catch {
            Write-Error "Self-Healing repair failed: $_"
        } finally {
            foreach ($r in $repairs) {
                if ($r.RunDir -and (Test-Path -LiteralPath $r.RunDir)) {
                    & cmd.exe /c "rd /s /q `"$($r.RunDir)`"" > $null 2>&1
                }
            }
        }
    } else {
        # Transient errors or no repairs identified; cool down caches and retry
        Write-Host "Cooling down file-system cache and RAM prior to retry..." -ForegroundColor Cyan
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 5
    }
}

if (-not $applySuccess) {
    $script:FinalPayloadVerified = $false
    $script:DiagnosticData.FinalPayloadVerified = $false
    $script:DiagnosticData.FailurePhase = "Phase 15: Deep Apply Verification"
    $script:DiagnosticData.FailureMessage = "DISM /Apply-Image /CheckIntegrity /Verify failed with ExitCode: $applyExit after $maxApplyAttempts attempts. Verification directory and logs preserved."
    Write-Nano11DiagnosticReport "Deep apply failed"
    throw "CRITICAL ERROR: install.wim failed deep apply verification (ExitCode: $applyExit). This payload would cause Windows Setup to fail with 0x80070570. Halting build to preserve evidence."
}

$script:FinalPayloadVerified = $true
$script:DiagnosticData.FinalPayloadVerified = $true
$script:VerifiedFinalWimSha256 = (Get-FileHash -LiteralPath $wimCheck -Algorithm SHA256).Hash
$script:DiagnosticData.FinalWimSha256 = $script:VerifiedFinalWimSha256
Write-Host "  [PASS] Deep apply verification completed successfully (ExitCode: 0)." -ForegroundColor Green
Write-Host "  [SHA256] Final WIM: $script:VerifiedFinalWimSha256" -ForegroundColor Green

# Auxiliary File Inspection (-Validate) (Rule 15)
# Runs against the deep-apply directory, i.e. the fully expanded final payload. This works for every payload
# format (the WIM is still present here, before any ESD/SWM conversion) and needs no extra DISM mount.
if ($Validate) {
    Write-Host "Running auxiliary image file inspection (-Validate)..." -ForegroundColor Cyan
    & dism.exe /English /Get-WimInfo "/WimFile:$wimCheck" | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-wiminfo.txt") -Encoding utf8
    $keyFiles = @(
        'Windows\System32\osk.exe',
        'Windows\System32\ctfmon.exe',
        'Windows\System32\Sysprep\sysprep.exe',
        'Windows\System32\cmd.exe'
    )
    $valLog = @()
    foreach ($kf in $keyFiles) {
        $exists = Test-Path -LiteralPath (Join-Path -Path $verifyApply -ChildPath $kf)
        $status = "{0} : {1}" -f $kf, $exists
        $valLog += $status
        $statusColor = if ($exists) { 'Green' } else { 'Yellow' }
        Write-Host "  - Verification: $status" -ForegroundColor $statusColor
    }
    $valLog | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-paths.txt") -Encoding utf8
}

# Clean up verification scratch on success
Remove-Item -LiteralPath $verifyApply -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $verifyScratch -Recurse -Force -ErrorAction SilentlyContinue

$activePayloadPath = $wimCheck
$activePayloadName = "install.wim"

if ($exportESDMode) {
    Write-Host "Converting verified install.wim to ultra-compressed install.esd (/Compress:recovery /CheckIntegrity)..." -ForegroundColor Cyan
    $esdOutPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.esd"
    & dism.exe /English /Export-Image "/SourceImageFile:$wimCheck" /SourceIndex:1 "/DestinationImageFile:$esdOutPath" /Compress:recovery /CheckIntegrity "/LogPath:$dismExportLog"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $esdOutPath)) {
        throw "CRITICAL ERROR: Failed to convert verified install.wim to install.esd (ExitCode: $LASTEXITCODE)."
    }
    Remove-Item -LiteralPath $wimCheck -Force -ErrorAction Stop
    $activePayloadPath = $esdOutPath
    $activePayloadName = "install.esd"
    $script:VerifiedFinalWimSha256 = (Get-FileHash -LiteralPath $activePayloadPath -Algorithm SHA256).Hash
    $script:DiagnosticData.FinalWimSha256 = $script:VerifiedFinalWimSha256
    Write-Host "  [PASS] Converted to install.esd (SHA256: $script:VerifiedFinalWimSha256)" -ForegroundColor Green
} elseif ($splitWIMMode) {
    Write-Host "Splitting verified install.wim into FAT32-compatible install.swm chunks (3800 MB /CheckIntegrity)..." -ForegroundColor Cyan
    $swmOutPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.swm"
    & dism.exe /English /Split-Image "/ImageFile:$wimCheck" "/SWMFile:$swmOutPath" /FileSize:3800 /CheckIntegrity "/LogPath:$dismExportLog"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $swmOutPath)) {
        throw "CRITICAL ERROR: Failed to split verified install.wim into install.swm (ExitCode: $LASTEXITCODE)."
    }
    Remove-Item -LiteralPath $wimCheck -Force -ErrorAction Stop
    $activePayloadPath = $swmOutPath
    $activePayloadName = "install.swm"
    $script:VerifiedFinalWimSha256 = (Get-FileHash -LiteralPath $activePayloadPath -Algorithm SHA256).Hash
    $script:DiagnosticData.FinalWimSha256 = $script:VerifiedFinalWimSha256
    Write-Host "  [PASS] Split into install.swm (Primary chunk SHA256: $script:VerifiedFinalWimSha256)" -ForegroundColor Green
}

# 3. Optional Auxiliary 7-Zip Check (Relegated to auxiliary, not replacing Apply) (Rule 7)
$sevenZipCandidates = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
)
$szTool = $sevenZipCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$aux7zStatus = "SKIPPED"
if ($szTool) {
    $szOut = & "$szTool" t "$activePayloadPath" 2>&1
    $szExit = $LASTEXITCODE
    $aux7zStatus = if ($szExit -eq 0 -and -not ($szOut -match 'Data Error|ERROR:|Sub items Errors')) { "PASS" } else { "FAIL" }
}

# Output separated verification summary (Rule 7)
Write-Host "Payload Verification Summary:" -ForegroundColor Cyan
Write-Host "  - Metadata Status:         $metadataStatus" -ForegroundColor Green
Write-Host "  - Export Status:           PASS" -ForegroundColor Green
Write-Host "  - Final Apply Status:      PASS" -ForegroundColor Green
Write-Host "  - Auxiliary 7-Zip Status:  $aux7zStatus" -ForegroundColor Gray
Write-Host "  - Payload SHA256:          $script:VerifiedFinalWimSha256" -ForegroundColor Green
Write-Host "  - ISO Payload Match:       PENDING (Phase 18)" -ForegroundColor Yellow
Write-Host "  - Overall Build Status:    PENDING (Phase 18)" -ForegroundColor Yellow

$wimSummaryPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "wim-verification-summary.txt"
$finalPayloadSizeGB = [math]::Round((Get-Item -LiteralPath $activePayloadPath).Length / 1GB, 2)
$wimSummaryLines = @(
    "=== Final Payload Verification Summary ===",
    "Timestamp:               $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Target Image:            $activePayloadPath",
    "Image Size:              $finalPayloadSizeGB GB",
    "Metadata Status:         $metadataStatus",
    "Export Status:           PASS",
    "Final Apply Status:      PASS",
    "Auxiliary 7-Zip Status:  $aux7zStatus",
    "Payload SHA256:          $script:VerifiedFinalWimSha256",
    "ISO Payload Match:       PENDING",
    "Overall Build Status:    PENDING",
    "=========================================="
)
[System.IO.File]::WriteAllLines($wimSummaryPath, $wimSummaryLines, [System.Text.Encoding]::UTF8)
