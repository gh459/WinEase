# WinEaseSystem.ps1 - BuildContext, DISM, hive, filesystem-capacity and timing helpers
# Dot-sourced by WinEasehelpers.ps1 (class and function definitions only).

# BuildContext class - aggregates all build state into a single object (C1)
# Foundation for dependency injection. Phases can optionally accept a BuildContext
# instead of relying on global $script: variables.

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
    [bool]$RemoveAppxBloatware
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
    [bool]$BypassActivationRestrictions
    [bool]$RadicalRAM
    [bool]$AllowPhysicalDebloat
    [string[]]$AdvancedDebloatStandard
    [string[]]$AdvancedDebloatExperimental
    [hashtable]$ActiveTweakGroups
    [hashtable]$TweakSettings
    [string]$PayloadFormat
    [string]$ComputerName
    [string]$UserName
    [string]$UserPassword
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
        $this.AdvancedDebloatStandard = @()
        $this.AdvancedDebloatExperimental = @()
        $this.RemovedPackagesCount = 0
        $this.WinSxSSavedMB = 0
        $this.WinSxsBeforeMB = 0
        $this.WinSxsAfterMB = 0
        $this.PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function New-WinEaseBuildId {
    param([datetime]$Timestamp = (Get-Date))
    $timePart = $Timestamp.ToString('yyyyMMdd_HHmmss')
    $guidPart = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "${timePart}_${guidPart}"
}

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
    $ctx.RemoveAppxBloatware = $removeAppxBloatware
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
    $ctx.BypassActivationRestrictions = $bypassActivationRestrictions
    $ctx.RadicalRAM = $radicalRAM
    $ctx.AllowPhysicalDebloat = if ($null -ne $allowPhysicalDebloat) { [bool]$allowPhysicalDebloat } elseif ($null -ne $script:AllowPhysicalDebloat) { [bool]$script:AllowPhysicalDebloat } else { $false }
    # Item lists (string[]), not flags: keep elements and order; $null/unset becomes an empty list.
    # Assigned outside an if-expression: its output would unroll an empty array to $null.
    $advStandardSrc = if ($null -ne $advancedDebloatStandard) { $advancedDebloatStandard } else { $script:AdvancedDebloatStandard }
    $ctx.AdvancedDebloatStandard = [string[]]@($advStandardSrc | Where-Object { $null -ne $_ })
    $advExperimentalSrc = if ($null -ne $advancedDebloatExperimental) { $advancedDebloatExperimental } else { $script:AdvancedDebloatExperimental }
    $ctx.AdvancedDebloatExperimental = [string[]]@($advExperimentalSrc | Where-Object { $null -ne $_ })
    $ctx.ActiveTweakGroups = $script:activeTweakGroups
    $ctx.TweakSettings = if ($null -ne $script:TweakSettings) { $script:TweakSettings } else { [ordered]@{} }
    $ctx.PayloadFormat = $PayloadFormat
    $ctx.ComputerName = $ComputerName
    $ctx.UserName = $UserName
    $ctx.UserPassword = $UserPassword
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

function Format-WinEasePhaseDuration {
    param(
        [Parameter(Mandatory = $true)]
        [double]$TotalSeconds
    )
    $roundedSec = [math]::Round($TotalSeconds, 1)
    if ($roundedSec -lt 60) { return "${roundedSec}s" }
    $mins = [math]::Floor($roundedSec / 60)
    $secs = [math]::Round($roundedSec % 60, 1)
    if ($secs -eq 60) {
        $mins++
        $secs = 0
    }
    if ($secs -gt 0) { return "${mins}m ${secs}s" }
    return "${mins}m"
}

# --- Windows Defender workspace exclusion ---------------------------------------------------------
# The build adds the workspace to the Defender exclusions to speed DISM up and removes it at the end.
# Only an exclusion this build added is removed: an exclusion the user already had for the same path
# stays, and a failed add or remove is reported instead of being assumed to have worked.
function Test-WinEaseDefenderExclusion {
    param([Parameter(Mandatory = $true)][string]$Path)
    $key = $Path.TrimEnd('\')
    $listed = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\') })
    return ($listed -icontains $key)
}

function Add-WinEaseDefenderExclusion {
    <#
    .OUTPUTS
        $true only when this call added the exclusion and a read-back shows it. $false when the path was
        already excluded (it is not ours to remove), or when the add failed.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-WinEaseDefenderExclusion -Path $Path) {
            Write-Verbose "Defender already excludes '$Path'; the exclusion is left as it is."
            return $false
        }
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        if (Test-WinEaseDefenderExclusion -Path $Path) { return $true }
        Write-Warning "Could not confirm the Windows Defender exclusion for '$Path'; the build runs without it."
        return $false
    } catch {
        Write-Verbose "Defender exclusion skipped: $($_.Exception.Message)"
        return $false
    }
}

function Remove-WinEaseDefenderExclusion {
    <#
    .OUTPUTS
        $true when the exclusion is gone (read back). $false, with a warning that names the command to run,
        when it could not be removed.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        Remove-MpPreference -ExclusionPath $Path -ErrorAction Stop
        if (Test-WinEaseDefenderExclusion -Path $Path) { throw 'the exclusion is still listed after Remove-MpPreference' }
        return $true
    } catch {
        Write-Warning "The temporary Windows Defender exclusion for '$Path' could not be removed: $($_.Exception.Message). Remove it with: Remove-MpPreference -ExclusionPath '$Path'"
        return $false
    }
}

function Dismount-WinEaseDiskImageVerified {
    param([Parameter(Mandatory = $true)][string]$ImagePath, [string]$Label = 'disk image')
    $attached = {
        try {
            $di = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop
            return [bool]($di -and $di.Attached)
        } catch { return $true }
    }
    try { Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null } catch { Write-Verbose "Dismount reported: $($_.Exception.Message)" }
    if (-not (& $attached)) { return $true }
    Start-Sleep -Milliseconds 500
    try { Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null } catch { Write-Verbose "Dismount retry reported: $($_.Exception.Message)" }
    if (-not (& $attached)) { return $true }
    Write-Warning "The $Label is still mounted: $ImagePath. Run: Dismount-DiskImage -ImagePath '$ImagePath'"
    if ($script:DiagnosticData) {
        if (-not $script:DiagnosticData.ContainsKey('DismountFailures')) { $script:DiagnosticData['DismountFailures'] = @() }
        $script:DiagnosticData['DismountFailures'] += $ImagePath
    }
    return $false
}

function Resolve-WinEaseExplicitSourceMedia {
    param([Parameter(Mandatory = $true)][string]$SourceDrive)
    $result = [ordered]@{ DriveLetter = ''; MountedIso = $null; MountedByWinEase = $false }
    if ($SourceDrive.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $SourceDrive -PathType Leaf)) {
            throw "The ISO specified with -SourceDrive does not exist: $SourceDrive"
        }
        $wasAttached = $false
        try {
            $existing = Get-DiskImage -ImagePath $SourceDrive -ErrorAction Stop
            $wasAttached = [bool]($existing -and $existing.Attached)
        } catch { Write-Verbose "Get-DiskImage failed: $($_.Exception.Message)" }
        try {
            $img = Mount-DiskImage -ImagePath $SourceDrive -PassThru -ErrorAction Stop
        } catch {
            throw "The ISO specified with -SourceDrive could not be mounted: $SourceDrive ($($_.Exception.Message)). Not falling back to another media."
        }
        $result.MountedIso = $img
        $result.MountedByWinEase = -not $wasAttached
        $vol = $img | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not ($vol -and $vol.DriveLetter)) {
            if ($result.MountedByWinEase) { [void](Dismount-WinEaseDiskImageVerified -ImagePath $SourceDrive -Label 'source ISO') }
            throw "The ISO specified with -SourceDrive mounted without a drive letter: $SourceDrive. Not falling back to another media."
        }
        $result.DriveLetter = "$($vol.DriveLetter):"
        return [PSCustomObject]$result
    }
    $cand = $SourceDrive.Trim().TrimEnd(':') + ':'
    if (-not (Test-Path -LiteralPath $cand)) {
        throw "The drive specified with -SourceDrive does not exist: $SourceDrive. Not falling back to another media."
    }
    $result.DriveLetter = $cand
    return [PSCustomObject]$result
}

function ConvertTo-WinEaseProcessArgumentString {
    # Start-Process joins an -ArgumentList array with spaces and no quoting, so a path with a space is split
    # into several arguments. This quotes each element the way CommandLineToArgvW expects.
    param([string[]]$Arguments)
    $quoted = foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $escaped = $a -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return ($quoted -join ' ')
}