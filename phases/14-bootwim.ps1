# Phase 14: 14-bootwim
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 14. Shrink and modify boot.wim (Setup bypasses & dynamic index handling)
$bootWimPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "boot.wim"
if (-not (Test-Path -LiteralPath $bootWimPath)) {
    $sourceBootWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "boot.wim"
    if (Test-Path -LiteralPath $sourceBootWim) {
        Write-Host "Restoring boot.wim from source media..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $sourceBootWim -Destination $bootWimPath -Force -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $bootWimPath) {
    Write-Host "Processing boot.wim..." -ForegroundColor Green
    Set-ItemOwnershipAndAccess -Path $bootWimPath
    try { Set-ItemProperty -LiteralPath $bootWimPath -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}

    # Inspect boot.wim indices (Setup image is usually Index 2, WinPE is Index 1)
    # We patch both indices in-place and preserve dual-index structure for 100% BCD and UEFI stability.
    $bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
    $hasIndex2 = ($bootInfo -split '\r?\n') -match 'Index\s*:\s*2'
    $indicesToPatch = if ($hasIndex2) { @(1, 2) } else { @(1) }

    # F9: ARM64 sanity check - boot.wim architecture must match the selected payload architecture
    if ($architecture -eq 'arm64') {
        Write-Host "  [ARM64] Detected ARM64 target. Boot.wim must be ARM64 (UEFI-only bootdata will be used)." -ForegroundColor Cyan
        $bootArchLine = ($bootInfo -split '\r?\n') | Where-Object { $_ -match 'Architecture' } | Select-Object -First 1
        if ($bootArchLine -and ($bootArchLine -notmatch 'arm64|aarch64')) {
            Write-Warning "boot.wim architecture ($bootArchLine) does not match ARM64 target. Setup may fail on ARM64 hardware."
        }
    }

    foreach ($bIndex in $indicesToPatch) {
        Write-Host "  - Applying Setup & Hardware requirement bypasses to boot.wim Index $bIndex..." -ForegroundColor Cyan
        $bMountResult = Invoke-Nano11ImageMount -ImageFile $bootWimPath -ImageIndex $bIndex -Retries 3
        $scratchDir = $bMountResult.MountDir
        $script:DismMountDir = $scratchDir
        $script:MountOpened = $true

        try {
            & reg.exe query "HKLM\zSYSTEM" > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')
            }
            $bootHiveFile = "$scratchDir\Windows\System32\config\SYSTEM"
            $bootLoadOutput = & reg.exe load HKLM\zSYSTEM "$bootHiveFile" 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Without LabConfig in boot.wim, Setup would reject unsupported hardware
                throw "Failed to load boot.wim Index $bIndex SYSTEM hive from '$bootHiveFile' (Exit code: $LASTEXITCODE): $bootLoadOutput"
            }
            $script:HivesLoaded = $true
            foreach ($key in $labConfigKeys) {
                reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
            }
            reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
            # CurrentControlSet is dynamically linked by the Windows kernel at boot; leave hive untouched.
        } finally {
            [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')
            $script:HivesLoaded = $false
        }

        Set-Location -LiteralPath $scriptDir
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        $bootUnmountSuccess = $false
        for ($bRetry = 1; $bRetry -le 3; $bRetry++) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Set-Location -LiteralPath $scriptDir
            Start-Sleep -Seconds 2
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
            if ($LASTEXITCODE -eq 0) {
                $bootUnmountSuccess = $true
                break
            }
            Set-Location -LiteralPath $scriptDir
            Start-Sleep -Seconds (2 * $bRetry)
        }

        if (-not $bootUnmountSuccess) {
            Write-Host "Falling back to discard unmount for boot.wim index $bIndex..." -ForegroundColor Yellow
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
            throw "Failed to commit changes to boot.wim Index $bIndex after multiple attempts. Aborting build."
        }

        # Verify unmount was completed and no lock remains
        Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $bootWimPath
        $script:MountOpened = $false
    }
}
