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

function New-Nano11TextBox {
    param(
        [int]$X, [int]$Y, [int]$Width, [int]$Height = 24,
        [string]$Text,
        [object]$Parent
    )
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point($X, $Y)
    $txt.Size = New-Object System.Drawing.Size($Width, $Height)
    $txt.BackColor = $script:Nano11GuiColors.Input
    $txt.ForeColor = [System.Drawing.Color]::White
    if ($Text) { $txt.Text = $Text }
    if ($Parent) { $Parent.Controls.Add($txt) }
    return $txt
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

# CheckedListBox filled with -Items, pre-checking those in -Selected; docked (-Fill) or placed
function New-Nano11CheckedList {
    param(
        [string[]]$Items = @(),
        [object[]]$Selected = @(),
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
    foreach ($item in $Items) { [void]$clb.Items.Add($item, ($Selected -contains $item)) }
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
        [void](New-Nano11Label -Text $Caption -X 230 -Y 11 -Width 400 -Height 20 -ForeColor ($script:Nano11GuiColors.Accent) -Parent $bar)
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
        [string]$Title = "nano11",
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info'
    )
    $icon = switch ($Kind) {
        'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
        'Error'   { [System.Windows.Forms.MessageBoxIcon]::Error }
        default   { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Confirm-Nano11GuiAction {
    param([string]$Message, [string]$Title = "Confirm")
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
        [string]$SelectText = "Select All",
        [string]$ClearText = "Clear All",
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

# Collect checked items of a CheckedListBox
function Get-Nano11CheckedItems {
    param([System.Windows.Forms.CheckedListBox]$List)
    $sel = @()
    for ($i = 0; $i -lt $List.Items.Count; $i++) { if ($List.GetItemChecked($i)) { $sel += $List.Items[$i] } }
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

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Advanced Debloat Options (Standard + Experimental)"
    $dlg.Size = New-Object System.Drawing.Size(700, 620)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $dlgBack

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(10, 10)
    $tabControl.Size = New-Object System.Drawing.Size(665, 480)
    $dlg.Controls.Add($tabControl)

    # Standard tab
    $tabStd = New-Nano11TabPage -Text "Standard (Safe - DISM/PS)" -TabControl $tabControl -BackColor $dlgBack
    $preStd = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    $clbStd = New-Nano11CheckedList -Items $stdItems -Selected $preStd -X 10 -Y 10 -Width 640 -Height 380 -Font $listFont -Parent $tabStd
    [void](Add-Nano11SelectButtons -Parent $tabStd -Target $clbStd -X 10 -Y 395 -Width 100 -Height 28 -ClearText "Deselect All" -ForeColor $dlgFore)

    # Experimental tab
    $tabExp = New-Nano11TabPage -Text "Experimental (Physical Deletion)" -TabControl $tabControl -BackColor $dlgBack
    [void](New-Nano11Label -Text "WARNING: Physical deletion permanently breaks Windows Update and sfc." -X 10 -Y 5 -Width 640 -Height 20 `
        -ForeColor ($script:Nano11GuiColors.Danger) -Font (New-Object System.Drawing.Font($UiFontName, 9, [System.Drawing.FontStyle]::Bold)) -Parent $tabExp)
    $preExp = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }
    $clbExp = New-Nano11CheckedList -Items $expItems -Selected $preExp -X 10 -Y 30 -Width 640 -Height 365 -Font $listFont -Parent $tabExp
    [void](Add-Nano11SelectButtons -Parent $tabExp -Target $clbExp -X 10 -Y 400 -Width 100 -Height 28 -ClearText "Deselect All" -ForeColor $dlgFore)

    # Both lists travel on the dialog's Tag for the Preview / OK handlers
    $dlg.Tag = @{ Std = $clbStd; Exp = $clbExp }

    [void](New-Nano11Button -Text "Preview" -X 10 -Y 500 -Width 100 -Height 30 -ForeColor $dlgFore -Parent $dlg -OnClick {
        $t = $this.FindForm().Tag
        $stdSel = Get-Nano11CheckedItems -List $t.Std
        $expSel = Get-Nano11CheckedItems -List $t.Exp
        $msg = "Selected: Standard=$($stdSel.Count) / Experimental=$($expSel.Count)`n`n"
        $msg += "Standard ($($stdSel.Count) items)`n"
        foreach ($s in $stdSel) { $msg += "  - $s`n" }
        $msg += "`nExperimental ($($expSel.Count) items)`n"
        foreach ($s in $expSel) { $msg += "  - $s`n" }
        if ($expSel.Count -gt 0) {
            $msg += "`nExperimental enabled: Windows Update will be broken"
        }
        Show-Nano11GuiMessage -Text $msg -Title "Deletion Preview" -Kind Info
    })

    # OK / Cancel
    [void](New-Nano11Button -Text "OK" -X 480 -Y 500 -Width 90 -Height 30 -BackColor ($script:Nano11GuiColors.Primary) -Parent $dlg -OnClick {
        $f = $this.FindForm()
        $script:advDebloatStd = Get-Nano11CheckedItems -List $f.Tag.Std
        $script:advDebloatExp = Get-Nano11CheckedItems -List $f.Tag.Exp
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })
    [void](New-Nano11Button -Text "Cancel" -X 575 -Y 500 -Width 90 -Height 30 -ForeColor $dlgFore -Parent $dlg -OnClick {
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
    foreach ($srcItem in $detectedSources) { [void]$Combo.Items.Add($srcItem) }
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
        $Gui.Estimate.Text = ("Estimated ISO Size: ~{0} GB (LZX baseline)" -f [math]::Round($mb / 1024, 2))
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
        if ($name -eq $script:Nano11GuiCurrentSettingsLabel) { $resolved += , (Get-Nano11GuiDraftConfig -Gui $Gui) } else { $resolved += , $name }
    }
    $diff = Compare-Nano11Config -ReferenceConfig $resolved[0] -DifferenceConfig $resolved[1]
    return (Format-Nano11ConfigDiff -DiffResult $diff)
}

# Read-only, scrollable text dialog (MessageBox truncates long results)
function Show-Nano11GuiTextDialog {
    param([string]$Title, [string]$Text, [System.Windows.Forms.IWin32Window]$Owner)
    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = $Title
        $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dlg.ClientSize = New-Object System.Drawing.Size(720, 520)
        $dlg.BackColor = $script:Nano11GuiColors.Dialog
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true
        $txt.ReadOnly = $true
        $txt.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $txt.WordWrap = $false
        $txt.Font = New-Object System.Drawing.Font('Consolas', 9)
        $txt.Dock = [System.Windows.Forms.DockStyle]::Fill
        $txt.BackColor = $script:Nano11GuiColors.Input
        $txt.ForeColor = [System.Drawing.Color]::White
        $txt.Text = ($Text -replace "(?<!`r)`n", "`r`n")
        $dlg.Controls.Add($txt)
        [void]$txt.Select(0, 0)
        if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    } finally { $dlg.Dispose() }
}

# "Preset Diff" picker: choose a base (presets or current window) and a target, then show the diff
function Show-Nano11GuiPresetDiff {
    param([hashtable]$Gui)
    $names = @($script:Nano11GuiCurrentSettingsLabel)
    if ($script:BuiltInPresets) { $names += @($script:BuiltInPresets.Keys) }
    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = "Preset Diff"
        $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.ClientSize = New-Object System.Drawing.Size(400, 160)
        $dlg.BackColor = $script:Nano11GuiColors.Dialog
        $dlg.ForeColor = [System.Drawing.Color]::White
        $combos = @{}
        $rows = @(@('From', 'Compare from:', 20, 0), @('To', 'Compare to:', 55, [Math]::Min(1, $names.Count - 1)))
        foreach ($r in $rows) {
            [void](New-Nano11Label -Text $r[1] -X 15 -Y ($r[2] + 3) -Width 100 -Height 20 -Parent $dlg)
            $cmb = New-Object System.Windows.Forms.ComboBox
            $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $cmb.Location = New-Object System.Drawing.Point(120, $r[2])
            $cmb.Size = New-Object System.Drawing.Size(260, 24)
            [void]$cmb.Items.AddRange($names)
            $cmb.SelectedIndex = $r[3]
            $dlg.Controls.Add($cmb)
            $combos[$r[0]] = $cmb
        }
        $dlg.Tag = @{ Gui = $Gui; From = $combos['From']; To = $combos['To'] }
        [void](New-Nano11Button -Text "Compare" -X 120 -Y 105 -Width 120 -Height 32 -Parent $dlg -OnClick {
            $f = $this.FindForm()
            $t = $f.Tag
            try {
                $txt = Get-Nano11GuiPresetDiffText -Gui $t.Gui -From ([string]$t.From.SelectedItem) -To ([string]$t.To.SelectedItem)
                Show-Nano11GuiTextDialog -Title "Preset Diff: $($t.From.SelectedItem) -> $($t.To.SelectedItem)" -Text $txt -Owner $f
            } catch {
                Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Preset Diff" -Kind Error
            }
        })
        $btnClose = New-Nano11Button -Text "Close" -X 260 -Y 105 -Width 120 -Height 32 -Parent $dlg
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
    if ($Gui.ClbStd) { foreach ($item in $Gui.ClbStd.CheckedItems) { $stdSelected += "$item" } }
    $expSelected = @()
    if ($Gui.ClbExp) { foreach ($item in $Gui.ClbExp.CheckedItems) { $expSelected += "$item" } }
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
    if (-not $root) { $root = Join-Path $env:USERPROFILE 'nano11_migration_backup' }
    return $root
}

# Checked personal folders -> @{ Category = real path } (only folders that exist)
function Get-Nano11GuiMigrationFolderMap {
    param([hashtable]$Gui)
    $map = @{}
    if (-not $Gui.MigFolders) { return $map }
    foreach ($name in $Gui.MigFolders.CheckedItems) {
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
        [void]$List.Items.Add("No migration rules found")
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
    param([string]$RepoRoot, [string]$Script, [hashtable]$Arguments = @{})
    $job = Start-Job -ScriptBlock {
        param($repoRoot, $inner, $jobArgs)
        Set-Location -LiteralPath $repoRoot
        . (Join-Path $repoRoot 'tools\migrator\Nano11Migration.ps1')
        & ([scriptblock]::Create($inner)) $jobArgs
    } -ArgumentList $RepoRoot, $Script, $Arguments
    while ($job.State -eq 'Running') {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $result = $null
    $jobError = $null
    $errors = @()
    if ($job.State -eq 'Failed') {
        $jobError = $job.ChildJobs[0].JobStateInfo.Reason.Message
    } else {
        foreach ($e in $job.ChildJobs[0].Error) { $errors += "$e" }
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($result -is [array]) { $result = $result[-1] }
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ Result = $result; Error = $jobError; Errors = $errors }
}

# Job outcome -> message box (errors from the error stream are appended to a successful message)
function Show-Nano11GuiJobOutcome {
    param($Outcome, [string]$Title, [string]$SuccessMessage)
    $kind = 'Info'
    if ($Outcome.Error) {
        $msg = "Error: $($Outcome.Error)"
        $kind = 'Error'
    } else {
        $msg = $SuccessMessage
        if (@($Outcome.Errors).Count -gt 0) {
            $msg += "`n`nErrors reported:`n" + (@($Outcome.Errors) -join "`n")
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

function Complete-Nano11GuiResult {
    param([hashtable]$Gui)
    $srcText = $Gui.Source.Text.Trim()
    if (-not $srcText) {
        Show-Nano11GuiMessage -Text "Please specify Windows 11 installation media or ISO image." -Title "Source Required" -Kind Warning
        return $false
    }

    if ($srcText -match '^([A-Za-z]:)') {
        $candLetter = $matches[1]
        $wimCheck = Join-Path -Path "$candLetter\sources" -ChildPath "install.wim"
        if (Test-Path -LiteralPath $wimCheck) {
            $resolvedSource = $candLetter
        } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
            $resolvedSource = $srcText
        } else {
            $resolvedSource = $candLetter
        }
    } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
        $resolvedSource = $srcText
    } else {
        $resolvedSource = $srcText
    }

    $wDir = $Gui.Work.Text.Trim()
    if (-not $wDir) {
        $docsDir = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
        $wDir = Join-Path -Path $docsDir -ChildPath "nano11_workspace"
    }

    $guiUserName = $Gui.UserName.Text.Trim()
    $guiComputerName = $Gui.ComputerName.Text.Trim()
    if (-not $guiComputerName) { $guiComputerName = '*' }
    if ($guiUserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') {
        Show-Nano11GuiMessage -Text "Username must contain only letters, digits, spaces, '.', '_', or '-' (max 20 chars)." -Title "Invalid Username" -Kind Warning
        return $false
    }
    if ($guiComputerName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') {
        Show-Nano11GuiMessage -Text "ComputerName must be '*' or up to 15 alphanumeric characters and hyphens." -Title "Invalid ComputerName" -Kind Warning
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
    foreach ($item in $Gui.ClbStd.CheckedItems) { $stdSelected += "$item" }
    $expSelected = @()
    foreach ($item in $Gui.ClbExp.CheckedItems) { $expSelected += "$item" }
    $formResult.AdvancedDebloatStandard     = $stdSelected
    $formResult.AdvancedDebloatExperimental = $expSelected

    return $true
}

# =========================================================================
# Main window. Returns the result hashtable (Success = $false on cancel);
# -NoShow returns the GUI context (Form, checkbox tables, ...) without showing it, for tests.
# =========================================================================
function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{},
        [switch]$NoShow
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "nano11 Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer"
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $form.ClientSize = New-Object System.Drawing.Size(880, 820)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.BackColor = $script:Nano11GuiColors.Window
    $form.ForeColor = $script:Nano11GuiColors.Text

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
    }
    $form.Tag = $gui
    $script:updatingPreset = $false

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $accent = $script:Nano11GuiColors.Accent
    $headerBack = $script:Nano11GuiColors.Header

    # Header Panel
    $headerPanel = New-Nano11ButtonBar -Parent $form -Height 65 -BackColor $headerBack
    [void](New-Nano11Label -Text "nano11 Builder v2.1" -X 16 -Y 10 -AutoSize -ForeColor $accent `
        -Font (New-Object System.Drawing.Font($uiFontName, 14, [System.Drawing.FontStyle]::Bold)) -Parent $headerPanel)
    [void](New-Nano11Label -Text "Universal, Language-Independent Windows 11 Modular Reducer & Full-Toggle Optimizer" -X 18 -Y 38 -AutoSize `
        -ForeColor ($script:Nano11GuiColors.Subtle) -Font (New-Object System.Drawing.Font($uiFontName, 8.5)) -Parent $headerPanel)

    # Bottom Button & Estimate Panel
    $bottomPanel = New-Nano11ButtonBar -Parent $form -Dock Bottom -Height 70 -BackColor $headerBack
    $gui.DryRun = New-Nano11CheckBox -Text "DryRun (Simulation Mode)" -X 20 -Y 12 -Width 200 -Height 22 -Parent $bottomPanel
    $gui.Estimate = New-Nano11Label -Text "Estimated ISO: ~5.5 GB (LZX baseline)" -X 20 -Y 38 -Width 380 -Height 20 `
        -ForeColor ($script:Nano11GuiColors.Muted) -Font (New-Object System.Drawing.Font($uiFontName, 9)) -Parent $bottomPanel

    [void](New-Nano11Button -Text "Preset Diff" -X 250 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($uiFontName, 9)) -Parent $bottomPanel -OnClick {
        $g = $this.FindForm().Tag
        try {
            Show-Nano11GuiPresetDiff -Gui $g
        } catch {
            Show-Nano11GuiMessage -Text "Preset Diff failed: $($_.Exception.Message)" -Title "nano11 - Preset Diff" -Kind Error
        }
    })
    [void](New-Nano11Button -Text "Check Dependencies" -X 370 -Y 15 -Width 150 -Height 40 -Font (New-Object System.Drawing.Font($uiFontName, 9)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        try {
            $cfg = Get-Nano11GuiDraftConfig -Gui $g
            $res = Test-Nano11Dependencies -Config $cfg
            $txt = Format-Nano11DependencyReport -Result $res
            if (-not $txt) { $txt = "No conflicts, unknowns or impacts detected." }
            Show-Nano11GuiMessage -Text $txt -Title "nano11 - Dependency Check" -Kind Info
        } catch {
            Show-Nano11GuiMessage -Text "Dependency check failed: $($_.Exception.Message)" -Title "nano11 - Dependency Check" -Kind Error
        }
    })
    [void](New-Nano11Button -Text "Start nano11 Build" -X 530 -Y 15 -Width 210 -Height 40 -BackColor ($script:Nano11GuiColors.Primary) `
        -Font (New-Object System.Drawing.Font($uiFontName, 10, [System.Drawing.FontStyle]::Bold)) -Parent $bottomPanel -OnClick {
        $f = $this.FindForm()
        $g = $f.Tag
        # Dependency / feature-impact pre-check before starting the build
        try {
            $depCfg = Get-Nano11GuiDraftConfig -Gui $g
            $depResult = Test-Nano11Dependencies -Config $depCfg
            if ($depResult.HasIssues) {
                $depText = Format-Nano11DependencyReport -Result $depResult
                $msg = "Dependency / feature-impact issues detected:`n`n$depText`n`nContinue with build anyway?"
                if (-not (Confirm-Nano11GuiAction -Message $msg -Title "nano11 - Dependency Check")) { return }
            }
        } catch {
            Write-Verbose "Dependency check skipped: $($_.Exception.Message)"
        }
        if (Complete-Nano11GuiResult -Gui $g) {
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
    })
    $btnCancel = New-Nano11Button -Text "Cancel" -X 750 -Y 15 -Width 110 -Height 40 -Font (New-Object System.Drawing.Font($uiFontName, 9.5)) -Parent $bottomPanel
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # Main Tab Control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $form.Controls.Add($tabControl)
    $tabControl.BringToFront()

    # =========================================================================
    # TAB 1: Media & Workspace & Preset
    # =========================================================================
    $tabMedia = New-Nano11TabPage -Text " 1. Media & Output " -TabControl $tabControl

    $grpMedia = New-Nano11GroupBox -Text " Source Media & Paths " -X 15 -Y 10 -Width 835 -Height 185 -Parent $tabMedia

    [void](New-Nano11Label -Text "Source Drive / ISO:" -X 15 -Y 28 -Width 130 -Height 20 -Parent $grpMedia)
    $cmbSource = New-Object System.Windows.Forms.ComboBox
    $cmbSource.Location = New-Object System.Drawing.Point(150, 25)
    $cmbSource.Size = New-Object System.Drawing.Size(370, 24)
    $cmbSource.BackColor = $script:Nano11GuiColors.Input
    $cmbSource.ForeColor = [System.Drawing.Color]::White
    $grpMedia.Controls.Add($cmbSource)
    $gui.Source = $cmbSource

    Update-Nano11GuiSources -Combo $cmbSource

    if ($InitialSettings.SourceDrive) { $cmbSource.Text = $InitialSettings.SourceDrive }
    elseif ($cmbSource.Items.Count -gt 0) { $cmbSource.SelectedIndex = 0 }
    else { $cmbSource.Text = "E:\" }

    # Browse / rescan buttons carry the control they fill on their Tag
    [void](New-Nano11Button -Text "Browse Drive..." -X 530 -Y 24 -Width 110 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select Windows 11 installation media or mounted virtual DVD drive"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $this.Tag.Text = $p
        }
    })
    [void](New-Nano11Button -Text "Browse ISO..." -X 645 -Y 24 -Width 100 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Windows 11 ISO (*.iso)|*.iso|All Files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $ofd.FileName }
    })
    [void](New-Nano11Button -Text "Rescan" -X 750 -Y 24 -Width 70 -Height 26 -Tag $cmbSource -Parent $grpMedia -OnClick {
        Update-Nano11GuiSources -Combo $this.Tag
    })

    $browseFolder = {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $this.Tag.Text = $fbd.SelectedPath }
    }

    # WorkDir
    [void](New-Nano11Label -Text "Workspace Dir:" -X 15 -Y 60 -Width 130 -Height 20 -Parent $grpMedia)
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    $workText = if ($InitialSettings.WorkDir) { $InitialSettings.WorkDir } else { Join-Path -Path $docsDir -ChildPath "nano11_workspace" }
    $gui.Work = New-Nano11TextBox -X 150 -Y 57 -Width 535 -Text $workText -Parent $grpMedia
    [void](New-Nano11Button -Text "Browse Folder..." -X 695 -Y 56 -Width 125 -Height 26 -Tag $gui.Work -OnClick $browseFolder -Parent $grpMedia)

    # Index & Drivers
    [void](New-Nano11Label -Text "Image Index:" -X 15 -Y 95 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.Index = New-Nano11TextBox -X 150 -Y 92 -Width 70 -Text $(if ($InitialSettings.Index) { "$($InitialSettings.Index)" }) -Parent $grpMedia
    [void](New-Nano11Label -Text 'Inject Drivers ($OEM$):' -X 235 -Y 95 -Width 140 -Height 20 -Parent $grpMedia)
    $gui.Drivers = New-Nano11TextBox -X 380 -Y 92 -Width 305 -Text $(if ($InitialSettings.InjectDrivers) { "$($InitialSettings.InjectDrivers)" }) -Parent $grpMedia
    [void](New-Nano11Button -Text "Browse..." -X 695 -Y 91 -Width 125 -Height 26 -Tag $gui.Drivers -OnClick $browseFolder -Parent $grpMedia)

    # User & Computer
    [void](New-Nano11Label -Text "Local Username:" -X 15 -Y 130 -Width 130 -Height 20 -Parent $grpMedia)
    $gui.UserName = New-Nano11TextBox -X 150 -Y 127 -Width 160 -Text $(if ($InitialSettings.UserName) { "$($InitialSettings.UserName)" } else { "User" }) -Parent $grpMedia
    [void](New-Nano11Label -Text "Computer Name:" -X 330 -Y 130 -Width 120 -Height 20 -Parent $grpMedia)
    $gui.ComputerName = New-Nano11TextBox -X 450 -Y 127 -Width 160 -Text $(if ($InitialSettings.ComputerName) { "$($InitialSettings.ComputerName)" } else { "*" }) -Parent $grpMedia

    # Preset Group
    $grpPreset = New-Nano11GroupBox -Text " Configuration Profile Preset " -X 15 -Y 205 -Width 835 -Height 75 -Parent $tabMedia

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.Location = New-Object System.Drawing.Point(15, 28)
    $cmbPreset.Size = New-Object System.Drawing.Size(805, 24)
    $cmbPreset.BackColor = $script:Nano11GuiColors.Input
    $cmbPreset.ForeColor = [System.Drawing.Color]::White
    $cmbPreset.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbPreset.Items.AddRange(@(
        "Extreme Slim & Gaming (Max debloat, minimal memory, ultra-low latency)",
        "Balanced Pro (Safe daily debloat: Windows Update & Defender preserved)",
        "FAT32 USB Split-WIM (UEFI compatible 3.8GB chunks)",
        "Handheld Gaming (ROG Ally, Steam Deck, Legion Go)",
        "VM & Developer Workstation (WSL2, Hyper-V, WinUpdate enabled)",
        "Audio & DAW Production (Low Latency, MMCSS Priority, VST Protected)",
        "Custom Configuration (Manual Tweak Switches)"
    ))
    $grpPreset.Controls.Add($cmbPreset)
    $gui.Preset = $cmbPreset

    # Payload Format Group
    $grpPayload = New-Nano11GroupBox -Text " Output Payload Format & Scratch Acceleration " -X 15 -Y 290 -Width 835 -Height 95 -Parent $tabMedia
    $gui.RadWIM = New-Nano11CheckBox -Radio -Text "install.wim (LZX - Recommended, High Compatibility)" -X 15 -Y 28 -Width 350 -Height 24 -Checked $true -Parent $grpPayload
    $gui.RadESD = New-Nano11CheckBox -Radio -Text "install.esd (LZMS - Ultra Compression)" -X 380 -Y 28 -Width 250 -Height 24 -Parent $grpPayload
    $gui.RadSWM = New-Nano11CheckBox -Radio -Text "install.swm (Split-WIM for FAT32 USB)" -X 640 -Y 28 -Width 185 -Height 24 -Parent $grpPayload

    if ($InitialSettings.ExportESDMode) { $gui.RadESD.Checked = $true }
    elseif ($InitialSettings.SplitWIMMode) { $gui.RadSWM.Checked = $true }

    $gui.VHDX = New-Nano11CheckBox -Text "Use Fast VHDX Scratch Disk (Accelerates DISM image servicing file I/O)" -X 15 -Y 60 -Width 550 -Height 24 `
        -Checked ([bool]$InitialSettings.UseVHDX) -Parent $grpPayload

    # =========================================================================
    # TABS 2-5: tweak toggles from config\tweaks.psd1, one tab per category
    # =========================================================================
    foreach ($cat in @(
        @(" 2. Security & Bypass ", "Security"),
        @(" 3. Privacy & AI ", "Privacy"),
        @(" 4. Performance ", "Performance"),
        @(" 5. UI & Shell ", "UI")
    )) {
        $category = $cat[1]
        $page = New-Nano11ToggleTab -Text $cat[0] -TabControl $tabControl -Caption "Switches: $category"
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
            $chk = New-Nano11ToggleCheckBox -Parent $page.Flow -Key $tk -Text "$tk - $($def.Description)" -ToolTip $toolTip -ToolTipText $def.Description -Checked $initVal
            $gui.TweakCheckboxes[$tk] = $chk
            $tabCheckboxes.Add($chk)
        }
        [void](Add-Nano11SelectButtons -Parent $page.Bar -Target $tabCheckboxes -X 15 -Y 7)
    }

    # =========================================================================
    # TAB 6: Components & Services
    # =========================================================================
    $page = New-Nano11ToggleTab -Text " 6. Services & Apps " -TabControl $tabControl

    # Components with a Gui entry in config\tweaks.psd1, in their Gui.Order
    $svcDefs = @($script:ComponentDefs.Values | Where-Object { $_.Gui -and $_.Gui.Tab -ne 'Migration' } | Sort-Object { [int]$_.Gui.Order } | ForEach-Object {
        @{ Key = $_.Key; Text = $_.Gui.Text; Desc = $_.Gui.Description; Def = [bool]$_.Gui.Default }
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

    # =========================================================================
    # TAB 7: Advanced Debloat (Physical Deletion)
    # =========================================================================
    # Populate standard and experimental debloat lists
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
        "Physical: Minidump (complete removal) [varies]"
    )

    $preStd = @()
    if ($InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    $preExp = @()
    if ($InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }

    $tabDebloat = New-Nano11TabPage -Text " 7. Advanced Debloat " -TabControl $tabControl
    $barDeb = New-Nano11ButtonBar -Parent $tabDebloat
    [void](New-Nano11Label -Text "Notice: Standard uses CBS safe operations. Experimental physically deletes files." -X 15 -Y 11 -Width 650 -Height 20 `
        -ForeColor ($script:Nano11GuiColors.Warn) -Font (New-Object System.Drawing.Font($uiFontName, 8.5)) -Parent $barDeb)
    $flowDeb = New-Nano11FlowPanel -Parent $tabDebloat

    # Standard Debloat group
    $grpStdDeb = New-Nano11GroupBox -Text " Standard Debloat (Safe Component Pruning) " -Width 410 -Height 480 -Parent $flowDeb
    $gui.ClbStd = New-Nano11CheckedList -Items $stdItems -Selected $preStd -Fill -Parent $grpStdDeb

    # Experimental Debloat group
    $grpExpDeb = New-Nano11GroupBox -Text " Experimental Physical Debloat (Destructive / Breaks WU) " -Width 410 -Height 480 `
        -ForeColor ($script:Nano11GuiColors.Danger) -Parent $flowDeb
    $gui.ClbExp = New-Nano11CheckedList -Items $expItems -Selected $preExp -Fill -Parent $grpExpDeb

    # Select All / Clear All bar at the bottom of each debloat group
    foreach ($pair in @(@($grpStdDeb, $gui.ClbStd, $null), @($grpExpDeb, $gui.ClbExp, "Select ALL experimental physical deletions?`nThis permanently breaks Windows Update and sfc."))) {
        $barList = New-Nano11ButtonBar -Parent $pair[0] -Dock Bottom -Height 34 -BackColor $null
        $pair[1].BringToFront()
        [void](Add-Nano11SelectButtons -Parent $barList -Target $pair[1] -X 5 -Y 4 -Step 100 -ConfirmSelect $pair[2])
    }

    # =========================================================================
    # Tab 8: Migration & Backup
    # =========================================================================
    $tabMigration = New-Nano11TabPage -Text " 8. Migration & Backup " -TabControl $tabControl
    $flowMig = New-Nano11FlowPanel -Parent $tabMigration

    # Top card: Post-Install Migration Assistant (a component switch from config\tweaks.psd1, Gui.Tab = 'Migration')
    $grpAssist = New-Nano11GroupBox -Text " Post-Install Migration Assistant " -Width 840 -Height 60 -Parent $flowMig
    $asDef = $script:ComponentDefs['IncludeMigrationAssistant']
    if ($asDef -and $asDef.Gui) {
        $asInit = [bool]$asDef.Gui.Default
        if ($InitialSettings.ContainsKey('IncludeMigrationAssistant')) { $asInit = [bool]$InitialSettings['IncludeMigrationAssistant'] }
        $chkAssist = New-Nano11ToggleCheckBox -Parent $grpAssist -Key 'IncludeMigrationAssistant' -Text "IncludeMigrationAssistant - $($asDef.Gui.Text)" -ToolTip $toolTip -ToolTipText $asDef.Gui.Description -Checked $asInit
        $chkAssist.Location = New-Object System.Drawing.Point(15, 24)
        $chkAssist.Size = New-Object System.Drawing.Size(800, 28)
        $gui.ComponentCheckboxes['IncludeMigrationAssistant'] = $chkAssist
    }

    # Backup settings: destination, credential handling, conflict policy
    $grpTop = New-Nano11GroupBox -Text " Backup Settings " -Width 840 -Height 110 -Parent $flowMig
    [void](New-Nano11Label -Text "Backup Root:" -X 15 -Y 22 -Width 90 -Height 20 -Parent $grpTop)
    $txtMigRoot = New-Nano11TextBox -X 110 -Y 20 -Width 420 -Height 24 -Text (Join-Path $env:USERPROFILE "nano11_migration_backup") -Parent $grpTop
    $gui.MigRoot = $txtMigRoot
    [void](New-Nano11Button -Text "Browse..." -X 540 -Y 19 -Width 90 -Height 26 -Parent $grpTop -OnClick {
        $g = $this.FindForm().Tag
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dlg.Description = "Select the migration backup destination"
            if ($g.MigRoot.Text -and (Test-Path -LiteralPath $g.MigRoot.Text)) { $dlg.SelectedPath = $g.MigRoot.Text }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $g.MigRoot.Text = $dlg.SelectedPath }
        } finally { $dlg.Dispose() }
    })
    $lblMigStatus = New-Nano11Label -Text "Select folders and rules, then click Backup or Restore." -X 640 -Y 22 -Width 190 -Height 40 -Parent $grpTop
    $gui.MigStatus = $lblMigStatus
    $gui.MigExcludeSecrets = New-Nano11CheckBox -Text "Exclude credentials/tokens (Recommended)" -X 15 -Y 52 -Width 320 -Height 24 -Checked $true -Parent $grpTop
    [void](New-Nano11Label -Text "If a file already exists on restore:" -X 15 -Y 80 -Width 220 -Height 20 -Parent $grpTop)
    $cmbConflict = New-Object System.Windows.Forms.ComboBox
    $cmbConflict.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbConflict.Location = New-Object System.Drawing.Point(240, 78)
    $cmbConflict.Size = New-Object System.Drawing.Size(200, 24)
    [void]$cmbConflict.Items.AddRange(@('BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite'))
    $cmbConflict.SelectedIndex = 0
    $grpTop.Controls.Add($cmbConflict)
    $gui.MigConflict = $cmbConflict

    # Left: personal data folders + migration rules
    $grpRules = New-Nano11GroupBox -Text " Personal Folders & Migration Rules " -Width 410 -Height 420 -Parent $flowMig
    $folderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads')
    $gui.MigFolders = New-Nano11CheckedList -Items $folderNames -Selected @('Documents', 'Desktop', 'Pictures') -X 10 -Y 20 -Width 390 -Height 100 -Parent $grpRules
    [void](New-Nano11Label -Text "Migration rules (games / app settings):" -X 10 -Y 126 -Width 390 -Height 18 -Parent $grpRules)
    $clbMig = New-Nano11CheckedList -Items @() -X 10 -Y 146 -Width 390 -Height 264 -Parent $grpRules
    # Rules are filled in the first time this tab is opened (the migration engine is not loaded before that)
    $clbMig.Tag = @()
    $tabMigration.Tag = @{ Loaded = $false; List = $clbMig }
    $tabMigration.Add_Enter({
        $st = $this.Tag
        if ($st.Loaded) { return }
        $st.Loaded = $true
        Initialize-Nano11GuiMigrationRules -List $st.List
    })
    $gui.MigRulesList = $clbMig

    # Right: Action buttons
    $grpActions = New-Nano11GroupBox -Text " Actions " -Width 410 -Height 420 -Parent $flowMig
    $btnY = 22
    $btnStep = 38
    [void](New-Nano11Button -Text "Recovery Readiness Check" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        try {
            $rr = Get-Nano11GuiRecoveryReadiness -Gui $g
            $msg = "Readiness Score: $($rr.ReadinessScore)`nSecondary Drives: $($rr.SecondaryDrives -join ', ')`nSystem Restore: $($rr.SystemRestoreEnabled)`nWinRE on target: $($rr.WinReEnabledOnTarget)`n`n$($rr.Recommendations -join "`n")"
            Show-Nano11GuiMessage -Text $msg -Title "Recovery Readiness" -Kind Info
        } catch {
            Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Recovery Readiness" -Kind Error
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text "Export App Inventory" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $dlg.Title = "Export App Inventory"
            $dlg.Filter = "JSON (*.json)|*.json|All files (*.*)|*.*"
            $dlg.FileName = "apps-inventory.json"
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $outPath = $dlg.FileName
        } finally { $dlg.Dispose() }
        $btn.Enabled = $false
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $script:Nano11GuiRepoRoot -Script 'param($a) Export-Nano11AppInventory -OutputPath $a.OutputPath' -Arguments @{ OutputPath = $outPath }
            Show-Nano11GuiJobOutcome -Outcome $o -Title "Export Apps" -SuccessMessage "App inventory exported to:`n$outPath"
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text "Open Migration Wizard" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $g = $this.FindForm().Tag
        $repoRoot = $script:Nano11GuiRepoRoot
        $migratorPath = Join-Path $repoRoot "tools\migrator\Nano11-Migrator.ps1"
        if (Test-Path -LiteralPath $migratorPath) {
            try {
                $root = Get-Nano11GuiMigrationRoot -Gui $g
                # -BackupRoot exists in every Nano11-Migrator.ps1 version (it is a -PackagePath alias after S6)
                Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$migratorPath`" -GUI -BackupRoot `"$root`"" -WindowStyle Normal
            } catch {
                Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Migration Wizard" -Kind Error
            }
        } else {
            Show-Nano11GuiMessage -Text "Nano11-Migrator.ps1 not found." -Title "Migration Wizard" -Kind Warning
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text "Estimate Size" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $btn.Enabled = $false
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $map = Get-Nano11GuiMigrationFolderMap -Gui $g
            $ea = @{ UserFolderPaths = @($map.Values); SelectedRuleIds = @(Get-Nano11GuiMigrationRuleIds -Gui $g); DestinationPath = (Get-Nano11GuiMigrationRoot -Gui $g) }
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $script:Nano11GuiRepoRoot -Arguments $ea -Script 'param($a) Get-Nano11MigrationSizeEstimate -UserFolderPaths $a.UserFolderPaths -SelectedRuleIds $a.SelectedRuleIds -DestinationPath $a.DestinationPath'
            $est = $o.Result
            $msg = if ($est) { "Files: $($est.TotalFiles)`nSize: $($est.TotalMB) MB`nFree on $($est.DestinationDrive): $($est.DestinationFreeMB) MB`nEnough space: $($est.HasEnoughSpace)" } else { "No estimate returned." }
            Show-Nano11GuiJobOutcome -Outcome $o -Title "Estimate Size" -SuccessMessage $msg
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text "Run Backup" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $btn.Enabled = $false
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $backupArgs = Get-Nano11GuiBackupArgs -Gui $g
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $script:Nano11GuiRepoRoot -Arguments $backupArgs -Script 'param($a) Start-Nano11MigrationBackup @a'
            Show-Nano11GuiJobOutcome -Outcome $o -Title "Backup" -SuccessMessage "Backup completed.`nManifest: $($backupArgs.BackupRoot)\migration-manifest.json"
            if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = "Backup completed." }
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $btnY += $btnStep
    [void](New-Nano11Button -Text "Verify Backup Integrity" -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -OnClick {
        $btn = $this
        $f = $btn.FindForm()
        $g = $f.Tag
        $btn.Enabled = $false
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $script = (Get-Command Test-Nano11GuiBackupIntegrity).ScriptBlock.ToString()
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $script:Nano11GuiRepoRoot -Arguments @{ BackupRoot = (Get-Nano11GuiMigrationRoot -Gui $g) } -Script $script
            $vr = $o.Result
            if ($vr -and @($vr.Problems).Count -gt 0) {
                $o.Errors = @($o.Errors) + @($vr.Problems)
                $msg = "Checked $($vr.Checked) file(s): $(@($vr.Problems).Count) problem(s)."
            } elseif ($vr) { $msg = "Checked $($vr.Checked) file(s): all present and matching." } else { $msg = "No result." }
            Show-Nano11GuiJobOutcome -Outcome $o -Title "Verify Backup" -SuccessMessage $msg
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $btnY += $btnStep
    foreach ($rs in @(@("Run Restore", $false), @("Retry Failed Tasks Only", $true))) {
        [void](New-Nano11Button -Text $rs[0] -X 15 -Y $btnY -Width 380 -Height 32 -Parent $grpActions -Tag $rs[1] -OnClick {
            $btn = $this
            $retry = [bool]$btn.Tag
            $f = $btn.FindForm()
            $g = $f.Tag
            $btn.Enabled = $false
            $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $ra = @{ BackupRoot = (Get-Nano11GuiMigrationRoot -Gui $g); ConflictPolicy = (Get-Nano11GuiConflictPolicy -Gui $g) }
                if ($retry) { $ra['RetryFailedOnly'] = $true }
                $o = Invoke-Nano11GuiMigrationJob -RepoRoot $script:Nano11GuiRepoRoot -Arguments $ra -Script 'param($a) Start-Nano11MigrationRestore @a'
                $msg = "Restore completed."
                if ($o.Result -and $o.Result.Results) { $msg += "`n" + ($o.Result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String) }
                Show-Nano11GuiJobOutcome -Outcome $o -Title "Restore" -SuccessMessage $msg
                if ($g.MigStatus -and -not $o.Error) { $g.MigStatus.Text = "Restore completed." }
            } finally {
                $btn.Enabled = $true
                $f.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        })
        $btnY += $btnStep
    }

    # Custom paths backup/restore section
    $grpCustom = New-Nano11GroupBox -Text " Custom File/Folder Backup (arbitrary paths) " -Width 840 -Height 140 -Parent $flowMig
    [void](New-Nano11Label -Text "Paths (one per line):" -X 15 -Y 20 -Width 140 -Height 20 -Parent $grpCustom)
    $txtCustomPaths = New-Object System.Windows.Forms.TextBox
    $txtCustomPaths.Location = New-Object System.Drawing.Point(15, 42)
    $txtCustomPaths.Size = New-Object System.Drawing.Size(560, 60)
    $txtCustomPaths.Multiline = $true
    $txtCustomPaths.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtCustomPaths.BackColor = $script:Nano11GuiColors.Input
    $txtCustomPaths.ForeColor = $script:Nano11GuiColors.Text
    $grpCustom.Controls.Add($txtCustomPaths)
    $gui.CustomPaths = $txtCustomPaths

    [void](New-Nano11Button -Text "Backup Custom Paths" -X 590 -Y 42 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $btn = $this
        $btn.Enabled = $false
        $f = $btn.FindForm()
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        $g = $f.Tag
        try {
            $root = $g.MigRoot.Text.Trim()
            if (-not $root) { $root = Join-Path $env:USERPROFILE "nano11_migration_backup" }
            $paths = @($g.CustomPaths.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($paths.Count -eq 0) { throw "No paths specified." }
            $result = Backup-Nano11CustomPaths -Paths $paths -BackupRoot $root
            $msg = "Custom paths backup completed.`nCopied: $($result.CopiedFiles) files.`nFailed: $($result.FailedFiles.Count)"
            Show-Nano11GuiMessage -Text $msg -Title "Backup Custom Paths" -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = "Custom backup: $($result.CopiedFiles) files." }
        } catch {
            Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Backup Custom Paths" -Kind Error
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    [void](New-Nano11Button -Text "Restore Custom Paths" -X 590 -Y 82 -Width 160 -Height 32 -Parent $grpCustom -OnClick {
        $btn = $this
        $btn.Enabled = $false
        $f = $btn.FindForm()
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        $g = $f.Tag
        try {
            $root = $g.MigRoot.Text.Trim()
            if (-not $root) { $root = Join-Path $env:USERPROFILE "nano11_migration_backup" }
            $result = Restore-Nano11CustomPaths -BackupRoot $root -ConflictPolicy (Get-Nano11GuiConflictPolicy -Gui $g)
            $msg = "Custom paths restore completed.`nRestored: $($result.RestoredFiles) files.`nFailed: $($result.FailedFiles.Count)"
            Show-Nano11GuiMessage -Text $msg -Title "Restore Custom Paths" -Kind Info
            if ($g.MigStatus) { $g.MigStatus.Text = "Custom restore: $($result.RestoredFiles) files." }
        } catch {
            Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Restore Custom Paths" -Kind Error
        } finally {
            $btn.Enabled = $true
            $f.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # User Extensions & Custom Scripts card: what config\user\user-tweaks.psd1 loaded (set by the builder)
    $grpExt = New-Nano11GroupBox -Text " User Extensions & Custom Scripts " -Width 840 -Height 110 -Parent $flowMig
    $extRes = $script:UserExtensionsResult
    $extErrors = @()
    if ($extRes -and $extRes.Errors) { $extErrors = @($extRes.Errors | Where-Object { $_ }) }
    if ($extRes) {
        $extText = "User tweaks: $($extRes.UserTweakCount)    User presets: $($extRes.UserPresetCount)    Custom scripts: $($extRes.CustomScriptCount)"
    } else {
        $extText = "User extensions have not been loaded."
    }
    [void](New-Nano11Label -Text $extText -X 15 -Y 24 -Width 600 -Height 20 -Parent $grpExt)
    $gui.ExtensionsLabel = New-Nano11Label -Text $(if ($extErrors.Count -gt 0) { "Load errors: " + ($extErrors -join '; ') } else { "No load errors." }) `
        -X 15 -Y 48 -Width 600 -Height 52 -ForeColor $(if ($extErrors.Count -gt 0) { $script:Nano11GuiColors.Warn } else { $script:Nano11GuiColors.Muted }) -Parent $grpExt
    [void](New-Nano11Button -Text "Open Extensibility Guide" -X 630 -Y 24 -Width 190 -Height 32 -Parent $grpExt -OnClick {
        $guide = Join-Path $script:Nano11GuiRepoRoot "docs\EXTENSIBILITY_GUIDE.md"
        try {
            if (-not (Test-Path -LiteralPath $guide)) { throw "Guide not found: $guide" }
            Start-Process -FilePath $guide
        } catch {
            Show-Nano11GuiMessage -Text "Error: $($_.Exception.Message)" -Title "Extensibility Guide" -Kind Error
        }
    })
    # =========================================================================
    # TAB 9: user-defined switches whose Category has no tab above (System / Gaming / UserCustom ...)
    # =========================================================================
    $builtinTabCategories = @('Security', 'Privacy', 'Performance', 'UI')
    $pageUser = New-Nano11ToggleTab -Text " 9. User Tweaks " -TabControl $tabControl -Caption "User-defined switches (config\user\user-tweaks.psd1)"
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
        $chk = New-Nano11ToggleCheckBox -Parent $pageUser.Flow -Key $tk -Text "$tk [$($def.Category)] - $($def.Description)" -ToolTip $toolTip -ToolTipText $def.Description -Checked $initVal
        $gui.TweakCheckboxes[$tk] = $chk
        $userTweakCount++
    }
    if ($userTweakCount -eq 0) {
        [void](New-Nano11Label -Text "No user-defined switches with a category outside Security / Privacy / Performance / UI." -X 0 -Y 0 -AutoSize -Parent $pageUser.Flow)
    }
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

    $script:guiBasePresetKey = if ($initPresetIdx -lt $gui.PresetKeyMap.Count) { $gui.PresetKeyMap[$initPresetIdx] } else { $null }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $this.SelectedIndex -ne ($this.Items.Count - 1)) {
            Set-Nano11GuiPreset -Gui $this.FindForm().Tag -PresetIndex $this.SelectedIndex
        }
    })

    foreach ($r in @($gui.RadWIM, $gui.RadESD, $gui.RadSWM)) {
        $r.Add_CheckedChanged({ Update-Nano11GuiEstimate -Gui $this.FindForm().Tag })
    }
    Update-Nano11GuiEstimate -Gui $gui

    Disable-Nano11Mnemonic -Control $form

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
