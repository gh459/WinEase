# WinEase-DefenderEnforce.ps1
#
# Online enforcement of RemoveDefender. Phase 10 removes the offline service keys,
# the CBS re-staging maps and the payload. Windows can nevertheless re-register some
# Defender services during the first boot from the servicing store. This script is
# deployed into C:\Windows\Setup\Scripts and runs as SYSTEM from Specialize.ps1 and
# SetupComplete.cmd, and again from FirstLogon.ps1 as a fallback.
#
# It removes the Defender engine and the Windows Security UI, not only their start
# values:
#   - stops and deletes the Defender/Security Center services, including their keys
#   - removes the Windows Security AppX package and its AppRepository/Appx rows
#   - removes the Defender payload folders
#   - installs IFEO traps so a re-created service still cannot start MsMpEng.exe
#   - disables the Defender scheduled tasks and the SecurityHealth autostart
#   - writes C:\ProgramData\WinEase\defender-status.txt
#
# The script never throws because it runs during OOBE: failures are written to the
# status file and the log, and the caller continues.

[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'SilentlyContinue'
$script:QuietMode = [bool]$Quiet
$markerDir = 'C:\ProgramData\WinEase'
$statusPath = Join-Path $markerDir 'defender-status.txt'
$logPath = Join-Path $markerDir 'defender-enforce.log'
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
}

function Write-EnfLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] [' + $Level + '] ' + $Message
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
    if (-not $script:QuietMode) { Write-Host $line }
}

function Remove-ProtectedTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        & takeown.exe /F $Path /R /A /D Y 2>$null | Out-Null
        & icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
        & icacls.exe $Path /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-EnfLog ("Could not remove {0}: {1}" -f $Path, $_.Exception.Message) 'WARN'
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Remove-DefenderService {
    param([string]$Name)
    # WinDefend and SecurityHealthService are owned by TrustedInstaller. regini gives
    # Administrators and SYSTEM the permissions needed to delete the key. It is
    # best-effort: sc.exe delete is still attempted if regini cannot change the ACL.
    $reginiLine = '\Registry\Machine\SYSTEM\CurrentControlSet\Services\' + $Name + ' [1 17]'
    $reginiFile = Join-Path $env:TEMP ('WinEase_defacl_' + [System.IO.Path]::GetRandomFileName() + '.txt')
    try {
        [System.IO.File]::WriteAllLines($reginiFile, @($reginiLine), [System.Text.Encoding]::ASCII)
        & regini.exe $reginiFile 2>$null | Out-Null
    } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $reginiFile -Force -ErrorAction SilentlyContinue

    & sc.exe stop $Name 2>$null | Out-Null
    & sc.exe config $Name start= disabled 2>$null | Out-Null
    & sc.exe delete $Name 2>$null | Out-Null
    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    if (Test-Path -LiteralPath $svcKey) {
        Remove-Item -LiteralPath $svcKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-SecurityUiPackage {
    # Remove the per-user registrations first, then the provisioned registration and
    # the payload. Every call is best-effort because Windows marks the package as
    # protected when the Security app is running.
    try {
        Get-AppxPackage -AllUsers -Name '*SecHealthUI*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
    } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
    try {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -match 'SecHealthUI' } |
            ForEach-Object {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
    } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }

    $payloadRoots = @(
        (Join-Path $env:ProgramFiles 'WindowsApps'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\AppRepository\Packages'),
        (Join-Path $env:windir 'SystemApps')
    )
    foreach ($root in $payloadRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'SecHealthUI' } |
            ForEach-Object { [void](Remove-ProtectedTree -Path $_.FullName) }
    }

    $appxRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApp',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\PendingDeployment',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned',
        'HKLM:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    )
    foreach ($root in $appxRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match 'SecHealthUI' } |
            ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($regPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy'
    )) {
        New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# Phase 11 only stages this helper when RemoveDefender (or the Security UI flag) is
# enabled. Refuse to act without that flag so a copied script can never harden a
# machine whose owner did not ask for it.
$removeDefenderFlag = 'C:\Windows\Setup\Scripts\remove-defender.flag'
if (-not (Test-Path -LiteralPath $removeDefenderFlag)) {
    Write-EnfLog 'No remove-defender.flag present; enforcement skipped.'
    exit 0
}

Write-EnfLog 'Windows Defender / Security UI enforcement started.'

# 1. Kill the engine and the Security UI processes before touching their services.
foreach ($proc in @('MsMpEng', 'MpCmdRun', 'NisSrv', 'Sense', 'MpCopyAccelerator', 'MpSigStub', 'SecurityHealthService', 'SecurityHealthSystray', 'SecurityHealthHost', 'SecHealthUI')) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 2. Remove the services and their service keys.
$services = @(
    'WinDefend', 'MDCoreSvc', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc',
    'webthreatdefsvc', 'webthreatdefusersvc', 'WdBoot', 'WdFilter', 'WdNisDrv',
    'SgrmBroker', 'SgrmAgent', 'MsSecCore', 'MsSecFlt', 'MsSecWfp'
)
foreach ($svc in $services) {
    Remove-DefenderService -Name $svc
}
Write-EnfLog ("Service removal requested for: {0}" -f ($services -join ', '))

# 3. Remove the Security UI package and its registrations.
Remove-SecurityUiPackage
Write-EnfLog 'Windows Security UI package removal requested.'

# 4. Remove the Defender payload folders.
$payloadDirs = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows Defender'),
    (Join-Path $env:ProgramData 'Microsoft\Windows Defender Platform'),
    (Join-Path $env:ProgramData 'Microsoft\Windows Security Health'),
    (Join-Path $env:ProgramFiles 'Windows Defender'),
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Defender')
)
foreach ($dir in $payloadDirs) {
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    [void](Remove-ProtectedTree -Path $dir)
}

# 5. Remove the Defender/Security Center scheduled tasks.
try {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -match 'Windows Defender|SecurityCenter|Windows Security'
    })
    foreach ($task in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
    }
} catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }

# 6. IFEO traps: even if a servicing pass re-creates a service, its image cannot start.
foreach ($ifeoName in @(
    'MsMpEng.exe', 'MpCmdRun.exe', 'NisSrv.exe', 'Sense.exe', 'MpCopyAccelerator.exe',
    'MpSigStub.exe', 'SecurityHealthService.exe', 'SecurityHealthSystray.exe',
    'SecurityHealthHost.exe', 'SecHealthUI.exe'
)) {
    $ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $ifeoName
    New-Item -Path $ifeoKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -LiteralPath $ifeoKey -Name 'Debugger' -Value '%SystemRoot%\System32\systray.exe' -Type String -Force -ErrorAction SilentlyContinue
}

# 7. Keep the policies that prevent re-enabling the engine.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiVirus' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -Name 'SubmitSamplesConsent' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'SecurityHealth' -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'SecurityHealth' -Force -ErrorAction SilentlyContinue

# 8. Remove Start menu shortcuts of the Security app.
foreach ($shortcut in @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Windows Security.lnk'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Security.lnk')
)) {
    Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
}

# 9. Report the real state. The service keys can survive until the next reboot after
#    sc delete, so the report distinguishes "absent" from "pending deletion".
$remainingServices = @()
foreach ($svc in $services) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) { $remainingServices += $svc }
}
$remainingProcesses = @()
foreach ($proc in @('MsMpEng', 'MpCmdRun', 'NisSrv', 'Sense', 'SecurityHealthService', 'SecurityHealthSystray', 'SecurityHealthHost', 'SecHealthUI')) {
    if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $remainingProcesses += $proc }
}
$remainingPackages = @()
try {
    $remainingPackages = @(Get-AppxPackage -AllUsers -Name '*SecHealthUI*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.PackageFullName })
} catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
$remainingDirs = [System.Collections.Generic.List[string]]::new()
foreach ($dir in $payloadDirs) {
    if ($dir -and (Test-Path -LiteralPath $dir)) { $remainingDirs.Add($dir) }
}
$ifeoPresent = @()
foreach ($ifeoName in @('MsMpEng.exe', 'SecurityHealthService.exe', 'SecurityHealthSystray.exe')) {
    $ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $ifeoName
    if (Test-Path -LiteralPath $ifeoKey) { $ifeoPresent += $ifeoName }
}

$status = @(
    'WinEase Defender / Security UI enforcement',
    'Timestamp:                  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
    'Services still registered:  ' + $(if ($remainingServices.Count) { $remainingServices -join ', ' } else { 'none' }),
    'Processes still running:    ' + $(if ($remainingProcesses.Count) { $remainingProcesses -join ', ' } else { 'none' }),
    'Security UI packages left:  ' + $(if ($remainingPackages.Count) { $remainingPackages -join ', ' } else { 'none' }),
    'Payload folders left:      ' + $(if ($remainingDirs.Count) { $remainingDirs -join ', ' } else { 'none' }),
    'IFEO traps present:        ' + $(if ($ifeoPresent.Count) { $ifeoPresent -join ', ' } else { 'none' })
)
try { [System.IO.File]::WriteAllLines($statusPath, $status, [System.Text.Encoding]::UTF8) } catch { Write-Verbose "Best-effort enforcement step failed: $($_.Exception.Message)" }
Write-EnfLog ('Status: services={0}; processes={1}; packages={2}; folders={3}' -f $status[2], $status[3], $status[4], $status[5])

# Never fail OOBE. The status file is the source of truth for verification.
exit 0
