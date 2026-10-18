# Phase 09: Physical Debloat (Experimental)
# Rust-based physical deletion of protected Windows components
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
# whole phase is skipped with an explicit notice.
$physGateAllowed = $false
if (Get-Variable -Name 'allowPhysicalDebloat' -Scope Script -ErrorAction SilentlyContinue) { $physGateAllowed = [bool]$script:allowPhysicalDebloat }
if (-not $physGateAllowed) {
    $reqStdCount = @($script:advancedDebloatStandard).Count
    $reqExpCount = @($script:advancedDebloatExperimental).Count
    Write-Host ""
    Write-Host "  [Physical Debloat] BLOCKED: -AllowPhysicalDebloat was not specified." -ForegroundColor Yellow
    Write-Host "  [Physical Debloat] Requested items were NOT executed (Standard: $reqStdCount, Experimental: $reqExpCount)." -ForegroundColor Yellow
    Write-Host "  [Physical Debloat] Re-run with -AllowPhysicalDebloat to authorize physical deletion (test environments only)." -ForegroundColor DarkYellow
    Write-Host ""
    return
}

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
# Mirrors phases/09-winsxs.ps1: Safe mode skips component cleanup entirely; on 24H2+ builds
# ResetBase requires the explicit -ForceWinSxSCleanup override.
$physTargetBuild = 0
$physNtoskrnl = Join-Path -Path $scratchDir -ChildPath "Windows\System32\ntoskrnl.exe"
if (Test-Path -LiteralPath $physNtoskrnl) {
    try { $physTargetBuild = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($physNtoskrnl).ProductBuildPart } catch {}
}
$physWinSxSBlockReason = $null
if ($safeDebloatMode) { $physWinSxSBlockReason = 'Safe Debloat Mode (component-store integrity protection)' }
elseif (($physTargetBuild -ge 26100) -and (-not $ForceWinSxSCleanup)) { $physWinSxSBlockReason = "build $physTargetBuild (24H2+) checkpoint-LCU corruption protection (0x80070570)" }

if (-not (Test-Path -LiteralPath $rustBinary)) {
    Write-Host "  [Physical Debloat] Rust binary not found at $rustBinary" -ForegroundColor Yellow
    Write-Host "  [Physical Debloat] Falling back to DISM-based removal (standard items only)." -ForegroundColor Yellow
    foreach ($item in $script:advancedDebloatStandard) {
        Write-Host "  [DISM Fallback] Processing: $item" -ForegroundColor Gray
        if ($item -match 'WinRE') {
            # SAFETY: WinRE is never deleted offline (breaks Setup SafeOS staging,
            # 0x80070002). Schedule safe online removal via the cleanup flag instead.
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
        }
        elseif ($item -match 'Windows Media Player') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Player disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Player DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'XPS Viewer') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:XPSViewer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] XPS Viewer disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] XPS Viewer DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Sandbox') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Containers-DisposableClientVM /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Sandbox disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Sandbox DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'WSL') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] WSL disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] WSL DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match '\.NET Framework 3\.5') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:NetFx3 /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] .NET 3.5 disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] .NET 3.5 DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows PowerShell ISE') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:MicrosoftWindowsPowerShellISE /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] PowerShell ISE disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] PowerShell ISE DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Steps Recorder') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:StepsRecorder /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Steps Recorder disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Steps Recorder DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Memory Diagnostic') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMemoryDiagnostic /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Memory Diagnostic disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Memory Diagnostic DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Telnet') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:TelnetClient /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Telnet disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Telnet DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Fax') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:FaxServicesClientPackage /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Fax disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Fax DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Media Center') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:MediaCenter /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Center disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Center DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Remote Desktop') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:RemoteDesktopServices /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Remote Desktop disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Remote Desktop DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'BitLocker') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:BitLocker /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] BitLocker disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] BitLocker DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Media Player') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Player disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Player DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'XPS Viewer') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:XPSViewer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] XPS Viewer disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] XPS Viewer DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Bluetooth') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Bluetooth /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Bluetooth disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Bluetooth DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Spooler') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Printing-PrintToPDFServices-Features /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Spooler disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Spooler DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'language packs') {
            try {
                $langPacks = & dism.exe /image:$scratchDir /Get-Packages /Format:Table 2>&1 | Select-String -Pattern 'LanguagePack' | Where-Object { $_ -notmatch 'ja-JP' }
                foreach ($lp in $langPacks) {
                    $pkgName = ($lp -split '\s+')[0]
                    if ($pkgName) {
                        if ($isDryRunMode) { Write-Host "    [DRY] Would remove: $pkgName" -ForegroundColor Yellow }
                        else { & dism.exe /image:$scratchDir /Remove-Package /PackageName:$pkgName /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Removed: $pkgName" -ForegroundColor Green }
                    }
                }
            } catch { Write-Host "    [WARN] Language pack removal failed: $_" -ForegroundColor Yellow }
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
        }
        else {
            Write-Host "    [SKIP] No DISM fallback for: $item" -ForegroundColor DarkGray
        }
    }
    return
}

Write-Host "  [Physical Debloat] Rust binary found: $rustBinary" -ForegroundColor Green

# --- Process Standard items via PowerShell (file deletions + DISM) ---
if ($hasStandardItems) {
    Write-Host "  [Physical Debloat] Processing Standard items via PowerShell..." -ForegroundColor Cyan
    foreach ($item in $script:advancedDebloatStandard) {
        Write-Host "  [Standard] Processing: $item" -ForegroundColor Gray
        $handled = $false

        if ($item -match 'WinRE') {
            # SAFETY: Never delete winre.wim offline. Windows Setup Pre-Finalize stages
            # SafeOS from winre.wim; offline removal aborts setup (0x80070002/0x8007000B).
            # Schedule safe online removal instead (see phases/08-filesystem.ps1).
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
                else { Remove-Item -LiteralPath $doPath -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted DeliveryOptimization" -ForegroundColor Green }
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
                $langPacks = & dism.exe /image:$scratchDir /Get-Packages /Format:Table 2>&1 | Select-String -Pattern 'LanguagePack' | Where-Object { $_ -notmatch 'ja-JP' }
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
                $keepFontsList = 'segoeui*,meiryo*,yugoth*,arial*,tahoma*,verdana*,calibri*,consola*,cour*,times*,georgia*,trebuc*,impact*,comic*'
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
            $handled = $true
        }
        elseif ($item -match 'Remote Desktop') {
            $rdpPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\mstsc.exe"
            if (Test-Path -LiteralPath $rdpPath) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $rdpPath" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $rdpPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted mstsc.exe" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Bluetooth') {
            foreach ($bin in @('bthserv.dll','BthAvctpSvc.dll')) {
                $binPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\$bin"
                if (Test-Path -LiteralPath $binPath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $binPath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $binPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted: $bin" -ForegroundColor Green }
                }
            }
            $handled = $true
        }
        elseif ($item -match 'Spooler') {
            $spoolerPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\spoolsv.exe"
            if (Test-Path -LiteralPath $spoolerPath) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $spoolerPath" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $spoolerPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted spoolsv.exe" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Touch/Pen') {
            foreach ($bin in @('tabtip.exe','inkobj.dll')) {
                $binPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\$bin"
                if (Test-Path -LiteralPath $binPath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $binPath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $binPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted: $bin" -ForegroundColor Green }
                }
            }
            $handled = $true
        }
        elseif ($item -match 'Accessibility') {
            # README design: core accessibility binaries must be RETAINED in System32 during setup.
            # Deleting them offline destabilizes the OOBE Ease of Access subsystem pass; they are
            # neutralized post-OOBE via IFEO debugger redirection in scripts\FirstLogon.ps1 instead.
            foreach ($bin in @('Narrator.exe','Magnify.exe','osk.exe')) {
                $binPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\$bin"
                if (Test-Path -LiteralPath $binPath) {
                    Write-Host "    [PRESERVE] Kept for OOBE stability (IFEO-blocked post-setup): $bin" -ForegroundColor Cyan
                }
            }
            $handled = $true
        }
        elseif ($item -match 'Hyper-V') {
            foreach ($bin in @('vmcompute.exe','vmms.exe','vmwp.exe')) {
                $binPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\$bin"
                if (Test-Path -LiteralPath $binPath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $binPath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $binPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted: $bin" -ForegroundColor Green }
                }
            }
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
            foreach ($bin in @('fveapi.dll','BitLockerToGo.exe','BdeHdCfg.exe')) {
                $binPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\$bin"
                if (Test-Path -LiteralPath $binPath) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $binPath" -ForegroundColor Yellow }
                    else { Remove-Item -LiteralPath $binPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted: $bin" -ForegroundColor Green }
                }
            }
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
        elseif ($item -match 'Remote Desktop') {
            $rdpPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\mstsc.exe"
            if (Test-Path -LiteralPath $rdpPath) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $rdpPath" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $rdpPath -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted mstsc.exe" -ForegroundColor Green }
            }
            $handled = $true
        }
        elseif ($item -match 'Media Player') {
            $mpDir = Join-Path -Path $scratchDir -ChildPath "Program Files\Windows Media Player"
            if (Test-Path -LiteralPath $mpDir) {
                if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $mpDir" -ForegroundColor Yellow }
                else { Remove-Item -LiteralPath $mpDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "    [OK] Deleted Media Player dir" -ForegroundColor Green }
            }
            $handled = $true
        }
        else {
            if (-not $handled) {
                Write-Host "    [SKIP] No standard handler for: $item" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "  [Standard Debloat] Phase complete." -ForegroundColor Green
}
# --- Process Experimental items via Rust binary ---
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

# Generate JSON config
$configObj = [ordered]@{
    dry_run = [bool]$isDryRunMode
    mount_path = "$scratchDir"
    log_path = Join-Path -Path $logDir -ChildPath "physical-debloat-result.json"
    experimental = $experimentalMap
}

$configPath = Join-Path -Path $logDir -ChildPath "experimental-debloat.json"
$configJson = $configObj | ConvertTo-Json -Depth 3
try {
    [System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.Encoding]::UTF8)
    Write-Host "  [Physical Debloat] Config written: $configPath" -ForegroundColor Green
} catch {
    # G6: A file lock (e.g. an editor holding the canonical path open) must never abort the build.
    # Fall back to a unique sibling path; the Rust tool only needs a readable config file.
    Write-Host "  [WARN] experimental-debloat.json is locked by another process; using a fallback path ($($_.Exception.Message))" -ForegroundColor Yellow
    $configPath = Join-Path -Path $logDir -ChildPath ("experimental-debloat-" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".json")
    [System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.Encoding]::UTF8)
    Write-Host "  [Physical Debloat] Config written (fallback): $configPath" -ForegroundColor Green
}
Write-Host "  [Physical Debloat] Experimental items: $($experimentalMap.Count)" -ForegroundColor Gray

# DryRun mode (Phase 4): list targets without deleting
if ($isDryRunMode) {
    Write-Host "  [Physical Debloat] DRY RUN MODE: listing targets only" -ForegroundColor Yellow
    $rustArgs = @("--config", $configPath, "--dry-run", "--log-path", (Join-Path -Path $logDir -ChildPath "physical-debloat-dryrun.json"))
} else {
    $rustArgs = @("--config", $configPath, "--log-path", (Join-Path -Path $logDir -ChildPath "physical-debloat-result.json"))
}

# Execute Rust binary
Write-Host "  [Physical Debloat] Executing: $rustBinary" -ForegroundColor Cyan
$proc = Start-Process -FilePath $rustBinary -ArgumentList $rustArgs -PassThru -Wait -NoNewWindow
$exitCode = $proc.ExitCode

if ($exitCode -eq 0) {
    Write-Host "  [Physical Debloat] Completed successfully" -ForegroundColor Green
    $resultPath = if ($isDryRunMode) { Join-Path -Path $logDir -ChildPath "physical-debloat-dryrun.json" } else { Join-Path -Path $logDir -ChildPath "physical-debloat-result.json" }
    if (Test-Path -LiteralPath $resultPath) {
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $deletedLabel = if ($isDryRunMode) { 'Would delete' } else { 'Deleted' }
        Write-Host "  [Physical Debloat] $deletedLabel files: $($result.deleted_files), dirs: $($result.deleted_dirs), reg keys: $($result.deleted_registry_keys), errors: $($result.errors.Count)" -ForegroundColor Gray
        if ($result.errors.Count -gt 0) {
            foreach ($err in $result.errors) {
                Write-Host "    [ERROR] $err" -ForegroundColor Red
            }
        }
    }
} elseif ($exitCode -eq 3) {
    Write-Host "  [Physical Debloat] [BLOCKED] The Rust tool refused the mount path (exit 3). Skipping DISM fallback and all further deletions." -ForegroundColor Red
} else {
    Write-Host "  [Physical Debloat] Rust binary failed (exit code $exitCode). Falling back to DISM-based removal." -ForegroundColor Yellow
    foreach ($item in $script:advancedDebloatExperimental) {
        Write-Host "  [DISM Fallback] Processing: $item" -ForegroundColor Gray
        if ($item -match 'WinRE') {
            # SAFETY: WinRE is never deleted offline (breaks Setup SafeOS staging,
            # 0x80070002). Legacy selections only schedule safe online removal.
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
        }
        elseif ($item -match 'Windows Media Player') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Player disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Player DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'XPS Viewer') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:XPSViewer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] XPS Viewer disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] XPS Viewer DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Sandbox') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Containers-DisposableClientVM /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Sandbox disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Sandbox DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'WSL') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] WSL disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] WSL DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match '\.NET Framework 3\.5') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:NetFx3 /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] .NET 3.5 disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] .NET 3.5 DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows PowerShell ISE') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:MicrosoftWindowsPowerShellISE /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] PowerShell ISE disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] PowerShell ISE DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Steps Recorder') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:StepsRecorder /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Steps Recorder disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Steps Recorder DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Memory Diagnostic') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMemoryDiagnostic /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Memory Diagnostic disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Memory Diagnostic DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Telnet') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:TelnetClient /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Telnet disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Telnet DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Fax') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:FaxServicesClientPackage /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Fax disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Fax DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Media Center') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:MediaCenter /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Center disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Center DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Remote Desktop') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:RemoteDesktopServices /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Remote Desktop disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Remote Desktop DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'BitLocker') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:BitLocker /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] BitLocker disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] BitLocker DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Windows Media Player') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Media Player disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Media Player DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'XPS Viewer') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:XPSViewer /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] XPS Viewer disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] XPS Viewer DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Bluetooth') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Bluetooth /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Bluetooth disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Bluetooth DISM failed: $_" -ForegroundColor Yellow }
        }
        elseif ($item -match 'Spooler') {
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:Printing-PrintToPDFServices-Features /NoRestart 2>&1 | Out-Null; Write-Host "    [OK] Spooler disabled via DISM" -ForegroundColor Green } catch { Write-Host "    [WARN] Spooler DISM failed: $_" -ForegroundColor Yellow }
        }
        else {
            Write-Host "    [SKIP] No DISM fallback for: $item" -ForegroundColor DarkGray
        }
    }
}

# Save result to log (best-effort: a file lock held by another process, e.g. an editor, must never abort the build)
$physLogPath = Join-Path -Path $logDir -ChildPath "physical-debloat.log"
try {
    "Physical Debloat Phase - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content -LiteralPath $physLogPath -Encoding utf8
    "Rust binary: $rustBinary" | Add-Content -LiteralPath $physLogPath -Encoding utf8
    "Exit code: $exitCode" | Add-Content -LiteralPath $physLogPath -Encoding utf8
    "Standard items: $($script:advancedDebloatStandard.Count)" | Add-Content -LiteralPath $physLogPath -Encoding utf8
    "Experimental items: $($script:advancedDebloatExperimental.Count)" | Add-Content -LiteralPath $physLogPath -Encoding utf8
    if (Test-Path -LiteralPath (Join-Path -Path $logDir -ChildPath "physical-debloat-result.json")) {
        Get-Content -LiteralPath (Join-Path -Path $logDir -ChildPath "physical-debloat-result.json") | Add-Content -LiteralPath $physLogPath -Encoding utf8
    }
} catch {
    Write-Host "  [WARN] physical-debloat.log is locked by another process; skipped log write ($($_.Exception.Message))" -ForegroundColor Yellow
}

Write-Host "  [Physical Debloat] Phase complete." -ForegroundColor Green
