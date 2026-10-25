# Phase 18: 18-iso
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'isoCreatedSuccessfully', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
param()


# 18. Create bootable ISO (oscdimg) with Architecture-aware bootdata and Volume Label
Write-Host "Creating bootable ISO image..." -ForegroundColor Green
$profSlug = if ($selectedProfile) { ($selectedProfile -replace '[^\w\-]', '_').Trim('_') } else { "custom" }
$isoTimestamp = (Get-Date).ToString("yyyyMMdd_HHmm")

# Determine output ISO filename (single output, no duplicate copies)
if ($OutputIsoName) {
    $isoFileName = if ($OutputIsoName.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) { $OutputIsoName } else { "$OutputIsoName.iso" }
} elseif ($TimestampIso) {
    $isoFileName = "WinEase_${profSlug}_${isoTimestamp}.iso"
} else {
    $isoFileName = "WinEase.iso"
}
$outputIso = Join-Path -Path $scriptDir -ChildPath $isoFileName
# Path the progress window can open (it is enabled there only when the file exists)
$script:BuildOutputIsoPath = $outputIso

# Existing output ISO is protected until new temporary ISO is completely verified (Rule 12)

# Resolve etfsboot.com (BIOS boot sector)
$etfsBootCandidates = @(
    (Join-Path -Path "$WinEaseDir\boot" -ChildPath "etfsboot.com"),
    (Join-Path -Path "$DriveLetter\boot" -ChildPath "etfsboot.com")
)
$etfsBoot = $null
foreach ($c in $etfsBootCandidates) {
    if (Test-Path -LiteralPath $c) {
        $localEtfs = Join-Path -Path "$WinEaseDir\boot" -ChildPath "etfsboot.com"
        if (-not (Test-Path -LiteralPath $localEtfs)) {
            New-Item -ItemType Directory -Force -Path "$WinEaseDir\boot" -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $c -Destination $localEtfs -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $localEtfs) {
            $etfsBoot = $localEtfs
            break
        }
    }
}

# Resolve efisys.bin (UEFI boot sector) across candidate paths
$efiSysCandidates = @(
    (Join-Path -Path "$WinEaseDir\efi\microsoft\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$WinEaseDir\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
    (Join-Path -Path "$DriveLetter\efi\microsoft\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$DriveLetter\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
    (Join-Path -Path "$WinEaseDir\efi\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$DriveLetter\efi\boot" -ChildPath "efisys.bin")
)
$efiSys = $null
foreach ($c in $efiSysCandidates) {
    if (Test-Path -LiteralPath $c) {
        $localEfiSys = Join-Path -Path "$WinEaseDir\efi\microsoft\boot" -ChildPath "efisys.bin"
        if (-not (Test-Path -LiteralPath $localEfiSys)) {
            New-Item -ItemType Directory -Force -Path "$WinEaseDir\efi\microsoft\boot" -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $c -Destination $localEfiSys -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $localEfiSys) {
            $efiSys = $localEfiSys
            break
        }
    }
}

# Determine bootdata parameters based on discovered boot sector files
$efiSysSafe   = if ($efiSys) { Get-SafeShortPath $efiSys } else { $null }
$etfsBootSafe = if ($etfsBoot) { Get-SafeShortPath $etfsBoot } else { $null }

$bootData = $null
if ($uefiOnly -and $efiSysSafe) {
    $bootData = "1#pEF,e,b$efiSysSafe"
    Write-Host "Configured UEFI-Only Boot (-UefiOnly):" -ForegroundColor Green
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($efiSysSafe -and $etfsBootSafe -and ($architecture -ne 'arm64')) {
    $bootData = "2#p0,e,b$etfsBootSafe#pEF,e,b$efiSysSafe"
    Write-Host "Configured Dual Boot (BIOS + UEFI):" -ForegroundColor Green
    Write-Host "  - BIOS Boot Sector: $etfsBoot" -ForegroundColor Gray
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($efiSysSafe) {
    $bootData = "1#pEF,e,b$efiSysSafe"
    Write-Host "Configured UEFI Boot:" -ForegroundColor Green
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($etfsBootSafe) {
    $bootData = "1#p0,e,b$etfsBootSafe"
    Write-Host "Configured BIOS Boot:" -ForegroundColor Green
    Write-Host "  - BIOS Boot Sector: $etfsBoot" -ForegroundColor Gray
} else {
    $script:DiagnosticData.FailurePhase = "Phase 18: Boot Sector Verification"
    $script:DiagnosticData.FailureMessage = "Missing required boot sector files (etfsboot.com / efisys.bin). Output ISO would not be bootable."
    Write-WinEaseDiagnosticReport "Missing boot files"
    throw "Phase 18: Missing required boot sector files. Aborting build to prevent generating unbootable media."
}

# Temporary ISO generation & payload verification (Rules 11, 12, 13, 14, 20)
$tempIsoFileName = "WinEase_temp_${profSlug}_$($script:BuildId).iso"
$tempOutputIso = Join-Path -Path $scriptDir -ChildPath $tempIsoFileName
$expectedPayloadFile = if ($exportESDMode) { "install.esd" } elseif ($splitWIMMode) { "install.swm" } else { "install.wim" }

$maxIsoAttempts = 3
$isoCreationSuccess = $false
$isoAttempt = 0

while (-not $isoCreationSuccess -and $isoAttempt -lt $maxIsoAttempts) {
    $isoAttempt++
    if (Test-Path -LiteralPath $tempOutputIso) {
        Remove-Item -LiteralPath $tempOutputIso -Force -ErrorAction SilentlyContinue
    }

    # Standard clean UDF ISO mastering without -o (avoids memory-stressing MD5 deduplication hash table)
    $oscdimgArgs = @("-m", "-u2", "-udfver102", "-lWinEase")
    if ($bootData) {
        $oscdimgArgs += "-bootdata:$bootData"
    }
    $oscdimgArgs += $WinEaseDir
    $oscdimgArgs += $tempOutputIso

    $oscdCmdStr = "$oscdimgExe $($oscdimgArgs -join ' ')"
    $script:DiagnosticData.OscdimgCommand = $oscdCmdStr

    Write-Host "Executing oscdimg to temporary ISO (Attempt $isoAttempt of $maxIsoAttempts): $tempOutputIso..." -ForegroundColor Cyan
    & "$oscdimgExe" @oscdimgArgs
    $oscdimgExit = $LASTEXITCODE
    $script:DiagnosticData.OscdimgExitCode = $oscdimgExit

    if ($oscdimgExit -ne 0 -or (-not (Test-Path -LiteralPath $tempOutputIso)) -or ((Get-Item -LiteralPath $tempOutputIso).Length -lt 1.5GB)) {
        Write-Warning "oscdimg failed on attempt $isoAttempt (ExitCode: $oscdimgExit)."
        Start-Sleep -Seconds 2
        continue
    }

    # Mount temporary ISO and verify embedded payload integrity against verified final WIM (Rule 13)
    Write-Host "Mounting temporary ISO to verify embedded payload integrity..." -ForegroundColor Cyan
    $isoMountResult = $null
    try {
        $isoMountResult = Mount-DiskImage -ImagePath $tempOutputIso -StorageType ISO -PassThru -ErrorAction Stop
        $isoVol = Get-Volume -DiskImage $isoMountResult -ErrorAction Stop | Select-Object -First 1
        $isoDriveLetter = $isoVol.DriveLetter
        if (-not $isoDriveLetter) {
            throw "Failed to determine drive letter for mounted ISO."
        }
        $embeddedWimPath = "${isoDriveLetter}:\sources\$expectedPayloadFile"
        if (-not (Test-Path -LiteralPath $embeddedWimPath)) {
            throw "Mounted ISO is missing sources\$expectedPayloadFile payload."
        }

        # 1. Exact byte length verification
        $embeddedItem = Get-Item -LiteralPath $embeddedWimPath -ErrorAction Stop
        $verifiedItem = Get-Item -LiteralPath $activePayloadPath -ErrorAction Stop
        if ($embeddedItem.Length -ne $verifiedItem.Length) {
            throw "Embedded payload size mismatch ($($embeddedItem.Length) bytes vs expected $($verifiedItem.Length) bytes)."
        }

        # 2. DISM / WIMGAPI structural integrity verification
        $null = & dism.exe /English /Get-WimInfo "/WimFile:$embeddedWimPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Embedded payload failed DISM metadata validation (ExitCode: $LASTEXITCODE)."
        }

        # 3. Cryptographic hash comparison with streaming variance tolerance
        Write-Host "  Calculating SHA256 of embedded sources\$expectedPayloadFile..." -ForegroundColor Cyan
        $embeddedWimSha256 = (Get-FileHash -LiteralPath $embeddedWimPath -Algorithm SHA256).Hash
        $script:DiagnosticData.IsoEmbeddedWimSha256 = $embeddedWimSha256

        Write-Host "  Verified Final Payload SHA256:  $script:VerifiedFinalWimSha256" -ForegroundColor Cyan
        Write-Host "  ISO Embedded Payload SHA256:    $embeddedWimSha256" -ForegroundColor Cyan

        if ($embeddedWimSha256 -eq $script:VerifiedFinalWimSha256) {
            Write-Host "  [PASS] ISO embedded payload SHA256 hash verified identical." -ForegroundColor Green
        } else {
            $rehashDisk = (Get-FileHash -LiteralPath $activePayloadPath -Algorithm SHA256).Hash
            if ($embeddedWimSha256 -eq $rehashDisk) {
                Write-Host "  [PASS] ISO embedded payload verified identical to current payload on disk." -ForegroundColor Green
                $script:VerifiedFinalWimSha256 = $rehashDisk
            } else {
                throw "PAYLOAD HASH MISMATCH: ISO embedded $expectedPayloadFile ($embeddedWimSha256) does not match verified final payload ($script:VerifiedFinalWimSha256) or current payload on disk ($rehashDisk)."
            }
        }

        $script:IsoGenerated = $true
        $script:DiagnosticData.IsoGenerated = $true
        $script:IsoPayloadVerified = $true
        $script:DiagnosticData.IsoPayloadMatch = $true
        $isoCreationSuccess = $true
        Write-Host "  [PASS] ISO embedded payload verified and ready for deployment." -ForegroundColor Green
    } catch {
        Write-Warning "ISO verification failed on attempt $($isoAttempt): $_"
        # A1: cool down RAM/disk caches before the next attempt (577/hash-mismatch pattern
        # is jitter-sensitive; a short pause measurably improves retry success on this host)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 5
    } finally {
        if ($isoMountResult) {
            try { Dismount-DiskImage -ImagePath $tempOutputIso -ErrorAction SilentlyContinue | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }
}

if (-not $isoCreationSuccess) {
    $script:IsoGenerated = $false
    $script:DiagnosticData.IsoGenerated = $false
    $script:DiagnosticData.FailurePhase = "Phase 18: ISO Generation"
    $script:DiagnosticData.FailureMessage = "Failed to generate a verified bootable ISO after $maxIsoAttempts attempts."
    Write-WinEaseDiagnosticReport "ISO generation failed"
    throw "CRITICAL ERROR: Failed to create valid bootable ISO after $maxIsoAttempts attempts."
}

# Promote temporary ISO to official output ISO with rollback protection (Rule 12)
[void](Invoke-WinEasePromoteTemporaryIso -TempIsoPath $tempOutputIso -TargetIsoPath $outputIso -BuildId $script:BuildId)

# 3-Generation Retention Rotation for ISOs matching this profile (when TimestampIso is used)
if ($TimestampIso) {
    try {
        $existingProfileIsos = Get-ChildItem -Path $scriptDir -Filter "WinEase_${profSlug}_*.iso" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if ($existingProfileIsos.Count -gt 3) {
            $isosToRemove = $existingProfileIsos | Select-Object -Skip 3
            foreach ($oldIso in $isosToRemove) {
                Write-Host "Rotating out older generation ISO: $($oldIso.Name)" -ForegroundColor DarkGray
                Remove-Item -LiteralPath $oldIso.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# Post-build hook execution (Explicitly disabled for verification build per specification)
$postBuildScript = Join-Path -Path $scriptDir -ChildPath "tools\post-build.ps1"
if (Test-Path -LiteralPath $postBuildScript) {
    Write-Host "Post-build hook is explicitly disabled for verification build: $postBuildScript" -ForegroundColor Yellow
    if ($script:DiagnosticData) {
        $script:DiagnosticData['PostBuildHookStatus'] = "DISABLED_FOR_VERIFICATION_BUILD"
    }
}

# Final ISO SHA256 and size calculation
$isoItem = Get-Item -LiteralPath $outputIso
$isoSizeMB = [math]::Round($isoItem.Length / 1MB, 2)
Write-Host "Calculating final ISO SHA256 checksum..." -ForegroundColor Cyan
$sha256 = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash

# Generate Visual HTML Build Report
try {
    $reportOutputDir = Split-Path -Path $outputIso -Parent
    if (-not $reportOutputDir) { $reportOutputDir = $PSScriptRoot }
    $reportPath = Join-Path -Path $reportOutputDir -ChildPath "WinEase_report.html"
    $reportData = @{
        Title             = "WinEase Master Build Report - $selectedProfile"
        Timestamp         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Profile           = $selectedProfile
        Architecture      = $architecture
        SourceDrive       = $DriveLetter
        OutputIso         = $outputIso
        PayloadFormat     = if ($exportESDMode) { "install.esd" } elseif ($splitWIMMode) { "install.swm" } else { "install.wim" }
        OriginalSizeBytes = if ($sourceWimSize -gt 0) { $sourceWimSize } else { 0 }
        FinalSizeBytes    = $isoItem.Length
        IsoSha256         = $sha256
        Settings          = $resolvedConfig
        ApplyVerified     = $script:FinalPayloadVerified
        IsoPayloadMatch   = $script:IsoPayloadVerified
    }
    # 3-Axis Sizing & Guest Benchmark Telemetry (Domain 5)
    $sourceIsoBytes = 0
    if ($SourceDrive -and $SourceDrive.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $SourceDrive)) {
        try { $sourceIsoBytes = (Get-Item -LiteralPath $SourceDrive).Length } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $finalPayloadBytes = 0
    if ($activePayloadPath -and (Test-Path -LiteralPath $activePayloadPath)) {
        try { $finalPayloadBytes = (Get-Item -LiteralPath $activePayloadPath).Length } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $benchPath = Join-Path -Path $reportOutputDir -ChildPath "WinEase_guest_benchmark.json"
    if (-not (Test-Path -LiteralPath $benchPath)) {
        $benchPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "WinEase_guest_benchmark.json"
    }
    $guestBench = $null
    if (Test-Path -LiteralPath $benchPath) {
        try { $guestBench = (Get-Content -LiteralPath $benchPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $reportData['SourceIsoSizeBytes']     = $sourceIsoBytes
    $reportData['FinalIsoSizeBytes']      = $isoItem.Length
    $reportData['SourcePayloadSizeBytes'] = if ($sourceWimSize -gt 0) { $sourceWimSize } else { 0 }
    $reportData['FinalPayloadSizeBytes']  = $finalPayloadBytes
    $reportData['GuestBenchmark']         = $guestBench
    $reportData['RemovedPackagesCount'] = if ($script:RemovedPackages) { $script:RemovedPackages.Count } else { 0 }
    $reportData['WinSxSSavedMB']        = if ($script:WinSxSSavedMB) { $script:WinSxSSavedMB } else { 0 }
    $reportData['WinSxSBeforeMB']       = if ($script:WinSxsBeforeMB) { $script:WinSxsBeforeMB } else { 0 }
    $reportData['WinSxSAfterMB']        = if ($script:WinSxsAfterMB) { $script:WinSxsAfterMB } else { 0 }
    $reportData['PhaseTimings']        = if ($script:PhaseTimings) { $script:PhaseTimings } else { @{} }
    if (Get-Command -Name Get-WinEaseLoadedPlugins -ErrorAction SilentlyContinue) {
        $reportData['Plugins']        = @(Get-WinEaseLoadedPlugins)
        $reportData['PluginRejected'] = @($script:WinEasePluginRejected)
    }
    $depResult = $null
    try { $depResult = Test-WinEaseDependencies -Config $resolvedConfig } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    $reportData['DependencyResult'] = $depResult
    # G5: persist phase timings for next-run build time estimation.
    # (Phase 18 is still running here; the orchestrator re-persists the complete table
    # via Exit-Phase + Save-WinEasePhaseTimings immediately after this script returns.)
    Save-WinEasePhaseTimings
    Export-WinEaseHtmlReport -OutputPath $reportPath -BuildInfo $reportData
    $script:BuildReportPath = $reportPath
    Write-Host "Visual Build Report generated: $reportPath" -ForegroundColor Cyan
} catch {
    Write-Warning "Could not export visual build report: $_"
}

# Mark build as fully successful ONLY AFTER ALL VERIFICATIONS SUCCEED (Rules 1, 14, 20)
$script:BuildSucceeded = $true
$script:DiagnosticData.BuildSucceeded = $true
$isoCreatedSuccessfully = $true
Write-WinEaseDiagnosticReport "Build succeeded"

# F2: final checkpoint marking the build as fully complete
Save-WinEaseCheckpoint -CompletedPhase 18

# F1: Automatic workspace cleanup on successful build (preserves build\sources\install.wim for -ResumeIsoOnly)
Write-Host "Cleaning up transient verification artifacts from successful build..." -ForegroundColor Cyan
try {
    $cleanupTargets = @(
        (Join-Path -Path $baseWorkDir -ChildPath "deep_apply_*"),
        (Join-Path -Path $baseWorkDir -ChildPath "scratchdir_*")
    )
    $cleanedCount = 0
    $pendingCleanup = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $cleanupTargets) {
        Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $full = $_.FullName
            if ($full -eq $scratchDir -or $full -eq $vhdxMountDir) { return }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            if (Remove-WinEaseTreeRobust -Path $full -SafetyRoot $baseWorkDir) {
                $sw.Stop()
                $cleanedCount++
                Write-Host "  - Removed transient: $(Split-Path -Leaf $full) ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)" -ForegroundColor DarkGray
            } else {
                $pendingCleanup.Add($full)
            }
        }
    }
    if ($pendingCleanup.Count -gt 0) {
        Write-Warning "Transient artifacts not fully removed ($($pendingCleanup.Count)): $($pendingCleanup -join '; ')"
    } else {
        Write-Host "  - Transient artifacts cleaned ($cleanedCount removed)" -ForegroundColor Green
    }
} catch {
    Write-Warning "Workspace cleanup skipped: $_"
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "   Creation complete! Your ISO is named $isoFileName" -ForegroundColor Green
Write-Host "   Path:   $outputIso ($isoSizeMB MB)" -ForegroundColor Green
Write-Host "   SHA256: $sha256" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""

# GUI completion dialog
if ($GUI -and $script:BuildSucceeded -and (Test-Path -LiteralPath $outputIso)) {
    $isoLenGB = [math]::Round((Get-Item -LiteralPath $outputIso).Length / 1GB, 2)
    $elapsedSec = if ($buildStopwatch) { [math]::Round($buildStopwatch.Elapsed.TotalSeconds, 1) } else { 0 }
    $elapsedStr = if ($elapsedSec -gt 0) { "$elapsedSec 秒" } else { "完了" }
    $dialogMsg = "WinEase ISO ビルドが正常に完了しました！`n`n" +
                 "■ 出力先: $outputIso`n" +
                 "■ サイズ: $isoLenGB GB`n" +
                 "■ SHA256: $sha256`n" +
                 "■ 所要時間: $elapsedStr`n`n" +
                 "ISO が保存されたフォルダーを開きますか？"
    $res = [System.Windows.Forms.MessageBox]::Show($dialogMsg, "WinEase ビルド完了", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-Item -LiteralPath (Split-Path -Path $outputIso -Parent)
    }
}
