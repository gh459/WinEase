# WinEaseFileSystem.ps1 - Directory safety checks, ownership/ACL, robust deletion and capacity checks
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).

# Helper function: Assert directory safety before destructive operations
function Assert-WinEaseDirectorySafety {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [ValidateSet('Reset', 'RemoveOfflineContent')]
        [string]$Operation
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Safety guard: Target path cannot be empty."
    }
    # F1-5: refuse drive-relative ('C:', 'C:foo') and root-relative ('\x') forms BEFORE
    # GetFullPath resolves them against the current directory of the drive - that resolution
    # disguises the target as an ordinary directory and bypasses the root/drive guard below.
    if (-not (Test-WinEaseAbsoluteLocalPath -Path $Path)) {
        throw "Safety guard: Refusing operation '$Operation' on root or drive directory (not an absolute local path): $Path"
    }
    $normPath = try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch {
        throw "Safety guard: Failed to normalize target path: $Path"
    }

    # Reject drive roots (e.g. C: or C:\), UNC roots, very short paths
    if ($normPath -match '^[a-zA-Z]:$' -or $normPath.Length -le 3 -or $normPath -match '^\\\\[^\\]+\\[^\\]+$') {
        throw "Safety guard: Refusing operation '$Operation' on root or drive directory: $normPath"
    }

    # Reject preserved directories that are marked as unresolved or inspection-only
    if ($Operation -eq 'Reset' -and $script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($normPath)) {
        throw "Safety guard: Target path '$normPath' is marked as Preserved (unresolved/protected). Refusing to reset."
    }

    # Reject critical host system directories
    $hostWin = [System.IO.Path]::GetFullPath($env:windir).TrimEnd('\')
    $hostProg = [System.IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
    $hostProgX86 = if (${env:ProgramFiles(x86)}) { [System.IO.Path]::GetFullPath(${env:ProgramFiles(x86)}).TrimEnd('\') } else { $null }
    $hostUsers = if ($env:SystemDrive) { [System.IO.Path]::GetFullPath("$($env:SystemDrive)\Users").TrimEnd('\') } else { $null }

    # Check if target path is inside the explicitly configured workspace or mount allocation root,
    # and remember which root contains it (used by the reparse-point ancestry check below)
    $isInsideWorkspace = $false
    $reparseWalkRoot = $null
    $normAllocRoot = if ($script:MountAllocationRoot) { [System.IO.Path]::GetFullPath($script:MountAllocationRoot).TrimEnd('\') } else { $null }
    $normBaseRoot = if ($script:BaseWorkDir) { [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\') } else { $null }
    if ($normAllocRoot) {
        if ($normPath -ieq $normAllocRoot -or $normPath.StartsWith($normAllocRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
            $reparseWalkRoot = $normAllocRoot
        }
    }
    if (-not $isInsideWorkspace -and $normBaseRoot) {
        if ($normPath -ieq $normBaseRoot -or $normPath.StartsWith($normBaseRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
            $reparseWalkRoot = $normBaseRoot
        }
    }

    $dangerousRoots = @($hostWin, $hostProg, $hostProgX86) | Where-Object { $_ }
    if (-not $isInsideWorkspace) {
        # Only treat $hostUsers as a dangerous root if the target is NOT inside our configured workspace
        if ($hostUsers) { $dangerousRoots += $hostUsers }
    } else {
        # Even inside workspace, the target cannot be the host Users root directory itself
        if ($hostUsers -and ($normPath -ieq $hostUsers)) {
            throw "Safety guard: Target path is host Users directory itself: $normPath"
        }
    }

    foreach ($dr in $dangerousRoots) {
        if ($normPath -ieq $dr -or $normPath.StartsWith($dr + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($Operation -eq 'RemoveOfflineContent') {
                if (-not $script:DismMountDir) {
                    throw "Safety guard: DismMountDir is not established. Cannot remove: $normPath"
                }
                $normScratch = [System.IO.Path]::GetFullPath($script:DismMountDir).TrimEnd('\')
                if (-not ($normPath.StartsWith($normScratch + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
                    throw "Safety guard: Target path is in protected host system directory: $normPath"
                }
            } else {
                throw "Safety guard: Target path is in protected host system directory: $normPath"
            }
        }
    }

    # F1-4: the containment checks above are lexical. A junction or symlink BETWEEN the
    # workspace root and the target can redirect a destructive operation to a directory
    # outside the workspace even though the target itself is a plain directory. Walk every
    # existing element between the containing workspace root and the target (the target
    # itself included) and refuse when any of them is a reparse point.
    if ($reparseWalkRoot -and (Test-WinEasePathHasReparsePoint -Path $normPath -Root $reparseWalkRoot)) {
        throw "Safety guard: Target path '$normPath' traverses a reparse point between the workspace root and the target. Refusing operation '$Operation'."
    }

    if ($Operation -eq 'Reset') {
        if ($script:BaseWorkDir) {
            $normBase = [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\')
            if ($normPath -ieq $normBase) {
                throw "Safety guard: Refusing to reset base workspace directory itself: $normPath"
            }
        }
        try {
            $mounted = @(Get-WinEaseMountedImages)
            # F1-2: mount records can be spelled with 8.3 short names, so compare real long
            # paths (existing segments expanded, reparse targets substituted) instead of raw
            # GetFullPath strings. An unresolvable record is a "cannot verify" failure.
            $normCompare = ConvertTo-WinEaseRealPath -Path $normPath
            if ($normCompare) { $normCompare = $normCompare.TrimEnd('\') } else { $normCompare = $normPath }
            foreach ($m in $mounted) {
                if ($m.Path) {
                    $mReal = ConvertTo-WinEaseRealPath -Path $m.Path
                    if (-not $mReal) {
                        throw "cannot resolve mount record path '$($m.Path)' to its real long path"
                    }
                    $mNorm = $mReal.TrimEnd('\')
                    if ($normCompare -ieq $mNorm -or $normCompare.StartsWith($mNorm + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $mNorm.StartsWith($normCompare + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Safety guard: Refusing to reset directory '$normPath' which overlaps with active DISM mount '$mNorm' (Status: $($m.MountStatus))"
                    }
                }
            }
        } catch {
            if ($_.Exception.Message -match "overlaps with active DISM mount") {
                throw $_
            }
            throw "Safety guard: Cannot verify mounted image status before Reset on '$normPath': $_"
        }
    } elseif ($Operation -eq 'RemoveOfflineContent') {
        if (-not $script:DismMountDir) {
            throw "Safety guard: Cannot execute RemoveOfflineContent when DismMountDir is not set."
        }
        $normScratch = [System.IO.Path]::GetFullPath($script:DismMountDir).TrimEnd('\')
        if ($normPath -ieq $normScratch -or -not ($normPath.StartsWith($normScratch + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Safety guard: RemoveOfflineContent is only permitted on strict descendants of DismMountDir ('$normScratch'): $normPath"
        }
    }
}

# Helper function: Strictly verify that a directory exists and is 100% empty (Resolves Error 0xc1420114)
function Assert-WinEaseDirectoryEmpty {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    if ($items.Count -gt 0) {
        $sample = ($items | Select-Object -First 20 | ForEach-Object { "$($_.FullName) [$($_.Attributes)]" }) -join "`n    "
        throw "Directory is not empty ($($items.Count) items found in '$Path'):`n    $sample"
    }
}

# Helper function: Take ownership and grant FullControl using PowerShell .NET ACL (Locale-independent via direct SID)
function Set-ItemOwnershipAndAccess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$Recurse,
        [switch]$Strict
    )
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
        return
    }

    # Language-independent Administrators group via Well-Known SID (S-1-5-32-544)
    $adminGroupSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')

    $failedItems = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue((Resolve-Path -LiteralPath $Path).Path)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not (Test-Path -LiteralPath $current)) { continue }

        $itemObj = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $itemObj) { continue }

        $isReparse = [bool]($itemObj.Attributes -band [System.IO.FileAttributes]::ReparsePoint)

        # Clear ReadOnly attribute if present
        if ($itemObj.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            try {
                $itemObj.Attributes = $itemObj.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
            } catch {
                try { Set-ItemProperty -LiteralPath $current -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }

        # Apply ownership and ACL
        $null = Enable-WinEaseTokenPrivileges
        $success = $false
        try {
            $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
            try { $acl.SetOwner($adminGroupSid) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminGroupSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]"None",
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
            $success = $true
        } catch {
            $repairErr = Repair-WinEaseDeniedAcl -Path $current
            if (-not $repairErr) {
                $success = $true
            }
        }

        if (-not $success) {
            & takeown.exe /F "$current" /A > $null 2>&1
            $takeExit = $LASTEXITCODE
            & icacls.exe "$current" /grant "*S-1-5-32-544:F" /C /Q > $null 2>&1
            $icaExit = $LASTEXITCODE
            if ($takeExit -eq 0 -or $icaExit -eq 0) {
                $success = $true
            }
        }

        if (-not $success -and $Strict) {
            $failedItems.Add($current)
        }

        # If it is a directory and NOT a reparse point, enqueue children
        if ($Recurse -and $itemObj.PSIsContainer -and (-not $isReparse)) {
            try {
                $children = Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop
                foreach ($c in $children) {
                    $pending.Enqueue($c.FullName)
                }
            } catch {
                if ($Strict) {
                    $failedItems.Add("$current (Enumeration failed: $_)")
                }
            }
        }
    }

    if ($Strict -and $failedItems.Count -gt 0) {
        $sample = ($failedItems | Select-Object -First 20) -join "`n    "
        throw "Failed to acquire ownership/access on $($failedItems.Count) item(s):`n    $sample"
    }
}

# Helper function: Robust directory deletion using empty directory robocopy mirror trick
function Remove-ProtectedDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ScratchPath', Justification = 'Kept for caller compatibility')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$ScratchPath,
        [int]$Retries = 3
    )
    Assert-WinEaseDirectorySafety -Path $Path -Operation 'RemoveOfflineContent'
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    if (-not (Test-Path -LiteralPath $full)) {
        return
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Set-ItemOwnershipAndAccess -Path $full -Recurse
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

        # 3. Safe native directory & reparse point removal (avoids robocopy /MIR junction traversal that deletes WinSxS targets)
        try {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                [System.IO.Directory]::Delete($full, $false)
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

        # 4. Windows native directory removal
        & cmd.exe /c "rd /s /q `"$full`"" > $null 2>&1

        # 5. PowerShell fallback removal
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $full)) {
            return
        }
        Start-Sleep -Milliseconds 500
    }

    if (Test-Path -LiteralPath $full) {
        throw "Failed to remove protected directory after $Retries attempts: $full"
    }
}

# Helper function: Check if foreign DISM activity is running and terminate dismhost/wimserv workers if safe
function Stop-WinEaseDismProcesses {
    param(
        [int]$Attempt
    )
    $foreignDismActive = $false
    if (Get-Process -Name "dism" -ErrorAction SilentlyContinue) {
        $foreignDismActive = $true
    } else {
        try {
            $foreignMounts = @(Get-WinEaseMountedImages | Where-Object {
                $_.Path -and -not (
                    (Test-WinEasePathWithin -Path $_.Path -Root $script:BaseWorkDir) -or
                    (Test-WinEasePathWithin -Path $_.Path -Root $script:MountAllocationRoot)
                )
            })
            if ($foreignMounts.Count -gt 0) { $foreignDismActive = $true }
        } catch {
            $foreignDismActive = $true
        }
    }
    if ($foreignDismActive) {
        Write-Warning "Reset attempt ${Attempt}: Other DISM activity detected outside the WinEase workspace. Not terminating dismhost/wimserv."
    } else {
        Get-Process -Name "dismhost", "wimserv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

# Helper function: Queue-based reparse point pruning without following links into targets
function Remove-WinEaseReparsePoints {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Attempt = 1
    )
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Path)
    $linkError = $false
    while ($queue.Count -gt 0) {
        $curr = $queue.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $curr -Force -ErrorAction Stop)
        } catch {
            Write-Warning "Reset attempt ${Attempt}: Could not enumerate '$curr': $_"
            return $false
        }
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                try {
                    if ($child.PSIsContainer) {
                        [System.IO.Directory]::Delete($child.FullName, $false)
                    } else {
                        [System.IO.File]::Delete($child.FullName)
                    }
                } catch {
                    Write-Warning "Reset attempt ${Attempt}: Failed to remove reparse point '$($child.FullName)': $_"
                    $linkError = $true
                }
            } elseif ($child.PSIsContainer) {
                $queue.Enqueue($child.FullName)
            }
        }
    }
    return (-not $linkError)
}

# Helper function: Strip ReadOnly, Hidden, and System attributes across root and children
function Clear-WinEaseDirectoryAttributes {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )
    $null = & attrib.exe -r -s -h $Path 2>&1
    $lastAttribExit = $LASTEXITCODE
    $childPattern = Join-Path -Path $Path -ChildPath '*'
    $null = & attrib.exe -r -s -h $childPattern /s /d 2>&1
    return $lastAttribExit
}

# Helper function: Run robocopy mirror against an empty temp directory
function Invoke-WinEaseRobocopyMirror {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Attempt = 1
    )
    $lastRoboOutput = $null
    $lastRoboExit = $null
    $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "WinEase_empty_$([System.IO.Path]::GetRandomFileName())"
    try {
        New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Assert-WinEaseDirectoryEmpty -Path $emptyTemp
        $lastRoboOutput = & robocopy.exe $emptyTemp $Path /MIR /XJ /R:0 /W:0 /NFL /NDL /NP /NJH /NJS 2>&1
        $lastRoboExit = $LASTEXITCODE
    } finally {
        if (Test-Path -LiteralPath $emptyTemp) {
            Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($lastRoboExit -ge 8) {
        Write-Warning "Reset attempt ${Attempt}: Robocopy error (Exit code: $lastRoboExit): $lastRoboOutput"
    }

    return [PSCustomObject]@{
        ExitCode = $lastRoboExit
        Output   = $lastRoboOutput
    }
}

# Helper function: Directly sweep remaining items in a directory post-robocopy
function Remove-WinEaseLingeringItems {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )
    $lingering = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    foreach ($item in $lingering) {
        try {
            if ($item.PSIsContainer) {
                [System.IO.Directory]::Delete($item.FullName, $true)
            } else {
                [System.IO.File]::Delete($item.FullName)
            }
        } catch {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }
    }
}

# Helper function: Build diagnostic failure report string for Reset-DirectoryWithRobocopy
function Get-WinEaseResetDiagnosticDetails {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Retries,
        $LastException,
        $LastRoboExit,
        $LastAttribExit
    )
    $remainingItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    $remainingDetails = ($remainingItems | ForEach-Object { "$($_.FullName) [$($_.Attributes)]" }) -join "`n    "
    $hivesInfo = ""
    if ($script:ManagedMountDirs.Contains($Path)) {
        try {
            $leftoverHives = @(Get-WinEaseDismOfflineHives -TargetMountDir $Path)
            if ($leftoverHives.Count -gt 0) {
                $hivesInfo = "`nLingering DISM offline registry hives:`n    " + (($leftoverHives | ForEach-Object { "$($_.KeyName) -> $($_.HivePath)" }) -join "`n    ")
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    return "Reset-DirectoryWithRobocopy failed to empty directory '$Path' after $Retries attempts.$hivesInfo`nRemaining items ($($remainingItems.Count)):`n    $remainingDetails`nLast error: $LastException`nRobocopy Exit Code: $LastRoboExit`nAttrib Exit Code: $LastAttribExit`nPlease close any process locking these files or restart Windows before retrying."
}

# Helper function: Fast and reliable directory reset using robocopy mirror trick (Guaranteed Empty)
function Reset-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [ValidateRange(1, 5)]
        [int]$Retries = 3
    )
    Assert-WinEaseDirectorySafety -Path $Path -Operation 'Reset'
    $full = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }

    # If this is a managed DISM mount directory, safely unload any locked offline hives first
    if ($script:ManagedMountDirs.Contains($full)) {
        [void](Unmount-DismOfflineHives -TargetMountDir $full)
    }

    if (-not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Force -Path $full -ErrorAction Stop | Out-Null
        return
    }

    $lastEx = $null
    $lastRoboExit = $null
    $lastAttribExit = $null

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        Assert-WinEaseDirectorySafety -Path $full -Operation 'Reset'

        if ($attempt -gt 1) {
            Stop-WinEaseDismProcesses -Attempt $attempt
            Start-Sleep -Seconds ($attempt * 2)
        }

        $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Safety violation: Target directory '$full' is itself a reparse point. Refusing to reset directly."
        }

        $linkClean = Remove-WinEaseReparsePoints -Path $full -Attempt $attempt

        if ($linkClean) {
            try {
                Set-ItemOwnershipAndAccess -Path $full -Recurse -Strict
            } catch {
                Write-Warning "Reset attempt ${attempt}: Ownership adjustment warning: $_"
            }

            $lastAttribExit = Clear-WinEaseDirectoryAttributes -Path $full

            $roboRes = Invoke-WinEaseRobocopyMirror -Path $full -Attempt $attempt
            $lastRoboExit = $roboRes.ExitCode

            # Sweep remaining items directly
            try {
                Remove-WinEaseLingeringItems -Path $full
            } catch {
                $lastEx = $_
            }
        } else {
            $lastEx = "Failed to clear reparse points within directory"
        }

        # Validate directory is strictly empty
        try {
            Assert-WinEaseDirectoryEmpty -Path $full
            return
        } catch {
            $lastEx = $_
            if ($attempt -lt $Retries) {
                if ($script:ManagedMountDirs.Contains($full)) {
                    try { [void](Unmount-DismOfflineHives -TargetMountDir $full -BestEffort) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                }
                Start-Sleep -Seconds $attempt
            }
        }
    }

    # Final attempt failed - build rich diagnostic failure report
    $diagMsg = Get-WinEaseResetDiagnosticDetails -Path $full -Retries $Retries -LastException $lastEx -LastRoboExit $lastRoboExit -LastAttribExit $lastAttribExit
    throw $diagMsg
}

# Helper function: Safe mountpoint cleanup guarded against modifying unmanaged external mounts
# ==============================================================================
# Helper Functions: Safe Deletion, Promotion, Metadata & Capacity Verification
function Invoke-WinEasePromoteTemporaryIso {
    param(
        [string]$TempIsoPath,
        [string]$TargetIsoPath,
        [string]$BuildId
    )
    if (-not (Test-Path -LiteralPath $TempIsoPath)) {
        throw "Temporary ISO not found: $TempIsoPath"
    }
    $targetDir = Split-Path -Path $TargetIsoPath -Parent
    if (-not $targetDir) { $targetDir = (Split-Path -Parent $PSScriptRoot) }
    $oldIsoBackup = Join-Path -Path $targetDir -ChildPath "WinEase_old_backup_${BuildId}.iso"

    $hasOldIso = Test-Path -LiteralPath $TargetIsoPath
    if ($hasOldIso) {
        Write-Host "Backing up existing ISO to unique backup: $oldIsoBackup..." -ForegroundColor Cyan
        Move-Item -LiteralPath $TargetIsoPath -Destination $oldIsoBackup -Force -ErrorAction Stop
    }

    $promotedSuccessfully = $false
    try {
        Write-Host "Promoting verified temporary ISO to official release name..." -ForegroundColor Cyan
        Move-Item -LiteralPath $TempIsoPath -Destination $TargetIsoPath -Force -ErrorAction Stop
        $promotedSuccessfully = $true
    } catch {
        $moveErr = $_
        if ($hasOldIso -and (Test-Path -LiteralPath $oldIsoBackup)) {
            Write-Warning "Promotion failed ($moveErr). Attempting rollback from $oldIsoBackup..."
            try {
                Move-Item -LiteralPath $oldIsoBackup -Destination $TargetIsoPath -Force -ErrorAction Stop
                Write-Host "Rollback successful: Restored original ISO to $TargetIsoPath." -ForegroundColor Green
            } catch {
                $rollbackErr = $_
                Write-Warning "CRITICAL: Rollback failed ($rollbackErr). Preserving backup at $oldIsoBackup"
                if ($script:DiagnosticData) {
                    $script:DiagnosticData.PreservedArtifacts += $oldIsoBackup
                }
                throw "Failed to promote temporary ISO to ${TargetIsoPath} ($moveErr) AND rollback restoration failed ($rollbackErr). Original ISO preserved at: $oldIsoBackup"
            }
        }
        throw "Failed to promote temporary ISO to ${TargetIsoPath}: $moveErr"
    }

    if ($promotedSuccessfully -and $hasOldIso -and (Test-Path -LiteralPath $oldIsoBackup)) {
        Remove-Item -LiteralPath $oldIsoBackup -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Test-WinEaseMetadataAndCapacity {
    param(
        [string]$WimPath,
        [string]$ExpectedEdition,
        [string]$ExpectedArch,
        [string]$VerifyApplyDir,
        [string]$VhdxFilePath = $null,
        [bool]$IsVhdx = $false
    )
    Write-Host "Querying WIM metadata via DISM /Get-WimInfo..." -ForegroundColor Cyan
    $dismMetaOut = & dism.exe /English /Get-WimInfo "/WimFile:$WimPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query WIM metadata (ExitCode: $LASTEXITCODE)."
    }
    $metaText = ($dismMetaOut -join "`n")
    $hasIndex1 = ($metaText -match '(?m)^\s*Index\s*:\s*1\s*$')
    $totalIndexCount = ([regex]::Matches($metaText, '(?m)^\s*Index\s*:\s*\d+\s*$')).Count
    if (-not $hasIndex1 -or ($totalIndexCount -ne 1)) {
        throw "WIM metadata validation failed: Expected exactly 1 index (Index 1), found $totalIndexCount indices."
    }

    $dismIdx1Out = & dism.exe /English /Get-WimInfo "/WimFile:$WimPath" "/Index:1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query WIM Index 1 detailed info (ExitCode: $LASTEXITCODE)."
    }
    $idx1Text = ($dismIdx1Out -join "`n")

    $editionName = if ($idx1Text -match '(?m)^\s*Name\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $arch = if ($idx1Text -match '(?m)^\s*Architecture\s*:\s*(\w+)') { $matches[1].Trim() } else { $null }
    $sizeRaw = if ($idx1Text -match '(?m)^\s*Size\s*:\s*([\d,]+)\s*bytes') { $matches[1] -replace ',', '' } else { $null }

    if (-not $editionName -or -not $arch -or -not $sizeRaw) {
        throw "Failed to extract required image info (Edition: '$editionName', Arch: '$arch', Size: '$sizeRaw')."
    }

    if ($ExpectedEdition -and ($editionName -inotlike "*$ExpectedEdition*")) {
        throw "Edition mismatch: Expected '$ExpectedEdition', found '$editionName'."
    }

    $normArch = $arch.ToLower()
    $normExpectedArch = if ($ExpectedArch) { $ExpectedArch.ToLower() } else { "" }
    if ($normExpectedArch -eq 'amd64') { $normExpectedArch = 'x64' }
    if ($normArch -eq 'amd64') { $normArch = 'x64' }
    if ($normExpectedArch -and ($normArch -ne $normExpectedArch)) {
        throw "Architecture mismatch: Expected '$normExpectedArch', found '$normArch'."
    }

    [int64]$expandedSizeBytes = [int64]$sizeRaw
    $expandedSizeGB = [math]::Ceiling($expandedSizeBytes / 1GB)
    $scratchMarginGB = 5
    $requiredSpaceGB = [math]::Max(15, ($expandedSizeGB + $scratchMarginGB))

    $targetFreeGB = Get-WinEaseVolumeFreeSpaceGB -Path $VerifyApplyDir
    $applyDriveLetter = try { (Split-Path -Path ([System.IO.Path]::GetFullPath($VerifyApplyDir)) -Qualifier).TrimEnd(':') } catch { "C" }

    Write-Host "Capacity Analysis for Deep Apply Verification:" -ForegroundColor Cyan
    Write-Host "  - Uncompressed Expanded Image Size: $expandedSizeGB GB ($expandedSizeBytes bytes)" -ForegroundColor Gray
    Write-Host "  - Scratch & Working Overhead:       $scratchMarginGB GB" -ForegroundColor Gray
    Write-Host "  - Dynamic Required Space:           $requiredSpaceGB GB" -ForegroundColor Gray
    Write-Host "  - Apply Target Volume (${applyDriveLetter}:):     $targetFreeGB GB available" -ForegroundColor Gray

    if ($IsVhdx -and $VhdxFilePath -and (Test-Path -LiteralPath $VhdxFilePath)) {
        $vhdxHostFreeGB = Get-WinEaseVolumeFreeSpaceGB -Path $VhdxFilePath
        $vhdxHostDriveLetter = try { (Split-Path -Path (Resolve-Path $VhdxFilePath).Path -Qualifier).TrimEnd(':') } catch { "C" }
        Write-Host "  - VHDX Host Volume (${vhdxHostDriveLetter}:):          $vhdxHostFreeGB GB available" -ForegroundColor Gray

        if ($applyDriveLetter -ieq $vhdxHostDriveLetter) {
            if ($targetFreeGB -lt $requiredSpaceGB) {
                throw "Insufficient disk space on host volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required)."
            }
        } else {
            if ($targetFreeGB -lt $requiredSpaceGB) {
                throw "Insufficient disk space on VHDX apply volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required)."
            }
            if ($vhdxHostFreeGB -lt 10) {
                throw "Insufficient disk space on VHDX host volume ${vhdxHostDriveLetter}: ($vhdxHostFreeGB GB available, minimum 10 GB required to back VHDX expansion)."
            }
        }
    } else {
        if ($targetFreeGB -lt $requiredSpaceGB) {
            throw "Insufficient disk space on volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required for expanded image + overhead)."
        }
    }

    return [PSCustomObject]@{
        EditionName      = $editionName
        Architecture     = $arch
        ExpandedSizeGB   = $expandedSizeGB
        RequiredSpaceGB  = $requiredSpaceGB
        TargetFreeGB     = $targetFreeGB
    }
}

# ----------------------------------------------------------------------------
# ACL-repair prerequisites: enable the token privileges that allow changing
# owner/DACL on image-protected trees in-process (P/Invoke, Add-Type).
# WHY not takeown/icacls: verified on the real leftover tree (2026-10-18) -
#   * takeown.exe REJECTS "/f <dir> /d y" (needs /R): argv validation error,
#     exit 1, NOTHING changed - and stderr went to $null, so the failure was
#     invisible in every build log;
#   * icacls reports "Access is denied" yet still exits 0, so exit codes alone
#     cannot detect its failure either;
#   * takeown /r and icacls /T recursively traverse junctions (verified hazard).
# Set-Acl raises real catchable .NET exceptions instead, and stays non-recursive.
# ----------------------------------------------------------------------------
function Enable-WinEaseTokenPrivileges {
    param([string[]]$Privileges = @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege'))
    if (-not ('WinEase.TokenHelpers' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinEase {
    public static class TokenHelpers {
        [StructLayout(LayoutKind.Sequential)]
        public struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        public struct TOKEN_PRIVILEGES {
            public uint PrivilegeCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
            public LUID_AND_ATTRIBUTES[] Privileges;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static bool EnablePrivilege(string name) {
            const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
            const uint TOKEN_QUERY = 0x0008;
            const uint SE_PRIVILEGE_ENABLED = 0x0002;
            const int ERROR_NOT_ALL_ASSIGNED = 1300;

            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) { return false; }
            try {
                LUID luid;
                if (!LookupPrivilegeValue(null, name, out luid)) { return false; }
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privileges = new LUID_AND_ATTRIBUTES[1];
                tp.Privileges[0].Luid = luid;
                tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
                if (!AdjustTokenPrivileges(token, false, ref tp, (uint)Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), IntPtr.Zero, IntPtr.Zero)) { return false; }
                return Marshal.GetLastWin32Error() != ERROR_NOT_ALL_ASSIGNED;
            } finally {
                CloseHandle(token);
            }
        }
    }
}
'@ -ErrorAction Stop
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    if (-not ('WinEase.TokenHelpers' -as [type])) {
        if (-not $script:WinEaseTokenHelperWarned) {
            $script:WinEaseTokenHelperWarned = $true
            Write-Warning "Enable-WinEaseTokenPrivileges: token helper type unavailable (Add-Type failed); ACL repair cannot elevate owner/DACL rights."
        }
        return $false
    }
    $allEnabled = $true
    foreach ($privilege in $Privileges) {
        try { if (-not ([WinEase.TokenHelpers]::EnablePrivilege($privilege))) { $allEnabled = $false } }
        catch { $allEnabled = $false }
    }
    return $allEnabled
}

# NON-recursive repair of one unreadable directory: take ownership for
# BUILTIN\Administrators (S-1-5-32-544), strip explicit Deny ACEs aimed at
# Administrators, add an inheritable FullControl grant, write it back via Set-Acl.
# The (OI)(CI) grant propagates to children inside this tree only (verified: it
# does NOT cross junctions - a link target keeps its own ACLs). Protected child
# directories are picked up by the next helper iteration.
# NEVER make this recursive (links may live below - verified hazard).
# Returns $null on success, or a one-line error message on failure (caller logs it).
function Repair-WinEaseDeniedAcl {
    param([Parameter(Mandatory=$true)][string]$Path)
    $null = Enable-WinEaseTokenPrivileges
    $adminsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch {
        # Unreadable DACL (e.g. owner is a service account and no Administrators ACE exists):
        # build a FRESH descriptor. With the privileges enabled above, WRITE_OWNER/WRITE_DAC
        # are granted regardless of the DACL, so one Set-Acl writes owner + inheritable grant.
        try {
            $fresh = New-Object System.Security.AccessControl.DirectorySecurity
            $fresh.SetOwner($adminsSid)
            $grant = New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            [void]$fresh.AddAccessRule($grant)
            Set-Acl -LiteralPath $Path -AclObject $fresh -ErrorAction Stop
            return $null
        } catch {
            return "fresh-descriptor Set-Acl failed: $(($_ -split "`n")[0])"
        }
    }
    try {
        $acl.SetOwner($adminsSid)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                $rule.IdentityReference.Value -eq 'S-1-5-32-544') {
                [void]$acl.RemoveAccessRuleSpecific($rule)
            }
        }
        $grant = New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($grant)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        return "Set-Acl failed: $(($_ -split "`n")[0])"
    }
    return $null
}

# Robust directory removal (long paths + image ACLs) - lifecycle cleanup fix
# WHY: PowerShell 5.1 Remove-Item fails with ACCESS DENIED on expanded Windows
# images (files owned by TrustedInstaller with Administrators granted RX only)
# and -ErrorAction SilentlyContinue turns that into a silent, invisible leak.
# cmd "rd /s /q" fails on the same ACLs too. robocopy /MIR /B (backup mode,
# SeBackupPrivilege) deletes them regardless of the DACL.
# Reparse points are pruned first on purpose: applied-image junctions such as
# 'Users\All Users' -> C:\ProgramData point at HOST paths, so nothing may ever
# recurse through them.
#   Pass: tolerant reparse prune -> [robocopy /MIR /XJ /B only when the tree is proven
#         link-free] -> rd /s /q, retried up to 4x; unreadable directories receive a
#         NON-recursive, in-process ACL repair between passes (take ownership +
#         inheritable Administrators grant via Set-Acl, see Repair-WinEaseDeniedAcl).
#         The previous takeown/icacls repair was a SILENT NO-OP: current Windows 11
#         takeown rejects "/d y" without "/r" (argv validation, exit 1) and icacls
#         reports "Access is denied" while still exiting 0 - and both stderr streams
#         were discarded ("> $null 2>&1"), which is what leaked the 17.2 GB tree.
#         VERIFIED HAZARDS: takeown /r and icacls /T traverse junctions, and robocopy /MIR
#         purges THROUGH junctions even with /XJ - so no recursive ACL grant and no mirror
#         purge may ever run while a link could remain (visible or hidden).
#   Fallback: (opt-in) Reset-DirectoryWithRobocopy for locked trees / loaded hives
# Returns $true when the path no longer exists.
function Remove-WinEaseTreeRobust {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$SafetyRoot,
        [switch]$AllowLockedFallback
    )
    # rd and robocopy report failures on stderr. When the caller runs with
    # $ErrorActionPreference = 'Stop' (the GitHub Actions powershell shell does), Windows
    # PowerShell 5.1 turns those redirected lines into terminating errors, so this function
    # threw "Access is denied" instead of retrying and returning $false. The result is
    # reported through the return value, so keep native-tool noise non-terminating here.
    # The assignment is local to this function and restored when it returns.
    $ErrorActionPreference = 'Continue'
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    $full = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }

    # Safety guards: never operate on a drive root, and (when given) only on a strict child of SafetyRoot
    if ($full -match '^[A-Za-z]:$') {
        Write-Warning "Remove-WinEaseTreeRobust: refusing to remove drive root '$full'."
        return $false
    }
    if ($SafetyRoot) {
        $normRoot = try { ConvertTo-WinEaseNormalizedPath -Path $SafetyRoot } catch { [System.IO.Path]::GetFullPath($SafetyRoot).TrimEnd('\') }
        if (($full -ieq $normRoot) -or (-not (Test-WinEasePathWithin -Path $full -Root $normRoot))) {
            Write-Warning "Remove-WinEaseTreeRobust: refusing '$full' (not a strict child of safety root '$normRoot')."
            return $false
        }
        # F1-4: the strict-child check is lexical. A junction between the safety root and the
        # target's parent would redirect the removal outside the safety root. Walk the existing
        # ancestors (NOT the target itself - a reparse-point target is legitimately removed as
        # a link only, below) and refuse when any of them is a reparse point.
        $parentOfFull = Split-Path -Parent $full
        if ($parentOfFull -and (Test-WinEasePathHasReparsePoint -Path $parentOfFull -Root $normRoot)) {
            Write-Warning "Remove-WinEaseTreeRobust: refusing '$full' (a reparse point exists between the safety root and its parent)."
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $full)) { return $true }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # If the directory itself is a reparse point, remove the link only (never the target)
    $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($rootItem -and ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        try { [System.IO.Directory]::Delete($full, $false) } catch { Write-Warning "Remove-WinEaseTreeRobust: failed to remove reparse point '$full': $_" }
        return (-not (Test-Path -LiteralPath $full))
    }

    # Tolerant reparse prune + native passes, iterated while progress is made.
    # SAFETY (empirically verified on Windows 11): takeown /r and icacls /T DO traverse
    # junctions, so no recursive ACL grant may ever meet a surviving link. ACL repair of
    # unreadable directories is therefore done NON-recursively, one directory at a time.
    $linkDeleteFailed = $false
    $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "WinEase_empty_$([System.IO.Path]::GetRandomFileName())"
    $enumDenied = [System.Collections.Generic.List[string]]::new()
    $linkFailedParents = [System.Collections.Generic.List[string]]::new()
    $repairFailures = [System.Collections.Generic.Dictionary[string,string]]::new()

    try {
        $null = New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop
    } catch {
        Write-Warning "Remove-WinEaseTreeRobust: could not create mirror source '$emptyTemp': $_"
    }

    try {
        for ($iteration = 1; $iteration -le 4; $iteration++) {
            # --- Repair ACLs on directories the previous pass could not read, plus the parents
            # --- of links the previous pass could not delete (all non-recursive on the target;
            # --- the (OI)(CI) grant then propagates inside this tree only) ---
            if ($iteration -ge 2) {
                foreach ($deniedPath in (@($enumDenied) + @($linkFailedParents) + @($full))) {
                    if (-not (Test-WinEasePathExistsSafe -Path $deniedPath)) { continue }
                    # Inheritable grant repairs the whole subtree in one pass and makes child
                    # links deletable; ACL propagation is verified NOT to cross junctions (a
                    # link target keeps its own ACLs). Children with protected ACLs are picked
                    # up by the next iteration. Failures are recorded (first error per path)
                    # and surfaced in the final warning instead of being swallowed.
                    $repairError = Repair-WinEaseDeniedAcl -Path $deniedPath
                    if ($repairError) {
                        if (-not $repairFailures.ContainsKey($deniedPath)) { $repairFailures[$deniedPath] = $repairError }
                        Write-Verbose "Remove-WinEaseTreeRobust: ACL repair failed for '$deniedPath': $repairError"
                    }
                }
                $enumDenied.Clear()
                $linkFailedParents.Clear()
            }

            # --- Prune visible reparse points (unreadable subdirs are recorded, not fatal) ---
            $prunedLinks = 0
            $linkDeleteFailed = $false
            $queue = [System.Collections.Generic.Queue[string]]::new()
            $queue.Enqueue($full)
            while ($queue.Count -gt 0) {
                $curr = $queue.Dequeue()
                # Enumeration failures are expected for not-yet-repaired protected dirs; capture
                # them via -ErrorVariable instead of try/catch so the transcript stays clean.
                $walkErr = $null
                $children = @(Get-ChildItem -LiteralPath $curr -Force -ErrorAction SilentlyContinue -ErrorVariable walkErr)
                if ($null -ne $walkErr -and @($walkErr).Count -gt 0) { $enumDenied.Add($curr); continue }
                foreach ($child in $children) {
                    if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        try {
                            if ($child.PSIsContainer) { [System.IO.Directory]::Delete($child.FullName, $false) }
                            else { [System.IO.File]::Delete($child.FullName) }
                            $prunedLinks++
                        } catch {
                            Write-Warning "Remove-WinEaseTreeRobust: could not prune reparse point '$($child.FullName)': $_"
                            $linkDeleteFailed = $true
                            $linkParent = [System.IO.Path]::GetDirectoryName($child.FullName)
                            if ($linkParent -and -not $linkFailedParents.Contains($linkParent)) { $linkFailedParents.Add($linkParent) }
                        }
                    } elseif ($child.PSIsContainer) {
                        $queue.Enqueue($child.FullName)
                    }
                }
            }
            if ($linkDeleteFailed) { continue }   # links survived: skip robocopy/rd, retry after repairing their parents

            # --- Backup-mode mirror: ONLY when the walk proved the tree is link-free.
            # VERIFIED HAZARD: robocopy /MIR purges THROUGH junctions even with /XJ (every
            # tested variant destroyed the junction target), so it must never meet an
            # unverified tree - not even one whose links are merely hidden from us.
            if ($enumDenied.Count -eq 0 -and (Test-Path -LiteralPath $emptyTemp)) {
                $null = & robocopy.exe $emptyTemp $full /MIR /XJ /B /R:0 /W:0 /NFL /NDL /NP /NJH /NJS 2>&1
            }

            # rd never follows junctions (verified): safe even while denied dirs remain
            & cmd.exe /c "rd /s /q `"$full`"" > $null 2>&1
            if (-not (Test-Path -LiteralPath $full)) {
                Write-Verbose "Remove-WinEaseTreeRobust: '$full' removed (iteration $iteration, $prunedLinks link(s) pruned, enumDenied=$($enumDenied.Count)) in $([math]::Round($sw.Elapsed.TotalSeconds,1))s."
                return $true
            }
        }
    } finally {
        if (Test-Path -LiteralPath $emptyTemp) { Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- Tier 3: heavy reset machinery for locked trees / loaded offline hives (opt-in) ---
    if ($AllowLockedFallback) {
        if (Get-Command -Name Reset-DirectoryWithRobocopy -ErrorAction SilentlyContinue) {
            try { Reset-DirectoryWithRobocopy -Path $full -Retries 2 } catch { Write-Warning "Remove-WinEaseTreeRobust: heavy reset failed for '$full': $(($_ -split "`n")[0])" }
            if (Test-Path -LiteralPath $full) {
                if (-not $linkDeleteFailed) { & cmd.exe /c "rd /s /q `"$full`"" > $null 2>&1 }
                else { try { [System.IO.Directory]::Delete($full, $false) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
            }
            if (-not (Test-Path -LiteralPath $full)) {
                Write-Verbose "Remove-WinEaseTreeRobust: '$full' removed via tier 3 in $([math]::Round($sw.Elapsed.TotalSeconds,1))s."
                return $true
            }
        } else {
            Write-Warning "Remove-WinEaseTreeRobust: Reset-DirectoryWithRobocopy not available; heavy fallback skipped for '$full'."
        }
    }

    $repairDetail = ''
    if ($repairFailures.Count -gt 0) {
        $repairSamples = @($repairFailures.Keys | Select-Object -First 3 | ForEach-Object { "'$_': $($repairFailures[$_])" }) -join '; '
        $repairDetail = " ACL repair errors ($($repairFailures.Count)): $repairSamples"
    }
    Write-Warning "Remove-WinEaseTreeRobust: '$full' could not be fully removed (linkPruneClean=$(-not $linkDeleteFailed), elapsed $([math]::Round($sw.Elapsed.TotalSeconds,1))s).$repairDetail"
    return $false
}
# Helper function: Write text file atomically with retry logic to avoid external lock failure

function Write-WinEaseTextFileAtomic {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$Content,
        [object]$Encoding = $null,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 200
    )
    $actualEncoding = if ($Encoding -is [System.Text.Encoding]) {
        $Encoding
    } elseif ($Encoding -is [string] -and $Encoding.ToLower() -eq 'ascii') {
        [System.Text.Encoding]::ASCII
    } elseif ($Encoding -is [string] -and $Encoding.ToLower() -eq 'unicode') {
        [System.Text.Encoding]::Unicode
    } else {
        [System.Text.Encoding]::UTF8
    }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue
    }
    $tempPath = "$Path.$([System.Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $actualEncoding)
    } catch {
        Write-Warning "Write-WinEaseTextFileAtomic: Failed to write initial temp file '$tempPath': $_"
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ([System.IO.File]::Exists($Path)) {
                try {
                    [System.IO.File]::Replace($tempPath, $Path, $null, $true)
                    return $true
                } catch {
                    [System.IO.File]::Delete($Path)
                    [System.IO.File]::Move($tempPath, $Path)
                    return $true
                }
            } else {
                [System.IO.File]::Move($tempPath, $Path)
                return $true
            }
        } catch {
            if ($attempt -eq $MaxRetries) {
                try {
                    [System.IO.File]::WriteAllText($Path, $Content, $actualEncoding)
                    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
                    return $true
                } catch {
                    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
                    Write-Warning "Write-WinEaseTextFileAtomic failed for '$Path': $_"
                    return $false
                }
            }
            Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
        }
    }
    return $false
}

# --- Workspace ownership marker -------------------------------------------------------------------
# The builder empties <WorkDir>\build and <WorkDir>\scratchdir (robocopy /MIR plus an ACL rewrite).
# -WorkDir can point at any folder, so a folder that happens to hold its own "build" or "scratchdir"
# must not be wiped silently. A workspace WinEase created carries this marker; a non-empty folder
# without it is only reset after an explicit -ForceResetWorkspace.
# (The marker file name is '.winease-workspace'; the modules hold functions only, so it is written out in both users.)

function Test-WinEaseDirectoryHasContent {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return ($null -ne (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
}

function Test-WinEaseWorkspaceResetAllowed {
    <#
    .SYNOPSIS
        Decides whether <BaseWorkDir>\build and <BaseWorkDir>\scratchdir may be emptied.
    .OUTPUTS
        PSCustomObject: Allowed (bool), Reason (string), Paths (the non-empty folders that block the reset).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BaseWorkDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$ScratchDir,
        [switch]$Force
    )
    $result = { param($allowed, $reason, $paths) [PSCustomObject]@{ Allowed = $allowed; Reason = $reason; Paths = @($paths) } }
    $marker = Join-Path -Path $BaseWorkDir -ChildPath '.winease-workspace'
    if (Test-Path -LiteralPath $marker -PathType Leaf) { return (& $result $true 'marker' @()) }

    $buildFull = Test-WinEaseDirectoryHasContent -Path $BuildDir
    $scratchFull = Test-WinEaseDirectoryHasContent -Path $ScratchDir
    if (-not $buildFull -and -not $scratchFull) { return (& $result $true 'empty' @()) }
    if ($Force) { return (& $result $true 'forced' @()) }

    # A workspace from a WinEase version that wrote no marker: the default folder name, or folders
    # that carry what WinEase puts there (build\sources, a mounted image under scratchdir).
    if ((Split-Path -Leaf $BaseWorkDir) -ieq 'WinEase_workspace') { return (& $result $true 'default-name' @()) }
    $legacyBuild = (-not $buildFull) -or (Test-Path -LiteralPath (Join-Path -Path $BuildDir -ChildPath 'sources') -PathType Container)
    $legacyScratch = (-not $scratchFull) -or
        (Test-Path -LiteralPath (Join-Path -Path $ScratchDir -ChildPath 'Windows') -PathType Container) -or
        (Test-Path -LiteralPath (Join-Path -Path $ScratchDir -ChildPath 'mount') -PathType Container)
    if ($legacyBuild -and $legacyScratch) { return (& $result $true 'legacy-signature' @()) }

    $blocking = @()
    if ($buildFull -and -not $legacyBuild) { $blocking += $BuildDir }
    if ($scratchFull -and -not $legacyScratch) { $blocking += $ScratchDir }
    return (& $result $false 'unmarked' $blocking)
}

function Write-WinEaseWorkspaceMarker {
    param([Parameter(Mandatory = $true)][string]$BaseWorkDir, [string]$BuildId = '')
    $marker = Join-Path -Path $BaseWorkDir -ChildPath '.winease-workspace'
    if (Test-Path -LiteralPath $marker -PathType Leaf) { return $true }
    $json = [ordered]@{ Tool = 'WinEase'; Purpose = 'build workspace'; CreatedUtc = [DateTime]::UtcNow.ToString('o'); BuildId = $BuildId } | ConvertTo-Json
    $ok = Write-WinEaseTextFileAtomic -Path $marker -Content $json
    if (-not $ok) { Write-Warning "Could not write the workspace marker '$marker'. The next build into this folder will need -ForceResetWorkspace." }
    return [bool]$ok
}

function Invoke-WinEasePromoteExportedWim {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentWim,
        [Parameter(Mandatory = $true)][string]$ExportedWim,
        [Parameter(Mandatory = $true)][string]$BackupWim
    )
    if (-not (Test-Path -LiteralPath $ExportedWim -PathType Leaf)) {
        throw "Exported WIM not found: $ExportedWim"
    }
    Move-Item -LiteralPath $CurrentWim -Destination $BackupWim -Force -ErrorAction Stop
    try {
        Move-Item -LiteralPath $ExportedWim -Destination $CurrentWim -Force -ErrorAction Stop
    } catch {
        $swapErr = $_
        # Never leave the ISO tree without an install image: put the pre-export image back.
        if ((Test-Path -LiteralPath $BackupWim) -and -not (Test-Path -LiteralPath $CurrentWim)) {
            try {
                Move-Item -LiteralPath $BackupWim -Destination $CurrentWim -Force -ErrorAction Stop
                Write-Warning "Export promotion failed ($swapErr). Restored the pre-export image to $CurrentWim."
            } catch {
                $restoreErr = $_
                if ($script:DiagnosticData) { $script:DiagnosticData.PreservedArtifacts += $BackupWim }
                throw "Failed to move the exported WIM into place ($swapErr) AND restoring the pre-export image failed ($restoreErr). The original image is preserved at: $BackupWim"
            }
        }
        throw "Failed to move the exported WIM into place: $swapErr"
    }
    return $true
}

function Get-WinEaseMinimumExportBytes {
    param([long]$SourceBytes = 0)
    if ($SourceBytes -le 0) { return [long]500MB }
    return [long][math]::Max([long]200MB, [long][math]::Floor($SourceBytes * 0.25))
}

function Get-WinEaseMinimumIsoBytes {
    param([long]$PayloadBytes = 0)
    if ($PayloadBytes -le 0) { return [long]1.5GB }
    # The ISO holds the payload plus boot media; anything smaller than payload + 100MB is truncated.
    return [long]($PayloadBytes + 100MB)
}

# Removes everything inside a directory and keeps the directory. Replaces "Remove-Item -Path '<dir>\*'
# -Recurse", whose wildcard also expands against unexpected names and follows links on older hosts.
# Children that are reparse points (junctions/symlinks) are never followed or deleted through; they are
# reported. Returns the number of entries that could not be removed.
function Clear-WinEaseDirectoryContents {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    $failed = 0
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Not removing the link '$($child.FullName)' (reparse point)."
            $failed++
            continue
        }
        try {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Could not remove '$($child.FullName)': $($_.Exception.Message)"
            $failed++
        }
    }
    return $failed
}