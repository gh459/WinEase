# Phase 5: 05-appx
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'scratchPath', Justification = 'Positional runspace argument of $folderCleanupScript supplied by the caller')]
param()


# 5. Removing provisioned AppX packages (Bloatware)
Write-Host "Removing provisioned AppX packages (bloatware)..." -ForegroundColor Cyan
# The list of the packages that are removed lives in config\schema.psd1 (AppxRemoval):
# every entry names the setting that controls it, so a package is only removed when
# the user asked for it. The default removal list is controlled by RemoveAppxBloatware;
# the Camera, Photos, Screen Sketch, Store and Defender entries are independent.
$appxSettings = @{
    RemoveAppxBloatware    = [bool]$removeAppxBloatware
    RemoveDefender         = [bool]$removeDefender
    RemoveStore            = [bool]$removeStore
    KeepBasicApps          = [bool]$keepBasicApps
    KeepXboxServices       = [bool]$keepXboxServices
    RemoveCameraApp        = [bool]$removeCameraApp
    RemovePhotosApp        = [bool]$removePhotosApp
    RemoveScreenSketchApp  = [bool]$removeScreenSketchApp
}
$appxPatterns = @()
if (Get-Command -Name Get-WinEaseAppxRemovalPatterns -ErrorAction SilentlyContinue) {
    $appxPatterns = @(Get-WinEaseAppxRemovalPatterns -Settings $appxSettings)
} elseif ($script:WinEaseSettingsDef -and $script:WinEaseSettingsDef.AppxRemoval) {
    # The shared library is not loaded: fall back to the definition file itself.
    $fallback = [ordered]@{}
    $removeDefault = [bool]$appxSettings['RemoveAppxBloatware']
    foreach ($d in @($script:WinEaseSettingsDef.AppxRemoval)) {
        if (-not $d -or -not $d.Pattern) { continue }
        $option = [string]$d.Option
        if ([string]::IsNullOrWhiteSpace($option)) {
            if ($removeDefault) { $fallback[[string]$d.Pattern] = $true }
            continue
        }
        if ([bool]$d.Invert -and -not $removeDefault) { continue }
        if (-not $appxSettings.ContainsKey($option)) { continue }
        $on = [bool]$appxSettings[$option]
        if ([bool]$d.Invert) { $on = -not $on }
        if ($on) { $fallback[[string]$d.Pattern] = $true }
    }
    $appxPatterns = @($fallback.Keys)
}
# Plugin contributions (IAppxRemovalContributor, IAppxRemovalRuleContributor: the built-in
# UpstreamSync plugin hands over its adopted packages as rules). They join the removal list
# here, so the protection whitelist below applies to them like to every other pattern.
if (Get-Command -Name Get-WinEasePluginAppxPatterns -ErrorAction SilentlyContinue) {
    $pluginAppxPatterns = @(Get-WinEasePluginAppxPatterns -Settings $appxSettings)
    if ($pluginAppxPatterns.Count -gt 0) {
        Write-Host "  [Plugins] $($pluginAppxPatterns.Count) AppX removal pattern(s) contributed by plugins" -ForegroundColor DarkCyan
        $appxPatterns += $pluginAppxPatterns
    }
}
if ($appxPatterns.Count -eq 0) {
    Write-Host "  [Apps] No AppX removal requested - every provisioned package is kept." -ForegroundColor Green
} else {
    Write-Host "  [Apps] Removing AppX packages matching $($appxPatterns.Count) pattern(s) (RemoveAppxBloatware=$removeAppxBloatware, Camera=$removeCameraApp, Photos=$removePhotosApp, ScreenSketch=$removeScreenSketchApp)." -ForegroundColor Cyan
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
}
$protectedAppxRegex = $null
$appxRegex = $null
if (Get-Command -Name Get-WinEaseAppxPatternRegex -ErrorAction SilentlyContinue) {
    $protectedAppxRegex = Get-WinEaseAppxPatternRegex -Patterns $protectedAppxPatterns
    $appxRegex = Get-WinEaseAppxPatternRegex -Patterns $appxPatterns
} else {
    $protectedAppxRegexPatterns = $protectedAppxPatterns | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }
    $protectedAppxRegex = [regex]::new(('^(' + ($protectedAppxRegexPatterns -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $appxRegexPatterns = @($appxPatterns | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' })
    if ($appxRegexPatterns.Count -gt 0) {
        $appxRegex = [regex]::new(('^(' + ($appxRegexPatterns -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
}

$packagesToRemove = @()
if ($appxRegex) {
    $packagesToRemove = @(Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
        Test-WinEaseAppxPackageRemovable -Name $_.PackageName -DisplayName $_.DisplayName -RemovalRegex $appxRegex -ProtectedRegex $protectedAppxRegex
    })
}

$successfullyRemovedPackages = [System.Collections.Generic.List[object]]::new()
# The packages the offline pass really removed. Phase 10 takes the staged registration of
# every one of them out of the SOFTWARE hive and phase 11 stages the per-user cleanup of
# the same list, so the apps are not installed for the first user with a payload that is
# gone (the app starts and renders a white window). The list used to be three hardcoded
# names while the offline pass removes every package of the removal list.
$script:WinEaseRemovedAppxPackages = [System.Collections.Generic.List[object]]::new()
foreach ($package in $packagesToRemove) {
    Write-Host "  - Removing: $($package.DisplayName)"
    if ($isDryRunMode) {
        Write-Host "    [DRY] Would remove the provisioned package '$($package.PackageName)'" -ForegroundColor Yellow
        continue
    }
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
    # Windows protects the Security UI package against Remove-AppxProvisionedPackage and
    # DISM even when the user asked for Defender removal. Remove its payload directly;
    # phase 10 removes the staged AppX registration and the AppRepository entry from the
    # offline hives. Without this the Security app stays installed (and points at a
    # Defender that no longer exists).
    if (-not $removed -and $removeDefender -and $package.PackageName -match 'SecHealthUI') {
        $secHealthPaths = @(
            (Join-Path -Path "$scratchDir\Program Files\WindowsApps" -ChildPath $package.PackageName)
        )
        foreach ($globRoot in @(
            "$scratchDir\Program Files\WindowsApps",
            "$scratchDir\Windows\SystemApps",
            "$scratchDir\ProgramData\Microsoft\Windows\AppRepository\Packages"
        )) {
            if (Test-Path -LiteralPath $globRoot) {
                $secHealthPaths += @(Get-ChildItem -LiteralPath $globRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'SecHealthUI' } |
                    ForEach-Object { $_.FullName })
            }
        }
        foreach ($secPath in @($secHealthPaths | Sort-Object -Unique)) {
            if (Test-Path -LiteralPath $secPath) {
                [void](Remove-WinEaseTreeRobust -Path $secPath -SafetyRoot $scratchDir)
            }
        }
        $remainingSecHealth = @()
        if (Test-Path -LiteralPath "$scratchDir\Program Files\WindowsApps") {
            $remainingSecHealth = @(Get-ChildItem -LiteralPath "$scratchDir\Program Files\WindowsApps" -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'SecHealthUI' })
        }
        if ($remainingSecHealth.Count -eq 0) {
            $removed = $true
            Write-Host "    [OK] Force-removed the protected Security UI package payload."
        }
    }
    if ($removed) {
        $successfullyRemovedPackages.Add($package)
        # <Name>_<Version>_<Architecture>_<PublisherId> -> <Name>: the identity name is what
        # Get-AppxPackage -Name matches, so the per-user cleanup needs it.
        $fullName = [string]$package.PackageName
        $shortName = ($fullName -split '_')[0]
        $publisherId = ''
        if ($fullName -match '^.+?_(?:[^_]+_)*([^_]+)$') { $publisherId = $Matches[1] }
        $script:WinEaseRemovedAppxPackages.Add([PSCustomObject]@{
            FullName    = $fullName
            ShortName   = $shortName
            PublisherId = $publisherId
        })
    } else {
        Write-Warning "  - Package '$($package.DisplayName)' is protected by Windows. Preserving WindowsApps directory to prevent package manifest corruption."
    }
}

# Clean leftover WindowsApps folders ONLY for packages that were successfully uninstalled via DISM
# F7: parallelize the file I/O (RunspacePool) - DISM package removal itself stays sequential
# because the offline image is locked by DISM per call; parallel DISM on one image fails with lock errors.
$folderCleanupScript = {
    param($folderPath, $scratchPath)
    # This script block runs inside a worker runspace, where the builder's
    # functions (Test-WinEasePathWithin etc.) are not available. Re-validate
    # containment here anyway: the caller checked $folderPath once before
    # queueing, but the worker must not delete a path that is not inside the
    # scratch (mount) directory, whatever it was handed. The check mirrors
    # Test-WinEasePathWithin: canonicalize both paths with GetFullPath, then
    # require equality or a '\'-bounded prefix, case-insensitively.
    $normalizedRoot = $null
    $normalizedTarget = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($scratchPath)) {
            $normalizedRoot = [System.IO.Path]::GetFullPath($scratchPath.Replace('/', '\')).TrimEnd('\', '/')
        }
        if (-not [string]::IsNullOrWhiteSpace($folderPath)) {
            $normalizedTarget = [System.IO.Path]::GetFullPath($folderPath.Replace('/', '\')).TrimEnd('\', '/')
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if (-not $normalizedRoot -or -not $normalizedTarget) { return $false }
    $isWithinRoot = $normalizedTarget.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedTarget.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isWithinRoot) { return $false }
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
    try {
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
    } finally {
        # The pool is released even if Open() or a worker throws; the
        # sequential verification pass below still runs afterwards.
        try { $runspacePool.Close() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        $runspacePool.Dispose()
    }
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
    $recallExitCode = $LASTEXITCODE
    & dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Windows-Recall-Optional-Package /Remove > $null 2>&1
    $recallPackageExitCode = $LASTEXITCODE
    # Best-effort: these features legitimately do not exist on many images, so
    # a failure is not fatal - but record the exit codes instead of dropping
    # them silently (3010 = success, restart required).
    if ($recallExitCode -notin @(0, 3010)) {
        Write-Verbose "Phase 5: DISM /Disable-Feature Recall returned exit code $recallExitCode (the feature may not be present in this image)."
    }
    if ($recallPackageExitCode -notin @(0, 3010)) {
        Write-Verbose "Phase 5: DISM /Disable-Feature Windows-Recall-Optional-Package returned exit code $recallPackageExitCode (the package may not be present in this image)."
    }
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
