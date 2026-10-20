# WinEaseMount.ps1 - DISM mount discovery, conflict cleanup, mount directories and offline registry hives
# Dot-sourced into the script scope of WinEasebuilder.ps1 (function definitions only).

function Get-WinEaseMountedImages {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $records = @()
    $querySuccess = $false
    $lastErr = $null

    try {
        if (Get-Command -Name Get-WindowsImage -Module DISM -ErrorAction SilentlyContinue) {
            $images = @(Get-WindowsImage -Mounted -ErrorAction Stop)
            $records = @($images | ForEach-Object {
                [PSCustomObject]@{
                    Path        = $_.Path
                    ImagePath   = $_.ImagePath
                    ImageIndex  = $_.ImageIndex
                    MountStatus = [string]$_.MountStatus
                }
            })
            $querySuccess = $true
        }
    } catch {
        $lastErr = $_
    }

    if (-not $querySuccess) {
        $out = & dism.exe /English /Get-MountedImageInfo 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $querySuccess = $true
            $cur = [ordered]@{}
            foreach ($line in $out) {
                $t = [string]$line
                if ([string]::IsNullOrWhiteSpace($t)) {
                    if ($cur.Count -gt 0 -and $cur.Contains('Mount Dir')) {
                        $records += [PSCustomObject]@{
                            Path        = $cur['Mount Dir']
                            ImagePath   = $cur['Image File']
                            ImageIndex  = $cur['Image Index']
                            MountStatus = $cur['Status']
                        }
                        $cur = [ordered]@{}
                    }
                    continue
                }
                if ($t -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                    $cur[$matches[1].Trim()] = $matches[2].Trim()
                }
            }
            if ($cur.Count -gt 0 -and $cur.Contains('Mount Dir')) {
                $records += [PSCustomObject]@{
                    Path        = $cur['Mount Dir']
                    ImagePath   = $cur['Image File']
                    ImageIndex  = $cur['Image Index']
                    MountStatus = $cur['Status']
                }
            }
        } else {
            $lastErr = "dism.exe /Get-MountedImageInfo returned exit code ${exitCode}: $($out -join ' ')"
        }
    }

    # Augment and correlate with direct WIMMount registry entries (detects corrupted/Invalid mounts where DISM API omits details)
    try {
        $regKey = "HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images"
        if (Test-Path -LiteralPath $regKey) {
            $subKeys = Get-ChildItem -LiteralPath $regKey -ErrorAction SilentlyContinue
            foreach ($sk in $subKeys) {
                $p = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.'Mount Path') {
                    $mPath = [string]$p.'Mount Path'
                    $wPath = [string]$p.'WIM Path'
                    $status = switch ($p.Status) {
                        1 { "Ok" }
                        2 { "Invalid" }
                        3 { "Needs Remount" }
                        default { [string]$p.Status }
                    }
                    $existingMatch = $records | Where-Object { $_.Path -and ($_.Path -ieq $mPath) }
                    if (-not $existingMatch) {
                        $records += [PSCustomObject]@{
                            Path        = $mPath
                            ImagePath   = $wPath
                            ImageIndex  = $p.'Image Index'
                            MountStatus = $status
                        }
                    } else {
                        if (-not $existingMatch.ImagePath -and $wPath) {
                            $existingMatch.ImagePath = $wPath
                        }
                    }
                }
            }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    if (-not $querySuccess) {
        throw "Failed to query mounted images from DISM (Get-WindowsImage failed and dism.exe returned non-zero exit code): $lastErr"
    }

    return @($records)
}

# Helper function: Detect orphaned DISM offline registry hives locked in HKLM
function Get-WinEaseDismOfflineHives {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetMountDir
    )
    $normTarget = ConvertTo-WinEaseNormalizedPath -Path $TargetMountDir
    if (-not $script:ManagedMountDirs.Contains($normTarget)) {
        throw "Target mount directory '$TargetMountDir' is not registered in ManagedMountDirs."
    }

    $expectedSubPaths = @(
        'Users\Default\ntuser.dat',
        'Windows\System32\config\COMPONENTS',
        'Windows\System32\config\DEFAULT',
        'Windows\System32\config\DRIVERS',
        'Windows\System32\config\SAM',
        'Windows\System32\config\SECURITY',
        'Windows\System32\config\SOFTWARE',
        'Windows\System32\config\SYSTEM',
        'Windows\System32\smi\store\Machine\schema.dat'
    )
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sub in $expectedSubPaths) {
        $expectedFullPath = [System.IO.Path]::Combine($normTarget, $sub)
        [void]$expectedSet.Add((ConvertTo-WinEaseNormalizedPath -Path $expectedFullPath))
    }

    $hklm = $null
    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $subKeyNames = $hklm.GetSubKeyNames()
    } catch {
        throw "Failed to enumerate HKLM subkeys: $_"
    } finally {
        if ($hklm) { $hklm.Dispose() }
    }

    $regex = '(?i)^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}(?<HivePath>[A-Za-z]:[\\/].+)$'
    foreach ($rawKey in $subKeyNames) {
        if ($rawKey -match $regex) {
            $hivePathRaw = $Matches['HivePath']
            try {
                $normHive = ConvertTo-WinEaseNormalizedPath -Path $hivePathRaw
                if ($expectedSet.Contains($normHive)) {
                    $candidates.Add([PSCustomObject]@{
                        KeyName  = $rawKey
                        HivePath = $normHive
                    })
                }
            } catch {
                # Not a valid absolute path or drive root, safely skip
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
    }
    return @($candidates)
}

# Internal helper function: Handle mount warning or error depending on BestEffort flag
function Invoke-WinEaseMountError {
    param(
        [string]$Message,
        [switch]$BestEffort
    )
    if ($BestEffort) {
        Write-Warning $Message
        return $false
    }
    throw $Message
}

# Internal helper function: Validate mounted images to protect active/valid mounts before unmounting hives
function Test-WinEaseDismOfflineHiveUnmountSafety {
    param(
        [Parameter(Mandatory=$true)]
        [string]$NormTarget,
        [Parameter(Mandatory=$true)]
        [string]$TargetMountDir,
        [object[]]$MountedImages
    )
    foreach ($img in $MountedImages) {
        if ([string]::IsNullOrWhiteSpace($img.Path)) { continue }
        try {
            $normImgPath = ConvertTo-WinEaseNormalizedPath -Path $img.Path
        } catch { continue }

        $isSame = [string]::Equals($normImgPath, $NormTarget, [System.StringComparison]::OrdinalIgnoreCase)
        $isDescendant = $normImgPath.StartsWith($NormTarget + '\', [System.StringComparison]::OrdinalIgnoreCase)
        $isAncestor = $NormTarget.StartsWith($normImgPath + '\', [System.StringComparison]::OrdinalIgnoreCase)

        if ($isSame) {
            if ($img.MountStatus -ne 'Invalid') {
                return "Cannot unmount offline hives: MountDir '$TargetMountDir' has active DISM mount status '$($img.MountStatus)'."
            }
        } elseif ($isDescendant -or $isAncestor) {
            if ($img.MountStatus -ieq 'Invalid') {
                Write-Warning "Overlapping orphaned/invalid DISM mount detected at '$($img.Path)' (Status: Invalid) - deferring to cleanup."
                continue
            }
            return "Cannot unmount offline hives: Overlapping DISM mount detected at '$($img.Path)' (Status: $($img.MountStatus))."
        }
    }
    return $null
}

# Internal helper function: Attempt to unload a list of candidate offline registry hives
function Invoke-DismOfflineHiveUnloadAttempt {
    param(
        [object[]]$Candidates
    )
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 300

    foreach ($cand in $Candidates) {
        $keyToUnload = "HKLM\" + $cand.KeyName
        $unloadOutput = & reg.exe unload $keyToUnload 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "  -> Successfully unloaded offline hive: $($cand.KeyName)" -ForegroundColor Green
        } else {
            Write-Warning "  -> Failed to unload offline hive '$($cand.KeyName)' (Exit code: $exitCode): $unloadOutput"
        }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

# Helper function: Safely unmount orphaned DISM offline registry hives
function Unmount-DismOfflineHives {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetMountDir,
        [ValidateRange(1, 10)]
        [int]$Retries = 5,
        [switch]$BestEffort
    )
    $normTarget = ConvertTo-WinEaseNormalizedPath -Path $TargetMountDir
    if (-not $script:ManagedMountDirs.Contains($normTarget)) {
        return (Invoke-WinEaseMountError -Message "Target mount directory '$TargetMountDir' is not registered in ManagedMountDirs." -BestEffort:$BestEffort)
    }

    # Verify mounted images status to protect active/valid mounts
    try {
        $mountedImages = @(Get-WinEaseMountedImages)
    } catch {
        return (Invoke-WinEaseMountError -Message "Failed to query DISM mounted images during offline hive unload validation: $_" -BestEffort:$BestEffort)
    }

    $safetyErr = Test-WinEaseDismOfflineHiveUnmountSafety -NormTarget $normTarget -TargetMountDir $TargetMountDir -MountedImages $mountedImages
    if ($safetyErr) {
        return (Invoke-WinEaseMountError -Message $safetyErr -BestEffort:$BestEffort)
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $candidates = @(Get-WinEaseDismOfflineHives -TargetMountDir $normTarget)
        if ($candidates.Count -eq 0) {
            return $true
        }

        Write-Host "Unloading $($candidates.Count) orphaned DISM offline registry hives for '$normTarget' (Attempt $attempt/$Retries)..." -ForegroundColor Cyan
        Invoke-DismOfflineHiveUnloadAttempt -Candidates $candidates

        $remaining = @(Get-WinEaseDismOfflineHives -TargetMountDir $normTarget)
        if ($remaining.Count -eq 0) {
            Write-Host "All orphaned DISM offline registry hives successfully unloaded." -ForegroundColor Green
            return $true
        }

        if ($attempt -lt $Retries) {
            Start-Sleep -Milliseconds (300 * $attempt)
        }
    }

    $finalRemaining = @(Get-WinEaseDismOfflineHives -TargetMountDir $normTarget)
    if ($finalRemaining.Count -gt 0) {
        $keysList = ($finalRemaining | ForEach-Object { "$($_.KeyName) -> $($_.HivePath)" }) -join "`n    "
        $errMsg = "Failed to unload $($finalRemaining.Count) orphaned DISM offline hives for '$normTarget' after $Retries attempts:`n    $keysList`nPlease close any process locking these hives or restart Windows before retrying."
        return (Invoke-WinEaseMountError -Message $errMsg -BestEffort:$BestEffort)
    }
    return $true
}

function Invoke-WinEaseMountpointCleanup {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $mounted = @(Get-WinEaseMountedImages)
    } catch {
        Write-Warning "Could not query mounted images before Cleanup-Mountpoints: $_. Skipping for safety."
        return $false
    }
    foreach ($m in $mounted) {
        if ([string]::IsNullOrWhiteSpace($m.Path)) { continue }
        $normP = try { ConvertTo-WinEaseNormalizedPath -Path $m.Path } catch { $null }
        if ($normP -and -not $script:ManagedMountDirs.Contains($normP)) {
            Write-Warning "Cannot safely run Cleanup-Mountpoints: Active mount exists outside ManagedMountDirs at '$($m.Path)' (Status: $($m.MountStatus))."
            return $false
        }
    }

    $cleanArgs = @('/English')
    if ($script:DismLogPath) {
        $cleanArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
    }
    $cleanArgs += @('/Cleanup-Mountpoints')
    & dism.exe @cleanArgs > $null 2>&1
    $exitCode = $LASTEXITCODE
    return ($exitCode -eq 0)
}

# Internal helper function: Test if a entry mount path or WIM path is within any workspace root
function Test-WinEaseMountPathInWorkspace {
    param(
        [string]$Path
    )
    if (-not $Path) { return $false }
    $normP = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { $null }
    if (-not $normP) { return $false }

    if ($script:MountAllocationRoot) {
        $normAllocRoot = ConvertTo-WinEaseNormalizedPath -Path $script:MountAllocationRoot
        if (Test-WinEasePathWithin -Path $normP -Root $normAllocRoot) {
            return $true
        }
    }
    $wsRef = if ($script:BaseWorkDir) { $script:BaseWorkDir } elseif ($baseWorkDir) { $baseWorkDir } elseif ($workingDir) { $workingDir } else { $null }
    if ($wsRef) {
        $normWorking = ConvertTo-WinEaseNormalizedPath -Path $wsRef
        if (Test-WinEasePathWithin -Path $normP -Root $normWorking) {
            return $true
        }
    }
    return $false
}

# Internal helper function: Perform Level 3 surgical registry metadata purge for corrupted/invalid orphaned DISM mounts
function Invoke-WinEaseLevel3RegistryPurge {
    param(
        [string]$NormMount,
        [string]$NormWim
    )
    if (-not ($NormMount -or $NormWim)) { return }

    if ($NormMount) {
        try {
            [void](Unmount-DismOfflineHives -TargetMountDir $NormMount -BestEffort)
        } catch {
            Write-Warning "Offline hive unload before Level 3 purge encountered warning: $_"
        }
    }

    $regBaseKey = "SOFTWARE\Microsoft\WIMMount\Mounted Images"
    $hklm = $null
    $mountedKey = $null
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $mountedKey = $hklm.OpenSubKey($regBaseKey, $true)
        if (-not $mountedKey) { return }

        $subKeyNames = $mountedKey.GetSubKeyNames()
        foreach ($guid in $subKeyNames) {
            $entryKey = $null
            try {
                $entryKey = $mountedKey.OpenSubKey($guid, $false)
                if (-not $entryKey) { continue }

                $mPathVal = [string]$entryKey.GetValue("Mount Path")
                $wPathVal = [string]$entryKey.GetValue("WIM Path")
                $statusVal = $entryKey.GetValue("Status")

                if ([string]::IsNullOrWhiteSpace($mPathVal)) { continue }
                $normEntryMount = try { ConvertTo-WinEaseNormalizedPath -Path $mPathVal } catch { $null }
                $normEntryWim   = try { if ($wPathVal) { [System.IO.Path]::GetFullPath($wPathVal).TrimEnd('\') } } catch { $null }

                $matchTargetMount = ($NormMount -and $normEntryMount -and ($normEntryMount -ieq $NormMount))
                $matchTargetWim   = ($NormWim -and $normEntryWim -and ($normEntryWim -ieq $NormWim))
                $isWorkspaceMount = Test-WinEaseMountPathInWorkspace -Path $normEntryMount

                # Strictly require Mount Path or WIM Path to match managed target, or be orphaned within workspace
                if ($matchTargetMount -or $matchTargetWim -or ($isWorkspaceMount -and ($statusVal -in @(2, 3, "2", "3")))) {
                    Write-Host "Purging corrupted/orphaned DISM mount metadata from registry: $guid (Mount: $mPathVal, WIM: $wPathVal, Status: $statusVal)..." -ForegroundColor Yellow
                    try {
                        $mountedKey.DeleteSubKeyTree($guid, $false)
                        Write-Host "  -> Successfully purged orphaned DISM mount metadata via .NET Registry: $guid" -ForegroundColor Green
                    } catch {
                        & reg.exe delete "HKLM\$regBaseKey\$guid" /f > $null 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  -> Successfully purged orphaned DISM mount metadata via reg.exe: $guid" -ForegroundColor Green
                        } else {
                            Write-Warning "Could not delete orphaned WIMMount registry entry ${guid}: $_"
                        }
                    }
                }
            } finally {
                if ($entryKey) { $entryKey.Dispose() }
            }
        }
    } catch {
        Write-Warning "Surgical registry metadata purge encountered warning: $_"
    } finally {
        if ($mountedKey) { $mountedKey.Dispose() }
        if ($hklm) { $hklm.Dispose() }
    }

    # Synchronize DISM mountpoints cache after surgical registry metadata purge
    Invoke-WinEaseMountpointCleanup | Out-Null
}

# Helper function: Detect and discard conflicting/orphaned DISM mounts (Resolves Error 0xc1420127 & Invalid mount lock)
function Clear-DismMountConflicts {
    param(
        [string]$TargetMountDir,
        [string]$TargetWimFile,
        [ValidateRange(1, 5)]
        [int]$Retries = 3,
        [switch]$ForceRecovery
    )
    $normMount = if ($TargetMountDir) { try { ConvertTo-WinEaseNormalizedPath -Path $TargetMountDir } catch { [System.IO.Path]::GetFullPath($TargetMountDir).TrimEnd('\') } } else { $null }
    $normWim   = if ($TargetWimFile)  { try { [System.IO.Path]::GetFullPath($TargetWimFile).TrimEnd('\') } catch { $null } } else { $null }

    if (-not $normMount -and -not $normWim) {
        return
    }

    if ($normMount -and -not $script:ManagedMountDirs.Contains($normMount)) {
        $isWorkspaceChild = $false
        if ($script:MountAllocationRoot) {
            $normAllocRoot = ConvertTo-WinEaseNormalizedPath -Path $script:MountAllocationRoot
            if (Test-WinEasePathWithin -Path $normMount -Root $normAllocRoot) {
                $isWorkspaceChild = $true
            }
        }
        $wsRef = if ($script:BaseWorkDir) { $script:BaseWorkDir } elseif ($baseWorkDir) { $baseWorkDir } elseif ($workingDir) { $workingDir } else { $null }
        if (-not $isWorkspaceChild -and $wsRef) {
            $normWorking = ConvertTo-WinEaseNormalizedPath -Path $wsRef
            if (Test-WinEasePathWithin -Path $normMount -Root $normWorking) {
                $isWorkspaceChild = $true
            }
        }

        if ($isWorkspaceChild) {
            [void]$script:ManagedMountDirs.Add($normMount)
        } else {
            throw "Safety violation: Target mount directory '$normMount' is not in ManagedMountDirs. Refusing to operate on unmanaged paths."
        }
    }

    # Best-effort preliminary unload of orphaned offline hives prior to DISM unmount attempts
    if ($normMount) {
        [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)
    }

    # Step 1: Attempt standard DISM unmount / remount retry loop
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $mounted = @(Get-WinEaseMountedImages)
        $conflicts = @()

        foreach ($m in $mounted) {
            $mPath = if ($m.Path) { try { [System.IO.Path]::GetFullPath($m.Path).TrimEnd('\') } catch { $null } } else { $null }
            $mImg  = if ($m.ImagePath) { try { [System.IO.Path]::GetFullPath($m.ImagePath).TrimEnd('\') } catch { $null } } else { $null }

            $matchMount = ($normMount -and $mPath -and ($mPath -ieq $normMount))
            $matchWim   = ($normWim -and $mImg -and ($mImg -ieq $normWim))

            if ($matchWim -and (-not $matchMount) -and $mPath) {
                # Check if $mPath or $normWim is located inside workspace root
                $isWorkspaceMount = (Test-WinEaseMountPathInWorkspace -Path $mPath) -or ($normWim -and (Test-WinEaseMountPathInWorkspace -Path $normWim))

                if ($isWorkspaceMount) {
                    Write-Host "Detected prior build mount at workspace path '$mPath' for '$normWim'. Adopting for safe cleanup." -ForegroundColor Yellow
                    [void]$script:ManagedMountDirs.Add($mPath)
                    [void]$script:AllocatedMountDirs.Add($mPath)
                    $conflicts += $m
                    continue
                } else {
                    throw "Safety violation: Target image '$normWim' is currently mounted at an external unmanaged directory '$mPath' (Status: $($m.MountStatus)). Refusing to automatically discard."
                }
            }

            if ($matchMount -or $matchWim) {
                $conflicts += $m
            }
        }

        if ($conflicts.Count -eq 0) {
            break
        }

        foreach ($c in $conflicts) {
            Write-Host "Resolving lingering DISM mount at '$($c.Path)' (Image: $($c.ImagePath), Status: $($c.MountStatus))..." -ForegroundColor Yellow

            # Unload any registry hives under this mount first
            @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
                try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }

            Set-Location -LiteralPath $scriptDir
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()

            if ($c.MountStatus -in @("Needs Remount", "Invalid")) {
                & dism.exe /English /Remount-Image "/MountDir:$($c.Path)" > $null 2>&1
            }
            & dism.exe /English /Unmount-Image "/MountDir:$($c.Path)" /discard > $null 2>&1
            $unmountExit = $LASTEXITCODE

            if ($unmountExit -ne 0) {
                Invoke-WinEaseMountpointCleanup | Out-Null
            }
        }

        Start-Sleep -Seconds (2 * $attempt)
    }

    # Step 2: Check if conflict is still lingering
    $finalMounted = @(Get-WinEaseMountedImages)
    $lingeringConflict = $finalMounted | Where-Object {
        $mPath = if ($_.Path) { try { [System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') } catch { $null } } else { $null }
        $mImg  = if ($_.ImagePath) { try { [System.IO.Path]::GetFullPath($_.ImagePath).TrimEnd('\') } catch { $null } } else { $null }
        ($normMount -and $mPath -and ($mPath -ieq $normMount)) -or ($normWim -and $mImg -and ($mImg -ieq $normWim))
    }

    # Step 3: Level 3 Surgical Purge for corrupted / Invalid orphaned WIMMount entries
    # If standard DISM commands failed because the mount is in an Invalid/Orphaned state,
    # safely purge ONLY the exact matching registry metadata for this managed mount workspace.
    if ($lingeringConflict -or $ForceRecovery) {
        $canPurge = $true
        # Check that lingering mount is strictly in Invalid status
        if ($lingeringConflict) {
            foreach ($lc in $lingeringConflict) {
                if ($lc.MountStatus -ne 'Invalid') {
                    Write-Warning "Cannot perform Level 3 purge: Mount at '$($lc.Path)' has non-invalid status '$($lc.MountStatus)'."
                    $canPurge = $false
                    break
                }
            }
        }

        if ($canPurge) {
            Invoke-WinEaseLevel3RegistryPurge -NormMount $normMount -NormWim $normWim
        }
    }

    # Step 4: Final verification after all recovery levels
    $verifiedMounted = @(Get-WinEaseMountedImages)
    $stillLingering = $verifiedMounted | Where-Object {
        $mPath = if ($_.Path) { try { [System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') } catch { $null } } else { $null }
        $mImg  = if ($_.ImagePath) { try { [System.IO.Path]::GetFullPath($_.ImagePath).TrimEnd('\') } catch { $null } } else { $null }
        ($normMount -and $mPath -and ($mPath -ieq $normMount)) -or ($normWim -and $mImg -and ($mImg -ieq $normWim))
    }

    # Clean up any lingering offline hives even if mount entry was already clear
    if ($normMount) {
        [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)
    }

    if ($stillLingering) {
        throw "Failed to clear DISM mount conflict for MountDir='$normMount' / WimFile='$normWim'. Active mount remains: $($stillLingering.Path) (Status: $($stillLingering.MountStatus))"
    } else {
        if ($lingeringConflict) {
            Write-Host "DISM mount conflict for '$normMount' successfully resolved." -ForegroundColor Green
        }
    }
}

# Helper function: Generate unique dynamic mount directory path under MountAllocationRoot
function New-WinEaseMountDirectoryPath {
    param()
    if (-not $script:MountAllocationRoot) {
        throw "MountAllocationRoot is not set."
    }
    $normRoot = ConvertTo-WinEaseNormalizedPath -Path $script:MountAllocationRoot

    $candidatePath = $null
    for ($i = 0; $i -lt 50; $i++) {
        $guidStr = [Guid]::NewGuid().ToString('N')
        $dirName = if ($script:MountDirectoryPrefix) { $script:MountDirectoryPrefix + $guidStr } else { "mount_" + $guidStr }
        $fullPath = Join-Path -Path $normRoot -ChildPath $dirName
        $candidatePath = ConvertTo-WinEaseNormalizedPath -Path $fullPath

        # Verify it is a direct child of MountAllocationRoot
        $parentDir = [System.IO.Path]::GetDirectoryName($candidatePath)
        if (-not [string]::Equals($parentDir, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Security violation: Generated mount directory '$candidatePath' is not a direct child of '$normRoot'."
        }

        if (-not (Test-Path -LiteralPath $candidatePath)) {
            break
        }
    }

    if (-not $candidatePath -or (Test-Path -LiteralPath $candidatePath)) {
        throw "Failed to generate unique mount directory path under '$normRoot'."
    }

    [void]$script:ManagedMountDirs.Add($candidatePath)
    [void]$script:AllocatedMountDirs.Add($candidatePath)
    return $candidatePath
}

# Helper function: Prepare and guarantee clean empty mount directory by physical recreation (Resolves Error 0xc1420113, 0xc1420114 & 0xc1420127)
function Initialize-WinEaseMountDirectory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MountDir,
        [string]$WimFile,
        [int]$Retries = 3
    )
    $normMount = ConvertTo-WinEaseNormalizedPath -Path $MountDir
    if (-not $script:ManagedMountDirs.Contains($normMount)) {
        throw "Safety violation: Target mount directory '$normMount' is not in ManagedMountDirs."
    }
    if ($script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($normMount)) {
        throw "Safety guard: Target mount directory '$normMount' is marked as Preserved. Refusing to initialize."
    }

    # 1. Clear any lingering DISM mount metadata or conflicting locks on the directory or WIM
    Clear-DismMountConflicts -TargetMountDir $normMount -TargetWimFile $WimFile -Retries $Retries

    # 2. Safety assert before destructive reset
    Assert-WinEaseDirectorySafety -Path $normMount -Operation 'Reset'

    # 3. Safely unload offline registry hives if present
    [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)

    # 4. Check if directory entity exists
    if (Test-Path -LiteralPath $normMount) {
        $dirItem = Get-Item -LiteralPath $normMount -Force -ErrorAction Stop
        if ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Safety violation: Target mount directory '$normMount' is a reparse point. Refusing to recreate."
        }
        if ($script:VhdxMountDir -and ($normMount -ieq (ConvertTo-WinEaseNormalizedPath -Path $script:VhdxMountDir))) {
            throw "Safety violation: Target mount directory '$normMount' is the VHDX volume mount point. Refusing to delete root entity."
        }

        # 5. Empty directory contents cleanly
        Reset-DirectoryWithRobocopy -Path $normMount -Retries $Retries
        Assert-WinEaseDirectoryEmpty -Path $normMount

        # 6. Delete directory entity itself to purge any hidden NTFS attributes/ADS/stale metadata
        try {
            [System.IO.Directory]::Delete($normMount, $false)
        } catch {
            Write-Warning "Direct directory entity deletion failed ($normMount): $_"
        }
    }

    # 7. Create fresh empty directory
    if (-not (Test-Path -LiteralPath $normMount)) {
        New-Item -ItemType Directory -Force -Path $normMount -ErrorAction Stop | Out-Null
    }

    # 8. Verify it is not a reparse point and is strictly empty
    $newDirItem = Get-Item -LiteralPath $normMount -Force -ErrorAction Stop
    if ($newDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Safety violation: Fresh mount directory '$normMount' was created as a reparse point."
    }
    Assert-WinEaseDirectoryEmpty -Path $normMount
}

# Helper function: Mount WIM image with automatic unique path rotation on conflict (0xc1420113 / 0xc1420114 / 0xc1420127)
function Invoke-WinEaseImageMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImageFile,
        [Parameter(Mandatory=$true)]
        [string]$ImageIndex,
        [switch]$ReadOnly,
        [ValidateRange(1, 5)]
        [int]$Retries = 3
    )

    $normWim = ConvertTo-WinEaseNormalizedPath -Path $ImageFile
    if (-not (Test-Path -LiteralPath $normWim)) {
        throw "Image file not found: $normWim"
    }

    $lastExitCode = 0
    $lastExitHex = ""
    $triedMountDirs = [System.Collections.Generic.List[string]]::new()

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        # 1. Allocate a fresh unique GUID mount path for every attempt
        $curMountDir = New-WinEaseMountDirectoryPath
        $triedMountDirs.Add($curMountDir)
        Write-Host "Preparing mount directory (Attempt $attempt of $Retries) at '$curMountDir'..." -ForegroundColor Cyan

        # 2. Physically recreate and verify empty directory
        Initialize-WinEaseMountDirectory -MountDir $curMountDir -WimFile $normWim -Retries $Retries

        # 3. Build DISM /Mount-Image arguments
        $dismMountArgs = @('/English')
        if ($script:DismLogPath) {
            $dismMountArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
        }
        $dismMountArgs += @('/Mount-Image', "/ImageFile:$normWim", "/Index:$ImageIndex", "/MountDir:$curMountDir")
        if ($ReadOnly) {
            $dismMountArgs += @('/ReadOnly')
        }

        & dism.exe @dismMountArgs
        $lastExitCode = $LASTEXITCODE
        $lastExitHex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$lastExitCode), 0))

        # 4. If exit code is 0, strictly verify DISM registration
        if ($lastExitCode -eq 0) {
            $mountedImages = @(Get-WinEaseMountedImages)
            $matchingMounts = @($mountedImages | Where-Object {
                $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
                $p -and ($p -ieq $curMountDir)
            })

            if ($matchingMounts.Count -eq 1) {
                $m = $matchingMounts[0]
                $imgNorm = try { ConvertTo-WinEaseNormalizedPath -Path $m.ImagePath } catch { $null }
                if ($imgNorm -and ($imgNorm -ieq $normWim) -and ($m.ImageIndex -eq $ImageIndex) -and ($m.MountStatus -ieq 'Ok')) {
                    Write-Host "Successfully mounted image to '$curMountDir' (Index: $ImageIndex, Status: $($m.MountStatus))." -ForegroundColor Green
                    return [PSCustomObject]@{
                        MountDir   = $curMountDir
                        ImageFile  = $normWim
                        ImageIndex = $ImageIndex
                    }
                }
            }
            Write-Warning "DISM returned 0 but mounted image verification failed for '$curMountDir'. Recovery required."
        }

        # 5. Handle mount failure and conflict recovery
        Write-Host "Mount attempt $attempt failed (Exit code: $lastExitHex / $lastExitCode). Resolving conflicts and recovering..." -ForegroundColor Yellow

        # Inspect if DISM actually created a partial mount on curMountDir
        $postCheckMounts = @(Get-WinEaseMountedImages)
        $partialMount = $postCheckMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and ($p -ieq $curMountDir)
        }

        if ($partialMount) {
            # Attempt to discard partial mount
            Write-Host "Discarding partial mount at '$curMountDir' (Status: $($partialMount.MountStatus))..." -ForegroundColor Yellow
            & dism.exe /English /Unmount-Image "/MountDir:$curMountDir" /discard > $null 2>&1
        }

        # Run safe mountpoint cleanup
        Invoke-WinEaseMountpointCleanup | Out-Null

        # Unload any offline hives
        try { [void](Unmount-DismOfflineHives -TargetMountDir $curMountDir -BestEffort) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

        # Re-verify that no active mount remains on curMountDir
        $verifyLingering = @(Get-WinEaseMountedImages) | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and ($p -ieq $curMountDir)
        }

        if ($verifyLingering) {
            Write-Warning "Unresolved mount remains on '$curMountDir'. Marking as Preserved for safety."
            [void]$script:PreservedMountDirs.Add($curMountDir)
            throw "Failed to resolve mount conflict on '$curMountDir'. Active mount remains: $($verifyLingering.MountStatus). Aborting for system protection."
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        if ($attempt -lt $Retries) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $triedStr = ($triedMountDirs -join ", ")
    throw "Failed to mount image '$normWim' (Index: $ImageIndex) after $Retries attempts. Tried directories: $triedStr. Last exit code: $lastExitHex ($lastExitCode)."
}
