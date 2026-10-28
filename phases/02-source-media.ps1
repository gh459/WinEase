# Phase 2: 02-source-media
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'destWim', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'hasSourceWim', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'hasSourceEsd', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
param()


# Determine source drive letter (with auto-detection)
$DriveLetter = ""
if ($SourceDrive) {
    # An explicit -SourceDrive is never replaced by auto-detection: resolve it or stop.
    $explicitMedia = Resolve-WinEaseExplicitSourceMedia -SourceDrive $SourceDrive
    $DriveLetter = $explicitMedia.DriveLetter
    if ($explicitMedia.MountedIso) {
        $script:MountedIso = $explicitMedia.MountedIso
        $script:MountedIsoByWinEase = $explicitMedia.MountedByWinEase
        if ($explicitMedia.MountedIso.ImagePath) {
            $script:DiagnosticData.SourceIsoPath = $explicitMedia.MountedIso.ImagePath
        }
        Write-Host "ISO mounted successfully on drive: $DriveLetter" -ForegroundColor Green
    } else {
        Write-Host "Using specified SourceDrive: $DriveLetter" -ForegroundColor Green
    }
}

# Helper: Scan for healthy Windows 11 ISO files on local storage and auto-mount if needed
function Find-AndMountHealthyWindowsIso {
    $searchPaths = @("E:\", "D:\", (Split-Path -Parent $PSScriptRoot), $env:USERPROFILE)
    $candidateIsos = @()
    foreach ($p in $searchPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $candidateIsos += Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 4GB -and ($_.Name -like "*26300*" -or $_.Name -like "*Win11*" -or $_.Name -like "*Windows11*") -and $_.Name -notlike "*WinEase*" }
    }
    # Sort: Prioritize 26300 (26H2) official ISO first, then by size
    $sortedIsos = $candidateIsos | Sort-Object { if ($_.Name -like "*26300*") { 0 } else { 1 } }, Length -Descending
    foreach ($iso in $sortedIsos) {
        try {
            $diskImg = Get-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue
            $script:MountedIsoByWinEase = (-not $diskImg -or -not $diskImg.Attached)
            if (-not $diskImg -or -not $diskImg.Attached) {
                Write-Host "Auto-mounting healthy Windows 11 ISO: $($iso.Name)..." -ForegroundColor Cyan
                $diskImg = Mount-DiskImage -ImagePath $iso.FullName -PassThru -ErrorAction SilentlyContinue
            }
            if ($diskImg) {
                $script:MountedIso = $diskImg
                $vol = $diskImg | Get-Volume -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter) {
                    $dl = "$($vol.DriveLetter):"
                    $wimCheck = Join-Path -Path "$dl\sources" -ChildPath "install.wim"
                    if ((Test-Path -LiteralPath $wimCheck) -and ((Get-Item -LiteralPath $wimCheck).Length -gt 1GB)) {
                        return $dl
                    }
                }
                # Dismount candidate if it does not contain a healthy install.wim
                if ($script:MountedIsoByWinEase) { [void](Dismount-WinEaseDiskImageVerified -ImagePath $iso.FullName -Label 'candidate ISO') }
                $script:MountedIso = $null
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    return $null
}

if (-not $DriveLetter) {
    # Scan all filesystem drives for sources\install.wim or sources\install.esd
    $detectedMediaDrives = @()
    foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $psd.Root) { continue }
        $rootClean = $psd.Root.TrimEnd('\')
        $wimP = Join-Path -Path "$rootClean\sources" -ChildPath "install.wim"
        $esdP = Join-Path -Path "$rootClean\sources" -ChildPath "install.esd"
        $hasWimP = (Test-Path -LiteralPath $wimP) -and ((Get-Item -LiteralPath $wimP).Length -gt 1GB)
        $hasEsdP = (Test-Path -LiteralPath $esdP) -and ((Get-Item -LiteralPath $esdP).Length -gt 1GB)
        if ($hasWimP) {
            $detectedMediaDrives += $psd
        } elseif ($hasEsdP) {
            $detectedMediaDrives += $psd
            Write-Host "  [i] Notice: Drive $rootClean contains 'install.esd'. It will be converted to install.wim via DISM." -ForegroundColor Cyan
        }
    }

    # If no healthy install.wim drive is mounted, check if a healthy official ISO can be auto-mounted
    $hasHealthyWimMounted = $detectedMediaDrives | Where-Object {
        $r = $_.Root.TrimEnd('\')
        Test-Path -LiteralPath "$r\sources\install.wim"
    }
    if (-not $hasHealthyWimMounted) {
        $mountedDriveLetter = Find-AndMountHealthyWindowsIso
        if ($mountedDriveLetter) {
            $mountedClean = $mountedDriveLetter.TrimEnd(':')
            $newPsd = Get-PSDrive -Name $mountedClean -PSProvider FileSystem -ErrorAction SilentlyContinue
            if ($newPsd -and ($detectedMediaDrives.Root -notcontains $newPsd.Root)) {
                $detectedMediaDrives += $newPsd
            }
        }
    }

    # Prioritize install.wim media over install.esd, and prioritize newer/larger 26H2 Build 26300 media
    $detectedMediaDrives = @($detectedMediaDrives | Sort-Object {
        $rootClean = $_.Root.TrimEnd('\')
        $wimFile = Join-Path -Path "$rootClean\sources" -ChildPath "install.wim"
        if (Test-Path -LiteralPath $wimFile) {
            # Negative length so larger (26H2 Build 26300 @ 8.01 GB) sorts before smaller media
            return -1 * ((Get-Item -LiteralPath $wimFile).Length)
        } else {
            return [long]::MaxValue
        }
    })

    if ($NonInteractive -and $detectedMediaDrives.Count -gt 0) {
        $DriveLetter = $detectedMediaDrives[0].Root.TrimEnd('\')
        Write-Host "Auto-detected Windows installation media on: $DriveLetter" -ForegroundColor Green
    } elseif ($detectedMediaDrives.Count -eq 1) {
        $cand = $detectedMediaDrives[0].Root.TrimEnd('\')
        $vol = Get-Volume -DriveLetter ($cand.TrimEnd(':')) -ErrorAction SilentlyContinue
        $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
        $wimP = Join-Path -Path "$cand\sources" -ChildPath "install.wim"
        $esdP = Join-Path -Path "$cand\sources" -ChildPath "install.esd"
        $typeDesc = if (Test-Path -LiteralPath $wimP) {
            "install.wim ($([math]::Round((Get-Item -LiteralPath $wimP).Length / 1GB, 2)) GB) [Recommended - Direct LZX, 100% Stable]"
        } elseif (Test-Path -LiteralPath $esdP) {
            "install.esd ($([math]::Round((Get-Item -LiteralPath $esdP).Length / 1GB, 2)) GB) [Requires ESD Decompression]"
        } else { "" }
        Write-Host "Auto-detected Windows 11 installation media on drive $cand$volLabel ($typeDesc)" -ForegroundColor Green
        $inputDrive = Read-Host "Use drive $cand? [Y/n, or enter another drive letter] (Default: Y)"
        if (-not $inputDrive -or ($inputDrive.Trim().ToLower() -in @('y', 'yes'))) {
            $DriveLetter = $cand
        } else {
            $candInput = $inputDrive.Trim().TrimEnd(':') + ":"
            if (Test-Path -LiteralPath $candInput) {
                $DriveLetter = $candInput
            }
        }
    } elseif ($detectedMediaDrives.Count -gt 1) {
        Write-Host "Multiple Windows installation media drives detected:" -ForegroundColor Green
        for ($i = 0; $i -lt $detectedMediaDrives.Count; $i++) {
            $d = $detectedMediaDrives[$i].Root.TrimEnd('\')
            $vol = Get-Volume -DriveLetter ($d.TrimEnd(':')) -ErrorAction SilentlyContinue
            $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
            $wimP = Join-Path -Path "$d\sources" -ChildPath "install.wim"
            $esdP = Join-Path -Path "$d\sources" -ChildPath "install.esd"
            $typeDesc = if (Test-Path -LiteralPath $wimP) {
                "install.wim ($([math]::Round((Get-Item -LiteralPath $wimP).Length / 1GB, 2)) GB) [Recommended - Windows 11 26H2 Official, 100% Stable]"
            } elseif (Test-Path -LiteralPath $esdP) {
                "install.esd ($([math]::Round((Get-Item -LiteralPath $esdP).Length / 1GB, 2)) GB) [Warning: Potential Error 1392 in ESD stream]"
            } else { "" }
            Write-Host "  [$($i+1)] Drive $d$volLabel - $typeDesc"
        }
        $sel = Read-Host "Select a drive number [1-$($detectedMediaDrives.Count)] or enter a drive letter (Default: 1)"
        if (-not $sel -or $sel.Trim() -eq '1') {
            $DriveLetter = $detectedMediaDrives[0].Root.TrimEnd('\')
        } elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $detectedMediaDrives.Count) {
            $DriveLetter = $detectedMediaDrives[[int]$sel - 1].Root.TrimEnd('\')
        } else {
            $candInput = $sel.Trim().TrimEnd(':') + ":"
            if (Test-Path -LiteralPath $candInput) {
                $DriveLetter = $candInput
            }
        }
    }

    if (-not $DriveLetter) {
        if ($NonInteractive) {
            throw "No Windows 11 installation media detected. In -NonInteractive mode, please specify a valid media drive or ISO path via -SourceDrive."
        }
        while (-not $DriveLetter) {
            $inputDrive = Read-Host "Please enter the drive letter for the Windows 11 installation media (e.g. D or D:)"
            if ($inputDrive) {
                $candDrive = $inputDrive.Trim().TrimEnd(':') + ":"
                if (Test-Path -LiteralPath $candDrive) {
                    $DriveLetter = $candDrive
                } else {
                    Write-Host "Drive $candDrive does not exist. Please check and re-enter." -ForegroundColor Red
                }
            }
        }
    }
}

# Check for install.wim or install.esd
$sourceWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.wim"
$sourceEsd = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.esd"
$destWim = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.wim"

$hasSourceWim = (Test-Path -LiteralPath $sourceWim) -and ((Get-Item -LiteralPath $sourceWim).Length -gt 1GB)
$hasSourceEsd = (Test-Path -LiteralPath $sourceEsd) -and ((Get-Item -LiteralPath $sourceEsd).Length -gt 1GB)

# Ensure destination sources directory exists prior to file operations
$destSourcesDir = Join-Path -Path $WinEaseDir -ChildPath "sources"
New-Item -ItemType Directory -Force -Path $destSourcesDir | Out-Null

# Note: there is no media cache. Phase 1 always empties the build directory, and a previous build's
# install.wim is already debloated/exported, so reusing it would process an image twice.
