# WinEaseGuiCore.ps1 - UI-independent GUI logic shared by the windows and the Migration Assistant
# Dot-sourced by gui\WinEaseGui.ps1 (WinForms window), gui\WinEaseWinUiHost.ps1 (WinUI 3 host) and
# tools\migrator\WinEase-Migrator.ps1. Function and variable definitions only; it loads no
# WinForms/Drawing assembly, so the WinUI 3 host can use it without the classic window.
# Holds: display language and UI strings, Advanced Debloat engine/items, source candidates, preset diff
# text, the draft config, and the migration (Tab 8) helpers.

# Repository root (this file lives in <repo>\lib)
$script:WinEaseGuiRepoRoot = Split-Path -Parent $PSScriptRoot
# Folder of the GUI scripts; gui\WinEaseGui.ps1 and gui\WinEaseWinUiHost.ps1 set it to gui\. Only a fallback here.
if (-not $script:WinEaseGuiDir) { $script:WinEaseGuiDir = $PSScriptRoot }

# Default backup folder for the migration tools: <base>\<folder name below>.
# Base 'Profile' = the user profile (GUI Tab 8), 'Documents' = the Documents folder (WinEase-Migrator).
$script:WinEaseMigrationBackupFolderName = 'WinEase_migration_backup'
function Get-WinEaseDefaultMigrationBackupPath {
    param([ValidateSet('Profile', 'Documents')][string]$Base = 'Profile')
    $baseDir = if ($Base -eq 'Documents') { [Environment]::GetFolderPath('MyDocuments') } else { $env:USERPROFILE }
    return (Join-Path -Path $baseDir -ChildPath $script:WinEaseMigrationBackupFolderName)
}

# =========================================================================
# Display language (English / Japanese). Display only: values that reach the build
# (settings, Advanced Debloat item names, ...) never change with the language.
# The strings live in config\ui-strings\<lang>.json (UTF-8) next to the tweak definitions, not in this
# ASCII-only file. Missing in the chosen language -> English table -> the key itself.
# =========================================================================
$script:WinEaseUiLanguage = 'en'
$script:WinEaseUiTables = @{}
$script:WinEaseUiLanguages = @('en', 'ja')

# Folder holding en.json / ja.json: config\ui-strings in the repository, ui-strings next to this file when bundled
function Get-WinEaseUiStringsDir {
    foreach ($c in @((Join-Path $script:WinEaseGuiRepoRoot 'config\ui-strings'), (Join-Path $script:WinEaseGuiDir 'ui-strings'))) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    return $null
}

# One language table as a hashtable (empty when the file is missing or unreadable); read once, then cached
function Get-WinEaseUiTable {
    param([Parameter(Mandatory = $true)][string]$Language)
    if ($script:WinEaseUiTables.ContainsKey($Language)) { return $script:WinEaseUiTables[$Language] }
    $table = @{}
    $dir = Get-WinEaseUiStringsDir
    if ($dir) {
        $file = Join-Path -Path $dir -ChildPath "$Language.json"
        try {
            if (Test-Path -LiteralPath $file) {
                $json = [System.IO.File]::ReadAllText($file, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $script:WinEaseUiTables[$Language] = $table
    return $table
}

# Display string for -Key in the current (or -Language) language; -Format fills {0}, {1}, ... placeholders.
# Fallback order: that language -> English -> -Default -> the key.
function Get-WinEaseUiString {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [object[]]$Format = @(),
        [string]$Language,
        [string]$Default
    )
    if (-not $Language) { $Language = $script:WinEaseUiLanguage }
    $text = $null
    $table = Get-WinEaseUiTable -Language $Language
    if ($table.ContainsKey($Key)) {
        $text = $table[$Key]
    } elseif ($Language -ne 'en') {
        $english = Get-WinEaseUiTable -Language 'en'
        if ($english.ContainsKey($Key)) { $text = $english[$Key] }
    }
    if ($null -eq $text) { $text = if ($PSBoundParameters.ContainsKey('Default')) { $Default } else { $Key } }
    if ($Format.Count -gt 0) {
        try { $text = $text -f $Format } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    return $text
}

# Where the chosen language is remembered between runs
function Get-WinEaseGuiSettingsPath {
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'WinEase\gui-settings.json')
}

function Get-WinEaseGuiSavedLanguage {
    $path = Get-WinEaseGuiSettingsPath
    try {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $saved = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            $lang = "$($saved.UiLanguage)".ToLower()
            if ($script:WinEaseUiLanguages -contains $lang) { return $lang }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $null
}

# Remember the language (other keys of the file are kept). Failing to save never stops the GUI.
function Save-WinEaseGuiLanguage {
    param([Parameter(Mandatory = $true)][string]$Language)
    $path = Get-WinEaseGuiSettingsPath
    if (-not $path) { return }
    try {
        $settings = [ordered]@{}
        if (Test-Path -LiteralPath $path) {
            try {
                $old = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                foreach ($p in $old.PSObject.Properties) { $settings[$p.Name] = $p.Value }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        $settings['UiLanguage'] = $Language
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [System.IO.File]::WriteAllText($path, ($settings | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# Language to use: -Requested (the -UiLanguage argument), then $env:WINEASE_UI_LANGUAGE, then the saved choice,
# then the OS display language (ja -> ja, anything else -> en)
function Resolve-WinEaseUiLanguage {
    param([string]$Requested)
    foreach ($candidate in @($Requested, $env:WINEASE_UI_LANGUAGE)) {
        $lang = "$candidate".Trim().ToLower()
        if ($script:WinEaseUiLanguages -contains $lang) { return $lang }
    }
    $saved = Get-WinEaseGuiSavedLanguage
    if ($saved) { return $saved }
    try {
        if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') { return 'ja' }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return 'en'
}

function Set-WinEaseUiLanguage {
    param([Parameter(Mandatory = $true)][ValidateSet('en', 'ja')][string]$Language)
    $script:WinEaseUiLanguage = $Language
}

# Checkbox / tooltip text of a tweak: the language table, then DescriptionJa of a user tweak (Japanese only),
# then the Description from config\schema.psd1
function Get-WinEaseTweakDescription {
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][hashtable]$Def)
    $fallback = [string]$Def.Description
    if ($script:WinEaseUiLanguage -eq 'ja' -and $Def.DescriptionJa) { $fallback = [string]$Def.DescriptionJa }
    return (Get-WinEaseUiString -Key "Tweak.$Key.Description" -Default $fallback)
}

# Display name of a list entry whose real value must not change with the language (Advanced Debloat items)
if (-not ('WinEaseListItem' -as [type])) {
    Add-Type -TypeDefinition @'
public class WinEaseListItem
{
    public string Value;
    public string Display;
    public WinEaseListItem(string value, string display) { Value = value; Display = display; }
    public override string ToString() { return Display; }
}
'@
}

# The real (language independent) value of a list entry: a plain string, or the Value of a WinEaseListItem
function Get-WinEaseListItemValue {
    param($Item)
    if ($Item -is [WinEaseListItem]) { return $Item.Value }
    return "$Item"
}

# Display text of an Advanced Debloat item. The English item text is the real value (phases\09 matches it);
# the language table holds its translation under the key 'Debloat:<English text>'.
function Get-WinEaseDebloatItemText {
    param([Parameter(Mandatory = $true)][string]$Item)
    return (Get-WinEaseUiString -Key "Debloat:$Item" -Default $Item)
}
$script:WinEaseDebloatDisplayText = { param($item) Get-WinEaseDebloatItemText -Item $item }

# Keeps a WinForms window repainting while a job runs. Without WinForms loaded (WinUI 3 host) there is no
# window of ours to repaint, so this does nothing.
function Invoke-WinEaseGuiDoEvents {
    $app = 'System.Windows.Forms.Application' -as [type]
    if ($app) { $app::DoEvents() }
}

# Runs -Action (called with -ArgumentList) while -Button is disabled and -Form shows the wait cursor;
# both are restored afterwards, also when the action throws. The action sees only its parameters,
# not the locals of the caller. Returns what the action returns.
function Invoke-WinEaseGuiBusy {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [object[]]$ArgumentList = @(),
        [object]$Button,
        [object]$Form
    )
    if ($Button) { $Button.Enabled = $false }
    if ($Form) { $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    Invoke-WinEaseGuiDoEvents
    try {
        return (& $Action @ArgumentList)
    } finally {
        if ($Button) { $Button.Enabled = $true }
        if ($Form) { $Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
}

# Disable the button, show the wait cursor, Start-Job, keep the window repainting (DoEvents) until the job
# ends, then restore both. -ScriptBlock gets -ArgumentList. Returns @{ Output; Error; Errors }:
# Output = everything the job emitted, Error = why the job itself failed, Errors = its error stream.
function Invoke-WinEaseGuiBackgroundJob {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [object]$Button,
        [object]$Form
    )
    return (Invoke-WinEaseGuiBusy -Button $Button -Form $Form -ArgumentList @($ScriptBlock, $ArgumentList) -Action {
        param($jobScript, $jobArgs)
        $job = Start-Job -ScriptBlock $jobScript -ArgumentList $jobArgs
        while ($job.State -eq 'Running') {
            Invoke-WinEaseGuiDoEvents
            Start-Sleep -Milliseconds 100
        }
        $output = @()
        $jobError = $null
        $errors = [System.Collections.Generic.List[string]]::new()
        if ($job.State -eq 'Failed') {
            $jobError = $job.ChildJobs[0].JobStateInfo.Reason.Message
        } else {
            foreach ($e in $job.ChildJobs[0].Error) { $errors.Add("$e") }
            $output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{ Output = $output; Error = $jobError; Errors = $errors }
    })
}

# =========================================================================
# Advanced Debloat: target selection + execution engine (PowerShell / Rust)
# =========================================================================
# The engine bindings come from config\schema.psd1 (DebloatEngines), the single source of
# truth. The builder loads that table already; the GUI loads it itself when it runs
# without the builder (the automated GUI tests do that).
function Get-WinEaseDebloatEngineDefs {
    if ($script:WinEaseDebloatEngineDefs) { return $script:WinEaseDebloatEngineDefs }
    $defs = @{}
    $source = $null
    if ((Get-Variable -Name 'WinEaseDebloatEngines' -Scope Script -ErrorAction SilentlyContinue) -and $script:WinEaseDebloatEngines) {
        $source = $script:WinEaseDebloatEngines
    } else {
        $cfgPath = Join-Path -Path $script:WinEaseGuiRepoRoot -ChildPath 'config\schema.psd1'
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $cfg = Import-PowerShellDataFile -LiteralPath $cfgPath
                $source = @{}
                foreach ($d in @($cfg.DebloatEngines)) {
                    if (-not $d -or -not $d.Item) { continue }
                    $source[[string]$d.Item] = $d
                }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }
    if ($source) {
        foreach ($k in $source.Keys) {
            $d = $source[$k]
            $defs[[string]$k] = @{ Engines = @($d.Engines); Default = [string]$d.Default }
        }
    }
    $script:WinEaseDebloatEngineDefs = $defs
    return $defs
}

# The engine of a target: the user's choice wins, otherwise the registered default.
function Get-WinEaseDebloatEngine {
    param([string]$Item, [hashtable]$EngineDefs, [hashtable]$EngineSelection)
    $allowed = @('PowerShell', 'Rust')
    $fallback = 'PowerShell'
    if ($EngineDefs -and $EngineDefs.Contains($Item)) {
        $allowed = @($EngineDefs[$Item].Engines)
        if ($EngineDefs[$Item].Default) { $fallback = [string]$EngineDefs[$Item].Default }
    }
    if ($EngineSelection -and $EngineSelection.Contains($Item)) {
        $chosen = [string]$EngineSelection[$Item]
        if ($allowed -contains $chosen) { return $chosen }
    }
    if ($allowed -contains $fallback) { return $fallback }
    if ($allowed.Count -gt 0) { return [string]$allowed[0] }
    return $fallback
}

# The selected targets and the engine of every target of a debloat grid
function Get-WinEaseDebloatGridState {
    param([Parameter(Mandatory = $true)][object]$Grid)
    $selected = [System.Collections.Generic.List[string]]::new()
    $engines = @{}
    for ($i = 0; $i -lt $Grid.Rows.Count; $i++) {
        $row = $Grid.Rows[$i]
        $item = [string]$row.Tag
        if ([bool]$row.Cells['On'].Value) { $selected.Add($item) }
        $engines[$item] = [string]$row.Cells['Engine'].Value
    }
    return @{ Selected = $selected.ToArray(); Engines = $engines }
}

# Detected Windows 11 media drives and ISO files (shared by the WinForms and WinUI 3 windows)
function Get-WinEaseGuiSourceCandidates {
    $detectedSources = [System.Collections.Generic.List[string]]::new()
    foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $psd.Root) { continue }
        $r = $psd.Root.TrimEnd('\')
        $wim = Join-Path -Path "$r\sources" -ChildPath "install.wim"
        $esd = Join-Path -Path "$r\sources" -ChildPath "install.esd"
        $vol = Get-Volume -DriveLetter ($r.TrimEnd(':')) -ErrorAction SilentlyContinue
        $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
        if ((Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 500MB)) {
            $detectedSources.Add("$r\$volLabel (Windows 11 Media - install.wim)")
        } elseif ((Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -gt 500MB)) {
            $detectedSources.Add("$r\$volLabel (Windows 11 Media - install.esd)")
        }
    }
    $desktopDir = Join-Path -Path $env:USERPROFILE -ChildPath "Desktop"
    $downloadsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
    foreach ($p in @("E:\", "D:\", "C:\", (Split-Path -Parent $script:WinEaseGuiRepoRoot), $env:USERPROFILE, $desktopDir, $downloadsDir)) {
        if (Test-Path -LiteralPath $p) {
            $foundIsos = Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 3GB -and ($_.Name -like "*Win11*" -or $_.Name -like "*Windows11*" -or $_.Name -like "*26300*" -or $_.Name -like "*24H2*") -and $_.Name -notlike "*WinEase*" }
            foreach ($iso in $foundIsos) { $detectedSources.Add($iso.FullName) }
        }
    }
    return ,$detectedSources
}

# Label of the "current window" entry in the Preset Diff dialog
$script:WinEaseGuiCurrentSettingsLabel = '(Current window settings)'

# Diff text between two sources: a preset name or the current window settings
function Get-WinEaseGuiPresetDiffText {
    param([hashtable]$Gui, [string]$From, [string]$To)
    $resolved = @()
    foreach ($name in @($From, $To)) {
        if ($name -eq $script:WinEaseGuiCurrentSettingsLabel -or $name -eq (Get-WinEaseUiString 'Dlg.PresetDiff.CurrentSettings')) { $resolved += , (Get-WinEaseGuiDraftConfig -Gui $Gui) } else { $resolved += , $name }
    }
    $diff = Compare-WinEaseConfig -ReferenceConfig $resolved[0] -DifferenceConfig $resolved[1]
    return (Format-WinEaseConfigDiff -DiffResult $diff)
}

# Validate the form and fill $Gui.Result; returns $false (after a message) if input is invalid
function Get-WinEaseGuiDraftConfig {
    param([hashtable]$Gui)
    $cfg = @{}
    if ($Gui.ComponentCheckboxes) {
        foreach ($k in $Gui.ComponentCheckboxes.Keys) {
            $cfg[$k] = [bool]$Gui.ComponentCheckboxes[$k].Checked
        }
    }
    $resolvedTweaks = [ordered]@{}
    if ($Gui.TweakCheckboxes) {
        foreach ($k in $Gui.TweakCheckboxes.Keys) {
            $resolvedTweaks[$k] = [bool]$Gui.TweakCheckboxes[$k].Checked
        }
    }
    $cfg['TweakSettings'] = $resolvedTweaks
    $stdSelected = @()
    $expSelected = @()
    $engineSel = @{}
    if ($Gui.GrdStd) {
        $st = Get-WinEaseDebloatGridState -Grid $Gui.GrdStd
        $stdSelected = @($st.Selected)
        $engineSel = $st.Engines
    }
    if ($Gui.GrdExp) {
        $st = Get-WinEaseDebloatGridState -Grid $Gui.GrdExp
        $expSelected = @($st.Selected)
        foreach ($k in $st.Engines.Keys) { $engineSel[$k] = $st.Engines[$k] }
    }
    $cfg['AdvancedDebloatStandard'] = $stdSelected
    $cfg['AdvancedDebloatExperimental'] = $expSelected
    $cfg['DebloatEngineSelection'] = $engineSel
    return $cfg
}

# Advanced Debloat items of Tab 7 (and of the WinUI 3 window). The English text is the value phases\09 matches.
$script:WinEaseDebloatStandardItems = @(
    "Remove PatchCache (dir delete) [200-500MB]",
    "Remove Delivery Optimization cache (dir delete) [100-500MB]",
    "Remove non-Japanese language packs (DISM) [200-500MB]",
    "Remove non-essential fonts (file delete) [50-100MB]",
    "WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]",
    "Remove pagefile.sys (pagefile disable) [4-16GB]",
    "Remove hiberfil.sys (powercfg /h off) [4-16GB]",
    "Remove swapfile.sys (pagefile disable) [256MB-1GB]",
    "Remove Provisioned AppX (list-based) [100-300MB]",
    "Remove Windows Media Player (component) [50-100MB]",
    "Remove Remote Desktop host (service + binary) [30-50MB]",
    "Remove Bluetooth stack (service + binary) [20-40MB]",
    "Remove Print Spooler (service + binary) [20-30MB]",
    "Remove touch/pen/ink components [20-30MB]",
    "Remove accessibility tools [15-25MB]",
    "Remove help files [10-20MB]",
    "Remove non-Japanese IME [5-15MB]",
    "Remove event logs [10-50MB]",
    "Remove crash dumps [varies]",
    "Remove Provisioning packages [5-10MB]",
    "Remove Windows Sandbox [10-20MB]",
    "Remove WSL / VM Platform [20-40MB]",
    "Remove .NET Framework 3.5 [100MB]",
    "Remove Windows PowerShell ISE [5MB]",
    "Remove Steps Recorder [2MB]",
    "Remove Telnet/TFTP client [1MB]",
    "Remove SNMP service [2MB]",
    "Remove Windows Identity Foundation [10MB]",
    "Remove Fax service [5MB]",
    "Remove XPS Viewer [5MB]"
)

$script:WinEaseDebloatExperimentalItems = @(
    "Physical: Edge / WebView2 (complete removal) [~200MB]",
    "Physical: Defender (complete removal) [~50MB]",
    "Physical: Cortana / Search (complete removal) [~100MB]",
    "Physical: OneDrive (complete removal) [~50MB]",
    "Physical: Telemetry/DiagTrack (complete removal) [~30MB]",
    "Physical: Hyper-V / Virtualization stack [~200-400MB]",
    "Physical: IIS (Web server) [~50-100MB]",
    "Physical: Windows Firewall (complete removal) [~20-40MB]",
    "Physical: BitLocker (complete removal) [~30-50MB]",
    "Physical: Windows Search index (complete removal) [varies]",
    "Physical: Windows.old (complete removal) [varies]",
    "Physical: Temp files (complete removal) [varies]",
    "Physical: Memory.dmp (complete removal) [varies]",
    "Physical: Minidump (complete removal) [varies]"
)

# --- Tab 8 (Migration & Backup) helpers ---------------------------------------------------------

# Backup destination typed in Tab 8 (a default outside the personal folders when empty)
function Get-WinEaseGuiMigrationRoot {
    param([hashtable]$Gui)
    $root = ''
    if ($Gui.MigRoot) { $root = $Gui.MigRoot.Text.Trim() }
    if (-not $root) { $root = Get-WinEaseDefaultMigrationBackupPath }
    return $root
}

# Checked personal folders -> @{ Category = real path } (only folders that exist)
function Get-WinEaseGuiMigrationFolderMap {
    param([hashtable]$Gui)
    if (-not $Gui.MigFolders) { return @{} }
    return (Get-WinEaseMigrationFolderMapFromNames -Names @($Gui.MigFolders.CheckedItems | ForEach-Object { "$_" }))
}

# Personal folder names (Documents, Desktop, ...) -> @{ Category = real path } (only folders that exist)
function Get-WinEaseMigrationFolderMapFromNames {
    param([string[]]$Names = @())
    $map = @{}
    foreach ($name in $Names) {
        $path = switch ("$name") {
            'Documents' { [Environment]::GetFolderPath('MyDocuments') }
            'Desktop'   { [Environment]::GetFolderPath('Desktop') }
            'Pictures'  { [Environment]::GetFolderPath('MyPictures') }
            'Videos'    { [Environment]::GetFolderPath('MyVideos') }
            'Downloads' { Join-Path $env:USERPROFILE 'Downloads' }
            default     { '' }
        }
        if ($path -and (Test-Path -LiteralPath $path)) { $map["$name"] = $path }
    }
    return $map
}

# Loads the migration engine (tools\migrator) on first use and fills the rule list. Called once from Tab 8.
function Initialize-WinEaseGuiMigrationRules {
    param($List)
    $migRuleRows = @()
    $migRuleIds = @()
    try {
        . (Join-Path $script:WinEaseGuiRepoRoot 'tools\migrator\WinEaseMigration.ps1')
        $migRulesData = Get-WinEaseMigrationRules
        foreach ($r in (@($migRulesData.GameRules) + @($migRulesData.AppConfigRules))) {
            if (-not $r -or -not $r.Id) { continue }
            $migRuleRows += "$($r.Id) - $($r.Name)"
            $migRuleIds += [string]$r.Id
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if ($migRuleRows.Count -eq 0) {
        # Placeholder row only: the list is disabled so it can never be checked or passed as a rule Id
        [void]$List.Items.Add((Get-WinEaseUiString 'Mig.NoRules'))
        $List.Enabled = $false
    } else {
        foreach ($row in $migRuleRows) { [void]$List.Items.Add($row) }
    }
    $List.Tag = $migRuleIds
}

# Ids of the checked migration rules. The list holds display rows only; the Ids live in its Tag.
function Get-WinEaseGuiMigrationRuleIds {
    param([hashtable]$Gui)
    $ids = @()
    $list = $Gui.MigRulesList
    if (-not $list -or -not $list.Enabled) { return $ids }
    $known = @($list.Tag)
    foreach ($i in $list.CheckedIndices) {
        if ($i -lt $known.Count -and $known[$i]) { $ids += [string]$known[$i] }
    }
    return $ids
}

# Parameters for Start-WinEaseMigrationBackup built from the current Tab 8 state
function Get-WinEaseGuiBackupArgs {
    param([hashtable]$Gui)
    $a = @{
        BackupRoot = (Get-WinEaseGuiMigrationRoot -Gui $Gui)
        RuleIds    = @(Get-WinEaseGuiMigrationRuleIds -Gui $Gui)
        FolderMap  = (Get-WinEaseGuiMigrationFolderMap -Gui $Gui)
    }
    if ($Gui.MigExcludeSecrets -and -not $Gui.MigExcludeSecrets.Checked) { $a['IncludeSecrets'] = $true }
    return $a
}

function Get-WinEaseGuiConflictPolicy {
    param([hashtable]$Gui)
    if ($Gui.MigConflict -and $Gui.MigConflict.SelectedItem) { return [string]$Gui.MigConflict.SelectedItem }
    return 'BackupExisting'
}

# Readiness check against the settings currently shown in the window (not the start-up settings)
function Get-WinEaseGuiRecoveryReadiness {
    param([hashtable]$Gui)
    $draft = Get-WinEaseGuiDraftConfig -Gui $Gui
    return Test-WinEaseRecoveryReadiness -Config $draft
}

# Runs tools\migrator\WinEaseMigration.ps1 code in a background job while the window keeps repainting.
# -Script is the text of a script block that takes one parameter (the hashtable in -Arguments).
# Errors written to the job's error stream are returned even when the job itself completed.
function Invoke-WinEaseGuiMigrationJob {
    param([string]$RepoRoot, [string]$Script, [hashtable]$Arguments = @{}, [object]$Button, [object]$Form)
    $o = Invoke-WinEaseGuiBackgroundJob -Button $Button -Form $Form -ArgumentList $RepoRoot, $Script, $Arguments -ScriptBlock {
        param($repoRoot, $inner, $jobArgs)
        Set-Location -LiteralPath $repoRoot
        # The migration engine uses the shared helpers (relative paths, path boundaries,
        # the restore path validation). A job starts with an empty session state, so
        # both files are loaded here.
        $helpers = Join-Path $repoRoot 'WinEasehelpers.ps1'
        if (Test-Path -LiteralPath $helpers) { . $helpers }
        . (Join-Path $repoRoot 'tools\migrator\WinEaseMigration.ps1')
        & ([scriptblock]::Create($inner)) $jobArgs
    }
    $result = $null
    if (-not $o.Error -and @($o.Output).Count -gt 0) { $result = @($o.Output)[-1] }
    return [PSCustomObject]@{ Result = $result; Error = $o.Error; Errors = $o.Errors }
}

# Checks every file recorded in migration-manifest.json: present and (when recorded) matching SHA-256
function Test-WinEaseGuiBackupIntegrity {
    param([hashtable]$a)
    $root = $a.BackupRoot
    $manifestPath = Join-Path -Path $root -ChildPath 'migration-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No migration-manifest.json in $root" }
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $checked = 0
    $problems = @()
    foreach ($e in @($m.Entries)) {
        $src = Join-Path -Path $root -ChildPath $e.RelativePath
        if ($e.Category) { $src = Join-Path -Path (Join-Path -Path $root -ChildPath $e.Category) -ChildPath $e.RelativePath }
        if (-not (Test-Path -LiteralPath $src)) { $alt = Join-Path -Path $root -ChildPath $e.RelativePath; if (Test-Path -LiteralPath $alt) { $src = $alt } }
        $checked++
        if (-not (Test-Path -LiteralPath $src)) { $problems += "Missing: $($e.RelativePath)"; continue }
        if ($e.Sha256) {
            $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
            if ($h -ne $e.Sha256) { $problems += "Hash mismatch: $($e.RelativePath)" }
        }
    }
    return [PSCustomObject]@{ Checked = $checked; Problems = $problems }
}

# Source text typed or picked in the window -> the -SourceDrive value (a drive letter like E: or an ISO path)
function Resolve-WinEaseGuiSource {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -match '^([A-Za-z]:)') {
        $candLetter = $matches[1]
        # A plain string: Join-Path throws for a drive letter that does not exist
        if (Test-Path -LiteralPath "$candLetter\sources\install.wim") { return $candLetter }
        if ($Text.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $Text)) { return $Text }
        return $candLetter
    }
    return $Text
}

# Workspace folder used when the box is left empty
function Get-WinEaseGuiDefaultWorkDir {
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    return (Join-Path -Path $docsDir -ChildPath "WinEase_workspace")
}
