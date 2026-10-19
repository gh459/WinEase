# Nano11Gui.ps1 - WinForms GUI for nano11builder.ps1
# Dot-sourced by nano11builder.ps1 only when a GUI can be shown (-GUI or menu option [7]).
# Needs $script:AllTweakDefs, $script:ComponentDefs and Get-Nano11Preset from the builder.
#
# Event handlers never read locals of the function that built the form: by click time that
# scope may be gone. A handler gets its target from $this.Tag, or the shared GUI context
# (controls, checkbox tables, result) from $this.FindForm().Tag.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Repository root (this file lives in <repo>\gui)
$script:Nano11GuiRepoRoot = Split-Path -Parent $PSScriptRoot

# Default backup folder for the migration tools: <base>\<folder name below>.
# Base 'Profile' = the user profile (GUI Tab 8), 'Documents' = the Documents folder (Nano11-Migrator).
$script:Nano11MigrationBackupFolderName = 'nano11_migration_backup'
function Get-Nano11DefaultMigrationBackupPath {
    param([ValidateSet('Profile', 'Documents')][string]$Base = 'Profile')
    $baseDir = if ($Base -eq 'Documents') { [Environment]::GetFolderPath('MyDocuments') } else { $env:USERPROFILE }
    return (Join-Path -Path $baseDir -ChildPath $script:Nano11MigrationBackupFolderName)
}

# The one colour table of the GUI (and of tools\migrator\Nano11-Migrator.ps1, which loads this file)
$script:Nano11GuiColors = @{
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
$script:Nano11GuiDir = $PSScriptRoot
$script:Nano11UiLanguage = 'en'
$script:Nano11UiTables = @{}
$script:Nano11UiLanguages = @('en', 'ja')

# Folder holding en.json / ja.json: config\ui-strings in the repository, ui-strings next to this file when bundled
function Get-Nano11UiStringsDir {
    foreach ($c in @((Join-Path $script:Nano11GuiRepoRoot 'config\ui-strings'), (Join-Path $script:Nano11GuiDir 'ui-strings'))) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    return $null
}

# One language table as a hashtable (empty when the file is missing or unreadable); read once, then cached
function Get-Nano11UiTable {
    param([Parameter(Mandatory = $true)][string]$Language)
    if ($script:Nano11UiTables.ContainsKey($Language)) { return $script:Nano11UiTables[$Language] }
    $table = @{}
    $dir = Get-Nano11UiStringsDir
    if ($dir) {
        $file = Join-Path -Path $dir -ChildPath "$Language.json"
        try {
            if (Test-Path -LiteralPath $file) {
                $json = [System.IO.File]::ReadAllText($file, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $script:Nano11UiTables[$Language] = $table
    return $table
}

# Display string for -Key in the current (or -Language) language; -Format fills {0}, {1}, ... placeholders.
# Fallback order: that language -> English -> -Default -> the key.
function Get-Nano11UiString {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [object[]]$Format = @(),
        [string]$Language,
        [string]$Default
    )
    if (-not $Language) { $Language = $script:Nano11UiLanguage }
    $text = $null
    $table = Get-Nano11UiTable -Language $Language
    if ($table.ContainsKey($Key)) {
        $text = $table[$Key]
    } elseif ($Language -ne 'en') {
        $english = Get-Nano11UiTable -Language 'en'
        if ($english.ContainsKey($Key)) { $text = $english[$Key] }
    }
    if ($null -eq $text) { $text = if ($PSBoundParameters.ContainsKey('Default')) { $Default } else { $Key } }
    if ($Format.Count -gt 0) {
        try { $text = $text -f $Format } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    return $text
}

# Where the chosen language is remembered between runs
function Get-Nano11GuiSettingsPath {
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nano11\gui-settings.json')
}

function Get-Nano11GuiSavedLanguage {
    $path = Get-Nano11GuiSettingsPath
    try {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $saved = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            $lang = "$($saved.UiLanguage)".ToLower()
            if ($script:Nano11UiLanguages -contains $lang) { return $lang }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $null
}

# Remember the language (other keys of the file are kept). Failing to save never stops the GUI.
function Save-Nano11GuiLanguage {
    param([Parameter(Mandatory = $true)][string]$Language)
    $path = Get-Nano11GuiSettingsPath
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

# Language to use: -Requested (the -UiLanguage argument), then $env:NANO11_UI_LANGUAGE, then the saved choice,
# then the OS display language (ja -> ja, anything else -> en)
function Resolve-Nano11UiLanguage {
    param([string]$Requested)
    foreach ($candidate in @($Requested, $env:NANO11_UI_LANGUAGE)) {
        $lang = "$candidate".Trim().ToLower()
        if ($script:Nano11UiLanguages -contains $lang) { return $lang }
    }
    $saved = Get-Nano11GuiSavedLanguage
    if ($saved) { return $saved }
    try {
        if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') { return 'ja' }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return 'en'
}

function Set-Nano11UiLanguage {
    param([Parameter(Mandatory = $true)][ValidateSet('en', 'ja')][string]$Language)
    $script:Nano11UiLanguage = $Language
}

# Checkbox / tooltip text of a tweak: the language table, then DescriptionJa of a user tweak (Japanese only),
# then the Description from config\tweaks.psd1
function Get-Nano11TweakDescription {
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][hashtable]$Def)
    $fallback = [string]$Def.Description
    if ($script:Nano11UiLanguage -eq 'ja' -and $Def.DescriptionJa) { $fallback = [string]$Def.DescriptionJa }
    return (Get-Nano11UiString -Key "Tweak.$Key.Description" -Default $fallback)
}

# Display name of a list entry whose real value must not change with the language (Advanced Debloat items)
if (-not ('Nano11ListItem' -as [type])) {
    Add-Type -TypeDefinition @'
public class Nano11ListItem
{
    public string Value;
    public string Display;
    public Nano11ListItem(string value, string display) { Value = value; Display = display; }
    public override string ToString() { return Display; }
}
'@
}

# The real (language independent) value of a list entry: a plain string, or the Value of a Nano11ListItem
function Get-Nano11ListItemValue {
    param($Item)
    if ($Item -is [Nano11ListItem]) { return $Item.Value }
    return "$Item"
}

# Display text of an Advanced Debloat item. The English item text is the real value (phases\09 matches it);
# the language table holds its translation under the key 'Debloat:<English text>'.
function Get-Nano11DebloatItemText {
    param([Parameter(Mandatory = $true)][string]$Item)
    return (Get-Nano11UiString -Key "Debloat:$Item" -Default $Item)
}
$script:Nano11DebloatDisplayText = { param($item) Get-Nano11DebloatItemText -Item $item }

# =========================================================================
# Control helpers
# =========================================================================

# Flat dark button; -Tag carries whatever the -OnClick handler needs (read it as $this.Tag)
function New-Nano11Button {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Color]$BackColor = $script:Nano11GuiColors.Button,
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

function New-Nano11Label {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [switch]$AutoSize,
        [System.Drawing.Color]$ForeColor = $script:Nano11GuiColors.Text,
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
function New-Nano11TextBox {
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
    $txt.BackColor = $script:Nano11GuiColors.Input
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
function New-Nano11ComboBox {
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
function New-Nano11Form {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Width, [int]$Height,
        [switch]$ClientSize,
        [System.Drawing.Color]$BackColor = $script:Nano11GuiColors.Dialog,
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
function New-Nano11TabControl {
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
function New-Nano11CheckBox {
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
    $chk.ForeColor = $script:Nano11GuiColors.Text
    if ($Checked) { $chk.Checked = $true }
    if ($Parent) { $Parent.Controls.Add($chk) }
    return $chk
}

# GroupBox; without -X/-Y it is left for a FlowLayoutPanel to place
function New-Nano11GroupBox {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [System.Drawing.Color]$ForeColor = $script:Nano11GuiColors.Accent,
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
function New-Nano11CheckedList {
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
    $clb.BackColor = $script:Nano11GuiColors.Input
    $clb.ForeColor = $script:Nano11GuiColors.Text
    if ($Font) { $clb.Font = $Font }
    $clb.CheckOnClick = $true
    # -DisplayText maps an item to the text shown; the entry then keeps the real item as its Value
    foreach ($item in $Items) {
        $entry = $item
        if ($DisplayText) {
            $shown = [string](& $DisplayText $item)
            if ($shown -ne $item) { $entry = New-Object Nano11ListItem -ArgumentList $item, $shown }
        }
        [void]$clb.Items.Add($entry, ($Selected -contains $item))
    }
    if ($Parent) { $Parent.Controls.Add($clb) }
    return $clb
}

function New-Nano11TabPage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TabControl]$TabControl,
        [System.Drawing.Color]$BackColor = $script:Nano11GuiColors.Window
    )
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Text
    $tab.BackColor = $BackColor
    $TabControl.TabPages.Add($tab)
    return $tab
}

# Docked strip holding Select All / Clear All buttons; -BackColor $null keeps the parent's color
function New-Nano11ButtonBar {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [System.Windows.Forms.DockStyle]$Dock = [System.Windows.Forms.DockStyle]::Top,
        [int]$Height = 40,
        [object]$BackColor = $script:Nano11GuiColors.Bar
    )
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = $Dock
    $bar.Height = $Height
    if ($null -ne $BackColor) { $bar.BackColor = $BackColor }
    $Parent.Controls.Add($bar)
    return $bar
}

# Scrolling panel that fills what the bars leave of -Parent
function New-Nano11FlowPanel {
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
function New-Nano11ToggleTab {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TabControl]$TabControl,
        [string]$Caption
    )
    $tab = New-Nano11TabPage -Text $Text -TabControl $TabControl
    $bar = New-Nano11ButtonBar -Parent $tab
    if ($Caption) {
        [void](New-Nano11Label -Text $Caption -X 230 -Y 11 -Width 400 -Height 20 -ForeColor $script:Nano11GuiColors.Accent -Parent $bar)
    }
    $flow = New-Nano11FlowPanel -Parent $tab -TopDown
    return @{ Tab = $tab; Bar = $bar; Flow = $flow }
}

# Check or uncheck every item of a CheckedListBox, or every CheckBox of a list
function Set-Nano11Checked {
    param([object]$Target, [bool]$Checked)
    if ($Target -is [System.Windows.Forms.CheckedListBox]) {
        for ($i = 0; $i -lt $Target.Items.Count; $i++) { $Target.SetItemChecked($i, $Checked) }
    } else {
        foreach ($c in $Target) { $c.Checked = $Checked }
    }
}

# OK-only message box; -Kind picks the icon (Info | Warning | Error)
function Show-Nano11GuiMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = (Get-Nano11UiString 'Msg.Title.Default'),
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info'
    )
    $icon = switch ($Kind) {
        'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
        'Error'   { [System.Windows.Forms.MessageBoxIcon]::Error }
        default   { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

# Runs -Action (called with -ArgumentList) while -Button is disabled and -Form shows the wait cursor;
# both are restored afterwards, also when the action throws. The action sees only its parameters,
# not the locals of the caller. Returns what the action returns.
function Invoke-Nano11GuiBusy {
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
function Invoke-Nano11GuiBackgroundJob {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [object]$Button,
        [object]$Form
    )
    return (Invoke-Nano11GuiBusy -Button $Button -Form $Form -ArgumentList @($ScriptBlock, $ArgumentList) -Action {
        param($jobScript, $jobArgs)
        $job = Start-Job -ScriptBlock $jobScript -ArgumentList $jobArgs
        while ($job.State -eq 'Running') {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $output = @()
        $jobError = $null
        $errors = @()
        if ($job.State -eq 'Failed') {
            $jobError = $job.ChildJobs[0].JobStateInfo.Reason.Message
        } else {
            foreach ($e in $job.ChildJobs[0].Error) { $errors += "$e" }
            $output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{ Output = $output; Error = $jobError; Errors = $errors }
    })
}

function Confirm-Nano11GuiAction {
    param([string]$Message, [string]$Title = (Get-Nano11UiString 'Msg.Title.Confirm'))
    $ans = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Select All / Clear All pair for -Target (a CheckedListBox or a list of CheckBoxes). The target
# travels on each button's Tag, so the handler works whatever scope is left at click time.
# -ConfirmSelect asks before Select All. Returns @{ Select; Clear }.
function Add-Nano11SelectButtons {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][object]$Target,
        [int]$X, [int]$Y,
        [int]$Width = 95, [int]$Height = 26, [int]$Step = 105,
        [string]$SelectText = (Get-Nano11UiString 'Button.SelectAll'),
        [string]$ClearText = (Get-Nano11UiString 'Button.ClearAll'),
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White,
        [string]$ConfirmSelect
    )
    $onClick = {
        $t = $this.Tag
        if ($t.Confirm -and -not (Confirm-Nano11GuiAction -Message $t.Confirm)) { return }
        Set-Nano11Checked -Target $t.Target -Checked $t.Checked
    }
    $btnSelect = New-Nano11Button -Text $SelectText -X $X -Y $Y -Width $Width -Height $Height -ForeColor $ForeColor `
        -Tag @{ Target = $Target; Checked = $true; Confirm = $ConfirmSelect } -OnClick $onClick -Parent $Parent
    $btnClear = New-Nano11Button -Text $ClearText -X ($X + $Step) -Y $Y -Width $Width -Height $Height -ForeColor $ForeColor `
        -Tag @{ Target = $Target; Checked = $false; Confirm = $null } -OnClick $onClick -Parent $Parent
    return @{ Select = $btnSelect; Clear = $btnClear }
}

# Toggle checkbox for one setting key. Changing it by hand switches the preset to Custom
# and refreshes the size estimate (both found through the form's GUI context).
function New-Nano11ToggleCheckBox {
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
    $chk.ForeColor = $script:Nano11GuiColors.Text
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
                Update-Nano11GuiEstimate -Gui $gui
            }
        }
    })
    $Parent.Controls.Add($chk)
    return $chk
}

function Disable-Nano11Mnemonic {
    param([object]$Control)
    foreach ($c in $Control.Controls) {
        if ($c.PSObject.Properties['UseMnemonic']) { $c.UseMnemonic = $false }
        Disable-Nano11Mnemonic -Control $c
    }
}

# Collect the real values of the checked items of a CheckedListBox (not the displayed text)
function Get-Nano11CheckedItems {
    param([System.Windows.Forms.CheckedListBox]$List)
    $sel = @()
    for ($i = 0; $i -lt $List.Items.Count; $i++) { if ($List.GetItemChecked($i)) { $sel += (Get-Nano11ListItemValue $List.Items[$i]) } }
    return ,$sel
}

# =========================================================================
# Advanced Debloat dialog (standalone; -NoShow returns the built dialog for tests)
# =========================================================================
function Show-AdvancedDebloatDialog {
    param(
        [hashtable]$InitialSettings = @{},
        [string]$UiFontName = "Segoe UI",
        [switch]$NoShow
    )

    $stdItems = @(
        "Remove WinRE (reagentc /disable + file delete) [500-700MB]",
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
        "Preserve accessibility tools for OOBE (IFEO-blocked after setup) [0MB]",
        "Remove help files [10-20MB]",
        "Remove non-Japanese IME [5-15MB]",
        "Remove event logs [10-50MB]",
        "Remove crash dumps [varies]",
        "Remove Windows Store cache [varies]",
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

    $expItems = @(
        "Physical: Edge / WebView2 (complete removal) [~200MB]",
        "Physical: Defender (complete removal) [~50MB]",
        "Physical: Cortana / Search (complete removal) [~100MB]",
        "Physical: OneDrive (complete removal) [~50MB]",
        "Physical: Telemetry/DiagTrack (complete removal) [~30MB]",
        "Physical: Hyper-V / Virtualization stack [~200-400MB]",
        "Physical: IIS (Web server) [~50-100MB]",
        "Physical: Windows Firewall (complete removal) [~20-40MB]",
        "Physical: Bluetooth stack (complete removal) [~20-40MB]",
        "Physical: Print Spooler (complete removal) [~20-30MB]",
        "Physical: Touch/Pen/Ink (complete removal) [~20-30MB]",
        "Physical: Accessibility tools (OOBE-safe: retained, IFEO-blocked) [0MB]",
        "Physical: Windows Media Player (complete removal) [~50-100MB]",
        "Physical: Remote Desktop host (OOBE-safe: Terminal Server keys retained) [~0MB]",
        "Physical: BitLocker (complete removal) [~30-50MB]",
        "Physical: Windows Sandbox (complete removal) [~10-20MB]",
        "Physical: WSL / VM Platform (complete removal) [~20-40MB]",
        "Physical: Help files (complete removal) [~10-20MB]",
        "Physical: Crash dumps (complete removal) [varies]",
        "Physical: Provisioning packages (complete removal) [~5-10MB]",
        "Physical: Delivery Optimization (complete removal) [varies]",
        "Physical: Windows Search index (complete removal) [varies]",
        "Physical: Windows.old (complete removal) [varies]",
        "Physical: Temp files (complete removal) [varies]",
        "Physical: Installer cache PatchCache (complete removal) [varies]",
        "Physical: pagefile.sys (disable + delete) [4-16GB]",
        "Physical: hiberfil.sys (disable + delete) [4-16GB]",
        "Physical: swapfile.sys (disable + delete) [256MB-1GB]",
        "Physical: Memory.dmp (complete removal) [varies]",
        "Physical: Minidump (complete removal) [varies]",
        "Physical: Cortana / Search (complete removal) [~100MB]",
        "Physical: OneDrive (complete removal) [~50MB]",
        "Physical: Telemetry/DiagTrack (complete removal) [~30MB]",
        "Physical: Hyper-V / Virtualization stack [~200-400MB]",
        "Physical: IIS (Web server) [~50-100MB]",
        "Physical: Windows Firewall (complete removal) [~20-40MB]",
        "Physical: Bluetooth stack (complete removal) [~20-40MB]",
        "Physical: Print Spooler (complete removal) [~20-30MB]",
        "Physical: Touch/Pen/Ink (complete removal) [~20-30MB]",
        "Physical: Accessibility tools (OOBE-safe: retained, IFEO-blocked) [0MB]",
        "Physical: Windows Media Player (complete removal) [~50-100MB]",
        "Physical: Remote Desktop host (OOBE-safe: Terminal Server keys retained) [~0MB]",
        "Physical: BitLocker (complete removal) [~30-50MB]"
    )

    $dlgBack = $script:Nano11GuiColors.DialogAlt
    $dlgFore = $script:Nano11GuiColors.Text
    $listFont = New-Object System.Drawing.Font($UiFontName, 9)

    $dlg = New-Nano11Form -Text (Get-Nano11UiString 'Dlg.Debloat.Title') -Width 700 -Height 620 -FixedDialog -NoMaximize -NoMinimize -BackColor $dlgBack

    $tabControl = New-Nano11TabControl -X 10 -Y 10 -Width 665 -Height 480 -Parent $dlg

    # Standard tab
    $tabStd = New-Nano11TabPage -Text (Get-Nano11UiString 'Dlg.Debloat.TabStandard') -TabControl $tabControl -BackColor $dlgBack
    $preStd = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    $clbStd = New-Nano11CheckedList -Items $stdItems -Selected $preStd -DisplayText $script:Nano11DebloatDisplayText -X 10 -Y 10 -Width 640 -Height 380 -Font $listFont -Parent $tabStd
    [void](Add-Nano11SelectButtons -Parent $tabStd -Target $clbStd -X 10 -Y 395 -Width 100 -Height 28 -ClearText (Get-Nano11UiString 'Button.DeselectAll') -ForeColor $dlgFore)

    # Experimental tab
    $tabExp = New-Nano11TabPage -Text (Get-Nano11UiString 'Dlg.Debloat.TabExperimental') -TabControl $tabControl -BackColor $dlgBack
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Dlg.Debloat.Warning') -X 10 -Y 5 -Width 640 -Height 20 `
        -ForeColor $script:Nano11GuiColors.Danger -Font (New-Object System.Drawing.Font($UiFontName, 9, [System.Drawing.FontStyle]::Bold)) -Parent $tabExp)
    $preExp = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }
    $clbExp = New-Nano11CheckedList -Items $expItems -Selected $preExp -DisplayText $script:Nano11DebloatDisplayText -X 10 -Y 30 -Width 640 -Height 365 -Font $listFont -Parent $tabExp
    [void](Add-Nano11SelectButtons -Parent $tabExp -Target $clbExp -X 10 -Y 400 -Width 100 -Height 28 -ClearText (Get-Nano11UiString 'Button.DeselectAll') -ForeColor $dlgFore)

    # Both lists travel on the dialog's Tag for the Preview / OK handlers
    $dlg.Tag = @{ Std = $clbStd; Exp = $clbExp }

    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Preview') -X 10 -Y 500 -Width 100 -Height 30 -ForeColor $dlgFore -Parent $dlg -OnClick {
        $t = $this.FindForm().Tag
        $stdSel = Get-Nano11CheckedItems -List $t.Std
        $expSel = Get-Nano11CheckedItems -List $t.Exp
        $msg = (Get-Nano11UiString 'Dlg.Debloat.Preview.Selected' -Format $stdSel.Count, $expSel.Count) + "`n`n"
        $msg += (Get-Nano11UiString 'Dlg.Debloat.Preview.Standard' -Format $stdSel.Count) + "`n"
        foreach ($s in $stdSel) { $msg += "  - $(Get-Nano11DebloatItemText -Item $s)`n" }
        $msg += "`n" + (Get-Nano11UiString 'Dlg.Debloat.Preview.Experimental' -Format $expSel.Count) + "`n"
        foreach ($s in $expSel) { $msg += "  - $(Get-Nano11DebloatItemText -Item $s)`n" }
        if ($expSel.Count -gt 0) {
            $msg += "`n" + (Get-Nano11UiString 'Dlg.Debloat.Preview.ExperimentalWarning')
        }
        Show-Nano11GuiMessage -Text $msg -Title (Get-Nano11UiString 'Dlg.Debloat.Preview.Title') -Kind Info
    })

    # OK / Cancel
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.OK') -X 480 -Y 500 -Width 90 -Height 30 -BackColor $script:Nano11GuiColors.Primary -Parent $dlg -OnClick {
        $f = $this.FindForm()
        $script:advDebloatStd = Get-Nano11CheckedItems -List $f.Tag.Std
        $script:advDebloatExp = Get-Nano11CheckedItems -List $f.Tag.Exp
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Cancel') -X 575 -Y 500 -Width 90 -Height 30 -ForeColor $dlgFore -Parent $dlg -OnClick {
        $f = $this.FindForm()
        $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $f.Close()
    })

    if ($NoShow) { return $dlg }

    $dlg.TopMost = $true
    $result = $dlg.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{ Success = $true; StandardSelected = $script:advDebloatStd; ExperimentalSelected = $script:advDebloatExp }
    }
    return @{ Success = $false; StandardSelected = @(); ExperimentalSelected = @() }
}

# =========================================================================
# Main window helpers (all take the GUI context stored on the form's Tag)
# =========================================================================

# Fill the source combo with detected Windows 11 media drives and ISO files
function Update-Nano11GuiSources {
    param([System.Windows.Forms.ComboBox]$Combo)
    $Combo.Items.Clear()
    foreach ($srcItem in (Get-Nano11GuiSourceCandidates)) { [void]$Combo.Items.Add($srcItem) }
}

# Detected Windows 11 media drives and ISO files (shared by the WinForms and WinUI 3 windows)
function Get-Nano11GuiSourceCandidates {
    $detectedSources = @()
    foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $psd.Root) { continue }
        $r = $psd.Root.TrimEnd('\')
        $wim = Join-Path -Path "$r\sources" -ChildPath "install.wim"
        $esd = Join-Path -Path "$r\sources" -ChildPath "install.esd"
        $vol = Get-Volume -DriveLetter ($r.TrimEnd(':')) -ErrorAction SilentlyContinue
        $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
        if ((Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 500MB)) {
            $detectedSources += "$r\$volLabel (Windows 11 Media - install.wim)"
        } elseif ((Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -gt 500MB)) {
            $detectedSources += "$r\$volLabel (Windows 11 Media - install.esd)"
        }
    }
    $desktopDir = Join-Path -Path $env:USERPROFILE -ChildPath "Desktop"
    $downloadsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
    foreach ($p in @("E:\", "D:\", "C:\", (Split-Path -Parent $script:Nano11GuiRepoRoot), $env:USERPROFILE, $desktopDir, $downloadsDir)) {
        if (Test-Path -LiteralPath $p) {
            $foundIsos = Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 3GB -and ($_.Name -like "*Win11*" -or $_.Name -like "*Windows11*" -or $_.Name -like "*26300*" -or $_.Name -like "*24H2*") -and $_.Name -notlike "*nano11*" }
            foreach ($iso in $foundIsos) { $detectedSources += $iso.FullName }
        }
    }
    return ,$detectedSources
}

function Update-Nano11GuiEstimate {
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
        $Gui.Estimate.Text = (Get-Nano11UiString 'Main.Estimate' -Format ([math]::Round($mb / 1024, 2)))
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# Apply built-in preset number -PresetIndex (order of $Gui.PresetKeyMap) to every checkbox
function Set-Nano11GuiPreset {
    param([hashtable]$Gui, [int]$PresetIndex)
    $presetKeyMap = $Gui.PresetKeyMap
    $script:updatingPreset = $true
    if ($PresetIndex -ge 0 -and $PresetIndex -lt $presetKeyMap.Count) {
        $pKey = $presetKeyMap[$PresetIndex]
        $pObj = Get-Nano11Preset -Name $pKey
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
    Update-Nano11GuiEstimate -Gui $Gui
}

# Label of the "current window" entry in the Preset Diff dialog
$script:Nano11GuiCurrentSettingsLabel = '(Current window settings)'

# Diff text between two sources: a preset name or the current window settings
function Get-Nano11GuiPresetDiffText {
    param([hashtable]$Gui, [string]$From, [string]$To)
    $resolved = @()
    foreach ($name in @($From, $To)) {
        if ($name -eq $script:Nano11GuiCurrentSettingsLabel -or $name -eq (Get-Nano11UiString 'Dlg.PresetDiff.CurrentSettings')) { $resolved += , (Get-Nano11GuiDraftConfig -Gui $Gui) } else { $resolved += , $name }
    }
    $diff = Compare-Nano11Config -ReferenceConfig $resolved[0] -DifferenceConfig $resolved[1]
    return (Format-Nano11ConfigDiff -DiffResult $diff)
}

# Read-only, scrollable text dialog (MessageBox truncates long results)
function Show-Nano11GuiTextDialog {
    param([string]$Title, [string]$Text, [System.Windows.Forms.IWin32Window]$Owner)
    $dlg = New-Nano11Form -Text $Title -Width 720 -Height 520 -ClientSize
    try {
        $txt = New-Nano11TextBox -Fill -Multiline -ReadOnly -ScrollBars Both -WordWrap $false -Font (New-Object System.Drawing.Font('Consolas', 9)) -Text ($Text -replace "(?<!`r)`n", "`r`n") -Parent $dlg
        [void]$txt.Select(0, 0)
        if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    } finally { $dlg.Dispose() }
}

# "Preset Diff" picker: choose a base (presets or current window) and a target, then show the diff
function Show-Nano11GuiPresetDiff {
    param([hashtable]$Gui)
    $names = @(Get-Nano11UiString 'Dlg.PresetDiff.CurrentSettings')
    if ($script:BuiltInPresets) { $names += @($script:BuiltInPresets.Keys) }
    $dlg = New-Nano11Form -Text (Get-Nano11UiString 'Dlg.PresetDiff.Title') -Width 400 -Height 160 -ClientSize -FixedDialog -NoMaximize -NoMinimize -ForeColor ([System.Drawing.Color]::White)
    try {
        $combos = @{}
        $rows = @(@('From', (Get-Nano11UiString 'Dlg.PresetDiff.From'), 20, 0), @('To', (Get-Nano11UiString 'Dlg.PresetDiff.To'), 55, [Math]::Min(1, $names.Count - 1)))
        foreach ($r in $rows) {
            [void](New-Nano11Label -Text $r[1] -X 15 -Y ($r[2] + 3) -Width 100 -Height 20 -Parent $dlg)
            $cmb = New-Nano11ComboBox -Items $names -SelectedIndex $r[3] -DropList -X 120 -Y $r[2] -Width 260 -Parent $dlg
            $combos[$r[0]] = $cmb
        }
        $dlg.Tag = @{ Gui = $Gui; From = $combos['From']; To = $combos['To'] }
        [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Compare') -X 120 -Y 105 -Width 120 -Height 32 -Parent $dlg -OnClick {
            $f = $this.FindForm()
            $t = $f.Tag
            try {
                $txt = Get-Nano11GuiPresetDiffText -Gui $t.Gui -From ([string]$t.From.SelectedItem) -To ([string]$t.To.SelectedItem)
                Show-Nano11GuiTextDialog -Title (Get-Nano11UiString 'Dlg.PresetDiff.ResultTitle' -Format $t.From.SelectedItem, $t.To.SelectedItem) -Text $txt -Owner $f
            } catch {
                Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Dlg.PresetDiff.Title') -Kind Error
            }
        })
        $btnClose = New-Nano11Button -Text (Get-Nano11UiString 'Button.Close') -X 260 -Y 105 -Width 120 -Height 32 -Parent $dlg
        $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.CancelButton = $btnClose
        [void]$dlg.ShowDialog()
    } finally { $dlg.Dispose() }
}

# Validate the form and fill $Gui.Result; returns $false (after a message) if input is invalid
function Get-Nano11GuiDraftConfig {
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
    if ($Gui.ClbStd) { foreach ($item in $Gui.ClbStd.CheckedItems) { $stdSelected += (Get-Nano11ListItemValue $item) } }
    $expSelected = @()
    if ($Gui.ClbExp) { foreach ($item in $Gui.ClbExp.CheckedItems) { $expSelected += (Get-Nano11ListItemValue $item) } }
    $cfg['AdvancedDebloatStandard'] = $stdSelected
    $cfg['AdvancedDebloatExperimental'] = $expSelected
    return $cfg
}

# --- Tab 8 (Migration & Backup) helpers ---------------------------------------------------------

# Backup destination typed in Tab 8 (a default outside the personal folders when empty)
function Get-Nano11GuiMigrationRoot {
    param([hashtable]$Gui)
    $root = ''
    if ($Gui.MigRoot) { $root = $Gui.MigRoot.Text.Trim() }
    if (-not $root) { $root = Get-Nano11DefaultMigrationBackupPath }
    return $root
}

# Checked personal folders -> @{ Category = real path } (only folders that exist)
function Get-Nano11GuiMigrationFolderMap {
    param([hashtable]$Gui)
    if (-not $Gui.MigFolders) { return @{} }
    return (Get-Nano11MigrationFolderMapFromNames -Names @($Gui.MigFolders.CheckedItems | ForEach-Object { "$_" }))
}

# Personal folder names (Documents, Desktop, ...) -> @{ Category = real path } (only folders that exist)
function Get-Nano11MigrationFolderMapFromNames {
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
function Initialize-Nano11GuiMigrationRules {
    param($List)
    $migRuleRows = @()
    $migRuleIds = @()
    try {
        . (Join-Path $script:Nano11GuiRepoRoot 'tools\migrator\Nano11Migration.ps1')
        $migRulesData = Get-Nano11MigrationRules
        foreach ($r in (@($migRulesData.GameRules) + @($migRulesData.AppConfigRules))) {
            if (-not $r -or -not $r.Id) { continue }
            $migRuleRows += "$($r.Id) - $($r.Name)"
            $migRuleIds += [string]$r.Id
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if ($migRuleRows.Count -eq 0) {
        # Placeholder row only: the list is disabled so it can never be checked or passed as a rule Id
        [void]$List.Items.Add((Get-Nano11UiString 'Mig.NoRules'))
        $List.Enabled = $false
    } else {
        foreach ($row in $migRuleRows) { [void]$List.Items.Add($row) }
    }
    $List.Tag = $migRuleIds
}

# Ids of the checked migration rules. The list holds display rows only; the Ids live in its Tag.
function Get-Nano11GuiMigrationRuleIds {
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

# Parameters for Start-Nano11MigrationBackup built from the current Tab 8 state
function Get-Nano11GuiBackupArgs {
    param([hashtable]$Gui)
    $a = @{
        BackupRoot = (Get-Nano11GuiMigrationRoot -Gui $Gui)
        RuleIds    = @(Get-Nano11GuiMigrationRuleIds -Gui $Gui)
        FolderMap  = (Get-Nano11GuiMigrationFolderMap -Gui $Gui)
    }
    if ($Gui.MigExcludeSecrets -and -not $Gui.MigExcludeSecrets.Checked) { $a['IncludeSecrets'] = $true }
    return $a
}

function Get-Nano11GuiConflictPolicy {
    param([hashtable]$Gui)
    if ($Gui.MigConflict -and $Gui.MigConflict.SelectedItem) { return [string]$Gui.MigConflict.SelectedItem }
    return 'BackupExisting'
}

# Readiness check against the settings currently shown in the window (not the start-up settings)
function Get-Nano11GuiRecoveryReadiness {
    param([hashtable]$Gui)
    $draft = Get-Nano11GuiDraftConfig -Gui $Gui
    return Test-Nano11RecoveryReadiness -Config $draft
}

# Runs tools\migrator\Nano11Migration.ps1 code in a background job while the window keeps repainting.
# -Script is the text of a script block that takes one parameter (the hashtable in -Arguments).
# Errors written to the job's error stream are returned even when the job itself completed.
function Invoke-Nano11GuiMigrationJob {
    param([string]$RepoRoot, [string]$Script, [hashtable]$Arguments = @{}, [object]$Button, [object]$Form)
    $o = Invoke-Nano11GuiBackgroundJob -Button $Button -Form $Form -ArgumentList $RepoRoot, $Script, $Arguments -ScriptBlock {
        param($repoRoot, $inner, $jobArgs)
        Set-Location -LiteralPath $repoRoot
        . (Join-Path $repoRoot 'tools\migrator\Nano11Migration.ps1')
        & ([scriptblock]::Create($inner)) $jobArgs
    }
    $result = $null
    if (-not $o.Error -and @($o.Output).Count -gt 0) { $result = @($o.Output)[-1] }
    return [PSCustomObject]@{ Result = $result; Error = $o.Error; Errors = $o.Errors }
}

# Job outcome -> message box (errors from the error stream are appended to a successful message)
function Show-Nano11GuiJobOutcome {
    param($Outcome, [string]$Title, [string]$SuccessMessage)
    $kind = 'Info'
    if ($Outcome.Error) {
        $msg = Get-Nano11UiString 'Msg.Error' -Format $Outcome.Error
        $kind = 'Error'
    } else {
        $msg = $SuccessMessage
        if (@($Outcome.Errors).Count -gt 0) {
            $msg += "`n`n" + (Get-Nano11UiString 'Msg.ErrorsReported') + "`n" + (@($Outcome.Errors) -join "`n")
            $kind = 'Warning'
        }
    }
    Show-Nano11GuiMessage -Text $msg -Title $Title -Kind $kind
}

# Checks every file recorded in migration-manifest.json: present and (when recorded) matching SHA-256
function Test-Nano11GuiBackupIntegrity {
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
function Resolve-Nano11GuiSource {
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
function Get-Nano11GuiDefaultWorkDir {
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    return (Join-Path -Path $docsDir -ChildPath "nano11_workspace")
}

function Complete-Nano11GuiResult {
    param([hashtable]$Gui)
    $srcText = $Gui.Source.Text.Trim()
    if (-not $srcText) {
        Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.SourceRequired.Text') -Title (Get-Nano11UiString 'Msg.SourceRequired.Title') -Kind Warning
        return $false
    }

    $resolvedSource = Resolve-Nano11GuiSource -Text $srcText

    $wDir = $Gui.Work.Text.Trim()
    if (-not $wDir) { $wDir = Get-Nano11GuiDefaultWorkDir }

    $guiUserName = $Gui.UserName.Text.Trim()
    $guiComputerName = $Gui.ComputerName.Text.Trim()
    if (-not $guiComputerName) { $guiComputerName = '*' }
    if ($guiUserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') {
        Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.InvalidUserName.Text') -Title (Get-Nano11UiString 'Msg.InvalidUserName.Title') -Kind Warning
        return $false
    }
    if ($guiComputerName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') {
        Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.InvalidComputerName.Text') -Title (Get-Nano11UiString 'Msg.InvalidComputerName.Title') -Kind Warning
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

    # Advanced Debloat items
    $stdSelected = @()
    foreach ($item in $Gui.ClbStd.CheckedItems) { $stdSelected += (Get-Nano11ListItemValue $item) }
    $expSelected = @()
    foreach ($item in $Gui.ClbExp.CheckedItems) { $expSelected += (Get-Nano11ListItemValue $item) }
    $formResult.AdvancedDebloatStandard     = $stdSelected
    $formResult.AdvancedDebloatExperimental = $expSelected

    return $true
}

# =========================================================================
# Main window tabs. Each takes the GUI context ($gui) and adds its controls and
# checkbox tables to it; handlers read them back from $this.FindForm().Tag.
# =========================================================================
# Tab 1: media, workspace, preset and payload format
function New-Nano11MediaTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings
    )
    # =========================================================================
    # TAB 1: Media & Workspace & Preset
    # =========================================================================
    $tabMedia = New-Nano11TabPage -Text (Get-Nano11UiString 'Tab.Media') -TabControl $tabControl

    $grpMedia = New-Nano11GroupBox -Text (Get-Nano11UiString 'Media.Group.Source') -X 15 -Y 10 -Width 835 -Height 185 -Parent $tabMedia

    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.Source') -X 15 -Y 28 -Width 130 -Height 20 -Parent $grpMedia)
    $cmbSource = New-Nano11ComboBox -X 150 -Y 25 -Width 370 -BackColor $script:Nano11GuiColors.Input -ForeColor ([System.Drawing.Color]::White) -Parent $grpMedia
    $gui.Source = $cmbSource

    Update-Nano11GuiSources -Combo $cmbSource

    if ($InitialSettings.SourceDrive) { $cmbSource.Text = $InitialSettings.SourceDrive }
    elseif ($cmbSource.Items.Count -gt 0) { $cmbSource.SelectedIndex = 0 }
    else { $cmbSource.Text = "E:\" }

    # Browse / rescan buttons carry the control they fill on their Tag
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.BrowseDrive') -X 530 -Y 24 -Width 110 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = Get-Nano11UiString 'Media.Dialog.BrowseDrive'
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $this.Tag.Text = $p
        }
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.BrowseISO') -X 645 -Y 24 -Width 100 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = Get-Nano11UiString 'Media.ISOFilter'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $ofd.FileName }
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Rescan') -X 750 -Y 24 -Width 70 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        Update-Nano11GuiSources -Combo $this.Tag
    })

    $browseFolder = {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $fbd.SelectedPath }
    }

    # WorkDir
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.Workspace') -X 15 -Y 60 -Width 130 -Height 20 -Parent $grpMedia)
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    $workText = if ($InitialSettings.WorkDir) { $InitialSettings.WorkDir } else { Join-Path -Path $docsDir -ChildPath "nano11_workspace" }
    $gui.Work = New-Nano11TextBox -X 150 -Y 57 -Width 535 -Text $workText -Parent $grpMedia
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.BrowseFolder') -X 695 -Y 56 -Width 125 -Height 26 -Tag $gui.Work -OnClick $browseFolder -Parent $grpMedia)

    # Index & Drivers
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.Index') -X 15 -Y 95 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.Index = New-Nano11TextBox -X 150 -Y 92 -Width 70 -Text $(if ($InitialSettings.Index) { "$($InitialSettings.Index)" }) -Parent $grpMedia
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.Drivers') -X 235 -Y 95 -Width 140 -Height 20 -Parent $grpMedia)
    $gui.Drivers = New-Nano11TextBox -X 380 -Y 92 -Width 305 -Text $(if ($InitialSettings.InjectDrivers) { "$($InitialSettings.InjectDrivers)" }) -Parent $grpMedia
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Browse') -X 695 -Y 91 -Width 125 -Height 26 -Tag $gui.Drivers -OnClick $browseFolder -Parent $grpMedia)

    # User & Computer
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.UserName') -X 15 -Y 130 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.UserName = New-Nano11TextBox -X 150 -Y 127 -Width 160 -Text $(if ($InitialSettings.UserName) { "$($InitialSettings.UserName)" } else { "User" }) -Parent $grpMedia
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Media.Label.ComputerName') -X 330 -Y 130 -Width 120 -Height 20 -Parent $grpMedia)
    $gui.ComputerName = New-Nano11TextBox -X 450 -Y 127 -Width 160 -Text $(if ($InitialSettings.ComputerName) { "$($InitialSettings.ComputerName)" } else { "*" }) -Parent $grpMedia

    # Preset Group
    $grpPreset = New-Nano11GroupBox -Text (Get-Nano11UiString 'Media.Group.Preset') -X 15 -Y 205 -Width 835 -Height 75 -Parent $tabMedia

    $cmbPreset = New-Nano11ComboBox -DropList -X 15 -Y 28 -Width 805 -BackColor $script:Nano11GuiColors.Input -ForeColor ([System.Drawing.Color]::White) -Parent $grpPreset -Items @(
        (Get-Nano11UiString 'Media.Preset.Extreme'),
        (Get-Nano11UiString 'Media.Preset.Balanced'),
        (Get-Nano11UiString 'Media.Preset.Fat32'),
        (Get-Nano11UiString 'Media.Preset.Handheld'),
        (Get-Nano11UiString 'Media.Preset.VM'),
        (Get-Nano11UiString 'Media.Preset.Audio'),
        (Get-Nano11UiString 'Media.Preset.Custom')
    )
    $gui.Preset = $cmbPreset

    # Payload Format Group
    $grpPayload = New-Nano11GroupBox -Text (Get-Nano11UiString 'Media.Group.Payload') -X 15 -Y 290 -Width 835 -Height 95 -Parent $tabMedia
    $gui.RadWIM = New-Nano11CheckBox -Radio -Text (Get-Nano11UiString 'Media.Radio.WIM') -X 15 -Y 28 -Width 350 -Height 24 -Checked $true -Parent $grpPayload
    $gui.RadESD = New-Nano11CheckBox -Radio -Text (Get-Nano11UiString 'Media.Radio.ESD') -X 380 -Y 28 -Width 250 -Height 24 -Parent $grpPayload
    $gui.RadSWM = New-Nano11CheckBox -Radio -Text (Get-Nano11UiString 'Media.Radio.SWM') -X 640 -Y 28 -Width 185 -Height 24 -Parent $grpPayload

    if ($InitialSettings.ExportESDMode) { $gui.RadESD.Checked = $true }
    elseif ($InitialSettings.SplitWIMMode) { $gui.RadSWM.Checked = $true }

    $gui.VHDX = New-Nano11CheckBox -Text (Get-Nano11UiString 'Media.Check.VHDX') -X 15 -Y 60 -Width 550 -Height 24 `
        -Checked ([bool]$InitialSettings.UseVHDX) -Parent $grpPayload
}

# Tabs 2-5: one toggle tab per tweak category
function New-Nano11TweakTabs {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TABS 2-5: tweak toggles from config\tweaks.psd1, one tab per category
    # =========================================================================
    foreach ($cat in @(
        @((Get-Nano11UiString 'Tab.Security'), "Security"),
        @((Get-Nano11UiString 'Tab.Privacy'), "Privacy"),
        @((Get-Nano11UiString 'Tab.Performance'), "Performance"),
        @((Get-Nano11UiString 'Tab.UI'), "UI")
    )) {
        $category = $cat[1]
        $page = New-Nano11ToggleTab -Text $cat[0] -TabControl $tabControl -Caption (Get-Nano11UiString 'Tab.TweakCaption' -Format (Get-Nano11UiString "Category.$category" -Default $category))
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
            $desc = Get-Nano11TweakDescription -Key $tk -Def $def
            $chk = New-Nano11ToggleCheckBox -Parent $page.Flow -Key $tk -Text "$tk - $desc" -ToolTip $toolTip -ToolTipText $desc -Checked $initVal
            $gui.TweakCheckboxes[$tk] = $chk
            $tabCheckboxes.Add($chk)
        }
        [void](Add-Nano11SelectButtons -Parent $page.Bar -Target $tabCheckboxes -X 15 -Y 7)
    }
}

# Tab 6: component switches
function New-Nano11ServicesTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # TAB 6: Components & Services
    # =========================================================================
    $page = New-Nano11ToggleTab -Text (Get-Nano11UiString 'Tab.Services') -TabControl $tabControl

    # Components with a Gui entry in config\tweaks.psd1, in their Gui.Order
    $svcDefs = @($script:ComponentDefs.Values | Where-Object { $_.Gui -and $_.Gui.Tab -ne 'Migration' } | Sort-Object { [int]$_.Gui.Order } | ForEach-Object {
        @{ Key = $_.Key; Text = (Get-Nano11UiString -Key "Component.$($_.Key).Text" -Default $_.Gui.Text); Desc = (Get-Nano11UiString -Key "Component.$($_.Key).Description" -Default $_.Gui.Description); Def = [bool]$_.Gui.Default }
    })
    $svcCheckboxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    foreach ($sd in $svcDefs) {
        $initVal = [bool]$sd.Def
        if ($InitialSettings.ContainsKey($sd.Key)) { $initVal = [bool]$InitialSettings[$sd.Key] }
        $chk = New-Nano11ToggleCheckBox -Parent $page.Flow -Key $sd.Key -Text "$($sd.Key) - $($sd.Text)" -ToolTip $toolTip -ToolTipText $sd.Desc -Checked $initVal
        $gui.ComponentCheckboxes[$sd.Key] = $chk
        $svcCheckboxes.Add($chk)
    }
    [void](Add-Nano11SelectButtons -Parent $page.Bar -Target $svcCheckboxes -X 15 -Y 7)
}

# Advanced Debloat items of Tab 7 (and of the WinUI 3 window). The English text is the value phases\09 matches.
$script:Nano11DebloatStandardItems = @(
    "Remove WinRE (reagentc /disable + file delete) [500-700MB]",
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
    "Remove Windows Store cache [varies]",
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

$script:Nano11DebloatExperimentalItems = @(
    "Physical: Edge / WebView2 (complete removal) [~200MB]",
    "Physical: Defender (complete removal) [~50MB]",
    "Physical: Cortana / Search (complete removal) [~100MB]",
    "Physical: OneDrive (complete removal) [~50MB]",
    "Physical: Telemetry/DiagTrack (complete removal) [~30MB]",
    "Physical: Hyper-V / Virtualization stack [~200-400MB]",
    "Physical: IIS (Web server) [~50-100MB]",
    "Physical: Windows Firewall (complete removal) [~20-40MB]",
    "Physical: Bluetooth stack (complete removal) [~20-40MB]",
    "Physical: Print Spooler (complete removal) [~20-30MB]",
    "Physical: Touch/Pen/Ink (complete removal) [~20-30MB]",
    "Physical: Accessibility tools (OOBE-safe: retained, IFEO-blocked) [0MB]",
    "Physical: Windows Media Player (complete removal) [~50-100MB]",
    "Physical: Remote Desktop host (OOBE-safe: Terminal Server keys retained) [~0MB]",
    "Physical: BitLocker (complete removal) [~30-50MB]",
    "Physical: Windows Sandbox (complete removal) [~10-20MB]",
    "Physical: WSL / VM Platform (complete removal) [~20-40MB]",
    "Physical: Help files (complete removal) [~10-20MB]",
    "Physical: Crash dumps (complete removal) [varies]",
    "Physical: Provisioning packages (complete removal) [~5-10MB]",
    "Physical: Delivery Optimization (complete removal) [varies]",
    "Physical: Windows Search index (complete removal) [varies]",
    "Physical: Windows.old (complete removal) [varies]",
    "Physical: Temp files (complete removal) [varies]",
    "Physical: Installer cache PatchCache (complete removal) [varies]",
    "Physical: pagefile.sys (disable + delete) [4-16GB]",
    "Physical: hiberfil.sys (disable + delete) [4-16GB]",
    "Physical: swapfile.sys (disable + delete) [256MB-1GB]",
    "Physical: Memory.dmp (complete removal) [varies]",
    "Physical: Minidump (complete removal) [varies]"
)

# Tab 7: Advanced Debloat lists
function New-Nano11DebloatTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [string]$UiFontName
    )
    # =========================================================================
    # TAB 7: Advanced Debloat (Physical Deletion)
    # =========================================================================
    $stdItems = $script:Nano11DebloatStandardItems
    $expItems = $script:Nano11DebloatExperimentalItems

    $preStd = @()
    if ($InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    $preExp = @()
    if ($InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }

    $tabDebloat = New-Nano11TabPage -Text (Get-Nano11UiString 'Tab.Debloat') -TabControl $tabControl
    $barDeb = New-Nano11ButtonBar -Parent $tabDebloat
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Debloat.Notice') -X 15 -Y 11 -Width 650 -Height 20 `
        -ForeColor $script:Nano11GuiColors.Warn -Font (New-Object System.Drawing.Font($uiFontName, 8.5)) -Parent $barDeb)
    $flowDeb = New-Nano11FlowPanel -Parent $tabDebloat

    # Standard Debloat group
    $grpStdDeb = New-Nano11GroupBox -Text (Get-Nano11UiString 'Debloat.Group.Standard') -Width 410 -Height 480 -Parent $flowDeb
    $gui.ClbStd = New-Nano11CheckedList -Items $stdItems -Selected $preStd -DisplayText $script:Nano11DebloatDisplayText -Fill -Parent $grpStdDeb

    # Experimental Debloat group
    $grpExpDeb = New-Nano11GroupBox -Text (Get-Nano11UiString 'Debloat.Group.Experimental') -Width 410 -Height 480 `
        -ForeColor $script:Nano11GuiColors.Danger -Parent $flowDeb
    $gui.ClbExp = New-Nano11CheckedList -Items $expItems -Selected $preExp -DisplayText $script:Nano11DebloatDisplayText -Fill -Parent $grpExpDeb

    # Select All / Clear All bar at the bottom of each debloat group
    foreach ($pair in @(@($grpStdDeb, $gui.ClbStd, $null), @($grpExpDeb, $gui.ClbExp, (Get-Nano11UiString 'Debloat.ConfirmSelectExperimental')))) {
        $barList = New-Nano11ButtonBar -Parent $pair[0] -Dock Bottom -Height 34 -BackColor $null
        $pair[1].BringToFront()
        [void](Add-Nano11SelectButtons -Parent $barList -Target $pair[1] -X 5 -Y 4 -Step 100 -ConfirmSelect $pair[2])
    }
}

# Tab 8, right column: backup / restore / verify / estimate action buttons
function New-Nano11MigrationActionsGroup {
    param([object]$Parent)
    $grpActions = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Actions') -Width 410 -Height 420 -Parent $Parent
    $btnY = 22
    $btnStep = 38
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Readiness') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        try {
            $rr = Get-Nano11GuiRecoveryReadiness -Gui $g
            $msg = Get-Nano11UiString 'Mig.Readiness.Message' -Format $rr.ReadinessScore, ($rr.SecondaryDrives -join ', '), $rr.SystemRestoreEnabled, $rr.WinReEnabledOnTarget, ($rr.Recommendations -join "`n")
            Show-Nano11GuiMessage -Text $msg -Title (Get-Nano11UiString 'Mig.Readiness.Title') -Kind Info
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Mig.Readiness.Title') -Kind Error
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.ExportApps') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $dlg.Title = Get-Nano11UiString 'Mig.Button.ExportApps'
            $dlg.Filter = Get-Nano11UiString 'Mig.Export.Filter'
            $dlg.FileName = "apps-inventory.json"
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $outPath = $dlg.FileName
        } finally { $dlg.Dispose() }
        $o = Invoke-Nano11GuiMigrationJob -Button $btn -Form $f -RepoRoot $script:Nano11GuiRepoRoot -Script 'param($a) Export-Nano11AppInventory -OutputPath $a.OutputPath' -Arguments @{ OutputPath = $outPath }
        Show-Nano11GuiJobOutcome -Outcome $o -Title (Get-Nano11UiString 'Mig.Export.Title') -SuccessMessage (Get-Nano11UiString 'Mig.Export.Done' -Format $outPath)
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Wizard') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        $repoRoot = $script:Nano11GuiRepoRoot
        $migratorPath = Join-Path $repoRoot "tools\migrator\Nano11-Migrator.ps1"
        if (Test-Path -LiteralPath $migratorPath) {
            try {
                $root = Get-Nano11GuiMigrationRoot -Gui $g
                # -BackupRoot exists in every Nano11-Migrator.ps1 version (it is a -PackagePath alias after S6);
                # the wizard opens in the language of this window
                Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$migratorPath`" -GUI -BackupRoot `"$root`" -UiLanguage $($script:Nano11UiLanguage)" -WindowStyle Normal
            } catch {
                Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Mig.Wizard.Title') -Kind Error
            }
        } else {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Mig.Wizard.NotFound') -Title (Get-Nano11UiString 'Mig.Wizard.Title') -Kind Warning
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Estimate') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $map = Get-Nano11GuiMigrationFolderMap -Gui $g
        $ea = @{ UserFolderPaths = @($map.Values); SelectedRuleIds = @(Get-Nano11GuiMigrationRuleIds -Gui $g); DestinationPath = (Get-Nano11GuiMigrationRoot -Gui $g) }
        $o = Invoke-Nano11GuiMigrationJob -Button $btn -Form $f -RepoRoot $script:Nano11GuiRepoRoot -Arguments $ea -Script 'param($a) Get-Nano11MigrationSizeEstimate -UserFolderPaths $a.UserFolderPaths -SelectedRuleIds $a.SelectedRuleIds -DestinationPath $a.DestinationPath'
        $est = $o.Result
        $msg = if ($est) { Get-Nano11UiString 'Mig.Estimate.Message' -Format $est.TotalFiles, $est.TotalMB, $est.DestinationDrive, $est.DestinationFreeMB, $est.HasEnoughSpace } else { Get-Nano11UiString 'Mig.Estimate.None' }
        Show-Nano11GuiJobOutcome -Outcome $o -Title (Get-Nano11UiString 'Mig.Button.Estimate') -SuccessMessage $msg
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Backup') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $backupArgs = Get-Nano11GuiBackupArgs -Gui $g
        $o = Invoke-Nano11GuiMigrationJob -Button $btn -Form $f -RepoRoot $script:Nano11GuiRepoRoot -Arguments $backupArgs -Script 'param($a) Start-Nano11MigrationBackup @a'
        Show-Nano11GuiJobOutcome -Outcome $o -Title (Get-Nano11UiString 'Mig.Backup.Title') -SuccessMessage (Get-Nano11UiString 'Mig.Backup.Done' -Format $backupArgs.BackupRoot)
        if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = Get-Nano11UiString 'Mig.Backup.Status' }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Verify') -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $script = (Get-Command Test-Nano11GuiBackupIntegrity).ScriptBlock.ToString()
        $o = Invoke-Nano11GuiMigrationJob -Button $btn -Form $f -RepoRoot $script:Nano11GuiRepoRoot -Arguments @{ BackupRoot = (Get-Nano11GuiMigrationRoot -Gui $g) } -Script $script
        $vr = $o.Result
        if ($vr -and @($vr.Problems).Count -gt 0) {
            $o.Errors = @($o.Errors) + @($vr.Problems)
            $msg = Get-Nano11UiString 'Mig.Verify.Problems' -Format $vr.Checked, @($vr.Problems).Count
        } elseif ($vr) { $msg = Get-Nano11UiString 'Mig.Verify.Ok' -Format $vr.Checked } else { $msg = Get-Nano11UiString 'Mig.Verify.None' }
        Show-Nano11GuiJobOutcome -Outcome $o -Title (Get-Nano11UiString 'Mig.Verify.Title') -SuccessMessage $msg
    })
    $btnY += $btnStep
    foreach ($rs in @(@((Get-Nano11UiString 'Mig.Button.Restore'), $false), @((Get-Nano11UiString 'Mig.Button.Retry'), $true))) {
        [void](New-Nano11Button -Text $rs[0] -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -Tag $rs[1] -OnClick {
            $btn = $this
            $retry = [bool]$btn.Tag
            $f = $btn.FindForm()
            $g = $f.Tag
            $ra = @{ BackupRoot = (Get-Nano11GuiMigrationRoot -Gui $g); ConflictPolicy = (Get-Nano11GuiConflictPolicy -Gui $g) }
            if ($retry) { $ra['RetryFailedOnly'] = $true }
            $o = Invoke-Nano11GuiMigrationJob -Button $btn -Form $f -RepoRoot $script:Nano11GuiRepoRoot -Arguments $ra -Script 'param($a) Start-Nano11MigrationRestore @a'
            $msg = Get-Nano11UiString 'Mig.Restore.Done'
            if ($o.Result -and $o.Result.Results) { $msg += "`n" + ($o.Result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String) }
            Show-Nano11GuiJobOutcome -Outcome $o -Title (Get-Nano11UiString 'Mig.Restore.Title') -SuccessMessage $msg
            if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = Get-Nano11UiString 'Mig.Restore.Done' }
        })
        $btnY += $btnStep
    }
}

# Tab 8: custom file/folder backup and restore
function New-Nano11MigrationCustomPathsGroup {
    param([hashtable]$Gui, [object]$Parent)
    # Custom paths backup/restore section
    $grpCustom = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Custom') -Width 840 -Height 140 -Parent $Parent
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Mig.Label.CustomPaths') -X 15 -Y 20 -Width 140 -Height 20 -Parent $grpCustom)
    $txtCustomPaths = New-Nano11TextBox -X 15 -Y 42 -Width 560 -Height 60 -Multiline -ScrollBars Vertical -ForeColor $script:Nano11GuiColors.Text -Parent $grpCustom
    $gui.CustomPaths = $txtCustomPaths

    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.BackupCustom') -X 590 -Y 42 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        try {
            $result = Invoke-Nano11GuiBusy -Button $this -Form $f -ArgumentList $g -Action {
                param($gui)
                $root = Get-Nano11GuiMigrationRoot -Gui $gui
                $paths = @($gui.CustomPaths.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($paths.Count -eq 0) { throw (Get-Nano11UiString 'Mig.Custom.NoPaths') }
                Backup-Nano11CustomPaths -Paths $paths -BackupRoot $root
            }
            $msg = Get-Nano11UiString 'Mig.Custom.BackupDone' -Format $result.CopiedFiles, $result.FailedFiles.Count
            Show-Nano11GuiMessage -Text $msg -Title (Get-Nano11UiString 'Mig.Button.BackupCustom') -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = Get-Nano11UiString 'Mig.Custom.BackupStatus' -Format $result.CopiedFiles }
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Mig.Button.BackupCustom') -Kind Error
        }
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.RestoreCustom') -X 590 -Y 82 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        try {
            $result = Invoke-Nano11GuiBusy -Button $this -Form $f -ArgumentList $g -Action {
                param($gui)
                Restore-Nano11CustomPaths -BackupRoot (Get-Nano11GuiMigrationRoot -Gui $gui) -ConflictPolicy (Get-Nano11GuiConflictPolicy -Gui $gui)
            }
            $msg = Get-Nano11UiString 'Mig.Custom.RestoreDone' -Format $result.RestoredFiles, $result.FailedFiles.Count
            Show-Nano11GuiMessage -Text $msg -Title (Get-Nano11UiString 'Mig.Button.RestoreCustom') -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = Get-Nano11UiString 'Mig.Custom.RestoreStatus' -Format $result.RestoredFiles }
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Mig.Button.RestoreCustom') -Kind Error
        }
    })
}

# Tab 8: what config\user\user-tweaks.psd1 loaded (set by the builder)
function New-Nano11MigrationExtensionsGroup {
    param([hashtable]$Gui, [object]$Parent)
    # User Extensions & Custom Scripts card: what config\user\user-tweaks.psd1 loaded (set by the builder)
    $grpExt = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Extensions') -Width 840 -Height 110 -Parent $Parent
    $extRes = $script:UserExtensionsResult
    $extErrors = @()
    if ($extRes -and $extRes.Errors) { $extErrors = @($extRes.Errors | Where-Object { $_ }) }
    if ($extRes) {
        $extText = Get-Nano11UiString 'Mig.Ext.Counts' -Format $extRes.UserTweakCount, $extRes.UserPresetCount, $extRes.CustomScriptCount
    } else {
        $extText = Get-Nano11UiString 'Mig.Ext.NotLoaded'
    }
    [void](New-Nano11Label -Text $extText -X 15 -Y 24 -Width 600 -Height 20 -Parent $grpExt)
    $gui.ExtensionsLabel = New-Nano11Label -Text $(if ($extErrors.Count -gt 0) { Get-Nano11UiString 'Mig.Ext.LoadErrors' -Format ($extErrors -join '; ') } else { Get-Nano11UiString 'Mig.Ext.NoErrors' }) `
        -X 15 -Y 48 -Width 600 -Height 52 -ForeColor $(if ($extErrors.Count -gt 0) { $script:Nano11GuiColors.Warn } else { $script:Nano11GuiColors.Muted }) -Parent $grpExt
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Mig.Button.Guide') -X 630 -Y 24 -Width 190 -Height 32 -Parent $grpExt -OnClick {
        $guide = Join-Path $script:Nano11GuiRepoRoot "docs\EXTENSIBILITY_GUIDE.md"
        try {
            if (-not (Test-Path -LiteralPath $guide)) { throw (Get-Nano11UiString 'Mig.Guide.NotFound' -Format $guide) }
            Start-Process -FilePath $guide
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Mig.Guide.Title') -Kind Error
        }
    })
}

# Tab 8: Migration & Backup
function New-Nano11MigrationTab {
    param(
        [hashtable]$Gui,
        [System.Windows.Forms.TabControl]$TabControl,
        [hashtable]$InitialSettings,
        [System.Windows.Forms.ToolTip]$ToolTip
    )
    # =========================================================================
    # Tab 8: Migration & Backup
    # =========================================================================
    $tabMigration = New-Nano11TabPage -Text (Get-Nano11UiString 'Tab.Migration') -TabControl $tabControl
    $flowMig = New-Nano11FlowPanel -Parent $tabMigration

    # Top card: Post-Install Migration Assistant (a component switch from config\tweaks.psd1, Gui.Tab = 'Migration')
    $grpAssist = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Assistant') -Width 840 -Height 60 -Parent $flowMig
    $asDef = $script:ComponentDefs['IncludeMigrationAssistant']
    if ($asDef -and $asDef.Gui) {
        $asInit = [bool]$asDef.Gui.Default
        $asText = Get-Nano11UiString -Key 'Component.IncludeMigrationAssistant.Text' -Default $asDef.Gui.Text
        $asDesc = Get-Nano11UiString -Key 'Component.IncludeMigrationAssistant.Description' -Default $asDef.Gui.Description
        if ($InitialSettings.ContainsKey('IncludeMigrationAssistant')) { $asInit = [bool]$InitialSettings['IncludeMigrationAssistant'] }
        $chkAssist = New-Nano11ToggleCheckBox -Parent $grpAssist -Key 'IncludeMigrationAssistant' -Text "IncludeMigrationAssistant - $asText" -ToolTip $toolTip -ToolTipText $asDesc -Checked $asInit
        $chkAssist.Location = New-Object System.Drawing.Point(15, 24)
        $chkAssist.Size = New-Object System.Drawing.Size(800, 28)
        $gui.ComponentCheckboxes['IncludeMigrationAssistant'] = $chkAssist
    }

    # Backup settings: destination, credential handling, conflict policy
    $grpTop = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Backup') -Width 840 -Height 110 -Parent $flowMig
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Mig.Label.BackupRoot') -X 15 -Y 22 -Width 90 -Height 20 -Parent $grpTop)
    $txtMigRoot = New-Nano11TextBox -X 110 -Y 20 -Width 420 -Height 24 -Text (Get-Nano11DefaultMigrationBackupPath) -Parent $grpTop
    $gui.MigRoot = $txtMigRoot
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.Browse') -X 540 -Y 19 -Width 90 -Height 26 -Parent $grpTop -OnClick {
        $g = $this.FindForm().Tag
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dlg.Description = Get-Nano11UiString 'Mig.Dialog.Destination'
            if ($g.MigRoot.Text -and (Test-Path -LiteralPath $g.MigRoot.Text)) { $dlg.SelectedPath = $g.MigRoot.Text }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $g.MigRoot.Text = $dlg.SelectedPath }
        } finally { $dlg.Dispose() }
    })
    $lblMigStatus = New-Nano11Label -Text (Get-Nano11UiString 'Mig.Status.Initial') -X 640 -Y 22 -Width 190 -Height 40 -Parent $grpTop
    $gui.MigStatus = $lblMigStatus
    $gui.MigExcludeSecrets = New-Nano11CheckBox -Text (Get-Nano11UiString 'Mig.Check.ExcludeSecrets') -X 15 -Y 52 -Width 320 -Height 24 -Checked $true -Parent $grpTop
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Mig.Label.ConflictPolicy') -X 15 -Y 80 -Width 220 -Height 20 -Parent $grpTop)
    $cmbConflict = New-Nano11ComboBox -Items @('BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite') -SelectedIndex 0 -DropList -X 240 -Y 78 -Width 200 -Parent $grpTop
    $gui.MigConflict = $cmbConflict

    # Left: personal data folders + migration rules
    $grpRules = New-Nano11GroupBox -Text (Get-Nano11UiString 'Mig.Group.Rules') -Width 410 -Height 420 -Parent $flowMig
    $folderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads')
    $gui.MigFolders = New-Nano11CheckedList -Items $folderNames -Selected @('Documents', 'Desktop', 'Pictures') -X 10 -Y 20 -Width 390 -Height 100 -Parent $grpRules
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Mig.Label.Rules') -X 10 -Y 126 -Width 390 -Height 18 -Parent $grpRules)
    $clbMig = New-Nano11CheckedList -Items @() -X 10 -Y 146 -Width 390 -Height 264 -Parent $grpRules
    # Rules are filled in the first time this tab is opened (the migration engine is not loaded before that)
    $clbMig.Tag = @()
    $tabMigration.Tag = @{ Loaded = $false; List = $clbMig }
    $gui.MigTab = $tabMigration
    $tabMigration.Add_Enter({
        $st = $this.Tag
        if ($st.Loaded) { return }
        $st.Loaded = $true
        Initialize-Nano11GuiMigrationRules -List $st.List
    })
    $gui.MigRulesList = $clbMig

    New-Nano11MigrationActionsGroup -Parent $flowMig
    New-Nano11MigrationCustomPathsGroup -Gui $gui -Parent $flowMig
    New-Nano11MigrationExtensionsGroup -Gui $gui -Parent $flowMig
}

# Tab 9: user-defined switches outside the built-in categories
function New-Nano11UserTweaksTab {
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
    $pageUser = New-Nano11ToggleTab -Text (Get-Nano11UiString 'Tab.UserTweaks') -TabControl $tabControl -Caption (Get-Nano11UiString 'UserTweaks.Caption')
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
        $desc = Get-Nano11TweakDescription -Key $tk -Def $def
        $chk = New-Nano11ToggleCheckBox -Parent $pageUser.Flow -Key $tk -Text "$tk [$($def.Category)] - $desc" -ToolTip $toolTip -ToolTipText $desc -Checked $initVal
        $gui.TweakCheckboxes[$tk] = $chk
        $userTweakCount++
    }
    if ($userTweakCount -eq 0) {
        [void](New-Nano11Label -Text (Get-Nano11UiString 'UserTweaks.None') -X 0 -Y 0 -AutoSize -Parent $pageUser.Flow)
    }
}

# =========================================================================
# Main window content. Everything here is added to $Gui.Form and can be removed and built again, which is how
# the display language is switched: -InitialSettings carries the state to show (see Switch-Nano11GuiLanguage).
# =========================================================================
function Initialize-Nano11GuiContent {
    param(
        [hashtable]$Gui,
        [hashtable]$InitialSettings,
        [string]$UiFontName
    )
    $form = $Gui.Form
    $form.Text = Get-Nano11UiString 'Main.WindowTitle'

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $accent = $script:Nano11GuiColors.Accent
    $headerBack = $script:Nano11GuiColors.Header

    # Header Panel
    $headerPanel = New-Nano11ButtonBar -Parent $form -Height 65 -BackColor $headerBack
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Main.Title') -X 16 -Y 10 -AutoSize -ForeColor $accent `
        -Font (New-Object System.Drawing.Font($UiFontName, 14, [System.Drawing.FontStyle]::Bold)) -Parent $headerPanel)
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Main.Subtitle') -X 18 -Y 38 -AutoSize `
        -ForeColor $script:Nano11GuiColors.Subtle -Font (New-Object System.Drawing.Font($UiFontName, 8.5)) -Parent $headerPanel)

    # Display language selector (switching rebuilds the content with the current settings kept)
    [void](New-Nano11Label -Text (Get-Nano11UiString 'Main.Language') -X 690 -Y 10 -AutoSize -ForeColor $script:Nano11GuiColors.Muted -Parent $headerPanel)
    $langNames = @($script:Nano11UiLanguages | ForEach-Object { Get-Nano11UiString 'Language.Name' -Language $_ -Default $_ })
    $cmbLang = New-Nano11ComboBox -Items $langNames -SelectedIndex ([array]::IndexOf($script:Nano11UiLanguages, $script:Nano11UiLanguage)) -DropList `
        -X 690 -Y 30 -Width 160 -BackColor $script:Nano11GuiColors.Input -ForeColor $script:Nano11GuiColors.Text -Parent $headerPanel
    $cmbLang.Add_SelectedIndexChanged({
        $f = $this.FindForm()
        $lang = $script:Nano11UiLanguages[$this.SelectedIndex]
        if (-not $lang -or $lang -eq $script:Nano11UiLanguage) { return }
        $f.Tag.PendingLanguage = $lang
        # The rebuild disposes this combo, so it runs from a timer once this event has finished
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 10
        $timer.Tag = $f
        $timer.Add_Tick({
            $this.Stop()
            $owner = $this.Tag
            $this.Dispose()
            Switch-Nano11GuiLanguage -Gui $owner.Tag
        })
        $timer.Start()
    })
    $Gui.Language = $cmbLang

    # Bottom Button & Estimate Panel
    $bottomPanel = New-Nano11ButtonBar -Parent $form -Dock Bottom -Height 70 -BackColor $headerBack
    $Gui.DryRun = New-Nano11CheckBox -Text (Get-Nano11UiString 'Main.DryRun') -X 20 -Y 12 -Width 200 -Height 22 -Parent $bottomPanel
    $Gui.Estimate = New-Nano11Label -Text (Get-Nano11UiString 'Main.Estimate.Initial') -X 20 -Y 38 -Width 380 -Height 20 `
        -ForeColor $script:Nano11GuiColors.Muted -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel

    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.PresetDiff') -X 250 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel -OnClick {
        $g = $this.FindForm().Tag
        try {
            Show-Nano11GuiPresetDiff -Gui $g
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.PresetDiff.Failed' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Msg.PresetDiff.Title') -Kind Error
        }
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.CheckDependencies') -X 370 -Y 15 -Width 150 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        try {
            $cfg = Get-Nano11GuiDraftConfig -Gui $g
            $res = Test-Nano11Dependencies -Config $cfg
            $txt = Format-Nano11DependencyReport -Result $res
            if (-not $txt) { $txt = Get-Nano11UiString 'Msg.Dependency.None' }
            Show-Nano11GuiMessage -Text $txt -Title (Get-Nano11UiString 'Msg.Dependency.Title') -Kind Info
        } catch {
            Show-Nano11GuiMessage -Text (Get-Nano11UiString 'Msg.Dependency.Failed' -Format $_.Exception.Message) -Title (Get-Nano11UiString 'Msg.Dependency.Title') -Kind Error
        }
    })
    [void](New-Nano11Button -Text (Get-Nano11UiString 'Button.StartBuild') -X 530 -Y 15 -Width 210 -Height 40 -BackColor $script:Nano11GuiColors.Primary `
        -Font (New-Object System.Drawing.Font($UiFontName, 10, [System.Drawing.FontStyle]::Bold)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        # Dependency / feature-impact pre-check before starting the build
        try {
            $depCfg = Get-Nano11GuiDraftConfig -Gui $g
            $depResult = Test-Nano11Dependencies -Config $depCfg
            if ($depResult.HasIssues) {
                $depText = Format-Nano11DependencyReport -Result $depResult
                $msg = Get-Nano11UiString 'Msg.Dependency.Confirm' -Format $depText
                if (-not (Confirm-Nano11GuiAction -Message $msg -Title (Get-Nano11UiString 'Msg.Dependency.Title'))) { return }
            }
        } catch {
            Write-Verbose "Dependency check skipped: $($_.Exception.Message)"
        }
        if (Complete-Nano11GuiResult -Gui $g) {
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
    })
    $btnCancel = New-Nano11Button -Text (Get-Nano11UiString 'Button.Cancel') -X 750 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($UiFontName, 9.5)) -Parent $bottomPanel
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # Main Tab Control
    $tabControl = New-Nano11TabControl -Fill -Font (New-Object System.Drawing.Font($UiFontName, 9)) -Parent $form
    $tabControl.BringToFront()
    $Gui.Tabs = $tabControl

    # =========================================================================
    # Tabs 1-9 (one function each, above)
    # =========================================================================
    New-Nano11MediaTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings
    New-Nano11TweakTabs -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-Nano11ServicesTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-Nano11DebloatTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -UiFontName $UiFontName
    New-Nano11MigrationTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    New-Nano11UserTweaksTab -Gui $Gui -TabControl $tabControl -InitialSettings $InitialSettings -ToolTip $toolTip
    $cmbPreset = $Gui.Preset

    # =========================================================================
    # Synchronization & Presets Handling
    # =========================================================================
    $initPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $initPresetName = "$($InitialSettings.PresetKey)".Trim().ToLower()
    $initPresetIdx = [array]::IndexOf($initPresetKeys, $initPresetName)
    if ($initPresetIdx -lt 0) {
        $initPresetIdx = if ($initPresetName) { $cmbPreset.Items.Count - 1 } else { 0 }
    }
    $cmbPreset.SelectedIndex = $initPresetIdx

    $script:guiBasePresetKey = if ($initPresetIdx -lt $Gui.PresetKeyMap.Count) { $Gui.PresetKeyMap[$initPresetIdx] } else { $null }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $this.SelectedIndex -ne ($this.Items.Count - 1)) {
            Set-Nano11GuiPreset -Gui $this.FindForm().Tag -PresetIndex $this.SelectedIndex
        }
    })

    foreach ($r in @($Gui.RadWIM, $Gui.RadESD, $Gui.RadSWM)) {
        $r.Add_CheckedChanged({ Update-Nano11GuiEstimate -Gui $this.FindForm().Tag })
    }
    Update-Nano11GuiEstimate -Gui $Gui

    Disable-Nano11Mnemonic -Control $form
}

# Everything the user can have entered or chosen in the main window, to put back after the content is rebuilt
function Get-Nano11GuiState {
    param([hashtable]$Gui)
    $settings = Get-Nano11GuiDraftConfig -Gui $Gui
    $settings['SourceDrive'] = $Gui.Source.Text
    $settings['WorkDir'] = $Gui.Work.Text
    $settings['Index'] = $Gui.Index.Text
    $settings['InjectDrivers'] = $Gui.Drivers.Text
    $settings['UserName'] = $Gui.UserName.Text
    $settings['ComputerName'] = $Gui.ComputerName.Text
    $settings['UseVHDX'] = [bool]$Gui.VHDX.Checked
    $settings['ExportESDMode'] = [bool]$Gui.RadESD.Checked
    $settings['SplitWIMMode'] = [bool]$Gui.RadSWM.Checked
    $migFolders = @()
    foreach ($name in $Gui.MigFolders.CheckedItems) { $migFolders += "$name" }
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
        MigRuleIds       = @(Get-Nano11GuiMigrationRuleIds -Gui $Gui)
    }
}

# Put a state taken by Get-Nano11GuiState back into freshly built content
function Restore-Nano11GuiState {
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
        Initialize-Nano11GuiMigrationRules -List $migState.List
        $known = @($migState.List.Tag)
        for ($i = 0; $i -lt $known.Count; $i++) {
            if ($State.MigRuleIds -contains [string]$known[$i]) { $migState.List.SetItemChecked($i, $true) }
        }
    }
    Update-Nano11GuiEstimate -Gui $Gui
    if ($State.TabIndex -ge 0 -and $State.TabIndex -lt $Gui.Tabs.TabPages.Count) { $Gui.Tabs.SelectedIndex = $State.TabIndex }
}

# Show the main window in another display language. The window is built again from the current settings, so
# nothing typed or checked is lost. -Language defaults to $Gui.PendingLanguage (set by the language selector).
function Switch-Nano11GuiLanguage {
    param([hashtable]$Gui, [string]$Language)
    if (-not $Language) { $Language = "$($Gui.PendingLanguage)" }
    if ($script:Nano11UiLanguages -notcontains $Language -or $Language -eq $script:Nano11UiLanguage) { return }
    $form = $Gui.Form
    $state = Get-Nano11GuiState -Gui $Gui
    Set-Nano11UiLanguage -Language $Language
    Save-Nano11GuiLanguage -Language $Language
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
        Initialize-Nano11GuiContent -Gui $Gui -InitialSettings $state.Settings -UiFontName $Gui.UiFontName
        Restore-Nano11GuiState -Gui $Gui -State $state
    } finally {
        $form.ResumeLayout($true)
    }
}

# =========================================================================
# Main window. Returns the result hashtable (Success = $false on cancel);
# -NoShow returns the GUI context (Form, checkbox tables, ...) without showing it, for tests.
# -UiLanguage en|ja picks the display language (default: the saved choice, else the OS language).
# =========================================================================
function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{},
        [ValidateSet('en', 'ja')][string]$UiLanguage,
        [switch]$NoShow
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()
    Set-Nano11UiLanguage -Language (Resolve-Nano11UiLanguage -Requested $UiLanguage)

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    $form = New-Nano11Form -Text (Get-Nano11UiString 'Main.WindowTitle') -Width 880 -Height 820 -ClientSize `
        -NoAutoScale -Font (New-Object System.Drawing.Font($uiFontName, 9)) -StartPosition CenterScreen -FixedDialog -NoMaximize `
        -BackColor $script:Nano11GuiColors.Window -ForeColor $script:Nano11GuiColors.Text

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

    Initialize-Nano11GuiContent -Gui $gui -InitialSettings $InitialSettings -UiFontName $uiFontName

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

# The WinUI 3 window host (Show-Nano11WinUiGUI) shares the helpers above
. (Join-Path -Path $PSScriptRoot -ChildPath 'Nano11WinUiHost.ps1')
