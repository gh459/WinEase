# Phase 1: 01-environment
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


    # DISM Binary Discovery & Architecture Verification
    $dismCmd = Get-Command "dism.exe" -ErrorAction SilentlyContinue
    $dismPath = if ($dismCmd) { $dismCmd.Source } else { Join-Path -Path $env:SystemRoot -ChildPath "System32\dism.exe" }
    $adkCandidates = @(
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe",
        "C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe"
    )
    foreach ($cand in $adkCandidates) {
        if (Test-Path -LiteralPath $cand) {
            $dismPath = $cand
            break
        }
    }
    $dismVerInfo = (Get-Item -LiteralPath $dismPath -ErrorAction SilentlyContinue).VersionInfo
    $dismVerStr = if ($dismVerInfo) { $dismVerInfo.FileVersion } else { "Unknown" }
    $hostBuildNum = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction SilentlyContinue).CurrentBuildNumber

    if ($script:DiagnosticData) {
        $script:DiagnosticData.DismPath = $dismPath
        $script:DiagnosticData.DismVersion = $dismVerStr
    }
    Write-Host "DISM Utility Diagnostics:" -ForegroundColor Cyan
    Write-Host "  - Path:    $dismPath" -ForegroundColor Green
    Write-Host "  - Version: $dismVerStr" -ForegroundColor Green
    if ($hostBuildNum -eq '26300' -and $dismVerStr -match '^10\.0\.26100') {
        Write-Host "  - Status:  Host is Windows 11 26H2 (Build 26300 Enablement Package)." -ForegroundColor DarkCyan
        Write-Host "             Core servicing stack & DISM share the Germanium (26100) branch." -ForegroundColor DarkCyan
        Write-Host "             DISM $dismVerStr is the official matching native servicing engine." -ForegroundColor DarkCyan
    }

    # Determine Working Directory (Defaults to user's Documents folder: Documents\WinEase_workspace)
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir)) {
            New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
        }
        $baseWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
        if (-not (Test-IsNtfsVolume -Path $baseWorkDir)) {
            Write-Host "Warning: Specified WorkDir '$baseWorkDir' is not on an NTFS volume. DISM requires NTFS for junction and reparse points." -ForegroundColor Yellow
            $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
            if ($altDrive) {
                $baseWorkDir = Join-Path -Path $altDrive.Root.TrimEnd('\') -ChildPath "WinEase_workspace"
                Write-Host "Redirecting workspace to NTFS drive: $baseWorkDir" -ForegroundColor Green
                New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
            }
        }
    } else {
        $docsDir = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDir) { $docsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Documents" }
        $defaultWorkDir = if ($docsDir) { Join-Path -Path $docsDir -ChildPath "WinEase_workspace" } else { Join-Path -Path $env:SystemDrive -ChildPath "WinEase_workspace" }
        $baseWorkDir = $defaultWorkDir
        if (-not (Test-Path -LiteralPath $baseWorkDir)) {
            New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
        }
        if (-not (Test-IsNtfsVolume -Path $baseWorkDir)) {
            Write-Host "Warning: Documents directory '$baseWorkDir' is not on an NTFS volume." -ForegroundColor Yellow
            $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
            if ($altDrive) {
                $baseWorkDir = Join-Path -Path $altDrive.Root.TrimEnd('\') -ChildPath "WinEase_workspace"
                Write-Host "Redirecting workspace to NTFS drive: $baseWorkDir" -ForegroundColor Green
                New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
            }
        }
    }

    # Verify available disk space on workspace volume (Minimum 25 GB required)
    $workDriveLetter = [System.IO.Path]::GetPathRoot($baseWorkDir).TrimEnd('\')
    if ($workDriveLetter -match '^[a-zA-Z]:') {
        $psDriveObj = Get-PSDrive -Name $workDriveLetter.Substring(0, 1) -ErrorAction SilentlyContinue
        if ($psDriveObj) {
            $freeGB = [math]::Round($psDriveObj.Free / 1GB, 1)
            if ($freeGB -lt 25.0) {
                Write-Host "Warning: Low disk space on workspace drive $workDriveLetter ($freeGB GB free, 25 GB recommended)." -ForegroundColor Yellow
                $altNtfs = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
                if ($altNtfs) {
                    $baseWorkDir = Join-Path -Path $altNtfs.Root.TrimEnd('\') -ChildPath "WinEase_workspace"
                    Write-Host "Redirected workspace to volume with sufficient space ($([math]::Round($altNtfs.Free / 1GB, 1)) GB free): $baseWorkDir" -ForegroundColor Green
                    New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
                }
            }
        }
    }

    $WorkDir = $baseWorkDir
    $script:BaseWorkDir = $baseWorkDir
    $WinEaseDir = Join-Path -Path $baseWorkDir -ChildPath "build"
    $vhdxMountDir = Join-Path -Path $baseWorkDir -ChildPath "scratchdir"
    $scratchDir = if ($UseVHDX) { Join-Path -Path $vhdxMountDir -ChildPath "mount" } else { $vhdxMountDir }
    $script:BaseWorkDir = $baseWorkDir
    $script:VhdxMountDir = $vhdxMountDir
    $script:DismMountDir = $scratchDir
    [void]$script:ManagedMountDirs.Add(
        (ConvertTo-WinEaseNormalizedPath -Path $scratchDir)
    )
    [void]$script:ManagedMountDirs.Add(
        (ConvertTo-WinEaseNormalizedPath -Path $vhdxMountDir)
    )
    $vhdxPath = Join-Path -Path $baseWorkDir -ChildPath "WinEase_scratch.vhdx"
    $isVhdxMounted = $false
    Write-Host "Working Directory: $baseWorkDir" -ForegroundColor Cyan

    # A3: Host environment stability diagnostics (root-cause aid for WIM 577 / hash-jitter builds)
    Invoke-WinEaseHostHealthCheck -WorkspaceDir $baseWorkDir

    # Temporarily exclude workspace from Windows Defender real-time scanning to accelerate DISM operations
    try {
        Add-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
        $script:DefenderExclusionAdded = $true
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    # 1. Resolve any lingering DISM mounts associated with our workspace or candidate WIMs
    $managedWims = @(
        (Join-Path -Path $WinEaseDir -ChildPath "sources\install.wim"),
        (Join-Path -Path $WinEaseDir -ChildPath "sources\boot.wim")
    )
    Clear-DismMountConflicts -TargetMountDir $scratchDir
    if ($vhdxMountDir -ne $scratchDir) {
        Clear-DismMountConflicts -TargetMountDir $vhdxMountDir
    }
    foreach ($wim in $managedWims) {
        Clear-DismMountConflicts -TargetWimFile $wim
    }

    # 2. Detach any leftover VHDX from previous runs
    if (Test-Path -LiteralPath $vhdxPath) {
        try {
            $dpDetachScript = "select vdisk file=`"$vhdxPath`"`r`ndetach vdisk`r`n"
            $dpDetachFile = Join-Path -Path $env:TEMP -ChildPath "WinEase_dp_clean_$([System.IO.Path]::GetRandomFileName()).txt"
            $dpDetachScript | Set-Content -LiteralPath $dpDetachFile -Encoding ascii
            & diskpart.exe /s $dpDetachFile > $null 2>&1
            Remove-Item -LiteralPath $dpDetachFile -Force -ErrorAction SilentlyContinue

            $detachedOk = $true
            try {
                $diskImg = Get-DiskImage -ImagePath $vhdxPath -ErrorAction Stop
                if ($diskImg.Attached) { $detachedOk = $false }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

            if ($detachedOk) {
                Remove-Item -LiteralPath $vhdxPath -Force -ErrorAction SilentlyContinue
            } else {
                Write-Warning "Could not confirm VHDX detach for '$vhdxPath'. Preserving file."
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    # 3. Safely reset build directory and scratch directory (Empty guaranteed)
    if (Test-Path -LiteralPath $WinEaseDir) {
        Write-Host "Cleaning up previous build directory..." -ForegroundColor Yellow
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        try {
            Reset-DirectoryWithRobocopy -Path $WinEaseDir
        } catch {
            Write-Warning "Reset of build directory encountered locked files: $($_.Exception.Message)"
            Write-Host "Triggering forced DISM recovery for managed WIM files..." -ForegroundColor Yellow
            foreach ($wim in $managedWims) {
                Clear-DismMountConflicts -TargetWimFile $wim -ForceRecovery
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 1
            Reset-DirectoryWithRobocopy -Path $WinEaseDir
        }
    }
    if (Test-Path -LiteralPath $vhdxMountDir) {
        Write-Host "Cleaning up previous scratch directory..." -ForegroundColor Yellow
        $vhdxDirItem = Get-Item -LiteralPath $vhdxMountDir -Force -ErrorAction SilentlyContinue
        if ($vhdxDirItem -and ($vhdxDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Host "Releasing previous VHDX mount point junction at '$vhdxMountDir'..." -ForegroundColor Cyan
            try { & mountvol.exe "$vhdxMountDir" /D > $null 2>&1 } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            try {
                [System.IO.Directory]::Delete($vhdxMountDir, $false)
            } catch {
                try { $vhdxDirItem.Delete() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }
        if (Test-Path -LiteralPath $vhdxMountDir) {
            Reset-DirectoryWithRobocopy -Path $vhdxMountDir
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path -Path $WinEaseDir -ChildPath "sources") | Out-Null
    if (-not (Test-Path -LiteralPath $vhdxMountDir)) {
        New-Item -ItemType Directory -Force -Path $vhdxMountDir | Out-Null
    }

    # Initialize High-Speed Dynamic VHDX scratch disk if requested (-UseVHDX / -FastVHDX)
    if ($UseVHDX) {
        Write-Host "Creating high-speed dynamic VHDX scratch disk (30 GB expandable)..." -ForegroundColor Cyan
        try {
            $dpAttachScript = @"
create vdisk file="$vhdxPath" maximum=30720 type=expandable
select vdisk file="$vhdxPath"
attach vdisk
clean
convert gpt
create partition primary
format fs=ntfs quick label="WinEase_scratch"
assign mount="$vhdxMountDir"
"@
            $dpAttachFile = Join-Path -Path $env:TEMP -ChildPath "WinEase_dp_attach_$([System.IO.Path]::GetRandomFileName()).txt"
            $dpAttachScript | Set-Content -LiteralPath $dpAttachFile -Encoding ascii
            & diskpart.exe /s $dpAttachFile > $null 2>&1
            Remove-Item -LiteralPath $dpAttachFile -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $vhdxPath) {
                $isVhdxMounted = $true
                $script:IsVhdxMounted = $true
                # Create isolated child directory inside VHDX volume exclusively for DISM mounting
                New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
                Write-Host "VHDX scratch volume mounted to $vhdxMountDir (DISM mount dir: $scratchDir)" -ForegroundColor Green
            } else {
                Write-Warning "VHDX initialization did not create $vhdxPath. Using standard physical directory."
                $scratchDir = $vhdxMountDir
                $script:DismMountDir = $scratchDir
            }
        } catch {
            Write-Warning "Could not mount VHDX scratch disk: $_. Using standard physical directory."
            $scratchDir = $vhdxMountDir
            $script:DismMountDir = $scratchDir
        }
    } else {
        New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    }

    if ($script:IsVhdxMounted) {
        $script:MountAllocationRoot = $vhdxMountDir
        $script:MountDirectoryPrefix = 'mount_'
    } else {
        $script:MountAllocationRoot = $baseWorkDir
        $script:MountDirectoryPrefix = 'scratchdir_'
    }
