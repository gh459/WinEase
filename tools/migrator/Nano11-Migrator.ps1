#Requires -Version 5.1
<#
.SYNOPSIS
    Nano11-Migrator - Standalone PC migration and backup tool for nano11.
.DESCRIPTION
    Backs up and restores user data, game saves and app configs between PCs.
    Runs from the repository (tools\ next to lib\) or from the ISO-bundled folder
    (this script, nano11helpers.ps1, Nano11Migration.ps1 and config in one folder).
    With no -Mode the GUI opens.
.PARAMETER Mode
    ExportApps | Backup | Restore | Verify | Estimate (ListRules and RecoveryCheck are kept for older callers).
.PARAMETER PackagePath
    Folder the backup is written to / read from. Alias: BackupRoot.
.PARAMETER UserFolders
    Known personal folders to back up (Documents, Desktop, Pictures, Videos, Downloads, Music).
.PARAMETER CustomPaths
    Extra files/folders to back up.
.PARAMETER RuleIds
    Comma-separated migration rule IDs (game saves / app settings).
.PARAMETER ConflictPolicy
    Skip | BackupExisting | OverwriteIfNewer | Overwrite (default: BackupExisting)
.PARAMETER IncludeSecrets
    Include credential/token files in the backup (excluded by default).
.PARAMETER RetryFailedOnly
    Restore only the tasks that failed (or are still pending) last time.
.PARAMETER DryRun
    Simulate without making changes.
.PARAMETER GUI
    Open the wizard window.
#>
[CmdletBinding(DefaultParameterSetName = 'GUI')]
param(
    [Parameter(ParameterSetName = 'CLI', Mandatory = $true)]
    [ValidateSet('ExportApps', 'Backup', 'Restore', 'Verify', 'Estimate', 'ListRules', 'RecoveryCheck')]
    [string]$Mode,
    [Alias('BackupRoot')]
    [string]$PackagePath = '',
    [string[]]$UserFolders = @('Documents', 'Desktop', 'Pictures'),
    [string[]]$CustomPaths = @(),
    [string]$RuleIds = '',
    [ValidateSet('Skip', 'BackupExisting', 'OverwriteIfNewer', 'Overwrite')]
    [string]$ConflictPolicy = 'BackupExisting',
    [switch]$IncludeSecrets,
    [switch]$RetryFailedOnly,
    [switch]$DryRun,
    [Parameter(ParameterSetName = 'CLI')]
    [string]$OutputPath = '',
    [Parameter(ParameterSetName = 'GUI')]
    [switch]$GUI
)

$ErrorActionPreference = 'Stop'
$script:MigratorToolPath = $MyInvocation.MyCommand.Path
$script:MigratorDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:DefaultPackagePath = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'nano11_migration_backup'

# Repository layout: <root>\tools + <root>\lib + <root>\config. ISO bundle: everything in this folder.
function Find-Nano11MigratorFile {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
$script:MigratorParent = Split-Path -Parent $script:MigratorDir
$script:HelpersPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'nano11helpers.ps1'), (Join-Path $script:MigratorDir 'nano11helpers.ps1'))
$script:LibPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'lib\Nano11Migration.ps1'), (Join-Path $script:MigratorDir 'Nano11Migration.ps1'),
    (Join-Path $script:MigratorDir 'lib\Nano11Migration.ps1'))
$script:RulesPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'config\migration-rules.psd1'), (Join-Path $script:MigratorDir 'config\migration-rules.psd1'),
    (Join-Path $script:MigratorDir 'migration-rules.psd1'))
$script:UserRulesPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'config\user-migration-rules.psd1'), (Join-Path $script:MigratorDir 'config\user-migration-rules.psd1'),
    (Join-Path $script:MigratorDir 'user-migration-rules.psd1'))
if (-not $script:LibPath) { throw "Nano11Migration.ps1 not found next to or above '$script:MigratorDir'." }
if ($script:HelpersPath) { . $script:HelpersPath }
. $script:LibPath

function Get-MigratorRules {
    $a = @{}
    if ($script:RulesPath) { $a.BuiltInPath = $script:RulesPath }
    if ($script:UserRulesPath) { $a.UserPath = $script:UserRulesPath }
    return (Get-Nano11MigrationRules @a)
}

# Known folder names -> real paths (the profile may be redirected, so no string-built paths)
function Resolve-MigratorUserFolders {
    param([string[]]$Names)
    $map = [ordered]@{}
    foreach ($n in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $n = $n.Trim()
        $p = switch -Regex ($n) {
            '^Documents$' { [Environment]::GetFolderPath('MyDocuments') }
            '^Desktop$' { [Environment]::GetFolderPath('DesktopDirectory') }
            '^Pictures$' { [Environment]::GetFolderPath('MyPictures') }
            '^Videos$' { [Environment]::GetFolderPath('MyVideos') }
            '^Music$' { [Environment]::GetFolderPath('MyMusic') }
            '^Downloads$' { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' }
            default { $null }
        }
        if (-not $p) { Write-Warning "Unknown user folder '$n' skipped (use -CustomPaths for arbitrary paths)."; continue }
        $map[$n] = $p
    }
    return $map
}

function Get-MigratorRuleList {
    param([string]$Ids)
    return @($Ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# SourcePaths and process names of the selected rules (for the size estimate)
function Get-MigratorRuleSources {
    param([string[]]$Ids)
    $r = Get-MigratorRules
    $all = @($r.GameRules) + @($r.AppConfigRules) + @($r.CustomPathRules)
    $paths = @(); $procs = @()
    foreach ($rule in $all) {
        if ($Ids -contains $rule.Id) { $paths += @($rule.SourcePaths); $procs += @($rule.ProcessNames) }
    }
    return [PSCustomObject]@{ Paths = @($paths); ProcessNames = @($procs | Select-Object -Unique) }
}

# Verify: compare every manifest entry with the file in the backup (SHA-256)
function Test-MigratorBackupIntegrity {
    param([string]$Root)
    $mp = Join-Path $Root 'migration-manifest.json'
    if (-not (Test-Path -LiteralPath $mp)) {
        return [PSCustomObject]@{ Mode = 'Verify'; Success = $false; Checked = 0; Mismatched = @(); Missing = @(); NoHash = 0; Message = "migration-manifest.json not found in '$Root'." }
    }
    $m = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json
    $checked = 0; $nohash = 0; $bad = @(); $missing = @()
    foreach ($e in @($m.Entries)) {
        if (-not $e -or -not $e.RelativePath) { continue }
        $sub = if ($e.Category -eq 'CustomPath') { 'Custom' } else { [string]$e.Category }
        $f = Join-Path (Join-Path $Root $sub) ([string]$e.RelativePath)
        if (-not (Test-Path -LiteralPath $f)) { $missing += $f; continue }
        if (-not $e.Sha256) { $nohash++; continue }
        $checked++
        if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne [string]$e.Sha256) { $bad += $f }
    }
    $ok = ($bad.Count -eq 0 -and $missing.Count -eq 0)
    $msg = "Verified $checked file(s): $($bad.Count) mismatched, $($missing.Count) missing, $nohash without hash."
    return [PSCustomObject]@{ Mode = 'Verify'; Success = $ok; Checked = $checked; Mismatched = $bad; Missing = $missing; NoHash = $nohash; Message = $msg }
}

function Get-MigratorEstimate {
    param([string]$Root, [string[]]$FolderPaths, [string[]]$Custom, [string[]]$Ids)
    $src = Get-MigratorRuleSources -Ids $Ids
    $est = Get-Nano11MigrationSizeEstimate -UserFolderPaths (@($FolderPaths) + @($Custom) + @($src.Paths)) -SelectedRuleIds $Ids -DestinationPath $Root
    $running = @()
    foreach ($pn in $src.ProcessNames) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $running += $pn } }
    $est.RunningProcesses = @($running)
    return $est
}

function Write-MigratorEstimate {
    param($Est)
    Write-Host ("Files: {0}  Required: {1} MB  Free on {2}: {3} MB  Enough space: {4}" -f $Est.TotalFiles, $Est.TotalMB, $Est.DestinationDrive, $Est.DestinationFreeMB, $Est.HasEnoughSpace)
    if (@($Est.RunningProcesses).Count -gt 0) { Write-Host ("Running processes to close first: {0}" -f (@($Est.RunningProcesses) -join ', ')) -ForegroundColor Yellow }
}

# =========================================================================
# GUI (handlers read state from $this / $this.FindForm().Tag, never from locals of the builder)
# =========================================================================
$script:MigDark = [System.Drawing.Color]::FromArgb(24, 26, 31)
$script:MigPanel = [System.Drawing.Color]::FromArgb(35, 38, 46)
$script:MigText = [System.Drawing.Color]::FromArgb(235, 238, 245)
$script:MigAccent = [System.Drawing.Color]::FromArgb(0, 190, 255)
$script:MigButton = [System.Drawing.Color]::FromArgb(45, 50, 60)

function New-MigControl {
    param([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Parent, [object]$Tag, [scriptblock]$OnClick)
    $c = New-Object "System.Windows.Forms.$Type"
    if ($Text) { $c.Text = $Text }
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.ForeColor = $script:MigText
    if ($Type -eq 'Button') {
        $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $c.BackColor = $script:MigButton
    } elseif ($Type -in 'TextBox', 'CheckedListBox', 'ComboBox') {
        $c.BackColor = $script:MigPanel
    }
    if ($null -ne $Tag) { $c.Tag = $Tag }
    if ($OnClick) { $c.Add_Click($OnClick) }
    [void]$Parent.Controls.Add($c)
    return $c
}

function Add-MigLog {
    param($Form, [string]$Line)
    $Form.Tag.Log.AppendText($Line + [Environment]::NewLine)
}

# Runs this tool's CLI in a background job so the window stays responsive; returns the last result object
function Invoke-MigratorJob {
    param($Form, [hashtable]$Params)
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $job = Start-Job -ScriptBlock {
        param($tool, $p)
        & $tool @p
    } -ArgumentList $script:MigratorToolPath, $Params
    while ($job.State -eq 'Running') {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $result = $null; $err = $null
    if ($job.State -eq 'Failed') { $err = $job.ChildJobs[0].JobStateInfo.Reason.Message }
    else {
        try { $out = @(Receive-Job -Job $job -ErrorAction Stop) } catch { $err = $_.Exception.Message; $out = @() }
        $result = $out | Where-Object { $_ -and $_.PSObject.Properties['Mode'] } | Select-Object -Last 1
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    return [PSCustomObject]@{ Result = $result; Error = $err }
}

function Update-MigFreeSpace {
    param($Form)
    $g = $Form.Tag
    $g.FreeLabel.Text = 'Free space: -'
    try {
        $root = [System.IO.Path]::GetPathRoot($g.BackupRoot.Text.Trim())
        if ($root) {
            $di = New-Object System.IO.DriveInfo($root)
            if ($di.IsReady) { $g.FreeLabel.Text = ('Free space on {0}: {1} GB' -f $di.Name, [math]::Round($di.AvailableFreeSpace / 1GB, 1)) }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

function Get-MigSelection {
    param($Form)
    $g = $Form.Tag
    $known = @(); $custom = @()
    foreach ($i in $g.Folders.CheckedItems) {
        if ($g.KnownFolderNames -contains [string]$i) { $known += [string]$i } else { $custom += [string]$i }
    }
    $ids = @()
    foreach ($lb in @($g.GameRules, $g.AppRules)) {
        foreach ($i in $lb.CheckedItems) { $ids += (([string]$i -split ' - ')[0]).Trim() }
    }
    $root = $g.BackupRoot.Text.Trim()
    if (-not $root) { $root = $script:DefaultPackagePath; $g.BackupRoot.Text = $root }
    return @{ PackagePath = $root; UserFolders = $known; CustomPaths = $custom; RuleIds = ($ids -join ','); IncludeSecrets = (-not $g.ExcludeSecrets.Checked) }
}

function Show-Nano11MigratorDialog {
    param([string]$PackagePath = '')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ([string]::IsNullOrWhiteSpace($PackagePath)) { $PackagePath = $script:DefaultPackagePath }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Nano11 PC Migration & Backup Wizard'
    $form.Size = New-Object System.Drawing.Size(900, 680)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $script:MigDark
    $form.ForeColor = $script:MigText

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(8, 8)
    $tabs.Size = New-Object System.Drawing.Size(868, 470)
    [void]$form.Controls.Add($tabs)
    $t1 = New-Object System.Windows.Forms.TabPage; $t1.Text = 'Export / Backup'; $t1.BackColor = $script:MigDark
    $t2 = New-Object System.Windows.Forms.TabPage; $t2.Text = 'Restore & Reinstall'; $t2.BackColor = $script:MigDark
    [void]$tabs.TabPages.Add($t1); [void]$tabs.TabPages.Add($t2)

    $log = New-MigControl TextBox '' 8 486 868 150 $form
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'

    $g = @{ Log = $log; KnownFolderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads') }
    $form.Tag = $g

    # ---- Tab 1: Export / Backup
    [void](New-MigControl Label 'Backup folder:' 12 16 95 20 $t1)
    $g.BackupRoot = New-MigControl TextBox $PackagePath 110 13 580 24 $t1
    $g.BackupRoot.Add_TextChanged({ Update-MigFreeSpace -Form $this.FindForm() })
    [void](New-MigControl Button 'Browse...' 700 11 90 28 $t1 $null {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $f.Tag.BackupRoot.Text = $d.SelectedPath }
    })
    $g.FreeLabel = New-MigControl Label 'Free space: -' 110 40 580 20 $t1
    $g.FreeLabel.ForeColor = $script:MigAccent

    [void](New-MigControl Label 'Personal data folders:' 12 70 270 20 $t1)
    $g.Folders = New-MigControl CheckedListBox '' 12 92 270 150 $t1
    $g.Folders.CheckOnClick = $true
    foreach ($n in $g.KnownFolderNames) { [void]$g.Folders.Items.Add($n, ($n -in 'Documents', 'Desktop', 'Pictures')) }
    [void](New-MigControl Button 'Add Custom Folder...' 12 246 270 28 $t1 $null {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [void]$f.Tag.Folders.Items.Add($d.SelectedPath, $true) }
    })

    $rules = Get-MigratorRules
    [void](New-MigControl Label 'Game save rules ([Cloud] = cloud save note)' 296 70 290 20 $t1)
    $g.GameRules = New-MigControl CheckedListBox '' 296 92 280 182 $t1
    $g.GameRules.CheckOnClick = $true
    foreach ($r in @($rules.GameRules)) {
        $mark = if ($r.CloudSaveNotice) { '  [Cloud]' } else { '' }
        [void]$g.GameRules.Items.Add("$($r.Id) - $($r.Name)$mark")
    }
    [void](New-MigControl Label 'App settings rules' 590 70 270 20 $t1)
    $g.AppRules = New-MigControl CheckedListBox '' 590 92 260 182 $t1
    $g.AppRules.CheckOnClick = $true
    foreach ($r in @($rules.AppConfigRules)) {
        $mark = if ($r.CloudSaveNotice) { '  [Cloud]' } else { '' }
        [void]$g.AppRules.Items.Add("$($r.Id) - $($r.Name)$mark")
    }

    $g.ExcludeSecrets = New-MigControl CheckBox 'Exclude credentials/tokens (Recommended)' 12 290 400 24 $t1
    $g.ExcludeSecrets.Checked = $true

    [void](New-MigControl Button 'Estimate Size & Pre-flight Check' 12 328 300 36 $t1 $null {
        $f = $this.FindForm(); $this.Enabled = $false
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Estimate'
        Add-MigLog $f 'Estimating...'
        $o = Invoke-MigratorJob -Form $f -Params $s
        if ($o.Error) { Add-MigLog $f "Error: $($o.Error)" }
        elseif ($o.Result) {
            $e = $o.Result.Estimate
            Add-MigLog $f ("Files: {0}, required {1} MB, free {2} MB, enough space: {3}" -f $e.TotalFiles, $e.TotalMB, $e.DestinationFreeMB, $e.HasEnoughSpace)
            if (@($e.RunningProcesses).Count -gt 0) { Add-MigLog $f ('Close these first: ' + (@($e.RunningProcesses) -join ', ')) }
        }
        $this.Enabled = $true
    })
    [void](New-MigControl Button 'Start Backup & Verify (SHA-256)' 326 328 320 36 $t1 $null {
        $f = $this.FindForm(); $this.Enabled = $false
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Backup'
        Add-MigLog $f "Backup started: $($s.PackagePath)"
        $o = Invoke-MigratorJob -Form $f -Params $s
        if ($o.Error) {
            Add-MigLog $f "Error: $($o.Error)"
            [void][System.Windows.Forms.MessageBox]::Show("Error: $($o.Error)", 'Backup', 'OK', 'Error')
        } elseif ($o.Result) {
            Add-MigLog $f ('Backup finished. ' + $o.Result.Verify.Message)
            $f.Tag.RestoreRoot.Text = $s.PackagePath
            $rp = $o.Result.ReportPath
            if ($rp -and (Test-Path -LiteralPath $rp)) { Start-Process -FilePath $rp }
        }
        $this.Enabled = $true
    })

    # ---- Tab 2: Restore & Reinstall
    [void](New-MigControl Label 'Backup to restore:' 12 16 110 20 $t2)
    $g.RestoreRoot = New-MigControl TextBox $PackagePath 125 13 565 24 $t2
    [void](New-MigControl Button 'Browse...' 700 11 90 28 $t2 $null {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Select the folder that contains migration-manifest.json'
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-Path -LiteralPath (Join-Path $d.SelectedPath 'migration-manifest.json')) { $f.Tag.RestoreRoot.Text = $d.SelectedPath }
            else { [void][System.Windows.Forms.MessageBox]::Show('migration-manifest.json was not found in that folder.', 'Restore', 'OK', 'Warning') }
        }
    })
    [void](New-MigControl Label 'If a file already exists:' 12 56 150 20 $t2)
    $g.Policy = New-MigControl ComboBox '' 165 53 300 24 $t2
    $g.Policy.DropDownStyle = 'DropDownList'
    foreach ($p in 'BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite') { [void]$g.Policy.Items.Add($p) }
    $g.Policy.SelectedIndex = 0
    [void](New-MigControl Label 'BackupExisting keeps the old file as .nano11.bak' 475 56 380 20 $t2)

    $restoreHandler = {
        $f = $this.FindForm(); $g2 = $f.Tag; $kind = [string]$this.Tag
        $root = $g2.RestoreRoot.Text.Trim()
        if (-not (Test-Path -LiteralPath (Join-Path $root 'migration-manifest.json'))) {
            [void][System.Windows.Forms.MessageBox]::Show('Select a backup folder that contains migration-manifest.json.', 'Restore', 'OK', 'Warning')
            return
        }
        $this.Enabled = $false
        $p = @{ PackagePath = $root; ConflictPolicy = [string]$g2.Policy.SelectedItem }
        if ($kind -eq 'Verify') { $p.Mode = 'Verify' } else { $p.Mode = 'Restore'; if ($kind -eq 'Retry') { $p.RetryFailedOnly = $true } }
        Add-MigLog $f "$($p.Mode) ($kind) started: $root"
        $o = Invoke-MigratorJob -Form $f -Params $p
        if ($o.Error) { Add-MigLog $f "Error: $($o.Error)" }
        elseif ($o.Result -and $p.Mode -eq 'Verify') { Add-MigLog $f $o.Result.Message }
        elseif ($o.Result) {
            foreach ($r in @($o.Result.Results)) { Add-MigLog $f ('  {0}: {1}' -f $r.TaskId, $r.Status) }
            if ($o.Result.ReportPath -and (Test-Path -LiteralPath $o.Result.ReportPath)) { Start-Process -FilePath $o.Result.ReportPath }
        }
        $this.Enabled = $true
    }
    [void](New-MigControl Button 'Verify Backup Integrity' 12 100 230 36 $t2 'Verify' $restoreHandler)
    [void](New-MigControl Button 'Restore Selected Items' 256 100 230 36 $t2 'Restore' $restoreHandler)
    [void](New-MigControl Button 'Retry Failed Tasks Only' 500 100 230 36 $t2 'Retry' $restoreHandler)

    Update-MigFreeSpace -Form $form
    [void]$form.ShowDialog()
}

# =========================================================================
# Entry point
# =========================================================================
if ($PSCmdlet.ParameterSetName -eq 'GUI') {
    Write-Verbose "Opening GUI (-GUI: $GUI)"
    Show-Nano11MigratorDialog -PackagePath $PackagePath
    return
}

if (-not $PackagePath) { $PackagePath = $script:DefaultPackagePath }
$idList = Get-MigratorRuleList -Ids $RuleIds

switch ($Mode) {
    'ListRules' {
        $rules = Get-MigratorRules
        Write-Host '=== Game Rules ===' -ForegroundColor Cyan
        $rules.GameRules | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Id, $_.Name) }
        Write-Host '=== App Config Rules ===' -ForegroundColor Cyan
        $rules.AppConfigRules | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Id, $_.Name) }
    }
    'ExportApps' {
        $out = if ($OutputPath) { $OutputPath } else { Join-Path $PackagePath 'apps-inventory.json' }
        $r = Export-Nano11AppInventory -OutputPath $out
        Write-Host "Exported $($r.TotalApps) apps ($($r.AutoInstallable) auto-installable) to $out" -ForegroundColor Green
        [PSCustomObject]@{ Mode = 'ExportApps'; OutputPath = $out; TotalApps = $r.TotalApps }
    }
    'RecoveryCheck' {
        $rr = Test-Nano11RecoveryReadiness -Config @{}
        Write-Host "Readiness Score: $($rr.ReadinessScore)" -ForegroundColor Cyan
        Write-Host "Secondary Drives: $($rr.SecondaryDrives -join ', ')"
        Write-Host "System Restore: $($rr.SystemRestoreEnabled)"
        Write-Host "WinRE on target: $($rr.WinReEnabledOnTarget)"
        Write-Host "Migration backup found: $($rr.MigrationBackupFound)"
        $rr.Recommendations | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    'Estimate' {
        $fm = Resolve-MigratorUserFolders -Names $UserFolders
        $est = Get-MigratorEstimate -Root $PackagePath -FolderPaths @($fm.Values) -Custom $CustomPaths -Ids $idList
        Write-MigratorEstimate -Est $est
        [PSCustomObject]@{ Mode = 'Estimate'; Estimate = $est }
    }
    'Verify' {
        $v = Test-MigratorBackupIntegrity -Root $PackagePath
        $color = if ($v.Success) { 'Green' } else { 'Red' }
        Write-Host $v.Message -ForegroundColor $color
        foreach ($x in $v.Mismatched) { Write-Host "  MISMATCH: $x" -ForegroundColor Red }
        foreach ($x in $v.Missing) { Write-Host "  MISSING:  $x" -ForegroundColor Red }
        $v
    }
    'Backup' {
        $fm = Resolve-MigratorUserFolders -Names $UserFolders
        $folderMap = @{}
        foreach ($k in $fm.Keys) { $folderMap[$k] = $fm[$k] }
        $est = Get-MigratorEstimate -Root $PackagePath -FolderPaths @($fm.Values) -Custom $CustomPaths -Ids $idList
        Write-MigratorEstimate -Est $est
        if (-not $est.HasEnoughSpace -and -not $DryRun) { throw 'Not enough free space on the backup drive.' }
        $result = Start-Nano11MigrationBackup -FolderMap $folderMap -BackupRoot $PackagePath -RuleIds $idList -CustomPaths $CustomPaths -IncludeSecrets:$IncludeSecrets -DryRun:$DryRun
        $verify = [PSCustomObject]@{ Success = $true; Message = 'DryRun: nothing to verify.' }
        $report = $null
        if (-not $DryRun) {
            $verify = Test-MigratorBackupIntegrity -Root $PackagePath
            $report = Join-Path $PackagePath 'migration-report.html'
            Write-Host "Backup completed. Manifest: $(Join-Path $PackagePath 'migration-manifest.json')" -ForegroundColor Green
            Write-Host $verify.Message
            Write-Host "Report: $report" -ForegroundColor Cyan
        }
        [PSCustomObject]@{ Mode = 'Backup'; Success = $verify.Success; Verify = $verify; ReportPath = $report; Manifest = $result }
    }
    'Restore' {
        $result = Start-Nano11MigrationRestore -BackupRoot $PackagePath -ConflictPolicy $ConflictPolicy -RetryFailedOnly:$RetryFailedOnly -DryRun:$DryRun
        Write-Host 'Restore completed.' -ForegroundColor Green
        $result.Results | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.TaskId, $_.Status) }
        $report = $null
        if (-not $DryRun) {
            $report = Join-Path $PackagePath 'migration-report.html'
            try { [void](Export-Nano11MigrationReport -MigrationResult $result -ReportPath $report) } catch { Write-Warning "Report not written: $($_.Exception.Message)"; $report = $null }
        }
        [PSCustomObject]@{ Mode = 'Restore'; Results = @($result.Results); ReportPath = $report }
    }
}
