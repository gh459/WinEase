# Phase 5: 05-appx
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'scratchPath', Justification = 'Positional runspace argument of $folderCleanupScript supplied by the caller')]
param()


# 5. Removing provisioned AppX packages (Bloatware)
Write-Host "Removing provisioned AppX packages (bloatware)..." -ForegroundColor Cyan
$appxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*', '*PowerAutomate*',
    '*Teams*', '*Todos*', '*YourPhone*', '*SoundRecorder*', '*Solitaire*',
    '*FeedbackHub*', '*Maps*', '*OfficeHub*', '*Help*', '*Family*', '*Alarms*',
    '*CommunicationsApps*', '*Copilot*', '*CompatibilityEnhancements*',
    '*AV1VideoExtension*', '*AVCEncoderVideoExtension*', '*HEIFImageExtension*',
    '*HEVCVideoExtension*', '*MicrosoftStickyNotes*', '*OutlookForWindows*',
    '*RawImageExtension*', '*VP9VideoExtensions*', '*WebpImageExtension*',
    '*DevHome*', '*Photos*', '*Camera*', '*QuickAssist*',
    '*Paint*', '*Notepad*', '*CrossDevice*', '*Getstarted*', '*GetStarted*', '*Microsoft.Getstarted*', '*Tips*',
    '*WindowsCalculator*', '*Calculator*', '*Xbox*',
    '*Microsoft.Windows.Ai.Copilot*', '*Recall*', '*MicrosoftCorporationII.QuickAssist*',
    '*MicrosoftCorporationII.MicrosoftFamily*', '*Edge.DevToolsClient*', '*549981C3F5F10*',
    '*Client.WebExperience*', '*Windows.Ai*', '*WindowsAI*',
    # Windows Backup app (Microsoft.WindowsBackupApp / WindowsBackupClient.exe host)
    '*WindowsBackupApp*',
    # Modern AI & Copilot bloatware (Windows 11 24H2 / 26H2 Canary)
    '*CopilotStudio*', '*ClickToDo*', '*WindowsAIClient*', '*Microsoft.Windows.StudioFX*',
    '*NewsAndInterests*', '*RecallAgent*', '*AIComponents*', '*Microsoft.Windows.AiPca*',
    # Third-party preloaded sponsor apps & OEM bloat
    '*Spotify*', '*Disney*', '*LinkedIn*', '*Twitter*', '*TikTok*', '*Facebook*',
    '*Instagram*', '*Netflix*', '*Amazon*', '*PrimeVideo*', '*CandyCrush*',
    # Xbox / Gaming overlays & speech services
    '*Microsoft.GamingApp*', '*XboxGameOverlay*', '*XboxSpeechToTextOverlay*',
    '*XboxGamingOverlay*', '*XboxIdentityProvider*', '*Microsoft.MixedReality.Portal*',
    '*MixedReality*',
    # Diagnostics & Feedback & Legacy 3D / Wallet
    '*Microsoft.WindowsFeedbackHub*', '*Microsoft.3DBuilder*', '*Print3D*', '*Wallet*', '*Pay*'
)
# Optional: Microsoft Store removal (-RemoveStore / prompt 15).
# Only the Store app and its purchase UI are removed. Microsoft.DesktopAppInstaller (winget)
# and Store framework packages (VCLibs, UI.Xaml, NET.Native, Services.Store.Engagement) are
# intentionally kept so winget, WinUtil and already-installed apps keep working.
if ($removeStore) {
    Write-Host "  [Store] Microsoft Store will be removed (Microsoft.WindowsStore, Microsoft.StorePurchaseApp)." -ForegroundColor Yellow
    $appxPatterns += @('Microsoft.WindowsStore_*', 'Microsoft.StorePurchaseApp_*')
}
if ($keepBasicApps) {
    Write-Host "  [Apps] Preserving essential productivity apps: Notepad, Paint, Calculator (-KeepBasicApps)." -ForegroundColor Green
    $appxPatterns = @($appxPatterns | Where-Object {
        $_ -notlike '*Notepad*' -and
        $_ -notlike '*Paint*' -and
        $_ -notlike '*Calculator*'
    })
}
if ($keepXboxServices) {
    Write-Host "  [Xbox] Preserving Xbox Game Bar and Gaming subsystem (-KeepXboxServices)." -ForegroundColor Green
    # '*Gaming*' must also be dropped: it matches Microsoft.GamingApp (the Xbox app) on its own
    $appxPatterns = @($appxPatterns | Where-Object { $_ -notlike '*Xbox*' -and $_ -notlike '*Gaming*' })
}
# Protection Whitelist: System-critical frameworks, shell hosts, and core dependencies
# MUST NEVER be removed. Removing them breaks Start Menu, Taskbar, Modern File Explorer, or causes 0x80073cfa.
$protectedAppxPatterns = @(
    '*Microsoft.UI.Xaml*',
    '*Microsoft.VCLibs*',
    '*Microsoft.NET.Native*',
    '*MicrosoftWindows.Client.CBS*',
    '*Microsoft.Windows.ShellExperienceHost*',
    '*Microsoft.Windows.StartMenuExperienceHost*',
    '*Microsoft.Windows.PeopleExperienceHost*',
    '*WindowsInternal.*',
    '*Microsoft.DesktopAppInstaller*',
    '*Microsoft.Services.Store.Engagement*',
    '*Microsoft.Windows.Sense.Client*',
    '*CoreAI*',
    '*PinningConfirmationBrowser*',
    '*SecureAssessmentBrowser*'
)
# The Windows Security UI (SecHealthUI) is normally protected, because the Security app is
# part of the Windows shell experience. When Defender itself is removed there is nothing left
# for the Security app to show, so the protection is lifted and the package is added to the
# removal list below. Leaving it protected would keep the Windows Security app installed
# (and its per-user package registered) even though Defender is gone.
if (-not $removeDefender) {
    $protectedAppxPatterns += '*Microsoft.SecHealthUI*'
} else {
    $appxPatterns += @('*Microsoft.SecHealthUI*', '*Microsoft.Windows.SecHealthUI*')
    Write-Host "  - Removing the Windows Security UI package (Defender removal requested)" -ForegroundColor Yellow
}
$protectedAppxRegexPatterns = $protectedAppxPatterns | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }
$protectedAppxRegex = [regex]::new(('^(' + ($protectedAppxRegexPatterns -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$appxRegexPatterns = $appxPatterns | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }
$appxRegex = [regex]::new(('^(' + ($appxRegexPatterns -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
    $name = $_.PackageName
    $disp = $_.DisplayName
    # Strictly exclude any package matching the protection whitelist
    if (($name -and $protectedAppxRegex.IsMatch($name)) -or ($disp -and $protectedAppxRegex.IsMatch($disp))) {
        return $false
    }
    return (($name -and $appxRegex.IsMatch($name)) -or ($disp -and $appxRegex.IsMatch($disp)))
}

$successfullyRemovedPackages = [System.Collections.Generic.List[object]]::new()
foreach ($package in $packagesToRemove) {
    Write-Host "  - Removing: $($package.DisplayName)"
    $removed = $false
    try {
        Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop | Out-Null
        $removed = $true
    } catch {
        # Fallback to dism.exe CLI if PowerShell COMException occurs
        & dism.exe /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$($package.PackageName)" > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            $removed = $true
        }
    }
    if ($removed) {
        $successfullyRemovedPackages.Add($package)
    } else {
        Write-Warning "  - Package '$($package.DisplayName)' is protected by Windows. Preserving WindowsApps directory to prevent package manifest corruption."
    }
}

# Clean leftover WindowsApps folders ONLY for packages that were successfully uninstalled via DISM
# F7: parallelize the file I/O (RunspacePool) - DISM package removal itself stays sequential
# because the offline image is locked by DISM per call; parallel DISM on one image fails with lock errors.
$folderCleanupScript = {
    param($folderPath, $scratchPath)
    if (Test-Path -LiteralPath $folderPath) {
        try {
            $rootItem = Get-Item -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue
            if ($rootItem -and ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                [System.IO.Directory]::Delete($folderPath, $false)
                return (-not (Test-Path -LiteralPath $folderPath))
            }
            $queue = [System.Collections.Generic.Queue[string]]::new()
            $queue.Enqueue($folderPath)
            while ($queue.Count -gt 0) {
                $curr = $queue.Dequeue()
                $children = Get-ChildItem -LiteralPath $curr -Force -ErrorAction SilentlyContinue
                foreach ($c in $children) {
                    if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        try {
                            if ($c.PSIsContainer) { [System.IO.Directory]::Delete($c.FullName, $false) }
                            else { [System.IO.File]::Delete($c.FullName) }
                        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                    } elseif ($c.PSIsContainer) {
                        $queue.Enqueue($c.FullName)
                    }
                }
            }
            & cmd.exe /c "rd /s /q `"$folderPath`"" > $null 2>&1
            if (Test-Path -LiteralPath $folderPath) { return $false }
            return $true
        } catch { return $false }
    }
    return $true
}

$parallelism = [Math]::Max(1, [Math]::Min($AppxParallelism, 8))
$folderPaths = @()
foreach ($package in $successfullyRemovedPackages) {
    $folderPaths += (Join-Path -Path "$scratchDir\Program Files\WindowsApps" -ChildPath $package.PackageName)
}

if ($parallelism -le 1 -or $folderPaths.Count -le 1) {
    foreach ($fp in $folderPaths) {
        if (Test-Path -LiteralPath $fp) {
            Remove-WinEaseTreeRobust -Path $fp -SafetyRoot $scratchDir
        }
    }
} else {
    Write-Host "  [F7] Cleaning $($folderPaths.Count) WindowsApps folders with $parallelism parallel workers..." -ForegroundColor Cyan
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $parallelism)
    $runspacePool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($fp in $folderPaths) {
        if (-not (Test-WinEasePathWithin -Path $fp -Root $scratchDir)) {
            Write-Warning "  - Skipping parallel cleanup of '$fp': path is outside the working directory."
            continue
        }
        if (-not (Test-Path -LiteralPath $fp)) { continue }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($folderCleanupScript).AddArgument($fp).AddArgument($scratchDir)
        $jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Path = $fp })
    }
    foreach ($job in $jobs) {
        try {
            $workerResult = @($job.PS.EndInvoke($job.Handle))
            if ($workerResult.Count -eq 0 -or -not $workerResult[-1]) {
                Write-Warning "  - Parallel cleanup failed for folder '$(Split-Path -Leaf $job.Path)' (retrying sequentially)."
            }
        } catch {
            Write-Warning "Parallel folder cleanup worker failed: $_ (falling back to sequential)"
        } finally {
            $job.PS.Dispose()
        }
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    # Verify + sequential fallback for any survivors
    foreach ($fp in $folderPaths) {
        if (Test-Path -LiteralPath $fp) {
            Remove-WinEaseTreeRobust -Path $fp -SafetyRoot $scratchDir
        }
    }
}

# 5b. Disabling Windows 11 24H2/26H2 Recall Optional Feature if present
# Bound to the RemoveRecall option (OFF = keep the Recall feature).
if (Test-TweakEnabled 'RemoveRecall' $true) {
    Write-Host "Disabling Recall and modern AI optional features..." -ForegroundColor Cyan
    & dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Recall /Remove > $null 2>&1
    & dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Windows-Recall-Optional-Package /Remove > $null 2>&1
}

# 5c. The Advanced Debloat targets this phase owns (config\schema.psd1 -> DebloatEngines).
# The provisioned AppX pass and the Cortana / Search system app folders are removed here,
# so they are not removed a second time by phase 09.
if (Get-Command -Name Invoke-WinEaseDebloatTargets -ErrorAction SilentlyContinue) {
    Invoke-WinEaseDebloatTargets -Phase '05-appx'
}

# M2: User extension actions (Appx)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType Appx -ScratchDir $scratchDir -DryRun:$DryRun | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}
