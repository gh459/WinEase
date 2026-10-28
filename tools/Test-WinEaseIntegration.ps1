<#
.SYNOPSIS
    Manual / scheduled integration test: real ISO build + Hyper-V Gen2 VM boot (spec PR F2, section 10).

.DESCRIPTION
    UNVERIFIED SCAFFOLD. Nothing in this script has been run against a real Windows ISO or a real
    Hyper-V host. It exists so the stage plan, the result schema, the secret scrub and the
    pass/fail assertions can be reviewed and unit tested (tests\Integration.Scaffold.Tests.ps1)
    before the first real run. A green Pester run proves the scaffold parses and its pure logic
    behaves; it does NOT prove that a build boots on real hardware.

    Stages (see Get-WinEaseIntegrationPlan):
      preflight, build-iso, create-vm, wait-firstlogon, collect-logs, teardown, post-assert, scrub

    First-logon detection (UNTESTED): scripts\FirstLogon.ps1 writes C:\ProgramData\WinEase\firstlogon.done
    when it finishes and firstlogon_script.failed when a block failed. This script polls for those
    two files from the host with PowerShell Direct (Invoke-Command -VMName), using the throw-away
    local account created by the build (-UserName) and a random per-run password that the host
    generates, passes to the builder as -UserPassword and never writes to disk or to the result.

    Run only on a dedicated, disposable self-hosted Hyper-V runner (see docs\INTEGRATION_TESTING.md).

.PARAMETER IsoPath
    Path of the source Windows 11 ISO on this machine. Not needed with -DryRunPlanOnly or -ScrubOnly.
.PARAMETER Profile
    WinEase profile passed to WinEasebuilder.ps1 (extreme, balanced, none, vm).
.PARAMETER Index
    Edition/image index passed to the builder as -Index. Empty = builder default.
.PARAMETER WorkDir
    Scratch root for the builder workspace, the VM files and staged logs. Removed by teardown.
.PARAMETER ArtifactDir
    Output folder for the JSON result and collected logs. Must be outside WorkDir.
.PARAMETER VmName
    Name of the VM that is created and destroyed. A VM with this name must not exist beforehand.
.PARAMETER TimeoutMinutes
    Upper bound for the wait for the first-logon marker.
.PARAMETER WindowsBuild
    Free-text label of the source Windows build (for the report only; never used for logic).
.PARAMETER DryRunPlanOnly
    Return the stage plan and exit. Never touches Hyper-V, the disk or the builder.
.PARAMETER ScrubOnly
    Only run the secret scrub over ArtifactDir (used by the workflow before the upload).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = '-Profile mirrors the builder parameter of the same name')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Script-scope values are read by the functions')]
[CmdletBinding()]
param(
    [string]$IsoPath,
    [ValidateSet('extreme', 'balanced', 'none', 'vm')]
    [string]$Profile = 'balanced',
    [string]$Index,
    [string]$WorkDir = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'WinEaseIntegration'),
    [string]$ArtifactDir,
    [string]$VmName = 'WinEase-Integration',
    [ValidateRange(5, 480)]
    [int]$TimeoutMinutes = 90,
    [string]$WindowsBuild = 'unspecified',
    [string]$UserName = 'User',
    [switch]$DryRunPlanOnly,
    [switch]$ScrubOnly
)

$ErrorActionPreference = 'Stop'
$script:IntegrationRoot = Split-Path -Parent $PSScriptRoot
$script:RequiredFreeBytes = 80GB
$script:MarkerDone = 'C:\ProgramData\WinEase\firstlogon.done'
$script:MarkerFailed = 'C:\ProgramData\WinEase\firstlogon_script.failed'

# ---------------------------------------------------------------------------------------------
# Pure helpers (unit tested without Hyper-V)
# ---------------------------------------------------------------------------------------------

function Get-WinEaseIntegrationPlan {
    # The ordered stage plan. Pure data: no side effects.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $defs = @(
        @('preflight',       'Hyper-V module/service present, free disk space, no stale DISM mounts, VM name free',                 $false),
        @('build-iso',       'Run WinEasebuilder.ps1 -NonInteractive with the chosen profile/index and a random user password',     $false),
        @('create-vm',       'New-VM Generation 2 + VHDX + vTPM, attach the built ISO as first boot device, Start-VM',              $true),
        @('wait-firstlogon', 'Poll the first-logon marker through PowerShell Direct until done/failed/timeout',                     $true),
        @('collect-logs',    'Copy first-logon logs from the guest and the build diagnostics/report from the host',                 $true),
        @('teardown',        'Stop and remove the VM, delete the VHDX and the work directory (always runs once a VM may exist)',    $true),
        @('post-assert',     'No DISM mounts, no leftover work directory, no leftover VM',                                          $true),
        @('scrub',           'Fail and quarantine if the password or a known secret pattern appears in any artifact',               $false)
    )
    $order = 0
    return @($defs | ForEach-Object {
        $order++
        [PSCustomObject]@{ Order = $order; Name = $_[0]; Description = $_[1]; TouchesHyperV = [bool]$_[2] }
    })
}

function New-WinEaseIntegrationPassword {
    # Random per-run password: 24 chars from a mixed alphabet plus a fixed complexity suffix.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $chars = foreach ($b in $bytes) { $alphabet[$b % $alphabet.Length] }
    return (-join $chars) + 'a1Z'
}

function Get-WinEaseSecretPatterns {
    # Known secret shapes. Name -> regex. The values found are never echoed, only the names.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
        'github-token'      = '\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b'
        'github-pat'        = '\bgithub_pat_[A-Za-z0-9_]{40,}\b'
        'aws-access-key-id' = '\bAKIA[0-9A-Z]{16}\b'
        'private-key-block' = '-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----'
        'bearer-token'      = '(?i)\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{20,}'
        'anthropic-api-key' = '\bsk-ant-[A-Za-z0-9_-]{20,}\b'
    }
}

function Test-WinEaseArtifactSecrets {
    # Scans every file under -Path for the literal -Secret values, the builder's default password
    # and the known patterns. Returns one finding per (file, rule); a finding never contains the
    # matched text.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Secret = @()
    )
    $findings = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $findings }
    $patterns = Get-WinEaseSecretPatterns
    $literals = @($Secret | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $knownLiterals = @{ 'builder-default-password' = ('WinEase' + '123!') }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        try { $bytes = [System.IO.File]::ReadAllBytes($f.FullName) } catch {
            $findings += [PSCustomObject]@{ File = $f.FullName; Rule = 'unreadable-file' }
            continue
        }
        # Decode as UTF-8 and UTF-16 so Windows PowerShell transcripts/logs are covered too.
        $texts = @([System.Text.Encoding]::UTF8.GetString($bytes), [System.Text.Encoding]::Unicode.GetString($bytes))
        foreach ($t in $texts) {
            foreach ($lit in $literals) {
                if ($t.IndexOf($lit, [System.StringComparison]::Ordinal) -ge 0) {
                    $findings += [PSCustomObject]@{ File = $f.FullName; Rule = 'literal-secret' }
                }
            }
            foreach ($name in $knownLiterals.Keys) {
                if ($t.IndexOf($knownLiterals[$name], [System.StringComparison]::Ordinal) -ge 0) {
                    $findings += [PSCustomObject]@{ File = $f.FullName; Rule = $name }
                }
            }
            foreach ($name in $patterns.Keys) {
                if ($t -match $patterns[$name]) {
                    $findings += [PSCustomObject]@{ File = $f.FullName; Rule = $name }
                }
            }
        }
    }
    return @($findings | Group-Object File, Rule | ForEach-Object { $_.Group[0] })
}

function Invoke-WinEaseArtifactScrub {
    # Scan; on findings delete the offending files (quarantine) so a later upload cannot publish them.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Secret = @()
    )
    $findings = @(Test-WinEaseArtifactSecrets -Path $Path -Secret $Secret)
    $removed = @()
    foreach ($file in @($findings | ForEach-Object { $_.File } | Sort-Object -Unique)) {
        try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop; $removed += $file } catch {
            Write-Verbose "Could not quarantine ${file}: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        Passed   = ($findings.Count -eq 0)
        Findings = $findings
        Removed  = $removed
    }
}

function Test-WinEaseIntegrationDiskSpace {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][double]$FreeBytes,
        [double]$RequiredBytes = $script:RequiredFreeBytes
    )
    return [PSCustomObject]@{
        Ok            = ($FreeBytes -ge $RequiredBytes)
        FreeBytes     = $FreeBytes
        RequiredBytes = $RequiredBytes
    }
}

function Test-WinEaseIntegrationMountState {
    # Takes the records of Get-WinEaseMountedImages. On a dedicated runner ANY mounted image is stale.
    [CmdletBinding()]
    [OutputType([object])]
    param([object[]]$Mounts = @())
    $list = @($Mounts | Where-Object { $_ })
    return [PSCustomObject]@{
        Ok     = ($list.Count -eq 0)
        Mounts = @($list | ForEach-Object { "$($_.Path) [$($_.MountStatus)]" })
    }
}

function Test-WinEaseFileLocked {
    # True when the file cannot be opened exclusively (another process holds it).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $false
    } catch [System.IO.IOException] {
        return $true
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Remove-WinEaseIntegrationPath {
    # Recursive delete with retries (AV scanners and late handle release make the first attempt flaky).
    # Returns $true when the path is gone afterwards; a lock that persists is reported, not hidden.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 10)][int]$Attempts = 3,
        [int]$DelaySeconds = 2
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch {
            Write-Verbose "Delete attempt $i of ${Path} failed: $($_.Exception.Message)"
            if ($i -lt $Attempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Test-WinEaseIntegrationPostRun {
    # Post-run assertion: nothing may be left behind. All inputs are injectable for tests.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [object[]]$Mounts = @(),
        [string]$WorkDir,
        [string[]]$ExistingVmNames = @(),
        [string]$VmName
    )
    $problems = @()
    $list = @($Mounts | Where-Object { $_ })
    foreach ($m in $list) { $problems += "DISM mount still present: $($m.Path) [$($m.MountStatus)]" }
    if ($WorkDir -and (Test-Path -LiteralPath $WorkDir)) { $problems += "Work directory still exists: $WorkDir" }
    if ($VmName -and (@($ExistingVmNames) -contains $VmName)) { $problems += "VM still exists: $VmName" }
    return [PSCustomObject]@{ Ok = ($problems.Count -eq 0); Problems = $problems }
}

function New-WinEaseIntegrationResult {
    [CmdletBinding()]
    [OutputType([object])]
    param([hashtable]$Context)
    $stages = [ordered]@{}
    foreach ($s in (Get-WinEaseIntegrationPlan)) { $stages[$s.Name] = [ordered]@{ status = 'pending'; detail = '' } }
    return [ordered]@{
        schema       = 'winease.integration.result/1'
        verified     = $false     # a real ISO/VM run has to be reviewed by a human; never set automatically
        note         = 'Scaffold output. CI/Pester success does not mean the build was verified on real hardware.'
        startedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        finishedUtc  = $null
        overall      = 'pending'
        profile      = $Context.Profile
        index        = $Context.Index
        windowsBuild = $Context.WindowsBuild
        isoFileName  = $Context.IsoFileName
        vmName       = $Context.VmName
        stages       = $stages
        problems     = @()
    }
}

function Set-WinEaseIntegrationStage {
    [CmdletBinding()]
    param($Result, [string]$Name, [string]$Status, [string]$Detail = '')
    $Result.stages[$Name].status = $Status
    $Result.stages[$Name].detail = $Detail
}

# ---------------------------------------------------------------------------------------------
# Stages that touch the machine (UNTESTED)
# ---------------------------------------------------------------------------------------------

function Invoke-WinEaseIntegrationPreflight {
    [CmdletBinding()]
    param([string]$IsoPath, [string]$WorkDir, [string]$VmName)
    $problems = @()
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { $problems += "ISO not found: $IsoPath" }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { $problems += 'Hyper-V PowerShell module is not installed' }
    elseif (-not (Get-Service -Name vmms -ErrorAction SilentlyContinue)) { $problems += 'Hyper-V Virtual Machine Management service (vmms) not found' }
    elseif (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { $problems += "A VM named '$VmName' already exists" }

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($WorkDir))
    $drive = New-Object System.IO.DriveInfo($root)
    $disk = Test-WinEaseIntegrationDiskSpace -FreeBytes $drive.AvailableFreeSpace
    if (-not $disk.Ok) { $problems += ("Low disk space on {0}: {1:N1} GB free, {2:N1} GB required" -f $root, ($disk.FreeBytes / 1GB), ($disk.RequiredBytes / 1GB)) }

    # Reuse the builder's own DISM discovery (function-only file, safe to dot-source).
    . (Join-Path -Path $script:IntegrationRoot -ChildPath 'lib\WinEaseMount.ps1')
    $mountState = Test-WinEaseIntegrationMountState -Mounts @(Get-WinEaseMountedImages)
    if (-not $mountState.Ok) { $problems += ("Stale DISM mounts: " + ($mountState.Mounts -join '; ') + " (clean up with: dism /Cleanup-Mountpoints, then re-run)") }

    if (Test-Path -LiteralPath $WorkDir) { $problems += "WorkDir already exists (stale run?): $WorkDir" }
    return $problems
}

function Invoke-WinEaseIntegrationBuild {
    [CmdletBinding()]
    param([string]$IsoPath, [string]$Profile, [string]$Index, [string]$WorkDir, [string]$AccountName, [string]$AccountSecret, [string]$IsoName, [string]$LogPath)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:IntegrationRoot 'WinEasebuilder.ps1'),
        '-NonInteractive', '-Profile', $Profile, '-SourceDrive', $IsoPath, '-WorkDir', (Join-Path $WorkDir 'build'),
        '-OutputIsoName', $IsoName, '-UserName', $AccountName, '-UserPassword', $AccountSecret)
    if ($Index) { $argList += @('-Index', $Index) }
    # Note: the password is a process argument (visible to local admins for the duration of the run);
    # acceptable on a dedicated disposable runner, called out in docs\INTEGRATION_TESTING.md.
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath + '.err')
    if ($p.ExitCode -ne 0) { throw "WinEasebuilder.ps1 exited with code $($p.ExitCode)" }
    $iso = Join-Path $script:IntegrationRoot ($IsoName + '.iso')
    if (-not (Test-Path -LiteralPath $iso)) { throw "Builder reported success but the ISO was not found: $iso" }
    return $iso
}

function New-WinEaseIntegrationVm {
    [CmdletBinding()]
    param([string]$VmName, [string]$IsoFile, [string]$WorkDir)
    $vmDir = Join-Path $WorkDir 'vm'
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    $vhd = Join-Path $vmDir "$VmName.vhdx"
    New-VHD -Path $vhd -SizeBytes 64GB -Dynamic | Out-Null
    $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $vhd -Path $vmDir
    Set-VMProcessor -VM $vm -Count 2
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
    $dvd = Add-VMDvdDrive -VMName $VmName -Path $IsoFile -Passthru
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
    Start-VM -Name $VmName
    # "Press any key to boot from CD" can be missed on Gen2: tap Space a few times (best effort, UNTESTED).
    try {
        $kb = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_Keyboard -Filter "ElementName='$VmName'"
        if ($kb) {
            1..8 | ForEach-Object {
                Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = 32 } | Out-Null
                Start-Sleep -Milliseconds 700
            }
        }
    } catch { Write-Verbose "Boot key tap skipped: $($_.Exception.Message)" }
    return $vhd
}

function New-WinEaseIntegrationCredential {
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [string]$AccountName,
        [object]$AccountSecret
    )
    if ($AccountSecret -is [System.Security.SecureString]) {
        $secure = $AccountSecret
    } elseif ($AccountSecret -is [string]) {
        $secure = New-Object System.Security.SecureString
        foreach ($char in $AccountSecret.ToCharArray()) {
            $secure.AppendChar($char)
        }
        $secure.MakeReadOnly()
    } else {
        throw 'AccountSecret must be a string or SecureString.'
    }
    return (New-Object System.Management.Automation.PSCredential($AccountName, $secure))
}

function Wait-WinEaseFirstLogon {
    # Returns 'done', 'failed' or 'timeout'. PowerShell Direct needs the guest to be up and the account to exist.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VmName, [pscredential]$Credential, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        try {
            $state = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
                param($done, $failed)
                if (Test-Path -LiteralPath $failed) { 'failed' } elseif (Test-Path -LiteralPath $done) { 'done' } else { 'waiting' }
            } -ArgumentList $script:MarkerDone, $script:MarkerFailed
            if ($state -eq 'done' -or $state -eq 'failed') { return $state }
        } catch {
            Write-Verbose "Guest not reachable yet: $($_.Exception.Message)"   # expected during setup reboots
        }
    }
    return 'timeout'
}

function Copy-WinEaseGuestLogs {
    [CmdletBinding()]
    param([string]$VmName, [pscredential]$Credential, [string]$Destination)
    $session = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
    try {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        foreach ($src in @('C:\ProgramData\WinEase\*', 'C:\Windows\Panther\setupact.log', 'C:\Windows\Panther\setuperr.log')) {
            Copy-Item -FromSession $session -Path $src -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
}

function Invoke-WinEaseIntegrationTeardown {
    [CmdletBinding()]
    param([string]$VmName, [string]$WorkDir)
    $problems = @()
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vm) {
        try { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop } catch { Write-Verbose "Stop-VM: $($_.Exception.Message)" }
        try { Remove-VM -Name $VmName -Force -ErrorAction Stop } catch { $problems += "Remove-VM failed: $($_.Exception.Message)" }
    }
    if (-not (Remove-WinEaseIntegrationPath -Path $WorkDir)) { $problems += "Could not remove work directory (locked file?): $WorkDir" }
    return $problems
}

# ---------------------------------------------------------------------------------------------
# Main (skipped when the file is dot-sourced, e.g. by Pester)
# ---------------------------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

if ($DryRunPlanOnly) {
    $plan = Get-WinEaseIntegrationPlan
    Write-Host 'WinEase integration plan (dry run, nothing executed, nothing verified):'
    $plan | ForEach-Object { Write-Host ("  {0}. {1,-16} {2}" -f $_.Order, $_.Name, $_.Description) }
    return [PSCustomObject]@{
        schema   = 'winease.integration.plan/1'
        verified = $false
        profile  = $Profile
        index    = $Index
        vmName   = $VmName
        stages   = $plan
    }
}

if (-not $ArtifactDir) { $ArtifactDir = Join-Path -Path $script:IntegrationRoot -ChildPath 'integration-artifacts' }
$ArtifactDir = [System.IO.Path]::GetFullPath($ArtifactDir)
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

if ($ScrubOnly) {
    $scrubRun = Invoke-WinEaseArtifactScrub -Path $ArtifactDir
    foreach ($f in $scrubRun.Findings) { Write-Host "::error::Secret pattern '$($f.Rule)' in $($f.File) (file removed from the upload set)" }
    if (-not $scrubRun.Passed) { exit 1 }
    Write-Host "Scrub passed for $ArtifactDir"
    exit 0
}

if (-not $IsoPath) { throw '-IsoPath is required (or use -DryRunPlanOnly / -ScrubOnly).' }
if ($ArtifactDir.StartsWith($WorkDir, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'ArtifactDir must not be inside WorkDir (teardown deletes WorkDir).' }
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

$password = New-WinEaseIntegrationPassword
$guestCred = New-WinEaseIntegrationCredential -AccountName $UserName -AccountSecret $password
$isoName = 'WinEase_integration_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$result = New-WinEaseIntegrationResult -Context @{
    Profile = $Profile; Index = $Index; WindowsBuild = $WindowsBuild
    IsoFileName = [System.IO.Path]::GetFileName($IsoPath); VmName = $VmName
}
$vmMayExist = $false
$builtIso = $null
$guestState = $null
$failed = $false

try {
    Set-WinEaseIntegrationStage $result 'preflight' 'running'
    $pre = @(Invoke-WinEaseIntegrationPreflight -IsoPath $IsoPath -WorkDir $WorkDir -VmName $VmName)
    if ($pre.Count -gt 0) { throw ('Preflight failed: ' + ($pre -join ' | ')) }
    Set-WinEaseIntegrationStage $result 'preflight' 'passed'

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Set-WinEaseIntegrationStage $result 'build-iso' 'running'
    $builtIso = Invoke-WinEaseIntegrationBuild -IsoPath $IsoPath -Profile $Profile -Index $Index -WorkDir $WorkDir `
        -AccountName $UserName -AccountSecret $password -IsoName $isoName -LogPath (Join-Path $ArtifactDir 'builder.log')
    Set-WinEaseIntegrationStage $result 'build-iso' 'passed'

    Set-WinEaseIntegrationStage $result 'create-vm' 'running'
    $vmMayExist = $true
    [void](New-WinEaseIntegrationVm -VmName $VmName -IsoFile $builtIso -WorkDir $WorkDir)
    Set-WinEaseIntegrationStage $result 'create-vm' 'passed'

    Set-WinEaseIntegrationStage $result 'wait-firstlogon' 'running'
    $guestState = Wait-WinEaseFirstLogon -VmName $VmName -Credential $guestCred -TimeoutMinutes $TimeoutMinutes
    Set-WinEaseIntegrationStage $result 'wait-firstlogon' $(if ($guestState -eq 'done') { 'passed' } else { 'failed' }) $guestState
    if ($guestState -ne 'done') { throw "First logon did not complete: $guestState" }
} catch {
    $failed = $true
    $errText = "$($_.Exception.Message)"
    $result.problems += $errText
    foreach ($s in @($result.stages.Keys)) {
        if ($result.stages[$s].status -eq 'running') { Set-WinEaseIntegrationStage $result $s 'failed' $errText }
    }
} finally {
    # Always: logs (best effort), then teardown, then assertions, then scrub.
    Set-WinEaseIntegrationStage $result 'collect-logs' 'running'
    try {
        if ($vmMayExist -and (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
            Copy-WinEaseGuestLogs -VmName $VmName -Credential $guestCred -Destination (Join-Path $ArtifactDir 'guest')
        }
        $report = Join-Path $script:IntegrationRoot 'WinEase_report.html'
        if (Test-Path -LiteralPath $report) { Copy-Item -LiteralPath $report -Destination $ArtifactDir -Force }
        $diag = Join-Path $script:IntegrationRoot 'build_diagnostics'
        if (Test-Path -LiteralPath $diag) { Copy-Item -LiteralPath $diag -Destination (Join-Path $ArtifactDir 'build_diagnostics') -Recurse -Force }
        Set-WinEaseIntegrationStage $result 'collect-logs' 'passed'
    } catch { Set-WinEaseIntegrationStage $result 'collect-logs' 'failed' $_.Exception.Message; $failed = $true }

    Set-WinEaseIntegrationStage $result 'teardown' 'running'
    $td = @(Invoke-WinEaseIntegrationTeardown -VmName $VmName -WorkDir $WorkDir)
    if ($builtIso) { [void](Remove-WinEaseIntegrationPath -Path $builtIso) }
    Set-WinEaseIntegrationStage $result 'teardown' $(if ($td.Count -eq 0) { 'passed' } else { 'failed' }) ($td -join '; ')
    if ($td.Count -gt 0) { $failed = $true; $result.problems += $td }

    Set-WinEaseIntegrationStage $result 'post-assert' 'running'
    try {
        . (Join-Path -Path $script:IntegrationRoot -ChildPath 'lib\WinEaseMount.ps1')
        $vmNames = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $post = Test-WinEaseIntegrationPostRun -Mounts @(Get-WinEaseMountedImages) -WorkDir $WorkDir -ExistingVmNames $vmNames -VmName $VmName
        Set-WinEaseIntegrationStage $result 'post-assert' $(if ($post.Ok) { 'passed' } else { 'failed' }) ($post.Problems -join '; ')
        if (-not $post.Ok) { $failed = $true; $result.problems += $post.Problems }
    } catch { Set-WinEaseIntegrationStage $result 'post-assert' 'failed' $_.Exception.Message; $failed = $true }

    # The result is written BEFORE the scrub so the scrub covers it too.
    $result.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $result.overall = $(if ($failed) { 'failed' } else { 'passed-unverified' })
    $resultPath = Join-Path $ArtifactDir 'integration-result.json'
    ($result | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $resultPath -Encoding UTF8

    $scrub = Invoke-WinEaseArtifactScrub -Path $ArtifactDir -Secret @($password)
    if (-not $scrub.Passed) {
        $failed = $true
        $result.overall = 'failed'
        $result.problems += @(foreach ($f in $scrub.Findings) { "Secret rule '$($f.Rule)' matched in $($f.File); file removed" })
    }
    Set-WinEaseIntegrationStage $result 'scrub' $(if ($scrub.Passed) { 'passed' } else { 'failed' }) ("{0} finding(s)" -f @($scrub.Findings).Count)
    ($result | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

if ($failed) { exit 1 }
exit 0
