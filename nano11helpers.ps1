# nano11helpers.ps1 - Pure utility helpers extracted from nano11builder.ps1 (F8)
# Dot-sourced by nano11builder.ps1. Functions use $script: scope of the caller.
# Keep this file next to nano11builder.ps1.

function ConvertTo-Nano11NormalizedPath {
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
# Compares on a '\' boundary so that 'C:\work2' is NOT treated as inside 'C:\work'.
function Test-Nano11PathWithin {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    $p = $Path.Replace('/', '\').TrimEnd('\')
    $r = $Root.Replace('/', '\').TrimEnd('\')
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
        } catch {}
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
        if ($full.Length -le 3) { return $false }
        $systemProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ($full -ieq $systemProfile.TrimEnd('\', '/')) { return $false }
        $windowsDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
        if (Test-Nano11PathWithin -Path $full -Root $windowsDir) { return $false }
        if ($scriptDir -and ($full -ieq [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\', '/'))) { return $false }
        return $true
    } catch {
        return $false
    }
}

function New-Nano11BuildId {
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

    for ($i = 1; $i -le $Retries; $i++) {
        if ($CaptureOutput) {
            $output = & dism.exe @fullArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $output
            }
        } else {
            if ($Quiet) {
                & dism.exe @fullArgs > $null 2>&1
            } else {
                & dism.exe @fullArgs
            }
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        if ($i -lt $Retries) {
            Write-Host "DISM command failed (Exit code: $LASTEXITCODE). Retrying ($i/$Retries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
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
$adminGroupSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

# Helper function: Query registered mounted images from DISM
# Helper function: Query registered mounted images from DISM (Distinguishes 0-mount success from query failure)

# ==============================================================================
# ==============================================================================
function Get-Nano11VolumeFreeSpaceGB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $driveLetter = (Split-Path -Path $resolved -Qualifier).TrimEnd(':')
        $drive = [System.IO.DriveInfo]::new($driveLetter)
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

    $normPath = try { ConvertTo-Nano11NormalizedPath -Path $Path } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-Nano11NormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-Nano11PathWithin -Path $normPath -Root $normBase)) {
            Write-Warning "Directory '$normPath' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normPDir = try { ConvertTo-Nano11NormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
            if ($normPath -ieq $normPDir) {
                Write-Warning "Directory '$normPath' is in PreservedMountDirs. Deletion prohibited."
                return $false
            }
            if ($normPDir.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Directory '$normPath' is a parent of preserved directory '$normPDir'. Deletion prohibited."
                return $false
            }
        }
    }

    try {
        $activeMounts = @(Get-Nano11MountedImages)
        $lingering = $activeMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
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

    $normVhdx = try { ConvertTo-Nano11NormalizedPath -Path $VhdxPath } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-Nano11NormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-Nano11PathWithin -Path $normVhdx -Root $normBase)) {
            Write-Warning "VHDX '$normVhdx' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normP = try { ConvertTo-Nano11NormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
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
    } catch {}

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
    } catch {}

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
    } catch {}
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
    [string]$Nano11Dir
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
    [hashtable]$ActiveTweakGroups
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
    $ctx.Nano11Dir = $nano11Dir
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
    $ctx.ActiveTweakGroups = $script:activeTweakGroups
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
    $script:activeTweakGroups = $ctx.ActiveTweakGroups
}

# Safe existence probe: Test-Path throws on some access-denied paths (verified),
# while Directory/File.Exists never throw.
function Test-Nano11PathExistsSafe {
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
#         NON-recursive takeown/icacls repair between passes.
#         VERIFIED HAZARDS: takeown /r and icacls /T traverse junctions, and robocopy /MIR
#         purges THROUGH junctions even with /XJ - so no recursive ACL grant and no mirror
#         purge may ever run while a link could remain (visible or hidden).
#   Fallback: (opt-in) Reset-DirectoryWithRobocopy for locked trees / loaded hives
# Returns $true when the path no longer exists.
# ============================================================================
function Remove-Nano11TreeRobust {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$SafetyRoot,
        [switch]$AllowLockedFallback
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    $full = try { ConvertTo-Nano11NormalizedPath -Path $Path } catch { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }

    # Safety guards: never operate on a drive root, and (when given) only on a strict child of SafetyRoot
    if ($full -match '^[A-Za-z]:$') {
        Write-Warning "Remove-Nano11TreeRobust: refusing to remove drive root '$full'."
        return $false
    }
    if ($SafetyRoot) {
        $normRoot = try { ConvertTo-Nano11NormalizedPath -Path $SafetyRoot } catch { [System.IO.Path]::GetFullPath($SafetyRoot).TrimEnd('\') }
        if (($full -ieq $normRoot) -or (-not (Test-Nano11PathWithin -Path $full -Root $normRoot))) {
            Write-Warning "Remove-Nano11TreeRobust: refusing '$full' (not a strict child of safety root '$normRoot')."
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $full)) { return $true }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # If the directory itself is a reparse point, remove the link only (never the target)
    $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($rootItem -and ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        try { [System.IO.Directory]::Delete($full, $false) } catch { Write-Warning "Remove-Nano11TreeRobust: failed to remove reparse point '$full': $_" }
        return (-not (Test-Path -LiteralPath $full))
    }

    # Tolerant reparse prune + native passes, iterated while progress is made.
    # SAFETY (empirically verified on Windows 11): takeown /r and icacls /T DO traverse
    # junctions, so no recursive ACL grant may ever meet a surviving link. ACL repair of
    # unreadable directories is therefore done NON-recursively, one directory at a time.
    $linkDeleteFailed = $false
    $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_empty_$([System.IO.Path]::GetRandomFileName())"
    $enumDenied = [System.Collections.Generic.List[string]]::new()
    $linkFailedParents = [System.Collections.Generic.List[string]]::new()

    try {
        New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Remove-Nano11TreeRobust: could not create mirror source '$emptyTemp': $_"
    }

    try {
        for ($iteration = 1; $iteration -le 4; $iteration++) {
            # --- Repair ACLs on directories the previous pass could not read, plus the parents
            # --- of links the previous pass could not delete (all non-recursive on the target;
            # --- the (OI)(CI) grant then propagates inside this tree only) ---
            if ($iteration -ge 2) {
                foreach ($deniedPath in (@($enumDenied) + @($linkFailedParents) + @($full))) {
                    if (-not (Test-Nano11PathExistsSafe -Path $deniedPath)) { continue }
                    # Inheritable grant repairs the whole subtree in one pass and makes child
                    # links deletable; ACL propagation is verified NOT to cross junctions (a
                    # link target keeps its own ACLs). Children with protected ACLs are picked
                    # up by the next iteration.
                    & takeown.exe /f "$deniedPath" /d y > $null 2>&1
                    & icacls.exe "$deniedPath" /remove:d '*S-1-5-32-544' /C /Q > $null 2>&1
                    & icacls.exe "$deniedPath" /grant '*S-1-5-32-544:(OI)(CI)F' /C /Q > $null 2>&1
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
                try { $children = @(Get-ChildItem -LiteralPath $curr -Force -ErrorAction Stop) }
                catch { $enumDenied.Add($curr); continue }
                foreach ($child in $children) {
                    if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        try {
                            if ($child.PSIsContainer) { [System.IO.Directory]::Delete($child.FullName, $false) }
                            else { [System.IO.File]::Delete($child.FullName) }
                            $prunedLinks++
                        } catch {
                            Write-Warning "Remove-Nano11TreeRobust: could not prune reparse point '$($child.FullName)': $_"
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
                Write-Verbose "Remove-Nano11TreeRobust: '$full' removed (iteration $iteration, $prunedLinks link(s) pruned, enumDenied=$($enumDenied.Count)) in $([math]::Round($sw.Elapsed.TotalSeconds,1))s."
                return $true
            }
        }
    } finally {
        if (Test-Path -LiteralPath $emptyTemp) { Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- Tier 3: heavy reset machinery for locked trees / loaded offline hives (opt-in) ---
    if ($AllowLockedFallback) {
        if (Get-Command -Name Reset-DirectoryWithRobocopy -ErrorAction SilentlyContinue) {
            try { Reset-DirectoryWithRobocopy -Path $full -Retries 2 } catch { Write-Warning "Remove-Nano11TreeRobust: heavy reset failed for '$full': $(($_ -split "`n")[0])" }
            if (Test-Path -LiteralPath $full) {
                if (-not $linkDeleteFailed) { & cmd.exe /c "rd /s /q `"$full`"" > $null 2>&1 }
                else { try { [System.IO.Directory]::Delete($full, $false) } catch {} }
            }
            if (-not (Test-Path -LiteralPath $full)) {
                Write-Verbose "Remove-Nano11TreeRobust: '$full' removed via tier 3 in $([math]::Round($sw.Elapsed.TotalSeconds,1))s."
                return $true
            }
        } else {
            Write-Warning "Remove-Nano11TreeRobust: Reset-DirectoryWithRobocopy not available; heavy fallback skipped for '$full'."
        }
    }

    Write-Warning "Remove-Nano11TreeRobust: '$full' could not be fully removed (linkPruneClean=$(-not $linkDeleteFailed), elapsed $([math]::Round($sw.Elapsed.TotalSeconds,1))s)."
    return $false
}
