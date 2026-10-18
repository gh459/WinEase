# Nano11Gui.ps1 - WinForms GUI for nano11builder.ps1
# Dot-sourced by nano11builder.ps1 only when a GUI can be shown (-GUI or menu option [7]).
# Needs $script:AllTweakDefs, $script:ComponentDefs and Get-Nano11Preset from the builder.

# Repository root (this file lives in <repo>\gui)
$script:Nano11GuiRepoRoot = Split-Path -Parent $PSScriptRoot

# Helper function: Display Graphical User Interface (GUI) for nano11 builder
function Show-AdvancedDebloatDialog {
    param(
        [hashtable]$InitialSettings = @{},
        [string]$UiFontName = "Segoe UI"
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

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Advanced Debloat Options (Standard + Experimental)"
    $dlg.Size = New-Object System.Drawing.Size(700, 620)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(10, 10)
    $tabControl.Size = New-Object System.Drawing.Size(665, 480)
    $dlg.Controls.Add($tabControl)

    # Standard tab
    $tabStd = New-Object System.Windows.Forms.TabPage
    $tabStd.Text = "Standard (Safe - DISM/PS)"
    $tabStd.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    $tabControl.TabPages.Add($tabStd)

    $clbStd = New-Object System.Windows.Forms.CheckedListBox
    $clbStd.Location = New-Object System.Drawing.Point(10, 10)
    $clbStd.Size = New-Object System.Drawing.Size(640, 380)
    $clbStd.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $clbStd.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $clbStd.Font = New-Object System.Drawing.Font($UiFontName, 9)
    $clbStd.CheckOnClick = $true
    $preStd = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatStandard) { $preStd = @($InitialSettings.AdvancedDebloatStandard) }
    foreach ($item in $stdItems) {
        $chk = $preStd -contains $item
        [void]$clbStd.Items.Add($item, $chk)
    }
    $tabStd.Controls.Add($clbStd)

    $btnStdAll = New-Object System.Windows.Forms.Button
    $btnStdAll.Text = "Select All"
    $btnStdAll.Location = New-Object System.Drawing.Point(10, 395)
    $btnStdAll.Size = New-Object System.Drawing.Size(100, 28)
    $btnStdAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnStdAll.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnStdAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $tabStd.Controls.Add($btnStdAll)

    $btnStdNone = New-Object System.Windows.Forms.Button
    $btnStdNone.Text = "Deselect All"
    $btnStdNone.Location = New-Object System.Drawing.Point(115, 395)
    $btnStdNone.Size = New-Object System.Drawing.Size(100, 28)
    $btnStdNone.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnStdNone.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnStdNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $tabStd.Controls.Add($btnStdNone)

    $btnStdAll.Add_Click({ for ($i = 0; $i -lt $clbStd.Items.Count; $i++) { $clbStd.SetItemChecked($i, $true) } })
    $btnStdNone.Add_Click({ for ($i = 0; $i -lt $clbStd.Items.Count; $i++) { $clbStd.SetItemChecked($i, $false) } })

    # Experimental tab
    $tabExp = New-Object System.Windows.Forms.TabPage
    $tabExp.Text = "Experimental (Physical Deletion)"
    $tabExp.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    $tabControl.TabPages.Add($tabExp)

    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.Text = "WARNING: Physical deletion permanently breaks Windows Update and sfc."
    $lblWarn.Location = New-Object System.Drawing.Point(10, 5)
    $lblWarn.Size = New-Object System.Drawing.Size(640, 20)
    $lblWarn.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    $lblWarn.Font = New-Object System.Drawing.Font($UiFontName, 9, [System.Drawing.FontStyle]::Bold)
    $tabExp.Controls.Add($lblWarn)

    $clbExp = New-Object System.Windows.Forms.CheckedListBox
    $clbExp.Location = New-Object System.Drawing.Point(10, 30)
    $clbExp.Size = New-Object System.Drawing.Size(640, 365)
    $clbExp.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $clbExp.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $clbExp.Font = New-Object System.Drawing.Font($UiFontName, 9)
    $clbExp.CheckOnClick = $true
    $preExp = @()
    if ($InitialSettings -and $InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }
    foreach ($item in $expItems) {
        $chk = $preExp -contains $item
        [void]$clbExp.Items.Add($item, $chk)
    }
    $tabExp.Controls.Add($clbExp)

    $btnExpAll = New-Object System.Windows.Forms.Button
    $btnExpAll.Text = "Select All"
    $btnExpAll.Location = New-Object System.Drawing.Point(10, 400)
    $btnExpAll.Size = New-Object System.Drawing.Size(100, 28)
    $btnExpAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnExpAll.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnExpAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $tabExp.Controls.Add($btnExpAll)

    $btnExpNone = New-Object System.Windows.Forms.Button
    $btnExpNone.Text = "Deselect All"
    $btnExpNone.Location = New-Object System.Drawing.Point(115, 400)
    $btnExpNone.Size = New-Object System.Drawing.Size(100, 28)
    $btnExpNone.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnExpNone.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnExpNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $tabExp.Controls.Add($btnExpNone)

    $btnExpAll.Add_Click({ for ($i = 0; $i -lt $clbExp.Items.Count; $i++) { $clbExp.SetItemChecked($i, $true) } })
    $btnExpNone.Add_Click({ for ($i = 0; $i -lt $clbExp.Items.Count; $i++) { $clbExp.SetItemChecked($i, $false) } })

    # Preview button
    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = "Preview"
    $btnPreview.Location = New-Object System.Drawing.Point(10, 500)
    $btnPreview.Size = New-Object System.Drawing.Size(100, 30)
    $btnPreview.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnPreview.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnPreview.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dlg.Controls.Add($btnPreview)

    $btnPreview.Add_Click({
        $stdSel = @(); $expSel = @()
        for ($i = 0; $i -lt $clbStd.Items.Count; $i++) { if ($clbStd.GetItemChecked($i)) { $stdSel += $clbStd.Items[$i] } }
        for ($i = 0; $i -lt $clbExp.Items.Count; $i++) { if ($clbExp.GetItemChecked($i)) { $expSel += $clbExp.Items[$i] } }
        $msg = "Selected: Standard=$($stdSel.Count) / Experimental=$($expSel.Count)`n`n"
        $msg += "Standard ($($stdSel.Count) items)`n"
        foreach ($s in $stdSel) { $msg += "  - $s`n" }
        $msg += "`nExperimental ($($expSel.Count) items)`n"
        foreach ($s in $expSel) { $msg += "  - $s`n" }
        if ($expSel.Count -gt 0) {
            $msg += "`nExperimental enabled: Windows Update will be broken"
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "Deletion Preview", "OK", "Information")
    })

    # OK / Cancel
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(480, 500)
    $btnOK.Size = New-Object System.Drawing.Size(90, 30)
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dlg.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(575, 500)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dlg.Controls.Add($btnCancel)

    $btnOK.Add_Click({
        $stdSel = @(); $expSel = @()
        for ($i = 0; $i -lt $clbStd.Items.Count; $i++) { if ($clbStd.GetItemChecked($i)) { $stdSel += $clbStd.Items[$i] } }
        for ($i = 0; $i -lt $clbExp.Items.Count; $i++) { if ($clbExp.GetItemChecked($i)) { $expSel += $clbExp.Items[$i] } }
        $script:advDebloatStd = $stdSel
        $script:advDebloatExp = $expSel
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnCancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    $dlg.TopMost = $true
    $result = $dlg.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{ Success = $true; StandardSelected = $script:advDebloatStd; ExperimentalSelected = $script:advDebloatExp }
    }
    return @{ Success = $false; StandardSelected = @(); ExperimentalSelected = @() }
}

function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{}
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch {}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "nano11 Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer"
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $form.ClientSize = New-Object System.Drawing.Size(880, 820)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)

    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $frameH = $form.Height - $form.ClientSize.Height
        if ($form.Height -gt $wa.Height) {
            $form.ClientSize = New-Object System.Drawing.Size(880, ($wa.Height - $frameH - 10))
        }
    } catch {}

    $toolTip = New-Object System.Windows.Forms.ToolTip

    # Header Panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 65
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "nano11 Builder v2.1"
    $titleLabel.Font = New-Object System.Drawing.Font($uiFontName, 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $titleLabel.Location = New-Object System.Drawing.Point(16, 10)
    $titleLabel.AutoSize = $true
    $headerPanel.Controls.Add($titleLabel)

    $subTitleLabel = New-Object System.Windows.Forms.Label
    $subTitleLabel.Text = "Universal, Language-Independent Windows 11 Modular Reducer & Full-Toggle Optimizer"
    $subTitleLabel.Font = New-Object System.Drawing.Font($uiFontName, 8.5)
    $subTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 165, 175)
    $subTitleLabel.Location = New-Object System.Drawing.Point(18, 38)
    $subTitleLabel.AutoSize = $true
    $headerPanel.Controls.Add($subTitleLabel)

    # Bottom Button & Estimate Panel
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 70
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($bottomPanel)

    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Text = "DryRun (Simulation Mode)"
    $chkDryRun.Location = New-Object System.Drawing.Point(20, 12)
    $chkDryRun.Size = New-Object System.Drawing.Size(200, 22)
    $chkDryRun.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $bottomPanel.Controls.Add($chkDryRun)

    $lblEstimate = New-Object System.Windows.Forms.Label
    $lblEstimate.Text = "Estimated ISO: ~5.5 GB (LZX baseline)"
    $lblEstimate.Location = New-Object System.Drawing.Point(20, 38)
    $lblEstimate.Size = New-Object System.Drawing.Size(380, 20)
    $lblEstimate.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $lblEstimate.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $bottomPanel.Controls.Add($lblEstimate)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "Start nano11 Build"
    $btnBuild.Location = New-Object System.Drawing.Point(540, 15)
    $btnBuild.Size = New-Object System.Drawing.Size(200, 40)
    $btnBuild.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.Font = New-Object System.Drawing.Font($uiFontName, 10, [System.Drawing.FontStyle]::Bold)
    $btnBuild.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $bottomPanel.Controls.Add($btnBuild)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Font = New-Object System.Drawing.Font($uiFontName, 9.5)
    $btnCancel.Location = New-Object System.Drawing.Point(750, 15)
    $btnCancel.Size = New-Object System.Drawing.Size(110, 40)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bottomPanel.Controls.Add($btnCancel)

    # Main Tab Control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $form.Controls.Add($tabControl)
    $tabControl.BringToFront()

    $tweakCheckboxes = @{}
    $componentCheckboxes = @{}
    $script:updatingPreset = $false

    # Helper function to create standard toggle checkboxes
    $createToggleChk = {
        param($parent, $name, $text, $toolTipText, $checked, $tag)
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $text
        $chk.Size = New-Object System.Drawing.Size(400, 28)
        $chk.AutoEllipsis = $true
        $chk.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
        $chk.Checked = [bool]$checked
        $chk.Tag = $tag
        $toolTip.SetToolTip($chk, $toolTipText)
        $chk.Add_CheckedChanged({
            if (-not $script:updatingPreset) {
                if ($cmbPreset -and $cmbPreset.Items.Count -gt 0) {
                    $script:updatingPreset = $true
                    $cmbPreset.SelectedIndex = ($cmbPreset.Items.Count - 1) # Custom
                    $script:updatingPreset = $false
                }
                & $updateEstimate
            }
        })
        $parent.Controls.Add($chk)
        return $chk
    }

    # =========================================================================
    # TAB 1: Media & Workspace & Preset
    # =========================================================================
    $tabMedia = New-Object System.Windows.Forms.TabPage
    $tabMedia.Text = " 1. Media & Output "
    $tabMedia.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $tabControl.TabPages.Add($tabMedia)

    $grpMedia = New-Object System.Windows.Forms.GroupBox
    $grpMedia.Text = " Source Media & Paths "
    $grpMedia.Location = New-Object System.Drawing.Point(15, 10)
    $grpMedia.Size = New-Object System.Drawing.Size(835, 185)
    $grpMedia.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $tabMedia.Controls.Add($grpMedia)

    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "Source Drive / ISO:"
    $lblSource.Location = New-Object System.Drawing.Point(15, 28)
    $lblSource.Size = New-Object System.Drawing.Size(130, 20)
    $lblSource.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblSource)

    $cmbSource = New-Object System.Windows.Forms.ComboBox
    $cmbSource.Location = New-Object System.Drawing.Point(150, 25)
    $cmbSource.Size = New-Object System.Drawing.Size(370, 24)
    $cmbSource.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbSource.ForeColor = [System.Drawing.Color]::White
    $grpMedia.Controls.Add($cmbSource)

    $populateSources = {
        $cmbSource.Items.Clear()
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
        foreach ($srcItem in $detectedSources) { [void]$cmbSource.Items.Add($srcItem) }
    }
    & $populateSources

    if ($InitialSettings.SourceDrive) { $cmbSource.Text = $InitialSettings.SourceDrive }
    elseif ($cmbSource.Items.Count -gt 0) { $cmbSource.SelectedIndex = 0 }
    else { $cmbSource.Text = "E:\" }

    $btnBrowseDrive = New-Object System.Windows.Forms.Button
    $btnBrowseDrive.Text = "Browse Drive..."
    $btnBrowseDrive.Location = New-Object System.Drawing.Point(530, 24)
    $btnBrowseDrive.Size = New-Object System.Drawing.Size(110, 26)
    $btnBrowseDrive.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrive.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrive.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseDrive.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select Windows 11 installation media or mounted virtual DVD drive"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $cmbSource.Text = $p
        }
    })
    $grpMedia.Controls.Add($btnBrowseDrive)

    $btnBrowseIso = New-Object System.Windows.Forms.Button
    $btnBrowseIso.Text = "Browse ISO..."
    $btnBrowseIso.Location = New-Object System.Drawing.Point(645, 24)
    $btnBrowseIso.Size = New-Object System.Drawing.Size(100, 26)
    $btnBrowseIso.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseIso.ForeColor = [System.Drawing.Color]::White
    $btnBrowseIso.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseIso.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Windows 11 ISO (*.iso)|*.iso|All Files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $cmbSource.Text = $ofd.FileName }
    })
    $grpMedia.Controls.Add($btnBrowseIso)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Rescan"
    $btnRefresh.Location = New-Object System.Drawing.Point(750, 24)
    $btnRefresh.Size = New-Object System.Drawing.Size(70, 26)
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRefresh.Add_Click({ & $populateSources })
    $grpMedia.Controls.Add($btnRefresh)

    # WorkDir
    $lblWork = New-Object System.Windows.Forms.Label
    $lblWork.Text = "Workspace Dir:"
    $lblWork.Location = New-Object System.Drawing.Point(15, 60)
    $lblWork.Size = New-Object System.Drawing.Size(130, 20)
    $lblWork.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblWork)

    $txtWork = New-Object System.Windows.Forms.TextBox
    $txtWork.Location = New-Object System.Drawing.Point(150, 57)
    $txtWork.Size = New-Object System.Drawing.Size(535, 24)
    $txtWork.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtWork.ForeColor = [System.Drawing.Color]::White
    $docsDir = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
    $txtWork.Text = if ($InitialSettings.WorkDir) { $InitialSettings.WorkDir } else { Join-Path -Path $docsDir -ChildPath "nano11_workspace" }
    $grpMedia.Controls.Add($txtWork)

    $btnBrowseWork = New-Object System.Windows.Forms.Button
    $btnBrowseWork.Text = "Browse Folder..."
    $btnBrowseWork.Location = New-Object System.Drawing.Point(695, 56)
    $btnBrowseWork.Size = New-Object System.Drawing.Size(125, 26)
    $btnBrowseWork.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseWork.ForeColor = [System.Drawing.Color]::White
    $btnBrowseWork.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseWork.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtWork.Text = $fbd.SelectedPath }
    })
    $grpMedia.Controls.Add($btnBrowseWork)

    # Index & Drivers
    $lblIndex = New-Object System.Windows.Forms.Label
    $lblIndex.Text = "Image Index:"
    $lblIndex.Location = New-Object System.Drawing.Point(15, 95)
    $lblIndex.Size = New-Object System.Drawing.Size(130, 20)
    $lblIndex.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblIndex)

    $txtIndex = New-Object System.Windows.Forms.TextBox
    $txtIndex.Location = New-Object System.Drawing.Point(150, 92)
    $txtIndex.Size = New-Object System.Drawing.Size(70, 24)
    $txtIndex.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtIndex.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.Index) { $txtIndex.Text = "$($InitialSettings.Index)" }
    $grpMedia.Controls.Add($txtIndex)

    $lblDrivers = New-Object System.Windows.Forms.Label
    $lblDrivers.Text = 'Inject Drivers ($OEM$):'
    $lblDrivers.Location = New-Object System.Drawing.Point(235, 95)
    $lblDrivers.Size = New-Object System.Drawing.Size(140, 20)
    $lblDrivers.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblDrivers)

    $txtDrivers = New-Object System.Windows.Forms.TextBox
    $txtDrivers.Location = New-Object System.Drawing.Point(380, 92)
    $txtDrivers.Size = New-Object System.Drawing.Size(305, 24)
    $txtDrivers.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtDrivers.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.InjectDrivers) { $txtDrivers.Text = "$($InitialSettings.InjectDrivers)" }
    $grpMedia.Controls.Add($txtDrivers)

    $btnBrowseDrivers = New-Object System.Windows.Forms.Button
    $btnBrowseDrivers.Text = "Browse..."
    $btnBrowseDrivers.Location = New-Object System.Drawing.Point(695, 91)
    $btnBrowseDrivers.Size = New-Object System.Drawing.Size(125, 26)
    $btnBrowseDrivers.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrivers.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrivers.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseDrivers.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtDrivers.Text = $fbd.SelectedPath }
    })
    $grpMedia.Controls.Add($btnBrowseDrivers)

    # User & Computer
    $lblUserName = New-Object System.Windows.Forms.Label
    $lblUserName.Text = "Local Username:"
    $lblUserName.Location = New-Object System.Drawing.Point(15, 130)
    $lblUserName.Size = New-Object System.Drawing.Size(130, 20)
    $lblUserName.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblUserName)

    $txtUserName = New-Object System.Windows.Forms.TextBox
    $txtUserName.Location = New-Object System.Drawing.Point(150, 127)
    $txtUserName.Size = New-Object System.Drawing.Size(160, 24)
    $txtUserName.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtUserName.ForeColor = [System.Drawing.Color]::White
    $txtUserName.Text = if ($InitialSettings.UserName) { "$($InitialSettings.UserName)" } else { "User" }
    $grpMedia.Controls.Add($txtUserName)

    $lblComputerName = New-Object System.Windows.Forms.Label
    $lblComputerName.Text = "Computer Name:"
    $lblComputerName.Location = New-Object System.Drawing.Point(330, 130)
    $lblComputerName.Size = New-Object System.Drawing.Size(120, 20)
    $lblComputerName.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblComputerName)

    $txtComputerName = New-Object System.Windows.Forms.TextBox
    $txtComputerName.Location = New-Object System.Drawing.Point(450, 127)
    $txtComputerName.Size = New-Object System.Drawing.Size(160, 24)
    $txtComputerName.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtComputerName.ForeColor = [System.Drawing.Color]::White
    $txtComputerName.Text = if ($InitialSettings.ComputerName) { "$($InitialSettings.ComputerName)" } else { "*" }
    $grpMedia.Controls.Add($txtComputerName)

    # Preset Group
    $grpPreset = New-Object System.Windows.Forms.GroupBox
    $grpPreset.Text = " Configuration Profile Preset "
    $grpPreset.Location = New-Object System.Drawing.Point(15, 205)
    $grpPreset.Size = New-Object System.Drawing.Size(835, 75)
    $grpPreset.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $tabMedia.Controls.Add($grpPreset)

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.Location = New-Object System.Drawing.Point(15, 28)
    $cmbPreset.Size = New-Object System.Drawing.Size(805, 24)
    $cmbPreset.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
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

    # Payload Format Group
    $grpPayload = New-Object System.Windows.Forms.GroupBox
    $grpPayload.Text = " Output Payload Format & Scratch Acceleration "
    $grpPayload.Location = New-Object System.Drawing.Point(15, 290)
    $grpPayload.Size = New-Object System.Drawing.Size(835, 95)
    $grpPayload.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $tabMedia.Controls.Add($grpPayload)

    $radWIM = New-Object System.Windows.Forms.RadioButton
    $radWIM.Text = "install.wim (LZX - Recommended, High Compatibility)"
    $radWIM.Location = New-Object System.Drawing.Point(15, 28)
    $radWIM.Size = New-Object System.Drawing.Size(350, 24)
    $radWIM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $radWIM.Checked = $true
    $grpPayload.Controls.Add($radWIM)

    $radESD = New-Object System.Windows.Forms.RadioButton
    $radESD.Text = "install.esd (LZMS - Ultra Compression)"
    $radESD.Location = New-Object System.Drawing.Point(380, 28)
    $radESD.Size = New-Object System.Drawing.Size(250, 24)
    $radESD.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radESD)

    $radSWM = New-Object System.Windows.Forms.RadioButton
    $radSWM.Text = "install.swm (Split-WIM for FAT32 USB)"
    $radSWM.Location = New-Object System.Drawing.Point(640, 28)
    $radSWM.Size = New-Object System.Drawing.Size(185, 24)
    $radSWM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radSWM)

    if ($InitialSettings.ExportESDMode) { $radESD.Checked = $true }
    elseif ($InitialSettings.SplitWIMMode) { $radSWM.Checked = $true }

    $chkVHDX = New-Object System.Windows.Forms.CheckBox
    $chkVHDX.Text = "Use Fast VHDX Scratch Disk (Accelerates DISM image servicing file I/O)"
    $chkVHDX.Location = New-Object System.Drawing.Point(15, 60)
    $chkVHDX.Size = New-Object System.Drawing.Size(550, 24)
    $chkVHDX.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $chkVHDX.Checked = [bool]$InitialSettings.UseVHDX
    $grpPayload.Controls.Add($chkVHDX)

    # Function to create toggle tab with select all / clear all buttons
    $createTweakTab = {
        param([string]$title, [string]$category)
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = " $title "
        $tab.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
        $tabControl.TabPages.Add($tab)

        # Top Button Bar
        $bar = New-Object System.Windows.Forms.Panel
        $bar.Dock = [System.Windows.Forms.DockStyle]::Top
        $bar.Height = 40
        $bar.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 28)
        $tab.Controls.Add($bar)

        $btnSelectAll = New-Object System.Windows.Forms.Button
        $btnSelectAll.Text = "Select All"
        $btnSelectAll.Location = New-Object System.Drawing.Point(15, 7)
        $btnSelectAll.Size = New-Object System.Drawing.Size(95, 26)
        $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
        $btnSelectAll.ForeColor = [System.Drawing.Color]::White
        $btnSelectAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $bar.Controls.Add($btnSelectAll)

        $btnClearAll = New-Object System.Windows.Forms.Button
        $btnClearAll.Text = "Clear All"
        $btnClearAll.Location = New-Object System.Drawing.Point(120, 7)
        $btnClearAll.Size = New-Object System.Drawing.Size(95, 26)
        $btnClearAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
        $btnClearAll.ForeColor = [System.Drawing.Color]::White
        $btnClearAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $bar.Controls.Add($btnClearAll)

        $lblCount = New-Object System.Windows.Forms.Label
        $lblCount.Text = "Switches: $category"
        $lblCount.Location = New-Object System.Drawing.Point(230, 11)
        $lblCount.Size = New-Object System.Drawing.Size(400, 20)
        $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
        $bar.Controls.Add($lblCount)

        # Scrollable flow panel
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
        $flow.AutoScroll = $true
        $flow.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
        $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
        $flow.WrapContents = $true
        $tab.Controls.Add($flow)
        $flow.BringToFront()

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
            $chk = & $createToggleChk $flow $tk "$tk - $($def.Description)" $def.Description $initVal $tk
            $tweakCheckboxes[$tk] = $chk
            $tabCheckboxes.Add($chk)
        }

        # $tabCheckboxes is local to this scriptblock's scope and is gone by the time a
        # Click handler runs, so carry the list on the buttons themselves via Tag.
        $btnSelectAll.Tag = $tabCheckboxes
        $btnClearAll.Tag = $tabCheckboxes
        $btnSelectAll.Add_Click({
            foreach ($c in $this.Tag) { $c.Checked = $true }
        })
        $btnClearAll.Add_Click({
            foreach ($c in $this.Tag) { $c.Checked = $false }
        })

        return $tab
    }

    # Create Categories
    $tabSec  = & $createTweakTab "2. Security & Bypass" "Security"
    $tabPriv = & $createTweakTab "3. Privacy & AI" "Privacy"
    $tabPerf = & $createTweakTab "4. Performance" "Performance"
    $tabUI   = & $createTweakTab "5. UI & Shell" "UI"

    # =========================================================================
    # TAB 6: Components & Services
    # =========================================================================
    $tabServices = New-Object System.Windows.Forms.TabPage
    $tabServices.Text = " 6. Services & Apps "
    $tabServices.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $tabControl.TabPages.Add($tabServices)

    $barSvc = New-Object System.Windows.Forms.Panel
    $barSvc.Dock = [System.Windows.Forms.DockStyle]::Top
    $barSvc.Height = 40
    $barSvc.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 28)
    $tabServices.Controls.Add($barSvc)

    $flowSvc = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowSvc.Dock = [System.Windows.Forms.DockStyle]::Fill
    $flowSvc.AutoScroll = $true
    $flowSvc.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
    $flowSvc.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $flowSvc.WrapContents = $true
    $tabServices.Controls.Add($flowSvc)
    $flowSvc.BringToFront()

    # Components with a Gui entry in config\tweaks.psd1, in their Gui.Order
    $svcDefs = @($script:ComponentDefs.Values | Where-Object { $_.Gui } | Sort-Object { [int]$_.Gui.Order } | ForEach-Object {
        @{ Key = $_.Key; Text = $_.Gui.Text; Desc = $_.Gui.Description; Def = [bool]$_.Gui.Default }
    })
    $svcCheckboxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    foreach ($sd in $svcDefs) {
        $initVal = [bool]$sd.Def
        if ($InitialSettings.ContainsKey($sd.Key)) { $initVal = [bool]$InitialSettings[$sd.Key] }
        $chk = & $createToggleChk $flowSvc $sd.Key "$($sd.Key) - $($sd.Text)" $sd.Desc $initVal $sd.Key
        $componentCheckboxes[$sd.Key] = $chk
        $svcCheckboxes.Add($chk)
    }

    $btnSvcAll = New-Object System.Windows.Forms.Button
    $btnSvcAll.Text = "Select All"
    $btnSvcAll.Location = New-Object System.Drawing.Point(15, 7)
    $btnSvcAll.Size = New-Object System.Drawing.Size(95, 26)
    $btnSvcAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnSvcAll.ForeColor = [System.Drawing.Color]::White
    $btnSvcAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSvcAll.Add_Click({ foreach ($c in $svcCheckboxes) { $c.Checked = $true } })
    $barSvc.Controls.Add($btnSvcAll)

    $btnSvcClear = New-Object System.Windows.Forms.Button
    $btnSvcClear.Text = "Clear All"
    $btnSvcClear.Location = New-Object System.Drawing.Point(120, 7)
    $btnSvcClear.Size = New-Object System.Drawing.Size(95, 26)
    $btnSvcClear.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnSvcClear.ForeColor = [System.Drawing.Color]::White
    $btnSvcClear.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSvcClear.Add_Click({ foreach ($c in $svcCheckboxes) { $c.Checked = $false } })
    $barSvc.Controls.Add($btnSvcClear)

    # =========================================================================
    # TAB 7: Advanced Debloat (Physical Deletion)
    # =========================================================================
    $tabDebloat = New-Object System.Windows.Forms.TabPage
    $tabDebloat.Text = " 7. Advanced Debloat "
    $tabDebloat.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $tabControl.TabPages.Add($tabDebloat)

    $barDeb = New-Object System.Windows.Forms.Panel
    $barDeb.Dock = [System.Windows.Forms.DockStyle]::Top
    $barDeb.Height = 40
    $barDeb.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 28)
    $tabDebloat.Controls.Add($barDeb)

    $lblDebWarn = New-Object System.Windows.Forms.Label
    $lblDebWarn.Text = "Notice: Standard uses CBS safe operations. Experimental physically deletes files."
    $lblDebWarn.Location = New-Object System.Drawing.Point(15, 11)
    $lblDebWarn.Size = New-Object System.Drawing.Size(650, 20)
    $lblDebWarn.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 100)
    $lblDebWarn.Font = New-Object System.Drawing.Font($uiFontName, 8.5)
    $barDeb.Controls.Add($lblDebWarn)

    $flowDeb = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowDeb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $flowDeb.AutoScroll = $true
    $flowDeb.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
    $tabDebloat.Controls.Add($flowDeb)
    $flowDeb.BringToFront()

    # Standard Debloat group
    $grpStdDeb = New-Object System.Windows.Forms.GroupBox
    $grpStdDeb.Text = " Standard Debloat (Safe Component Pruning) "
    $grpStdDeb.Size = New-Object System.Drawing.Size(410, 480)
    $grpStdDeb.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $flowDeb.Controls.Add($grpStdDeb)

    $clbStd = New-Object System.Windows.Forms.CheckedListBox
    $clbStd.Dock = [System.Windows.Forms.DockStyle]::Fill
    $clbStd.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $clbStd.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $clbStd.CheckOnClick = $true
    $grpStdDeb.Controls.Add($clbStd)

    # Experimental Debloat group
    $grpExpDeb = New-Object System.Windows.Forms.GroupBox
    $grpExpDeb.Text = " Experimental Physical Debloat (Destructive / Breaks WU) "
    $grpExpDeb.Size = New-Object System.Drawing.Size(410, 480)
    $grpExpDeb.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    $flowDeb.Controls.Add($grpExpDeb)

    $clbExp = New-Object System.Windows.Forms.CheckedListBox
    $clbExp.Dock = [System.Windows.Forms.DockStyle]::Fill
    $clbExp.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $clbExp.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $clbExp.CheckOnClick = $true
    $grpExpDeb.Controls.Add($clbExp)

    # Select All / Clear All bar at the bottom of each debloat group. The target list
    # travels on each button's Tag so the Click handler doesn't depend on scope.
    foreach ($pair in @(@($grpStdDeb, $clbStd, $false), @($grpExpDeb, $clbExp, $true))) {
        $grp = $pair[0]; $clb = $pair[1]; $isDestructive = $pair[2]
        $barList = New-Object System.Windows.Forms.Panel
        $barList.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $barList.Height = 34
        $grp.Controls.Add($barList)
        $clb.BringToFront()

        $btnListAll = New-Object System.Windows.Forms.Button
        $btnListAll.Text = "Select All"
        $btnListAll.Location = New-Object System.Drawing.Point(5, 4)
        $btnListAll.Size = New-Object System.Drawing.Size(95, 26)
        $btnListAll.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
        $btnListAll.ForeColor = [System.Drawing.Color]::White
        $btnListAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnListAll.Tag = @{ List = $clb; Confirm = $isDestructive }
        $btnListAll.Add_Click({
            $t = $this.Tag
            if ($t.Confirm) {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    "Select ALL experimental physical deletions?`nThis permanently breaks Windows Update and sfc.",
                    "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            for ($i = 0; $i -lt $t.List.Items.Count; $i++) { $t.List.SetItemChecked($i, $true) }
        })
        $barList.Controls.Add($btnListAll)

        $btnListClear = New-Object System.Windows.Forms.Button
        $btnListClear.Text = "Clear All"
        $btnListClear.Location = New-Object System.Drawing.Point(105, 4)
        $btnListClear.Size = New-Object System.Drawing.Size(95, 26)
        $btnListClear.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
        $btnListClear.ForeColor = [System.Drawing.Color]::White
        $btnListClear.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnListClear.Tag = $clb
        $btnListClear.Add_Click({
            for ($i = 0; $i -lt $this.Tag.Items.Count; $i++) { $this.Tag.SetItemChecked($i, $false) }
        })
        $barList.Controls.Add($btnListClear)
    }

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
    foreach ($item in $stdItems) {
        $chk = $preStd -contains $item
        [void]$clbStd.Items.Add($item, $chk)
    }

    $preExp = @()
    if ($InitialSettings.AdvancedDebloatExperimental) { $preExp = @($InitialSettings.AdvancedDebloatExperimental) }
    foreach ($item in $expItems) {
        $chk = $preExp -contains $item
        [void]$clbExp.Items.Add($item, $chk)
    }

    # =========================================================================
    # Synchronization & Presets Handling
    # =========================================================================
    $presetKeyMap = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $initPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $initPresetName = "$($InitialSettings.PresetKey)".Trim().ToLower()
    $initPresetIdx = [array]::IndexOf($initPresetKeys, $initPresetName)
    if ($initPresetIdx -lt 0) {
        $initPresetIdx = if ($initPresetName) { $cmbPreset.Items.Count - 1 } else { 0 }
    }
    $cmbPreset.SelectedIndex = $initPresetIdx

    $script:guiBasePresetKey = if ($initPresetIdx -lt $presetKeyMap.Count) { $presetKeyMap[$initPresetIdx] } else { $null }

    $updateEstimate = {
        try {
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
            if ($radESD.Checked) { $mb = [math]::Round($mb * 0.82) }
            $lblEstimate.Text = ("Estimated ISO Size: ~{0} GB (LZX baseline)" -f [math]::Round($mb / 1024, 2))
        } catch {}
    }

    $applyPreset = {
        param($presetIndex)
        $script:updatingPreset = $true
        if ($presetIndex -ge 0 -and $presetIndex -lt $presetKeyMap.Count) {
            $pKey = $presetKeyMap[$presetIndex]
            $pObj = Get-Nano11Preset -Name $pKey
            if ($pObj) {
                # Update component checkboxes
                foreach ($k in $componentCheckboxes.Keys) {
                    if ($pObj.Contains($k)) {
                        $componentCheckboxes[$k].Checked = [bool]$pObj[$k]
                    }
                }
                # Update tweak checkboxes
                $pTweaks = if ($pObj.TweakSettings) { $pObj.TweakSettings } else { $null }
                foreach ($tk in $tweakCheckboxes.Keys) {
                    if ($pTweaks -and $pTweaks.Contains($tk)) {
                        $tweakCheckboxes[$tk].Checked = [bool]$pTweaks[$tk]
                    } elseif ($pObj.Contains($tk)) {
                        $tweakCheckboxes[$tk].Checked = [bool]$pObj[$tk]
                    } else {
                        $tweakCheckboxes[$tk].Checked = [bool]$script:AllTweakDefs[$tk].Default
                    }
                }
                # Update payload radio
                $fmt = "$($pObj.PayloadFormat)".ToUpper()
                if ($fmt -eq 'ESD') { $radESD.Checked = $true }
                elseif ($fmt -eq 'SWM') { $radSWM.Checked = $true }
                else { $radWIM.Checked = $true }
                $script:guiBasePresetKey = $pKey
            }
        }
        $script:updatingPreset = $false
        & $updateEstimate
    }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $cmbPreset.SelectedIndex -ne ($cmbPreset.Items.Count - 1)) {
            & $applyPreset $cmbPreset.SelectedIndex
        }
    })

    foreach ($r in @($radWIM, $radESD, $radSWM)) {
        $r.Add_CheckedChanged({ & $updateEstimate })
    }
    & $updateEstimate

    # Build Button Action
    $formResult = @{ Success = $false }

    $btnBuild.Add_Click({
        $srcText = $cmbSource.Text.Trim()
        if (-not $srcText) {
            [System.Windows.Forms.MessageBox]::Show("Please specify Windows 11 installation media or ISO image.", "Source Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
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

        $wDir = $txtWork.Text.Trim()
        if (-not $wDir) {
            $docsDir = [Environment]::GetFolderPath('MyDocuments')
            if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
            $wDir = Join-Path -Path $docsDir -ChildPath "nano11_workspace"
        }

        $guiUserName = $txtUserName.Text.Trim()
        $guiComputerName = $txtComputerName.Text.Trim()
        if (-not $guiComputerName) { $guiComputerName = '*' }
        if ($guiUserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') {
            [System.Windows.Forms.MessageBox]::Show("Username must contain only letters, digits, spaces, '.', '_', or '-' (max 20 chars).", "Invalid Username", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($guiComputerName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') {
            [System.Windows.Forms.MessageBox]::Show("ComputerName must be '*' or up to 15 alphanumeric characters and hyphens.", "Invalid ComputerName", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $formResult.Success                      = $true
        $formResult.UserName                     = $guiUserName
        $formResult.ComputerName                 = $guiComputerName
        $formResult.PresetKey                    = if ($cmbPreset.SelectedIndex -ge 0 -and $cmbPreset.SelectedIndex -lt $presetKeyMap.Count) { $presetKeyMap[$cmbPreset.SelectedIndex] } else { $null }
        $formResult.BasePresetKey                = $script:guiBasePresetKey
        $formResult.SourceDrive                  = $resolvedSource
        $formResult.WorkDir                      = $wDir
        $formResult.Index                        = $txtIndex.Text.Trim()
        $formResult.InjectDrivers                = $txtDrivers.Text.Trim()
        $formResult.DryRun                       = $chkDryRun.Checked
        $formResult.UseVHDX                      = $chkVHDX.Checked
        $formResult.ExportESDMode                = $radESD.Checked
        $formResult.SplitWIMMode                 = $radSWM.Checked

        # Component values
        foreach ($k in $componentCheckboxes.Keys) {
            $formResult[$k] = $componentCheckboxes[$k].Checked
        }

        # Granular TweakSettings
        $resolvedTweaks = [ordered]@{}
        foreach ($k in $tweakCheckboxes.Keys) {
            $resolvedTweaks[$k] = $tweakCheckboxes[$k].Checked
        }
        $formResult.TweakSettings = $resolvedTweaks

        # Advanced Debloat items
        $stdSelected = @()
        foreach ($item in $clbStd.CheckedItems) { $stdSelected += "$item" }
        $expSelected = @()
        foreach ($item in $clbExp.CheckedItems) { $expSelected += "$item" }
        $formResult.AdvancedDebloatStandard     = $stdSelected
        $formResult.AdvancedDebloatExperimental = $expSelected

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $disableMnemonic = { param($ctl) foreach ($c in $ctl.Controls) { if ($c.PSObject.Properties['UseMnemonic']) { $c.UseMnemonic = $false }; & $disableMnemonic $c } }
    & $disableMnemonic $form

    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    $diagResult = $form.ShowDialog()
    if ($diagResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $formResult
    }
    return @{ Success = $false }
}
