# Phase 10: Registry Hive Loading, Hardware Bypasses & Granular Tweaks
# Dot-sourced by the main orchestrator (WinEasebuilder.ps1)

if (-not $scratchDir -and $script:scratchDir) { $scratchDir = $script:scratchDir }

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
    Mount-WinEaseRegistryHive -Name $hiveName -Path $hiveFile
    $script:HivesLoaded = $true
}

# Detect and display target Windows build info. The build number also selects the MinBuild /
# MaxBuild entries of the config\registry tables; it stays unset when it cannot be read.
$script:WinEaseTargetBuild = $null
try {
    $targetProductName = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ProductName 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetDisplayVer  = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetBuildNum    = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetUBR         = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR 2>$null | Select-String -Pattern 'REG_DWORD\s+0x([0-9a-fA-F]+)' | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
    $parsedTargetBuild = 0
    if ([int]::TryParse([string]$targetBuildNum, [ref]$parsedTargetBuild) -and $parsedTargetBuild -gt 0) { $script:WinEaseTargetBuild = $parsedTargetBuild }
    if ($targetProductName) {
        Write-Host "Target Image OS: $targetProductName (Version: $targetDisplayVer, Build: $targetBuildNum.$targetUBR)" -ForegroundColor Green
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

# Helper function to evaluate individual toggle settings
# (guarded so a re-run of the phase does not redefine it; the canonical definition
# lives in WinEasebuilder.ps1, so the guard normally finds the one from there.
# This copy only matters when the phase is dot-sourced on its own.)
if (-not (Get-Command -Name Test-TweakEnabled -ErrorAction SilentlyContinue)) {
    function Test-TweakEnabled {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Name,
            [bool]$Default = $true
        )
        if ($null -ne $script:TweakSettings -and ([System.Collections.IDictionary]$script:TweakSettings).Contains($Name)) {
            return [bool]$script:TweakSettings[$Name]
        }
        # Legacy key names (older profiles / -TweakSettings hashtables) that map onto this GUI key
        if ($null -ne $script:TweakSettings -and $script:TweakKeyAliases) {
            foreach ($alias in $script:TweakKeyAliases.Keys) {
                if ($script:TweakKeyAliases[$alias] -eq $Name -and ([System.Collections.IDictionary]$script:TweakSettings).Contains($alias)) {
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
    Invoke-WinEaseRegistryTable -Section setup -Tweak BypassHardwareRequirements
}

# ============================================================================
# 2. OOBE & Local Account Setup
# ============================================================================
if (Test-TweakEnabled 'BypassNRO' $true) {
    Write-Host "Enabling Local Account bypass on OOBE (BypassNRO)..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section setup -Tweak BypassNRO
}

if (Test-TweakEnabled 'PreventDeviceEncryption' $false) {
    Write-Host "Preventing automatic BitLocker device encryption..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section setup -Tweak PreventDeviceEncryption
}

# Japanese 106/109 Keyboard Configuration
if ($setJapaneseKeyboard -or (Test-TweakEnabled 'SetJapaneseKeyboard' $false)) {
    Write-Host "Configuring Japanese 106/109 keyboard layout..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section setup -Tweak SetJapaneseKeyboard -Unconditional
}

# Setup & Winlogon / Blank Password / Script Execution
# The network use of a blank password is blocked in every configuration: an empty
# password must never work over the network.
Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Control\Lsa" -Name "LimitBlankPasswordUse" -Type REG_DWORD -Data '1'
if (Test-TweakEnabled 'ConfigureWinlogon' $false) {
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Type REG_SZ -Data "1"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultUserName" -Type REG_SZ -Data "$UserName"
    # The password is written through the .NET registry API, not reg.exe: a native command line
    # cannot carry an arbitrary password (quotes, backslashes) and would expose it to argument parsing.
    $defPassVal = if ($null -ne $script:UserPassword -and $script:UserPassword -ne '') { [string]$script:UserPassword } else { '' }
    if (-not (Set-WinEaseRegistrySecretString -Key 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -Value $defPassVal)) {
        Write-Warning "The Winlogon DefaultPassword could not be written; the automatic logon may not work."
    }
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ForceAutoLogon" -Type REG_SZ -Data "1"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowDomainDelayLock" -Type REG_DWORD -Data '1'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "FilterAdministratorToken" -Type REG_DWORD -Data '0'
} else {
    Write-Host "Blank-password auto-logon is disabled (ConfigureWinlogon is off)." -ForegroundColor Yellow
}

# PowerShell Script Execution Policy
Invoke-WinEaseRegistryTable -Section setup -Tweak EnableScripts

# ============================================================================
# 3. Sponsored Apps, Suggestions & Cloud Content
# ============================================================================
if (Test-TweakEnabled 'DisableCloudContent' $true) {
    Write-Host "Disabling Sponsored Apps & Cloud Content..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section cloud-content -Tweak DisableCloudContent
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" -Name "ConfigureStartPins" -Type REG_SZ -Data "{\`"pinnedList\`": [{}]}"
}

# ============================================================================
# 4. Diagnostics, Privacy & Telemetry
# ============================================================================
if (Test-TweakEnabled 'DisableTelemetryAndDiagnostics' $true) {
    Write-Host "Disabling Diagnostics & Telemetry..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableTelemetryAndDiagnostics
}

# Windows Error Reporting
Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableErrorReporting

# User Activity History & Sync
Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableActivityHistory

# ============================================================================
# 5. Windows AI, Recall, Click-To-Do & Copilot
# ============================================================================
if (Test-TweakEnabled 'DisableWindowsAI' $true) {
    Write-Host "Disabling Windows AI, Recall, and Click-To-Do policies..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section ai -Tweak DisableWindowsAI
}

if (Test-TweakEnabled 'DisableCopilot' $true) {
    Write-Host "Disabling Copilot, DevHome, and Teams auto-install..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section ai -Tweak DisableCopilot
}

# ============================================================================
# 6. Cross-Device & Mobile Device Integration
# ============================================================================
if (Test-TweakEnabled 'DisableCrossDevice' $true) {
    Write-Host "Disabling Cross-Device Experience / Phone Link & Resume..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section cross-device -Tweak DisableCrossDevice
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\SendToPhone"
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\SendToPhone"
}

# ============================================================================
# 7. Start Menu, Web Search & Widgets
# ============================================================================
if (Test-TweakEnabled 'DisableWebSearch' $true) {
    Write-Host "Disabling Bing search & web suggestions in Start menu..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section start-search -Tweak DisableWebSearch
}

Invoke-WinEaseRegistryTable -Section start-search -Tweak HideSearchBox

if (Test-TweakEnabled 'DisableWidgets' $true) {
    Write-Host "Disabling Windows 11 Widgets..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section start-search -Tweak DisableWidgets
}

Invoke-WinEaseRegistryTable -Section start-search -Tweak HideRecommendedSection

# ============================================================================
# 8. Security & Stability Controls
# ============================================================================
if (Test-TweakEnabled 'DisableSmartScreen' $false) {
    Write-Host "Disabling SmartScreen policies..." -ForegroundColor Yellow
    Invoke-WinEaseRegistryTable -Section security -Tweak DisableSmartScreen
}

if (Test-TweakEnabled 'DisableUACPrompts' $false) {
    Write-Host "Disabling UAC consent prompts (UAC stays on)..." -ForegroundColor Yellow
    Invoke-WinEaseRegistryTable -Section security -Tweak DisableUACPrompts
}

if (Test-TweakEnabled 'DisableUAC' $false) {
    Write-Host "Turning User Account Control off completely (EnableLUA = 0, effective after a restart)..." -ForegroundColor Yellow
    Invoke-WinEaseRegistryTable -Section security -Tweak DisableUAC
}

if (Test-TweakEnabled 'DisableVBS' $false) {
    Write-Host "Disabling Virtualization-Based Security (VBS / HVCI)..." -ForegroundColor Yellow
    Invoke-WinEaseRegistryTable -Section security -Tweak DisableVBS
}

if (Test-TweakEnabled 'DisableWPBT' $false) {
    Write-Host "Blocking UEFI WPBT execution (OEM bloatware persistence prevention)..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section security -Tweak DisableWPBT
}

if (Test-TweakEnabled 'HardenSystemSecurity' $false) {
    # Harden-Windows-Security (HotCakeX) HardenSystemSecurity-v1.0.97.0: the subset of its
    # categories that is a plain registry value and can be written into the offline hives.
    Write-Host "Applying offline security hardening (LSA, NTLM, anonymous access, AutoRun, logging)..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section security -Tweak HardenSystemSecurity
}

Invoke-WinEaseRegistryTable -Section security -Tweak DisableBSODEmoticon

Invoke-WinEaseRegistryTable -Section security -Tweak DisableFTH

Invoke-WinEaseRegistryTable -Section security -Tweak DisablePCA

Invoke-WinEaseRegistryTable -Section security -Tweak DisableDeliveryOptimization

# ============================================================================
# 9. Performance, Power & Latency Optimizations
# ============================================================================
# Power throttling, the foreground quantum / DPC settings (ThreadDpcEnable, AtlasReviOSMode) and the MMCSS
# task profiles (LowLatencyAudioMMCSS, MMCSSGaming) are implemented by the built-in plugin
# WinEase.Plugins.Builtin.Latency (src\WinEase.Plugins.Builtin.Latency), which runs right after this phase.

Invoke-WinEaseRegistryTable -Section performance -Tweak DisableIdleMaintenance

Invoke-WinEaseRegistryTable -Section performance -Tweak NtfsDisable8dot3

Invoke-WinEaseRegistryTable -Section performance -Tweak EnableLongPaths

Invoke-WinEaseRegistryTable -Section performance -Tweak NetworkTuning

if ($radicalRAM -or (Test-TweakEnabled 'SvcHostConsolidation' $false)) {
    Invoke-WinEaseRegistryTable -Section performance -Tweak SvcHostConsolidation -Unconditional
}

if ($noKernelPaging -or (Test-TweakEnabled 'NoKernelPaging' $false)) {
    Invoke-WinEaseRegistryTable -Section performance -Tweak NoKernelPaging -Unconditional
}

if ($disableCPUMitigations -or (Test-TweakEnabled 'DisableCPUMitigations' $false)) {
    Write-Host "  [SECURITY WARNING] Disabling CPU speculative execution mitigations (Spectre/Meltdown)..." -ForegroundColor Yellow
    Invoke-WinEaseRegistryTable -Section performance -Tweak DisableCPUMitigations -Unconditional
}

if ($disableFSE -or (Test-TweakEnabled 'DisableFSE' $false)) {
    Invoke-WinEaseRegistryTable -Section performance -Tweak DisableFSE -Unconditional
}

# NVIDIA low-latency: PowerMizer performance mode + per-CPU core DPC registry tuning.
# The switch existed in the CLI and the README documented the behaviour, but no phase
# consumed it, so the flag had no effect. PowerMizer is set to "Prefer maximum
# performance" (0x1) and the per-processor DPC policy is switched to the DPC profile.
if ($nvidiaLowLatency -or (Test-TweakEnabled 'NvidiaLowLatency' $false)) {
    Write-Host "  [NVIDIA] Applying PowerMizer performance mode and per-CPU core DPC policy..." -ForegroundColor Green
    # PowerMizer: 0 = max performance (newer drivers), 1 = adaptive
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" -Name "PowerMizerPerf" -Type REG_DWORD -Data '1'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" -Name "PowerMizerAsync" -Type REG_DWORD -Data '0'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\CurrentControlSet\Control\Video\NVIDIA\PowerMizer" -Name "PowerMizerClock" -Type REG_DWORD -Data '0'
    # Per-processor DPC policy: 1 = the processor is a DPC processor (defers non-DPC work).
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\CurrentControlSet\Control\Session Manager\kernel" -Name "DpcProfile" -Type REG_DWORD -Data '1'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\CurrentControlSet\Control\Session Manager\kernel\Processor" -Name "DpcProfile" -Type REG_DWORD -Data '1'
}

# HAGS (EnableHAGS / the GPULatency group) is implemented by the built-in plugin WinEase.Plugins.Builtin.Latency.

# ============================================================================
# 10. UI & Ergonomics
# ============================================================================
if (Test-TweakEnabled 'EnableClassicContextMenu' $true) {
    Write-Host "Enabling Windows 10 Classic Context Menu..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section ui -Tweak EnableClassicContextMenu
}

# Not wrapped in a Test-TweakEnabled check: while the setting is off, the table writes the
# light theme (OffData), so switching it off really selects the light theme.
Write-Host ("Setting the default theme ({0})..." -f $(if (Test-TweakEnabled 'EnableDarkTheme' $true) { 'dark' } else { 'light' })) -ForegroundColor Green
Invoke-WinEaseRegistryTable -Section ui -Tweak EnableDarkTheme

Invoke-WinEaseRegistryTable -Section ui -Tweak ShowFileExtensions

Invoke-WinEaseRegistryTable -Section ui -Tweak ShowHiddenFiles

Invoke-WinEaseRegistryTable -Section ui -Tweak LaunchToThisPC

Invoke-WinEaseRegistryTable -Section ui -Tweak TaskbarEndTask

# The UI preferences seen in WinUtil / Win11Debloat / Bloatynosy / Debloat-Win11
# (upstream sync 2026-10) live in config\ui-preferences.psd1. All of them are off
# by default; each one only writes the per-user hives.
#
# The table is a data file and not a nested array literal in this phase on
# purpose. The @() operator unwraps a group that holds a single entry, so a
# group with one entry arrived here as four separate strings: the four fields
# of the entry were then read one by one and reg.exe was called with an empty
# value name, an empty type and an empty data. A native call drops an empty
# argument, so reg.exe read the '/f' switch as the data and wrote a key named
# after the first character of the data, holding a value named '/t'. The next
# build found that value, reg.exe asked "Overwrite (Yes/No)?" and waited for a
# key press - the build hung in phase 10 and no ISO was produced.
$effectiveScriptDir = if ($scriptDir) { $scriptDir } elseif ($script:scriptDir) { $script:scriptDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$uiPreferencePath = Join-Path -Path $effectiveScriptDir -ChildPath "config\ui-preferences.psd1"
$uiPreferenceData = Import-PowerShellDataFile -LiteralPath $uiPreferencePath
$uiPreferenceTweaks = @($uiPreferenceData.UiPreferences)

# The keys that the broken table left behind are removed again, so an image
# that was built with the old code does not keep them. Only a key whose single
# value is named '/t' is removed - that is the signature of the bug, so a real
# key of the image is never touched.
function Remove-WinEaseBrokenUiPreferenceKey {
    param([Parameter(Mandatory = $true)][string]$HiveName, [Parameter(Mandatory = $true)][string]$KeyName)
    $hive = $null
    try {
        $hive = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($HiveName, $true)
        if (-not $hive) { return }
        $key = $hive.OpenSubKey($KeyName, $true)
        if (-not $key) { return }
        try {
            $valueNames = @($key.GetValueNames())
            if ($valueNames.Count -ne 1 -or $valueNames[0] -ne '/t') { return }
        } finally {
            $key.Close()
        }
        $hive.DeleteSubKeyTree($KeyName, $false)
        Write-Host "  -> Removed the leftover registry key '$HiveName\$KeyName' of the old UI preference table." -ForegroundColor Yellow
    } catch {
        Write-Verbose "Ignored: $($_.Exception.Message)"
    } finally {
        if ($hive) { $hive.Close() }
    }
}
foreach ($userHive in 'zNTUSER', 'zDEFAULT') {
    foreach ($brokenKey in '0', '1', '3') {
        Remove-WinEaseBrokenUiPreferenceKey -HiveName $userHive -KeyName $brokenKey | Out-Null
    }
}

foreach ($v in $uiPreferenceTweaks) {
    if (-not (Test-TweakEnabled $v.Tweak $false)) { continue }
    # An empty field would be dropped by the native call and reg.exe would read
    # the next switch as the value - the entry is skipped instead.
    $emptyFields = @('Path', 'Name', 'Type', 'Data').Where({ [string]::IsNullOrWhiteSpace([string]$v[$_]) })
    if ($emptyFields.Count -gt 0) {
        Write-Warning "Skipping the UI preference of '$($v.Tweak)': the field(s) $($emptyFields -join ', ') are empty."
        continue
    }
    foreach ($userHive in 'zNTUSER', 'zDEFAULT') {
        Invoke-WinEaseReg -Action Add -Key "HKLM\$userHive\$($v.Path)" -Name $v.Name -Type $v.Type -Data $v.Data
    }
}
Invoke-WinEaseRegistryTable -Section ui -Tweak DisableLogonBlur

Invoke-WinEaseRegistryTable -Section ui -Tweak TaskbarAlignLeft

Invoke-WinEaseRegistryTable -Section ui -Tweak HideMeetNow

Invoke-WinEaseRegistryTable -Section ui -Tweak HideSyncNotifications

Invoke-WinEaseRegistryTable -Section ui -Tweak DisableStartupSound

Invoke-WinEaseRegistryTable -Section ui -Tweak DisableLockScreen

Invoke-WinEaseRegistryTable -Section ui -Tweak DisableSleepOption

Invoke-WinEaseRegistryTable -Section ui -Tweak MenuShowDelayZero

if (Test-TweakEnabled 'TakeOwnershipContextMenu' $false) {
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\*\shell\runas" -DefaultValue -Type REG_SZ -Data "Take Ownership"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\*\shell\runas" -Name "HasLUAShield" -Type REG_SZ -Data '""'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\*\shell\runas" -Name "NoWorkingDirectory" -Type REG_SZ -Data '""'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\*\shell\runas\command" -DefaultValue -Type REG_SZ -Data 'powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -Command "& { param($p) takeown.exe /f $p; icacls.exe $p /grant administrators:F }" "%1"'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\shell\runas" -DefaultValue -Type REG_SZ -Data "Take Ownership"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\shell\runas" -Name "HasLUAShield" -Type REG_SZ -Data '""'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\shell\runas" -Name "NoWorkingDirectory" -Type REG_SZ -Data '""'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" -DefaultValue -Type REG_SZ -Data 'powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -Command "& { param($p) takeown.exe /f $p /r /d y; icacls.exe $p /grant administrators:F /t }" "%1"'
}

if (Test-TweakEnabled 'CmdAsAdminContextMenu' $false) {
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" -DefaultValue -Type REG_SZ -Data "Open Command Prompt as Administrator"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" -Name "HasLUAShield" -Type REG_SZ -Data '""'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas\command" -DefaultValue -Type REG_SZ -Data 'PowerShell -windowstyle hidden -Command \"Start-Process cmd.exe -ArgumentList ''/s,/k,pushd,\"%V\"'' -Verb RunAs\"'
}

if (Test-TweakEnabled 'PhotoViewerAssociations' $true) {
    $photoViewerAssocs = @(
        @{ Ext = ".bmp";  ProgId = "PhotoViewer.FileAssoc.Bitmap"; Friendly = "Bitmap Image" },
        @{ Ext = ".dib";  ProgId = "PhotoViewer.FileAssoc.Bitmap"; Friendly = "Bitmap Image" },
        @{ Ext = ".gif";  ProgId = "PhotoViewer.FileAssoc.Gif";    Friendly = "GIF Image" },
        @{ Ext = ".jfif"; ProgId = "PhotoViewer.FileAssoc.JFIF";   Friendly = "JPEG Image" },
        @{ Ext = ".jpe";  ProgId = "PhotoViewer.FileAssoc.Jpeg";   Friendly = "JPEG Image" },
        @{ Ext = ".jpeg"; ProgId = "PhotoViewer.FileAssoc.Jpeg";   Friendly = "JPEG Image" },
        @{ Ext = ".jpg";  ProgId = "PhotoViewer.FileAssoc.Jpeg";   Friendly = "JPEG Image" },
        @{ Ext = ".png";  ProgId = "PhotoViewer.FileAssoc.Png";    Friendly = "PNG Image" },
        @{ Ext = ".tif";  ProgId = "PhotoViewer.FileAssoc.Tiff";   Friendly = "TIFF Image" },
        @{ Ext = ".tiff"; ProgId = "PhotoViewer.FileAssoc.Tiff";   Friendly = "TIFF Image" },
        @{ Ext = ".wdp";  ProgId = "PhotoViewer.FileAssoc.Wdp";    Friendly = "Windows Media Photo" }
    )
    # The capabilities alone do not make a file type open with the classic viewer. The
    # ProgID has to exist and the per-user UserChoice cache has to be cleared: Windows
    # rejects a UserChoice key unless it contains the proprietary hash, so writing one
    # offline never worked. Without the cache the per-user class default is used.
    $photoViewerCommand = '"%SystemRoot%\System32\rundll32.exe" "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen %1'
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" -Name "ApplicationName" -Type REG_SZ -Data "Windows Photo Viewer"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" -Name "ApplicationDescription" -Type REG_SZ -Data "View pictures with Windows Photo Viewer"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" -Name "ApplicationIcon" -Type REG_SZ -Data "%SystemRoot%\System32\imageres.dll,-70"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\RegisteredApplications" -Name "Windows Photo Viewer" -Type REG_SZ -Data "SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities"
    $registeredPhotoProgIds = @($photoViewerAssocs | ForEach-Object { $_.ProgId } | Sort-Object -Unique)
    foreach ($progId in $registeredPhotoProgIds) {
        $progKey = "HKLM\zSOFTWARE\Classes\$progId"
        Invoke-WinEaseReg -Action Add -Key $progKey -DefaultValue -Type REG_SZ -Data "Windows Photo Viewer"
        Invoke-WinEaseReg -Action Add -Key "$progKey\DefaultIcon" -DefaultValue -Type REG_SZ -Data "%SystemRoot%\System32\imageres.dll,-70"
        # Do not pass the command through reg.exe: its embedded quotes make reg.exe
        # interpret the value as extra arguments, so the open\command key was never
        # created. The registry provider writes the string verbatim.
        #
        # Windows ships protected ProgIDs (notably the TIFF one) whose existing
        # shell\open key is owned by TrustedInstaller. Leave a valid existing command
        # alone; only create the missing command for the new PhotoViewer ProgIDs, and
        # never abort the whole build if one legacy key refuses the write.
        $commandKey = "Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\$progId\shell\open\command"
        $existingCommand = $null
        try {
            $existingCommand = (Get-ItemProperty -LiteralPath $commandKey -Name '(default)' -ErrorAction Stop).'(default)'
        } catch { $existingCommand = $null }
        if ("$existingCommand" -notmatch 'PhotoViewer\.dll') {
            try {
                New-Item -Path $commandKey -Force -ErrorAction Stop | Out-Null
                Set-ItemProperty -Path $commandKey -Name '(default)' -Value $photoViewerCommand -ErrorAction Stop
            } catch {
                Write-Warning "Could not register the Photo Viewer command for $progId`: $($_.Exception.Message)"
            }
        }
    }
    foreach ($pa in $photoViewerAssocs) {
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations" -Name $pa.Ext -Type REG_SZ -Data $pa.ProgId
        # Expose the ProgID in "Open with" for all users.
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Classes\$($pa.Ext)\OpenWithProgids" -Name $pa.ProgId -Type REG_NONE
        foreach ($uiHive in @('zNTUSER', 'zDEFAULT')) {
            # A stale UserChoice wins over everything below it, and it cannot be forged
            # offline (the hash depends on the user SID and the current time).
            Invoke-WinEaseReg -Action Delete -Key "HKLM\$uiHive\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($pa.Ext)\UserChoice"
            Invoke-WinEaseReg -Action Add -Key "HKLM\$uiHive\Software\Classes\$($pa.Ext)" -DefaultValue -Type REG_SZ -Data $pa.ProgId
            Invoke-WinEaseReg -Action Add -Key "HKLM\$uiHive\Software\Classes\$($pa.Ext)\OpenWithProgids" -Name $pa.ProgId -Type REG_NONE
        }
    }
}

# Japanese IME Privacy
if (Test-TweakEnabled 'DisableIMETelemetry' $true) {
    Write-Host "Configuring Japanese IME privacy opt-out..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableIMETelemetry
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
    "diagsvc"                                  = 4
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
    "IsoEnvBroker"                             = 4
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
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\$($svc.Key)" -Name "Start" -Type REG_DWORD -Data $($svc.Value)
    }
}

# Revision Tool 2.14.1 (Superfetch): ReadyBoost caches go together with SysMain.
Invoke-WinEaseRegistryTable -Section performance -Tweak DisableSuperfetch

# The services of the components the Advanced Debloat tab removes. These used to be
# printed in phase 09 and nothing else happened: the services stayed enabled, so the
# items did not do what the GUI promised. They are applied on their own, because the
# user asked for this component explicitly - they do not depend on the ServiceTrim group.
function Set-WinEaseServiceStartIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][int]$Start)
    if (-not (Invoke-WinEaseReg -Action Query -Key "HKLM\zSYSTEM\ControlSet001\Services\$Name" -PassThru)) {
        Write-Verbose "Service $Name is not in the image - nothing to set."
        return $false
    }
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\$Name" -Name "Start" -Type REG_DWORD -Data $Start
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
    # The targets below remove a service and its binary. The binary is removed by the
    # engine the user picked, so the service has to be disabled in any case - otherwise
    # the image keeps a service whose binary is gone.
    # The Defender services are only disabled when the user asked for the Defender to be
    # removed. The "Physical: Defender" target of the Advanced Debloat tab is a second way
    # to ask for the same thing, but it must never disable the Defender on its own: the
    # conflict matrix removes the target when "RemoveDefender" is off, and this guard makes
    # sure that a target that reaches this phase anyway cannot kill the Defender.
    if ($removeDefender -and (Test-WinEaseDebloatTargetSelected -Item 'Physical: Defender (complete removal) [~50MB]')) {
        $advServices["WinDefend"] = 4
        $advServices["MDCoreSvc"] = 4
        $advServices["WdNisSvc"] = 4
        $advServices["Sense"] = 4
        $advServices["SecurityHealthService"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Physical: Windows Firewall (complete removal) [~20-40MB]') {
        # only the firewall service itself: the base filtering engine (BFE) is shared
        # with other services and stays enabled
        $advServices["MpsSvc"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove SNMP service [2MB]') {
        $advServices["SNMP"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove Fax service [5MB]') {
        # the service name of the fax service is "Fax" (the binary is fxssvc.exe)
        $advServices["Fax"] = 4
    }
    if (Test-WinEaseDebloatTargetSelected -Item 'Remove Telnet/TFTP client [1MB]') {
        $advServices["Telnet"] = 4
        $advServices["TFTP"] = 4
    }
    foreach ($svc in $advServices.GetEnumerator()) {
        Write-Host "  - Disabling service: $($svc.Key) (Advanced Debloat)" -ForegroundColor Cyan
        [void](Set-WinEaseServiceStartIfPresent -Name $svc.Key -Start $svc.Value)
    }
}

# Staged AppX registrations of the packages phase 05 removed from the image.
# The offline pass removes the provisioned package and deletes its payload folder under
# "Program Files\WindowsApps", but the image keeps the STAGED copy of the inbox app
# ("AppxAllUserStore\InboxApp"). Windows installs that staged copy for the first user, so
# the app is registered while its payload is gone: it starts and renders a white window.
# Taking the staged registration out of the SOFTWARE hive prevents the installation.
if ($script:WinEaseRemovedAppxPackages -and $script:WinEaseRemovedAppxPackages.Count -gt 0) {
    $inboxRemoved = 0
    foreach ($removedPkg in $script:WinEaseRemovedAppxPackages) {
        $inboxKeys = @("HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApp\$($removedPkg.FullName)")
        if ($removedPkg.PublisherId) {
            # some builds stage the package without its version
            $inboxKeys += "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApp\$($removedPkg.ShortName)_$($removedPkg.PublisherId)"
        }
        foreach ($inboxKey in $inboxKeys) {
            if (Invoke-WinEaseReg -Action Query -Key $inboxKey -PassThru) {
                if (Invoke-WinEaseReg -Action Delete -Key $inboxKey -PassThru) { $inboxRemoved++ }
            }
        }
    }
    if ($inboxRemoved -gt 0) {
        Write-Host "  - Removed $inboxRemoved staged AppX registration(s) of the removed packages" -ForegroundColor Green
    }
}

# Windows Defender Removal / Disable
if ($removeDefender -or (Test-TweakEnabled 'RemoveDefender' $false)) {
    Write-Host "  [SECURITY WARNING] Disabling Windows Defender Real-Time Protection and security policies..." -ForegroundColor Yellow
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
    $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $reginiFile = Join-Path -Path $tempDir -ChildPath "WinEase_regini_$([System.IO.Path]::GetRandomFileName()).txt"
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
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\$drv" -Name "Start" -Type REG_DWORD -Data '4'
    }
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\WdBoot" -Name "SupportElamHive" -Type REG_DWORD -Data '0'
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Services\WdBoot" -Name "Group"
    # WdFilter is an FSFilter anti-virus minifilter; drop it from the filter group as well
    # so no file-system filter instance is bound when the stack starts.
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Services\WdFilter" -Name "Group"

    # --- Service key removal ------------------------------------------------------------
    # The service keys are deleted (not just disabled) so that a later CBS servicing pass
    # cannot re-enable them. Each operation is verified: the previous implementation
    # redirected every reg.exe call to "> $null 2>&1", so a failed delete (e.g. a key still
    # owned by TrustedInstaller) was indistinguishable from a successful one and the build
    # continued with Defender still registered.
    $defServices = @('WinDefend', 'MDCoreSvc', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc', 'webthreatdefsvc', 'webthreatdefusersvc', 'SgrmBroker', 'SgrmAgent')
    $failedDefSvc = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $defServices) {
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\$svc" -Name "Start" -Type REG_DWORD -Data '4'
        Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Services\$svc\TriggerInfo"
        Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Services\$svc"
        # Verify the key is really gone instead of trusting the exit code of a silenced call.
        if (Invoke-WinEaseReg -Action Query -Key "HKLM\zSYSTEM\ControlSet001\Services\$svc" -PassThru) {
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
    Invoke-WinEaseRegistryTable -Section defender -Tweak RemoveDefender -Unconditional
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "SecurityHealth"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe"
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy"

    # --- Windows Security UI: remove the package, not only its service -----------------
    # Remove-AppxProvisionedPackage refuses to remove Microsoft.SecHealthUI ("protected by
    # Windows"), so phase 05 removes the payload directly. Clear the staged registrations
    # and the AppRepository rows here; otherwise the first user gets a registered app with
    # no payload (a white window) or Windows re-installs it from the provisioning store.
    foreach ($secRoot in @(
        'Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications',
        'Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApp',
        'Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\PendingDeployment',
        'Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned',
        'Registry::HKEY_LOCAL_MACHINE\zSOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    )) {
        if (Test-Path -LiteralPath $secRoot) {
            Get-ChildItem -LiteralPath $secRoot -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match 'SecHealthUI' } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                }
        }
    }
    foreach ($secGlobRoot in @(
        "$scratchDir\Program Files\WindowsApps",
        "$scratchDir\Windows\SystemApps",
        "$scratchDir\ProgramData\Microsoft\Windows\AppRepository\Packages"
    )) {
        if ($scratchDir -and (Test-Path -LiteralPath $secGlobRoot)) {
            Get-ChildItem -LiteralPath $secGlobRoot -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'SecHealthUI' } |
                ForEach-Object { [void](Remove-WinEaseTreeRobust -Path $_.FullName -SafetyRoot $scratchDir) }
        }
    }

    # --- IFEO traps: the engine cannot be started even if CBS re-registers a service ---
    # A Debugger value makes Windows launch the stub instead of the requested image. The
    # services are also deleted below; this is the second line of defence for a servicing
    # pass that re-creates them.
    $defIfeoNames = @(
        'MsMpEng.exe', 'MpCmdRun.exe', 'NisSrv.exe', 'Sense.exe', 'MpCopyAccelerator.exe',
        'MpSigStub.exe', 'SecurityHealthService.exe', 'SecurityHealthSystray.exe',
        'SecurityHealthHost.exe', 'SecHealthUI.exe'
    )
    foreach ($ifeoName in $defIfeoNames) {
        $ifeoKey = "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ifeoName"
        Invoke-WinEaseReg -Action Add -Key $ifeoKey -Name "Debugger" -Type REG_SZ -Data "%SystemRoot%\System32\systray.exe"
    }
    # The Defender and Security Center scheduled tasks are re-created from the task store.
    foreach ($taskFolder in @(
        "$scratchDir\Windows\System32\Tasks\Microsoft\Windows\Windows Defender",
        "$scratchDir\Windows\System32\Tasks\Microsoft\Windows\SecurityCenter",
        "$scratchDir\Windows\System32\Tasks\Microsoft\Windows\Windows Security"
    )) {
        if ($scratchDir -and (Test-Path -LiteralPath $taskFolder)) {
            [void](Remove-WinEaseTreeRobust -Path $taskFolder -SafetyRoot $scratchDir)
        }
    }

    # Windows Defender Remover release13-rev1: the Microsoft Security core drivers of 24H2+
    # (disabled, not deleted: they are boot-start filters), the Defender ETW autologgers,
    # the Defender maintenance entries of the Ubpm scheduler, and the Settings page.
    foreach ($drv in @('MsSecCore', 'MsSecFlt', 'MsSecWfp')) {
        if (Invoke-WinEaseReg -Action Query -Key "HKLM\zSYSTEM\ControlSet001\Services\$drv" -PassThru) {
            Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Services\$drv" -Name "Start" -Type REG_DWORD -Data '4'
        }
    }
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Control\WMI\Autologger\DefenderApiLogger"
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Control\WMI\Autologger\DefenderAuditLogger"
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Control\Ubpm" -Name "CriticalMaintenance_DefenderCleanup"
    Invoke-WinEaseReg -Action Delete -Key "HKLM\zSYSTEM\ControlSet001\Control\Ubpm" -Name "CriticalMaintenance_DefenderVerification"
    # SettingsPageVisibility is a single value: keep the AI page hidden as well when
    # DisableWindowsAI wrote it above.
    $hiddenPages = @('windowsdefender')
    if (Test-TweakEnabled 'DisableWindowsAI' $true) { $hiddenPages = @('aicomponents') + $hiddenPages }
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "SettingsPageVisibility" -Type REG_SZ -Data ("hide:" + ($hiddenPages -join ';'))
}

# ============================================================================
# GUI tweak toggles (keys match $script:AllTweakDefs in WinEasebuilder.ps1)
# ============================================================================
Invoke-WinEaseRegistryTable -Section setup -Tweak BypassNetworkRequirement

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableAdvertisingId

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableAppPrivacy

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableDefenderSecurityCenter

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableCortana

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableTimeline

if (Test-TweakEnabled 'DisableDiagnosticData' $true) {
    Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableDiagnosticData
    # WinUtil main (config/tweaks.json, WPFTweaksTelemetry): the sampling period
    # of the telemetry client is removed, not only its counter.
    foreach ($userHive in 'zNTUSER', 'zDEFAULT') {
        Invoke-WinEaseReg -Action Delete -Key "HKLM\$userHive\Software\Microsoft\Siuf\Rules" -Name "PeriodInNanoSeconds"
    }
}

Invoke-WinEaseRegistryTable -Section performance -Tweak TuneMemoryAndPaging

Invoke-WinEaseRegistryTable -Section privacy -Tweak DisableBackgroundApps

Invoke-WinEaseRegistryTable -Section performance -Tweak DisableGameDVR

Invoke-WinEaseRegistryTable -Section performance -Tweak DisableFastStartup

Invoke-WinEaseRegistryTable -Section ui -Tweak TransparentShortcutOverlay

Invoke-WinEaseRegistryTable -Section performance -Tweak OptimizeVisualEffects

Invoke-WinEaseRegistryTable -Section ui -Tweak CleanContextMenus

# ReviOS 26.10 / main (registry/explorer/search.yml) and Revision Tool 2.14.x
# (src/lib/core/services/win_registry_service.dart): the two shell features that
# let SearchHost start a WebView2 runtime are switched off with an obfuscated
# FeatureManagement override. Without them the search box keeps a WebView2
# process alive in the background, which is one of the biggest idle RAM costs of
# a stock Windows 11 install.
if (Test-TweakEnabled 'DisableSearchWebView2' $true) {
    Write-Host "Disabling the WebView2 search features..." -ForegroundColor Green
    $searchWebView2Features = @(
        @{ Id = 43998308; Name = 'SearchWebView2_Master' },
        @{ Id = 37926450; Name = 'WebView2_SearchHost' }
    )
    foreach ($feature in $searchWebView2Features) {
        $overrideId = ConvertTo-WinEaseFeatureIdOverride -FeatureId $feature.Id
        # Policy location: the variant the ReviOS playbook writes.
        Invoke-WinEaseReg -Action Add -Key "HKLM\zSYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides" -Name "$overrideId" -Type REG_DWORD -Data '0'
        # Primary location: the variant the Revision Tool writes.
        $overrideKey = "HKLM\zSYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\$overrideId"
        Invoke-WinEaseReg -Action Add -Key $overrideKey -Name "EnabledState" -Type REG_DWORD -Data '1'
        Invoke-WinEaseReg -Action Add -Key $overrideKey -Name "EnabledStateOptions" -Type REG_DWORD -Data '0'
        Invoke-WinEaseReg -Action Add -Key $overrideKey -Name "Variant" -Type REG_DWORD -Data '0'
        Invoke-WinEaseReg -Action Add -Key $overrideKey -Name "VariantPayload" -Type REG_DWORD -Data '0'
        Invoke-WinEaseReg -Action Add -Key $overrideKey -Name "VariantPayloadKind" -Type REG_DWORD -Data '0'
    }
}

# Personalization unlock & watermark suppression
if ($bypassActivationRestrictions -or (Test-TweakEnabled 'BypassActivationRestrictions' $false)) {
    Write-Host "Applying Windows personalization unlock policies..." -ForegroundColor Green
    Invoke-WinEaseRegistryTable -Section security -Tweak BypassActivationRestrictions -Unconditional
    # Do not force NoLockScreen=0 here: the personalization unlock used to overwrite the
    # DisableLockScreen option. The value follows the user's lock-screen choice.
    $noLockScreenValue = if (Test-TweakEnabled 'DisableLockScreen' $false) { 1 } else { 0 }
    Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Type REG_DWORD -Data $noLockScreenValue
}

# OEM Information Branding
Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" -Name "Manufacturer" -Type REG_SZ -Data "WinEase Project"
Invoke-WinEaseReg -Action Add -Key "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" -Name "SupportURL" -Type REG_SZ -Data "https://github.com/gh459/WinEase"

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

# Plugin contributions (IRegistryContributor, IServiceStartContributor). The registry entries
# run through the same table runner as config\registry (build range and tweak gate included).
if (Get-Command -Name Get-WinEasePluginContributions -ErrorAction SilentlyContinue) {
    $pluginRegistryEntries = @(Get-WinEasePluginContributions -Kind Registry)
    if ($pluginRegistryEntries.Count -gt 0) {
        Write-Host "  [Plugins] Applying $($pluginRegistryEntries.Count) registry value(s) contributed by plugins..." -ForegroundColor DarkCyan
        if ($DryRun) {
            Write-Host "  [DryRun] Would write the plugin registry values." -ForegroundColor DarkYellow
        } else {
            Invoke-WinEaseRegistryTable -Entries $pluginRegistryEntries
        }
    }
    foreach ($pluginService in @(Get-WinEasePluginContributions -Kind Service)) {
        Write-Host "  [Plugin $($pluginService.PluginId)] service $($pluginService.Name) -> Start=$($pluginService.Start)" -ForegroundColor DarkCyan
        if (-not $DryRun) { [void](Set-WinEaseServiceStartIfPresent -Name $pluginService.Name -Start $pluginService.Start) }
    }
}

# M2: User extension actions (Registry)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType Registry -ScratchDir $scratchDir -DryRun:$DryRun | Out-Null } catch { Write-Warning "User extension actions (Registry) failed: $($_.Exception.Message)" }
}

# P1-01: a registry write that reg.exe refused no longer passes unnoticed.
Assert-WinEaseRegistryWrites -Stage 'phase 10 (registry)' -Strict:([bool]$script:StrictRegistryWrites)
