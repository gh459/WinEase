# Phase 10: 10-registry
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 10. Load Registry Hives and Apply Optimizations
Write-Host "Loading offline registry hives..." -ForegroundColor Cyan
$systemHive    = "$scratchDir\Windows\System32\config\SYSTEM"
$softwareHive  = "$scratchDir\Windows\System32\config\SOFTWARE"
$defaultHive   = "$scratchDir\Windows\System32\config\default"
$componentsHive= "$scratchDir\Windows\System32\config\COMPONENTS"
$ntuserHive    = "$scratchDir\Users\Default\ntuser.dat"

# Abort on any load failure: otherwise every reg.exe add below silently fails and an un-tweaked
# image would be reported as a successful build. Loaded hives are unloaded by the outer finally block.
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

# Detect and display target Windows build info (e.g. Windows 11 26H2 Build 26300.9457)
try {
    $targetProductName = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ProductName 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetDisplayVer  = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetBuildNum    = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetUBR         = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR 2>$null | Select-String -Pattern 'REG_DWORD\s+0x([0-9a-fA-F]+)' | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
    if ($targetProductName) {
        Write-Host "Target Image OS: $targetProductName (Version: $targetDisplayVer, Build: $targetBuildNum.$targetUBR)" -ForegroundColor Green
    }
} catch {}

Write-Host "Applying Setup & Hardware requirement bypasses..." -ForegroundColor Green
$labConfigKeys = @(
    'BypassCPUCheck',
    'BypassRAMCheck',
    'BypassSecureBootCheck',
    'BypassStorageCheck',
    'BypassTPMCheck',
    'BypassDiskCheck'
)
foreach ($key in $labConfigKeys) {
    reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1

Write-Host "Disabling Sponsored Apps & Cloud Content..." -ForegroundColor Green
$cdmSettings = @(
    'ContentDeliveryAllowed',
    'FeatureManagementEnabled',
    'OemPreInstalledAppsEnabled',
    'PreInstalledAppsEnabled',
    'PreInstalledAppsEverEnabled',
    'SilentInstalledAppsEnabled',
    'SoftLandingEnabled',
    'SubscribedContentEnabled',
    'SubscribedContent-310093Enabled',
    'SubscribedContent-338387Enabled',
    'SubscribedContent-338388Enabled',
    'SubscribedContent-338389Enabled',
    'SubscribedContent-338393Enabled',
    'SubscribedContent-353694Enabled',
    'SubscribedContent-353696Enabled',
    'SubscribedContent-353698Enabled',
    'SystemPaneSuggestionsEnabled'
)
foreach ($setting in $cdmSettings) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $setting /t REG_DWORD /d 0 /f > $null 2>&1
}
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableConsumerAccountStateContent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v "DisablePushToInstall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v "DontOfferThroughWUAU" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v "ConfigureStartPins" /t REG_SZ /d "{\`"pinnedList\`": [{}]}" /f > $null 2>&1

# OOBE & Local Accounts (Resolves Issue #15)
Write-Host "Enabling Local Account bypass on OOBE..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v "ShippedWithReserves" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\EnhancedStorageDevices" /v "TCGSecurityActivationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Japanese 106/109 Keyboard Configuration (Prevents English 101/104 misdetection)
if ($setJapaneseKeyboard) {
    Write-Host "Configuring Japanese 106/109 keyboard layout..." -ForegroundColor Green
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "LayerDriver JPN" /t REG_SZ /d "kbd106.dll" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardIdentifier" /t REG_SZ /d "PCAT_106KEY" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardType" /t REG_DWORD /d 7 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardSubtype" /t REG_DWORD /d 2 /f > $null 2>&1
}

reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v "ChatIcon" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1

# Setup & Winlogon / Blank Password / PowerShell Execution Policy tweaks
# LimitBlankPasswordUse stays 1: blank-password AutoLogon works locally, network logons are refused
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Lsa" /v "LimitBlankPasswordUse" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "AutoAdminLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultUserName" /t REG_SZ /d "$UserName" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /f /v "DefaultPassword" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "ForceAutoLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowDomainDelayLock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "FilterAdministratorToken" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "EnableScripts" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1

# Edge Uninstall Registry cleanup
reg.exe delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f > $null 2>&1
reg.exe delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f > $null 2>&1

# Telemetry
Write-Host "Disabling Diagnostics & Telemetry..." -ForegroundColor Green
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v "TailoredExperiencesWithDiagnosticDataEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v "HasAccepted" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitInkCollection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitTextCollection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1

# Copilot & Bloatware Prevention
Write-Host "Disabling Copilot, DevHome, and Teams auto-install..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "HubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v "DisableInstallation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v "PreventRun" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Cross-Device / Mobile Devices / Resume & Windows Backup
Write-Host "Disabling Mobile Devices / Cross-Device Resume & Windows Backup..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableCdp" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableMmx" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowCrossDeviceClipboard" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "UploadUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "PublishUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableSoftLanding" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsSpotlightFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Backup" /v "DisableCloudBackup" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableBackupRestore" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSync" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSyncUserOverride" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1

# Accessibility Hotkey & Feature Suppressions (Voice Access, Live Captions, Narrator, StickyKeys)
Write-Host "Configuring Accessibility & Assistive hotkey suppressions..." -ForegroundColor Green
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Narrator" /v "WinEnterLaunchNarrator" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Narrator" /v "NoStartNarratorShortcut" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Narrator" /v "WinEnterLaunchNarrator" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Narrator" /v "NoStartNarratorShortcut" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\VoiceAccess" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\VoiceAccess" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\LiveCaptions" /v "LiveCaptionsDesktopEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\LiveCaptions" /v "LiveCaptionsDesktopEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows NT\CurrentVersion\Accessibility" /f /v "Configuration" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows NT\CurrentVersion\Accessibility" /f /v "Configuration" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "26" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "26" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "34" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "34" /f > $null 2>&1

if (-not $keepXboxServices) {
    # Disable Xbox Game Bar & GameDVR
    Write-Host "Disabling Xbox Game Bar & GameDVR..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR" /v "AllowGameDVR" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" /v "value" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_DXGIHonorFSEWindowsCompatible" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_DXGIHonorFSEWindowsCompatible" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_EFSEFeatureFlags" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_EFSEFeatureFlags" /t REG_DWORD /d 0 /f > $null 2>&1
} else {
    Write-Host "Preserving Xbox Game Bar & GameDVR (-KeepXboxServices)..." -ForegroundColor Green
}

# IFEO Debugger redirect for non-OOBE background processes (OSK/Narrator/Magnifier blocked safely in FirstLogon after OOBE completes)
$blockedExes = @(
    "CrossDeviceResume.exe",
    "WindowsBackupClient.exe",
    "WebExperienceHostApp.exe",
    "VoiceAccess.exe",
    "Livecaptions.exe",
    "OneDriveSetup.exe"
)
# SearchHost.exe hosts the Start/taskbar search UI; only block it when search indexing is not kept
if (-not $keepSearchIndex) {
    $blockedExes += "SearchHost.exe"
}
if (-not $keepXboxServices) {
    $blockedExes += @("GameBar.exe", "GameBarFTServer.exe", "GameBarPresenceWriter.exe")
}
if ($removeDefender) {
    $blockedExes += @(
        "MsMpEng.exe",
        "NisSrv.exe",
        "SecurityHealthService.exe",
        "SecurityHealthSystray.exe"
    )
}
foreach ($exe in $blockedExes) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe" /v "Debugger" /t REG_SZ /d "rundll32.exe" /f > $null 2>&1
}

# CRITICAL: smartscreen.exe MUST NEVER have an IFEO Debugger set!
# Windows Shell invokes smartscreen.exe -Embedding via COM for binary reputation checks.
# Setting an IFEO Debugger causes RunDLL error 'エントリがありません: -Embedding'
# and fatally blocks ALL .exe files (Task Manager, Windows Tools, apps) from launching.
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe" /f > $null 2>&1

# --- CrossDevice & SearchHost Offline Suppression ---
# CrossDevice / リモート再開の無効化
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceResume" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "DisableResume" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableCdp" /t REG_DWORD /d 0 /f > $null 2>&1
# --- CrossDevice & SearchHost Offline Suppression ---
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\CDPUserSvc" /v "UserServiceFlags" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\CDPSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\CDPUserSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "DisableCrossDeviceResume" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowSearchHostPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Search" /v "AllowSearchHostPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowSearchToUseLocation" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCloudSearch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1


# Scheduled Tasks Cleanup (Path fixed - no hardcoded C:)
Write-Host "Cleaning up scheduled telemetry tasks..." -ForegroundColor Cyan
$tasksPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Tasks"
$telemetryAndMemTasks = @(
    "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "Microsoft\Windows\Application Experience\StartupAppTask",
    "Microsoft\Windows\Customer Experience Improvement Program",
    "Microsoft\Windows\Chkdsk\Proxy",
    "Microsoft\Windows\Windows Error Reporting\QueueReporting",
    "Microsoft\XblGameSave",
    "Microsoft\Windows\DiskDiagnostic",
    "Microsoft\Windows\Feedback",
    "Microsoft\Windows\FileHistory",
    "Microsoft\Windows\Maintenance\WinSAT",
    "Microsoft\Windows\PI\Sqm-Tasks",
    "Microsoft\Windows\Power Efficiency Diagnostics",
    "Microsoft\Windows\Shell\FamilySafetyMonitor",
    "Microsoft\Windows\Shell\FamilySafetyRefreshTask",
    "Microsoft\Windows\Registry\RegIdleBackup",
    "Microsoft\Windows\Diagnosis",
    "Microsoft\Windows\MemoryDiagnostic",
    "Microsoft\Windows\DiskFootprint",
    "Microsoft\Windows\Maps",
    "Microsoft\Windows\Speech",
    "Microsoft\Windows\Defrag\ScheduledDefrag",
    "Microsoft\Windows\Windows Filtering Platform",
    "Microsoft\Windows\Device Information",
    "Microsoft\Windows\NetTrace",
    "Microsoft\Windows\WindowsAI\RecallConfiguration",
    "Microsoft\Windows\WindowsAI\RecallPipeline",
    "Microsoft\Windows\Autochk\Proxy",
    "Microsoft\Windows\CrossDevice\CrossDeviceResumeTask",
    "Microsoft\Windows\CrossDevice\CrossDeviceTask",
    "Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTask",
    "Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskLogon",
    "Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskNetwork",
    "Microsoft\Windows\Application Experience\MareBackup",
    "Microsoft\Windows\Application Experience\PcaPatchDbTask"
)
foreach ($t in $telemetryAndMemTasks) {
    Remove-Item -LiteralPath "$tasksPath\$t" -Recurse -Force -ErrorAction SilentlyContinue
}

# Windows Update (optional)
if ($disableWU) {
    Write-Host "Disabling Windows Update..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DoNotConnectToWindowsUpdateInternetLocations" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DisableWindowsUpdateAccess" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "NoAutoUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
}

# ============================================================================
# Windows Defender & Security Complete Removal (ionuttbara/windows-defender-remover integration)
# ============================================================================
if ($removeDefender) {
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
    $reginiFile = Join-Path -Path $env:TEMP -ChildPath "nano11_regini_$([System.IO.Path]::GetRandomFileName()).txt"
    [System.IO.File]::WriteAllLines($reginiFile, $reginiLines, [System.Text.Encoding]::ASCII)
    & regini.exe $reginiFile > $null 2>&1
    Remove-Item -LiteralPath $reginiFile -Force -ErrorAction SilentlyContinue

    Write-Host "Disabling Windows Defender drivers & services offline in zSYSTEM..." -ForegroundColor Green

    # 1. Disable Early Launch Anti-Malware (ELAM) and Filesystem Minifilter Drivers (Start = 4: Disabled)
    $defDrivers = @('WdBoot', 'WdFilter', 'WdNisDrv')
    foreach ($drv in $defDrivers) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$drv" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    }

    # 2. Disable all Defender user-mode services and strip TriggerInfo
    $defServices = @(
        'WinDefend',
        'MDCoreSvc',
        'WdNisSvc',
        'Sense',
        'SecurityHealthService',
        'wscsvc',
        'webthreatdefsvc',
        'webthreatdefusersvc',
        'SgrmBroker',
        'SgrmAgent',
        'whesvc'   # Windows Health and Enhanced Security (Defender Remover integration)
    )
    foreach ($svc in $defServices) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
        reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc\TriggerInfo" /f > $null 2>&1
        # Defender Remover (ionuttbara) integration: delete service keys entirely for thorough removal
        reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$svc" /f > $null 2>&1
    }

    # 3. Disable Tamper Protection offline
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Defender\Features" /v "TamperProtection" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Defender\Features" /v "TamperProtectionSource" /t REG_DWORD /d 0 /f > $null 2>&1

    # 4. Enforce group policy restrictions
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiSpyware" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiVirus" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableRealtimeMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableBehaviorMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableOnAccessProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableIOAVProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray" /v "HideSystray" /t REG_DWORD /d 1 /f > $null 2>&1

    # 5. Remove SecurityHealthSystray autorun entry
    reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecurityHealth" /f > $null 2>&1

    # 6. Remove shell context menu extensions
    reg.exe delete "HKLM\zSOFTWARE\Classes\CLSID\{09A47860-11B0-4DA5-AFA5-26D86198A780}" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1

    # 7. Deprovision SecHealthUI (Windows Security) in AppxAllUserStore
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy" /f > $null 2>&1
}

# ============================================================================
# eclean.gg Comprehensive Windows Optimization (Gaming Latency, Power, Memory & Disk)
# ============================================================================
Write-Host "Applying eclean.gg advanced system optimizations (Low-latency Gaming, Power & DPC)..." -ForegroundColor Cyan

# 1. DPC & Low-Latency Thread Scheduling
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Kernel" /v "ThreadDpcEnable" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 38 /f > $null 2>&1

# 2. CPU Core Parking & Hybrid Architecture (P-Core / E-Core) Optimization (eclean.gg / AtlasOS)
$powerPath = "HKLM\zSOFTWARE\Policies\Microsoft\Power\PowerSettings"
reg.exe add "$powerPath\0cc5b647-c1df-4637-891a-dec35c318583" /v "ACSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\0cc5b647-c1df-4637-891a-dec35c318583" /v "DCSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\ea062031-0e34-4ff1-9b6d-eb1059334028" /v "ACSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\ea062031-0e34-4ff1-9b6d-eb1059334028" /v "DCSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1

# Energy Performance Preference (EPP 0 = Max Performance)
reg.exe add "$powerPath\36687f9e-e3a5-4dbf-b1dc-15eb381c6863" /v "ACSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687f9e-e3a5-4dbf-b1dc-15eb381c6863" /v "DCSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687e9e-e3a5-4dbf-b1dc-15eb31c7448b" /v "ACSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687e9e-e3a5-4dbf-b1dc-15eb31c7448b" /v "DCSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1

# Hybrid P-Core Priority Scheduling (Keep high-priority / game threads on high-performance cores)
reg.exe add "$powerPath\93b22d1d-9513-4bc7-ad42-1e967313f2e4" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "$powerPath\bae08b81-2d5e-4688-ad6a-13243356654b" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "$powerPath\be337238-0d82-4146-a960-4f3749d470c7" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1

# 3. Disk, NVMe & Memory Management (eclean.gg Deep Clean)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisable8dot3NameCreation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisableLastAccessUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "DontVerifyRandomDrivers" /t REG_DWORD /d 1 /f > $null 2>&1

# 4. Network & TCP/IP Low-Latency (Nagle's Algorithm Disabled, Instant ACK)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "TcpTimedWaitDelay" /t REG_DWORD /d 30 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "MaxUserPort" /t REG_DWORD /d 65534 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "DefaultTTL" /t REG_DWORD /d 64 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "EnableICMPRedirect" /t REG_DWORD /d 0 /f > $null 2>&1

# MMCSS (Multimedia Class Scheduler Service)
Write-Host "Applying System Performance & Latency optimizations..." -ForegroundColor Green
if ($keepAudioTweaks -or $dawMode) {
    Write-Host "  [Audio DAW] Configuring low-latency Pro Audio MMCSS task profile..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Priority" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
}
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NoLazyMode" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "AlwaysOn" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NetworkThrottlingIndex" /t REG_DWORD /d 4294967295 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "SystemResponsiveness" /t REG_DWORD /d 0 /f > $null 2>&1
if ($mmcssGaming) {
    Write-Host "  [Gaming] Configuring Games MMCSS task profile (-MMCSSGaming)..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 6 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Affinity" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1
}

# SvcHost RAM consolidation & Service Timeout
# 67108864 (64GB) groups services into shared svchost processes, preventing 70-90 individual svchost instances and saving 500MB-800MB RAM
if ($radicalRAM) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "SvcHostSplitThresholdInKB" /t REG_DWORD /d 67108864 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "ServicesPipeTimeout" /t REG_DWORD /d 30000 /f > $null 2>&1

# Kernel Memory Management (Radical RAM Optimization & Page Combining)
if ($radicalRAM) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePageCombining" /t REG_DWORD /d 0 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1
$pagingExecutiveVal = if ($noKernelPaging) { 1 } else { 0 }
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /f /v "DisablePagingExecutive" /t REG_DWORD /d $pagingExecutiveVal > $null 2>&1

# CPU Speculative Execution Mitigations (Spectre / Meltdown toggle: -DisableCPUMitigations)
if ($disableCPUMitigations -or $script:activeTweakGroups['CpuMitigations']) {
    Write-Host "  [SECURITY WARNING] Disabling CPU speculative execution mitigations (FeatureSettingsOverride=3)..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverride" /t REG_DWORD /d 3 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverrideMask" /t REG_DWORD /d 3 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "ClearPageFileAtShutdown" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnablePrefetcher" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnableSuperfetch" /t REG_DWORD /d 0 /f > $null 2>&1

# Unified Background System Services Configuration (Start: 4 = Disabled, 3 = Demand/Manual)
Write-Host "Configuring system services for performance and radical RAM reduction..." -ForegroundColor Green
$serviceConfigs = [ordered]@{
    # --- Disabled Background Services (Start = 4: Completely stopped, zero memory overhead) ---
    "AJRouter"                                 = 4  # AllJoyn Router Service
    "AppVClient"                               = 4  # Microsoft Application Virtualization Client
    "AssignedAccessManagerSvc"                 = 4  # Assigned Access Manager
    "CertPropSvc"                              = 4  # Certificate Propagation
    "CscService"                               = 4  # Offline Files
    "DialogBlockingService"                    = 4  # Dialog Blocking Service
    "DiagTrack"                                = 4  # Connected User Experiences and Telemetry
    "diagnosticshub.standardcollector.service" = 4  # Diagnostics Hub Collector
    "dmwappushservice"                         = 4  # WAP Push Message Routing Service
    "DoSvc"                                    = 4  # Delivery Optimization
    "DPS"                                      = 4  # Diagnostic Policy Service
    "DusmSvc"                                  = 4  # Data Usage Monitoring
    "edgeupdate"                               = 4  # Microsoft Edge Update Service
    "edgeupdatem"                              = 4  # Microsoft Edge Update Service
    "Fax"                                      = 4  # Fax Service
    "GpuEnergyDrv"                             = 4  # GPU Energy Driver
    "GraphicsPerfSvc"                          = 4  # Graphics Performance Monitor Service
    "HomeGroupListener"                        = 4  # HomeGroup Listener
    "HomeGroupProvider"                        = 4  # HomeGroup Provider
    "icssvc"                                   = 4  # Mobile Hotspot Service
    "InventorySvc"                             = 4  # Device Association / Inventory Service
    "iphlpsvc"                                 = 4  # IP Helper (IPv6 6to4/ISATAP tunnels)
    "lfsvc"                                    = 4  # Geolocation Service
    "MapsBroker"                               = 4  # Downloaded Maps Manager
    "NetTcpPortSharing"                        = 4  # Net.Tcp Port Sharing Service
    "Ndu"                                      = 4  # Network Data Usage Monitoring (Prevents non-paged pool memory leak)
    "PcaSvc"                                   = 4  # Program Compatibility Assistant
    "PhoneSvc"                                 = 4  # Phone Service
    "PrintNotify"                              = 4  # Print Spooler Notification Service
    "RemoteRegistry"                           = 4  # Remote Registry
    "RetailDemo"                               = 4  # Retail Demo Service
    "SCardSvr"                                 = 4  # Smart Card Service
    "ScDeviceEnum"                             = 4  # Smart Card Device Enumeration Service
    "SEMgrSvc"                                 = 4  # Payments and NFC/SE Manager
    "SensorDataService"                        = 4  # Sensor Data Service
    "SensorService"                            = 4  # Sensor Service
    "SensrSvc"                                 = 4  # Sensor Monitoring Service
    "SharedAccess"                             = 4  # Internet Connection Sharing
    "SharedRealitySvc"                         = 4  # Spatial Data / Mixed Reality Service
    "SmsRouter"                                = 4  # SMS Router
    "SysMain"                                  = 4  # SuperFetch / RAM pre-caching
    "TrkWks"                                   = 4  # Distributed Link Tracking Client
    "TroubleshootingSvc"                       = 4  # Recommended Troubleshooting Service
    "WalletService"                            = 4  # Wallet Service
    "WarpJITSvc"                               = 4  # WARP JIT Service
    "WdiServiceHost"                           = 4  # Diagnostic Service Host
    "WdiSystemHost"                            = 4  # Diagnostic System Host
    "wercplsupport"                            = 4  # Problem Reports Control Panel Support
    "WerSvc"                                   = 4  # Windows Error Reporting Service
    "wisvc"                                    = 4  # Windows Insider Service
    "WMPNetworkSvc"                            = 4  # Windows Media Player Network Sharing
    "WpcMonSvc"                                = 4  # Parental Controls
    "WSAIFabricSvc"                            = 4  # Windows Subsystem for Android Fabric Service
    "WSearch"                                  = $(if ($keepSearchIndex) { 2 } else { 4 })  # Windows Search Indexer (2=Auto, 4=Disabled)
    "XblAuthManager"                           = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Auth Manager
    "XblGameSave"                              = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Game Save
    "XboxGipSvc"                               = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Accessory Management Service
    "XboxNetApiSvc"                            = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Networking Service
    "CDPSvc"                                   = 4  # Connected Devices Platform Service (Disabled)
    "CDPUserSvc"                               = 4  # Connected Devices Platform User Service (Disabled)

    # --- Demand Start Services (Start = 3: Manual, runs on demand only - protects LogonUI, DirectWrite & Per-User sessions) ---
    "AppHostSvc"                               = 3  # Application Host Helper
    "AxInstSV"                                 = 3  # ActiveX Installer
    "BcastDVRUserService"                      = 3  # GameDVR and Broadcast User Service (Per-user template)
    "BDESVC"                                   = 3  # BitLocker Drive Encryption Service
    "CaptureService"                           = 3  # Screen / Camera capture broker
    "DevQueryBroker"                           = 3  # Device Setup / Query Broker
    "DeviceInstall"                            = 3  # Device Install Service
    "DisplayEnhancementService"                = 3  # Display Enhancement Service
    "DmEnrollmentSvc"                          = 3  # Device Management Enrollment
    "DsSvc"                                    = 3  # Data Sharing Service
    "DsmSvc"                                   = 3  # Device Setup Manager
    "EapHost"                                  = 3  # Extensible Authentication Protocol
    "EFS"                                      = 3  # Encrypting File System
    "EntAppSvc"                                = 3  # Enterprise App Management
    "FDResPub"                                 = 3  # Function Discovery Resource Publication
    "FontCache"                                = 3  # Windows Font Cache Service (Demand-start prevents DirectWrite LogonUI hang)
    "FontCache3.0.0.0"                         = 3  # WPF Font Cache Service (Demand-start prevents XAML/DirectWrite hang)
    "FrameServer"                              = 3  # Windows Camera Frame Server
    "IEEtwCollectorService"                    = 3  # Internet Explorer ETW Collector
    "IKEEXT"                                   = 3  # IKE and AuthIP IPsec Keying Modules
    "InstallService"                           = 3  # Microsoft Store Install Service
    "IpxlatCfgSvc"                             = 3  # IP Translation Configuration Service
    "KtmRm"                                    = 3  # KtmRm for Distributed Transaction Coordinator
    "LanmanServer"                             = 3  # Server / SMB File Sharing
    "LicenseManager"                           = 3  # Windows License Manager
    "LxpSvc"                                   = 3  # Language Experience Service
    "McpManagementService"                     = 3  # Media Control Platform
    "MessagingService"                         = 3  # Messaging Service (Per-user template)
    "MixedRealityOpenXRSvc"                    = 3  # Mixed Reality OpenXR Service
    "MSDTC"                                    = 3  # Distributed Transaction Coordinator
    "MSiSCSI"                                  = 3  # Microsoft iSCSI Initiator
    "NaturalAuthentication"                    = 3  # Companion Device Authentication
    "NcaSvc"                                   = 3  # Network Connectivity Assistant
    "NcbService"                               = 3  # Network Connection Broker
    "NcdAutoSetup"                             = 3  # Network Connected Devices Auto-Setup
    "Netlogon"                                 = 3  # Netlogon
    "Netman"                                   = 3  # Network Connections
    "NetSetupSvc"                              = 3  # Network Setup Service
    "NgcCtnrSvc"                               = 3  # Passport Container Service
    "OneSyncSvc"                               = 3  # Sync Host (Per-user template)
    "PimIndexMaintenanceSvc"                   = 3  # Contact Data Indexing (Per-user template)
    "SCPolicySvc"                              = 3  # Smart Card Removal Policy
    "ShellHWDetection"                         = 3  # Shell Hardware Detection
    "Spooler"                                  = 3  # Print Spooler (Demand/Manual start, integrated from Winhancements)
    "stisvc"                                   = 3  # Windows Image Acquisition
    "svsvc"                                    = 3  # Spot Verifier
    "TabletInputService"                       = 3  # Touch Keyboard and Handwriting Panel
    "TapiSrv"                                  = 3  # Telephony
    "TokenBroker"                              = 3  # Web Account Manager
    "UnistoreSvc"                              = 3  # User Data Storage (Per-user template)
    "UserDataSvc"                              = 3  # User Data Access (Per-user template)
    "VaultSvc"                                 = 3  # Credential Manager
    "WbioSrvc"                                 = 3  # Windows Biometric Service (Hello/Fingerprint on demand)
    "WpnService"                               = 3  # Windows Push Notifications System Service (Protects Explorer taskbar initialization)
    "WpnUserService"                           = 3  # Push Notifications User Service (Per-user template)
}

# Apply conditional service configurations
if (-not $keepBT) {
    $serviceConfigs["BthAvctpSvc"]          = 4  # Audio/Video Control Transport Protocol
    $serviceConfigs["BluetoothUserService"] = 3  # Bluetooth User Support Service (Demand-start to preserve per-user integrity)
}
if ($disableWU) {
    $serviceConfigs["wuauserv"]             = 4  # Windows Update
    $serviceConfigs["UsoSvc"]               = 4  # Update Orchestrator Service
    $serviceConfigs["WaaSMedicSVC"]         = 4  # Windows Update Medic Service
}

# Windows Search disable hardening (④ review fix):
# The Windows Search disable option previously wrote Start=4 only to ControlSet001.
# Cover alternate control sets and strip DelayedAutoStart so no path re-enables the indexer,
# and log one explicit confirmation line. Online enforcement happens in FirstLogon.ps1 via
# disable-search.flag (staged below in Phase 11).
if (-not $keepSearchIndex) {
    foreach ($csKey in @('ControlSet001', 'ControlSet002', 'ControlSet006')) {
        reg.exe add "HKLM\zSYSTEM\$csKey\Services\WSearch" /f /v "Start" /t REG_DWORD /d 4 > $null 2>&1
        reg.exe delete "HKLM\zSYSTEM\$csKey\Services\WSearch" /v "DelayedAutoStart" /f > $null 2>&1
    }
    Write-Host "Windows Search disabled offline (WSearch Start=4 on all control sets + SearchHost IFEO + web-search policies)" -ForegroundColor Green
}

if (-not ($script:activeTweakGroups -and $script:activeTweakGroups.Contains('ServiceTrim') -and (-not $script:activeTweakGroups['ServiceTrim']))) {
    foreach ($svc in $serviceConfigs.GetEnumerator()) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$($svc.Key)" /f /v "Start" /t REG_DWORD /d $($svc.Value) > $null 2>&1
    }
}

# ============================================================================
# Radical RAM: Per-User Services Suppression & Background Process Elimination
# ============================================================================
if ($radicalRAM) {
    Write-Host "Applying Radical RAM footprint minimization (Widgets, SearchHost/WebView2, CrossDevice, Services)..." -ForegroundColor Green

    # 1. Windows 11 Widgets (Widgets.exe, WebWidget) Policy Suppression
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Widgets" /v "AllowWidgets" /t REG_DWORD /d 0 /f > $null 2>&1

    # 2. SearchHost & Web Search / WebView2 Suppression (Stops 340MB msedgewebview2.exe background instances)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "EnableDynamicContentInWSB" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCloudSearch" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowSearchToUseLocation" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWebOverMeteredConnections" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "AllowCortana" /t REG_DWORD /d 0 /f > $null 2>&1

    # 3. Cross-Device Experience & Resume Suppression (Stops 47MB CrossDeviceResume.exe)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableCdp" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableMmx" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\CDPSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\CDPUserSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1

    # 4. SmartScreen Complete Policy Suppression (Clean policy-based disabling without breaking COM / .exe execution)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableSmartScreen" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "SmartScreenEnabled" /t REG_SZ /d "Off" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "SmartScreenEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "SmartScreenPuaEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter" /v "EnabledV9" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen" /v "ConfigureAppInstallControlEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen" /v "ConfigureAppInstallControl" /t REG_SZ /d "Anywhere" /f > $null 2>&1

    # 5. Non-Essential Background Services Optimization
    # TrkWks (Distributed Link Tracking) - Not needed on single-user/gaming PCs
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\TrkWks" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    # BITS (Background Intelligent Transfer) - Revert to Manual demand start
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\BITS" /v "Start" /t REG_DWORD /d 3 /f > $null 2>&1

    # 6. Edge & WebView2 Pre-Launch & Background Memory Elimination
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "WebWidgetIsEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" /v "AllowPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1

    # 7. User Hive (zDEFAULT / zNTUSER) Bing Search & CrossDevice Defaults
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration" /v "IsResumeAllowed" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration" /v "IsResumeAllowed" /t REG_DWORD /d 0 /f > $null 2>&1

    # 8. Complete Background AppX Execution Block (Saves ~150MB across background broker hosts)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v "LetAppsRunInBackground" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

    # 9. DWM & Rendering Footprint Minimization (Saves ~80MB, keeps DirectWrite font smoothing for readability)
    if (-not ($script:activeTweakGroups -and $script:activeTweakGroups.Contains('VisualFX') -and (-not $script:activeTweakGroups['VisualFX']))) {
        reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
        reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
        reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
        reg.exe add "HKLM\zNTUSER\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
        reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
        reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
        reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "FontSmoothingType" /t REG_DWORD /d 2 /f > $null 2>&1
    }

    # 10. VBS / HVCI (Virtualization-Based Security / Memory Integrity) Elimination (Saves ~150-300MB reserved RAM)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "EnableVirtualizationBasedSecurity" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1

    # 11. Additional Push & Background Sync Services Suppression (Keep WpnService=3 to protect Explorer taskbar init)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WpnService" /v "Start" /t REG_DWORD /d 3 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WpnUserService" /v "Start" /t REG_DWORD /d 3 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WpnUserService" /v "UserServiceFlags" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\PushToInstall" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    if ($disableWU) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\DoSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    }
}

# WebDAV File Size Limit (4GB)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WebClient\Parameters" /v "FileSizeLimitInBytes" /t REG_DWORD /d 4294967295 /f > $null 2>&1

# Block UEFI WPBT execution (prevent OEM bloatware persistence)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d 1 /f > $null 2>&1

# Detailed BSOD Stop Codes (Disable smiley emoticon, show technical crash info)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisplayParameters" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisableEmoticon" /t REG_DWORD /d 1 /f > $null 2>&1

# eclean & AtlasOS - Fault Tolerant Heap (FTH) Disabled (Eliminates crash mitigation overhead for games/apps)
reg.exe add "HKLM\zSOFTWARE\Microsoft\FTH" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1

# eclean & AtlasOS - Program Compatibility Assistant (PCA) Complete Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisablePCA" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableEngine" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableInventory" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AITEnable" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableUAR" /t REG_DWORD /d 1 /f > $null 2>&1

# eclean & AtlasOS - Delivery Optimization (P2P Background Upload) Disabled
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v "DODownloadMode" /t REG_DWORD /d 0 /f > $null 2>&1

# Hibernate & Fast Startup Configuration (HibernateMode = Off / Reduced / Keep)
switch ($hibernateMode.ToLower()) {
    'off' {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HibernateEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    }
    'reduced' {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HibernateEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HiberFileSizePercent" /t REG_DWORD /d 20 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
    }
    default {
        # Keep OS default or disable fast startup for AtlasOS longevity
        if ($atlasReviOSMode) {
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
        }
    }
}

# Full-Screen Optimizations (DisableFSE: Mode 2 = Fullscreen Exclusive priority)
if ($disableFSE) {
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
}

# DNS Client LLMNR & Multicast Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "EnableMulticast" /t REG_DWORD /d 0 /f > $null 2>&1

# Enable Win32 Long Paths
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "LongPathsEnabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Verbose boot/shutdown/logon status
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "verbosestatus" /t REG_DWORD /d 1 /f > $null 2>&1

# Remote Desktop: Don't warn about unsigned drivers
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v "DoNotWarnIfUnsigned" /t REG_DWORD /d 1 /f > $null 2>&1

# Prevent DNS leaks by disabling Smart Multi-Homed Name Resolution
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "DisableSmartNameResolution" /t REG_DWORD /d 1 /f > $null 2>&1

# HAGS is applied together with MSI further below, gated by the GPULatency tweak group

# Disable Power Throttling for background tasks
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerThrottling" /v "PowerThrottlingOff" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Automatic Idle Maintenance
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v "MaintenanceDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Virtualization Based Security (VBS) for max gaming performance
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "EnableVirtualizationBasedSecurity" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "RequirePlatformSecurityFeatures" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1

# Windows AI, Recall, and Click-To-Do Policies (Integrated from sparkle & optimizerDuck)
Write-Host "Configuring Windows AI, Recall, and Click-To-Do policies..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallEnablement" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallToBeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableClickToDo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableSettingsAgent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentWorkspaces" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableRemoteAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowCopilotRuntime" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallToBeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarCompanion" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarCompanion" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1

# Disable WMI AutoLoggers (Integrated from sparkle)
Write-Host "Disabling WMI AutoLoggers background tracing sessions..." -ForegroundColor Green
$autoLoggers = @(
    'AppModel', 'Cellcore', 'CloudExperienceHostOobe', 'DataMarket',
    'DiagLog', 'Diagtrack-Listener', 'LwtNetLog', 'SQMLogger',
    'WdiContextLog', 'WiFiSession'
)
foreach ($logger in $autoLoggers) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\WMI\Autologger\$logger" /v "Start" /t REG_DWORD /d 0 /f > $null 2>&1
}

# AtlasOS & ReviOS Radical Performance, Low-Latency & Storage Optimization Block
if ($atlasReviOSMode) {
    Write-Host "Applying AtlasOS & ReviOS radical performance, latency & storage optimizations..." -ForegroundColor Green

    # 1. Network QoS Latency (100% full bandwidth allocation)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Psched" /v "NonBestEffortLimit" /t REG_DWORD /d 0 /f > $null 2>&1

    # 2. Storage & Crash Control (Configurable CrashDumpMode: Automatic=7, Small=3, None=0)
    $cdVal = switch ($crashDumpMode.ToLower()) {
        'none'      { 0 }
        'small'     { 3 }
        'automatic' { 7 }
        default     { if ($atlasReviOSMode) { 0 } else { 7 } }
    }
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /f /v "CrashDumpEnabled" /t REG_DWORD /d $cdVal > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "LogEvent" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "SendAlert" /t REG_DWORD /d 0 /f > $null 2>&1

    # 6. Additional Scheduled Tasks Purged Offline
    $atlasTasks = @(
        "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver",
        "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "Microsoft\Windows\Feedback\Siuf\DmClient",
        "Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
        "Microsoft\Windows\FileHistory\File History (maintenance mode)",
        "Microsoft\Windows\Maintenance\WinSAT",
        "Microsoft\Windows\PI\Sqm-Tasks",
        "Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
        "Microsoft\Windows\Shell\FamilySafetyMonitor",
        "Microsoft\Windows\Shell\FamilySafetyRefreshTask",
        "Microsoft\Windows\Registry\RegIdleBackup",
        "Microsoft\Windows\Diagnosis\Scheduled"
    )
    foreach ($task in $atlasTasks) {
        $tPath = Join-Path -Path $tasksPath -ChildPath $task
        if (Test-Path -LiteralPath $tPath) {
            Remove-Item -LiteralPath $tPath -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# Default User UI / UX, Latency & Gaming (Baked into Default User profile)
Write-Host "Configuring Default User UI/UX, input latency, and performance..." -ForegroundColor Green
# Startup & Menu latency
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v "StartupDelayInMSec" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v "StartupDelayInMSec" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1

# Keyboard latency & NumLock at boot
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "KeyboardDelay" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "KeyboardSpeed" /t REG_SZ /d "31" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "InitialKeyboardIndicators" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Keyboard" /v "InitialKeyboardIndicators" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay" /t REG_SZ /d "200" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatRate" /t REG_SZ /d "6" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "BounceTime" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance" /t REG_SZ /d "0" /f > $null 2>&1

# Mouse: 1:1 Raw Input (Zero acceleration, instant hover)
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseSpeed" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseThreshold1" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseThreshold2" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseHoverTime" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseSpeed" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseThreshold1" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseThreshold2" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseHoverTime" /t REG_SZ /d "1" /f > $null 2>&1

# Game Mode & Windowed Game optimizations
reg.exe add "HKLM\zNTUSER\Software\Microsoft\GameBar" /v "AllowAutoGameMode" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\GameBar" /v "AutoGameModeEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\DirectX\UserGpuPreferences" /v "DirectXUserGlobalSettings" /t REG_SZ /d "SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;" /f > $null 2>&1

# Explorer UI: End Task, Win10 Classic Context Menu, Dark Mode, File Extensions, Clock Seconds
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1

# Windows 10 Classic Context Menu (Baked directly into Default User profile for guaranteed inheritance)
reg.exe add "HKLM\zDEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1

# Radical RAM: Disable Transparency & DWM render targets & Best Performance Visual Effects
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\DWM" /v "AlwaysHibernateThumbnails" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\DWM" /v "AlwaysHibernateThumbnails" /t REG_DWORD /d 0 /f > $null 2>&1

# Best Performance Visual Effects (Zero Animation / Zero Shadow / No Live Window Drag)
if (-not ($script:activeTweakGroups -and $script:activeTweakGroups.Contains('VisualFX') -and (-not $script:activeTweakGroups['VisualFX']))) {
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012018010000000" /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012018010000000" /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "DragFullWindows" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "DragFullWindows" /t REG_SZ /d "0" /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
}

# Shell & Thumbnail RAM Optimization: Stop thumbnail caching
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAnimations" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAnimations" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewAlphaSelect" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewAlphaSelect" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewShadow" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewShadow" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DisableThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DisableThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1

# Edge & WebView2 Background Memory Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "PreloadEdgeDefaultEngine" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSecondsInSystemClock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSecondsInSystemClock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowTaskViewButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowTaskViewButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LastActiveClick" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LastActiveClick" /t REG_DWORD /d 1 /f > $null 2>&1

# Start Menu web search, suggestions, and account ads off
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications" /v "EnableAccountNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications" /v "EnableAccountNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_TrackProgs" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_TrackProgs" /t REG_DWORD /d 0 /f > $null 2>&1

# Dynamically set SettingsPageVisibility only for actually removed/disabled components
$hidePages = [System.Collections.Generic.List[string]]::new()
if ($removeDefender) {
    $hidePages.Add("virus")
    $hidePages.Add("windowsdefender")
    $hidePages.Add("windowsdefender-account")
    $hidePages.Add("windowsdefender-device")
    $hidePages.Add("windowsdefender-firewall")
}
if ($disableWU)      { $hidePages.Add("windowsupdate") }
$extraHidePages = @(
    "mobile-devices",
    "crossdevice",
    "backup",
    "easeofaccess-voiceaccess",
    "easeofaccess-magnifier",
    "easeofaccess-narrator",
    "easeofaccess-closedcaptioning",
    "easeofaccess-keyboard",
    "easeofaccess-speechrecognition",
    "gaming-gamebar",
    "gaming-gamedvr",
    "gaming-broadcasting"
)
foreach ($hp in $extraHidePages) {
    $hidePages.Add($hp)
}
if ($hidePages.Count -gt 0) {
    $hideVal = "hide:" + ($hidePages -join ";")
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /t REG_SZ /d "$hideVal" /f > $null 2>&1
}

# ============================================================================
# Revo Registry Cleaner - Complete "Registry Tuner" Integration (All 6 Categories)
# ============================================================================
Write-Host "Applying Revo Registry Cleaner 'Registry Tuner' optimizations (All 6 Categories)..." -ForegroundColor Green

# 1. Desktop
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "Max Cached Icons" /t REG_SZ /d "4096" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "link" /t REG_BINARY /d "00000000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "link" /t REG_BINARY /d "00000000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ExtendedUIHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ExtendedUIHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DesktopLivePreviewHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DesktopLivePreviewHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1

# 2. File Explorer
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "Append Completion" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "AutoSuggest" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "Append Completion" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "AutoSuggest" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowDriveLettersFirst" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowDriveLettersFirst" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager" /v "ConfirmationCheckBoxDoForAll" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager" /v "ConfirmationCheckBoxDoForAll" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "FolderContentsInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "FolderContentsInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoNewAppAlert" /t REG_DWORD /d 1 /f > $null 2>&1

# Show Full Details in File Operation Conflict / Deletion
reg.exe add "HKLM\zSOFTWARE\Classes\AllFilesystemObjects" /v "ConflictPrompt" /t REG_SZ /d "prop:System.ItemTypeText;System.Size;System.DateModified;System.OfflineAvailability" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\AllFilesystemObjects" /v "FullDetails" /t REG_SZ /d "prop:System.DateModified;System.Size;System.DateCreated;*System.StorageProviderState;*System.OfflineAvailability;*System.OfflineStatus;*System.SharedWith" /f > $null 2>&1

# Context Menu: Take Ownership
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /ve /t REG_SZ /d "Take Ownership" > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /f /v "NoWorkingDirectory" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas\command" /f /ve /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" && icacls \"%1\" /grant administrators:F' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas\command" /f /v "IsolatedCommand" /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" && icacls \"%1\" /grant administrators:F' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /ve /t REG_SZ /d "Take Ownership" > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /f /v "NoWorkingDirectory" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" /f /ve /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" /r /d y && icacls \"%1\" /grant administrators:F /t' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" /f /v "IsolatedCommand" /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" /r /d y && icacls \"%1\" /grant administrators:F /t' > $null 2>&1

# Context Menu: Command Prompt as Administrator
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /f /ve /t REG_SZ /d "Open Command Prompt as Administrator" > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /f /v "HasLUAShield" /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas\command" /f /ve /t REG_SZ /d 'PowerShell -windowstyle hidden -Command \"Start-Process cmd.exe -ArgumentList ''/s,/k,pushd,%V'' -Verb RunAs\"' > $null 2>&1

# Context Menu: Rotate Right / Rotate Left for Images
$imgExts = @('.avif', '.dds', '.gif', '.heif', '.jfif', '.jpeg', '.jpg', '.jxr', '.png', '.rle', '.tiff', '.webp')
foreach ($ext in $imgExts) {
    reg.exe add "HKLM\zSOFTWARE\Classes\SystemFileAssociations\$ext\ShellEx\ContextMenuHandlers\ShellImagePreview" /ve /t REG_SZ /d "{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}" /f > $null 2>&1
}

# 3. Security and Stability
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoDriveTypeAutoRun" /t REG_DWORD /d 255 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" /v "DisableAutoplay" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "AutoEndTasks" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "AutoEndTasks" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "HungAppTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "HungAppTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "WaitToKillAppTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "WaitToKillAppTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "LowLevelHooksTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "LowLevelHooksTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "WaitToKillServiceTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "EnableLinkedConnections" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "ConsentPromptBehaviorAdmin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "PromptOnSecureDesktop" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "RecycleBinDrives" /t REG_DWORD /d 1 /f > $null 2>&1
if (-not $removeDefender) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" /v "MpEnablePus" /t REG_DWORD /d 1 /f > $null 2>&1
}
reg.exe add "HKLM\zSOFTWARE\Microsoft\OEM\Device\Capture" /v "NoPhysicalCameraLED" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v "DumpType" /t REG_DWORD /d 2 /f > $null 2>&1

# 4. System
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "AltTabSettings" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "AltTabSettings" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\default\Update\ExcludeUpdateDrivers" /v "value" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\WindowsStore" /v "AutoDownload" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" /v "AllowPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "WebWidgetIsEnabled" /t REG_DWORD /d 0 /f > $null 2>&1

# Background Process Reduction: OneDrive background sync & startup
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDriveSetup" /f > $null 2>&1
reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1
reg.exe delete "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1

# Background Process Reduction: Windows Error Reporting (wermgr.exe)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontSendAdditionalData" /t REG_DWORD /d 1 /f > $null 2>&1

# Background Process Reduction: CrossDevice & Phone Link (PhoneExperienceHost.exe)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1

# 5. Windows Appearance
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "DisableAcrylicBackgroundOnLogon" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell" /v "UseWin32BatteryFlyout" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "EnergyEstimationEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "UserPresencePrediction" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\MTCUVC" /v "EnableMtcUvc" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d 0 /f > $null 2>&1

# 6. Windows Usage
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v "LetAppsRunInBackground" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel\NameSpace\{EDEEBE61-B85A-46B1-834B-E545EF04E947}" /ve /t REG_SZ /d "Classic User Accounts" /f > $null 2>&1

# Enable Windows Photo Viewer Associations
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

# ============================================================================
# Advanced Windows Optimization Suite: WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy
# ============================================================================
Write-Host "Applying advanced optimizations from WinUtil, Sophia Script, SophiApp, Optimizer & Bloatynosy..." -ForegroundColor Green

# 1. Bloatynosy & Classic Shell: Classic Context Menu baked into Default & NTUSER hives offline
Write-Host "  -> Classic Context Menu (Bloatynosy)..." -ForegroundColor Cyan
reg.exe add "HKLM\zDEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve /t REG_SZ /d '""' > $null 2>&1

# 2. Sophia Script & SophiApp: Instant First Logon, Lossless Wallpaper, and Control Panel
Write-Host "  -> Instant Logon, Wallpaper & Control Panel (Sophia Script)..." -ForegroundColor Cyan
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "EnableFirstLogonAnimation" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "EnableFirstLogonAnimation" /t REG_DWORD /d 0 /f > $null 2>&1
# Lossless wallpaper quality (JPEGImportQuality 100)
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "JPEGImportQuality" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "JPEGImportQuality" /t REG_DWORD /d 100 /f > $null 2>&1
# Classic Control Panel: Large Icons view by default
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "AllItemsIconView" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "StartupPage" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "AllItemsIconView" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "StartupPage" /t REG_DWORD /d 1 /f > $null 2>&1
# Sophia scheduled task purges offline
foreach ($sophiaTask in @("MareBackup", "StartupAppTask")) {
    $targetSophiaPath = Join-Path -Path $tasksPath -ChildPath "Microsoft\Windows\Application Experience\$sophiaTask"
    if (Test-Path -LiteralPath $targetSophiaPath) {
        Remove-Item -LiteralPath $targetSophiaPath -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 3. Chris Titus WinUtil: OOBE Background UScheduler Bloat Suppression
Write-Host "  -> Background UScheduler Bloat Suppression (WinUtil)..." -ForegroundColor Cyan
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1

# 4. Hellzerg Optimizer: RegBack Backups & Explorer Responsiveness
Write-Host "  -> Explorer Responsiveness & RegBack (Optimizer)..." -ForegroundColor Cyan
# Re-enable periodic registry hive backups to RegBack
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Configuration Manager" /v "EnablePeriodicBackup" /t REG_DWORD /d 1 /f > $null 2>&1
# Explorer link resolution, low disk space warnings, unknown extension web searches
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoLowDiskSpaceChecks" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "LinkResolveIgnoreLinkInfo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveSearch" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveTrack" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoLowDiskSpaceChecks" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "LinkResolveIgnoreLinkInfo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveSearch" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveTrack" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f > $null 2>&1
# Disable Remote Assistance unsolicited help invitations
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Remote Assistance" /v "fAllowToGetHelp" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 5. Low-Latency Gaming, Hardware Scheduling, and CPU Tuning (AtlasOS / ReviOS Aligned)
# ============================================================================
Write-Host "Applying Low-Latency Gaming, HAGS, & CPU scheduling optimizations..." -ForegroundColor Green
# GPULatency tweak group: Hardware-Accelerated GPU Scheduling (HAGS) + offline MSI enablement (below)
$gpuLatencyEnabled = [bool]$script:activeTweakGroups['GPULatency']
if ($gpuLatencyEnabled) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers" /v "HwSchMode" /t REG_DWORD /d 2 /f > $null 2>&1
}
# CPU core parking is disabled via the power policy (CPMINCORES/CPMAXCORES = 100% under
# Policies\Microsoft\Power\PowerSettings). The setting's ValueMin/ValueMax range is intentionally
# left at the OS default: clamping it to 0..0 would make the 100% policy value out of range.
# Energy Performance Preference (EPP) is set via the power policy (36687f9e... ACSettingIndex/DCSettingIndex).
# Its ValueMin/ValueMax range is left at the OS default so power plans (e.g. handheld battery tuning) can still change it.

# Modular Power Presets (USB Selective Suspend, PCIe ASPM, CPU Boost, Disk Idle)
$psBase = "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings"
$resolvedPower = if ($powerPreset -and $script:PowerPresets.Contains($powerPreset)) { $script:PowerPresets[$powerPreset] } else { $script:PowerPresets['Desktop'] }

$usbVal = if ($disableUSBSuspend) { 0 } else { $resolvedPower.UsbSuspend }
reg.exe add "$psBase\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" /f /v "ACSettingIndex" /t REG_DWORD /d $usbVal > $null 2>&1
reg.exe add "$psBase\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" /f /v "DCSettingIndex" /t REG_DWORD /d $usbVal > $null 2>&1

reg.exe add "$psBase\501a4d13-42af-4429-9fd1-a8218c268e20\ee12f906-d277-404b-b6da-e5fa1a576df5" /f /v "ACSettingIndex" /t REG_DWORD /d $resolvedPower.PcieLpm > $null 2>&1
reg.exe add "$psBase\501a4d13-42af-4429-9fd1-a8218c268e20\ee12f906-d277-404b-b6da-e5fa1a576df5" /f /v "DCSettingIndex" /t REG_DWORD /d $resolvedPower.PcieLpm > $null 2>&1

$boostAc = if ($cpuBoostMode -eq 'Aggressive') { 2 } elseif ($cpuBoostMode -eq 'Efficient') { 1 } elseif ($cpuBoostMode -eq 'Off') { 0 } else { $resolvedPower.BoostAc }
$boostDc = if ($cpuBoostMode -eq 'Aggressive') { 2 } elseif ($cpuBoostMode -eq 'Efficient') { 1 } elseif ($cpuBoostMode -eq 'Off') { 0 } else { $resolvedPower.BoostDc }
$boostGuid = "$psBase\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7"
reg.exe add $boostGuid /f /v "ACSettingIndex" /t REG_DWORD /d $boostAc > $null 2>&1
reg.exe add $boostGuid /f /v "DCSettingIndex" /t REG_DWORD /d $boostDc > $null 2>&1

$diskGuid = "$psBase\0012ee47-9041-4b5d-9b77-535fba8b1442\abfc2519-3608-4c2a-9dea-dfd1d45f50c4"
reg.exe add $diskGuid /f /v "ACSettingIndex" /t REG_DWORD /d $resolvedPower.DiskIdle > $null 2>&1
reg.exe add $diskGuid /f /v "DCSettingIndex" /t REG_DWORD /d $resolvedPower.DiskIdle > $null 2>&1
# Exclude display/chipset driver overwrites in Windows Update (prevents GPU driver rollback)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f > $null 2>&1

# Offline Message Signaled Interrupts (MSI) enablement across target PCI device classes (GPU, NVMe, NIC)
try {
    # GPU and NIC only: forcing MSI on storage controllers / unclassified devices can prevent boot
    $targetClasses = @(
        '{4d36e968-e325-11ce-bfc1-08002be10318}', # Display / GPU
        '{4d36e972-e325-11ce-bfc1-08002be10318}'  # Network Adapters (NIC)
    )
    $pciRoot = "HKLM:\zSYSTEM\ControlSet001\Enum\PCI"
    if (Test-Path -LiteralPath $pciRoot) {
        foreach ($venKey in (Get-ChildItem -LiteralPath $pciRoot -ErrorAction SilentlyContinue)) {
            foreach ($devKey in (Get-ChildItem -LiteralPath $venKey.PSPath -ErrorAction SilentlyContinue)) {
                $devParamPath = Join-Path -Path $devKey.PSPath -ChildPath "Device Parameters"
                if (Test-Path -LiteralPath $devParamPath) {
                    $classGuid = (Get-ItemProperty -LiteralPath $devKey.PSPath -Name "ClassGUID" -ErrorAction SilentlyContinue).ClassGUID
                    if ($gpuLatencyEnabled -and $classGuid -and ($targetClasses -contains $classGuid)) {
                        $msiKey = Join-Path -Path $devParamPath -ChildPath "Interrupt Management\MessageSignaledInterruptProperties"
                        if (-not (Test-Path -LiteralPath $msiKey)) {
                            New-Item -Path $msiKey -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        Set-ItemProperty -LiteralPath $msiKey -Name "MSISupported" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    }
                    # NVIDIA Ultra Low Latency Registry Tuning (PowerMizer & Per-CPU Core DPC)
                    if ($nvidiaLowLatency -and ($devKey.PSChildName -match 'VEN_10DE' -or $venKey.PSChildName -match 'VEN_10DE')) {
                        Set-ItemProperty -LiteralPath $devParamPath -Name "PowerMizerEnable" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -LiteralPath $devParamPath -Name "PerfLevelSrc" -Value 13090 -Type DWord -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -LiteralPath $devParamPath -Name "RmGpsPsEnablePerCpuCoreDpc" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
} catch {}

# ============================================================================
# 6. Windows 11 AI, Copilot, Recall & Edge Telemetry Offline Suppression
# ============================================================================
Write-Host "Applying Windows 11 AI, Copilot, Recall & Edge suppression policies..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
# Edge Copilot and Hubs Sidebar
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "HubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "CopilotPageContext" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StandaloneHubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
# Edge Update suppression (protects WebView2 for Steam/Discord/desktop apps)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Update{F3017226-FE2A-4295-8BDF-F0E3A9A7E4C5}" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Install{F3017226-FE2A-4295-8BDF-F0E3A9A7E4C5}" /t REG_DWORD /d 1 /f > $null 2>&1
# SmartScreen & PII telemetry opt-out
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableSmartScreen" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\AppHost" /v "EnableWebContentEvaluation" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AppHost" /v "EnableWebContentEvaluation" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 7. Japanese IME Privacy & Telemetry Opt-out
# ============================================================================
Write-Host "Configuring Japanese IME privacy opt-out..." -ForegroundColor Green
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 8. Dark Mode Default Configuration
# ============================================================================
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 9. OEM Information Branding
# ============================================================================
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "Manufacturer" /t REG_SZ /d "nano11 Project" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "SupportURL" /t REG_SZ /d "https://github.com/gh459/nano11" /f > $null 2>&1

# ============================================================================
# 11. Windows Activation Restriction Bypass & Watermark/SPP Suppression
# ============================================================================
if ($bypassActivationRestrictions) {
    Write-Host "Applying Windows activation restriction bypass & personalization unlock policies..." -ForegroundColor Green
    # Desktop watermark and not genuine banner suppression
    reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v "DisplayNotGenuine" /t REG_DWORD /d 0 /f > $null 2>&1

    # Personalization lockout bypass (unlock wallpaper, themes, lockscreen, colors)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Personalization" /v "NoLockScreen" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v "NoChangingWallPaper" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v "NoChangingWallPaper" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoThemesTab" /t REG_DWORD /d 0 /f > $null 2>&1
    $transparencyVal = if ($radicalRAM) { 0 } else { 1 }
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /f /v "EnableTransparency" /t REG_DWORD /d $transparencyVal > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /f /v "EnableTransparency" /t REG_DWORD /d $transparencyVal > $null 2>&1

    # Software Protection Platform (SPP) nag & toast notification suppression
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "NoGenTicket" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "UserOperations" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "NotificationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "NotificationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" /v "UserOperations" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Activation" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Activation" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Activation" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Licensing" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Licensing" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
}

Write-Host "    -> Applying integrated debloat optimizations (Sophia / Win11Debloat / NixThis / privacy.sexy)..." -ForegroundColor Cyan

    # 1. Windows 11 24H2/25H2 AI & Recall & Copilot Suppression (Win11Debloat & Sophia)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableClickToDo" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Notepad" /v "EnableAIFeatures" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Paint" /v "EnableCocreator" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WSAIFabricSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1

    # 2. Windows 11 24H2 Setup Safeguard: Prevent Automatic BitLocker Device Encryption (Win11Debloat)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1

    # 3. Privacy, Telemetry & Data Collection Policies (Sophia & privacy.sexy curated safe subset)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MaxTelemetryAllowed" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DoNotShowFeedbackNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AITEnable" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableInventory" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\SQMClient\Windows" /v "CEIPEnable" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Device Metadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d 1 /f > $null 2>&1

    # 4. Ads, Suggestions & Consumer Content Delivery Suppression (NixThis & Win11Debloat)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableAccountBasedInSettings" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-353694Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-353696Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SystemSettingsInfoEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSyncProviderNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_IrisRecommendations" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "RotatingImageOverlayEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-338387Enabled" /t REG_DWORD /d 0 /f > $null 2>&1

    # 5. UI Ergonomics & Latency Optimization (Win11Debloat & Sophia)
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "HideSCAMeetNow" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings" /v "EnforceConnectedStandby" /t REG_DWORD /d 0 /f > $null 2>&1

    # 6. Browser Policy Hardening: Edge / Chrome / Brave Background Bloat & AI Suppression (NixThis & Win11Debloat)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "PersonalizationReportingEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "WebWidgetIsEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Google\Chrome" /v "AIModeSettings" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\BraveSoftware\Brave" /v "BraveAIChatEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\BraveSoftware\Brave" /v "BraveRewardsDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\BraveSoftware\Brave" /v "BraveVPNDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

    Write-Host "    -> Integrated debloat optimizations applied successfully." -ForegroundColor Green

# ============================================================================
# 12. Winhancements & Unattend Offline System/User Registry & Assets Integration
# ============================================================================
Write-Host "Applying Winhancements offline system & user customizations..." -ForegroundColor Green

# 1. Unhide advanced power settings in Control Panel / Power Options
$hiddenPowerSettings = @(
    '0012ee47-9041-4b5d-9b77-535fba8b1442\0b2d69d7-a2a1-449c-9680-f91c70521c60', # Hard disk burst ignore time
    '0012ee47-9041-4b5d-9b77-535fba8b1442\abfc2519-3608-4c2a-9dea-dfd1d45f50c4', # Turn off hard disk after
    '0012ee47-9041-4b5d-9b77-535fba8b1442\fc95f35b-34ea-4ee6-bc56-f959d49312e7', # Disk idle timeout
    '238c2580-0ad3-4b49-9600-03e44c389c70\9d7815a3-66a4-44e3-9e37-540f9e402b5b', # Sleep timeout
    '238c2580-0ad3-4b49-9600-03e44c389c70\94ac6d29-73ce-41a6-809f-6363ba21b47e', # Hibernate timeout
    '2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226', # USB selective suspend
    '501a4d13-42af-4429-9fd1-a8218c268e20\ee12f906-d277-404b-b6da-e5fa1a576df5', # PCI Express Link State Power Management
    '54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583', # Processor core parking min cores
    '54533251-82be-4824-96c1-47b60b740d00\36687f9e-e3a5-4dbf-b1dc-15eb381c6863', # Energy Performance Preference
    '54533251-82be-4824-96c1-47b60b740d00\86644480-2187-4e96-adf2-30e9e5353756', # Processor autonomous mode
    '54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7', # Processor performance boost mode
    '54533251-82be-4824-96c1-47b60b740d00\ea062031-0e34-4ff1-9b6d-eb1059334028', # Processor core parking max cores
    '0012ee47-9041-4b5d-9b77-535fba8b1442\d3d55b30-48fb-4e08-8547-024508492025', # NVMe NOPPME
    '0012ee47-9041-4b5d-9b77-535fba8b1442\d6395100-e628-4100-ac18-6d0256e036e7'  # NVMe Power State Transition Latency Tolerance
)
foreach ($hps in $hiddenPowerSettings) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings\$hps" /v "Attributes" /t REG_DWORD /d 0 /f > $null 2>&1
}

# 2. Service TriggerInfo Removal (prevents unwanted background auto-triggering)
$triggerServices = @('DiagTrack', 'WSearch', 'SysMain', 'DoSvc', 'WerSvc', 'PcaSvc', 'MapsBroker', 'lfsvc', 'wisvc', 'RetailDemo', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'BcastDVRUserService')
foreach ($ts in $triggerServices) {
    reg.exe delete "HKLM\zSYSTEM\ControlSet001\Services\$ts\TriggerInfo" /f > $null 2>&1
}

# 3. Transparent Shortcut Overlay Icon & Shell Icons
$blankIcoPath = Join-Path -Path $scratchDir -ChildPath "Windows\blank.ico"
$blankIcoBytes = [System.Convert]::FromBase64String("AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
[System.IO.File]::WriteAllBytes($blankIcoPath, $blankIcoBytes)
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons" /v "29" /t REG_SZ /d "C:\Windows\blank.ico,0" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache" /v "Autorun" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\lnkfile" /v "NeverShowExt" /t REG_SZ /d '""' /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\ContextMenus\CompressToFullMenu_ForOldContextMenu" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\Drive\ContextMenus\CompressToFullMenu_ForOldContextMenu" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\AllFilesystemObjects\ContextMenus\CompressToFullMenu_ForOldContextMenu" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\background\shell\Windows.ShowFileExtensions" /f > $null 2>&1

# 4. Hide legacy user folders from This PC and navigation pane
$folderGuids = @(
    '{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}', # 3D Objects
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}', # Desktop
    '{f42ee2d3-909f-4907-8871-4c22fc0bf756}', # Documents
    '{7d830970-0744-430b-9940-0430e386f18f}', # Downloads
    '{a0c69a78-042a-42f8-97af-96a9625646f8}', # Music
    '{0ddd015d-b061-47fe-8c11-15e128e578e1}', # Pictures
    '{35286175-63c0-4d56-8d1a-cc97d00b9817}'  # Videos
)
foreach ($fg in $folderGuids) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$fg\PropertyBag" /v "ThisPCPolicy" /t REG_SZ /d "Hide" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$fg\PropertyBag" /v "ThisPCPolicy" /t REG_SZ /d "Hide" /f > $null 2>&1
}
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{F5FB2C77-0E2F-4A16-A381-3E560C68BC83}" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{F5FB2C77-0E2F-4A16-A381-3E560C68BC83}" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}" /v "System.IsPinnedToNameSpaceTree" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\CLSID\{e88865ea-0e14-4b44-9343-b99b34005b45}" /v "System.IsPinnedToNameSpaceTree" /t REG_DWORD /d 0 /f > $null 2>&1

# 5. Security Center, Windows Update UX, and Startup Sound Policies
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Defender Security Center\Notifications" /v "DisableNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Defender Security Center\Notifications" /v "DisableEnhancedNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v "ShowSleepOption" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v "ShowLockOption" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "SetAutoRestartNotificationConfig" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "AutoRestartNotificationSchedule" /t REG_DWORD /d 15 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\UX\Settings" /v "RestartNotificationsAllowed2" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\UX\Settings" /v "IsContinuousInnovationOptedIn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\UX\Settings" /v "ActiveHoursStart" /t REG_DWORD /d 9 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\UX\Settings" /v "ActiveHoursEnd" /t REG_DWORD /d 17 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "IsEducationEnvironment" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device" /v "DevicePasswordLessBuildVersion" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation" /v "DisableStartupSound" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Speech_OneCore" /f > $null 2>&1

# 6. Default User UI, CabinetState, SnapAssist & Audio Ducking
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" /v "FullPath" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" /v "FullPath" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowEncryptCompressedColor" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowEncryptCompressedColor" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "SharingWizardOn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "SharingWizardOn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "EnableSnapAssistFlyout" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "EnableSnapAssistFlyout" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DontUsePowerShellOnWinX" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DontUsePowerShellOnWinX" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Multimedia\Audio" /v "UserDuckingPreference" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Multimedia\Audio" /v "UserDuckingPreference" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\UserOnce.ps1" /f > $null 2>&1

# 7. Start Menu clean layout modification XML
$layoutXmlDir = Join-Path -Path $scratchDir -ChildPath "Users\Default\AppData\Local\Microsoft\Windows\Shell"
if (-not (Test-Path -LiteralPath $layoutXmlDir)) {
    New-Item -Path $layoutXmlDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
}
$cleanLayoutContent = '<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"><LayoutOptions StartTileGroupCellWidth="6" /><DefaultLayoutOverride><StartLayoutCollection><defaultlayout:StartLayout Host="StartMenu"><start:Group Name="" /></defaultlayout:StartLayout></StartLayoutCollection></DefaultLayoutOverride></LayoutModificationTemplate>'
Set-Content -LiteralPath (Join-Path -Path $layoutXmlDir -ChildPath "LayoutModification.xml") -Value $cleanLayoutContent -Encoding utf8

# ==============================================================================
# Helper Function: Save-Nano11UnattendXml
# Strictly writes XmlDocument to disk with a single UTF-8 BOM, validates bytes,
# verifies via XmlDocument.Load, and checks pass attribute integrity.
# ==============================================================================
function Save-Nano11UnattendXml {
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

    # Strict Post-Save Validation:
    # 1. Byte check: Verify first 4 bytes are EF-BB-BF-3C, and no double BOM
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

    # 2. XmlDocument.Load validation
    try {
        $verifyDoc = New-Object System.Xml.XmlDocument
        $verifyDoc.Load($DestinationPath)
    } catch {
        throw "XML save verification failed: XmlDocument.Load failed for $($DestinationPath) : $_"
    }

    # 3. Settings pass attribute integrity check
    $settingsNodes = $verifyDoc.SelectNodes("//*[local-name()='settings']")
    foreach ($s in $settingsNodes) {
        $passAttr = $s.GetAttribute("pass")
        if ([string]::IsNullOrWhiteSpace($passAttr)) {
            throw "XML save verification failed: <settings> node missing required 'pass' attribute in $($DestinationPath)"
        }
    }

    Write-Host "  [XML Verified] Saved $($DestinationPath) (Single UTF-8 BOM, valid XML DOM, pass attributes intact)" -ForegroundColor Green
}
