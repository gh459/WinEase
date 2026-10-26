# WinEaseResume.ps1 - Resume-ISO mode (-ResumeIsoOnly / -ResumeFromPhase) and phase checkpoints
# Dot-sourced into the script scope of WinEasebuilder.ps1 (function definitions only).
# The resume entry blocks stay in WinEasebuilder.ps1: exit inside a dot-sourced file
# would only leave that file, not the builder.

# ============================================================================
# A2. Resume-ISO Mode (-ResumeIsoOnly): Phase 14-18 fast-track from preserved payload
# Rebuilds the bootable ISO from the payload already verified & exported by a
# previous run (workspace\build\sources\install.wim), skipping Phases 1-13.
# Skipped deep-apply this run; run a timestamped full build offline whenever the
# host is stable. Designed to recover the Oct 16 "hash mismatch at the finish line"
# failure pattern without repeating a 15-minute debloat pipeline.
# ============================================================================
function Invoke-WinEaseResumeIsoBuild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'bootWimPath', Justification = 'Read by New-BuildContextFromScriptScope via dynamic scope')]
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "  WinEase RESUME-ISO MODE (-ResumeIsoOnly)" -ForegroundColor Cyan
    Write-Host "  Re-uses the preserved workspace payload; Phases 1-13 are skipped." -ForegroundColor Yellow
    Write-Host "==============================================================================" -ForegroundColor Cyan

    # 1. Resolve workspace with the same defaults as Phase 1 (Documents\WinEase_workspace)
    $resumeWorkDir = $null
    if ($WorkDir) {
        $resumeWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
    } else {
        $docsDirResume = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDirResume) { $docsDirResume = Join-Path -Path $env:USERPROFILE -ChildPath "Documents" }
        $resumeWorkDir = Join-Path -Path $docsDirResume -ChildPath "WinEase_workspace"
    }
    # 1.5. Validate workspace integrity via Test-WinEaseResumeIntegrity
    Write-Host "Verifying workspace structural integrity for resume..." -ForegroundColor Cyan
    $expectedArch = if (Get-Variable -Name 'architecture' -Scope Script -ErrorAction SilentlyContinue) { "$script:architecture" } else { '' }
    $expectedEd = if (Get-Variable -Name 'targetEditionName' -Scope Script -ErrorAction SilentlyContinue) { "$script:targetEditionName" } else { '' }
    $integrity = Test-WinEaseResumeIntegrity -WorkspaceDir $resumeWorkDir -IsIsoOnly -ExpectedArchitecture $expectedArch -ExpectedEdition $expectedEd
    if (-not $integrity.IsValid) {
        throw "ResumeIsoOnly integrity check failed:`n - " + ($integrity.Errors -join "`n - ")
    }
    if ($integrity.Warnings.Count -gt 0) {
        foreach ($w in $integrity.Warnings) { Write-Warning "Resume warning: $w" }
    }

    $resumeNanoDir = Join-Path -Path $resumeWorkDir -ChildPath "build"
    if (-not (Test-Path -LiteralPath $resumeNanoDir)) {
        throw "ResumeIsoOnly: build workspace not found at '$resumeNanoDir'. Run a normal build first (it preserves this folder automatically)."
    }
    Write-Host "Workspace:        $resumeWorkDir" -ForegroundColor Cyan

    # 2. Resolve preserved payload (install.wim / install.esd; SWM must be re-exported via full build)
    $resumePayload = $null
    $expectedPayloadFile = $null
    foreach ($candidate in @('install.wim', 'install.esd')) {
        $candPath = Join-Path -Path "$resumeNanoDir\sources" -ChildPath $candidate
        if ((Test-Path -LiteralPath $candPath) -and ((Get-Item -LiteralPath $candPath).Length -gt 1GB)) {
            $resumePayload = $candPath
            $expectedPayloadFile = $candidate
            break
        }
    }
    if (-not $resumePayload) {
        throw "ResumeIsoOnly: no valid install.wim / install.esd (> 1 GB) found in '$resumeNanoDir\sources'."
    }
    $resumeBootWim = Join-Path -Path "$resumeNanoDir\sources" -ChildPath "boot.wim"
    if (-not (Test-Path -LiteralPath $resumeBootWim)) {
        throw "ResumeIsoOnly: boot.wim is missing from '$resumeNanoDir\sources'. ISO mastering requires it."
    }
    foreach ($requiredRootItem in @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $resumeNanoDir -ChildPath $requiredRootItem))) {
            throw "ResumeIsoOnly: ISO root item '$requiredRootItem' is missing in '$resumeNanoDir'. The workspace looks incomplete."
        }
    }
    $payloadSizeGB = [math]::Round((Get-Item -LiteralPath $resumePayload).Length / 1GB, 2)
    Write-Host "Payload:       $resumePayload ($payloadSizeGB GB)" -ForegroundColor Green

    # 3. Payload integrity (hash-level only; deep apply is deliberately skipped in resume mode)
    Invoke-WinEaseHostHealthCheck -WorkspaceDir $resumeWorkDir
    Write-Host "Verifying payload structural integrity + SHA256..." -ForegroundColor Cyan
    $null = & dism.exe /English /Get-WimInfo "/WimFile:$resumePayload" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ResumeIsoOnly: payload metadata validation failed (ExitCode: $LASTEXITCODE). The payload is unusable - run a full build instead."
    }
    $resumeIdx1 = & dism.exe /English /Get-WimInfo "/WimFile:$resumePayload" "/Index:1" 2>&1
    $resumeEditionName = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Name\s*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
    $resumeArch = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Architecture\s*:\s*(\w+)') { $Matches[1].Trim() } else { "amd64" }
    $resumeExpandedSizeGB = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Size\s*:\s*([\d,]+)\s*bytes') { [math]::Round((($Matches[1] -replace ',', '') -as [double]) / 1GB, 1) } else { 0 }
    Write-Host "  - Edition:            $resumeEditionName" -ForegroundColor Green
    Write-Host "  - Architecture:       $resumeArch" -ForegroundColor Green
    Write-Host "  - Expanded size:      $resumeExpandedSizeGB GB" -ForegroundColor Green

    $script:VerifiedFinalWimSha256 = (Get-FileHash -LiteralPath $resumePayload -Algorithm SHA256).Hash
    # C-H3: FinalPayloadVerified stays $false in resume mode. The hash above only
    # proves which file is on disk (and Test-WinEaseResumeIntegrity has already
    # checked it against the checkpoint's recorded FinalWimSha256 when one was
    # saved); the Phase 15 deep-apply verification itself is deliberately skipped
    # in this run, so this payload must not be reported as "verified" the way a
    # full build's Phase 15 pass is. The ISO built here is therefore reported
    # with PayloadVerified = $false until a full build verifies the payload.
    $script:FinalPayloadVerified = $false
    $script:IsoPayloadVerified = $false
    $activePayloadPath = $resumePayload

    if ($script:DiagnosticData) {
        $script:DiagnosticData.SourceIsoPath = "(resume mode - preserved workspace payload)"
        $script:DiagnosticData.SelectedImageIndex = 1
        $script:DiagnosticData.SelectedImageName = $resumeEditionName
        $script:DiagnosticData.FinalPayloadVerified = $false
        $script:DiagnosticData.FinalWimSha256 = $script:VerifiedFinalWimSha256
        $script:DiagnosticData.ExportSucceeded = $false
    }

    # 4. Phase 14 equivalent: patch boot.wim (LabConfig & bypasses) on both indexes
    $resumeLabConfigKeys = @(
        'BypassCPUCheck', 'BypassRAMCheck', 'BypassSecureBootCheck',
        'BypassStorageCheck', 'BypassTPMCheck', 'BypassDiskCheck'
    )
    Write-Host "Patching boot.wim (LabConfig + setup bypasses, Phase 14 equivalent)..." -ForegroundColor Green
    Set-ItemOwnershipAndAccess -Path $resumeBootWim
    try { Set-ItemProperty -LiteralPath $resumeBootWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    $resumeBootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$resumeBootWim"
    $resumeHasIndex2 = (($resumeBootInfo -split '\r?\n') -match 'Index\s*:\s*2')
    $resumeIndices = if ($resumeHasIndex2) { @(1, 2) } else { @(1) }
    $bootWimPath = $resumeBootWim
    foreach ($bIndex in $resumeIndices) {
        Write-Host "  - Applying bypasses to boot.wim Index $bIndex..." -ForegroundColor Cyan
        $bMountResult = Invoke-WinEaseImageMount -ImageFile $resumeBootWim -ImageIndex $bIndex -Retries 3
        $scratchDir = $bMountResult.MountDir
        $script:DismMountDir = $scratchDir
        $script:MountOpened = $true
        try {
            & reg.exe query "HKLM\zSYSTEM" > $null 2>&1
            if ($LASTEXITCODE -eq 0) { [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM') }
            $bootHiveFile = "$scratchDir\Windows\System32\config\SYSTEM"
            $bootLoadOutput = & reg.exe load HKLM\zSYSTEM "$bootHiveFile" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to load boot.wim Index $bIndex SYSTEM hive (Exit code: $LASTEXITCODE): $bootLoadOutput" }
            $script:HivesLoaded = $true
            foreach ($key in $resumeLabConfigKeys) {
                reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
            }
            reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
        } finally {
            [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')
            $script:HivesLoaded = $false
        }
        Set-Location -LiteralPath $scriptDir
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $bootUnmountSuccess = $false
        for ($bRetry = 1; $bRetry -le 3; $bRetry++) {
            Set-Location -LiteralPath $scriptDir
            Start-Sleep -Seconds 2
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
            if ($LASTEXITCODE -eq 0) { $bootUnmountSuccess = $true; break }
            Start-Sleep -Seconds (2 * $bRetry)
        }
        if (-not $bootUnmountSuccess) {
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
            throw "Failed to commit changes to boot.wim Index $bIndex after multiple attempts."
        }
        [void](Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $resumeBootWim)
        $script:MountOpened = $false
    }

    # 5. Phase 15 equivalent (light): metadata verified, SHA256 verified; deep apply intentionally skipped
    Write-Host "Deep apply verification is intentionally skipped in resume mode (run a full build to re-verify)." -ForegroundColor Yellow

    # 6. Phase 16 equivalent: ISO root cleanup + traceability manifest refresh
    Write-Host "ISO root cleanup (Phase 16 equivalent)..." -ForegroundColor Cyan
    $resumeKeepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml", "WinEase-build-info.json")
    Get-ChildItem -Path $resumeNanoDir | Where-Object { $_.Name -notin $resumeKeepList } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $resumeSourcesDir = Join-Path -Path $resumeNanoDir -ChildPath "sources"
    if (Test-Path -LiteralPath $resumeSourcesDir) {
        Remove-Item -Path "$resumeSourcesDir\setupcore.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$resumeSourcesDir\*.diagerr" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$resumeSourcesDir\*.diagxml" -Force -ErrorAction SilentlyContinue
        if ($ultraSlimMode) {
            Write-Host "  [UltraSlim] Trimming media payloads (sources\sxs, langpacks, sflist*.dat)..." -ForegroundColor Cyan
            Remove-Item -LiteralPath "$resumeSourcesDir\sxs" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$resumeSourcesDir\langpacks" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "$resumeSourcesDir\sflist*.dat" -Force -ErrorAction SilentlyContinue
        }
        $resumeSuspicious = Get-ChildItem -Path $resumeSourcesDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "*backup*" -or $_.Name -like "*temp*" -or $_.Name -like "*export*"
        }
        if ($resumeSuspicious) {
            throw ("Verification failed: Temporary or backup files remain in ISO sources tree: " + (($resumeSuspicious | ForEach-Object { $_.Name }) -join ", "))
        }
    }
    # Refresh traceability manifest (keeps the same profile values, marks resume runs)
    try {
        $resumeInfoObj = [ordered]@{
            BuilderVersion   = $script:WinEaseVersion
            BuildUtc         = [DateTime]::UtcNow.ToString("o")
            Profile          = $selectedProfile
            Architecture     = $resumeArch
            ComputerName     = $ComputerName
            UserName         = $UserName
            ResumeMode       = $true
            KeepSearchIndex  = [bool]$keepSearchIndex
            DisableWindowsUpdate = [bool]$disableWU
            SourceDrive      = "(resume mode)"
            PayloadFormat    = if ($expectedPayloadFile -eq 'install.esd') { "ESD" } else { "WIM" }
        }
        $resumeInfoObj | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path -Path $resumeNanoDir -ChildPath "WinEase-build-info.json") -Encoding utf8
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    # 7. Phase 17 equivalent: locate verified oscdimg.exe (local first, then PATH/ADK)
    $resumeOscdimg = $null
    $resumeOscdimgCandidates = @(
        (Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $pathOscdResume = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
    if ($pathOscdResume -and $pathOscdResume.Source) { $resumeOscdimgCandidates += $pathOscdResume.Source }
    foreach ($candidate in $resumeOscdimgCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate) -and (Test-OscdimgIntegrity -OscdimgPath $candidate)) {
            $resumeOscdimg = $candidate
            break
        }
    }
    if (-not $resumeOscdimg) {
        throw "ResumeIsoOnly: no Authenticode-verified oscdimg.exe available."
    }
    Write-Host "Using oscdimg.exe: $resumeOscdimg" -ForegroundColor Green

    # 8. Phase 18 equivalent: master bootable ISO + in-ISO payload verification (up to 3 attempts)
    $profSlugResume = if ($selectedProfile) { ($selectedProfile -replace '[^\w\-]', '_').Trim('_') } else { "custom" }
    $resumeOutputIsoName = if ($OutputIsoName) {
        "$OutputIsoName.iso"
    } elseif ($TimestampIso) {
        "WinEase_${profSlugResume}_$(Get-Date -Format 'yyyyMMdd_HHmm').iso"
    } else { "WinEase.iso" }
    $resumeOutputIso = Join-Path -Path $scriptDir -ChildPath $resumeOutputIsoName
    $resumeTempIso = Join-Path -Path $scriptDir -ChildPath "WinEase_temp_resume_$($script:BuildId).iso"

    # Boot sector discovery (workspace-only candidates; source media is not mounted in resume mode)
    $resumeEtfsBoot = Join-Path -Path "$resumeNanoDir\boot" -ChildPath "etfsboot.com"
    $resumeEfiSys = $null
    foreach ($efiCand in @(
        (Join-Path -Path "$resumeNanoDir\efi\microsoft\boot" -ChildPath "efisys.bin"),
        (Join-Path -Path "$resumeNanoDir\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
        (Join-Path -Path "$resumeNanoDir\efi\boot" -ChildPath "efisys.bin"))) {
        if (Test-Path -LiteralPath $efiCand) { $resumeEfiSys = $efiCand; break }
    }
    $resumeBootData = $null
    $resumeUtfiSysSafe = if ($resumeEfiSys) { Get-SafeShortPath $resumeEfiSys } else { $null }
    $resumeEtfsSafe = if (($etf = $resumeEtfsBoot) -and (Test-Path -LiteralPath $etf)) { Get-SafeShortPath $etf } else { $null }
    if ($resumeUtfiSysSafe -and $resumeEtfsSafe -and ($resumeArch -ne 'arm64')) {
        $resumeBootData = "2#p0,e,b$resumeEtfsSafe#pEF,e,b$resumeUtfiSysSafe"
        Write-Host "Configured Dual Boot (BIOS + UEFI)" -ForegroundColor Green
    } elseif ($resumeUtfiSysSafe) {
        $resumeBootData = "1#pEF,e,b$resumeUtfiSysSafe"
        Write-Host "Configured UEFI Boot" -ForegroundColor Green
    } elseif ($resumeEtfsSafe) {
        $resumeBootData = "1#p0,e,b$resumeEtfsSafe"
        Write-Host "Configured BIOS Boot" -ForegroundColor Green
    } else {
        throw "ResumeIsoOnly: missing boot sector files (etfsboot.com / efisys.bin) in workspace."
    }

    $resumeExpectedPayload = $expectedPayloadFile
    $resumeIsoSuccess = $false
    $resumeIsoAttempt = 0
    while (-not $resumeIsoSuccess -and $resumeIsoAttempt -lt 3) {
        $resumeIsoAttempt++
        if (Test-Path -LiteralPath $resumeTempIso) { Remove-Item -LiteralPath $resumeTempIso -Force -ErrorAction SilentlyContinue }
        $resumeOscdimgArgs = @("-m", "-u2", "-udfver102", "-lWinEase")
        if ($resumeBootData) { $resumeOscdimgArgs += "-bootdata:$resumeBootData" }
        $resumeOscdimgArgs += $resumeNanoDir
        $resumeOscdimgArgs += $resumeTempIso

        Write-Host "Executing oscdimg (Attempt $resumeIsoAttempt of 3): $resumeTempIso..." -ForegroundColor Cyan
        & "$resumeOscdimg" @resumeOscdimgArgs
        $resumeOscdimgExit = $LASTEXITCODE
        if ($script:DiagnosticData) { $script:DiagnosticData.OscdimgExitCode = $resumeOscdimgExit }
        if ($resumeOscdimgExit -ne 0 -or (-not (Test-Path -LiteralPath $resumeTempIso)) -or ((Get-Item -LiteralPath $resumeTempIso).Length -lt 1.5GB)) {
            Write-Warning "oscdimg failed on attempt $resumeIsoAttempt (ExitCode: $resumeOscdimgExit). Retrying after cooldown..."
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 5
            continue
        }

        Write-Host "Mounting temporary ISO to verify embedded payload integrity..." -ForegroundColor Cyan
        $resumeMountResult = $null
        try {
            $resumeMountResult = Mount-DiskImage -ImagePath $resumeTempIso -StorageType ISO -PassThru -ErrorAction Stop
            $resumeVol = Get-Volume -DiskImage $resumeMountResult -ErrorAction Stop | Select-Object -First 1
            $resumeIsoDrive = $resumeVol.DriveLetter
            if (-not $resumeIsoDrive) { throw "Failed to determine drive letter for mounted ISO." }
            $resumeEmbeddedPath = "${resumeIsoDrive}:\sources\$resumeExpectedPayload"
            if (-not (Test-Path -LiteralPath $resumeEmbeddedPath)) { throw "Mounted ISO is missing sources\$resumeExpectedPayload payload." }

            $resumeEmbeddedItem = Get-Item -LiteralPath $resumeEmbeddedPath -ErrorAction Stop
            if ($resumeEmbeddedItem.Length -ne $activePayloadPath.Length) { throw "Embedded payload size mismatch." }
            & dism.exe /English /Get-WimInfo "/WimFile:$resumeEmbeddedPath" > $null 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Embedded payload failed DISM metadata validation (ExitCode: $LASTEXITCODE)." }

            $resumeEmbeddedSha = (Get-FileHash -LiteralPath $resumeEmbeddedPath -Algorithm SHA256).Hash
            if ($script:DiagnosticData) { $script:DiagnosticData.IsoEmbeddedWimSha256 = $resumeEmbeddedSha }
            Write-Host "  Verified Final Payload SHA256:  $script:VerifiedFinalWimSha256" -ForegroundColor Cyan
            Write-Host "  ISO Embedded Payload SHA256:    $resumeEmbeddedSha" -ForegroundColor Cyan
            if ($resumeEmbeddedSha -ne $script:VerifiedFinalWimSha256) {
                $resumeRehash = (Get-FileHash -LiteralPath $activePayloadPath -Algorithm SHA256).Hash
                if ($resumeEmbeddedSha -eq $resumeRehash) {
                    $script:VerifiedFinalWimSha256 = $resumeRehash
                    Write-Host "  [PASS] payload hash consistent with current on-disk payload." -ForegroundColor Green
                } else {
                    throw "PAYLOAD HASH MISMATCH: ISO embedded ($resumeEmbeddedSha) vs payload on disk ($resumeRehash). Likely host instability - retrying."
                }
            }
            $resumeIsoSuccess = $true
            $script:IsoPayloadVerified = $true
            if ($script:DiagnosticData) { $script:DiagnosticData.IsoPayloadMatch = $true }
            Write-Host "  [PASS] ISO embedded payload verified identical." -ForegroundColor Green
        } catch {
            Write-Warning "ISO verification failed on attempt $($resumeIsoAttempt): $_"
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 5
        } finally {
            if ($resumeMountResult) {
                try { Dismount-DiskImage -ImagePath $resumeTempIso -ErrorAction SilentlyContinue | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }
    }
    if (-not $resumeIsoSuccess) {
        throw "ResumeIsoOnly: failed to create a verified bootable ISO after 3 attempts."
    }

    # 9. Promote, rotate, final hash + HTML report
    [void](Invoke-WinEasePromoteTemporaryIso -TempIsoPath $resumeTempIso -TargetIsoPath $resumeOutputIso -BuildId $script:BuildId)
    if ($TimestampIso) {
        try {
            $resumeProfileIsos = Get-ChildItem -Path $scriptDir -Filter "WinEase_${profSlugResume}_*.iso" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($resumeProfileIsos.Count -gt 3) {
                $resumeProfileIsos | Select-Object -Skip 3 | ForEach-Object {
                    Write-Host "Rotating out older generation ISO: $($_.Name)" -ForegroundColor DarkGray
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $resumeIsoItem = Get-Item -LiteralPath $resumeOutputIso
    $resumeIsoSha256 = (Get-FileHash -LiteralPath $resumeOutputIso -Algorithm SHA256).Hash
    try {
        $resumeReportPath = Join-Path -Path $scriptDir -ChildPath "WinEase_report.html"
        Export-WinEaseHtmlReport -OutputPath $resumeReportPath -BuildInfo @{
            Title             = "WinEase Resume Build Report - $selectedProfile"
            Timestamp         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Profile           = $selectedProfile
            Architecture      = $resumeArch
            SourceDrive       = "(resume mode)"
            OutputIso         = $resumeOutputIso
            PayloadFormat     = if ($expectedPayloadFile -eq 'install.esd') { "install.esd" } else { "install.wim" }
            OriginalSizeBytes = [int64]($resumeExpandedSizeGB * 1GB)
            FinalSizeBytes    = $resumeIsoItem.Length
            IsoSha256         = $resumeIsoSha256
            Settings          = (Get-WinEaseCurrentConfig -ProfileName $selectedProfile)
            ApplyVerified     = $script:FinalPayloadVerified
            IsoPayloadMatch   = $script:IsoPayloadVerified
        }
        Write-Host "Visual Build Report generated: $resumeReportPath" -ForegroundColor Cyan
    } catch { Write-Warning "Could not export visual build report: $_" }

    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  WinEase RESUME BUILD SUCCESSFUL" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  - Output ISO:        $resumeOutputIso" -ForegroundColor Green
    Write-Host "  - ISO Size:          $([math]::Round($resumeIsoItem.Length / 1GB, 2)) GB" -ForegroundColor Green
    Write-Host "  - ISO SHA256:        $resumeIsoSha256" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "Build lifecycle finished in $($buildStopwatch.Elapsed.TotalSeconds.ToString('0.0')) seconds (resume mode)."
    if ($script:DiagnosticData) {
        $script:DiagnosticData.BuildSucceeded = $true
        $script:DiagnosticData.IsoGenerated = $true
        $script:DiagnosticData.IsoPayloadVerified = $true
        Write-WinEaseDiagnosticReport "Resume build succeeded"
    }
    try { Stop-Transcript } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# ============================================================================
# F2. Phase Checkpoint Save/Load (foundation for -ResumeFromPhase)
# ============================================================================
# C-H3: canonical hash of the resolved configuration (selected profile + the
# resolved TweakSettings, keys sorted) so a checkpoint can be tied to the build
# that produced it. Returns $null when no configuration is available; callers
# treat $null as "not recorded" and skip the comparison rather than failing.
function Get-WinEaseCheckpointConfigHash {
    [CmdletBinding()]
    param()
    try {
        $pairs = [System.Collections.Generic.List[string]]::new()
        $ts = $script:TweakSettings
        if ($ts -is [System.Collections.IDictionary]) {
            foreach ($k in @($ts.Keys | Sort-Object)) { $pairs.Add("$k=$([bool]$ts[$k])") }
        } elseif ($null -ne $ts) {
            foreach ($p in @($ts.PSObject.Properties | Sort-Object -Property Name)) { $pairs.Add("$($p.Name)=$([bool]$p.Value)") }
        }
        $canonical = "Profile=$([string]$selectedProfile)`n" + ($pairs -join "`n")
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
        } finally {
            $sha.Dispose()
        }
    } catch {
        return $null
    }
}

function Save-WinEaseCheckpoint {
    [CmdletBinding()]
    # C-H4: [double] so a checkpoint can record Phase 9.5 as completed without
    # the value being rounded to a neighbouring integer phase.
    param([double]$CompletedPhase = 0)
    try {
        if (-not $script:BaseWorkDir) { return }
        $cpPath = Join-Path -Path $script:BaseWorkDir -ChildPath "checkpoint.json"
        $cp = [ordered]@{
            CompletedPhase       = $CompletedPhase
            Timestamp           = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            BuildId             = $script:BuildId
            BaseWorkDir         = $script:BaseWorkDir
            WinEaseDir           = $WinEaseDir
            ScratchDir          = $scratchDir
            VhdxMountDir        = $vhdxMountDir
            DriveLetter         = $DriveLetter
            Index               = $index
            TargetEditionName   = $targetEditionName
            Architecture        = $architecture
            LanguageCode        = $languageCode
            SelectedProfile     = $selectedProfile
            KeepSearchIndex     = [bool]$keepSearchIndex
            RemoveDefender      = [bool]$removeDefender
            UltraSlimMode       = [bool]$ultraSlimMode
            SafeDebloatMode     = [bool]$safeDebloatMode
            AllowPhysicalDebloat = [bool]$allowPhysicalDebloat
            TweakSettings       = $script:TweakSettings
            # C-H3: bind the checkpoint to the build that produced it. FinalWimSha256
            # is the Phase 15 verified payload hash (empty until Phase 15 has run);
            # Test-WinEaseResumeIntegrity recomputes the on-disk payload hash and
            # rejects the resume when a recorded value does not match.
            # ResolvedConfigHash is checked by WinEasebuilder.ps1 on -ResumeFromPhase.
            FinalWimSha256      = if ($script:VerifiedFinalWimSha256) { [string]$script:VerifiedFinalWimSha256 } else { $null }
            ResolvedConfigHash  = Get-WinEaseCheckpointConfigHash
        }
        $json = $cp | ConvertTo-Json -Depth 6
        [void](Write-WinEaseTextFileAtomic -Path $cpPath -Content $json -Encoding utf8)
    } catch {
        Write-Warning "Checkpoint save skipped: $_"
    }
}

function Load-WinEaseCheckpoint {
    [CmdletBinding()]
    param()
    $cpPath = $null
    if ($script:BaseWorkDir) { $cpPath = Join-Path -Path $script:BaseWorkDir -ChildPath "checkpoint.json" }
    if (-not $cpPath -or -not (Test-Path -LiteralPath $cpPath)) {
        # Try default workspace
        $docsDir = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDir) { $docsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Documents" }
        $cpPath = Join-Path -Path (Join-Path -Path $docsDir -ChildPath "WinEase_workspace") -ChildPath "checkpoint.json"
    }
    if (-not (Test-Path -LiteralPath $cpPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($cpPath, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warning "Checkpoint load failed: $_"
        return $null
    }
}
