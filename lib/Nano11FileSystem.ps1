# Nano11FileSystem.ps1 - Directory safety checks, ownership/ACL, robust deletion and capacity checks
# Dot-sourced into the script scope of nano11builder.ps1 (function definitions only).

# Helper function: Assert directory safety before destructive operations
function Assert-Nano11DirectorySafety {
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

    # Check if target path is inside the explicitly configured workspace or mount allocation root
    $isInsideWorkspace = $false
    if ($script:MountAllocationRoot) {
        $normAllocRoot = [System.IO.Path]::GetFullPath($script:MountAllocationRoot).TrimEnd('\')
        if ($normPath -ieq $normAllocRoot -or $normPath.StartsWith($normAllocRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
        }
    }
    if (-not $isInsideWorkspace -and $script:BaseWorkDir) {
        $normBaseRoot = [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\')
        if ($normPath -ieq $normBaseRoot -or $normPath.StartsWith($normBaseRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
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

    if ($Operation -eq 'Reset') {
        if ($script:BaseWorkDir) {
            $normBase = [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\')
            if ($normPath -ieq $normBase) {
                throw "Safety guard: Refusing to reset base workspace directory itself: $normPath"
            }
        }
        try {
            $mounted = @(Get-Nano11MountedImages)
            foreach ($m in $mounted) {
                if ($m.Path) {
                    $mNorm = [System.IO.Path]::GetFullPath($m.Path).TrimEnd('\')
                    if ($normPath -ieq $mNorm -or $normPath.StartsWith($mNorm + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $mNorm.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
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
function Assert-Nano11DirectoryEmpty {
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
        $null = Enable-Nano11TokenPrivileges
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
            $repairErr = Repair-Nano11DeniedAcl -Path $current
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
    Assert-Nano11DirectorySafety -Path $Path -Operation 'RemoveOfflineContent'
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

# Helper function: Check if a path resides on an NTFS volume (DISM requirement for reparse points)
# Helper function: Fast and reliable directory reset using robocopy mirror trick (Guaranteed Empty)
function Reset-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [ValidateRange(1, 5)]
        [int]$Retries = 3
    )
    Assert-Nano11DirectorySafety -Path $Path -Operation 'Reset'
    $full = try { ConvertTo-Nano11NormalizedPath -Path $Path } catch { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }

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
    $lastRoboOutput = $null
    $lastAttribExit = $null

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        Assert-Nano11DirectorySafety -Path $full -Operation 'Reset'

        if ($attempt -gt 1) {
            # Terminate lingering dismhost/wimserv workers to release file locks, but only when no other
            # DISM activity is visible (our dism.exe calls are synchronous, so a running dism.exe is foreign)
            $foreignDismActive = $false
            if (Get-Process -Name "dism" -ErrorAction SilentlyContinue) {
                $foreignDismActive = $true
            } else {
                try {
                    $foreignMounts = @(Get-Nano11MountedImages | Where-Object {
                        $_.Path -and -not (
                            (Test-Nano11PathWithin -Path $_.Path -Root $script:BaseWorkDir) -or
                            (Test-Nano11PathWithin -Path $_.Path -Root $script:MountAllocationRoot)
                        )
                    })
                    if ($foreignMounts.Count -gt 0) { $foreignDismActive = $true }
                } catch {
                    $foreignDismActive = $true
                }
            }
            if ($foreignDismActive) {
                Write-Warning "Reset attempt ${attempt}: Other DISM activity detected outside the nano11 workspace. Not terminating dismhost/wimserv."
            } else {
                Get-Process -Name "dismhost", "wimserv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds ($attempt * 2)
        }

        $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Safety violation: Target directory '$full' is itself a reparse point. Refusing to reset directly."
        }

        # Queue-based reparse point pruning without following links into targets
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($full)
        $linkError = $false
        while ($queue.Count -gt 0) {
            $curr = $queue.Dequeue()
            try {
                $children = @(Get-ChildItem -LiteralPath $curr -Force -ErrorAction Stop)
            } catch {
                Write-Warning "Reset attempt ${attempt}: Could not enumerate '$curr': $_"
                $linkError = $true
                break
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
                        Write-Warning "Reset attempt ${attempt}: Failed to remove reparse point '$($child.FullName)': $_"
                        $linkError = $true
                    }
                } elseif ($child.PSIsContainer) {
                    $queue.Enqueue($child.FullName)
                }
            }
        }

        if (-not $linkError) {
            try {
                Set-ItemOwnershipAndAccess -Path $full -Recurse -Strict
            } catch {
                Write-Warning "Reset attempt ${attempt}: Ownership adjustment warning: $_"
            }

            # Strip ReadOnly, Hidden, and System attributes across root and children
            $null = & attrib.exe -r -s -h $full 2>&1
            $lastAttribExit = $LASTEXITCODE
            $childPattern = Join-Path -Path $full -ChildPath '*'
            $null = & attrib.exe -r -s -h $childPattern /s /d 2>&1

            $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_empty_$([System.IO.Path]::GetRandomFileName())"
            try {
                New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Assert-Nano11DirectoryEmpty -Path $emptyTemp
                $lastRoboOutput = & robocopy.exe $emptyTemp $full /MIR /XJ /R:0 /W:0 /NFL /NDL /NP /NJH /NJS 2>&1
                $lastRoboExit = $LASTEXITCODE
            } finally {
                if (Test-Path -LiteralPath $emptyTemp) {
                    Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            if ($lastRoboExit -ge 8) {
                Write-Warning "Reset attempt ${attempt}: Robocopy error (Exit code: $lastRoboExit): $lastRoboOutput"
            }

            # Sweep remaining items directly
            try {
                $lingering = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
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
            } catch {
                $lastEx = $_
            }
        }

        # Validate directory is strictly empty
        try {
            Assert-Nano11DirectoryEmpty -Path $full
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
    $remainingItems = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
    $remainingDetails = ($remainingItems | ForEach-Object { "$($_.FullName) [$($_.Attributes)]" }) -join "`n    "
    $hivesInfo = ""
    if ($script:ManagedMountDirs.Contains($full)) {
        try {
            $leftoverHives = @(Get-Nano11DismOfflineHives -TargetMountDir $full)
            if ($leftoverHives.Count -gt 0) {
                $hivesInfo = "`nLingering DISM offline registry hives:`n    " + (($leftoverHives | ForEach-Object { "$($_.KeyName) -> $($_.HivePath)" }) -join "`n    ")
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    throw "Reset-DirectoryWithRobocopy failed to empty directory '$full' after $Retries attempts.$hivesInfo`nRemaining items ($($remainingItems.Count)):`n    $remainingDetails`nLast error: $lastEx`nRobocopy Exit Code: $lastRoboExit`nAttrib Exit Code: $lastAttribExit`nPlease close any process locking these files or restart Windows before retrying."
}

# Helper function: Safe mountpoint cleanup guarded against modifying unmanaged external mounts
# ==============================================================================
# Helper Functions: Safe Deletion, Promotion, Metadata & Capacity Verification
function Invoke-Nano11PromoteTemporaryIso {
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
    $oldIsoBackup = Join-Path -Path $targetDir -ChildPath "nano11_old_backup_${BuildId}.iso"

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

function Test-Nano11MetadataAndCapacity {
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

    $targetFreeGB = Get-Nano11VolumeFreeSpaceGB -Path $VerifyApplyDir
    $applyDriveLetter = try { (Split-Path -Path ([System.IO.Path]::GetFullPath($VerifyApplyDir)) -Qualifier).TrimEnd(':') } catch { "C" }

    Write-Host "Capacity Analysis for Deep Apply Verification:" -ForegroundColor Cyan
    Write-Host "  - Uncompressed Expanded Image Size: $expandedSizeGB GB ($expandedSizeBytes bytes)" -ForegroundColor Gray
    Write-Host "  - Scratch & Working Overhead:       $scratchMarginGB GB" -ForegroundColor Gray
    Write-Host "  - Dynamic Required Space:           $requiredSpaceGB GB" -ForegroundColor Gray
    Write-Host "  - Apply Target Volume (${applyDriveLetter}:):     $targetFreeGB GB available" -ForegroundColor Gray

    if ($IsVhdx -and $VhdxFilePath -and (Test-Path -LiteralPath $VhdxFilePath)) {
        $vhdxHostFreeGB = Get-Nano11VolumeFreeSpaceGB -Path $VhdxFilePath
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
