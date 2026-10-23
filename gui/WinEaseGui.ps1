# WinEaseGui.ps1 - WinForms GUI for WinEasebuilder.ps1
# Dot-sourced by WinEasebuilder.ps1 only when a GUI can be shown (-GUI or menu option [7]).
# Needs $script:AllTweakDefs, $script:ComponentDefs and Get-WinEasePreset from the builder.
#
# Event handlers never read locals of the function that built the form: by click time that
# scope may be gone. A handler gets its target from $this.Tag, or the shared GUI context
# (controls, checkbox tables, result) from $this.FindForm().Tag.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Repository root (this file lives in <repo>\gui)
$script:WinEaseGuiRepoRoot = Split-Path -Parent $PSScriptRoot

# The user extensibility engine (user tweaks, presets, custom scripts, Tab 10). Loading it inside a
# function would define its functions in that function's scope only, so it is loaded here once. The
# migration bundle has no lib\ folder: the file is simply absent there and the tab reports it.
$script:WinEaseExtensionsPath = Join-Path -Path $script:WinEaseGuiRepoRoot -ChildPath 'lib\WinEaseExtensions.ps1'
if (Test-Path -LiteralPath $script:WinEaseExtensionsPath) { . $script:WinEaseExtensionsPath }

# Default backup folder for the migration tools: <base>\<folder name below>.
# Base 'Profile' = the user profile (GUI Tab 8), 'Documents' = the Documents folder (WinEase-Migrator).
$script:WinEaseMigrationBackupFolderName = 'WinEase_migration_backup'
function Get-WinEaseDefaultMigrationBackupPath {
    param([ValidateSet('Profile', 'Documents')][string]$Base = 'Profile')
    $baseDir = if ($Base -eq 'Documents') { [Environment]::GetFolderPath('MyDocuments') } else { $env:USERPROFILE }
    return (Join-Path -Path $baseDir -ChildPath $script:WinEaseMigrationBackupFolderName)
}

# The one colour table of the GUI (and of tools\migrator\WinEase-Migrator.ps1, which loads this file)
$script:WinEaseGuiColors = @{
    Text       = [System.Drawing.Color]::FromArgb(235, 238, 245)  # default text
    Input      = [System.Drawing.Color]::FromArgb(35, 38, 46)     # text boxes, lists, combo boxes
    Accent     = [System.Drawing.Color]::FromArgb(0, 190, 255)    # captions, group titles
    Button     = [System.Drawing.Color]::FromArgb(45, 50, 60)     # flat button face
    Primary    = [System.Drawing.Color]::FromArgb(0, 120, 215)    # build / OK button
    Window     = [System.Drawing.Color]::FromArgb(26, 28, 34)     # main window and tab pages
    Header     = [System.Drawing.Color]::FromArgb(18, 20, 24)     # header and bottom panels
    Bar        = [System.Drawing.Color]::FromArgb(20, 22, 28)     # button bars
    Dialog     = [System.Drawing.Color]::FromArgb(24, 26, 32)     # small dialogs
    DialogAlt  = [System.Drawing.Color]::FromArgb(24, 26, 31)     # Advanced Debloat dialog, migrator window
    Muted      = [System.Drawing.Color]::FromArgb(148, 163, 184)  # secondary text
    Subtle     = [System.Drawing.Color]::FromArgb(160, 165, 175)  # sub-title text
    Warn       = [System.Drawing.Color]::FromArgb(255, 140, 100)  # notices, load errors
    Danger     = [System.Drawing.Color]::FromArgb(255, 100, 100)  # destructive options
}

# =========================================================================
# Display language (English / Japanese). Display only: values that reach the build
# (settings, Advanced Debloat item names, ...) never change with the language.
# The strings live in config\ui-strings\<lang>.json (UTF-8) next to the tweak definitions, not in this
# ASCII-only file. Missing in the chosen language -> English table -> the key itself.
# =========================================================================
$script:WinEaseGuiDir = $PSScriptRoot
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

# =========================================================================
# Control helpers
# =========================================================================

# Flat dark button; -Tag carries whatever the -OnClick handler needs (read it as $this.Tag)
function New-WinEaseButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Color]$BackColor = $script:WinEaseGuiColors.Button,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White,
        [System.Drawing.Font]$Font,
        [object]$Tag,
        [scriptblock]$OnClick,
        [object]$Parent
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    if ($Font) { $btn.Font = $Font }
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.BackColor = $BackColor
    $btn.ForeColor = $ForeColor
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    if ($PSBoundParameters.ContainsKey('Tag')) { $btn.Tag = $Tag }
    if ($OnClick) { $btn.Add_Click($OnClick) }
    if ($Parent) { $Parent.Controls.Add($btn) }
    return $btn
}

function New-WinEaseLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [switch]$AutoSize,
        [System.Drawing.Color]$ForeColor = $script:WinEaseGuiColors.Text,
        [System.Drawing.Font]$Font,
        [object]$Parent
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    if ($Font) { $lbl.Font = $Font }
    $lbl.ForeColor = $ForeColor
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    if ($AutoSize) { $lbl.AutoSize = $true } else { $lbl.Size = New-Object System.Drawing.Size($Width, $Height) }
    if ($Parent) { $Parent.Controls.Add($lbl) }
    return $lbl
}

# Single-line TextBox; -Multiline / -ReadOnly / -ScrollBars / -WordWrap make a log or editor box,
# -Fill docks it instead of placing it
function New-WinEaseTextBox {
    param(
        [int]$X, [int]$Y, [int]$Width, [int]$Height = 24,
        [string]$Text,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White,
        [System.Drawing.Font]$Font,
        [switch]$Multiline,
        [switch]$ReadOnly,
        [System.Windows.Forms.ScrollBars]$ScrollBars,
        [bool]$WordWrap,
        [switch]$Fill,
        [object]$Parent
    )
    $txt = New-Object System.Windows.Forms.TextBox
    if ($Fill) {
        $txt.Dock = [System.Windows.Forms.DockStyle]::Fill
    } else {
        $txt.Location = New-Object System.Drawing.Point($X, $Y)
        $txt.Size = New-Object System.Drawing.Size($Width, $Height)
    }
    $txt.BackColor = $script:WinEaseGuiColors.Input
    $txt.ForeColor = $ForeColor
    if ($Font) { $txt.Font = $Font }
    if ($Multiline) { $txt.Multiline = $true }
    if ($ReadOnly) { $txt.ReadOnly = $true }
    if ($PSBoundParameters.ContainsKey('ScrollBars')) { $txt.ScrollBars = $ScrollBars }
    if ($PSBoundParameters.ContainsKey('WordWrap')) { $txt.WordWrap = $WordWrap }
    if ($Text) { $txt.Text = $Text }
    if ($Parent) { $Parent.Controls.Add($txt) }
    return $txt
}

# ComboBox filled with -Items; -DropList makes it select-only. Colours are applied only when given.
function New-WinEaseComboBox {
    param(
        [string[]]$Items = @(),
        [int]$SelectedIndex = -1,
        [switch]$DropList,
        [int]$X, [int]$Y, [int]$Width, [int]$Height = 24,
        [object]$BackColor,
        [object]$ForeColor,
        [object]$Parent
    )
    $cmb = New-Object System.Windows.Forms.ComboBox
    if ($DropList) { $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList }
    $cmb.Location = New-Object System.Drawing.Point($X, $Y)
    $cmb.Size = New-Object System.Drawing.Size($Width, $Height)
    if ($null -ne $BackColor) { $cmb.BackColor = $BackColor }
    if ($null -ne $ForeColor) { $cmb.ForeColor = $ForeColor }
    if ($Items.Count -gt 0) { [void]$cmb.Items.AddRange($Items) }
    if ($SelectedIndex -ge 0) { $cmb.SelectedIndex = $SelectedIndex }
    if ($Parent) { $Parent.Controls.Add($cmb) }
    return $cmb
}

# Top-level window or dialog. -ClientSize sizes the inside instead of the outer frame.
function New-WinEaseForm {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Width, [int]$Height,
        [switch]$ClientSize,
        [System.Drawing.Color]$BackColor = $script:WinEaseGuiColors.Dialog,
        [object]$ForeColor,
        [System.Drawing.Font]$Font,
        [System.Windows.Forms.FormStartPosition]$StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent,
        [switch]$FixedDialog,
        [switch]$NoMaximize,
        [switch]$NoMinimize,
        [switch]$NoAutoScale
    )
    $frm = New-Object System.Windows.Forms.Form
    $frm.Text = $Text
    if ($NoAutoScale) { $frm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None }
    if ($Font) { $frm.Font = $Font }
    if ($ClientSize) { $frm.ClientSize = New-Object System.Drawing.Size($Width, $Height) } else { $frm.Size = New-Object System.Drawing.Size($Width, $Height) }
    $frm.StartPosition = $StartPosition
    if ($FixedDialog) { $frm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog }
    if ($NoMaximize) { $frm.MaximizeBox = $false }
    if ($NoMinimize) { $frm.MinimizeBox = $false }
    $frm.BackColor = $BackColor
    if ($null -ne $ForeColor) { $frm.ForeColor = $ForeColor }
    return $frm
}

# TabControl, docked (-Fill) or placed
function New-WinEaseTabControl {
    param(
        [switch]$Fill,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Font]$Font,
        [object]$Parent
    )
    $tc = New-Object System.Windows.Forms.TabControl
    if ($Fill) {
        $tc.Dock = [System.Windows.Forms.DockStyle]::Fill
    } else {
        $tc.Location = New-Object System.Drawing.Point($X, $Y)
        $tc.Size = New-Object System.Drawing.Size($Width, $Height)
    }
    if ($Font) { $tc.Font = $Font }
    if ($Parent) { $Parent.Controls.Add($tc) }
    return $tc
}

# CheckBox, or RadioButton with -Radio
function New-WinEaseCheckBox {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [bool]$Checked = $false,
        [switch]$Radio,
        [object]$Parent
    )
    $chk = if ($Radio) { New-Object System.Windows.Forms.RadioButton } else { New-Object System.Windows.Forms.CheckBox }
    $chk.Text = $Text
    $chk.Location = New-Object System.Drawing.Point($X, $Y)
    $chk.Size = New-Object System.Drawing.Size($Width, $Height)
    $chk.ForeColor = $script:WinEaseGuiColors.Text
    if ($Checked) { $chk.Checked = $true }
    if ($Parent) { $Parent.Controls.Add($chk) }
    return $chk
}

# GroupBox; without -X/-Y it is left for a FlowLayoutPanel to place
function New-WinEaseGroupBox {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Color]$ForeColor = $script:WinEaseGuiColors.Accent,
        [object]$Parent
    )
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = $Text
    if ($PSBoundParameters.ContainsKey('X') -or $PSBoundParameters.ContainsKey('Y')) {
        $grp.Location = New-Object System.Drawing.Point($X, $Y)
    }
    $grp.Size = New-Object System.Drawing.Size($Width, $Height)
    $grp.ForeColor = $ForeColor
    if ($Parent) { $Parent.Controls.Add($grp) }
    return $grp
}

# CheckedListBox filled with -Items, pre-checking those in -Selected; docked (-Fill) or placed.
# Selected items are matched by their real value, whatever -DisplayText shows.
function New-WinEaseCheckedList {
    param(
        [string[]]$Items = @(),
        [object[]]$Selected = @(),
        [scriptblock]$DisplayText,
        [switch]$Fill,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Font]$Font,
        [object]$Parent
    )
    $clb = New-Object System.Windows.Forms.CheckedListBox
    if ($Fill) {
        $clb.Dock = [System.Windows.Forms.DockStyle]::Fill
    } else {
        $clb.Location = New-Object System.Drawing.Point($X, $Y)
        $clb.Size = New-Object System.Drawing.Size($Width, $Height)
    }
    $clb.BackColor = $script:WinEaseGuiColors.Input
    $clb.ForeColor = $script:WinEaseGuiColors.Text
    if ($Font) { $clb.Font = $Font }
    $clb.CheckOnClick = $true
    # -DisplayText maps an item to the text shown; the entry then keeps the real item as its Value
    foreach ($item in $Items) {
        $entry = $item
        if ($DisplayText) {
            $shown = [string](& $DisplayText $item)
            if ($shown -ne $item) { $entry = New-Object WinEaseListItem -ArgumentList $item, $shown }
        }
        [void]$clb.Items.Add($entry, ($Selected -contains $item))
    }
    if ($Parent) { $Parent.Controls.Add($clb) }
    return $clb
}

function New-WinEaseTabPage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TabControl]$TabControl,
        [System.Drawing.Color]$BackColor = $script:WinEaseGuiColors.Window
    )
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Text
    $tab.BackColor = $BackColor
    $TabControl.TabPages.Add($tab)
    return $tab
}

# Docked strip holding Select All / Clear All buttons; -BackColor $null keeps the parent's color
function New-WinEaseButtonBar {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [System.Windows.Forms.DockStyle]$Dock = [System.Windows.Forms.DockStyle]::Top,
        [int]$Height = 40,
        [object]$BackColor = $script:WinEaseGuiColors.Bar
    )
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = $Dock
    $bar.Height = $Height
    if ($null -ne $BackColor) { $bar.BackColor = $BackColor }
    $Parent.Controls.Add($bar)
    return $bar
}

# Scrolling panel that fills what the bars leave of -Parent
function New-WinEaseFlowPanel {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [switch]$TopDown
    )
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $flow.AutoScroll = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
    if ($TopDown) {
        $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
        $flow.WrapContents = $true
    }
    $Parent.Controls.Add($flow)
    $flow.BringToFront()
    return $flow
}

# Tab page with a top button bar (optional caption) and a top-down flow panel for toggles.
# Returns @{ Tab; Bar; Flow }.
function New-WinEaseToggleTab {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TabControl]$TabControl,
        [string]$Caption
    )
    $tab = New-WinEaseTabPage -Text $Text -TabControl $TabControl
    $bar = New-WinEaseButtonBar -Parent $tab
    if ($Caption) {
        [void](New-WinEaseLabel -Text $Caption -X 230 -Y 11 -Width 400 -Height 20 -ForeColor $script:WinEaseGuiColors.Accent -Parent $bar)
    }
    $flow = New-WinEaseFlowPanel -Parent $tab -TopDown
    return @{ Tab = $tab; Bar = $bar; Flow = $flow }
}

# Check or uncheck every item of a CheckedListBox, or every CheckBox of a list
function Set-WinEaseChecked {
    param([object]$Target, [bool]$Checked)
    if ($Target -is [System.Windows.Forms.CheckedListBox]) {
        for ($i = 0; $i -lt $Target.Items.Count; $i++) { $Target.SetItemChecked($i, $Checked) }
    } else {
        foreach ($c in $Target) { $c.Checked = $Checked }
    }
}

# OK-only message box; -Kind picks the icon (Info | Warning | Error)
function Show-WinEaseGuiMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = (Get-WinEaseUiString 'Msg.Title.Default'),
        [ValidateSet('Info', 'Warning', 'Error', 'Question')][string]$Kind = 'Info',
        [switch]$YesNo
    )
    $icon = switch ($Kind) {
        'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
        'Error'   { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Question' { [System.Windows.Forms.MessageBoxIcon]::Question }
        default   { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    if ($YesNo) {
        # -YesNo asks the question and returns $true when the user says yes
        $answer = [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, $icon)
        return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
    return $true
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
    [System.Windows.Forms.Application]::DoEvents()
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
            [System.Windows.Forms.Application]::DoEvents()
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

function Confirm-WinEaseGuiAction {
    param([string]$Message, [string]$Title = (Get-WinEaseUiString 'Msg.Title.Confirm'))
    $ans = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Select All / Clear All pair for -Target (a CheckedListBox or a list of CheckBoxes). The target
# travels on each button's Tag, so the handler works whatever scope is left at click time.
# -ConfirmSelect asks before Select All. Returns @{ Select; Clear }.
function Add-WinEaseSelectButtons {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][object]$Target,
        [int]$X, [int]$Y,
        [int]$Width = 95, [int]$Height = 26, [int]$Step = 105,
        [string]$SelectText = (Get-WinEaseUiString 'Button.SelectAll'),
        [string]$ClearText = (Get-WinEaseUiString 'Button.ClearAll'),
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White,
        [string]$ConfirmSelect
    )
    $onClick = {
        $t = $this.Tag
        if ($t.Confirm -and -not (Confirm-WinEaseGuiAction -Message $t.Confirm)) { return }
        Set-WinEaseChecked -Target $t.Target -Checked $t.Checked
    }
    $btnSelect = New-WinEaseButton -Text $SelectText -X $X -Y $Y -Width $Width -Height $Height -ForeColor $ForeColor `
        -Tag @{ Target = $Target; Checked = $true; Confirm = $ConfirmSelect } -OnClick $onClick -Parent $Parent
    $btnClear = New-WinEaseButton -Text $ClearText -X ($X + $Step) -Y $Y -Width $Width -Height $Height -ForeColor $ForeColor `
        -Tag @{ Target = $Target; Checked = $false; Confirm = $null } -OnClick $onClick -Parent $Parent
    return @{ Select = $btnSelect; Clear = $btnClear }
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

# Locks the engine cell of one row. The engine is only editable while the target is
# selected: an unselected target never runs, so there is no engine to pick.
function Update-WinEaseDebloatRowState {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [Parameter(Mandatory = $true)][int]$RowIndex,
        [hashtable]$EngineDefs
    )
    if ($RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) { return }
    $row = $Grid.Rows[$RowIndex]
    $item = [string]$row.Tag
    $selected = [bool]$row.Cells['On'].Value
    $allowed = @('PowerShell', 'Rust')
    if ($EngineDefs -and $EngineDefs.Contains($item)) { $allowed = @($EngineDefs[$item].Engines) }
    $cell = $row.Cells['Engine']
    $locked = (-not $selected) -or ($allowed.Count -le 1)
    $cell.ReadOnly = $locked
    if ($locked) {
        $cell.Style.ForeColor = $script:WinEaseGuiColors.Muted
    } else {
        $cell.Style.ForeColor = $script:WinEaseGuiColors.Text
    }
    $cell.Style.BackColor = $script:WinEaseGuiColors.Input
}

# One row per Advanced Debloat target: the checkbox selects the target, the Engine column
# picks the engine that removes it (PowerShell = safe, Rust = forced physical deletion).
function New-WinEaseDebloatGrid {
    param(
        [string[]]$Items = @(),
        [object[]]$Selected = @(),
        [hashtable]$EngineDefs = @{},
        [hashtable]$EngineSelection = @{},
        [switch]$Fill,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Font]$Font,
        [object]$Parent
    )
    $grid = New-Object System.Windows.Forms.DataGridView
    if ($Fill) {
        $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    } else {
        $grid.Location = New-Object System.Drawing.Point($X, $Y)
        $grid.Size = New-Object System.Drawing.Size($Width, $Height)
    }
    if ($Font) { $grid.Font = $Font }
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
    $grid.MultiSelect = $false
    $grid.BackgroundColor = $script:WinEaseGuiColors.Input
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.GridColor = $script:WinEaseGuiColors.Input
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::None
    $grid.DefaultCellStyle.BackColor = $script:WinEaseGuiColors.Input
    $grid.DefaultCellStyle.ForeColor = $script:WinEaseGuiColors.Text
    $grid.DefaultCellStyle.SelectionBackColor = $script:WinEaseGuiColors.Input
    $grid.DefaultCellStyle.SelectionForeColor = $script:WinEaseGuiColors.Text
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:WinEaseGuiColors.Input
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:WinEaseGuiColors.Text
    $grid.ColumnHeadersHeight = 22

    $colOn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colOn.Name = 'On'
    $colOn.HeaderText = ''
    $colOn.Width = 32
    $colOn.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
    $colOn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable

    $colTarget = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colTarget.Name = 'Target'
    $colTarget.HeaderText = (Get-WinEaseUiString 'Debloat.Column.Target' -Default 'Target')
    $colTarget.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colTarget.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable

    $colEngine = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colEngine.Name = 'Engine'
    $colEngine.HeaderText = (Get-WinEaseUiString 'Debloat.Column.Engine' -Default 'Engine')
    $colEngine.Width = 108
    $colEngine.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
    $colEngine.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $colEngine.DisplayStyle = [System.Windows.Forms.DataGridViewComboBoxDisplayStyle]::DropDownButton
    [void]$colEngine.Items.Add('PowerShell')
    [void]$colEngine.Items.Add('Rust')
    [void]$grid.Columns.Add($colOn)
    [void]$grid.Columns.Add($colTarget)
    [void]$grid.Columns.Add($colEngine)

    foreach ($item in $Items) {
        $idx = $grid.Rows.Add()
        $row = $grid.Rows[$idx]
        $row.Tag = $item
        $row.Cells['On'].Value = ($Selected -contains $item)
        $row.Cells['Target'].Value = (Get-WinEaseDebloatItemText -Item $item)
        $row.Cells['Engine'].Value = (Get-WinEaseDebloatEngine -Item $item -EngineDefs $EngineDefs -EngineSelection $EngineSelection)
        $row.Cells['Target'].ToolTipText = $item
    }

    $grid.Add_CurrentCellDirtyStateChanged({
        if ($this.IsCurrentCellDirty) {
            [void]$this.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })
    $grid.Add_CellValueChanged({
        $e = $args[0]
        if (-not $e -or $e.RowIndex -lt 0) { return }
        $defs = Get-WinEaseDebloatEngineDefs
        if ($e.ColumnIndex -eq 0) {
            Update-WinEaseDebloatRowState -Grid $this -RowIndex $e.RowIndex -EngineDefs $defs
            # Selecting a target changes the build; the preset becomes "Custom" and the
            # size estimate is refreshed (same behaviour as the other checkboxes).
            $form = $this.FindForm()
            $gui = if ($form) { $form.Tag } else { $null }
            if ($gui -and -not $script:updatingPreset) {
                if ($gui.Preset -and $gui.Preset.Items.Count -gt 0) {
                    $script:updatingPreset = $true
                    $gui.Preset.SelectedIndex = ($gui.Preset.Items.Count - 1)
                    $script:updatingPreset = $false
                }
                Update-WinEaseGuiEstimate -Gui $gui
            }
        }
    })

    if ($Parent) { $Parent.Controls.Add($grid) }
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        Update-WinEaseDebloatRowState -Grid $grid -RowIndex $i -EngineDefs $EngineDefs
    }
    return $grid
}

# Select All / Clear All for a debloat grid
function Set-WinEaseDebloatGridChecked {
    param([Parameter(Mandatory = $true)][object]$Grid, [bool]$Checked)
    $defs = Get-WinEaseDebloatEngineDefs
    for ($i = 0; $i -lt $Grid.Rows.Count; $i++) {
        $Grid.Rows[$i].Cells['On'].Value = $Checked
        Update-WinEaseDebloatRowState -Grid $Grid -RowIndex $i -EngineDefs $defs
    }
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

# The global engine switch: applies one engine to every target that supports it.
function Set-WinEaseDebloatEngineForAll {
    param(
        [Parameter(Mandatory = $true)][object[]]$Grids,
        [Parameter(Mandatory = $true)][ValidateSet('PowerShell', 'Rust')][string]$Engine
    )
    $defs = Get-WinEaseDebloatEngineDefs
    foreach ($grid in $Grids) {
        if (-not $grid) { continue }
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            $row = $grid.Rows[$i]
            $item = [string]$row.Tag
            $allowed = @('PowerShell', 'Rust')
            if ($defs.Contains($item)) { $allowed = @($defs[$item].Engines) }
            if ($allowed -notcontains $Engine) { continue }
            $row.Cells['Engine'].Value = $Engine
        }
    }
}

# Toggle checkbox for one setting key. Changing it by hand switches the preset to Custom
# and refreshes the size estimate (both found through the form's GUI context).
function New-WinEaseToggleCheckBox {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Text,
        [System.Windows.Forms.ToolTip]$ToolTip,
        [string]$ToolTipText,
        [bool]$Checked
    )
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = $Text
    $chk.Size = New-Object System.Drawing.Size(400, 28)
    $chk.AutoEllipsis = $true
    $chk.ForeColor = $script:WinEaseGuiColors.Text
    $chk.Checked = $Checked
    $chk.Tag = $Key
    if ($ToolTip) { $ToolTip.SetToolTip($chk, $ToolTipText) }
    $chk.Add_CheckedChanged({
        if (-not $script:updatingPreset) {
            $form = $this.FindForm()
            $gui = if ($form) { $form.Tag } else { $null }
            if ($gui) {
                if ($gui.Preset -and $gui.Preset.Items.Count -gt 0) {
                    $script:updatingPreset = $true
                    $gui.Preset.SelectedIndex = ($gui.Preset.Items.Count - 1) # Custom
                    $script:updatingPreset = $false
                }
                Update-WinEaseGuiEstimate -Gui $gui
            }
        }
    })
    $Parent.Controls.Add($chk)
    return $chk
}

function Disable-WinEaseMnemonic {
    param([object]$Control)
    foreach ($c in $Control.Controls) {
        if ($c.PSObject.Properties['UseMnemonic']) { $c.UseMnemonic = $false }
        Disable-WinEaseMnemonic -Control $c
    }
}

# Collect the real values of the checked items of a CheckedListBox (not the displayed text)
function Get-WinEaseCheckedItems {
    param([System.Windows.Forms.CheckedListBox]$List)
    $sel = @()
    for ($i = 0; $i -lt $List.Items.Count; $i++) { if ($List.GetItemChecked($i)) { $sel += (Get-WinEaseListItemValue $List.Items[$i]) } }
    return ,$sel
}


# =========================================================================
# Main window helpers (all take the GUI context stored on the form's Tag)
# =========================================================================

# Fill the source combo with detected Windows 11 media drives and ISO files
function Update-WinEaseGuiSources {
    param([System.Windows.Forms.ComboBox]$Combo)
    $Combo.Items.Clear()
    foreach ($srcItem in (Get-WinEaseGuiSourceCandidates)) { [void]$Combo.Items.Add($srcItem) }
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

function Update-WinEaseGuiEstimate {
    param([hashtable]$Gui)
    try {
        $componentCheckboxes = $Gui.ComponentCheckboxes
        $mb = 5500.0
        if ($componentCheckboxes['KeepExtraFonts'] -and $componentCheckboxes['KeepExtraFonts'].Checked) { $mb += 150 }
        if ($componentCheckboxes['KeepAsianIME'] -and $componentCheckboxes['KeepAsianIME'].Checked)     { $mb += 400 }
        if ($componentCheckboxes['RemoveDefender'] -and -not $componentCheckboxes['RemoveDefender'].Checked) { $mb += 200 }
        if ($componentCheckboxes['RemoveStore'] -and -not $componentCheckboxes['RemoveStore'].Checked)       { $mb += 120 }
        if ($componentCheckboxes['DisableWindowsUpdate'] -and -not $componentCheckboxes['DisableWindowsUpdate'].Checked) { $mb += 50 }
        if ($componentCheckboxes['KeepBasicApps'] -and $componentCheckboxes['KeepBasicApps'].Checked)       { $mb += 30 }
        if ($componentCheckboxes['KeepSearchIndex'] -and $componentCheckboxes['KeepSearchIndex'].Checked)   { $mb += 20 }
        if ($componentCheckboxes['KeepXboxServices'] -and $componentCheckboxes['KeepXboxServices'].Checked) { $mb += 40 }
        if ($componentCheckboxes['RemoveDrivers'] -and $componentCheckboxes['RemoveDrivers'].Checked)       { $mb -= 80 }
        if ($componentCheckboxes['UltraSlimMode'] -and $componentCheckboxes['UltraSlimMode'].Checked)       { $mb -= 200 }
        if ($Gui.RadESD.Checked) { $mb = [math]::Round($mb * 0.82) }
        $Gui.Estimate.Text = (Get-WinEaseUiString 'Main.Estimate' -Format ([math]::Round($mb / 1024, 2)))
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# Apply built-in preset number -PresetIndex (order of $Gui.PresetKeyMap) to every checkbox
function Set-WinEaseGuiPreset {
    param([hashtable]$Gui, [int]$PresetIndex)
    $presetKeyMap = $Gui.PresetKeyMap
    $script:updatingPreset = $true
    if ($PresetIndex -ge 0 -and $PresetIndex -lt $presetKeyMap.Count) {
        $pKey = $presetKeyMap[$PresetIndex]
        $pObj = Get-WinEasePreset -Name $pKey
        if ($pObj) {
            # Update component checkboxes
            foreach ($k in $Gui.ComponentCheckboxes.Keys) {
                if ($pObj.Contains($k)) {
                    $Gui.ComponentCheckboxes[$k].Checked = [bool]$pObj[$k]
                }
            }
            # Update tweak checkboxes
            $pTweaks = if ($pObj.TweakSettings) { $pObj.TweakSettings } else { $null }
            foreach ($tk in $Gui.TweakCheckboxes.Keys) {
                if ($pTweaks -and $pTweaks.Contains($tk)) {
                    $Gui.TweakCheckboxes[$tk].Checked = [bool]$pTweaks[$tk]
                } elseif ($pObj.Contains($tk)) {
                    $Gui.TweakCheckboxes[$tk].Checked = [bool]$pObj[$tk]
                } else {
                    $Gui.TweakCheckboxes[$tk].Checked = [bool]$script:AllTweakDefs[$tk].Default
                }
            }
            # Update payload radio
            $fmt = "$($pObj.PayloadFormat)".ToUpper()
            if ($fmt -eq 'ESD') { $Gui.RadESD.Checked = $true }
            elseif ($fmt -eq 'SWM') { $Gui.RadSWM.Checked = $true }
            else { $Gui.RadWIM.Checked = $true }
            $script:guiBasePresetKey = $pKey
        }
    }
    $script:updatingPreset = $false
    Update-WinEaseGuiEstimate -Gui $Gui
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

# Read-only, scrollable text dialog (MessageBox truncates long results)
function Show-WinEaseGuiTextDialog {
    param([string]$Title, [string]$Text, [System.Windows.Forms.IWin32Window]$Owner)
    $dlg = New-WinEaseForm -Text $Title -Width 720 -Height 520 -ClientSize
    try {
        $txt = New-WinEaseTextBox -Fill -Multiline -ReadOnly -ScrollBars Both -WordWrap $false -Font (New-Object System.Drawing.Font('Consolas', 9)) -Text ($Text -replace "(?<!`r)`n", "`r`n") -Parent $dlg
        [void]$txt.Select(0, 0)
        if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    } finally { $dlg.Dispose() }
}

# "Preset Diff" picker: choose a base (presets or current window) and a target, then show the diff
function Show-WinEaseGuiPresetDiff {
    param([hashtable]$Gui)
    $names = @(Get-WinEaseUiString 'Dlg.PresetDiff.CurrentSettings')
    if ($script:BuiltInPresets) { $names += @($script:BuiltInPresets.Keys) }
    $dlg = New-WinEaseForm -Text (Get-WinEaseUiString 'Dlg.PresetDiff.Title') -Width 400 -Height 160 -ClientSize -FixedDialog -NoMaximize -NoMinimize -ForeColor ([System.Drawing.Color]::White)
    try {
        $combos = @{}
        $rows = @(@('From', (Get-WinEaseUiString 'Dlg.PresetDiff.From'), 20, 0), @('To', (Get-WinEaseUiString 'Dlg.PresetDiff.To'), 55, [Math]::Min(1, $names.Count - 1)))
        foreach ($r in $rows) {
            [void](New-WinEaseLabel -Text $r[1] -X 15 -Y ($r[2] + 3) -Width 100 -Height 20 -Parent $dlg)
            $cmb = New-WinEaseComboBox -Items $names -SelectedIndex $r[3] -DropList -X 120 -Y $r[2] -Width 260 -Parent $dlg
            $combos[$r[0]] = $cmb
        }
        $dlg.Tag = @{ Gui = $Gui; From = $combos['From']; To = $combos['To'] }
        [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Compare') -X 120 -Y 105 -Width 120 -Height 32 -Parent $dlg -OnClick {
            $f = $this.FindForm()
            $t = $f.Tag
            try {
                $txt = Get-WinEaseGuiPresetDiffText -Gui $t.Gui -From ([string]$t.From.SelectedItem) -To ([string]$t.To.SelectedItem)
                Show-WinEaseGuiTextDialog -Title (Get-WinEaseUiString 'Dlg.PresetDiff.ResultTitle' -Format $t.From.SelectedItem, $t.To.SelectedItem) -Text $txt -Owner $f
            } catch {
                Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Dlg.PresetDiff.Title') -Kind Error
            }
        })
        $btnClose = New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Close') -X 260 -Y 105 -Width 120 -Height 32 -Parent $dlg
        $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.CancelButton = $btnClose
        [void]$dlg.ShowDialog()
    } finally { $dlg.Dispose() }
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

# Job outcome -> message box (errors from the error stream are appended to a successful message)
function Show-WinEaseGuiJobOutcome {
    param($Outcome, [string]$Title, [string]$SuccessMessage)
    $kind = 'Info'
    if ($Outcome.Error) {
        $msg = Get-WinEaseUiString 'Msg.Error' -Format $Outcome.Error
        $kind = 'Error'
    } else {
        $msg = $SuccessMessage
        if (@($Outcome.Errors).Count -gt 0) {
            $msg += "`n`n" + (Get-WinEaseUiString 'Msg.ErrorsReported') + "`n" + (@($Outcome.Errors) -join "`n")
            $kind = 'Warning'
        }
    }
    Show-WinEaseGuiMessage -Text $msg -Title $Title -Kind $kind
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

function Complete-WinEaseGuiResult {
    param(
        [hashtable]$Gui,
        # Set by the test harness: skip the modal physical-debloat confirmation so the
        # automated GUI tests do not block on a message box.
        [switch]$SkipPhysicalDebloatConsent
    )
    $srcText = $Gui.Source.Text.Trim()
    if (-not $srcText) {
        Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.SourceRequired.Text') -Title (Get-WinEaseUiString 'Msg.SourceRequired.Title') -Kind Warning
        return $false
    }

    $resolvedSource = Resolve-WinEaseGuiSource -Text $srcText

    $wDir = $Gui.Work.Text.Trim()
    if (-not $wDir) { $wDir = Get-WinEaseGuiDefaultWorkDir }

    $guiUserName = $Gui.UserName.Text.Trim()
    $guiComputerName = $Gui.ComputerName.Text.Trim()
    if (-not $guiComputerName) { $guiComputerName = '*' }
    if ($guiUserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') {
        Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.InvalidUserName.Text') -Title (Get-WinEaseUiString 'Msg.InvalidUserName.Title') -Kind Warning
        return $false
    }
    if ($guiComputerName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') {
        Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.InvalidComputerName.Text') -Title (Get-WinEaseUiString 'Msg.InvalidComputerName.Title') -Kind Warning
        return $false
    }

    $formResult = $Gui.Result
    $cmbPreset = $Gui.Preset
    $presetKeyMap = $Gui.PresetKeyMap
    $formResult.Success                      = $true
    $formResult.UserName                     = $guiUserName
    $formResult.ComputerName                 = $guiComputerName
    $formResult.PresetKey                    = if ($cmbPreset.SelectedIndex -ge 0 -and $cmbPreset.SelectedIndex -lt $presetKeyMap.Count) { $presetKeyMap[$cmbPreset.SelectedIndex] } else { $null }
    $formResult.BasePresetKey                = $script:guiBasePresetKey
    $formResult.SourceDrive                  = $resolvedSource
    $formResult.WorkDir                      = $wDir
    $formResult.Index                        = $Gui.Index.Text.Trim()
    $formResult.InjectDrivers                = $Gui.Drivers.Text.Trim()
    $formResult.DryRun                       = $Gui.DryRun.Checked
    $formResult.UseVHDX                      = $Gui.VHDX.Checked
    $formResult.ExportESDMode                = $Gui.RadESD.Checked
    $formResult.SplitWIMMode                 = $Gui.RadSWM.Checked

    # Component values
    foreach ($k in $Gui.ComponentCheckboxes.Keys) {
        $formResult[$k] = $Gui.ComponentCheckboxes[$k].Checked
    }

    # Granular TweakSettings
    $resolvedTweaks = [ordered]@{}
    foreach ($k in $Gui.TweakCheckboxes.Keys) {
        $resolvedTweaks[$k] = $Gui.TweakCheckboxes[$k].Checked
    }
    $formResult.TweakSettings = $resolvedTweaks

    # Advanced Debloat items and the engine that removes them
    $stdSelected = @()
    $expSelected = @()
    $engineSelection = [ordered]@{}
    if ($Gui.GrdStd) {
        $st = Get-WinEaseDebloatGridState -Grid $Gui.GrdStd
        $stdSelected = @($st.Selected)
        $engineSelection = $st.Engines
    }
    if ($Gui.GrdExp) {
        $st = Get-WinEaseDebloatGridState -Grid $Gui.GrdExp
        $expSelected = @($st.Selected)
        foreach ($k in $st.Engines.Keys) { $engineSelection[$k] = $st.Engines[$k] }
    }
    $formResult.AdvancedDebloatStandard     = $stdSelected
    $formResult.AdvancedDebloatExperimental = $expSelected
    # Only the targets that run on another engine than their registered default are saved,
    # so a profile stays small and the default is restored automatically for the rest.
    $engineDefs = Get-WinEaseDebloatEngineDefs
    $engineDelta = [ordered]@{}
    foreach ($k in $engineSelection.Keys) {
        $engine = [string]$engineSelection[$k]
        $default = 'PowerShell'
        if ($engineDefs.Contains($k) -and $engineDefs[$k].Default) { $default = [string]$engineDefs[$k].Default }
        if ($engine -ne $default) { $engineDelta[$k] = $engine }
    }
    $formResult.DebloatEngineSelection = $engineDelta

    # Physical debloat consent. The WinUI 3 window asks for this itself (it owns the
    # confirmation dialog), the classic WinForms window did not, so the builder ended up
    # showing a second, differently worded confirmation for this GUI only. Ask here as well
    # so both windows behave the same: the user confirms once, next to the selection.
    $formResult.PhysicalDebloatConsent = $false
    if ((-not $SkipPhysicalDebloatConsent) -and (($stdSelected.Count + $expSelected.Count) -gt 0)) {
        $consentText = Get-WinEaseUiString 'Msg.PhysicalConsent.Text' -Format @($stdSelected.Count, $expSelected.Count) -Default (
            "Advanced Debloat options selected: Standard={0} / Experimental={1}.`n`n" +
            "These operations physically delete files and directories from the offline image.`n" +
            "Experimental items permanently break Windows Update and sfc verification.`n`n" +
            "Enable physical debloat for this build? (No clears the Advanced Debloat selections.)")
        $consentTitle = Get-WinEaseUiString 'Msg.PhysicalConsent.Title' -Default 'WinEase - Confirm Physical Debloat'
        if (Confirm-WinEaseGuiAction -Message $consentText -Title $consentTitle) {
            $formResult.PhysicalDebloatConsent = $true
        } else {
            # The user declined: clear the selection so the builder does not run anything.
            $formResult.AdvancedDebloatStandard     = @()
            $formResult.AdvancedDebloatExperimental = @()
        }
    }

    return $true
}

# =========================================================================
# Main window tabs. Each takes the GUI context ($gui) and adds its controls and
# checkbox tables to it; handlers read them back from $this.FindForm().Tag.
# =========================================================================
# Tab 1: media, workspace, preset and payload format
function New-WinEaseMediaTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings
    )
    # =========================================================================
    # TAB 1: Media & Workspace & Preset
    # =========================================================================
    $tabMedia = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Tab.Media') -TabControl $tabControl

    $grpMedia = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Media.Group.Source') -X 15 -Y 10 -Width 835 -Height 185 -Parent $tabMedia

    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.Source') -X 15 -Y 28 -Width 130 -Height 20 -Parent $grpMedia)
    $cmbSource = New-WinEaseComboBox -X 150 -Y 25 -Width 370 -BackColor $script:WinEaseGuiColors.Input -ForeColor ([System.Drawing.Color]::White) -Parent $grpMedia
    $gui.Source = $cmbSource

    Update-WinEaseGuiSources -Combo $cmbSource

    if ($InitialSettings.SourceDrive) { $cmbSource.Text = $InitialSettings.SourceDrive }
    elseif ($cmbSource.Items.Count -gt 0) { $cmbSource.SelectedIndex = 0 }
    else { $cmbSource.Text = "E:\" }

    # Browse / rescan buttons carry the control they fill on their Tag
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.BrowseDrive') -X 530 -Y 24 -Width 110 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = Get-WinEaseUiString 'Media.Dialog.BrowseDrive'
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $this.Tag.Text = $p
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.BrowseISO') -X 645 -Y 24 -Width 100 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = Get-WinEaseUiString 'Media.ISOFilter'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $ofd.FileName }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Rescan') -X 750 -Y 24 -Width 70 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        Update-WinEaseGuiSources -Combo $this.Tag
    })

    $browseFolder = {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $fbd.SelectedPath }
    }

    # WorkDir
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.Workspace') -X 15 -Y 60 -Width 130 -Height 20 -Parent $grpMedia)
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    $workText = if ($InitialSettings.WorkDir) { $InitialSettings.WorkDir } else { Join-Path -Path $docsDir -ChildPath "WinEase_workspace" }
    $gui.Work = New-WinEaseTextBox -X 150 -Y 57 -Width 535 -Text $workText -Parent $grpMedia
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.BrowseFolder') -X 695 -Y 56 -Width 125 -Height 26 -Tag $gui.Work -OnClick $browseFolder -Parent $grpMedia)

    # Index & Drivers
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.Index') -X 15 -Y 95 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.Index = New-WinEaseTextBox -X 150 -Y 92 -Width 70 -Text $(if ($InitialSettings.Index) { "$($InitialSettings.Index)" }) -Parent $grpMedia
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.Drivers') -X 235 -Y 95 -Width 140 -Height 20 -Parent $grpMedia)
    $gui.Drivers = New-WinEaseTextBox -X 380 -Y 92 -Width 305 -Text $(if ($InitialSettings.InjectDrivers) { "$($InitialSettings.InjectDrivers)" }) -Parent $grpMedia
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Browse') -X 695 -Y 91 -Width 125 -Height 26 -Tag $gui.Drivers -OnClick $browseFolder -Parent $grpMedia)

    # User & Computer
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.UserName') -X 15 -Y 130 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.UserName = New-WinEaseTextBox -X 150 -Y 127 -Width 160 -Text $(if ($InitialSettings.UserName) { "$($InitialSettings.UserName)" } else { "User" }) -Parent $grpMedia
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Media.Label.ComputerName') -X 330 -Y 130 -Width 120 -Height 20 -Parent $grpMedia)
    $gui.ComputerName = New-WinEaseTextBox -X 450 -Y 127 -Width 160 -Text $(if ($InitialSettings.ComputerName) { "$($InitialSettings.ComputerName)" } else { "*" }) -Parent $grpMedia

    # Preset Group
    $grpPreset = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Media.Group.Preset') -X 15 -Y 205 -Width 835 -Height 75 -Parent $tabMedia

    $cmbPreset = New-WinEaseComboBox -DropList -X 15 -Y 28 -Width 805 -BackColor $script:WinEaseGuiColors.Input -ForeColor ([System.Drawing.Color]::White) -Parent $grpPreset -Items @(
        (Get-WinEaseUiString 'Media.Preset.Extreme'),
        (Get-WinEaseUiString 'Media.Preset.Balanced'),
        (Get-WinEaseUiString 'Media.Preset.Fat32'),
        (Get-WinEaseUiString 'Media.Preset.Handheld'),
        (Get-WinEaseUiString 'Media.Preset.VM'),
        (Get-WinEaseUiString 'Media.Preset.Audio'),
        (Get-WinEaseUiString 'Media.Preset.Custom')
    )
    $gui.Preset = $cmbPreset

    # Payload Format Group
    $grpPayload = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Media.Group.Payload') -X 15 -Y 290 -Width 835 -Height 95 -Parent $tabMedia
    $gui.RadWIM = New-WinEaseCheckBox -Radio -Text (Get-WinEaseUiString 'Media.Radio.WIM') -X 15 -Y 28 -Width 350 -Height 24 -Checked $true -Parent $grpPayload
    $gui.RadESD = New-WinEaseCheckBox -Radio -Text (Get-WinEaseUiString 'Media.Radio.ESD') -X 380 -Y 28 -Width 250 -Height 24 -Parent $grpPayload
    $gui.RadSWM = New-WinEaseCheckBox -Radio -Text (Get-WinEaseUiString 'Media.Radio.SWM') -X 640 -Y 28 -Width 185 -Height 24 -Parent $grpPayload

    if ($InitialSettings.ExportESDMode) { $gui.RadESD.Checked = $true }
    elseif ($InitialSettings.SplitWIMMode) { $gui.RadSWM.Checked = $true }

    $gui.VHDX = New-WinEaseCheckBox -Text (Get-WinEaseUiString 'Media.Check.VHDX') -X 15 -Y 60 -Width 550 -Height 24 `
        -Checked ([bool]$InitialSettings.UseVHDX) -Parent $grpPayload
}

# Tabs 2-5: one toggle tab per tweak category
function New-WinEaseTweakTabs {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TABS 2-5: tweak toggles from config\schema.psd1, one tab per category
    # =========================================================================
    foreach ($cat in @(
        @((Get-WinEaseUiString 'Tab.Security'), "Security"),
        @((Get-WinEaseUiString 'Tab.Privacy'), "Privacy"),
        @((Get-WinEaseUiString 'Tab.Performance'), "Performance"),
        @((Get-WinEaseUiString 'Tab.UI'), "UI")
    )) {
        $category = $cat[1]
        $page = New-WinEaseToggleTab -Text $cat[0] -TabControl $tabControl -Caption (Get-WinEaseUiString 'Tab.TweakCaption' -Format (Get-WinEaseUiString "Category.$category" -Default $category))
        $tabCheckboxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
        foreach ($tk in $script:AllTweakDefs.Keys) {
            $def = $script:AllTweakDefs[$tk]
            if ($def.Category -ne $category) { continue }
            $initVal = [bool]$def.Default
            if ($InitialSettings.TweakSettings -and $InitialSettings.TweakSettings.Contains($tk)) {
                $initVal = [bool]$InitialSettings.TweakSettings[$tk]
            } elseif ($InitialSettings.ContainsKey($tk)) {
                $initVal = [bool]$InitialSettings[$tk]
            }
            $desc = Get-WinEaseTweakDescription -Key $tk -Def $def
            $chk = New-WinEaseToggleCheckBox -Parent $page.Flow -Key $tk -Text "$tk - $desc" -ToolTip $toolTip -ToolTipText $desc -Checked $initVal
            $gui.TweakCheckboxes[$tk] = $chk
            $tabCheckboxes.Add($chk)
        }
        [void](Add-WinEaseSelectButtons -Parent $page.Bar -Target $tabCheckboxes -X 15 -Y 7)
    }
}

# Tab 6: component switches
function New-WinEaseServicesTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TAB 6: Components & Services
    # =========================================================================
    $page = New-WinEaseToggleTab -Text (Get-WinEaseUiString 'Tab.Services') -TabControl $tabControl

    # Components with a Gui entry in config\schema.psd1, in their Gui.Order
    $svcDefs = @($script:ComponentDefs.Values | Where-Object { $_.Gui -and $_.Gui.Tab -ne 'Migration' } | Sort-Object { [int]$_.Gui.Order } | ForEach-Object {
        @{ Key = $_.Key; Text = (Get-WinEaseUiString -Key "Component.$($_.Key).Text" -Default $_.Gui.Text); Desc = (Get-WinEaseUiString -Key "Component.$($_.Key).Description" -Default $_.Gui.Description); Def = [bool]$_.Gui.Default }
    })
    $svcCheckboxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    foreach ($sd in $svcDefs) {
        $initVal = [bool]$sd.Def
        if ($InitialSettings.ContainsKey($sd.Key)) { $initVal = [bool]$InitialSettings[$sd.Key] }
        $chk = New-WinEaseToggleCheckBox -Parent $page.Flow -Key $sd.Key -Text "$($sd.Key) - $($sd.Text)" -ToolTip $toolTip -ToolTipText $sd.Desc -Checked $initVal
        $gui.ComponentCheckboxes[$sd.Key] = $chk
        $svcCheckboxes.Add($chk)
    }
    [void](Add-WinEaseSelectButtons -Parent $page.Bar -Target $svcCheckboxes -X 15 -Y 7)
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

# Tab 7: Advanced Debloat lists
function New-WinEaseDebloatTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [string]$UiFontName,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TAB 7: Advanced Debloat (Physical Deletion)
    # =========================================================================
    $stdItems = $script:WinEaseDebloatStandardItems
    $expItems = $script:WinEaseDebloatExperimentalItems
    $engineDefs = Get-WinEaseDebloatEngineDefs
    $engineSel = @{}
    if ($InitialSettings -and $InitialSettings.DebloatEngineSelection) {
        $rawEngine = $InitialSettings.DebloatEngineSelection
        if ($rawEngine -is [System.Collections.IDictionary]) {
            foreach ($k in $rawEngine.Keys) { $engineSel[[string]$k] = [string]$rawEngine[$k] }
        } else {
            foreach ($p in $rawEngine.PSObject.Properties) { $engineSel[[string]$p.Name] = [string]$p.Value }
        }
    }

    $preStd = @()
    if ($InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    $preExp = @()
    if ($InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }

    $tabDebloat = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Tab.Debloat') -TabControl $TabControl
    $barDeb = New-WinEaseButtonBar -Parent $tabDebloat
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Debloat.Notice') -X 15 -Y 11 -Width 412 -Height 20 `
        -ForeColor $script:WinEaseGuiColors.Warn -Font (New-Object System.Drawing.Font($uiFontName, 8.5)) -Parent $barDeb)
    # Global engine switch: applies one engine to every target that supports it
    # The help mark next to the label: what the engine choice does is not obvious, so the
    # mark explains it in a tooltip.
    $engineHelpText = Get-WinEaseUiString 'Debloat.Engine.Help'
    $engineHelpMark = New-WinEaseLabel -Text '?' -X 431 -Y 11 -Width 16 -Height 20 `
        -ForeColor $script:WinEaseGuiColors.Accent -Font (New-Object System.Drawing.Font($uiFontName, 9, [System.Drawing.FontStyle]::Bold)) -Parent $barDeb
    $engineHelpMark.Name = 'WinEaseEngineHelp'
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Debloat.Engine.All') -X 455 -Y 11 -Width 135 -Height 20 `
        -ForeColor $script:WinEaseGuiColors.Text -Font (New-Object System.Drawing.Font($uiFontName, 8.5)) -Parent $barDeb)
    $cmbAllEngine = New-WinEaseComboBox -Items @('PowerShell', 'Rust') -DropList -SelectedIndex 0 `
        -X 590 -Y 8 -Width 115 -Height 22 -BackColor $script:WinEaseGuiColors.Input -ForeColor $script:WinEaseGuiColors.Text -Parent $barDeb
    if ($ToolTip) {
        $ToolTip.SetToolTip($engineHelpMark, $engineHelpText)
        $ToolTip.SetToolTip($cmbAllEngine, $engineHelpText)
    }
    $flowDeb = New-WinEaseFlowPanel -Parent $tabDebloat

    # Standard Debloat group
    $grpStdDeb = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Debloat.Group.Standard') -Width 410 -Height 480 -Parent $flowDeb
    $gui.GrdStd = New-WinEaseDebloatGrid -Items $stdItems -Selected $preStd -EngineDefs $engineDefs `
        -EngineSelection $engineSel -Fill -Parent $grpStdDeb

    # Experimental Debloat group
    $grpExpDeb = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Debloat.Group.Experimental') -Width 410 -Height 480 `
        -ForeColor $script:WinEaseGuiColors.Danger -Parent $flowDeb
    $gui.GrdExp = New-WinEaseDebloatGrid -Items $expItems -Selected $preExp -EngineDefs $engineDefs `
        -EngineSelection $engineSel -Fill -Parent $grpExpDeb

    # Select All / Clear All bar at the bottom of each debloat group
    foreach ($pair in @(@($grpStdDeb, $gui.GrdStd, $null), @($grpExpDeb, $gui.GrdExp, (Get-WinEaseUiString 'Debloat.ConfirmSelectExperimental')))) {
        $barList = New-WinEaseButtonBar -Parent $pair[0] -Dock Bottom -Height 34 -BackColor $null
        $pair[1].BringToFront()
        $onSelect = {
            $t = $this.Tag
            if ($t.Confirm -and -not (Confirm-WinEaseGuiAction -Message $t.Confirm)) { return }
            Set-WinEaseDebloatGridChecked -Grid $t.Grid -Checked $t.Checked
        }
        [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.SelectAll') -X 5 -Y 4 -Width 95 -Height 26 `
            -Tag @{ Grid = $pair[1]; Checked = $true; Confirm = $pair[2] } -OnClick $onSelect -Parent $barList)
        [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.ClearAll') -X 105 -Y 4 -Width 95 -Height 26 `
            -Tag @{ Grid = $pair[1]; Checked = $false; Confirm = $null } -OnClick $onSelect -Parent $barList)
    }

    # The global engine switch applies to both lists at once
    $cmbAllEngine.Add_SelectedIndexChanged({
        $engine = [string]$this.SelectedItem
        if (-not $engine) { return }
        $form = $this.FindForm()
        $guiCtx = if ($form) { $form.Tag } else { $null }
        if (-not $guiCtx) { return }
        Set-WinEaseDebloatEngineForAll -Grids @($guiCtx.GrdStd, $guiCtx.GrdExp) -Engine $engine
    })
}

# Tab 8, right column: backup / restore / verify / estimate action buttons
function New-WinEaseMigrationActionsGroup {
    param([object]$Parent)
    $grpActions = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Actions') -Width 410 -Height 420 -Parent $Parent
    $btnY = 22
    $btnStep = 38
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Readiness') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        try {
            $rr = Get-WinEaseGuiRecoveryReadiness -Gui $g
            $msg = Get-WinEaseUiString 'Mig.Readiness.Message' -Format $rr.ReadinessScore, ($rr.SecondaryDrives -join ', '), $rr.SystemRestoreEnabled, $rr.WinReEnabledOnTarget, ($rr.Recommendations -join "`n")
            Show-WinEaseGuiMessage -Text $msg -Title (Get-WinEaseUiString 'Mig.Readiness.Title') -Kind Info
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Mig.Readiness.Title') -Kind Error
        }
    })
    $btnY += $btnStep
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.ExportApps') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $dlg.Title = Get-WinEaseUiString 'Mig.Button.ExportApps'
            $dlg.Filter = Get-WinEaseUiString 'Mig.Export.Filter'
            $dlg.FileName = "apps-inventory.json"
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $outPath = $dlg.FileName
        } finally { $dlg.Dispose() }
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Script 'param($a) Export-WinEaseAppInventory -OutputPath $a.OutputPath' -Arguments @{ OutputPath = $outPath }
        Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Export.Title') -SuccessMessage (Get-WinEaseUiString 'Mig.Export.Done' -Format $outPath)
    })
    $btnY += $btnStep
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Wizard') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        $repoRoot = $script:WinEaseGuiRepoRoot
        $migratorPath = Join-Path $repoRoot "tools\migrator\WinEase-Migrator.ps1"
        if (Test-Path -LiteralPath $migratorPath) {
            try {
                $root = Get-WinEaseGuiMigrationRoot -Gui $g
                # -BackupRoot exists in every WinEase-Migrator.ps1 version (it is a -PackagePath alias after S6);
                # the wizard opens in the language of this window
                $migratorArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $migratorPath, '-GUI', '-BackupRoot', $root, '-UiLanguage', "$($script:WinEaseUiLanguage)")
                Start-Process powershell.exe -ArgumentList $migratorArgs -WindowStyle Normal
            } catch {
                Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Mig.Wizard.Title') -Kind Error
            }
        } else {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Mig.Wizard.NotFound') -Title (Get-WinEaseUiString 'Mig.Wizard.Title') -Kind Warning
        }
    })
    $btnY += $btnStep
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Estimate') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $map = Get-WinEaseGuiMigrationFolderMap -Gui $g
        $ea = @{ UserFolderPaths = @($map.Values); SelectedRuleIds = @(Get-WinEaseGuiMigrationRuleIds -Gui $g); DestinationPath = (Get-WinEaseGuiMigrationRoot -Gui $g) }
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments $ea -Script 'param($a) Get-WinEaseMigrationSizeEstimate -UserFolderPaths $a.UserFolderPaths -SelectedRuleIds $a.SelectedRuleIds -DestinationPath $a.DestinationPath'
        $est = $o.Result
        $msg = if ($est) { Get-WinEaseUiString 'Mig.Estimate.Message' -Format $est.TotalFiles, $est.TotalMB, $est.DestinationDrive, $est.DestinationFreeMB, $est.HasEnoughSpace } else { Get-WinEaseUiString 'Mig.Estimate.None' }
        Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Button.Estimate') -SuccessMessage $msg
    })
    $btnY += $btnStep
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Backup') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $backupArgs = Get-WinEaseGuiBackupArgs -Gui $g
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments $backupArgs -Script 'param($a) Start-WinEaseMigrationBackup @a'
        Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Backup.Title') -SuccessMessage (Get-WinEaseUiString 'Mig.Backup.Done' -Format $backupArgs.BackupRoot)
        if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = Get-WinEaseUiString 'Mig.Backup.Status' }
    })
    $btnY += $btnStep
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Verify') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $script = (Get-Command Test-WinEaseGuiBackupIntegrity).ScriptBlock.ToString()
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments @{ BackupRoot = (Get-WinEaseGuiMigrationRoot -Gui $g) } -Script $script
        $vr = $o.Result
        if ($vr -and @($vr.Problems).Count -gt 0) {
            $o.Errors = @($o.Errors) + @($vr.Problems)
            $msg = Get-WinEaseUiString 'Mig.Verify.Problems' -Format $vr.Checked, @($vr.Problems).Count
        } elseif ($vr) { $msg = Get-WinEaseUiString 'Mig.Verify.Ok' -Format $vr.Checked } else { $msg = Get-WinEaseUiString 'Mig.Verify.None' }
        Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Verify.Title') -SuccessMessage $msg
    })
    $btnY += $btnStep
    foreach ($rs in @(@((Get-WinEaseUiString 'Mig.Button.Restore'), $false), @((Get-WinEaseUiString 'Mig.Button.Retry'), $true))) {
        [void](New-WinEaseButton -Text $rs[0] -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -Tag $rs[1] -OnClick {
            $btn = $this
            $retry = [bool]$btn.Tag
            $f = $btn.FindForm()
            $g = $f.Tag
            $ra = @{ BackupRoot = (Get-WinEaseGuiMigrationRoot -Gui $g); ConflictPolicy = (Get-WinEaseGuiConflictPolicy -Gui $g) }
            # The custom paths of the backup are only restored to the locations that are
            # listed in the custom path box: the manifest alone never decides where a
            # file is written to.
            $allowed = @(($g.CustomPaths.Text -split "`n").ForEach({ $_.Trim() }).Where({ $_ }))
            if ($allowed.Count -gt 0) { $ra['AllowedCustomPaths'] = $allowed }
            if ($retry) { $ra['RetryFailedOnly'] = $true }
            $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments $ra -Script 'param($a) Start-WinEaseMigrationRestore @a'
            $msg = Get-WinEaseUiString 'Mig.Restore.Done'
            if ($o.Result -and $o.Result.Results) { $msg += "`n" + ($o.Result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String) }
            Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Restore.Title') -SuccessMessage $msg
            if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = Get-WinEaseUiString 'Mig.Restore.Done' }
        })
        $btnY += $btnStep
    }
}

# Tab 8: custom file/folder backup and restore
function New-WinEaseMigrationCustomPathsGroup {
    param([hashtable]$Gui, [object]$Parent)
    # Custom paths backup/restore section
    $grpCustom = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Custom') -Width 840 -Height 140 -Parent $Parent
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Mig.Label.CustomPaths') -X 15 -Y 20 -Width 140 -Height 20 -Parent $grpCustom)
    $txtCustomPaths = New-WinEaseTextBox -X 15 -Y 42 -Width 560 -Height 60 -Multiline -ScrollBars Vertical -ForeColor $script:WinEaseGuiColors.Text -Parent $grpCustom
    $gui.CustomPaths = $txtCustomPaths

    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.BackupCustom') -X 590 -Y 42 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $paths = @(($g.CustomPaths.Text -split "`n").ForEach({ $_.Trim() }).Where({ $_ }))
        if ($paths.Count -eq 0) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Mig.Custom.NoPaths') -Title (Get-WinEaseUiString 'Mig.Button.BackupCustom') -Kind Warning
            return
        }
        $ca = @{ Paths = $paths; BackupRoot = (Get-WinEaseGuiMigrationRoot -Gui $g) }
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments $ca -Script 'param($a) Backup-WinEaseCustomPaths @a'
        if ($o.Result) {
            $msg = Get-WinEaseUiString 'Mig.Custom.BackupDone' -Format $o.Result.CopiedFiles, @($o.Result.FailedFiles).Count
            Show-WinEaseGuiMessage -Text $msg -Title (Get-WinEaseUiString 'Mig.Button.BackupCustom') -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = Get-WinEaseUiString 'Mig.Custom.BackupStatus' -Format $o.Result.CopiedFiles }
        } else {
            Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Button.BackupCustom') -SuccessMessage (Get-WinEaseUiString 'Mig.Custom.BackupDone' -Format 0, 0)
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.RestoreCustom') -X 590 -Y 82 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        # The custom paths are restored to the locations that are listed here: the
        # manifest alone never decides where a file is written to.
        $paths = @(($g.CustomPaths.Text -split "`n").ForEach({ $_.Trim() }).Where({ $_ }))
        if ($paths.Count -eq 0) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Mig.Custom.NoPaths') -Title (Get-WinEaseUiString 'Mig.Button.RestoreCustom') -Kind Warning
            return
        }
        $ra = @{ BackupRoot = (Get-WinEaseGuiMigrationRoot -Gui $g); ConflictPolicy = (Get-WinEaseGuiConflictPolicy -Gui $g); AllowedSourcePaths = $paths }
        $o = Invoke-WinEaseGuiMigrationJob -Button $btn -Form $f -RepoRoot $script:WinEaseGuiRepoRoot -Arguments $ra -Script 'param($a) Restore-WinEaseCustomPaths @a'
        if ($o.Result) {
            $msg = Get-WinEaseUiString 'Mig.Custom.RestoreDone' -Format $o.Result.RestoredFiles, @($o.Result.FailedFiles).Count
            Show-WinEaseGuiMessage -Text $msg -Title (Get-WinEaseUiString 'Mig.Button.RestoreCustom') -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = Get-WinEaseUiString 'Mig.Custom.RestoreStatus' -Format $o.Result.RestoredFiles }
        } else {
            Show-WinEaseGuiJobOutcome -Outcome $o -Title (Get-WinEaseUiString 'Mig.Button.RestoreCustom') -SuccessMessage (Get-WinEaseUiString 'Mig.Custom.RestoreDone' -Format 0, 0)
        }
    })
}

# Tab 8: what config\user\user-tweaks.psd1 loaded (set by the builder)
function New-WinEaseMigrationExtensionsGroup {
    param([hashtable]$Gui, [object]$Parent)
    # User Extensions & Custom Scripts card: what config\user\user-tweaks.psd1 loaded (set by the builder)
    $grpExt = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Extensions') -Width 840 -Height 110 -Parent $Parent
    $extRes = $script:UserExtensionsResult
    $extErrors = @()
    if ($extRes -and $extRes.Errors) { $extErrors = @($extRes.Errors | Where-Object { $_ }) }
    if ($extRes) {
        $extText = Get-WinEaseUiString 'Mig.Ext.Counts' -Format $extRes.UserTweakCount, $extRes.UserPresetCount, $extRes.CustomScriptCount
    } else {
        $extText = Get-WinEaseUiString 'Mig.Ext.NotLoaded'
    }
    [void](New-WinEaseLabel -Text $extText -X 15 -Y 24 -Width 600 -Height 20 -Parent $grpExt)
    $gui.ExtensionsLabel = New-WinEaseLabel -Text $(if ($extErrors.Count -gt 0) { Get-WinEaseUiString 'Mig.Ext.LoadErrors' -Format ($extErrors -join '; ') } else { Get-WinEaseUiString 'Mig.Ext.NoErrors' }) `
        -X 15 -Y 48 -Width 600 -Height 52 -ForeColor $(if ($extErrors.Count -gt 0) { $script:WinEaseGuiColors.Warn } else { $script:WinEaseGuiColors.Muted }) -Parent $grpExt
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Guide') -X 630 -Y 24 -Width 190 -Height 32 -Parent $grpExt -OnClick {
        $guide = Join-Path $script:WinEaseGuiRepoRoot "docs\EXTENSIBILITY_GUIDE.md"
        try {
            if (-not (Test-Path -LiteralPath $guide)) { throw (Get-WinEaseUiString 'Mig.Guide.NotFound' -Format $guide) }
            Start-Process -FilePath $guide
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Mig.Guide.Title') -Kind Error
        }
    })
}

# Tab 8: Migration & Backup
function New-WinEaseMigrationTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # Tab 8: Migration & Backup
    # =========================================================================
    $tabMigration = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Tab.Migration') -TabControl $tabControl
    $flowMig = New-WinEaseFlowPanel -Parent $tabMigration

    # Top card: Post-Install Migration Assistant (a component switch from config\schema.psd1, Gui.Tab = 'Migration')
    $grpAssist = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Assistant') -Width 840 -Height 92 -Parent $flowMig
    $chkAssist = $null
    $asDef = $script:ComponentDefs['IncludeMigrationAssistant']
    if ($asDef -and $asDef.Gui) {
        $asInit = [bool]$asDef.Gui.Default
        $asText = Get-WinEaseUiString -Key 'Component.IncludeMigrationAssistant.Text' -Default $asDef.Gui.Text
        $asDesc = Get-WinEaseUiString -Key 'Component.IncludeMigrationAssistant.Description' -Default $asDef.Gui.Description
        if ($InitialSettings.ContainsKey('IncludeMigrationAssistant')) { $asInit = [bool]$InitialSettings['IncludeMigrationAssistant'] }
        $chkAssist = New-WinEaseToggleCheckBox -Parent $grpAssist -Key 'IncludeMigrationAssistant' -Text "IncludeMigrationAssistant - $asText" -ToolTip $toolTip -ToolTipText $asDesc -Checked $asInit
        $chkAssist.Location = New-Object System.Drawing.Point(15, 22)
        $chkAssist.Size = New-Object System.Drawing.Size(800, 28)
        $gui.ComponentCheckboxes['IncludeMigrationAssistant'] = $chkAssist
    }
    $bkDef = $script:ComponentDefs['IncludeMigrationBackup']
    if ($bkDef -and $bkDef.Gui) {
        $bkInit = [bool]$bkDef.Gui.Default
        $bkText = Get-WinEaseUiString -Key 'Component.IncludeMigrationBackup.Text' -Default $bkDef.Gui.Text
        $bkDesc = Get-WinEaseUiString -Key 'Component.IncludeMigrationBackup.Description' -Default $bkDef.Gui.Description
        if ($InitialSettings.ContainsKey('IncludeMigrationBackup')) { $bkInit = [bool]$InitialSettings['IncludeMigrationBackup'] }
        $chkBackup = New-WinEaseToggleCheckBox -Parent $grpAssist -Key 'IncludeMigrationBackup' -Text "IncludeMigrationBackup - $bkText" -ToolTip $toolTip -ToolTipText $bkDesc -Checked $bkInit
        $chkBackup.Location = New-Object System.Drawing.Point(34, 55)
        $chkBackup.Size = New-Object System.Drawing.Size(790, 26)
        $chkBackup.Enabled = ($chkAssist -and $chkAssist.Checked)
        if ($chkAssist) {
            # Event scripts must not close over function locals: read both controls from the
            # shared GUI context instead, which is still alive when the user clicks.
            $chkAssist.Add_CheckedChanged({
                $g = if ($this.FindForm()) { $this.FindForm().Tag } else { $null }
                if ($g -and $g.ComponentCheckboxes) {
                    $backup = $g.ComponentCheckboxes['IncludeMigrationBackup']
                    if ($backup) { $backup.Enabled = $this.Checked }
                }
            })
        }
        $gui.ComponentCheckboxes['IncludeMigrationBackup'] = $chkBackup
    }

    # Backup settings: destination, credential handling, conflict policy
    $grpTop = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Backup') -Width 840 -Height 110 -Parent $flowMig
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Mig.Label.BackupRoot') -X 15 -Y 22 -Width 90 -Height 20 -Parent $grpTop)
    $txtMigRoot = New-WinEaseTextBox -X 110 -Y 20 -Width 420 -Height 24 -Text (Get-WinEaseDefaultMigrationBackupPath) -Parent $grpTop
    $gui.MigRoot = $txtMigRoot
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Browse') -X 540 -Y 19 -Width 90 -Height 26 -Parent $grpTop -OnClick {
        $g = $this.FindForm().Tag
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dlg.Description = Get-WinEaseUiString 'Mig.Dialog.Destination'
            if ($g.MigRoot.Text -and (Test-Path -LiteralPath $g.MigRoot.Text)) { $dlg.SelectedPath = $g.MigRoot.Text }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $g.MigRoot.Text = $dlg.SelectedPath }
        } finally { $dlg.Dispose() }
    })
    $lblMigStatus = New-WinEaseLabel -Text (Get-WinEaseUiString 'Mig.Status.Initial') -X 640 -Y 22 -Width 190 -Height 40 -Parent $grpTop
    $gui.MigStatus = $lblMigStatus
    $gui.MigExcludeSecrets = New-WinEaseCheckBox -Text (Get-WinEaseUiString 'Mig.Check.ExcludeSecrets') -X 15 -Y 52 -Width 320 -Height 24 -Checked $true -Parent $grpTop
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Mig.Label.ConflictPolicy') -X 15 -Y 80 -Width 220 -Height 20 -Parent $grpTop)
    $cmbConflict = New-WinEaseComboBox -Items @('BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite') -SelectedIndex 0 -DropList -X 240 -Y 78 -Width 200 -Parent $grpTop
    $gui.MigConflict = $cmbConflict

    # Left: personal data folders + migration rules
    $grpRules = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'Mig.Group.Rules') -Width 410 -Height 420 -Parent $flowMig
    $folderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads')
    $gui.MigFolders = New-WinEaseCheckedList -Items $folderNames -Selected @('Documents', 'Desktop', 'Pictures') -X 10 -Y 20 -Width 390 -Height 100 -Parent $grpRules
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Mig.Label.Rules') -X 10 -Y 126 -Width 390 -Height 18 -Parent $grpRules)
    $clbMig = New-WinEaseCheckedList -Items @() -X 10 -Y 146 -Width 390 -Height 264 -Parent $grpRules
    # Rules are filled in the first time this tab is opened (the migration engine is not loaded before that)
    $clbMig.Tag = @()
    $tabMigration.Tag = @{ Loaded = $false; List = $clbMig }
    $gui.MigTab = $tabMigration
    $tabMigration.Add_Enter({
        $st = $this.Tag
        if ($st.Loaded) { return }
        $st.Loaded = $true
        Initialize-WinEaseGuiMigrationRules -List $st.List
    })
    $gui.MigRulesList = $clbMig

    New-WinEaseMigrationActionsGroup -Parent $flowMig
    New-WinEaseMigrationCustomPathsGroup -Gui $gui -Parent $flowMig
    New-WinEaseMigrationExtensionsGroup -Gui $gui -Parent $flowMig
}

# Tab 9: user-defined switches outside the built-in categories
function New-WinEaseUserTweaksTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TAB 9: user-defined switches whose Category has no tab above (System / Gaming / UserCustom ...)
    # =========================================================================
    $builtinTabCategories = @('Security', 'Privacy', 'Performance', 'UI')
    $pageUser = New-WinEaseToggleTab -Text (Get-WinEaseUiString 'Tab.UserTweaks') -TabControl $tabControl -Caption (Get-WinEaseUiString 'UserTweaks.Caption')
    $userTweakCount = 0
    foreach ($tk in $script:AllTweakDefs.Keys) {
        $def = $script:AllTweakDefs[$tk]
        if ($builtinTabCategories -contains $def.Category) { continue }
        $initVal = [bool]$def.Default
        if ($InitialSettings.TweakSettings -and $InitialSettings.TweakSettings.Contains($tk)) {
            $initVal = [bool]$InitialSettings.TweakSettings[$tk]
        } elseif ($InitialSettings.ContainsKey($tk)) {
            $initVal = [bool]$InitialSettings[$tk]
        }
        $desc = Get-WinEaseTweakDescription -Key $tk -Def $def
        $chk = New-WinEaseToggleCheckBox -Parent $pageUser.Flow -Key $tk -Text "$tk [$($def.Category)] - $desc" -ToolTip $toolTip -ToolTipText $desc -Checked $initVal
        $gui.TweakCheckboxes[$tk] = $chk
        $userTweakCount++
    }
    if ($userTweakCount -eq 0) {
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'UserTweaks.None') -X 0 -Y 0 -AutoSize -Parent $pageUser.Flow)
    }
}

# =========================================================================
# Tab 10: custom scripts (tools\custom-scripts\<Stage>)
# =========================================================================

# The extension engine owns the custom script helpers; it is loaded with this file (see the top).
function Initialize-WinEaseGuiCustomScriptEngine {
    return $null -ne (Get-Command -Name Get-WinEaseCustomScriptInventory -ErrorAction SilentlyContinue)
}

# The description of a stage: where the scripts run and with which rights.
function Get-WinEaseGuiCustomScriptStageInfo {
    param([string]$Stage)
    $info = @(Get-WinEaseCustomScriptStageMap | Where-Object { $_.Stage -eq $Stage })[0]
    if (-not $info) { return '' }
    $runsAs = switch ($info.RunsAs) {
        'Administrator' { Get-WinEaseUiString 'CS.RunsAs.Admin' }
        'StandardUser' { Get-WinEaseUiString 'CS.RunsAs.User' }
        default { Get-WinEaseUiString 'CS.RunsAs.Build' }
    }
    $where = if ($info.ImageFolder) { Get-WinEaseUiString 'CS.Stage.InImage' -Format $info.ImageFolder } else { Get-WinEaseUiString 'CS.Stage.BuildOnly' }
    return (Get-WinEaseUiString 'CS.Stage.Info' -Format $info.Stage, $runsAs, $where)
}

# Fills the list with the scripts of the selected stage.
function Update-WinEaseGuiCustomScriptsList {
    param([hashtable]$Gui)
    if (-not $Gui.CsList) { return }
    $stage = [string]$Gui.CsStage.SelectedItem
    try {
        if ($Gui.CsStageInfo) { $Gui.CsStageInfo.Text = (Get-WinEaseGuiCustomScriptStageInfo -Stage $stage) }
        $items = @(Get-WinEaseCustomScriptInventory -RepoRoot $script:WinEaseGuiRepoRoot -Stage $stage)
    } catch { $items = @() }
    $list = $Gui.CsList
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($it in $items) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$it.Name)
            [void]$row.SubItems.Add([string]$it.EffectiveOrder)
            [void]$row.SubItems.Add([string]$it.Extension)
            [void]$row.SubItems.Add([string]$it.Size)
            [void]$row.SubItems.Add([string]$it.Condition)
            [void]$row.SubItems.Add([string]$it.OnError)
            [void]$row.SubItems.Add([string]$it.Description)
            if ($it.Location -eq 'Legacy') { $row.ForeColor = $script:WinEaseGuiColors.Warn }
            $row.Tag = $it
            [void]$list.Items.Add($row)
        }
    } finally { $list.EndUpdate() }
    if ($Gui.CsCount) {
        $Gui.CsCount.Text = (Get-WinEaseUiString 'CS.Count' -Format @($items).Count, $stage)
    }
}

# The script the user picked in the list ($null when nothing is selected).
function Get-WinEaseGuiSelectedCustomScript {
    param([hashtable]$Gui)
    if (-not $Gui.CsList) { return $null }
    if ($Gui.CsList.SelectedItems.Count -eq 0) { return $null }
    return $Gui.CsList.SelectedItems[0].Tag
}

# Metadata editor: order, condition, error handling and description of one script.
function Show-WinEaseGuiCustomScriptMetadataDialog {
    param([hashtable]$Gui, [object]$Script)
    $dlg = New-WinEaseForm -Text (Get-WinEaseUiString 'CS.Dlg.Meta.Title') -Width 520 -Height 300 -ClientSize -FixedDialog -NoMaximize -NoMinimize -ForeColor ([System.Drawing.Color]::White)
    try {
        $dlg.Tag = @{ Gui = $Gui; Script = $Script; Order = $null; Condition = $null; OnError = $null; Description = $null }
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Meta.Order') -X 15 -Y 22 -Width 120 -Height 20 -Parent $dlg)
        $dlg.Tag.Order = New-WinEaseTextBox -X 140 -Y 19 -Width 120 -Height 24 -Text ([string]$Script.EffectiveOrder) -Parent $dlg
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Meta.Condition') -X 15 -Y 57 -Width 120 -Height 20 -Parent $dlg)
        $dlg.Tag.Condition = New-WinEaseTextBox -X 140 -Y 54 -Width 340 -Height 24 -Text ([string]$Script.Condition) -Parent $dlg
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Meta.OnError') -X 15 -Y 92 -Width 120 -Height 20 -Parent $dlg)
        $dlg.Tag.OnError = New-WinEaseComboBox -Items @('Warn', 'Stop', 'Ignore') -SelectedIndex 0 -DropList -X 140 -Y 89 -Width 140 -Parent $dlg
        if ([string]$Script.OnError -in @('Warn', 'Stop', 'Ignore')) { $dlg.Tag.OnError.SelectedIndex = @('Warn', 'Stop', 'Ignore').IndexOf([string]$Script.OnError) }
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Meta.Description') -X 15 -Y 127 -Width 120 -Height 20 -Parent $dlg)
        $dlg.Tag.Description = New-WinEaseTextBox -X 140 -Y 124 -Width 340 -Height 24 -Text ([string]$Script.Description) -Parent $dlg
        [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Meta.Hint') -X 15 -Y 160 -Width 480 -Height 40 -Parent $dlg)
        [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Save') -X 140 -Y 210 -Width 120 -Height 32 -Parent $dlg -OnClick {
            $f = $this.FindForm()
            $t = $f.Tag
            try {
                $order = 100
                if (-not [int]::TryParse($t.Order.Text.Trim(), [ref]$order)) { $order = 100 }
                Set-WinEaseCustomScriptMetadata -Path ([string]$t.Script.FullPath) -Order $order `
                    -Condition $t.Condition.Text.Trim() -OnError ([string]$t.OnError.SelectedItem) -Description $t.Description.Text.Trim() | Out-Null
                $f.Tag = 'OK'
                $f.Close()
            } catch {
                Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'CS.Dlg.Meta.Title') -Kind Error
            }
        })
        $btnCancel = New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Cancel') -X 280 -Y 210 -Width 120 -Height 32 -Parent $dlg
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.CancelButton = $btnCancel
        [void]$dlg.ShowDialog()
        return ($dlg.Tag -is [string] -and $dlg.Tag -eq 'OK')
    } finally { $dlg.Dispose() }
}

# Tab 10: the custom scripts of the four stages
function New-WinEaseCustomScriptsTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl
    )
    $tabCs = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Tab.CustomScripts') -TabControl $TabControl
    $flowCs = New-WinEaseFlowPanel -Parent $tabCs

    # Stage selection
    $grpStage = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'CS.Group.Stage') -Width 840 -Height 92 -Parent $flowCs
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Label.Stage') -X 15 -Y 26 -Width 70 -Height 20 -Parent $grpStage)
    $cmbStage = New-WinEaseComboBox -Items @('PreBuild', 'OfflineImage', 'FirstLogon', 'UserOnce') -SelectedIndex 2 -DropList -X 90 -Y 23 -Width 170 -Parent $grpStage
    $gui.CsStage = $cmbStage
    $cmbStage.Add_SelectedIndexChanged({
        $g = $this.FindForm().Tag
        Update-WinEaseGuiCustomScriptsList -Gui $g
    })
    $gui.CsStageInfo = New-WinEaseLabel -Text ' ' -X 275 -Y 24 -Width 470 -Height 44 -Parent $grpStage
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.OpenFolder') -X 750 -Y 21 -Width 80 -Height 28 -Parent $grpStage -OnClick {
        $g = $this.FindForm().Tag
        $stage = [string]$g.CsStage.SelectedItem
        $info = @(Get-WinEaseCustomScriptStageMap | Where-Object { $_.Stage -eq $stage })[0]
        if (-not $info) { return }
        $folder = Join-Path $script:WinEaseGuiRepoRoot $info.RepoFolder
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`""
    })

    # The scripts of the stage
    $grpList = New-WinEaseGroupBox -Text (Get-WinEaseUiString 'CS.Group.Scripts') -Width 840 -Height 330 -Parent $flowCs
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(10, 20)
    $list.Size = New-Object System.Drawing.Size(820, 240)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.BackColor = $script:WinEaseGuiColors.Input
    $list.ForeColor = $script:WinEaseGuiColors.Text
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $cols = @(
        @((Get-WinEaseUiString 'CS.Column.Name'), 210),
        @((Get-WinEaseUiString 'CS.Column.Order'), 60),
        @((Get-WinEaseUiString 'CS.Column.Type'), 60),
        @((Get-WinEaseUiString 'CS.Column.Size'), 70),
        @((Get-WinEaseUiString 'CS.Column.Condition'), 130),
        @((Get-WinEaseUiString 'CS.Column.OnError'), 80),
        @((Get-WinEaseUiString 'CS.Column.Description'), 210)
    )
    foreach ($c in $cols) {
        $col = New-Object System.Windows.Forms.ColumnHeader
        $col.Text = [string]$c[0]
        $col.Width = [int]$c[1]
        [void]$list.Columns.Add($col)
    }
    [void]$grpList.Controls.Add($list)
    $gui.CsList = $list
    $gui.CsCount = New-WinEaseLabel -Text ' ' -X 10 -Y 264 -Width 400 -Height 20 -Parent $grpList

    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.Add') -X 10 -Y 288 -Width 120 -Height 30 -Parent $grpList -OnClick {
        $g = $this.FindForm().Tag
        try {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $dlg.Title = (Get-WinEaseUiString 'CS.Dialog.Add')
                $dlg.Filter = (Get-WinEaseUiString 'CS.Dialog.Filter')
                $dlg.Multiselect = $true
                if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
                $paths = @($dlg.FileNames)
            } finally { $dlg.Dispose() }
            $stage = [string]$g.CsStage.SelectedItem
            $res = Add-WinEaseCustomScript -RepoRoot $script:WinEaseGuiRepoRoot -Stage $stage -Paths $paths
            Update-WinEaseGuiCustomScriptsList -Gui $g
            $msg = (Get-WinEaseUiString 'CS.Msg.Added' -Format @($res.Added).Count, $stage)
            if (@($res.Errors).Count -gt 0) { $msg += "`n" + (@($res.Errors) -join "`n") }
            Show-WinEaseGuiMessage -Text $msg -Title (Get-WinEaseUiString 'CS.Button.Add') -Kind $(if (@($res.Errors).Count -gt 0) { 'Warning' } else { 'Info' })
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'CS.Button.Add') -Kind Error
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.Remove') -X 140 -Y 288 -Width 120 -Height 30 -Parent $grpList -OnClick {
        $g = $this.FindForm().Tag
        $sel = Get-WinEaseGuiSelectedCustomScript -Gui $g
        if (-not $sel) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'CS.Msg.NoSelection') -Title (Get-WinEaseUiString 'CS.Button.Remove') -Kind Warning
            return
        }
        $ask = Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'CS.Msg.ConfirmRemove' -Format $sel.Name) -Title (Get-WinEaseUiString 'CS.Button.Remove') -Kind Question -YesNo
        if (-not $ask) { return }
        try {
            Remove-WinEaseCustomScript -RepoRoot $script:WinEaseGuiRepoRoot -Stage ([string]$sel.Stage) -Path ([string]$sel.FullPath) | Out-Null
            Update-WinEaseGuiCustomScriptsList -Gui $g
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'CS.Button.Remove') -Kind Error
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.Edit') -X 270 -Y 288 -Width 120 -Height 30 -Parent $grpList -OnClick {
        $g = $this.FindForm().Tag
        $sel = Get-WinEaseGuiSelectedCustomScript -Gui $g
        if (-not $sel) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'CS.Msg.NoSelection') -Title (Get-WinEaseUiString 'CS.Button.Edit') -Kind Warning
            return
        }
        if (Show-WinEaseGuiCustomScriptMetadataDialog -Gui $g -Script $sel) {
            Update-WinEaseGuiCustomScriptsList -Gui $g
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.Reorder') -X 400 -Y 288 -Width 120 -Height 30 -Parent $grpList -OnClick {
        $g = $this.FindForm().Tag
        $sel = Get-WinEaseGuiSelectedCustomScript -Gui $g
        if (-not $sel) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'CS.Msg.NoSelection') -Title (Get-WinEaseUiString 'CS.Button.Reorder') -Kind Warning
            return
        }
        $newOrder = 0
        if (-not [int]::TryParse($sel.EffectiveOrder, [ref]$newOrder)) { $newOrder = 100 }
        $dlg = New-WinEaseForm -Text (Get-WinEaseUiString 'CS.Dlg.Reorder.Title') -Width 380 -Height 150 -ClientSize -FixedDialog -NoMaximize -NoMinimize -ForeColor ([System.Drawing.Color]::White)
        try {
            [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'CS.Dlg.Reorder.Hint' -Format $sel.Name) -X 15 -Y 20 -Width 340 -Height 20 -Parent $dlg)
            $dlg.Tag = @{ Script = $sel; Order = (New-WinEaseTextBox -X 15 -Y 48 -Width 100 -Height 24 -Text ([string]$newOrder) -Parent $dlg) }
            [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Save') -X 15 -Y 90 -Width 110 -Height 30 -Parent $dlg -OnClick {
                $f = $this.FindForm()
                $t = $f.Tag
                try {
                    $order = 100
                    if (-not [int]::TryParse($t.Order.Text.Trim(), [ref]$order)) { $order = 100 }
                    Move-WinEaseCustomScriptOrder -Path ([string]$t.Script.FullPath) -NewOrder $order | Out-Null
                    $f.Tag = 'OK'
                    $f.Close()
                } catch {
                    Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'CS.Dlg.Reorder.Title') -Kind Error
                }
            })
            $btnCancel = New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Cancel') -X 140 -Y 90 -Width 110 -Height 30 -Parent $dlg
            $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $dlg.CancelButton = $btnCancel
            [void]$dlg.ShowDialog()
            if ($dlg.Tag -is [string] -and $dlg.Tag -eq 'OK') { Update-WinEaseGuiCustomScriptsList -Gui $g }
        } finally { $dlg.Dispose() }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'CS.Button.Preview') -X 530 -Y 288 -Width 140 -Height 30 -Parent $grpList -OnClick {
        try {
            $rows = @(Get-WinEaseCustomScriptPreview -RepoRoot $script:WinEaseGuiRepoRoot)
            $lines = @()
            foreach ($r in $rows) { $lines += ("{0}  {1}  ({2})" -f $r.Stage, $r.ImagePath, $r.RunsAs) }
            if ($lines.Count -eq 0) { $lines = @((Get-WinEaseUiString 'CS.Msg.Empty')) }
            Show-WinEaseGuiTextDialog -Title (Get-WinEaseUiString 'CS.Msg.PreviewTitle') -Text ($lines -join "`r`n")
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'CS.Button.Preview') -Kind Error
        }
    })

    # The engine is loaded when the tab is opened for the first time
    $tabCs.Tag = @{ Loaded = $false }
    $gui.CsTab = $tabCs
    $tabCs.Add_Enter({
        $st = $this.Tag
        if (-not $st.Loaded) {
            $st.Loaded = $true
            Initialize-WinEaseGuiCustomScriptEngine | Out-Null
        }
        Update-WinEaseGuiCustomScriptsList -Gui $this.FindForm().Tag
    })
}

# =========================================================================
# Main window content. Everything here is added to $Gui.Form and can be removed and built again, which is how
# the display language is switched: -InitialSettings carries the state to show (see Switch-WinEaseGuiLanguage).
# =========================================================================
function Initialize-WinEaseGuiContent {
    param(
        [hashtable]$Gui,
        [hashtable]$InitialSettings,
        [string]$UiFontName
    )
    $form = $Gui.Form
    $form.Text = Get-WinEaseUiString 'Main.WindowTitle'

    $toolTip = New-Object System.Windows.Forms.ToolTip
    # the shared tooltip of the window; the GUI context keeps it, so the help texts of
    # the controls can be read (and checked) from the outside
    $Gui.ToolTip = $toolTip
    $accent = $script:WinEaseGuiColors.Accent
    $headerBack = $script:WinEaseGuiColors.Header

    # Header Panel
    $headerPanel = New-WinEaseButtonBar -Parent $form -Height 65 -BackColor $headerBack
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Main.Title') -X 16 -Y 10 -AutoSize -ForeColor $accent `
        -Font (New-Object System.Drawing.Font($UiFontName, 14, [System.Drawing.FontStyle]::Bold)) -Parent $headerPanel)
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Main.Subtitle') -X 18 -Y 38 -AutoSize `
        -ForeColor $script:WinEaseGuiColors.Subtle -Font (New-Object System.Drawing.Font($UiFontName, 8.5)) -Parent $headerPanel)

    # Display language selector (switching rebuilds the content with the current settings kept)
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Main.Language') -X 690 -Y 10 -AutoSize -ForeColor $script:WinEaseGuiColors.Muted -Parent $headerPanel)
    $langNames = @($script:WinEaseUiLanguages | ForEach-Object { Get-WinEaseUiString 'Language.Name' -Language $_ -Default $_ })
    $cmbLang = New-WinEaseComboBox -Items $langNames -SelectedIndex ([array]::IndexOf($script:WinEaseUiLanguages, $script:WinEaseUiLanguage)) -DropList `
        -X 690 -Y 30 -Width 160 -BackColor $script:WinEaseGuiColors.Input -ForeColor $script:WinEaseGuiColors.Text -Parent $headerPanel
    $cmbLang.Add_SelectedIndexChanged({
        $f = $this.FindForm()
        $lang = $script:WinEaseUiLanguages[$this.SelectedIndex]
        if (-not $lang -or $lang -eq $script:WinEaseUiLanguage) { return }
        $f.Tag.PendingLanguage = $lang
        # The rebuild disposes this combo, so it runs from a timer once this event has finished
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 10
        $timer.Tag = $f
        $timer.Add_Tick({
            $this.Stop()
            $owner = $this.Tag
            $this.Dispose()
            Switch-WinEaseGuiLanguage -Gui $owner.Tag
        })
        $timer.Start()
    })
    $Gui.Language = $cmbLang

    # Bottom Button & Estimate Panel
    $bottomPanel = New-WinEaseButtonBar -Parent $form -Dock Bottom -Height 70 -BackColor $headerBack
    $Gui.DryRun = New-WinEaseCheckBox -Text (Get-WinEaseUiString 'Main.DryRun') -X 20 -Y 12 -Width 200 -Height 22 -Parent $bottomPanel
    $Gui.Estimate = New-WinEaseLabel -Text (Get-WinEaseUiString 'Main.Estimate.Initial') -X 20 -Y 38 -Width 380 -Height 20 `
        -ForeColor $script:WinEaseGuiColors.Muted -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel

    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.PresetDiff') -X 250 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel -OnClick {
        $g = $this.FindForm().Tag
        try {
            Show-WinEaseGuiPresetDiff -Gui $g
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.PresetDiff.Failed' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Msg.PresetDiff.Title') -Kind Error
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.CheckDependencies') -X 370 -Y 15 -Width 150 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        try {
            $cfg = Get-WinEaseGuiDraftConfig -Gui $g
            $res = Test-WinEaseDependencies -Config $cfg
            $txt = Format-WinEaseDependencyReport -Result $res
            if (-not $txt) { $txt = Get-WinEaseUiString 'Msg.Dependency.None' }
            Show-WinEaseGuiMessage -Text $txt -Title (Get-WinEaseUiString 'Msg.Dependency.Title') -Kind Info
        } catch {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Dependency.Failed' -Format $_.Exception.Message) -Title (Get-WinEaseUiString 'Msg.Dependency.Title') -Kind Error
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.StartBuild') -X 530 -Y 15 -Width 210 -Height 40 -BackColor $script:WinEaseGuiColors.Primary `
        -Font (New-Object System.Drawing.Font($UiFontName, 10, [System.Drawing.FontStyle]::Bold)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        # Dependency / feature-impact pre-check before starting the build
        try {
            $depCfg = Get-WinEaseGuiDraftConfig -Gui $g
            $depResult = Test-WinEaseDependencies -Config $depCfg
            if ($depResult.HasIssues) {
                $depText = Format-WinEaseDependencyReport -Result $depResult
                $msg = Get-WinEaseUiString 'Msg.Dependency.Confirm' -Format $depText
                if (-not (Confirm-WinEaseGuiAction -Message $msg -Title (Get-WinEaseUiString 'Msg.Dependency.Title'))) { return }
            }
        } catch {
            Write-Verbose "Dependency check skipped: $($_.Exception.Message)"
        }
        if (Complete-WinEaseGuiResult -Gui $g) {
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
    })
    $btnCancel = New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Cancel') -X 750 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9.5)) -Parent $bottomPanel
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # Main Tab Control
    $tabControl = New-WinEaseTabControl -Fill -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $form
    $tabControl.BringToFront()
    $Gui.Tabs = $tabControl

    # =========================================================================
    # Tabs 1-9 (one function each, above)
    # =========================================================================
    New-WinEaseMediaTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings
    New-WinEaseTweakTabs -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-WinEaseServicesTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-WinEaseDebloatTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -UiFontName $UiFontName -ToolTip $toolTip
    New-WinEaseMigrationTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-WinEaseUserTweaksTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-WinEaseCustomScriptsTab -Gui $Gui -TabControl $tabControl
    $cmbPreset = $Gui.Preset

    # =========================================================================
    # Synchronization & Presets Handling
    # =========================================================================
    $initPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $initPresetName = "$($InitialSettings.PresetKey)".Trim().ToLower()
    $initPresetIdx = [array]::IndexOf($initPresetKeys, $initPresetName)
    if ($initPresetIdx -lt 0) {
        # No preset was chosen yet: the window starts on the safe "balanced" preset and every
        # debloat target runs on the safe PowerShell engine. A preset that was chosen
        # explicitly (a profile, the command line) is never overridden.
        $initPresetIdx = if ($initPresetName) { $cmbPreset.Items.Count - 1 } else { 1 }
    }
    $cmbPreset.SelectedIndex = $initPresetIdx

    $script:guiBasePresetKey = if ($initPresetIdx -lt $Gui.PresetKeyMap.Count) { $Gui.PresetKeyMap[$initPresetIdx] } else { $null }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $this.SelectedIndex -ne ($this.Items.Count - 1)) {
            Set-WinEaseGuiPreset -Gui $this.FindForm().Tag -PresetIndex $this.SelectedIndex
        }
    })

    foreach ($r in @($Gui.RadWIM, $Gui.RadESD, $Gui.RadSWM)) {
        $r.Add_CheckedChanged({ Update-WinEaseGuiEstimate -Gui $this.FindForm().Tag })
    }
    Update-WinEaseGuiEstimate -Gui $Gui

    Disable-WinEaseMnemonic -Control $form
}

# Everything the user can have entered or chosen in the main window, to put back after the content is rebuilt
function Get-WinEaseGuiState {
    param([hashtable]$Gui)
    $settings = Get-WinEaseGuiDraftConfig -Gui $Gui
    $settings['SourceDrive'] = $Gui.Source.Text
    $settings['WorkDir'] = $Gui.Work.Text
    $settings['Index'] = $Gui.Index.Text
    $settings['InjectDrivers'] = $Gui.Drivers.Text
    $settings['UserName'] = $Gui.UserName.Text
    $settings['ComputerName'] = $Gui.ComputerName.Text
    $settings['UseVHDX'] = [bool]$Gui.VHDX.Checked
    $settings['ExportESDMode'] = [bool]$Gui.RadESD.Checked
    $settings['SplitWIMMode'] = [bool]$Gui.RadSWM.Checked
    $migFolders = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Gui.MigFolders.CheckedItems) { $migFolders.Add("$name") }
    $migTab = $Gui.MigTab
    return @{
        Settings         = $settings
        PresetIndex      = $Gui.Preset.SelectedIndex
        BasePresetKey    = $script:guiBasePresetKey
        TabIndex         = $Gui.Tabs.SelectedIndex
        DryRun           = [bool]$Gui.DryRun.Checked
        MigRoot          = $Gui.MigRoot.Text
        MigFolders       = $migFolders
        MigExcludeSecret = [bool]$Gui.MigExcludeSecrets.Checked
        MigConflict      = $Gui.MigConflict.SelectedIndex
        MigCustomPaths   = $Gui.CustomPaths.Text
        MigRulesLoaded   = [bool]($migTab -and $migTab.Tag.Loaded)
        MigRuleIds       = @(Get-WinEaseGuiMigrationRuleIds -Gui $Gui)
    }
}

# Put a state taken by Get-WinEaseGuiState back into freshly built content
function Restore-WinEaseGuiState {
    param([hashtable]$Gui, [hashtable]$State)
    $script:updatingPreset = $true
    $Gui.Preset.SelectedIndex = $State.PresetIndex
    $script:updatingPreset = $false
    $script:guiBasePresetKey = $State.BasePresetKey
    # Text boxes get their exact text back (an emptied box must stay empty, not fall back to its default)
    $Gui.Source.Text = $State.Settings['SourceDrive']
    $Gui.Work.Text = $State.Settings['WorkDir']
    $Gui.Index.Text = $State.Settings['Index']
    $Gui.Drivers.Text = $State.Settings['InjectDrivers']
    $Gui.UserName.Text = $State.Settings['UserName']
    $Gui.ComputerName.Text = $State.Settings['ComputerName']
    $Gui.DryRun.Checked = $State.DryRun
    $Gui.MigRoot.Text = $State.MigRoot
    for ($i = 0; $i -lt $Gui.MigFolders.Items.Count; $i++) {
        $Gui.MigFolders.SetItemChecked($i, ($State.MigFolders -contains "$($Gui.MigFolders.Items[$i])"))
    }
    $Gui.MigExcludeSecrets.Checked = $State.MigExcludeSecret
    if ($State.MigConflict -ge 0) { $Gui.MigConflict.SelectedIndex = $State.MigConflict }
    $Gui.CustomPaths.Text = $State.MigCustomPaths
    if ($State.MigRulesLoaded) {
        # The rule list is filled lazily; fill it now so the checked rules can be restored
        $migState = $Gui.MigTab.Tag
        $migState.Loaded = $true
        Initialize-WinEaseGuiMigrationRules -List $migState.List
        $known = @($migState.List.Tag)
        for ($i = 0; $i -lt $known.Count; $i++) {
            if ($State.MigRuleIds -contains [string]$known[$i]) { $migState.List.SetItemChecked($i, $true) }
        }
    }
    Update-WinEaseGuiEstimate -Gui $Gui
    if ($State.TabIndex -ge 0 -and $State.TabIndex -lt $Gui.Tabs.TabPages.Count) { $Gui.Tabs.SelectedIndex = $State.TabIndex }
}

# Show the main window in another display language. The window is built again from the current settings, so
# nothing typed or checked is lost. -Language defaults to $Gui.PendingLanguage (set by the language selector).
function Switch-WinEaseGuiLanguage {
    param([hashtable]$Gui, [string]$Language)
    if (-not $Language) { $Language = "$($Gui.PendingLanguage)" }
    if ($script:WinEaseUiLanguages -notcontains $Language -or $Language -eq $script:WinEaseUiLanguage) { return }
    $form = $Gui.Form
    $state = Get-WinEaseGuiState -Gui $Gui
    Set-WinEaseUiLanguage -Language $Language
    Save-WinEaseGuiLanguage -Language $Language
    $form.SuspendLayout()
    try {
        $old = @($form.Controls | ForEach-Object { $_ })
        $form.Controls.Clear()
        foreach ($c in $old) { $c.Dispose() }
        foreach ($k in @($Gui.Keys)) {
            if (@('Form', 'PresetKeyMap', 'Result', 'UiFontName') -notcontains $k) { $Gui.Remove($k) }
        }
        $Gui.TweakCheckboxes = @{}
        $Gui.ComponentCheckboxes = @{}
        Initialize-WinEaseGuiContent -Gui $Gui -InitialSettings $state.Settings -UiFontName $Gui.UiFontName
        Restore-WinEaseGuiState -Gui $Gui -State $state
    } finally {
        $form.ResumeLayout($true)
    }
}

# =========================================================================
# Main window. Returns the result hashtable (Success = $false on cancel);
# -NoShow returns the GUI context (Form, checkbox tables, ...) without showing it, for tests.
# -UiLanguage en|ja picks the display language (default: the saved choice, else the OS language).
# =========================================================================
function Show-WinEaseGUI {
    param(
        [hashtable]$InitialSettings = @{},
        [ValidateSet('en', 'ja')][string]$UiLanguage,
        [switch]$NoShow
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()
    Set-WinEaseUiLanguage -Language (Resolve-WinEaseUiLanguage -Requested $UiLanguage)

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    $form = New-WinEaseForm -Text (Get-WinEaseUiString 'Main.WindowTitle') -Width 880 -Height 820 -ClientSize `
        -NoAutoScale -Font (New-Object System.Drawing.Font($uiFontName, 9)) -StartPosition CenterScreen -FixedDialog -NoMaximize `
        -BackColor $script:WinEaseGuiColors.Window -ForeColor $script:WinEaseGuiColors.Text

    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $frameH = $form.Height - $form.ClientSize.Height
        if ($form.Height -gt $wa.Height) {
            $form.ClientSize = New-Object System.Drawing.Size(880, ($wa.Height - $frameH - 10))
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    # Shared state for event handlers: they read it back as $this.FindForm().Tag
    $gui = @{
        Form                = $form
        TweakCheckboxes     = @{}
        ComponentCheckboxes = @{}
        PresetKeyMap        = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
        Result              = @{ Success = $false }
        UiFontName          = $uiFontName
    }
    $form.Tag = $gui
    $script:updatingPreset = $false

    Initialize-WinEaseGuiContent -Gui $gui -InitialSettings $InitialSettings -UiFontName $uiFontName

    if ($NoShow) { return $gui }

    $form.TopMost = $true
    $form.Add_Shown({
        $this.Activate()
        $this.TopMost = $false
    })

    $diagResult = $form.ShowDialog()
    if ($diagResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $gui.Result
    }
    return @{ Success = $false }
}

# The WinUI 3 window host (Show-WinEaseWinUiGUI) shares the helpers above.
# The Migration Assistant bundle ships this file without the WinUI host (the window is a separate
# process and cannot run from the bundle), so the host is only loaded when it is really there.
$winUiHostPath = Join-Path -Path $PSScriptRoot -ChildPath 'WinEaseWinUiHost.ps1'
if (Test-Path -LiteralPath $winUiHostPath) { . $winUiHostPath }
