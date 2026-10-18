# Phase 09b: Physical Debloat (Experimental)
# Rust-based physical deletion of protected Windows components with strict safety guards
# Dot-sourced by the main orchestrator

Write-Host "Configuring physical debloat (experimental)..." -ForegroundColor Cyan

# Resolve paths
$rustBinary = Join-Path -Path $scriptDir -ChildPath "tools\nano11-physical-debloat\target\release\nano11-physical-debloat.exe"
if (-not (Test-Path -LiteralPath $rustBinary)) {
    $rustBinary = Join-Path -Path $scriptDir -ChildPath "tools\nano11-physical-debloat\target\debug\nano11-physical-debloat.exe"
}

$hasStandardItems = $script:advancedDebloatStandard -and $script:advancedDebloatStandard.Count -gt 0
$hasExperimentalItems = $script:advancedDebloatExperimental -and $script:advancedDebloatExperimental.Count -gt 0

if (-not $hasStandardItems -and -not $hasExperimentalItems) {
    Write-Host "  [Physical Debloat] No items selected. Skipping." -ForegroundColor DarkGray
    return
}

# --- E1 SAFETY GATE: physical deletion is strictly opt-in -----------------------------------
# Selections coming from a JSON profile or the GUI do NOT authorize destructive physical
# deletion by themselves. Without -AllowPhysicalDebloat (CLI) or the GUI consent dialog the
# experimental deletions are skipped with an explicit notice.
$physGateAllowed = $false
if (Get-Variable -Name 'allowPhysicalDebloat' -Scope Script -ErrorAction SilentlyContinue) { $physGateAllowed = [bool]$script:allowPhysicalDebloat }

# --- E1 SAFETY VALIDATION: verify the mount directory before any destructive operation ------
# Rejects empty paths, drive roots, non-existent directories, trees without the offline-image
# marker, and mounts outside the workspace/mount roots.
$physMountError = $null
if ([string]::IsNullOrWhiteSpace("$scratchDir")) {
    $physMountError = "scratchDir is empty"
} else {
    try {
        $physMountFull = [System.IO.Path]::GetFullPath("$scratchDir").TrimEnd('\')
        $physDriveRoot = [System.IO.Path]::GetPathRoot($physMountFull)
        if ($physDriveRoot -and ($physMountFull -ieq $physDriveRoot.TrimEnd('\'))) {
            $physMountError = "scratchDir is a drive root ($physMountFull)"
        } elseif (-not (Test-Path -LiteralPath $physMountFull -PathType Container)) {
            $physMountError = "scratchDir is not an existing directory ($physMountFull)"
        } elseif (-not (Test-Path -LiteralPath (Join-Path -Path $physMountFull -ChildPath 'Windows\System32\config\SYSTEM'))) {
            $physMountError = "Windows\System32\config\SYSTEM marker not found - not a mounted Windows image ($physMountFull)"
        } else {
            $physWorkspaceRoots = @()
            if ($script:BaseWorkDir) { $physWorkspaceRoots += "$($script:BaseWorkDir)" }
            if ($script:MountAllocationRoot) { $physWorkspaceRoots += "$($script:MountAllocationRoot)" }
            if ($baseWorkDir) { $physWorkspaceRoots += "$baseWorkDir" }
            if ($physWorkspaceRoots.Count -gt 0 -and (Get-Command -Name 'Test-Nano11PathWithin' -ErrorAction SilentlyContinue)) {
                $physInside = $false
                foreach ($physRoot in $physWorkspaceRoots) {
                    if (Test-Nano11PathWithin -Path $physMountFull -Root $physRoot) { $physInside = $true; break }
                }
                if (-not $physInside) {
                    $physMountError = "scratchDir is outside the workspace/mount roots ($($physWorkspaceRoots -join ', '))"
                }
            }
        }
    } catch {
        $physMountError = "mount path validation failed: $($_.Exception.Message)"
    }
}
if ($physMountError) {
    Write-Host "  [Physical Debloat] BLOCKED: mount directory failed the safety validation." -ForegroundColor Red
    Write-Host "    Reason: $physMountError" -ForegroundColor Red
    Write-Host "    No deletion was attempted." -ForegroundColor Yellow
    return
}

# --- E2 SAFETY: offline /ResetBase is blocked on 26100+ (checkpoint LCU protection) ---------
$physTargetBuild = 0
$physNtoskrnl = Join-Path -Path $scratchDir -ChildPath "Windows\System32\ntoskrnl.exe"
if (Test-Path -LiteralPath $physNtoskrnl) {
    try { $physTargetBuild = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($physNtoskrnl).ProductBuildPart } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}
$physWinSxSBlockReason = $null
if ($safeDebloatMode) { $physWinSxSBlockReason = 'Safe Debloat Mode (component-store integrity protection)' }
elseif (($physTargetBuild -ge 26100) -and (-not $ForceWinSxSCleanup)) { $physWinSxSBlockReason = "build $physTargetBuild (24H2+) checkpoint-LCU corruption protection (0x80070570)" }

# --- DISM helpers for Standard items (servicing-stack removal, no raw file deletion) ---
function Invoke-Nano11DebloatFeatureRemoval {
    param([string[]]$FeatureNames)
    foreach ($feature in $FeatureNames) {
        if ($isDryRunMode) { Write-Host "    [DRY] Would disable feature: $feature (/Remove)" -ForegroundColor Yellow; continue }
        $dismOut = & dism.exe /English "/image:$scratchDir" /Disable-Feature "/FeatureName:$feature" /Remove /NoRestart 2>&1
        $dismExit = $LASTEXITCODE
        if ($dismExit -eq 0 -or $dismExit -eq 3010) { Write-Host "    [OK] Disabled feature: $feature" -ForegroundColor Green }
        elseif (($dismOut | Out-String) -match '0x800f080c|feature name .* is unknown') { Write-Host "    [INFO] Feature not present in image: $feature" -ForegroundColor Gray }
        else { Write-Host "    [WARN] Could not disable feature $feature (DISM exit $dismExit)" -ForegroundColor Yellow }
    }
}

function Invoke-Nano11DebloatCapabilityRemoval {
    param([string[]]$NamePatterns)
    $capLines = & dism.exe /English "/image:$scratchDir" /Get-Capabilities /Format:Table 2>&1
    $installed = @($capLines | ForEach-Object {
        if ("$_" -match '^\s*(\S+~\S*)\s*\|\s*Installed') { $Matches[1] }
    })
    $matched = @($installed | Where-Object { $cap = $_; @($NamePatterns | Where-Object { $cap -like $_ }).Count -gt 0 })
    if ($matched.Count -eq 0) {
        Write-Host "    [INFO] No installed capability matches: $($NamePatterns -join ', ')" -ForegroundColor Gray
        return
    }
    foreach ($cap in $matched) {
        if ($isDryRunMode) { Write-Host "    [DRY] Would remove capability: $cap" -ForegroundColor Yellow; continue }
        & dism.exe /English "/image:$scratchDir" /Remove-Capability "/CapabilityName:$cap" /NoRestart > $null 2>&1
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { Write-Host "    [OK] Removed capability: $cap" -ForegroundColor Green }
        else { Write-Host "    [WARN] Could not remove capability $cap (DISM exit $LASTEXITCODE)" -ForegroundColor Yellow }
    }
}

# --- Process Standard items via safe PowerShell removal / DISM ---
if ($hasStandardItems) {
    Write-Host "  [Physical Debloat] Processing Standard items safely..." -ForegroundColor Cyan
    foreach ($item in $script:advancedDebloatStandard) {
        Write-Host "  [Standard] Processing: $item" -ForegroundColor Gray
        $handled = $false

        if ($item -match 'WinRE') {
            # SAFETY: Never delete winre.wim offline. Windows Setup Pre-Finalize stages
            # SafeOS from winre.wim; offline removal aborts setup (0x80070002/0x8007000B).
            if ($keepRecoveryEnv) {
                Write-Host "    [INFO] WinRE kept (KeepRecovery enabled)" -ForegroundColor Gray
            } else {
                $winreFlagDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts"
                $winreFlag = Join-Path -Path $winreFlagDir -ChildPath "winre-cleanup.flag"
                if ($isDryRunMode) { Write-Host "    [DRY] Would schedule WinRE for online removal (winre-cleanup.flag)" -ForegroundColor Yellow }
                else {
                    if (-not (Test-Path -LiteralPath $winreFlagDir)) { New-Item -ItemType Directory -Force -Path $winreFlagDir -ErrorAction SilentlyContinue | Out-Null }
                    Set-Content -LiteralPath $winreFlag -Value "remove" -Encoding ascii -Force
                    Write-Host "    [OK] WinRE scheduled for online removal via FirstLogon (reagentc /disable + file delete)" -ForegroundColor Green
                }
            }
            $handled = $true
        }
        elseif ($item -match 'PatchCache') {
            $patchCache = Join-Path -Path $scratchDir -ChildPath "Windows\Installer\`$PatchCache$"
            if (Test-Path -LiteralPath $patchCache) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $patchCache" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $patchCache -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted \$PatchCache$" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Delivery Optimization') {
            $doPath = Join-Path -Path $scratchDir -ChildPath "Windows\SoftwareDistribution\DeliveryOptimization"
            if (Test-Path -LiteralPath $doPath) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $doPath" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $doPath -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted DeliveryOptimization cache" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'pagefile') {
            if ($isDryRunMode) { Write-Host "    [DRY] Would disable pagefile" -ForegroundColor Yellow }
            else { Write-Host "    [INFO] Pagefile disable is handled by FirstLogon.ps1" -ForegroundColor Gray }
            $handled = $true
        }
        elseif ($item -match 'hiberfil') {
            if ($isDryRunMode) { Write-Host "    [DRY] Would disable hibernation" -ForegroundColor Yellow }
            else { Write-Host "    [INFO] Hibernation disable is handled by FirstLogon.ps1" -ForegroundColor Gray }
            $handled = $true
        }
        elseif ($item -match 'language packs') {
            try {
                $langPacks = & dism.exe /image:$scratchDir /Get-Packages /Format:Table 2>&1 | Select-String -Pattern 'LanguagePack' | Where-Object { $_ -notmatch 'ja-JP|en-US' }
                foreach ($lp in $langPacks) {
                    $pkgName = ($lp -split '\s+')[0]
                    if ($pkgName) {
                        if ($isDryRunMode) { Write-Host "    [DRY] Would remove: $pkgName" -ForegroundColor Yellow }
                        else { & dism.exe /image:$scratchDir /Remove-Package /PackageName:$pkgName /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Removed: $pkgName" -ForegroundColor Green }
                    }
                }
                $handled = $true
            } catch { Write-Host "    [WARN] Language pack removal failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'non-essential fonts') {
            $fontsDir = Join-Path -Path $scratchDir -ChildPath "Windows\Fonts"
            if (Test-Path -LiteralPath $fontsDir) {
                $keepFontsList = 'segoeui*,meiryo*,yugoth*,msmincho*,msgothic*,arial*,tahoma*,verdana*,calibri*,consola*,cour*,times*,georgia*,trebuc*,impact*,comic*'
                [string[]]$keepFonts = $keepFontsList.Split(',')
                $toDelete = Get-ChildItem -LiteralPath $fontsDir -File -ErrorAction SilentlyContinue | Where-Object {
                    $keep = $false
                    foreach ($kf in $keepFonts) { if ($_.Name -like $kf) { $keep = $true; break } }
                    return (-not $keep)
                }
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete $($toDelete.Count) non-essential fonts" -ForegroundColor Yellow }
                else { $toDelete | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted $($toDelete.Count) non-essential fonts" -ForegroundColor Green }
                $handled = $true
            }
        }
        elseif ($item -match 'WinSxS') {
            if ($physWinSxSBlockReason) {
                Write-Host "    [SKIP] WinSxS /StartComponentCleanup /ResetBase skipped: $physWinSxSBlockReason" -ForegroundColor Green
                Write-Host "      (pass -ForceWinSxSCleanup to override on 24H2+; see 09-winsxs.ps1)" -ForegroundColor DarkYellow
            }
            elseif ($isDryRunMode) { Write-Host "    [DRY] Would run DISM /StartComponentCleanup /ResetBase" -ForegroundColor Yellow }
            else {
                try { & dism.exe /image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null; Write-Host "    [OK] WinSxS cleanup completed" -ForegroundColor Green } catch { Write-Host "    [WARN] WinSxS cleanup failed: $_" -ForegroundColor Yellow }
            }
            $handled = $true
        }
        elseif ($item -match 'event logs') {
            $evtxDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\winevt\Logs"
            if (Test-Path -LiteralPath $evtxDir) {
                $evtxFiles = Get-ChildItem -LiteralPath $evtxDir -Filter "*.evtx" -ErrorAction SilentlyContinue
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete $($evtxFiles.Count) .evtx files" -ForegroundColor Yellow }
                else { $evtxFiles | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted $($evtxFiles.Count) .evtx files" -ForegroundColor Green }
                $handled = $true
            }
        }
        elseif ($item -match 'crash dumps') {
            $minidump = Join-Path -Path $scratchDir -ChildPath "Windows\Minidump"
            $memoryDmp = Join-Path -Path $scratchDir -ChildPath "Windows\Memory.dmp"
            if (Test-Path -LiteralPath $minidump) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $minidump" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $minidump -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Minidump dir" -ForegroundColor Green }
            }
            if (Test-Path -LiteralPath $memoryDmp) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $memoryDmp" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $memoryDmp -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Memory.dmp" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Store cache') {
            # The Store cache lives under each user profile and only exists after first sign-in
            Write-Host "    [INFO] Store cache is per-user; nothing exists in the offline image to remove" -ForegroundColor Gray
            $handled = $true
        }
        elseif ($item -match 'Provisioned AppX') {
            # Second pass over the Phase 05 pattern list (same protection whitelist) for packages that survived it
            if ($appxRegex -and $protectedAppxRegex) {
                $leftoverAppx = @(Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
                    $n = $_.PackageName; $d = $_.DisplayName
                    if (($n -and $protectedAppxRegex.IsMatch($n)) -or ($d -and $protectedAppxRegex.IsMatch($d))) { return $false }
                    return (($n -and $appxRegex.IsMatch($n)) -or ($d -and $appxRegex.IsMatch($d)))
                })
                if ($leftoverAppx.Count -eq 0) { Write-Host "    [OK] No listed provisioned AppX packages remain" -ForegroundColor Green }
                foreach ($pkg in $leftoverAppx) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would remove provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Yellow; continue }
                    & dism.exe /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$($pkg.PackageName)" > $null 2>&1
                    if ($LASTEXITCODE -eq 0) { Write-Host "    [OK] Removed provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Green }
                    else { Write-Host "    [WARN] Could not remove provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Yellow }
                }
            } else {
                Write-Host "    [WARN] Phase 05 AppX pattern list unavailable; provisioned AppX pass skipped" -ForegroundColor Yellow
            }
            $handled = $true
        }
        elseif ($item -match 'non-Japanese IME') {
            # Same directories Phase 08 removes when Asian IMEs are not kept; JPN is preserved
            foreach ($imeDir in @('CHS', 'CHT', 'KOR')) {
                $imePath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\InputMethod\$imeDir"
                if (Test-Path -LiteralPath $imePath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $imePath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $imePath -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted InputMethod\$imeDir" -ForegroundColor Green }
                }
            }
            $handled = $true
        }
        elseif ($item -match 'Windows Sandbox') {
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('Containers-DisposableClientVM')
            $handled = $true
        }
        elseif ($item -match 'WSL / VM Platform') {
            if ($wslSupport) { Write-Host "    [SKIP] WSL support is enabled for this build; WSL / VM Platform kept" -ForegroundColor Yellow }
            else { Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') }
            $handled = $true
        }
        elseif ($item -match '\.NET Framework 3\.5') {
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('NetFx3')
            $handled = $true
        }
        elseif ($item -match 'PowerShell ISE') {
            Invoke-Nano11DebloatCapabilityRemoval -NamePatterns @('Microsoft.Windows.PowerShell.ISE~*')
            $handled = $true
        }
        elseif ($item -match 'Steps Recorder') {
            Invoke-Nano11DebloatCapabilityRemoval -NamePatterns @('App.StepsRecorder~*')
            $handled = $true
        }
        elseif ($item -match 'Telnet/TFTP') {
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('TelnetClient', 'TFTP')
            $handled = $true
        }
        elseif ($item -match 'SNMP') {
            Invoke-Nano11DebloatCapabilityRemoval -NamePatterns @('SNMP.Client~*', 'WMI-SNMP-Provider.Client~*')
            $handled = $true
        }
        elseif ($item -match 'Identity Foundation') {
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('Windows-Identity-Foundation')
            $handled = $true
        }
        elseif ($item -match 'Fax service') {
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('FaxServicesClientPackage')
            Invoke-Nano11DebloatCapabilityRemoval -NamePatterns @('Print.Fax.Scan~*')
            $handled = $true
        }
        elseif ($item -match 'XPS Viewer') {
            Invoke-Nano11DebloatCapabilityRemoval -NamePatterns @('XPS.Viewer~*')
            Invoke-Nano11DebloatFeatureRemoval -FeatureNames @('Printing-XPSServices-Features')
            $handled = $true
        }
        elseif ($item -match 'help files') {
            $helpDir = Join-Path -Path $scratchDir -ChildPath "Windows\Help"
            if (Test-Path -LiteralPath $helpDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $helpDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $helpDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Help dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Provisioning') {
            $provDir = Join-Path -Path $scratchDir -ChildPath "Windows\Provisioning"
            if (Test-Path -LiteralPath $provDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $provDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $provDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Provisioning dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Windows.old') {
            $oldDir = Join-Path -Path $scratchDir -ChildPath "Windows.old"
            if (Test-Path -LiteralPath $oldDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $oldDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Windows.old" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Temp files') {
            $tempDir = Join-Path -Path $scratchDir -ChildPath "Windows\Temp"
            if (Test-Path -LiteralPath $tempDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete contents of: $tempDir" -ForegroundColor Yellow }
                else { Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Cleaned Temp dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Media Player') {
            $mpDir = Join-Path -Path $scratchDir -ChildPath "Program Files\Windows Media Player"
            if (Test-Path -LiteralPath $mpDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $mpDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $mpDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Media Player dir" -ForegroundColor Green }
            }
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            $handled = $true
        }
        elseif ($item -match 'Remote Desktop') {
            # In standard debloat, do not physically delete mstsc.exe from System32 (preserves CBS integrity)
            Write-Host "    [SAFE] Remote Desktop service disabled via registry (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Bluetooth') {
            # In standard debloat, do not physically delete bthserv.dll from System32
            Write-Host "    [SAFE] Bluetooth services disabled via registry (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Spooler') {
            # In standard debloat, do not physically delete spoolsv.exe from System32
            Write-Host "    [SAFE] Spooler service disabled via registry (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Touch/Pen') {
            Write-Host "    [SAFE] Touch/Pen services disabled via registry (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Accessibility') {
            Write-Host "    [PRESERVE] Accessibility binaries kept for OOBE stability (IFEO-blocked post-setup)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Hyper-V') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Microsoft-Hyper-V-All /NoRestart 2>&1 | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            Write-Host "    [SAFE] Hyper-V disabled via DISM (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'Cortana') {
            foreach ($dir in @('Windows\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy', 'Windows\SystemApps\Microsoft.Cortana_cw5n1h2txyewy')) {
                $dirPath = Join-Path -Path $scratchDir -ChildPath $dir
                if (Test-Path -LiteralPath $dirPath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $dirPath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $dirPath -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted: $dir" -ForegroundColor Green }
                }
            }
            $handled = $true
        }
        elseif ($item -match 'IIS') {
            $iisDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\inetsrv"
            if (Test-Path -LiteralPath $iisDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $iisDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $iisDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted inetsrv dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'BitLocker') {
            Write-Host "    [SAFE] BitLocker disabled via registry (System32 binaries preserved)" -ForegroundColor Cyan
            $handled = $true
        }
        elseif ($item -match 'OneDrive') {
            $odPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\OneDriveSetup.exe"
            if (Test-Path -LiteralPath $odPath) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $odPath" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $odPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted OneDriveSetup.exe" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Telemetry') {
            $diagDir = Join-Path -Path $scratchDir -ChildPath "ProgramData\Microsoft\Diagnosis"
            if (Test-Path -LiteralPath $diagDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $diagDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $diagDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Diagnosis dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        else {
            if (-not $handled) {
                Write-Host "    [SKIP] No standard handler for: $item" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "  [Standard Debloat] Safe processing complete." -ForegroundColor Green
}

# --- Process Experimental items via Rust binary ---
if ($hasExperimentalItems -and $script:advancedDebloatExperimental.Count -gt 0) {
    if (-not $physGateAllowed) {
        $reqExpCount = @($script:advancedDebloatExperimental).Count
        Write-Host ""
        Write-Host "  [Physical Debloat] BLOCKED: -AllowPhysicalDebloat was not specified." -ForegroundColor Yellow
        Write-Host "  [Physical Debloat] $reqExpCount experimental items were NOT executed (experimental physical deletion is strictly opt-in)." -ForegroundColor Yellow
        Write-Host "  [Physical Debloat] Re-run with -AllowPhysicalDebloat to authorize physical deletion (test environments only)." -ForegroundColor DarkYellow
        Write-Host ""
        return
    }

    if (-not (Test-Path -LiteralPath $rustBinary)) {
        Write-Host "  [Physical Debloat] BLOCKED: Rust binary not found at $rustBinary" -ForegroundColor Red
        Write-Host "  [Physical Debloat] Experimental items skipped to avoid unsafe unverified deletion." -ForegroundColor Yellow
        return
    }

    Write-Host "  [Physical Debloat] Rust binary verified: $rustBinary" -ForegroundColor Green

    $experimentalMap = @{}
    foreach ($item in $script:advancedDebloatExperimental) {
        $key = $null
        if ($item -match 'Edge') { $key = 'physical_edge' }
        elseif ($item -match 'Defender') { $key = 'physical_defender' }
        elseif ($item -match 'Cortana') { $key = 'physical_cortana' }
        elseif ($item -match 'OneDrive') { $key = 'physical_onedrive' }
        elseif ($item -match 'Telemetry') { $key = 'physical_telemetry' }
        elseif ($item -match 'Hyper-V') { $key = 'physical_hyperv' }
        elseif ($item -match 'IIS') { $key = 'physical_iis' }
        elseif ($item -match 'Firewall') { $key = 'physical_firewall' }
        elseif ($item -match 'Bluetooth') { $key = 'physical_bluetooth' }
        elseif ($item -match 'Spooler') { $key = 'physical_spooler' }
        elseif ($item -match 'Touch/Pen') { $key = 'physical_touch_pen' }
        elseif ($item -match 'Accessibility') { $key = 'physical_accessibility' }
        elseif ($item -match 'Media Player') { $key = 'physical_media_player' }
        elseif ($item -match 'Remote Desktop') { $key = 'physical_rdp' }
        elseif ($item -match 'BitLocker') { $key = 'physical_bitlocker' }
        elseif ($item -match 'Sandbox') { $key = 'physical_sandbox' }
        elseif ($item -match 'WSL') { $key = 'physical_wsl' }
        elseif ($item -match 'Help') { $key = 'physical_help' }
        elseif ($item -match 'Crash dumps') { $key = 'physical_crash_dumps' }
        elseif ($item -match 'Provisioning') { $key = 'physical_provisioning' }
        elseif ($item -match 'Delivery Optimization') { $key = 'physical_delivery_optimization' }
        elseif ($item -match 'Search index') { $key = 'physical_search_index' }
        elseif ($item -match 'Windows.old') { $key = 'physical_windows_old' }
        elseif ($item -match 'Temp files') { $key = 'physical_temp_files' }
        elseif ($item -match 'PatchCache') { $key = 'physical_patchcache' }
        elseif ($item -match 'pagefile') { $key = 'physical_pagefile' }
        elseif ($item -match 'hiberfil') { $key = 'physical_hiberfil' }
        elseif ($item -match 'swapfile') { $key = 'physical_swapfile' }
        elseif ($item -match 'Memory.dmp') { $key = 'physical_memory_dmp' }
        elseif ($item -match 'Minidump') { $key = 'physical_minidump' }
        else {
            $key = $item -replace '\s*\[.*?\]\s*', '' -replace '\s+', '_' -replace '[^a-zA-Z0-9_]', '' -replace '_+', '_' -replace '^_|_$', ''
            $key = 'physical_' + $key.ToLower()
        }
        if ($key) { $experimentalMap[$key] = $true }
    }

    $resultLogName = if ($isDryRunMode) { "physical-debloat-dryrun.json" } else { "physical-debloat-result.json" }
    $resultLogPath = Join-Path -Path $logDir -ChildPath $resultLogName

    $configObj = [ordered]@{
        dry_run      = [bool]$isDryRunMode
        mount_path   = "$scratchDir"
        log_path     = $resultLogPath
        experimental = $experimentalMap
    }

    $configPath = Join-Path -Path $logDir -ChildPath "experimental-debloat.json"
    $configJson = $configObj | ConvertTo-Json -Depth 3

    if (Get-Command -Name 'Write-Nano11TextFileAtomic' -ErrorAction SilentlyContinue) {
        Write-Nano11TextFileAtomic -Path $configPath -Content $configJson | Out-Null
    } else {
        [System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.Encoding]::UTF8)
    }
    Write-Host "  [Physical Debloat] Config written: $configPath" -ForegroundColor Green
    Write-Host "  [Physical Debloat] Experimental items: $($experimentalMap.Count)" -ForegroundColor Gray

    if ($isDryRunMode) {
        Write-Host "  [Physical Debloat] DRY RUN MODE: listing targets without deleting" -ForegroundColor Yellow
        $rustArgs = @("--config", $configPath, "--dry-run", "--log-path", $resultLogPath)
    } else {
        $rustArgs = @("--config", $configPath, "--confirm-offline-image", "--log-path", $resultLogPath)
    }

    # Execute Rust binary
    Write-Host "  [Physical Debloat] Executing: $rustBinary $($rustArgs -join ' ')" -ForegroundColor Cyan
    $proc = Start-Process -FilePath $rustBinary -ArgumentList $rustArgs -PassThru -Wait -NoNewWindow
    $exitCode = $proc.ExitCode

    if ($exitCode -eq 0) {
        Write-Host "  [Physical Debloat] Completed successfully (Exit code: 0)" -ForegroundColor Green
        if (Test-Path -LiteralPath $resultLogPath) {
            $result = Get-Content -LiteralPath $resultLogPath -Raw | ConvertFrom-Json
            $deletedLabel = if ($isDryRunMode) { 'Would delete' } else { 'Deleted' }
            Write-Host "  [Physical Debloat] $deletedLabel files: $($result.deleted_files), dirs: $($result.deleted_dirs), reg keys: $($result.deleted_registry_keys), errors: $($result.errors.Count)" -ForegroundColor Gray
            if ($result.errors.Count -gt 0) {
                foreach ($err in $result.errors) {
                    Write-Host "    [ERROR] $err" -ForegroundColor Red
                }
            }
        }
    } elseif ($exitCode -eq 2) {
        throw "Physical debloat aborted: one or more experimental targets were rejected by the allowlist (exit code 2)."
    } elseif ($exitCode -eq 3) {
        throw "Physical debloat aborted: mount directory failed safety validation in Rust tool (exit code 3)."
    } else {
        throw "Physical debloat failed with exit code $exitCode. Aborting build to maintain image integrity."
    }

    # Save summary to physical-debloat.log
    $physLogPath = Join-Path -Path $logDir -ChildPath "physical-debloat.log"
    $logLines = @(
        "Physical Debloat Phase - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Rust binary: $rustBinary",
        "Exit code: $exitCode",
        "DryRun: $isDryRunMode",
        "Standard items: $($script:advancedDebloatStandard.Count)",
        "Experimental items: $($script:advancedDebloatExperimental.Count)"
    )
    if (Test-Path -LiteralPath $resultLogPath) {
        $logLines += (Get-Content -LiteralPath $resultLogPath -Raw)
    }
    $logText = $logLines -join [System.Environment]::NewLine

    if (Get-Command -Name 'Write-Nano11TextFileAtomic' -ErrorAction SilentlyContinue) {
        Write-Nano11TextFileAtomic -Path $physLogPath -Content $logText | Out-Null
    } else {
        try { [System.IO.File]::WriteAllText($physLogPath, $logText, [System.Text.Encoding]::UTF8) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
}

Write-Host "  [Physical Debloat] Phase complete." -ForegroundColor Green
