# Phase 8: 08-filesystem
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 8. File system slimming
$winDir = "$scratchDir\Windows"

# Non-essential driver cleanup (optional)
if ($removeDrivers) {
    Write-Host "Slimming legacy peripheral drivers in DriverStore (strictly protecting ntprint, rdpbus)..." -ForegroundColor Cyan
    $driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
    # CRITICAL: ntprint.inf and rdpbus.inf are CORE Windows system drivers.
    # Deleting them causes Windows Setup PnP driver staging to hang at 77%!
    # Only optional standalone printer/fax/modem INF packages may be safely trimmed.
    $driverPatterns = @('prnms*.inf*', 'scan*.inf*', 'mfd*.inf*', 'wscsmd.inf*', 'fax*.inf*', 'modem*.inf*')
    if (-not $keepBT) {
        $driverPatterns += 'tdibth.inf*'
    }
    if (Test-Path -LiteralPath $driverRepo) {
        Get-ChildItem -Path $driverRepo -Directory | ForEach-Object {
            $folder = $_
            # Explicit safety guard against deleting core system drivers
            if ($folder.Name -like 'ntprint*' -or $folder.Name -like 'rdpbus*') {
                return
            }
            foreach ($pattern in $driverPatterns) {
                if ($folder.Name -like $pattern) {
                    Write-Host "  - Removing legacy peripheral driver package: $($folder.Name)"
                    Remove-ProtectedDirectory -Path $folder.FullName -ScratchPath $scratchDir
                    break
                }
            }
        }
    }
} else {
    Write-Host "Preserving DriverStore inbox drivers (guarantees zero setup stalls at 77%)..." -ForegroundColor Green
}

# Fonts slimming (strictly skipped if keepExtraFonts is true, even in ultraSlimMode)
if (-not $keepExtraFonts) {
    Write-Host "Slimming Fonts folder (preserving Japanese and core system fonts)..." -ForegroundColor Cyan
    $fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
    if (Test-Path -LiteralPath $fontsPath) {
        $essentialSystemFonts = @(
            "segoe*", "tahoma*", "marlett.ttf", "8541oem.fon", "segui*", "consol*",
            "lucon*", "calibri*", "arial*", "times*", "cou*", "8*.*"
        )
        $japaneseFonts = @(
            "meiryo*", "yugoth*", "yumin*", "msgoth*", "msgothic*", "msmin*", "msmincho*", "segoeuihistoric.ttf"
        )
        # Keep display fonts for the target UI language so ko/zh images remain readable after size-first trimming
        $ownLanguageFontFiles = @()
        if ($script:primaryImeLang) {
            switch ($script:primaryImeLang) {
                'ko-kr' { $ownLanguageFontFiles = @("gulim*", "malgun*", "batang*") }
                'zh-cn' { $ownLanguageFontFiles = @("simsun*", "msyh*", "simhei*", "dengxian*") }
                'zh-tw' { $ownLanguageFontFiles = @("mingliu*", "msjh*", "jhen*", "tc*") }
            }
        }
        $fontsToKeep = $essentialSystemFonts + $japaneseFonts + $ownLanguageFontFiles

        $foreignFonts = @(
            "mingliu*", "simsun*", "msjh*", "msyh*", "malgun*",
            "khmer*", "lao*", "myanmar*", "thai*", "leelaw*", "gadugi*",
            "ebrima*", "dokchamp*", "taile*", "sylfaen*", "mvboli*",
            "plantc*", "himalaya*", "nyala*", "monbaiti*", "javatext*"
        )

        Get-ChildItem -Path $fontsPath | ForEach-Object {
            $fontItem = $_
            $isKeep = $false
            foreach ($kp in $fontsToKeep) {
                if ($fontItem.Name -like $kp) { $isKeep = $true; break }
            }
            if (-not $isKeep) {
                $isForeign = $false
                foreach ($fp in $foreignFonts) {
                    if ($fontItem.Name -like $fp) { $isForeign = $true; break }
                }
                if ($isForeign -or (-not $keepExtraFonts)) {
                    Set-ItemOwnershipAndAccess -Path $fontItem.FullName
                    Remove-Item -LiteralPath $fontItem.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# Asian IME Input Methods: language-aware retention (size-first decoupling)
# keepAsianIME = true  -> preserve the target-language IME directory (KOR/CHS/CHT when matching, JPN otherwise)
#                         plus JPN (README "Keep Asian IMEs" always retains ja-JP); trim foreign dictionaries.
# keepAsianIME = false -> remove every Asian IME directory and the TTS voice engine folder.
$imeDirectoryForLanguage = @{ 'ko-kr' = 'KOR'; 'zh-cn' = 'CHS'; 'zh-tw' = 'CHT'; 'zh-hk' = 'CHT' }
$allImeDirectories = @('CHS', 'CHT', 'KOR', 'JPN')
$keepImeDirectories = @('JPN')
if ($script:primaryImeLang -and $imeDirectoryForLanguage.ContainsKey($script:primaryImeLang)) {
    $keepImeDirectories += $imeDirectoryForLanguage[$script:primaryImeLang]
}
if (-not $keepAsianIME) {
    Write-Host "Removing Asian Input Methods (CHS, CHT, KOR, JPN)..." -ForegroundColor Cyan
    $keepImeDirectories = @()
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($imeDir in $allImeDirectories) {
    if ($imeDir -notin $keepImeDirectories) {
        Remove-Item -LiteralPath (Join-Path -Path $winDir -ChildPath "System32\InputMethod\$imeDir") -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($keepAsianIME) {
    $keepListText = $keepImeDirectories -join ', '
    Write-Host "Preserving Asian Input Methods ($keepListText) and decoupling foreign dictionaries (-KeepAsianIME)..." -ForegroundColor Green
}

# Speech & Text-to-Speech Models (UltraSlim cleanup: trim heavy voice models, preserve core OneCore runtime for OOBE)
if ($ultraSlimMode) {
    Write-Host "Trimming heavy Speech recognition and TTS voice models (preserving OOBE core)..." -ForegroundColor Cyan
    $ttsPaths = @(
        (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS"),
        (Join-Path -Path $winDir -ChildPath "Speech_OneCore\Engines\TTS")
    )
    foreach ($tp in $ttsPaths) {
        if (Test-Path -LiteralPath $tp) {
            Get-ChildItem -Path $tp -Include "*.dat", "*.lex", "*.bin" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Set-ItemOwnershipAndAccess -Path $_.FullName
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Windows\Speech_OneCore directory and WinSxS speech-onecore manifests are preserved to prevent OOBE narrator crashes.
}

# Windows Defender definitions and telemetry cache purge (safe for Code Integrity & ci.dll)
if ($removeDefender) {
    Write-Host "Purging Windows Defender definition updates, platform cache, and telemetry..." -ForegroundColor Cyan

    # 1. ProgramData payload (definition databases + MpEngine.dll).
    #    NOTE: the previous implementation used "Remove-Item -Path '...\*' -Recurse", which in
    #    Windows PowerShell 5.1 does not reliably recurse into a wildcard root and silently
    #    swallowed every failure (-ErrorAction SilentlyContinue). The directory could therefore
    #    survive the purge with its contents still present. Remove-ProtectedDirectory takes
    #    ownership first and throws when the directory is still there afterwards, so a failed
    #    purge is now visible instead of silent.
    $defenderDataDir = Join-Path -Path $scratchDir -ChildPath "ProgramData\Microsoft\Windows Defender"
    if (Test-Path -LiteralPath $defenderDataDir) {
        Write-Host "  - Purging ProgramData\Microsoft\Windows Defender" -ForegroundColor Cyan
        Remove-ProtectedDirectory -Path $defenderDataDir -ScratchPath $scratchDir
        New-Item -ItemType Directory -Force -Path $defenderDataDir -ErrorAction SilentlyContinue | Out-Null
    }

    # 2. Defender Remover (ionuttbara) integration: remove Defender folders entirely and recreate
    #    empty ones so the service registrations keep resolving to an existing (empty) folder.
    foreach ($defFolder in @("Program Files\Windows Defender", "Program Files\Windows Defender Advanced Threat Protection")) {
        $fullDefPath = Join-Path -Path $scratchDir -ChildPath $defFolder
        if (Test-Path -LiteralPath $fullDefPath) {
            Write-Host "  - Removing Defender folder: $defFolder" -ForegroundColor Cyan
            Remove-ProtectedDirectory -Path $fullDefPath -ScratchPath $scratchDir
            New-Item -ItemType Directory -Force -Path $fullDefPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # 3. Neutralize the CBS re-staging maps for Defender.
    #    WinSxS keeps the complete Defender payload (windows-defender-service holds MsMpEng.exe,
    #    MpClient.dll, MpSvc.dll, MpAsDesc.dll ...). CBS uses the FileMaps entries to re-stage
    #    that payload back into "Program Files\Windows Defender" and to re-register the
    #    WinDefend/MDCoreSvc service keys, which is what resurrects the Defender process after
    #    the offline service-key deletion in Phase 10. Removing only the map entries stops the
    #    re-staging while leaving the WinSxS package folders themselves untouched, so the
    #    component store stays internally consistent (deleting the payload folders instead
    #    breaks hardlink identity and triggers WIM stream corruption 0x80070570 / Code
    #    Integrity failure 0xC0000428 -> installer BSOD).
    $fileMapsDir = Join-Path -Path $scratchDir -ChildPath "Windows\WinSxS\FileMaps"
    if (Test-Path -LiteralPath $fileMapsDir) {
        $defenderMaps = @(Get-ChildItem -LiteralPath $fileMapsDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'defender' })
        if ($defenderMaps.Count -gt 0) {
            Write-Host "  - Removing CBS re-staging maps for Defender ($($defenderMaps.Count) FileMaps entries)..." -ForegroundColor Cyan
            $mapFailures = 0
            foreach ($map in $defenderMaps) {
                try {
                    # The FileMaps entries are owned by TrustedInstaller and are sparse files.
                    # Without taking ownership first, Remove-Item fails with "access denied"
                    # and cmd del /f fails the same way, so ownership MUST be taken first.
                    & attrib.exe -R -S -H $map.FullName > $null 2>&1
                    & takeown.exe /F $map.FullName /A > $null 2>&1
                    & icacls.exe $map.FullName /grant "*S-1-5-32-544:F" /C /Q > $null 2>&1
                    Remove-Item -LiteralPath $map.FullName -Force -ErrorAction Stop
                } catch {
                    $mapFailures++
                    Write-Warning "  - Could not remove Defender FileMap '$($map.Name)': $($_.Exception.Message)"
                }
            }
            $mapRemaining = @(Get-ChildItem -LiteralPath $fileMapsDir -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'defender' }).Count
            if ($mapFailures -eq 0 -and $mapRemaining -eq 0) {
                Write-Host "  - All Defender CBS re-staging maps removed." -ForegroundColor Green
            } else {
                Write-Warning "  - $mapRemaining Defender CBS re-staging map(s) remain; Defender may be re-staged on first boot."
            }
        }
    }

    # Note: WinSxS manifests, security catalogs (.cat), and System32 binaries are strictly preserved.
    # On Windows 11 24H2+, deleting hardlinked binaries outside DISM causes WIM stream corruption (Data Error 0x80070570)
    # and Code Integrity (ci.dll) failure with STATUS_INVALID_IMAGE_HASH (0xC0000428) -> Installer BSOD/reboot loop.
    # Defender is neutralized offline in Phase 10 via ELAM drivers (WdBoot/WdFilter/WdNisDrv Start=4),
    # service & group policies, and by the removal of the CBS re-staging maps above.
}

# General cleanup & offline cache trimming
# Every removal here used to run unconditionally on every build. They are now bound to
# individual options so that "keep" really keeps: OFF = the folder is left untouched.
# The option asks for the whole set; the Advanced Debloat targets ask for one part of it
# (the event logs, the crash dumps, the temp files). The work is done once, here.
$cleanOfflineCaches = (Test-TweakEnabled 'RemoveOfflineCacheFiles' $true)
$cleanEventLogs = $cleanOfflineCaches
$cleanCrashDumps = $cleanOfflineCaches
$cleanTempFiles = $cleanOfflineCaches
if (Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue) {
    $cleanEventLogs = $cleanEventLogs -or (Test-WinEaseDebloatTarget -Item 'Remove event logs [10-50MB]')
    $cleanCrashDumps = $cleanCrashDumps -or (Test-WinEaseDebloatTarget -Item 'Remove crash dumps [varies]')
    $cleanTempFiles = $cleanTempFiles -or (Test-WinEaseDebloatTarget -Item 'Remove Temp files [varies]')
}
if ($cleanOfflineCaches -or $cleanEventLogs -or $cleanCrashDumps -or $cleanTempFiles) {
    Write-Host "Cleaning offline system caches, prefetch, and setup logs..." -ForegroundColor Cyan
    if ($cleanTempFiles) {
        Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($cleanOfflineCaches) {
        Remove-Item -Path "$scratchDir\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$scratchDir\Windows\System32\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$scratchDir\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$scratchDir\Windows\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$scratchDir\Windows\Downloaded Program Files\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($cleanEventLogs) {
        Remove-Item -Path "$scratchDir\Windows\System32\winevt\Logs\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($cleanCrashDumps) {
        Remove-Item -Path "$scratchDir\Windows\Minidump\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$scratchDir\Windows\Memory.dmp" -Force -ErrorAction SilentlyContinue
    }
}
if ($trimWallpapers) {
    Write-Host "Trimming 4K default wallpapers and lock screen images (-TrimWallpapers)..." -ForegroundColor Cyan
    Remove-ProtectedDirectory -Path "$scratchDir\Windows\Web\Wallpaper" -ScratchPath $scratchDir
    Remove-Item "$scratchDir\Windows\Web\Screen\*.jpg" -Force -ErrorAction SilentlyContinue
}
$removeHelpFiles = (Test-TweakEnabled 'RemoveHelpFiles' $true)
if (-not $removeHelpFiles -and (Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue)) {
    $removeHelpFiles = Test-WinEaseDebloatTarget -Item 'Remove help files [10-20MB]'
}
if ($removeHelpFiles) {
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue
}

# Edge Browser and OneDrive (Preserve System32 WebView2 runtime for Windows 11 OOBE stability)
if (Test-TweakEnabled 'RemoveEdge' $true) {
    Write-Host "Removing Edge browser..." -ForegroundColor Cyan
    Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\Edge" -ScratchPath $scratchDir
    Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate" -ScratchPath $scratchDir
    Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeCore" -ScratchPath $scratchDir
}

# Residual SystemApps payload removal (Windows Backup app & Web Experience host)
# Provisioned-package removal does not delete the SystemApps staging folders that contain
# WindowsBackupClient.exe and WebExperienceHostApp.exe; removing those folders (plus IFEO in
# Phase 10 and the FirstLogon per-user fallback) makes sure neither app can launch or re-stage.
# Servicing payload/manifests stay intact in WinSxS, so CBS integrity is not affected.
$systemAppsDir = Join-Path -Path $winDir -ChildPath "SystemApps"
if (Test-Path -LiteralPath $systemAppsDir) {
    $systemAppsRemovePatterns = @()
    if (Test-TweakEnabled 'RemoveWindowsBackup' $true)    { $systemAppsRemovePatterns += 'Microsoft.WindowsBackupApp_*' }
    if (Test-TweakEnabled 'RemoveWebExperienceHost' $true) { $systemAppsRemovePatterns += 'MicrosoftWindows.Client.WebExperience_*' }
    foreach ($systemAppPattern in $systemAppsRemovePatterns) {
        Get-ChildItem -LiteralPath $systemAppsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $systemAppPattern } |
            ForEach-Object {
                Write-Host "  - Removing residual SystemApps folder: $($_.Name)" -ForegroundColor Cyan
                Remove-ProtectedDirectory -Path $_.FullName -ScratchPath $scratchDir
            }
    }
}

# Directive 2.1: Physical deletion of System32 binaries abolished to prevent NTFS hardlink desync and WIM stream corruption (0x80070570).
# Execution neutralization for OneDriveSetup.exe, VoiceAccess.exe, Livecaptions.exe, and GameBarPresenceWriter.exe is handled via IFEO in Phase 10.
# Purge Windows Backup scheduled tasks
if (Test-TweakEnabled 'RemoveWindowsBackup' $true) {
    Remove-Item -LiteralPath "$scratchDir\Windows\System32\Tasks\Microsoft\Windows\AppListBackup" -Recurse -Force -ErrorAction SilentlyContinue
}


# WinRE Handling (Guarantees Setup SafeOS staging succeeds, then cleans up post-install)
$recoveryDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Recovery"
$keepMarkerFile = Join-Path -Path $recoveryDir -ChildPath "winre.wim.keep"
$targetWinre = Join-Path -Path $recoveryDir -ChildPath "winre.wim"

if ($keepRecoveryEnv) {
    Write-Host "Preserving Windows Recovery Environment (WinRE)..." -ForegroundColor Green
    New-Item -Path $keepMarkerFile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
} else {
    Write-Host "Configuring Windows Recovery Environment for post-install cleanup..." -ForegroundColor Cyan
    # CRITICAL: winre.wim MUST remain inside the image during build time!
    # Windows Setup (setup.exe) mandatory Pre-Finalize phase stages SafeOS from winre.wim.
    # If winre.wim is removed offline or is 0 bytes, Setup aborts with "Windows 11 installation has failed" (0x80070002 / 0x8007000B).
    # Instead, we keep winre.wim for Setup to succeed, and FirstLogon.ps1 unregisters (reagentc /disable) and deletes it online post-install.
    $winreFlagDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts"
    if (-not (Test-Path -LiteralPath $winreFlagDir)) {
        New-Item -ItemType Directory -Force -Path $winreFlagDir -ErrorAction SilentlyContinue | Out-Null
    }
    Set-Content -LiteralPath (Join-Path -Path $winreFlagDir -ChildPath "winre-cleanup.flag") -Value "remove" -Encoding ascii -Force
    if (Test-Path -LiteralPath $keepMarkerFile) {
        Remove-Item -LiteralPath $keepMarkerFile -Force -ErrorAction SilentlyContinue
    }

    # Ensure WinRE has proper Read/Write access and full ACL permissions for Setup SafeOS staging
    if (Test-Path -LiteralPath $targetWinre) {
        Write-Host "Configuring WinRE permissions (clearing Read-Only, granting SYSTEM/Admin full control to prevent Setup 0x80070005)..." -ForegroundColor Green
        try {
            & attrib.exe -R -S -H "$targetWinre" > $null 2>&1
            # Well-known SIDs (SYSTEM / Administrators / Users) so this works on any host language
            & icacls.exe "$targetWinre" /grant "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" "*S-1-5-32-545:(RX)" /c > $null 2>&1
        } catch {
            Write-Warning "Failed to set permissions for WinRE: $_. Continuing build safely."
        }
    }
}

# The Advanced Debloat targets this phase owns (config\schema.psd1 -> DebloatEngines):
# the cache and payload folders that are removed here, so phase 09 does not remove them a
# second time.
if (Get-Command -Name Invoke-WinEaseDebloatTargets -ErrorAction SilentlyContinue) {
    Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
}

# Feature flags and build traceability manifest are staged comprehensively in Phase 11
