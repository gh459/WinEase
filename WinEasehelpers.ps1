# WinEasehelpers.ps1 - Pure utility helpers extracted from WinEasebuilder.ps1 (F8)
# Dot-sourced by WinEasebuilder.ps1. Functions use $script: scope of the caller.
# Keep this file next to WinEasebuilder.ps1.

function ConvertTo-WinEaseNormalizedPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be null or empty."
    }
    $cleanPath = $Path.Replace('/', '\')
    if ($cleanPath -notmatch '^[A-Za-z]:\\') {
        throw "Path must be an absolute local drive path starting with a drive letter: '$Path'"
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($cleanPath).TrimEnd('\')
    } catch {
        throw "Failed to get full path for '$Path': $_"
    }
    if ($fullPath -match '^[A-Za-z]:$') {
        throw "Drive root path is not allowed as a managed path: '$Path'"
    }
    return $fullPath
}

# Helper function: True if Path equals Root or is a descendant of it.
# Compares on a '\' boundary after canonicalizing both paths via GetFullPath.
function Test-WinEasePathWithin {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    try {
        $cleanP = $Path.Replace('/', '\')
        $cleanR = $Root.Replace('/', '\')
        $p = [System.IO.Path]::GetFullPath($cleanP).TrimEnd('\', '/')
        $r = [System.IO.Path]::GetFullPath($cleanR).TrimEnd('\', '/')
    } catch {
        return $false
    }
    if ($p -ieq $r) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}


function Test-IsNtfsVolume {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { return $false }
        try {
            $drive = New-Object System.IO.DriveInfo($root)
            if ($drive.IsReady) {
                return ($drive.DriveFormat -ieq 'NTFS')
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        if ($root -match '^[a-zA-Z]:') {
            $letter = $root.Substring(0, 1)
            $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
            return ($vol.FileSystem -ieq 'NTFS')
        }
        return $false
    } catch {
        return $false
    }
}


function Test-IsSafePathToDelete {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        # 1. Drive roots (C:, D:\, etc.)
        if ($full.Length -le 3 -or $full -match '^[A-Za-z]:$') { return $false }

        # 2. Reject UNC roots (\\server\share)
        if ($full -match '^\\\\[^\\]+\\[^\\]+$') { return $false }

        # 3. User profile and users root
        $systemProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ($systemProfile) {
            $normUser = [System.IO.Path]::GetFullPath($systemProfile).TrimEnd('\', '/')
            if ($full -ieq $normUser -or $normUser.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
        if ($env:SystemDrive) {
            $hostUsers = [System.IO.Path]::GetFullPath("$($env:SystemDrive)\Users").TrimEnd('\', '/')
            if ($full -ieq $hostUsers -or $hostUsers.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }

        # 4. Critical OS and program files directories
        $protectedRoots = @(
            [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows),
            [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles),
            [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonProgramFiles),
            [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
        )
        if (${env:ProgramFiles(x86)}) {
            $protectedRoots += ${env:ProgramFiles(x86)}
        }
        foreach ($pr in $protectedRoots) {
            if ([string]::IsNullOrWhiteSpace($pr)) { continue }
            $normPr = [System.IO.Path]::GetFullPath($pr).TrimEnd('\', '/')
            if ($full -ieq $normPr -or $full.StartsWith($normPr + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normPr.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }

        # 5. Repository script directory itself, any subfolder inside it, or any ancestor of it
        $refScriptDir = if ($scriptDir) { $scriptDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { $null }
        if ($refScriptDir) {
            $normScript = [System.IO.Path]::GetFullPath($refScriptDir).TrimEnd('\', '/')
            if ($full -ieq $normScript -or $full.StartsWith($normScript + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normScript.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }

        return $true
    } catch {
        return $false
    }
}

function New-WinEaseBuildId {
    param([datetime]$Timestamp = (Get-Date))
    $timePart = $Timestamp.ToString('yyyyMMdd_HHmmss')
    $guidPart = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "${timePart}_${guidPart}"
}


# ==============================================================================
# Helper function: Standardized DISM wrapper with retries and exit code diagnostics
function Invoke-Dism {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$DismArgs,
        [int]$Retries = 1,
        [string]$ActivityDescription = "",
        [switch]$CaptureOutput,
        [switch]$Quiet
    )
    if ($ActivityDescription) {
        Write-Host "  -> DISM: $ActivityDescription..." -ForegroundColor Cyan
    }
    $fullArgs = @('/English')
    if ($script:DismLogPath) {
        $fullArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
    }
    $fullArgs += $DismArgs

    $maxAttempts = [math]::Max(1, $Retries)
    for ($i = 1; $i -le $maxAttempts; $i++) {
        $output = $null
        if ($CaptureOutput) {
            $output = & dism.exe @fullArgs 2>&1
        } else {
            if ($Quiet) {
                & dism.exe @fullArgs > $null 2>&1
            } else {
                & dism.exe @fullArgs
            }
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        $script:LastDismExitCode = $exitCode

        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            if ($CaptureOutput) {
                return $output
            }
            return $true
        }

        $exitHex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$exitCode), 0))
        if ($i -lt $maxAttempts) {
            Write-Host "DISM command failed (Exit code: $exitCode / $exitHex). Retrying ($i/$maxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        } else {
            Write-Warning "DISM command failed (Final attempt $i/$maxAttempts, Exit code: $exitCode / $exitHex)."
        }
    }
    if ($CaptureOutput) { return $null }
    return $false
}


# ==============================================================================
# Helper function: Safely unmount offline registry hive with retry and garbage collection
function Unmount-RegistryHiveWithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [int]$Retries = 5
    )
    for ($i = 0; $i -le $Retries; $i++) {
        & reg.exe query "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $true
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 300
        & reg.exe unload "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

# 4. Language-independent Administrators group via Well-Known SID (S-1-5-32-544)

# Helper function: Query registered mounted images from DISM
# Helper function: Query registered mounted images from DISM (Distinguishes 0-mount success from query failure)

# ==============================================================================
# ==============================================================================
function Get-WinEaseVolumeFreeSpaceGB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be null or empty when querying volume free space."
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if (-not $root) {
            throw "Failed to extract path root from '$Path'."
        }
        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) {
            throw "Drive '$root' is not ready or volume is unavailable."
        }
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    } catch {
        throw "Failed to query volume free space for '$Path': $_"
    }
}


# ==============================================================================
function Test-CanSafelyDeleteDirectory {
    param(
        [string]$Path,
        [string]$ExpectedBaseDir,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if (-not $script:BuildSucceeded) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-IsSafePathToDelete -Path $Path)) { return $false }

    $normPath = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-WinEaseNormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        # Prohibit deleting the workspace root itself
        if ($normPath -ieq $normBase) {
            Write-Warning "Directory '$normPath' is the workspace root itself. Deletion prohibited."
            return $false
        }
        if (-not (Test-WinEasePathWithin -Path $normPath -Root $normBase)) {
            Write-Warning "Directory '$normPath' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normPDir = try { ConvertTo-WinEaseNormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
            if ($normPath -ieq $normPDir) {
                Write-Warning "Directory '$normPath' is in PreservedMountDirs. Deletion prohibited."
                return $false
            }
            if ($normPDir.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Directory '$normPath' is a parent of preserved directory '$normPDir'. Deletion prohibited."
                return $false
            }
            if ($normPath.StartsWith($normPDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Directory '$normPath' is a descendant of preserved directory '$normPDir'. Deletion prohibited."
                return $false
            }
        }
    }

    try {
        $activeMounts = @(Get-WinEaseMountedImages)
        $lingering = $activeMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and (($p -ieq $normPath) -or $p.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normPath.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase))
        }
        if ($lingering) {
            Write-Warning "Active DISM mount detected on or under '$normPath'. Deletion prohibited."
            return $false
        }
    } catch {
        Write-Warning "Could not confirm DISM mount status on '$normPath': $_. Deletion prohibited."
        return $false
    }

    foreach ($hive in @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')) {
        try {
            $hiveKey = "HKLM:\$hive"
            if (Test-Path -LiteralPath $hiveKey -ErrorAction Stop) {
                Write-Warning "Offline registry hive '$hive' still loaded. Deletion prohibited."
                return $false
            }
        } catch {
            Write-Warning "Could not confirm offline registry hive '$hive' status: $_. Deletion prohibited."
            return $false
        }
    }

    return $true
}


# ==============================================================================
function Test-CanSafelyDeleteVhdx {
    param(
        [string]$VhdxPath,
        [bool]$VhdxDetached,
        [string]$ExpectedBaseDir,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if (-not $script:BuildSucceeded) { return $false }
    if (-not $VhdxDetached) { return $false }
    if ([string]::IsNullOrWhiteSpace($VhdxPath) -or -not (Test-Path -LiteralPath $VhdxPath)) { return $false }
    if (-not (Test-IsSafePathToDelete -Path $VhdxPath)) { return $false }

    $normVhdx = try { ConvertTo-WinEaseNormalizedPath -Path $VhdxPath } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-WinEaseNormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-WinEasePathWithin -Path $normVhdx -Root $normBase)) {
            Write-Warning "VHDX '$normVhdx' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normP = try { ConvertTo-WinEaseNormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
            if ($normVhdx -ieq $normP -or $normVhdx.StartsWith($normP + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "VHDX '$normVhdx' is in or under PreservedMountDirs '$normP'. Deletion prohibited."
                return $false
            }
        }
    }

    return $true
}


# ==============================================================================
# Helper function: Verify oscdimg.exe Authenticode signature or pinned SHA256 hashes
function Test-OscdimgIntegrity {
    param([string]$OscdimgPath)
    if (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath)) { return $false }

    # 1. Check Authenticode Signature (Official Microsoft Windows ADK binary)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $OscdimgPath -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid' -and ($sig.SignerCertificate.Subject -match 'Microsoft')) {
            return $true
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    # 2. Known Official & Pinned SHA256 Hashes
    $knownHashes = @(
        'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD', # Bundled repo version (2.56)
        '8DC3FB38E75C42127BE0A29D64CA6D79DFDDFDCBEE4A3BA8B36CFEBDCC1689E2', # Windows 11 ADK x64
        'CE53D1C8C08FF54B4B91D2DFDE80F9D86427BC8C78FA6BBDE278456CDD2E2B85', # Windows 11 ADK x86
        'B27E36C95A7490A175B5F17781C5C7A7C0B0C4670ACBF5B0BA0E0556BCDE0F46'  # Windows 11 ADK ARM64
    )
    try {
        $fileHash = (Get-FileHash -LiteralPath $OscdimgPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($fileHash -and ($knownHashes -contains $fileHash.ToUpperInvariant())) {
            return $true
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    return $false
}


# ==============================================================================
# Helper function: Convert file/folder path to 8.3 short path if containing spaces, preventing parser issues with oscdimg -bootdata
function Get-SafeShortPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    if ($Path -notmatch '\s') { return $Path }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $short = $fso.GetFile($Path).ShortPath
            if ($short) { return $short }
        } elseif (Test-Path -LiteralPath $Path -PathType Container) {
            $short = $fso.GetFolder($Path).ShortPath
            if ($short) { return $short }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $Path
}

# ---------------------------------------------------------------------------------------------
# WIM stream integrity helpers (Phase 15 self-healing)
# DISM /Apply-Image /Verify fails with 577 (0x80070241 ERROR_INVALID_IMAGE_HASH) or 0x80070570 when a
# decompressed file does not match the SHA-1 recorded in the WIM. Two very different causes produce the
# same error code:
#   1. Persistent corruption: a stream was damaged while /Unmount-Image /commit hashed/compressed it.
#      The bad stream is then copied verbatim by /Export-Image (which still reports success).
#   2. Transient corruption: the WIM is intact, but data was damaged in RAM while DISM decompressed it
#      (unstable memory/CPU). The failing file changes on every run.
# The helpers below extract the failing files directly via wimgapi.dll, classify them, and repair
# persistent corruption from a known-good reference image (source media / untouched editions).
# ---------------------------------------------------------------------------------------------


# ============================================================================
# BuildContext class - aggregates all build state into a single object (C1)
# Foundation for dependency injection. Phases can optionally accept a BuildContext
# instead of relying on global $script: variables.
# ============================================================================

class BuildContext {
    # --- Workspace & paths ---
    [string]$BaseWorkDir
    [string]$WinEaseDir
    [string]$ScratchDir
    [string]$VhdxMountDir
    [string]$VhdxPath
    [string]$DriveLetter
    [string]$WorkDir
    # --- Image metadata ---
    [int]$Index
    [string]$TargetEditionName
    [string]$Architecture
    [string]$LanguageCode
    # --- Build identity ---
    [string]$BuildId
    [string]$DiagDir
    [hashtable]$DiagnosticData
    [int]$CurrentPhase
    [hashtable]$PhaseTimings
    [System.Diagnostics.Stopwatch]$PhaseStopwatch
    # --- Build state ---
    [bool]$BuildSucceeded
    [bool]$FinalPayloadVerified
    [string]$VerifiedFinalWimSha256
    [bool]$IsoPayloadVerified
    [bool]$StreamIntegrityVerified
    [string]$StreamIntegrityMethod
    [int]$RemovedPackagesCount
    [int]$WinSxSSavedMB
    [int]$WinSxsBeforeMB
    [int]$WinSxsAfterMB
    [string]$DismLogPath
    [bool]$DefenderExclusionAdded
    [bool]$HivesLoaded
    [bool]$MountOpened
    [string]$DismMountDir
    [System.Collections.Generic.HashSet[string]]$ManagedMountDirs
    [System.Collections.Generic.HashSet[string]]$AllocatedMountDirs
    [System.Collections.Generic.HashSet[string]]$PreservedMountDirs
    [bool]$IsoCreatedSuccessfully
    [bool]$IsoPayloadMatch
    [bool]$ExportSucceeded
    [bool]$IsoGenerated
    # --- Configuration ---
    [string]$SelectedProfile
    [bool]$RemoveDefender
    [bool]$KeepAsianIME
    [bool]$KeepExtraFonts
    [bool]$RemoveDrivers
    [bool]$DisableWU
    [bool]$KeepBT
    [bool]$WslSupport
    [bool]$KeepRecoveryEnv
    [bool]$SafeDebloatMode
    [bool]$UltraSlimMode
    [bool]$SetJapaneseKeyboard
    [bool]$AtlasReviOSMode
    [bool]$ExportESDMode
    [bool]$SplitWIMMode
    [bool]$RemoveStore
    [bool]$KeepBasicApps
    [bool]$KeepSearchIndex
    [bool]$KeepXboxServices
    [bool]$KeepAudioTweaks
    [bool]$UseVHDX
    [bool]$RemoveLegacyFOD
    [bool]$TrimWallpapers
    [string]$HibernateMode
    [string]$CrashDumpMode
    [bool]$DisableCPUMitigations
    [bool]$MmcssGaming
    [bool]$DawMode
    [bool]$DisableMemCompression
    [bool]$DisableFSE
    [bool]$NvidiaLowLatency
    [bool]$NoKernelPaging
    [bool]$DisableUSBSuspend
    [bool]$NoHypervisor
    [bool]$RemoveWebViewPostOOBE
    [bool]$FastExport
    [bool]$UefiOnly
    [string]$CpuBoostMode
    [string]$PowerPreset
    [bool]$BypassActivationRestrictions
    [bool]$RadicalRAM
    [bool]$AllowPhysicalDebloat
    [bool]$AdvancedDebloatStandard
    [bool]$AdvancedDebloatExperimental
    [hashtable]$ActiveTweakGroups
    [hashtable]$TweakSettings
    [string]$PayloadFormat
    [string]$ComputerName
    [string]$UserName
    [string]$SourceWimSize
    [string]$ActivePayloadPath
    [string]$ActivePayloadName
    # --- Mutable state ---
    [string]$DismPath
    [string]$DismVerStr
    [string]$HostBuildNum
    [string]$IsoFileName
    [string]$OutputIso
    [string]$IsoSha256
    [int]$IsoSizeMB
    [string]$TempOutputIso
    [string]$ExpectedPayloadFile
    [string]$ProfSlug
    [string]$BootWimPath

    BuildContext() {
        $this.ManagedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.AllocatedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.PreservedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.PhaseTimings = [ordered]@{}
        $this.ActiveTweakGroups = [ordered]@{}
        $this.DiagnosticData = [ordered]@{}
        $this.TweakSettings = [ordered]@{}
        $this.CurrentPhase = 0
        $this.BuildSucceeded = $false
        $this.FinalPayloadVerified = $false
        $this.IsoPayloadVerified = $false
        $this.StreamIntegrityVerified = $false
        $this.StreamIntegrityMethod = "NOT VERIFIED"
        $this.DefenderExclusionAdded = $false
        $this.HivesLoaded = $false
        $this.MountOpened = $false
        $this.IsoCreatedSuccessfully = $false
        $this.IsoPayloadMatch = $false
        $this.ExportSucceeded = $false
        $this.IsoGenerated = $false
        $this.AllowPhysicalDebloat = $false
        $this.AdvancedDebloatStandard = $false
        $this.AdvancedDebloatExperimental = $false
        $this.RemovedPackagesCount = 0
        $this.WinSxSSavedMB = 0
        $this.WinSxsBeforeMB = 0
        $this.WinSxsAfterMB = 0
        $this.PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

# Helper: create BuildContext from resolved script-scope variables (bridge for incremental migration)
function New-BuildContextFromScriptScope {
    $ctx = [BuildContext]::new()
    $ctx.BaseWorkDir = $script:BaseWorkDir
    $ctx.WinEaseDir = $WinEaseDir
    $ctx.ScratchDir = $scratchDir
    $ctx.VhdxMountDir = $vhdxMountDir
    $ctx.VhdxPath = $vhdxPath
    $ctx.DriveLetter = $DriveLetter
    $ctx.WorkDir = $WorkDir
    $ctx.Index = $index
    $ctx.TargetEditionName = $targetEditionName
    $ctx.Architecture = $architecture
    $ctx.LanguageCode = $languageCode
    $ctx.BuildId = $script:BuildId
    $ctx.DiagDir = $script:DiagDir
    $ctx.DiagnosticData = $script:DiagnosticData
    $ctx.CurrentPhase = $script:CurrentPhase
    $ctx.PhaseTimings = $script:PhaseTimings
    $ctx.PhaseStopwatch = $script:PhaseStopwatch
    $ctx.BuildSucceeded = $script:BuildSucceeded
    $ctx.FinalPayloadVerified = $script:FinalPayloadVerified
    $ctx.VerifiedFinalWimSha256 = $script:VerifiedFinalWimSha256
    $ctx.IsoPayloadVerified = $script:IsoPayloadVerified
    $ctx.StreamIntegrityVerified = $script:StreamIntegrityVerified
    $ctx.StreamIntegrityMethod = $script:StreamIntegrityMethod
    $ctx.RemovedPackagesCount = if ($script:RemovedPackages) { $script:RemovedPackages.Count } else { 0 }
    $ctx.WinSxSSavedMB = if ($script:WinSxSSavedMB) { $script:WinSxSSavedMB } else { 0 }
    $ctx.WinSxsBeforeMB = if ($script:WinSxsBeforeMB) { $script:WinSxsBeforeMB } else { 0 }
    $ctx.WinSxsAfterMB = if ($script:WinSxsAfterMB) { $script:WinSxsAfterMB } else { 0 }
    $ctx.DismLogPath = $script:DismLogPath
    $ctx.DefenderExclusionAdded = $script:DefenderExclusionAdded
    $ctx.HivesLoaded = $script:HivesLoaded
    $ctx.MountOpened = $script:MountOpened
    $ctx.DismMountDir = $script:DismMountDir
    $ctx.ManagedMountDirs = $script:ManagedMountDirs
    $ctx.AllocatedMountDirs = $script:AllocatedMountDirs
    $ctx.PreservedMountDirs = $script:PreservedMountDirs
    $ctx.IsoCreatedSuccessfully = if ($null -ne $script:IsoCreatedSuccessfully) { [bool]$script:IsoCreatedSuccessfully } else { $false }
    $ctx.IsoPayloadMatch = if ($null -ne $script:IsoPayloadMatch) { [bool]$script:IsoPayloadMatch } else { $false }
    $ctx.ExportSucceeded = if ($null -ne $script:ExportSucceeded) { [bool]$script:ExportSucceeded } else { $false }
    $ctx.IsoGenerated = if ($null -ne $script:IsoGenerated) { [bool]$script:IsoGenerated } else { $false }
    $ctx.SelectedProfile = $selectedProfile
    $ctx.RemoveDefender = $removeDefender
    $ctx.KeepAsianIME = $keepAsianIME
    $ctx.KeepExtraFonts = $keepExtraFonts
    $ctx.RemoveDrivers = $removeDrivers
    $ctx.DisableWU = $disableWU
    $ctx.KeepBT = $keepBT
    $ctx.WslSupport = $wslSupport
    $ctx.KeepRecoveryEnv = $keepRecoveryEnv
    $ctx.SafeDebloatMode = $safeDebloatMode
    $ctx.UltraSlimMode = $ultraSlimMode
    $ctx.SetJapaneseKeyboard = $setJapaneseKeyboard
    $ctx.AtlasReviOSMode = $atlasReviOSMode
    $ctx.ExportESDMode = $exportESDMode
    $ctx.SplitWIMMode = $splitWIMMode
    $ctx.RemoveStore = $removeStore
    $ctx.KeepBasicApps = $keepBasicApps
    $ctx.KeepSearchIndex = $keepSearchIndex
    $ctx.KeepXboxServices = $keepXboxServices
    $ctx.KeepAudioTweaks = $keepAudioTweaks
    $ctx.UseVHDX = $useVHDX
    $ctx.RemoveLegacyFOD = $removeLegacyFOD
    $ctx.TrimWallpapers = $trimWallpapers
    $ctx.HibernateMode = $hibernateMode
    $ctx.CrashDumpMode = $crashDumpMode
    $ctx.DisableCPUMitigations = $disableCPUMitigations
    $ctx.MmcssGaming = $mmcssGaming
    $ctx.DawMode = $dawMode
    $ctx.DisableMemCompression = $disableMemCompression
    $ctx.DisableFSE = $disableFSE
    $ctx.NvidiaLowLatency = $nvidiaLowLatency
    $ctx.NoKernelPaging = $noKernelPaging
    $ctx.DisableUSBSuspend = $disableUSBSuspend
    $ctx.NoHypervisor = $noHypervisor
    $ctx.RemoveWebViewPostOOBE = $removeWebViewPostOOBE
    $ctx.FastExport = $fastExport
    $ctx.UefiOnly = $uefiOnly
    $ctx.CpuBoostMode = $cpuBoostMode
    $ctx.PowerPreset = $powerPreset
    $ctx.BypassActivationRestrictions = $bypassActivationRestrictions
    $ctx.RadicalRAM = $radicalRAM
    $ctx.AllowPhysicalDebloat = if ($null -ne $allowPhysicalDebloat) { [bool]$allowPhysicalDebloat } elseif ($null -ne $script:AllowPhysicalDebloat) { [bool]$script:AllowPhysicalDebloat } else { $false }
    $ctx.AdvancedDebloatStandard = if ($null -ne $advancedDebloatStandard) { [bool]$advancedDebloatStandard } elseif ($null -ne $script:AdvancedDebloatStandard) { [bool]$script:AdvancedDebloatStandard } else { $false }
    $ctx.AdvancedDebloatExperimental = if ($null -ne $advancedDebloatExperimental) { [bool]$advancedDebloatExperimental } elseif ($null -ne $script:AdvancedDebloatExperimental) { [bool]$script:AdvancedDebloatExperimental } else { $false }
    $ctx.ActiveTweakGroups = $script:activeTweakGroups
    $ctx.TweakSettings = if ($null -ne $script:TweakSettings) { $script:TweakSettings } else { [ordered]@{} }
    $ctx.PayloadFormat = $PayloadFormat
    $ctx.ComputerName = $ComputerName
    $ctx.UserName = $UserName
    $ctx.SourceWimSize = $sourceWimSize
    $ctx.ActivePayloadPath = $activePayloadPath
    $ctx.ActivePayloadName = $activePayloadName
    $ctx.DismPath = $dismPath
    $ctx.DismVerStr = $dismVerStr
    $ctx.HostBuildNum = $hostBuildNum
    $ctx.TargetEditionName = $targetEditionName
    $ctx.IsoFileName = $isoFileName
    $ctx.OutputIso = $outputIso
    $ctx.IsoSha256 = $sha256
    $ctx.IsoSizeMB = $isoSizeMB
    $ctx.TempOutputIso = $tempOutputIso
    $ctx.ExpectedPayloadFile = $expectedPayloadFile
    $ctx.ProfSlug = $profSlug
    $ctx.BootWimPath = $bootWimPath
    return $ctx
}

# Helper: sync BuildContext back to script-scope variables (bridge for incremental migration)
function Sync-ScriptScopeFromContext {
    param([BuildContext]$ctx)
    $script:BaseWorkDir = $ctx.BaseWorkDir
    $script:BuildId = $ctx.BuildId
    $script:DiagDir = $ctx.DiagDir
    $script:DiagnosticData = $ctx.DiagnosticData
    $script:CurrentPhase = $ctx.CurrentPhase
    $script:PhaseTimings = $ctx.PhaseTimings
    $script:PhaseStopwatch = $ctx.PhaseStopwatch
    $script:BuildSucceeded = $ctx.BuildSucceeded
    $script:FinalPayloadVerified = $ctx.FinalPayloadVerified
    $script:VerifiedFinalWimSha256 = $ctx.VerifiedFinalWimSha256
    $script:IsoPayloadVerified = $ctx.IsoPayloadVerified
    $script:StreamIntegrityVerified = $ctx.StreamIntegrityVerified
    $script:StreamIntegrityMethod = $ctx.StreamIntegrityMethod
    $script:RemovedPackagesCount = $ctx.RemovedPackagesCount
    $script:WinSxSSavedMB = $ctx.WinSxSSavedMB
    $script:WinSxsBeforeMB = $ctx.WinSxsBeforeMB
    $script:WinSxsAfterMB = $ctx.WinSxsAfterMB
    $script:DismLogPath = $ctx.DismLogPath
    $script:DefenderExclusionAdded = $ctx.DefenderExclusionAdded
    $script:HivesLoaded = $ctx.HivesLoaded
    $script:MountOpened = $ctx.MountOpened
    $script:DismMountDir = $ctx.DismMountDir
    $script:ManagedMountDirs = $ctx.ManagedMountDirs
    $script:AllocatedMountDirs = $ctx.AllocatedMountDirs
    $script:PreservedMountDirs = $ctx.PreservedMountDirs
    $script:IsoCreatedSuccessfully = $ctx.IsoCreatedSuccessfully
    $script:IsoPayloadMatch = $ctx.IsoPayloadMatch
    $script:ExportSucceeded = $ctx.ExportSucceeded
    $script:IsoGenerated = $ctx.IsoGenerated
    $script:AllowPhysicalDebloat = $ctx.AllowPhysicalDebloat
    $script:AdvancedDebloatStandard = $ctx.AdvancedDebloatStandard
    $script:AdvancedDebloatExperimental = $ctx.AdvancedDebloatExperimental
    $script:activeTweakGroups = $ctx.ActiveTweakGroups
    $script:TweakSettings = $ctx.TweakSettings
}

# Safe existence probe: Test-Path throws on some access-denied paths (verified),
# while Directory/File.Exists never throw.
function Test-WinEasePathExistsSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)) } catch { return $false }
}

# ============================================================================
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
# ============================================================================

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

function Remove-WinEaseTreeRobust {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$SafetyRoot,
        [switch]$AllowLockedFallback
    )
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
        New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop | Out-Null
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

# ==============================================================================
# Helper function: Write text file atomically with retry logic to avoid external lock failure
# ==============================================================================
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
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue | Out-Null
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

# ==============================================================================
# Helper function: Detect and resolve configuration conflicts across debloat selections and tweaks
# ==============================================================================
function Test-WinEaseConfigConflicts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Config,
        [switch]$AutoResolve
    )
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Helper to get property value whether hashtable or psobject
    $getVal = {
        param($key)
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains($key)) { return $Config[$key] }
        } elseif ($Config.PSObject.Properties[$key]) {
            return $Config.PSObject.Properties[$key].Value
        }
        return $null
    }
    $setVal = {
        param($key, $val)
        if ($Config -is [System.Collections.IDictionary]) {
            $Config[$key] = $val
        } elseif ($Config.PSObject.Properties[$key]) {
            $Config.PSObject.Properties[$key].Value = $val
        } else {
            $Config | Add-Member -NotePropertyName $key -NotePropertyValue $val -Force
        }
    }

    $rawStd = & $getVal 'advancedDebloatStandard'
    $rawExp = & $getVal 'advancedDebloatExperimental'
    $stdItems = [System.Collections.Generic.List[string]]::new()
    if ($rawStd) { foreach ($item in $rawStd) { $stdItems.Add("$item") } }
    $expItems = [System.Collections.Generic.List[string]]::new()
    if ($rawExp) { foreach ($item in $rawExp) { $expItems.Add("$item") } }

    $tweakSettings = & $getVal 'TweakSettings'
    $getTweak = {
        param($tkey)
        if ($tweakSettings -is [System.Collections.IDictionary]) {
            if ($tweakSettings.Contains($tkey)) { return [bool]$tweakSettings[$tkey] }
        } elseif ($tweakSettings -and $tweakSettings.PSObject.Properties[$tkey]) {
            return [bool]$tweakSettings.PSObject.Properties[$tkey].Value
        }
        return $false
    }
    $setTweak = {
        param($tkey, $tval)
        if ($tweakSettings -is [System.Collections.IDictionary]) {
            $tweakSettings[$tkey] = [bool]$tval
        } elseif ($tweakSettings -and $tweakSettings.PSObject.Properties[$tkey]) {
            $tweakSettings.PSObject.Properties[$tkey].Value = [bool]$tval
        }
    }

    # 1. Edge conflict
    if (& $getVal 'KeepEdge') {
        $expEdge = $expItems | Where-Object { $_ -match 'Edge' }
        if ($expEdge) {
            $msg = "KeepEdge is true, but advancedDebloatExperimental contains '$($expEdge -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "KeepEdge"; Type = "Browser"; Details = $msg; Resolution = "Removed Edge items from experimental debloat" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($expEdge)) { [void]$expItems.Remove($item) }
            }
        }
    }

    # 2. Defender conflict
    if ((& $getVal 'KeepDefender') -or (-not (& $getVal 'RemoveDefender'))) {
        $expDef = $expItems | Where-Object { $_ -match 'Defender|Firewall' }
        if ($expDef) {
            $msg = "Defender is kept, but advancedDebloatExperimental contains '$($expDef -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "Defender"; Type = "Security"; Details = $msg; Resolution = "Removed Defender items from experimental debloat" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($expDef)) { [void]$expItems.Remove($item) }
            }
        }
    }

    # 3. Recovery / WinRE conflict
    if (& $getVal 'KeepRecoveryEnv') {
        $stdWinre = $stdItems | Where-Object { $_ -match 'WinRE' }
        if ($stdWinre) {
            $msg = "KeepRecoveryEnv is true, but advancedDebloatStandard contains '$($stdWinre -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "WinRE"; Type = "Recovery"; Details = $msg; Resolution = "Removed WinRE removal from debloat" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($stdWinre)) { [void]$stdItems.Remove($item) }
            }
        }
    }

    # 4. Search index conflict
    if (& $getVal 'KeepSearchIndex') {
        $expSearch = $expItems | Where-Object { $_ -match 'Search index' }
        if ($expSearch) {
            $msg = "KeepSearchIndex is true, but advancedDebloatExperimental contains '$($expSearch -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "SearchIndex"; Type = "System"; Details = $msg; Resolution = "Removed Search index removal from debloat" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($expSearch)) { [void]$expItems.Remove($item) }
            }
        }
    }

    # 5. Xbox conflict
    if (& $getVal 'KeepXboxServices') {
        $stdXbox = $stdItems | Where-Object { $_ -match 'Xbox' }
        if ($stdXbox) {
            $msg = "KeepXboxServices is true, but debloat contains '$($stdXbox -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "XboxServices"; Type = "Gaming"; Details = $msg; Resolution = "Removed Xbox debloat items" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($stdXbox)) { [void]$stdItems.Remove($item) }
                foreach ($item in @($expItems | Where-Object { $_ -match 'Xbox' })) { [void]$expItems.Remove($item) }
            }
        }
    }

    # 6. Bluetooth conflict
    if (& $getVal 'KeepBT') {
        $stdBT = $stdItems | Where-Object { $_ -match 'Bluetooth' }
        $expBT = $expItems | Where-Object { $_ -match 'Bluetooth' }
        if ($stdBT -or $expBT) {
            $msg = "KeepBT is true, but debloat contains Bluetooth items."
            $conf = [PSCustomObject]@{ Rule = "Bluetooth"; Type = "Hardware"; Details = $msg; Resolution = "Removed Bluetooth debloat items" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($stdBT)) { [void]$stdItems.Remove($item) }
                foreach ($item in @($expBT)) { [void]$expItems.Remove($item) }
            }
        }
    }

    # 7. Microsoft Store vs Windows Update dependency
    $removeStoreVal = [bool](& $getVal 'RemoveStore')
    $keepStoreVal = [bool](& $getVal 'KeepStore')
    $storeRetained = (-not $removeStoreVal) -or $keepStoreVal
    $disableWUVal = [bool](& $getVal 'DisableWindowsUpdate')

    if ($storeRetained -and $disableWUVal) {
        $msg = "Microsoft Store is kept, but DisableWindowsUpdate is true. Store downloads/updates require Windows Update."
        $conf = [PSCustomObject]@{ Rule = "StoreWindowsUpdateDependency"; Type = "Dependency"; Details = $msg; Resolution = "Set DisableWindowsUpdate = $false to ensure Store functionality" }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
        if ($AutoResolve) {
            & $setVal 'DisableWindowsUpdate' $false
        }
    }

    # 8. Store retention conflict (KeepStore vs RemoveStore)
    if ($keepStoreVal -and $removeStoreVal) {
        $msg = "KeepStore is true, but RemoveStore is also set to true."
        $conf = [PSCustomObject]@{ Rule = "KeepStoreVsRemoveStore"; Type = "Logic"; Details = $msg; Resolution = "Set RemoveStore = $false (KeepStore takes precedence)" }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
        if ($AutoResolve) {
            & $setVal 'RemoveStore' $false
        }
    }

    # 9. Physical Debloat Safety Gate (-AllowPhysicalDebloat guard)
    $allowPhys = [bool](& $getVal 'AllowPhysicalDebloat')
    $physTweak = & $getTweak 'PhysicalDebloat'
    $hasPhysExp = ($expItems.Count -gt 0)
    if ((-not $allowPhys) -and ($physTweak -or $hasPhysExp)) {
        $msg = "Destructive physical debloat is requested, but -AllowPhysicalDebloat safety guard is not enabled."
        $conf = [PSCustomObject]@{ Rule = "PhysicalDebloatSafetyGate"; Type = "Safety"; Details = $msg; Resolution = "Disabled PhysicalDebloat tweak and cleared experimental deletions" }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
        if ($AutoResolve) {
            & $setTweak 'PhysicalDebloat' $false
            $expItems.Clear()
        }
    }

    # 10. Asian IME Preservation
    if (& $getVal 'KeepAsianIME') {
        $imeItems = $stdItems | Where-Object { $_ -match 'IME' }
        if ($imeItems) {
            $msg = "KeepAsianIME is true, but debloat contains IME removal items."
            $conf = [PSCustomObject]@{ Rule = "KeepAsianIME"; Type = "Localization"; Details = $msg; Resolution = "Removed IME removal items" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($imeItems)) { [void]$stdItems.Remove($item) }
            }
        }
    }

    # 11. Extra Fonts Preservation
    if (& $getVal 'KeepExtraFonts') {
        $fontItems = $stdItems | Where-Object { $_ -match 'font' }
        if ($fontItems) {
            $msg = "KeepExtraFonts is true, but debloat contains font removal items."
            $conf = [PSCustomObject]@{ Rule = "KeepExtraFonts"; Type = "Localization"; Details = $msg; Resolution = "Removed font removal items" }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
            if ($AutoResolve) {
                foreach ($item in @($fontItems)) { [void]$stdItems.Remove($item) }
            }
        }
    }

    if ($AutoResolve) {
        & $setVal 'advancedDebloatStandard' ($stdItems.ToArray())
        & $setVal 'advancedDebloatExperimental' ($expItems.ToArray())
    }

    return [PSCustomObject]@{
        HasConflicts   = ($conflicts.Count -gt 0)
        Conflicts      = [object[]]$conflicts
        Warnings       = [string[]]$warnings
        ResolvedConfig = $Config
    }
}

# ==============================================================================
# Helper function: Validate image and workspace integrity before resuming
# ==============================================================================
function Test-WinEaseResumeIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceDir,
        [int]$TargetPhase = 0,
        [switch]$IsIsoOnly
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $payloadPath = $null
    $payloadType = $null
    $bootWimPath = $null

    if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
        $errors.Add("Workspace directory '$WorkspaceDir' does not exist.")
        return [PSCustomObject]@{ IsValid = $false; Errors = [string[]]$errors; Warnings = [string[]]$warnings; BuildDir = $null; PayloadPath = $null; PayloadType = $null; BootWimPath = $null }
    }

    $buildDir = Join-Path -Path $WorkspaceDir -ChildPath "build"
    if (-not (Test-Path -LiteralPath $buildDir)) {
        $errors.Add("Workspace build directory '$buildDir' does not exist.")
        return [PSCustomObject]@{ IsValid = $false; Errors = [string[]]$errors; Warnings = [string[]]$warnings; BuildDir = $null; PayloadPath = $null; PayloadType = $null; BootWimPath = $null }
    }

    $sourcesDir = Join-Path -Path $buildDir -ChildPath "sources"
    if (-not (Test-Path -LiteralPath $sourcesDir)) {
        $errors.Add("Build sources directory '$sourcesDir' does not exist.")
    } else {
        foreach ($cand in @('install.wim', 'install.esd')) {
            $p = Join-Path -Path $sourcesDir -ChildPath $cand
            if (Test-Path -LiteralPath $p) {
                $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                if ($item.Length -gt 500MB) {
                    $payloadPath = $p
                    $payloadType = [System.IO.Path]::GetExtension($cand).TrimStart('.').ToUpperInvariant()
                    # Validate WIM header magic bytes MSWIM\0\0
                    try {
                        $fs = [System.IO.File]::OpenRead($p)
                        $hdr = New-Object byte[] 8
                        $null = $fs.Read($hdr, 0, 8)
                        $fs.Close()
                        $sig = [System.Text.Encoding]::ASCII.GetString($hdr, 0, 5)
                        if ($sig -ne 'MSWIM') {
                            $errors.Add("File '$p' does not have valid MSWIM header signature (got '$sig').")
                        }
                    } catch {
                        $errors.Add("Could not read WIM header of '$p': $_")
                    }
                    break
                }
            }
        }
        if (-not $payloadPath) {
            $errors.Add("No valid install.wim or install.esd (>500MB) found in '$sourcesDir'.")
        }
        $bootWimPath = Join-Path -Path $sourcesDir -ChildPath "boot.wim"
        if (-not (Test-Path -LiteralPath $bootWimPath)) {
            $errors.Add("boot.wim is missing in '$sourcesDir'.")
        }
    }

    # ISO root items validation for resume ISO mode
    if ($IsIsoOnly -or $TargetPhase -ge 13) {
        $requiredRootItems = @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')
        foreach ($item in $requiredRootItems) {
            $itemPath = Join-Path -Path $buildDir -ChildPath $item
            if (-not (Test-Path -LiteralPath $itemPath)) {
                $errors.Add("Required ISO root component '$item' is missing in '$buildDir'.")
            }
        }
    }

    return [PSCustomObject]@{
        IsValid     = ($errors.Count -eq 0)
        Errors      = [string[]]$errors
        Warnings    = [string[]]$warnings
        BuildDir    = $buildDir
        PayloadPath = $payloadPath
        PayloadType = $payloadType
        BootWimPath = $bootWimPath
    }
}

# ============================================================================
# Statistical Analysis & Benchmark Comparison Utilities
# ============================================================================

function Get-WinEaseMetricStatistics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [double[]]$Values
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [PSCustomObject]@{
            Count  = 0
            Mean   = 0.0
            Median = 0.0
            Min    = 0.0
            Max    = 0.0
            StdDev = 0.0
            IQR    = 0.0
        }
    }

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    # Mean
    $sum = 0.0
    foreach ($v in $sorted) { $sum += $v }
    $mean = [math]::Round($sum / $count, 3)

    # Median (p50)
    $median = if ($count % 2 -eq 1) {
        [double]$sorted[[math]::Floor($count / 2)]
    } else {
        $mid = [int]($count / 2)
        [double](([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0)
    }
    $median = [math]::Round($median, 3)

    # Min / Max
    $min = [double]$sorted[0]
    $max = [double]$sorted[$count - 1]

    # Sample StdDev (if count > 1, else 0)
    $stddev = 0.0
    if ($count -gt 1) {
        $sumSqDiff = 0.0
        foreach ($v in $sorted) {
            $diff = $v - $mean
            $sumSqDiff += ($diff * $diff)
        }
        $variance = $sumSqDiff / ($count - 1)
        $stddev = [math]::Round([math]::Sqrt($variance), 3)
    }

    # Interquartile Range (IQR) = Q3 - Q1
    $getPercentile = {
        param([double[]]$arr, [double]$p)
        if ($arr.Count -eq 1) { return [double]$arr[0] }
        $idx = ($arr.Count - 1) * $p
        $low = [int][math]::Floor($idx)
        $high = [int][math]::Ceiling($idx)
        if ($low -eq $high) { return [double]$arr[$low] }
        $weight = $idx - $low
        return [double]($arr[$low] * (1.0 - $weight) + $arr[$high] * $weight)
    }

    $q1 = & $getPercentile $sorted 0.25
    $q3 = & $getPercentile $sorted 0.75
    $iqr = [math]::Round(($q3 - $q1), 3)

    return [PSCustomObject]@{
        Count  = $count
        Mean   = $mean
        Median = $median
        Min    = $min
        Max    = $max
        StdDev = $stddev
        IQR    = $iqr
    }
}

function Compare-WinEaseBenchmarkSeries {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$BaselineRuns,

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$OptimizedRuns,

        [string]$OptimizedLabel = "WinEase Standard"
    )

    if ($null -eq $BaselineRuns -or $BaselineRuns.Count -eq 0 -or
        $null -eq $OptimizedRuns -or $OptimizedRuns.Count -eq 0) {
        return @{}
    }

    $extractValues = {
        param([PSCustomObject[]]$runs, [string]$metricName)
        $vals = [System.Collections.Generic.List[double]]::new()
        foreach ($r in $runs) {
            $val = $null
            if ($r.PSObject.Properties[$metricName]) {
                $val = $r.$metricName
            } elseif ($metricName -eq "CommittedMemoryMB" -and $r.Memory -and $r.Memory.CommittedMB) {
                $val = $r.Memory.CommittedMB
            } elseif ($metricName -eq "ProcessCount" -and $r.Memory -and $r.Memory.ProcessCount) {
                $val = $r.Memory.ProcessCount
            } elseif ($metricName -eq "ThreadCount" -and $r.Memory -and $r.Memory.ThreadCount) {
                $val = $r.Memory.ThreadCount
            } elseif ($metricName -eq "HandleCount" -and $r.Memory -and $r.Memory.HandleCount) {
                $val = $r.Memory.HandleCount
            } elseif ($metricName -eq "ColdCmdLatencyMs" -and $r.Probes -and $r.Probes.ColdLaunch -and $r.Probes.ColdLaunch.CmdExeMs) {
                $val = $r.Probes.ColdLaunch.CmdExeMs
            } elseif ($metricName -eq "WarmCmdLatencyMs" -and $r.Probes -and $r.Probes.WarmLaunch -and $r.Probes.WarmLaunch.CmdExeMs) {
                $val = $r.Probes.WarmLaunch.CmdExeMs
            } elseif ($metricName -eq "WindowsDirMB" -and $r.DiskFootprint -and $r.DiskFootprint.WindowsDirMB) {
                $val = $r.DiskFootprint.WindowsDirMB
            }

            if ($null -ne $val) {
                $num = 0.0
                if ([double]::TryParse([string]$val, [ref]$num)) {
                    $vals.Add($num)
                }
            }
        }
        return [double[]]$vals.ToArray()
    }

    $metricList = @(
        'CommittedMemoryMB',
        'ProcessCount',
        'ThreadCount',
        'HandleCount',
        'ColdCmdLatencyMs',
        'WarmCmdLatencyMs',
        'WindowsDirMB'
    )

    $comparison = [ordered]@{}

    foreach ($m in $metricList) {
        $baseVals = & $extractValues $BaselineRuns $m
        $optVals  = & $extractValues $OptimizedRuns $m

        if ($baseVals.Count -gt 0 -and $optVals.Count -gt 0) {
            $baseStats = Get-WinEaseMetricStatistics -Values $baseVals
            $optStats  = Get-WinEaseMetricStatistics -Values $optVals

            $pctImprovement = 0.0
            if ($baseStats.Median -gt 0) {
                $pctImprovement = [math]::Round((($baseStats.Median - $optStats.Median) / $baseStats.Median) * 100.0, 2)
            }

            $comparison[$m] = [PSCustomObject]@{
                Metric             = $m
                Baseline           = $baseStats
                Optimized          = $optStats
                OptimizedLabel     = $OptimizedLabel
                ImprovementPercent = $pctImprovement
            }
        }
    }

    return $comparison
}

# =========================================================================
# Dependency / feature-impact analysis (config/dependencies.psd1)
# =========================================================================

function Import-WinEaseDependencyCatalog {
    [CmdletBinding()]
    param(
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $Path = Join-Path -Path $scriptDir -ChildPath 'config\dependencies.psd1'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dependency catalog not found: $Path"
    }
    $catalog = Import-PowerShellDataFile -Path $Path
    $script:WinEaseDependencyCatalog = $catalog
    $script:WinEaseDependencyCatalogPath = $Path
    return $catalog
}

function Test-WinEaseDependencies {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Config
    )
    if (-not $script:WinEaseDependencyCatalog) {
        try { Import-WinEaseDependencyCatalog | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $cat = $script:WinEaseDependencyCatalog
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $impacts = [System.Collections.Generic.List[object]]::new()
    $unknowns = [System.Collections.Generic.List[object]]::new()
    $seenConflicts = @{}

    $addConflict = {
        param($category, $source, $summary, $conflictingWith)
        $key = "$source|$conflictingWith"
        if ($seenConflicts.ContainsKey($key)) { return }
        $seenConflicts[$key] = $true
        $conflicts.Add([pscustomobject]@{
            Category       = $category
            Source         = $source
            Summary        = $summary
            ConflictingWith = $conflictingWith
        })
    }

    if ($null -eq $cat) {
        return @{ HasIssues = $false; HasCritical = $false; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
    }

    # helper: is a given setting "removed / disabled"?
    $isRemoved = {
        param($entry, $value)
        if ($null -eq $entry -or $null -eq $entry.TriggerValue) { return $false }
        $tv = $entry.TriggerValue
        if ($tv -is [bool]) { return ([bool]$value -eq $tv) }
        return ("$value" -eq "$tv")
    }

    # Cross-rule conflicts (explicit)
    $wuKept = $false
    if ($Config -and $Config.ContainsKey('DisableWindowsUpdate')) { $wuKept = -not [bool]$Config['DisableWindowsUpdate'] }
    $expSelected = @()
    $stdSelected = @()
    if ($Config) {
        if ($Config.ContainsKey('AdvancedDebloatExperimental')) { $expSelected = @($Config['AdvancedDebloatExperimental']) }
        if ($Config.ContainsKey('AdvancedDebloatStandard')) { $stdSelected = @($Config['AdvancedDebloatStandard']) }
    }
    $safeMode = $false
    if ($Config -and $Config.ContainsKey('SafeDebloatMode')) { $safeMode = [bool]$Config['SafeDebloatMode'] }
    $keepBT = $true
    if ($Config -and $Config.ContainsKey('KeepBluetooth')) { $keepBT = [bool]$Config['KeepBluetooth'] }
    $wsl = $false
    if ($Config -and $Config.ContainsKey('WSLSupport')) { $wsl = [bool]$Config['WSLSupport'] }
    $noHyp = $false
    if ($Config -and $Config.ContainsKey('NoHypervisor')) { $noHyp = [bool]$Config['NoHypervisor'] }
    $keepRec = $false
    if ($Config -and $Config.ContainsKey('KeepRecoveryEnv')) { $keepRec = [bool]$Config['KeepRecoveryEnv'] }
    $keepSearch = $false
    if ($Config -and $Config.ContainsKey('KeepSearchIndex')) { $keepSearch = [bool]$Config['KeepSearchIndex'] }
    $disableSearch = $false
    if ($Config -and $Config.ContainsKey('DisableWindowsSearchIndexing')) { $disableSearch = [bool]$Config['DisableWindowsSearchIndexing'] }
    $keepXbox = $false
    if ($Config -and $Config.ContainsKey('KeepXboxServices')) { $keepXbox = [bool]$Config['KeepXboxServices'] }
    $removeStore = $false
    if ($Config -and $Config.ContainsKey('RemoveStore')) { $removeStore = [bool]$Config['RemoveStore'] }
    $disableGameDVR = $false
    if ($Config -and $Config.ContainsKey('DisableGameDVR')) { $disableGameDVR = [bool]$Config['DisableGameDVR'] }

    $btRemoved = ($stdSelected -contains 'Remove Bluetooth stack (service + binary) [20-40MB]') -or ($expSelected -contains 'Physical: Bluetooth stack (complete removal) [~20-40MB]')
    $wslRemoved = ($stdSelected -contains 'Remove WSL / VM Platform [20-40MB]') -or ($expSelected -contains 'Physical: WSL / VM Platform (complete removal) [~20-40MB]') -or ($expSelected -contains 'Physical: Hyper-V / Virtualization stack [~200-400MB]')
    $winreRemoved = ($stdSelected -contains 'Remove WinRE (reagentc /disable + file delete) [500-700MB]')
    $searchRemoved = ($expSelected -contains 'Physical: Cortana / Search (complete removal) [~100MB]') -or ($expSelected -contains 'Physical: Windows Search index (complete removal) [varies]')

    if ($wuKept -and $expSelected.Count -gt 0) {
        & $addConflict 'Component' 'DisableWindowsUpdate' 'Windows Update is kept but Experimental physical debloat is selected, which breaks WinSxS/CBS integrity.' 'AdvancedDebloatExperimental'
    }
    if ($safeMode -and $expSelected.Count -gt 0) {
        & $addConflict 'Component' 'SafeDebloatMode' 'Safe WinSxS mode is enabled but Experimental physical debloat is selected, which breaks CBS/WinSxS integrity.' 'AdvancedDebloatExperimental'
    }
    if ($keepBT -and $btRemoved) {
        & $addConflict 'Component' 'KeepBluetooth' 'Bluetooth is kept but a Bluetooth stack removal item is selected.' 'Bluetooth removal item'
    }
    if ($wsl -and ($noHyp -or $wslRemoved)) {
        & $addConflict 'Component' 'WSLSupport' 'WSL support is enabled but hypervisor is disabled or WSL/Hyper-V removal is selected.' 'NoHypervisor / WSL removal'
    }
    if ($keepRec -and $winreRemoved) {
        & $addConflict 'Component' 'KeepRecoveryEnv' 'Recovery environment is kept but WinRE removal is selected.' 'Remove WinRE'
    }
    if ($keepSearch -and ($disableSearch -or $searchRemoved)) {
        & $addConflict 'Component' 'KeepSearchIndex' 'Search indexing is kept but search disabling/removal is selected.' 'DisableWindowsSearchIndexing / search removal'
    }
    if ($keepXbox -and ($removeStore -or $disableGameDVR)) {
        & $addConflict 'Component' 'KeepXboxServices' 'Xbox services are kept but Store removal or GameDVR disable is selected.' 'RemoveStore / DisableGameDVR'
    }

    if (-not $Config) {
        $hasIssues = ($conflicts.Count -gt 0 -or $impacts.Count -gt 0 -or $unknowns.Count -gt 0)
        $hasCritical = ($conflicts.Count -gt 0 -or $unknowns.Count -gt 0)
        return @{ HasIssues = $hasIssues; HasCritical = $hasCritical; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
    }

    # Step 2: per-item ConflictsWith (generic) + Impacts/Unknowns
    # Components
    if ($cat -and $cat.Components) {
        foreach ($key in $cat.Components.Keys) {
            if (-not $Config.ContainsKey($key)) { continue }
            $entry = $cat.Components[$key]
            if ($null -eq $entry) { continue }
            $val = $Config[$key]
            $removed = & $isRemoved $entry $val
            if (-not $removed) { continue }
            if ($entry.Status -eq 'Safe') { continue }
            if ($entry.Status -eq 'Known') {
                $impacts.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
            } elseif ($entry.Status -eq 'Unknown') {
                $unknowns.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
            }
            # ConflictsWith generic
            if ($entry.ConflictsWith) {
                foreach ($cw in $entry.ConflictsWith) {
                    # determine if conflicting target is also removed/enabled
                    $targetRemoved = $false
                    if ($Config.ContainsKey($cw)) {
                        if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                        elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                        else { $targetRemoved = [bool]$Config[$cw] }
                    } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                        $targetRemoved = $true
                    }
                    if ($targetRemoved) {
                        & $addConflict 'Component' $key "$($entry.Summary)" $cw
                    }
                }
            }
        }
    }

    # Tweaks
    $tweakSettings = $null
    if ($Config.ContainsKey('TweakSettings')) { $tweakSettings = $Config['TweakSettings'] }
    if ($cat -and $cat.Tweaks) {
        foreach ($key in $cat.Tweaks.Keys) {
            $entry = $cat.Tweaks[$key]
            if ($null -eq $entry) { continue }
            $val = $null
            if ($tweakSettings) {
                if ($tweakSettings -is [System.Collections.IDictionary]) {
                    if ($tweakSettings.Contains($key)) { $val = $tweakSettings[$key] }
                } elseif ($tweakSettings.PSObject -and $tweakSettings.PSObject.Properties[$key]) {
                    $val = $tweakSettings.PSObject.Properties[$key].Value
                }
            }
            if ($null -eq $val -and $Config.ContainsKey($key)) { $val = $Config[$key] }
            if ($null -eq $val) { continue }
            $removed = & $isRemoved $entry $val
            if (-not $removed) { continue }
            if ($entry.Status -eq 'Safe') { continue }
            if ($entry.Status -eq 'Known') {
                $impacts.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
            } elseif ($entry.Status -eq 'Unknown') {
                $unknowns.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
            }
            if ($entry.ConflictsWith) {
                foreach ($cw in $entry.ConflictsWith) {
                    $targetRemoved = $false
                    if ($Config.ContainsKey($cw)) {
                        if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                        elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                        else { $targetRemoved = [bool]$Config[$cw] }
                    } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                        $targetRemoved = $true
                    }
                    if ($targetRemoved) {
                        & $addConflict 'Tweak' $key "$($entry.Summary)" $cw
                    }
                }
            }
        }
    }

    # User-defined custom tweaks (lib/WinEaseExtensions.ps1): enabled ones without explicit Impact are Unknown
    $userDefs = $null
    if (Get-Variable -Name UserTweakDefs -Scope Script -ErrorAction SilentlyContinue) { $userDefs = $script:UserTweakDefs }
    if ($userDefs -and $userDefs.Count -gt 0) {
        foreach ($ukey in @($userDefs.Keys)) {
            $uval = $null
            if ($tweakSettings) {
                if ($tweakSettings -is [System.Collections.IDictionary]) {
                    if ($tweakSettings.Contains($ukey)) { $uval = $tweakSettings[$ukey] }
                } elseif ($tweakSettings.PSObject -and $tweakSettings.PSObject.Properties[$ukey]) {
                    $uval = $tweakSettings.PSObject.Properties[$ukey].Value
                }
            }
            if ($null -eq $uval -and $Config.ContainsKey($ukey)) { $uval = $Config[$ukey] }
            if ($null -eq $uval -or $uval -ne $true) { continue }

            $udef = $userDefs[$ukey]
            $impact = $null
            if ($udef -is [System.Collections.IDictionary]) {
                if ($udef.Contains('Impact')) { $impact = $udef['Impact'] }
            } elseif ($udef -and $udef.PSObject.Properties['Impact']) {
                $impact = $udef.PSObject.Properties['Impact'].Value
            }

            if ($impact -is [System.Collections.IDictionary]) {
                $feat = @()
                if ($impact.Contains('AffectedFeatures')) { $feat = @($impact['AffectedFeatures']) }
                $reason = ''
                if ($impact.Contains('Reason')) { $reason = "$($impact['Reason'])" }
                $sev = ''
                if ($impact.Contains('Severity')) { $sev = "$($impact['Severity'])" }
                $impacts.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = $reason; AffectedFeatures = $feat; Severity = $sev })
            } elseif ($impact -is [string] -and $impact -eq 'Safe') {
                continue
            } else {
                $unknowns.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = 'User-defined custom tweak does not declare explicit dependency impact metadata (Dependency: Unknown).'; Reason = 'Impact is undefined or Unknown (fail-safe).' })
            }
        }
    }

    # AdvancedDebloat items (present in lists)
    if ($cat -and $cat.AdvancedDebloat) {
        foreach ($listName in @('AdvancedDebloatStandard','AdvancedDebloatExperimental')) {
            $items = @()
            if ($Config.ContainsKey($listName)) { $items = @($Config[$listName]) }
            foreach ($item in $items) {
                if ($cat.AdvancedDebloat.ContainsKey($item)) {
                    $entry = $cat.AdvancedDebloat[$item]
                    if ($entry.Status -eq 'Safe') { continue }
                    if ($entry.Status -eq 'Known') {
                        $impacts.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
                    } elseif ($entry.Status -eq 'Unknown') {
                        $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
                    }
                    if ($entry.ConflictsWith) {
                        foreach ($cw in $entry.ConflictsWith) {
                            $targetRemoved = $false
                            if ($Config.ContainsKey($cw)) {
                                if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                                elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                                else { $targetRemoved = [bool]$Config[$cw] }
                            } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                                $targetRemoved = $true
                            }
                            if ($targetRemoved) {
                                & $addConflict 'AdvancedDebloat' $item "$($entry.Summary)" $cw
                            }
                        }
                    }
                } else {
                    # fail-safe: unregistered item -> Unknown
                    $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = "Unregistered advanced debloat item"; Reason = 'Not defined in config/dependencies.psd1 (fail-safe: treated as Unknown).' })
                }
            }
        }
    }

    $hasIssues = ($conflicts.Count -gt 0 -or $impacts.Count -gt 0 -or $unknowns.Count -gt 0)
    $hasCritical = ($conflicts.Count -gt 0 -or $unknowns.Count -gt 0)
    return @{ HasIssues = $hasIssues; HasCritical = $hasCritical; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
}

function Format-WinEaseDependencyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )
    $sb = New-Object System.Text.StringBuilder
    if ($Result.Conflicts -and $Result.Conflicts.Count -gt 0) {
        [void]$sb.AppendLine('[DEPENDENCY CONFLICT]')
        foreach ($c in $Result.Conflicts) {
            $cw = if ($c.ConflictingWith) { " (conflicts with: $($c.ConflictingWith))" } else { '' }
            [void]$sb.AppendLine("  - [$($c.Category)] $($c.Source): $($c.Summary)$cw")
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Unknowns -and $Result.Unknowns.Count -gt 0) {
        [void]$sb.AppendLine('[DEPENDENCY UNKNOWN / 不明]')
        foreach ($u in $Result.Unknowns) {
            [void]$sb.AppendLine("  - [$($u.Category)] $($u.Source): $($u.Summary) -- $($u.Reason)")
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Impacts -and $Result.Impacts.Count -gt 0) {
        [void]$sb.AppendLine('[FEATURE IMPACT]')
        foreach ($i in $Result.Impacts) {
            [void]$sb.AppendLine("  - [$($i.Category)] $($i.Source): $($i.Summary)")
            if ($i.AffectedFeatures) {
                foreach ($af in $i.AffectedFeatures) {
                    [void]$sb.AppendLine("      * $af")
                }
            }
        }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}

# Path of a user-editable config file. The new home is config\user\<Name>; a file left in the old config\<Name>
# is still used when the new one is absent, with a one-time warning per file.
function Resolve-WinEaseUserConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $newPath = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'config\user') -ChildPath $Name
    if (Test-Path -LiteralPath $newPath) { return $newPath }
    $oldPath = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'config') -ChildPath $Name
    if (Test-Path -LiteralPath $oldPath) {
        if ($null -eq $script:WinEaseLegacyConfigWarned) { $script:WinEaseLegacyConfigWarned = @{} }
        if (-not $script:WinEaseLegacyConfigWarned.ContainsKey($Name)) {
            $script:WinEaseLegacyConfigWarned[$Name] = $true
            Write-Warning "Using '$oldPath' from the old location. Move it to '$newPath'."
        }
        return $oldPath
    }
    return $newPath
}
