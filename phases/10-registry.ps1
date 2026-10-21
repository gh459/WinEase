# Phase 10: Registry Hive Loading, Hardware Bypasses & Granular Tweaks
# Dot-sourced by the main orchestrator (WinEasebuilder.ps1)

Write-Host "Loading offline registry hives..." -ForegroundColor Cyan
$systemHive    = "$scratchDir\Windows\System32\config\SYSTEM"
$softwareHive  = "$scratchDir\Windows\System32\config\SOFTWARE"
$defaultHive   = "$scratchDir\Windows\System32\config\default"
$componentsHive= "$scratchDir\Windows\System32\config\COMPONENTS"
$ntuserHive    = "$scratchDir\Users\Default\ntuser.dat"

# Abort on any load failure
$hivesToLoad = [ordered]@{
    zSYSTEM     = $systemHive
    zSOFTWARE   = $softwareHive
    zDEFAULT    = $defaultHive
    zCOMPONENTS = $componentsHive
    zNTUSER     = $ntuserHive
}
foreach ($hiveName in $hivesToLoad.Keys) {
    $hiveFile = $hivesToLoad[$hiveName]
    $loadOutput = & reg.exe load "HKLM\$hiveName" "$hiveFile" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline registry hive HKLM\$hiveName from '$hiveFile' (Exit code: $LASTEXITCODE): $loadOutput"
    }
    $script:HivesLoaded = $true
}

# Detect and display target Windows build info
try {
    $targetProductName = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ProductName 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetDisplayVer  = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetBuildNum    = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetUBR         = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR 2>$null | Select-String -Pattern 'REG_DWORD\s+0x([0-9a-fA-F]+)' | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
    if ($targetProductName) {
        Write-Host "Target Image OS: $targetProductName (Version: $targetDisplayVer, Build: $targetBuildNum.$targetUBR)" -ForegroundColor Green
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

# Helper function to evaluate individual toggle settings
# (guarded so a re-run of the phase does not redefine it; phase 11 declares the same helper)
if (-not (Get-Command -Name Test-TweakEnabled -ErrorAction SilentlyContinue)) {
    function Test-TweakEnabled {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Name,
            [bool]$Default = $true
        )
        if ($null -ne $script:TweakSettings -and $script:TweakSettings.Contains($Name)) {
            return [bool]$script:TweakSettings[$Name]
        }
        # Legacy key names (older profiles / -TweakSettings hashtables) that map onto this GUI key
        if ($null -ne $script:TweakSettings -and $script:TweakKeyAliases) {
            foreach ($alias in $script:TweakKeyAliases.Keys) {
                if ($script:TweakKeyAliases[$alias] -eq $Name -and $script:TweakSettings.Contains($alias)) {
                    return [bool]$script:TweakSettings[$alias]
                }
            }
        }
        $varName = "Tweak_$Name"
        $v = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $v) { return [bool]$v.Value }
        return $Default
    }
}

# ============================================================================
# 1. Setup & Hardware Requirement Bypasses
# ============================================================================
if (Test-TweakEnabled 'BypassHardwareRequirements' $true) {
    Write-Host "Applying Setup & Hardware requirement bypasses (LabConfig + MoSetup)..." -ForegroundColor Green
    $labConfigKeys = @('BypassCPUCheck', 'BypassRAMCheck', 'BypassSecureBootCheck', 'BypassStorageCheck', 'BypassTPMCheck', 'BypassDiskCheck')
    foreach ($key in $labConfigKeys) {
        reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
    }
    reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1
}

# ============================================================================
# 2. OOBE & Local Account Setup
# ============================================================================
# BypassNRO and BypassNetworkRequirement are one setting (Get-WinEaseBypassNROEnabled); phase 11 removes
# the specialize command of autounattend.xml with the same answer.
if (Get-WinEaseBypassNROEnabled -TweakSettings $script:TweakSettings) {
    Write-Host "Enabling Local Account bypass on OOBE (BypassNRO)..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
} else {
    Write-Host "BypassNRO is off: OOBE keeps its network requirement (no BypassNRO is written)." -ForegroundColor Yellow
    # an image that went through an earlier run may already carry the values
    reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /f > $null 2>&1
    reg.exe delete "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /f > $null 2>&1
}
if (Test-TweakEnabled 'BypassNRO' $true) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v "ShippedWithReserves" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'PreventDeviceEncryption' $false) {
    Write-Host "Preventing automatic BitLocker device encryption..." -ForegroundColor Green
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\EnhancedStorageDevices" /v "TCGSecurityActivationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
}

# Japanese 106/109 Keyboard Configuration
if ($setJapaneseKeyboard -or (Test-TweakEnabled 'SetJapaneseKeyboard' $false)) {
    Write-Host "Configuring Japanese 106/109 keyboard layout..." -ForegroundColor Green
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "LayerDriver JPN" /t REG_SZ /d "kbd106.dll" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardIdentifier" /t REG_SZ /d "PCAT_106KEY" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardType" /t REG_DWORD /d 7 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardSubtype" /t REG_DWORD /d 2 /f > $null 2>&1
}

# Setup & Winlogon / Blank Password / Script Execution
# The network use of a blank password is blocked in every configuration: an empty
# password must never work over the network.
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Lsa" /v "LimitBlankPasswordUse" /t REG_DWORD /d 1 /f > $null 2>&1
if (Test-TweakEnabled 'ConfigureWinlogon' $false) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "AutoAdminLogon" /t REG_SZ /d "1" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultUserName" /t REG_SZ /d "$UserName" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /f /v "DefaultPassword" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "ForceAutoLogon" /t REG_SZ /d "1" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowDomainDelayLock" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "FilterAdministratorToken" /t REG_DWORD /d 0 /f > $null 2>&1
} else {
    Write-Host "Blank-password auto-logon is disabled (ConfigureWinlogon is off)." -ForegroundColor Yellow
}

# PowerShell Script Execution Policy
if (Test-TweakEnabled 'EnableScripts' $true) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "EnableScripts" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1
}

# ============================================================================
# 3. Sponsored Apps, Suggestions & Cloud Content
# ============================================================================
if (Test-TweakEnabled 'DisableCloudContent' $true) {
    Write-Host "Disabling Sponsored Apps & Cloud Content..." -ForegroundColor Green
    $cdmSettings = @(
        'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
        'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
        'SoftLandingEnabled', 'SubscribedContentEnabled', 'SubscribedContent-310093Enabled',
        'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
        'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
        'SubscribedContent-353698Enabled', 'SystemPaneSuggestionsEnabled', 'RotatingImageOverlayEnabled'
    )
    foreach ($setting in $cdmSettings) {
        reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $setting /t REG_DWORD /d 0 /f > $null 2>&1
        reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $setting /t REG_DWORD /d 0 /f > $null 2>&1
    }
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableConsumerAccountStateContent" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableSoftLanding" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsSpotlightFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableAccountBasedInSettings" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v "DisablePushToInstall" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v "DontOfferThroughWUAU" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v "ConfigureStartPins" /t REG_SZ /d "{\`"pinnedList\`": [{}]}" /f > $null 2>&1
}

# ============================================================================
# 4. Diagnostics, Privacy & Telemetry
# ============================================================================
if (Test-TweakEnabled 'DisableTelemetryAndDiagnostics' $true) {
    Write-Host "Disabling Diagnostics & Telemetry..." -ForegroundColor Green
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v "TailoredExperiencesWithDiagnosticDataEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy" /v "TailoredExperiencesWithDiagnosticDataEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v "HasAccepted" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v "HasAccepted" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Input\TIPC" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitInkCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitTextCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\InputPersonalization" /v "RestrictImplicitInkCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\InputPersonalization" /v "RestrictImplicitTextCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MaxTelemetryAllowed" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\SQMClient\Windows" /v "CEIPEnable" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Device Metadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d 1 /f > $null 2>&1
}

# Windows Error Reporting
if (Test-TweakEnabled 'DisableErrorReporting' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontSendAdditionalData" /t REG_DWORD /d 1 /f > $null 2>&1
}

# User Activity History & Sync
if (Test-TweakEnabled 'DisableActivityHistory' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "UploadUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "PublishUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Backup" /v "DisableCloudBackup" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableBackupRestore" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSync" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSyncUserOverride" /t REG_DWORD /d 1 /f > $null 2>&1
}

# ============================================================================
# 5. Windows AI, Recall, Click-To-Do & Copilot
# ============================================================================
if (Test-TweakEnabled 'DisableWindowsAI' $true) {
    Write-Host "Disabling Windows AI, Recall, and Click-To-Do policies..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallEnablement" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallToBeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableClickToDo" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableSettingsAgent" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentWorkspaces" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableRemoteAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowCopilotRuntime" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Notepad" /v "EnableAIFeatures" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Paint" /v "EnableCocreator" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableCopilot' $true) {
    Write-Host "Disabling Copilot, DevHome, and Teams auto-install..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "HubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "CopilotPageContext" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v "DisableInstallation" /t REG_DWORD /d 1 /f > $null 2>&1
}

# ============================================================================
# 6. Cross-Device & Mobile Device Integration
# ============================================================================
if (Test-TweakEnabled 'DisableCrossDevice' $true) {
    Write-Host "Disabling Cross-Device Experience / Phone Link & Resume..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceResume" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "DisableResume" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "DisableCrossDeviceResume" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableCdp" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableMmx" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowCrossDeviceClipboard" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration" /v "IsResumeAllowed" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration" /v "IsResumeAllowed" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1
}

# ============================================================================
# 7. Start Menu, Web Search & Widgets
# ============================================================================
if (Test-TweakEnabled 'DisableWebSearch' $true) {
    Write-Host "Disabling Bing search & web suggestions in Start menu..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "EnableDynamicContentInWSB" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCloudSearch" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowSearchToUseLocation" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'HideSearchBox' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableWidgets' $true) {
    Write-Host "Disabling Windows 11 Widgets..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Widgets" /v "AllowWidgets" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'HideRecommendedSection' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_IrisRecommendations" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_IrisRecommendations" /t REG_DWORD /d 0 /f > $null 2>&1
}

# ============================================================================
# 8. Security & Stability Controls
# ============================================================================
if (Test-TweakEnabled 'DisableSmartScreen' $false) {
    Write-Host "Disabling SmartScreen policies..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableSmartScreen" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "SmartScreenEnabled" /t REG_SZ /d "Off" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "SmartScreenEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "SmartScreenPuaEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableUAC' $false) {
    Write-Host "Disabling UAC consent prompts..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "ConsentPromptBehaviorAdmin" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "PromptOnSecureDesktop" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableVBS' $false) {
    Write-Host "Disabling Virtualization-Based Security (VBS / HVCI)..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "EnableVirtualizationBasedSecurity" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "RequirePlatformSecurityFeatures" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableWPBT' $false) {
    Write-Host "Blocking UEFI WPBT execution (OEM bloatware persistence prevention)..." -ForegroundColor Green
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableBSODEmoticon' $false) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisplayParameters" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisableEmoticon" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableFTH' $false) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\FTH" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisablePCA' $false) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisablePCA" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableEngine" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableInventory" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AITEnable" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableUAR" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableDeliveryOptimization' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v "DODownloadMode" /t REG_DWORD /d 0 /f > $null 2>&1
}

# ============================================================================
# 9. Performance, Power & Latency Optimizations
# ============================================================================
if (Test-TweakEnabled 'DisablePowerThrottling' $true) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerThrottling" /v "PowerThrottlingOff" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableIdleMaintenance' $false) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v "MaintenanceDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
}

# AtlasOS & ReviOS low-latency kernel tuning.
# The GUI exposes "AtlasOS & ReviOS Low-Latency Kernel Tuning" as a component
# (AtlasReviOSMode) but nothing in the phases read it, so the checkbox had no
# effect at all. It is the umbrella switch for the latency kernel work below:
# DPC thread tweaking + foreground quantum scheduling (ThreadDpcEnable) and the
# MMCSS Games/Pro Audio task profiles. Turning it off skips the whole set.
$atlasReviOSEnabled = [bool]$atlasReviOSMode

if (Test-TweakEnabled 'ThreadDpcEnable' $false) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Kernel" /v "ThreadDpcEnable" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 38 /f > $null 2>&1
} elseif ($atlasReviOSEnabled) {
    # Atlas/ReviOS baseline: foreground quantum scheduling without the DPC tweak.
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 38 /f > $null 2>&1
}

if (Test-TweakEnabled 'NtfsDisable8dot3' $true) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisable8dot3NameCreation" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisableLastAccessUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'EnableLongPaths' $true) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "LongPathsEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'NetworkTuning' $false) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "TcpTimedWaitDelay" /t REG_DWORD /d 30 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "MaxUserPort" /t REG_DWORD /d 65534 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "DefaultTTL" /t REG_DWORD /d 64 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "EnableICMPRedirect" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "EnableMulticast" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "DisableSmartNameResolution" /t REG_DWORD /d 1 /f > $null 2>&1
}

if ($keepAudioTweaks -or $dawMode -or (Test-TweakEnabled 'LowLatencyAudioMMCSS' $false)) {
    Write-Host "  [Audio DAW] Configuring low-latency Pro Audio MMCSS task profile..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Priority" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
}

if ($mmcssGaming -or (Test-TweakEnabled 'MMCSSGaming' $false) -or $atlasReviOSEnabled) {
    Write-Host "  [Gaming] Configuring Games MMCSS task profile..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 6 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Affinity" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1
}

if ($radicalRAM -or (Test-TweakEnabled 'SvcHostConsolidation' $false)) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "SvcHostSplitThresholdInKB" /t REG_DWORD /d 67108864 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePageCombining" /t REG_DWORD /d 0 /f > $null 2>&1
}

if ($noKernelPaging -or (Test-TweakEnabled 'NoKernelPaging' $false)) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /f /v "DisablePagingExecutive" /t REG_DWORD /d 1 > $null 2>&1
}

if ($disableCPUMitigations -or (Test-TweakEnabled 'DisableCPUMitigations' $false)) {
    Write-Host "  [SECURITY WARNING] Disabling CPU speculative execution mitigations (Spectre/Meltdown)..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverride" /t REG_DWORD /d 3 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverrideMask" /t REG_DWORD /d 3 /f > $null 2>&1
}

if ($disableFSE -or (Test-TweakEnabled 'DisableFSE' $false)) {
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
}

# NVIDIA low-latency: PowerMizer performance mode + per-CPU core DPC registry tuning.
# The switch existed in the CLI and the README documented the behaviour, but no phase
# consumed it, so the flag had no effect. PowerMizer is set to "Prefer maximum
# performance" (0x1) and the per-processor DPC policy is switched to the DPC profile.
if ($nvidiaLowLatency -or (Test-TweakEnabled 'NvidiaLowLatency' $false)) {
    Write-Host "  [NVIDIA] Applying PowerMizer performance mode and per-CPU core DPC policy..." -ForegroundColor Green
    # PowerMizer: 0 = max performance (newer drivers), 1 = adaptive
    reg.exe add "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" /v "PowerMizerPerf" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" /v "PowerMizerAsync" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" /v "PowerMizerClock" /t REG_DWORD /d 0 /f > $null 2>&1
    # Per-processor DPC policy: 1 = the processor is a DPC processor (defers non-DPC work).
    reg.exe add "HKLM\zSYSTEM\CurrentControlSet\Control\Session Manager\kernel" /v "DpcProfile" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\CurrentControlSet\Control\Session Manager\kernel\Processor" /v "DpcProfile" /t REG_DWORD /d 1 /f > $null 2>&1
}

# HAGS & MSI
$gpuLatencyEnabled = [bool]$script:activeTweakGroups['GPULatency'] -or (Test-TweakEnabled 'EnableHAGS' $true)
if ($gpuLatencyEnabled) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers" /v "HwSchMode" /t REG_DWORD /d 2 /f > $null 2>&1
}

# ============================================================================
# 10. UI & Ergonomics
# ============================================================================
if (Test-TweakEnabled 'EnableClassicContextMenu' $true) {
    Write-Host "Enabling Windows 10 Classic Context Menu..." -ForegroundColor Green
    reg.exe add "HKLM\zDEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1
}

if (Test-TweakEnabled 'EnableDarkTheme' $true) {
    Write-Host "Enabling Dark Theme by default..." -ForegroundColor Green
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'ShowFileExtensions' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'ShowHiddenFiles' $false) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'LaunchToThisPC' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'TaskbarEndTask' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'TaskbarAlignLeft' $false) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'HideMeetNow' $true) {
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "HideSCAMeetNow" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "HideSCAMeetNow" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'HideSyncNotifications' $true) {
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSyncProviderNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSyncProviderNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableStartupSound' $true) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation" /v "DisableStartupSound" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableLockScreen' $false) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Personalization" /v "NoLockScreen" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableSleepOption' $false) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v "ShowSleepOption" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'MenuShowDelayZero' $true) {
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1
}

if (Test-TweakEnabled 'TakeOwnershipContextMenu' $false) {
    reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /ve /t REG_SZ /d "Take Ownership" > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /v "NoWorkingDirectory" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas\command" /f /ve /t REG_SZ /d 'powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -Command "& { param($p) takeown.exe /f $p; icacls.exe $p /grant administrators:F }" "%1"' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /ve /t REG_SZ /d "Take Ownership" > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /v "NoWorkingDirectory" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" /f /ve /t REG_SZ /d 'powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -Command "& { param($p) takeown.exe /f $p /r /d y; icacls.exe $p /grant administrators:F /t }" "%1"' > $null 2>&1
}

if (Test-TweakEnabled 'CmdAsAdminContextMenu' $false) {
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /f /ve /t REG_SZ /d "Open Command Prompt as Administrator" > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas\command" /f /ve /t REG_SZ /d 'PowerShell -windowstyle hidden -Command \"Start-Process cmd.exe -ArgumentList ''/s,/k,pushd,\"%V\"'' -Verb RunAs\"' > $null 2>&1
}

if (Test-TweakEnabled 'PhotoViewerAssociations' $true) {
    $photoViewerAssocs = @(
        @{ Ext = ".bmp";  ProgId = "PhotoViewer.FileAssoc.Bitmap" },
        @{ Ext = ".dib";  ProgId = "PhotoViewer.FileAssoc.Bitmap" },
        @{ Ext = ".gif";  ProgId = "PhotoViewer.FileAssoc.Tiff" },
        @{ Ext = ".jfif"; ProgId = "PhotoViewer.FileAssoc.JFIF" },
        @{ Ext = ".jpe";  ProgId = "PhotoViewer.FileAssoc.Jpeg" },
        @{ Ext = ".jpeg"; ProgId = "PhotoViewer.FileAssoc.Jpeg" },
        @{ Ext = ".jpg";  ProgId = "PhotoViewer.FileAssoc.Jpeg" },
        @{ Ext = ".png";  ProgId = "PhotoViewer.FileAssoc.Png" },
        @{ Ext = ".tif";  ProgId = "PhotoViewer.FileAssoc.Tiff" },
        @{ Ext = ".tiff"; ProgId = "PhotoViewer.FileAssoc.Tiff" },
        @{ Ext = ".wdp";  ProgId = "PhotoViewer.FileAssoc.Wdp" }
    )
    foreach ($pa in $photoViewerAssocs) {
        reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations" /f /v $pa.Ext /t REG_SZ /d $pa.ProgId > $null 2>&1
    }
}

# Japanese IME Privacy
if (Test-TweakEnabled 'DisableIMETelemetry' $true) {
    Write-Host "Configuring Japanese IME privacy opt-out..." -ForegroundColor Green
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1
}

# ============================================================================
# 11. Services & Component Optimization
# ============================================================================
# Service trims
$serviceConfigs = [ordered]@{
    "AJRouter"                                 = 4
    "AppVClient"                               = 4
    "AssignedAccessManagerSvc"                 = 4
    "CertPropSvc"                              = 4
    "CscService"                               = 4
    "DialogBlockingService"                    = 4
    "DiagTrack"                                = 4
    "diagnosticshub.standardcollector.service" = 4
    "dmwappushservice"                         = 4
    "DoSvc"                                    = 4
    "DPS"                                      = 4
    "DusmSvc"                                  = 4
    "edgeupdate"                               = 4
    "edgeupdatem"                              = 4
    "Fax"                                      = 4
    "GpuEnergyDrv"                             = 4
    "GraphicsPerfSvc"                          = 4
    "HomeGroupListener"                        = 4
    "HomeGroupProvider"                        = 4
    "icssvc"                                   = 4
    "InventorySvc"                             = 4
    "iphlpsvc"                                 = 4
    "lfsvc"                                    = 4
    "MapsBroker"                               = 4
    "NetTcpPortSharing"                        = 4
    "Ndu"                                      = 4
    "PcaSvc"                                   = 4
    "PhoneSvc"                                 = 4
    "RemoteRegistry"                           = 4
    "RetailDemo"                               = 4
    "SCardSvr"                                 = 4
    "ScDeviceEnum"                             = 4
    "SEMgrSvc"                                 = 4
    "SensorDataService"                        = 4
    "SensorService"                            = 4
    "SensrSvc"                                 = 4
    "SharedAccess"                             = 4
    "SharedRealitySvc"                         = 4
    "SmsRouter"                                = 4
    "SysMain"                                  = $(if (Test-TweakEnabled 'DisableSuperfetch' $true) { 4 } else { 2 })
    "TrkWks"                                   = 4
    "TroubleshootingSvc"                       = 4
    "WalletService"                            = 4
    "WarpJITSvc"                               = 4
    "WdiServiceHost"                           = 4
    "WdiSystemHost"                            = 4
    "wercplsupport"                            = 4
    "WerSvc"                                   = 4
    "wisvc"                                    = 4
    "WMPNetworkSvc"                            = 4
    "WpcMonSvc"                                = 4
    "WSAIFabricSvc"                            = 4
    "CDPSvc"                                   = 4
    "CDPUserSvc"                               = 4
    "WSearch"                                  = $(if ($keepSearchIndex -or -not (Test-TweakEnabled 'DisableWindowsSearchIndexing' $true)) { 2 } else { 4 })
    "XblAuthManager"                           = if ($keepXboxServices) { 3 } else { 4 }
    "XblGameSave"                              = if ($keepXboxServices) { 3 } else { 4 }
    "XboxGipSvc"                               = if ($keepXboxServices) { 3 } else { 4 }
    "XboxNetApiSvc"                            = if ($keepXboxServices) { 3 } else { 4 }
}

if (-not $keepBT) {
    $serviceConfigs["BthAvctpSvc"]          = 4
    $serviceConfigs["BluetoothUserService"] = 3
}

if ($disableWU -or (Test-TweakEnabled 'DisableWindowsUpdate' $false)) {
    $serviceConfigs["wuauserv"]             = 4
    $serviceConfigs["UsoSvc"]               = 4
    $serviceConfigs["WaaSMedicSVC"]         = 4
}

if ([bool]$script:activeTweakGroups['ServiceTrim']) {
    foreach ($svc in $serviceConfigs.GetEnumerator()) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$($svc.Key)" /f /v "Start" /t REG_DWORD /d $($svc.Value) > $null 2>&1
    }
}

# The services of the components the Advanced Debloat tab removes. These used to be
# printed in phase 09 and nothing else happened: the services stayed enabled, so the
# items did not do what the GUI promised. They are applied on their own, because the
# user asked for this component explicitly - they do not depend on the ServiceTrim group.
function Set-WinEaseServiceStartIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][int]$Start)
    & reg.exe query "HKLM\zSYSTEM\ControlSet001\Services\$Name" > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Service $Name is not in the image - nothing to set."
        return $false
    }
    & reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$Name" /f /v "Start" /t REG_DWORD /d $Start > $null 2>&1
    return $true
}

if (Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue) {
    # The services belong to the target itself and not to one engine: the binaries of the
    # Spooler, the Bluetooth stack, the Remote Desktop host and the BitLocker stack are
    # removed by the engine the user picked, but the services have to be disabled in any
    # case - otherwise the image keeps a service whose binary the Rust engine has just
    # deleted.
    $advServices = [ordered]@{}
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove Print Spooler (service + binary) [20-30MB]') {
        $advServices["Spooler"] = 4
        $advServices["PrintNotify"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove Bluetooth stack (service + binary) [20-40MB]') {
        $advServices["bthserv"] = 4
        $advServices["BthAvctpSvc"] = 4
        $advServices["BluetoothUserService"] = 3
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove Remote Desktop host (service + binary) [30-50MB]') {
        $advServices["TermService"] = 4
        $advServices["UmRdpService"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove touch/pen/ink components [20-30MB]') {
        $advServices["TabletInputService"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Physical: BitLocker (complete removal) [~30-50MB]') {
        $advServices["fvevc"] = 4
    }
    foreach ($svc in $advServices.GetEnumerator()) {
        Write-Host "  - Disabling service: $($svc.Key) (Advanced Debloat)" -ForegroundColor Cyan
        [void](Set-WinEaseServiceStartIfPresent -Name $svc.Key -Start $svc.Value)
    }
}

# Windows Defender Removal / Disable
if ($removeDefender -or (Test-TweakEnabled 'RemoveDefender' $false)) {
    Write-Host "Elevating offline registry DACLs for Defender keys via regini.exe..." -ForegroundColor Cyan
    $reginiLines = @(
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\WinDefend [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\MDCoreSvc [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\WdNisSvc [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\Sense [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\SecurityHealthService [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\wscsvc [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\webthreatdefsvc [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\webthreatdefusersvc [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\WdBoot [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\WdFilter [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\WdNisDrv [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\SgrmBroker [1 17]',
        '\Registry\Machine\zSYSTEM\ControlSet001\Services\SgrmAgent [1 17]',
        '\Registry\Machine\zSOFTWARE\Microsoft\Windows Defender\Features [1 17]'
    )
    $reginiFile = Join-Path -Path $env:TEMP -ChildPath "WinEase_regini_$([System.IO.Path]::GetRandomFileName()).txt"
    [System.IO.File]::WriteAllLines($reginiFile, $reginiLines, [System.Text.Encoding]::ASCII)
    & regini.exe $reginiFile > $null 2>&1
    Remove-Item -LiteralPath $reginiFile -Force -ErrorAction SilentlyContinue

    Write-Host "Disabling Windows Defender drivers & services offline in zSYSTEM..." -ForegroundColor Green

    # --- ELAM (Early Launch Anti-Malware) neutralization -------------------------------
    # WdBoot is an ELAM driver (Group = Early-Launch). ELAM drivers are loaded by the boot
    # loader before the kernel starts the anti-malware stack, so a plain Start=4 is not
    # always honoured: the driver is still picked up from the ELAM hive. Clearing the
    # "Early-Launch" group membership and the ELAM support flag takes the driver out of
    # the early-launch path entirely.
    foreach ($drv in @('WdBoot', 'WdFilter', 'WdNisDrv')) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$drv" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    }
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WdBoot" /v "SupportElamHive" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WdBoot" /v "Group" /f > $null 2>&1
    # WdFilter is an FSFilter anti-virus minifilter; drop it from the filter group as well
    # so no file-system filter instance is bound when the stack starts.
    reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\WdFilter" /v "Group" /f > $null 2>&1

    # --- Service key removal ------------------------------------------------------------
    # The service keys are deleted (not just disabled) so that a later CBS servicing pass
    # cannot re-enable them. Each operation is verified: the previous implementation
    # redirected every reg.exe call to "> $null 2>&1", so a failed delete (e.g. a key still
    # owned by TrustedInstaller) was indistinguishable from a successful one and the build
    # continued with Defender still registered.
    $defServices = @('WinDefend', 'MDCoreSvc', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc', 'webthreatdefsvc', 'webthreatdefusersvc', 'SgrmBroker', 'SgrmAgent', 'whesvc')
    $failedDefSvc = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $defServices) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
        reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc\TriggerInfo" /f > $null 2>&1
        reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc" /f > $null 2>&1
        # Verify the key is really gone instead of trusting the exit code of a silenced call.
        $null = & reg.exe query "HKLM\zSYSTEM\ControlSet001\Services\$svc" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $failedDefSvc.Add($svc)
        }
    }
    if ($failedDefSvc.Count -gt 0) {
        Write-Warning "  - Defender service keys still present after removal: $($failedDefSvc -join ', ')"
        Write-Warning "  - These services may be re-registered by CBS; the post-build verification in Phase 15 will flag this."
    } else {
        Write-Host "  - All $($defServices.Count) Defender service keys removed from the offline SYSTEM hive." -ForegroundColor Green
    }

    # --- Policies ------------------------------------------------------------------------
    # Tamper Protection must be off before the engine can be stopped or removed.
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Defender\Features" /v "TamperProtection" /t REG_DWORD /d 0 /f > $null 2>&1
    # DisableAntiSpyware no longer disables the engine on Windows 11 24H2+ (Microsoft removed
    # the behaviour), so it is kept only for legacy builds and the working policies below are
    # the actual mechanism.
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiSpyware" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiVirus" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableRealtimeMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableBehaviorMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableOnAccessProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableScanOnRealtimeEnable" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" /v "MpEngineEnableFileNameFiltering" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v "SubmitSamplesConsent" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v "SpynetReporting" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v "SpynetProtection" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates" /v "SignatureUpdateInterval" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "PUAProtection" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecurityHealth" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy" /f > $null 2>&1
}

# ============================================================================
# GUI tweak toggles (keys match $script:AllTweakDefs in WinEasebuilder.ps1)
# ============================================================================
# BypassNetworkRequirement: written together with BypassNRO in section 2 (Get-WinEaseBypassNROEnabled).
# It used to write the same OOBE\BypassNRO value here a second time, so switching BypassNRO off had no effect.

if (Test-TweakEnabled 'DisableAdvertisingId' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" /v "DisabledByGroupPolicy" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableAppPrivacy' $true) {
    foreach ($appPriv in @('LetAppsAccessLocation', 'LetAppsAccessMicrophone', 'LetAppsAccessContacts', 'LetAppsAccessCalendar', 'LetAppsAccessCallHistory', 'LetAppsAccessMessaging', 'LetAppsAccessAccountInfo')) {
        reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v $appPriv /t REG_DWORD /d 2 /f > $null 2>&1
    }
}

if (Test-TweakEnabled 'DisableDefenderSecurityCenter' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications" /v "DisableEnhancedNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray" /v "HideSystray" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableCortana' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortanaAboveLock" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableTimeline' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableActivityFeed" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableDiagnosticData' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DoNotShowFeedbackNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "LimitDiagnosticLogCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "LimitDumpCollection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DisableDiagnosticDataViewer" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Siuf\Rules" /v "NumberOfSIUFInPeriod" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Siuf\Rules" /v "NumberOfSIUFInPeriod" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'TuneMemoryAndPaging' $true) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "ClearPageFileAtShutdown" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'GamingNetworkTweaks' $true) {
    # Per-adapter TcpAckFrequency needs interface GUIDs that only exist online; these are the offline-safe parts
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NetworkThrottlingIndex" /t REG_DWORD /d 0xffffffff /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\MSMQ\Parameters" /v "TCPNoDelay" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableBackgroundApps' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v "LetAppsRunInBackground" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableGameDVR' $true) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR" /v "AllowGameDVR" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'DisableFastStartup' $false) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'TransparentShortcutOverlay' $false) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons" /v "29" /t REG_EXPAND_SZ /d "%SystemRoot%\System32\imageres.dll,-17" /f > $null 2>&1
}

if (Test-TweakEnabled 'OptimizeVisualEffects' $true) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAnimations" /t REG_DWORD /d 0 /f > $null 2>&1
}

if (Test-TweakEnabled 'CleanContextMenus' $true) {
    # Share, Give access to, Cast to Device
    foreach ($shellExt in @('{e2bf9676-5f8f-435c-97eb-11607a5bedf7}', '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}', '{7AD84985-87B4-4a16-BE58-8B72A5B390F7}')) {
        reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" /v $shellExt /t REG_SZ /d "" /f > $null 2>&1
    }
}

# Personalization unlock & watermark suppression
if ($bypassActivationRestrictions -or (Test-TweakEnabled 'BypassActivationRestrictions' $false)) {
    Write-Host "Applying Windows personalization unlock policies..." -ForegroundColor Green
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v "DisplayNotGenuine" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Personalization" /v "NoLockScreen" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v "NoChangingWallPaper" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v "NoChangingWallPaper" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "NoGenTicket" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "NotificationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
}

# OEM Information Branding
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "Manufacturer" /t REG_SZ /d "WinEase Project" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "SupportURL" /t REG_SZ /d "https://github.com/gh459/WinEase" /f > $null 2>&1

Write-Host "Registry tweaks applied successfully." -ForegroundColor Green

# ==============================================================================
# Helper Function: Save-WinEaseUnattendXml
# Strictly writes XmlDocument to disk with a single UTF-8 BOM, validates bytes,
# verifies via XmlDocument.Load, and checks pass attribute integrity.
# ==============================================================================
function Save-WinEaseUnattendXml {
    param(
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlDocument]$XmlDocument,
        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )
    $destDir = Split-Path -Path $DestinationPath -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    $xwSettings = New-Object System.Xml.XmlWriterSettings
    $xwSettings.Indent = $true
    $xwSettings.Encoding = $utf8WithBom
    $xwSettings.OmitXmlDeclaration = $false

    $fs = [System.IO.File]::Create($DestinationPath)
    try {
        $xw = [System.Xml.XmlWriter]::Create($fs, $xwSettings)
        try {
            $XmlDocument.Save($xw)
        } finally {
            $xw.Dispose()
        }
    } finally {
        $fs.Dispose()
    }

    $bytes = [System.IO.File]::ReadAllBytes($DestinationPath)
    if ($bytes.Length -lt 4) {
        throw "XML save verification failed: File too short ($($bytes.Length) bytes) at $($DestinationPath)"
    }
    if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "XML save verification failed: Missing UTF-8 BOM at $($DestinationPath)"
    }
    if ($bytes.Length -ge 6 -and $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF) {
        throw "XML save verification failed: Double UTF-8 BOM detected at $($DestinationPath)"
    }
    if ($bytes[3] -ne 0x3C) {
        throw "XML save verification failed: First character after BOM is not '<' (0x$($bytes[3].ToString('X2'))) at $($DestinationPath)"
    }

    try {
        $verifyDoc = New-Object System.Xml.XmlDocument
        $verifyDoc.Load($DestinationPath)
    } catch {
        throw "XML save verification failed: XmlDocument.Load failed for $($DestinationPath) : $_"
    }

    $settingsNodes = $verifyDoc.SelectNodes("//*[local-name()='settings']")
    foreach ($s in $settingsNodes) {
        $passAttr = $s.GetAttribute("pass")
        if ([string]::IsNullOrWhiteSpace($passAttr)) {
            throw "XML save verification failed: <settings> node missing required 'pass' attribute in $($DestinationPath)"
        }
    }

    Write-Host "  [XML Verified] Saved $($DestinationPath) (Single UTF-8 BOM, valid XML DOM, pass attributes intact)" -ForegroundColor Green
}

# M2: User extension actions (Registry)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType Registry -ScratchDir $scratchDir -DryRun:$DryRun | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}
