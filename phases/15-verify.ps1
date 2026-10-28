# Phase 15: 15-verify
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'activePayloadName', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
param()


# Re-create the diagnostic directory if it was removed during the build (see phase 13).
if ($script:DiagDir -and -not (Test-Path -LiteralPath $script:DiagDir)) {
    New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
}

# 15. Verify final installation payload
$wimCheck = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.wim"

if (-not (Test-Path -LiteralPath $wimCheck) -or ((Get-Item -LiteralPath $wimCheck).Length -lt 500MB)) {
    $script:DiagnosticData.FailurePhase = "Phase 15: Payload Verification"
    $script:DiagnosticData.FailureMessage = "No valid install.wim found in $WinEaseDir\sources"
    Write-WinEaseDiagnosticReport "Missing install.wim"
    throw "CRITICAL ERROR: No valid installation payload (install.wim) found in $WinEaseDir\sources!"
}

$wimSizeGB = [math]::Round((Get-Item -LiteralPath $wimCheck).Length / 1GB, 2)
Write-Host "Final installation image confirmed: install.wim ($wimSizeGB GB)" -ForegroundColor Green

# 1. Metadata Verification & Dynamic Capacity Assessment via DISM /Get-WimInfo (Rule 8)
Write-Host "Verifying install.wim metadata structure and target capacity..." -ForegroundColor Cyan
$verifyApply = Join-Path -Path $baseWorkDir -ChildPath "deep_apply_verification_$($script:BuildId)"
$verifyScratch = Join-Path -Path $baseWorkDir -ChildPath "deep_apply_scratch_$($script:BuildId)"
$verifyLog = Join-Path -Path $script:DiagDir -ChildPath "dism_deep_apply.log"
$verifyReport = Join-Path -Path $script:DiagDir -ChildPath "final_apply_report.txt"

$metaCapInfo = Test-WinEaseMetadataAndCapacity `
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
    $failedFiles = Get-WinEaseDeepApplyFailedFiles -LogPath $verifyLog -ApplyDir $verifyApply
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
        $fp = Get-WinEaseWimFileFingerprint -WimPath $wimCheck -Index 1 -ImagePath $ff -WorkDir $baseWorkDir
        if ($fp -and $fp.StableRead -and $fp.Signature -eq 'Valid') {
            # File inside WIM is stable and digitally valid. DISM hit transient decompression glitch in RAM/cache.
            Write-Host "    [TRANSIENT] $ff stream in WIM is valid (SHA1: $($fp.Sha1), Sig: $($fp.Signature)). DISM hit transient decompression glitch." -ForegroundColor Yellow
            $transientCount++
        } else {
            # Stream inside WIM is corrupted or invalid. Find a clean replacement and repair.
            Write-Host "    [CORRUPTED] $ff stream in WIM is invalid or modified. Searching reference media for clean original..." -ForegroundColor Red
            $goodCopy = Find-WinEaseReferenceWimFile -ImagePath $ff -References $refList -WorkDir $baseWorkDir
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
            Repair-WinEaseWimFiles -WimPath $wimCheck -Repairs $repairs -WorkDir $baseWorkDir -CompressMode $repairCompMode -LogPath (Join-Path -Path $script:DiagDir -ChildPath "dism_repair_export.log")
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
    Write-WinEaseDiagnosticReport "Deep apply failed"
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

# Defender removal verification (runs against the fully expanded final payload).
# The offline build removes the Defender service keys and the ProgramData/Program Files
# payload, but CBS keeps the complete Defender servicing payload in WinSxS and can re-stage
# it (and re-register the service keys) on the first boot. The check below therefore
# verifies the three things that decide whether Defender comes back:
#   1. the CBS re-staging maps for Defender are gone (they are what re-stages the payload),
#   2. the Defender service keys are absent from the offline SYSTEM hive,
#   3. the Defender payload folders in Program Files / ProgramData are empty.
# A failure is reported as a warning: the image is still valid, the user is just told that
# Defender may re-appear on the installed system.
if ($removeDefender) {
    Write-Host "Verifying Windows Defender removal in the final payload..." -ForegroundColor Cyan
    $defIssues = [System.Collections.Generic.List[string]]::new()
    $defReport = [System.Collections.Generic.List[string]]::new()

    # 1. CBS re-staging maps
    $defMapDir = Join-Path -Path $verifyApply -ChildPath "Windows\WinSxS\FileMaps"
    $defMaps = @()
    if (Test-Path -LiteralPath $defMapDir) {
        $defMaps = @(Get-ChildItem -LiteralPath $defMapDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'defender' })
    }
    $defReport.Add("CBS Defender FileMaps entries : $($defMaps.Count)")
    if ($defMaps.Count -gt 0) {
        $defIssues.Add("CBS re-staging maps still present ($($defMaps.Count) entries) - Defender may be re-staged on first boot")
    }

    # 2. Defender service keys in the offline SYSTEM hive. The user-mode services are
    #    deleted; the boot-start filter drivers are kept but must be out of the boot path
    #    (Start=4, no Early-Launch group). Treating a correctly disabled driver as a
    #    surviving service made this check warn on every successful removal.
    $sysHive = Join-Path -Path $verifyApply -ChildPath "Windows\System32\config\SYSTEM"
    $defSvc = @('WinDefend','MDCoreSvc','WdNisSvc','Sense','SecurityHealthService','wscsvc','webthreatdefsvc','webthreatdefusersvc','SgrmBroker','SgrmAgent')
    $defDrv = @('WdBoot','WdFilter','WdNisDrv','MsSecCore','MsSecFlt','MsSecWfp')
    $presentSvc = @()
    $presentDrv = @()
    $badDrv = @()
    if (Test-Path -LiteralPath $sysHive) {
        $null = & reg.exe load "HKLM\zVERIFYDEF" "$sysHive" 2>&1
        if ($LASTEXITCODE -eq 0) {
          try {
            foreach ($s in $defSvc) {
                $null = & reg.exe query "HKLM\zVERIFYDEF\ControlSet001\Services\$s" 2>&1
                if ($LASTEXITCODE -eq 0) { $presentSvc += $s }
            }
            foreach ($d in $defDrv) {
                $drvKey = "Registry::HKEY_LOCAL_MACHINE\zVERIFYDEF\ControlSet001\Services\$d"
                if (-not (Test-Path -LiteralPath $drvKey)) { continue }
                $presentDrv += $d
                $drvStart = (Get-ItemProperty -LiteralPath $drvKey -Name 'Start' -ErrorAction SilentlyContinue).Start
                if ($null -eq $drvStart -or [int]$drvStart -ne 4) {
                    $badDrv += "$d (Start=$drvStart)"
                }
            }
            foreach ($d in @('WdBoot','WdFilter')) {
                $drvKey = "Registry::HKEY_LOCAL_MACHINE\zVERIFYDEF\ControlSet001\Services\$d"
                if (Test-Path -LiteralPath $drvKey) {
                    $group = (Get-ItemProperty -LiteralPath $drvKey -Name 'Group' -ErrorAction SilentlyContinue).Group
                    if (-not [string]::IsNullOrWhiteSpace("$group")) {
                        $badDrv += "$d (Group=$group)"
                    }
                }
            }
          } finally {
            # unloaded even when one of the reads above throws, so the hive never stays loaded
            & reg.exe unload "HKLM\zVERIFYDEF" > $null 2>&1
          }
        }
    }
    $defReport.Add("Defender service keys present  : $(if($presentSvc.Count){$presentSvc -join ', '}else{'none'})")
    if ($presentSvc.Count -gt 0) {
        $defIssues.Add("Defender service keys still registered: $($presentSvc -join ', ')")
    }
    $defReport.Add("Defender driver keys disabled  : $(if($presentDrv.Count){$presentDrv -join ', '}else{'none present'})")
    if ($badDrv.Count -gt 0) {
        $defIssues.Add("Defender driver keys are still active: $($badDrv -join ', ')")
    }

    # 3. Defender payload folders
    foreach ($p in @("Program Files\Windows Defender", "ProgramData\Microsoft\Windows Defender", "ProgramData\Microsoft\Windows Defender Platform", "ProgramData\Microsoft\Windows Security Health")) {
        $full = Join-Path -Path $verifyApply -ChildPath $p
        $cnt = 0
        if (Test-Path -LiteralPath $full) {
            $cnt = @(Get-ChildItem -LiteralPath $full -Recurse -Force -File -ErrorAction SilentlyContinue).Count
        }
        $defReport.Add("Payload files in $p : $cnt")
        if ($cnt -gt 0) {
            $defIssues.Add("$p still contains $cnt file(s)")
        }
    }

    # 4. Defender CBS package (best-effort removal in phase 08). A remaining package is
    #    not fatal, but it is the source a future servicing pass re-stages from.
    $defPackagesLeft = @()
    try {
        $defPackagesLeft = @(Get-WindowsPackage -Path $verifyApply -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -match 'Windows-Defender' })
    } catch { Write-Verbose "Could not enumerate Defender CBS packages: $($_.Exception.Message)" }
    $defReport.Add("Defender CBS packages present : $(if($defPackagesLeft.Count){$defPackagesLeft.Count}else{'none'})")
    if ($defPackagesLeft.Count -gt 0) {
        $defIssues.Add("Defender CBS package(s) still present: $(($defPackagesLeft | ForEach-Object { $_.PackageName }) -join ', ')")
    }

    # 5. Windows Security UI AppX payload / registration
    $secHealthDirs = @()
    foreach ($secRoot in @("Program Files\WindowsApps", "Windows\SystemApps", "ProgramData\Microsoft\Windows\AppRepository\Packages")) {
        $fullRoot = Join-Path -Path $verifyApply -ChildPath $secRoot
        if (Test-Path -LiteralPath $fullRoot) {
            $secHealthDirs += @(Get-ChildItem -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'SecHealthUI' } |
                ForEach-Object { Join-Path -Path $secRoot -ChildPath $_.Name })
        }
    }
    $defReport.Add("Security UI package entries  : $(if($secHealthDirs.Count){$secHealthDirs -join ', '}else{'none'})")
    if ($secHealthDirs.Count -gt 0) {
        $defIssues.Add("Windows Security UI package still present: $($secHealthDirs -join ', ')")
    }

    foreach ($line in $defReport) { Write-Host "  - $line" -ForegroundColor Gray }
    $defReport | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-defender.txt") -Encoding utf8
    if ($defIssues.Count -gt 0) {
        foreach ($issue in $defIssues) {
            Write-Warning "Defender verification: $issue"
        }
    } else {
        Write-Host "  - [PASS] Defender payload, service keys and CBS re-staging maps are all removed." -ForegroundColor Green
    }
}

# UI preference verification. Several UI options used to write values Windows ignores
# (mouse acceleration 1/6/10 is the enabled default) or were overwritten later in the
# phase (NoLockScreen). This checks the effective offline values, not only the code path.
Write-Host "Verifying UI preferences in the final payload..." -ForegroundColor Cyan
$uiReport = [System.Collections.Generic.List[string]]::new()
$uiIssues = [System.Collections.Generic.List[string]]::new()
$ntHivePath = Join-Path -Path $verifyApply -ChildPath "Users\Default\ntuser.dat"
$softHivePath = Join-Path -Path $verifyApply -ChildPath "Windows\System32\config\SOFTWARE"
$ntLoaded = $false
$softLoaded = $false
try {
    if (Test-Path -LiteralPath $ntHivePath) {
        $null = & reg.exe load "HKLM\zVERIFYNT" "$ntHivePath" 2>&1
        $ntLoaded = ($LASTEXITCODE -eq 0)
    }
    if (Test-Path -LiteralPath $softHivePath) {
        $null = & reg.exe load "HKLM\zVERIFYUISOFT" "$softHivePath" 2>&1
        $softLoaded = ($LASTEXITCODE -eq 0)
    }
    $getUiValue = {
        param([string]$Hive, [string]$Path, [string]$Name)
        $key = "Registry::HKEY_LOCAL_MACHINE\$Hive\$Path"
        try { return (Get-ItemProperty -LiteralPath $key -Name $Name -ErrorAction Stop).$Name } catch { return $null }
    }
    if (Test-TweakEnabled 'OptimizeVisualEffects' $true) {
        if (-not $ntLoaded) {
            $uiIssues.Add("Default user hive could not be loaded; visual effects cannot be verified")
        } else {
            foreach ($check in @(
                @{ Name = 'MinAnimate'; Path = 'Control Panel\Desktop\WindowMetrics'; Expected = '0' },
                @{ Name = 'DragFullWindows'; Path = 'Control Panel\Desktop'; Expected = '0' },
                @{ Name = 'VisualFXSetting'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Expected = 2 },
                @{ Name = 'TaskbarAnimations'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Expected = 0 },
                @{ Name = 'ListviewAlphaSelect'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Expected = 0 },
                @{ Name = 'ListviewShadow'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Expected = 0 },
                @{ Name = 'EnableTransparency'; Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Expected = 0 }
            )) {
                $actual = & $getUiValue 'zVERIFYNT' $check.Path $check.Name
                $uiReport.Add("$($check.Name) = $actual (expected $($check.Expected))")
                if ($null -eq $actual -or "$actual" -ne "$($check.Expected)") {
                    $uiIssues.Add("$($check.Name) is '$actual', expected '$($check.Expected)'")
                }
            }
        }
    }
    if (Test-TweakEnabled 'DisableMouseAcceleration' $false) {
        if (-not $ntLoaded) {
            $uiIssues.Add("Default user hive could not be loaded; mouse acceleration cannot be verified")
        } else {
            foreach ($name in @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')) {
                $actual = & $getUiValue 'zVERIFYNT' 'Control Panel\Mouse' $name
                $uiReport.Add("$name = $actual (expected 0)")
                if ($null -eq $actual -or "$actual" -ne '0') { $uiIssues.Add("$name is '$actual', expected '0'") }
            }
        }
    }
    if (Test-TweakEnabled 'DisableLockScreen' $false) {
        $noLock = if ($softLoaded) { & $getUiValue 'zVERIFYUISOFT' 'Policies\Microsoft\Windows\Personalization' 'NoLockScreen' } else { $null }
        # The SOFTWARE hive holds HKLM; zVERIFYUISOFT maps it, so the path is relative.
        $uiReport.Add("NoLockScreen = $noLock (expected 1)")
        if ($null -eq $noLock -or "$noLock" -ne '1') { $uiIssues.Add("NoLockScreen is '$noLock', expected '1'") }
    }
    if (Test-TweakEnabled 'PhotoViewerAssociations' $true) {
        $photoCmd = if ($softLoaded) { & $getUiValue 'zVERIFYUISOFT' 'Classes\PhotoViewer.FileAssoc.Jpeg\shell\open\command' '(default)' } else { $null }
        $photoJpg = if ($ntLoaded) { & $getUiValue 'zVERIFYNT' 'Software\Classes\.jpg' '(default)' } else { $null }
        $uiReport.Add("Photo Viewer JPEG command registered = $(if($photoCmd){'yes'}else{'no'})")
        $uiReport.Add("Default-user .jpg ProgID = $photoJpg (expected PhotoViewer.FileAssoc.Jpeg)")
        if (-not $photoCmd -or "$photoCmd" -notmatch 'PhotoViewer\.dll') {
            $uiIssues.Add("Photo Viewer JPEG ProgID command is not registered correctly")
        }
        if ("$photoJpg" -ne 'PhotoViewer.FileAssoc.Jpeg') {
            $uiIssues.Add("Default-user .jpg ProgID is '$photoJpg', expected 'PhotoViewer.FileAssoc.Jpeg'")
        }
    }
    foreach ($line in $uiReport) { Write-Host "  - $line" -ForegroundColor Gray }
    $uiReport | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-ui.txt") -Encoding utf8
    if ($uiIssues.Count -gt 0) {
        foreach ($issue in $uiIssues) { Write-Warning "UI verification: $issue" }
    } else {
        Write-Host "  - [PASS] Selected UI preferences are effective in the offline image." -ForegroundColor Green
    }
} finally {
    if ($ntLoaded) { & reg.exe unload "HKLM\zVERIFYNT" > $null 2>&1 }
    if ($softLoaded) { & reg.exe unload "HKLM\zVERIFYUISOFT" > $null 2>&1 }
}

# Clean up verification scratch on success (robust delete: expanded images contain
# >260-char paths and TrustedInstaller/RX-only ACLs that plain Remove-Item cannot delete)
$verifyApplySw = [System.Diagnostics.Stopwatch]::StartNew()
if (Remove-WinEaseTreeRobust -Path $verifyApply -SafetyRoot $baseWorkDir) {
    $verifyApplySw.Stop()
    Write-Host "  - Deep-apply verification directory removed ($([math]::Round($verifyApplySw.Elapsed.TotalSeconds,1))s)." -ForegroundColor DarkGray
} else {
    Write-Warning "Deep-apply verification directory could not be fully removed: $verifyApply (later cleanup will retry)"
}
[void](Remove-WinEaseTreeRobust -Path $verifyScratch -SafetyRoot $baseWorkDir)

$activePayloadPath = $wimCheck
$activePayloadName = "install.wim"

if ($exportESDMode) {
    Write-Host "Converting verified install.wim to ultra-compressed install.esd (/Compress:recovery /CheckIntegrity)..." -ForegroundColor Cyan
    $esdOutPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.esd"
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
    $swmOutPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.swm"
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

$wimSummaryPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "wim-verification-summary.txt"
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
