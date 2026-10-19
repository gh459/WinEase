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

# Repository layout: <root>\tools\migrator (this script, engine, rules) + <root>\config\user (user rules) + <root>\nano11helpers.ps1.
# ISO bundle: everything in this folder.
function Find-Nano11MigratorFile {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
$script:MigratorParent = Split-Path -Parent (Split-Path -Parent $script:MigratorDir)
# Shared WinForms parts, colour table and default backup folder: gui\Nano11Gui.ps1 in the repository,
# Nano11Gui.ps1 in this folder when bundled. Loaded first so the helpers and the engine win any name clash.
$script:GuiPartsPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'gui\Nano11Gui.ps1'), (Join-Path $script:MigratorDir 'Nano11Gui.ps1'))
if ($script:GuiPartsPath) { . $script:GuiPartsPath }
$script:DefaultPackagePath = if (Get-Command -Name Get-Nano11DefaultMigrationBackupPath -ErrorAction SilentlyContinue) {
    Get-Nano11DefaultMigrationBackupPath -Base Documents
} else {
    # Only without Nano11Gui.ps1 (CLI use of a bundle that does not ship it)
    Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'nano11_migration_backup'
}
$script:HelpersPath = Find-Nano11MigratorFile @(
    (Join-Path $script:MigratorParent 'nano11helpers.ps1'), (Join-Path $script:MigratorDir 'nano11helpers.ps1'))
$script:LibPath = Find-Nano11MigratorFile @((Join-Path $script:MigratorDir 'Nano11Migration.ps1'))
$script:RulesPath = Find-Nano11MigratorFile @((Join-Path $script:MigratorDir 'migration-rules.psd1'))
$script:UserRulesPath = Find-Nano11MigratorFile @((Join-Path $script:MigratorDir 'user-migration-rules.psd1'))
if (-not $script:LibPath) { throw "Nano11Migration.ps1 not found next to '$script:MigratorDir'." }
if ($script:HelpersPath) { . $script:HelpersPath }
# Repo checkout: user rules live in config\user (an old config\ copy still works, with a warning)
if (-not $script:UserRulesPath -and (Get-Command -Name Resolve-Nano11UserConfigPath -ErrorAction SilentlyContinue)) {
    $ur = Resolve-Nano11UserConfigPath -RepoRoot $script:MigratorParent -Name 'user-migration-rules.psd1'
    if (Test-Path -LiteralPath $ur) { $script:UserRulesPath = $ur }
}
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
# GUI (handlers read state from $this / $this.FindForm().Tag, never from locals of the builder).
# Controls, colours, message boxes and the background-job loop come from gui\Nano11Gui.ps1.
# =========================================================================
function Add-MigLog {
    param($Form, [string]$Line)
    $Form.Tag.Log.AppendText($Line + [Environment]::NewLine)
}

# Runs this tool's CLI in a background job so the window stays responsive; returns the last result object.
# -Button is disabled and -Form shows the wait cursor while the job runs.
function Invoke-MigratorJob {
    param($Form, [hashtable]$Params, $Button)
    $o = Invoke-Nano11GuiBackgroundJob -Button $Button -Form $Form -ArgumentList $script:MigratorToolPath, $Params -ScriptBlock {
        param($tool, $p)
        & $tool @p
    }
    $result = $null
    $err = $o.Error
    if (-not $err -and @($o.Errors).Count -gt 0) { $err = $o.Errors[0] }
    if (-not $err) { $result = $o.Output | Where-Object { $_ -and $_.PSObject.Properties['Mode'] } | Select-Object -Last 1 }
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

# "ID - Name" rows for a rule list; rules with a cloud-save note get a [Cloud] mark
function Get-MigRuleRows {
    param($Rules)
    $rows = @()
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        $mark = if ($r.CloudSaveNotice) { '  [Cloud]' } else { '' }
        $rows += "$($r.Id) - $($r.Name)$mark"
    }
    return $rows
}

# Tab 1: Export / Backup
function New-MigBackupTab {
    param([hashtable]$Gui, $Tab, [string]$PackagePath)
    $c = $script:Nano11GuiColors
    [void](New-Nano11Label -Text 'Backup folder:' -X 12 -Y 16 -Width 95 -Height 20 -Parent $Tab)
    $Gui.BackupRoot = New-Nano11TextBox -X 110 -Y 13 -Width 580 -Height 24 -Text $PackagePath -ForeColor $c.Text -Parent $Tab
    $Gui.BackupRoot.Add_TextChanged({ Update-MigFreeSpace -Form $this.FindForm() })
    [void](New-Nano11Button -Text 'Browse...' -X 700 -Y 11 -Width 90 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $f.Tag.BackupRoot.Text = $d.SelectedPath }
    })
    $Gui.FreeLabel = New-Nano11Label -Text 'Free space: -' -X 110 -Y 40 -Width 580 -Height 20 -ForeColor $c.Accent -Parent $Tab

    [void](New-Nano11Label -Text 'Personal data folders:' -X 12 -Y 70 -Width 270 -Height 20 -Parent $Tab)
    $Gui.Folders = New-Nano11CheckedList -Items $Gui.KnownFolderNames -Selected @('Documents', 'Desktop', 'Pictures') -X 12 -Y 92 -Width 270 -Height 150 -Parent $Tab
    [void](New-Nano11Button -Text 'Add Custom Folder...' -X 12 -Y 246 -Width 270 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [void]$f.Tag.Folders.Items.Add($d.SelectedPath, $true) }
    })

    $rules = Get-MigratorRules
    [void](New-Nano11Label -Text 'Game save rules ([Cloud] = cloud save note)' -X 296 -Y 70 -Width 290 -Height 20 -Parent $Tab)
    $Gui.GameRules = New-Nano11CheckedList -Items (Get-MigRuleRows $rules.GameRules) -X 296 -Y 92 -Width 280 -Height 182 -Parent $Tab
    [void](New-Nano11Label -Text 'App settings rules' -X 590 -Y 70 -Width 270 -Height 20 -Parent $Tab)
    $Gui.AppRules = New-Nano11CheckedList -Items (Get-MigRuleRows $rules.AppConfigRules) -X 590 -Y 92 -Width 260 -Height 182 -Parent $Tab

    $Gui.ExcludeSecrets = New-Nano11CheckBox -Text 'Exclude credentials/tokens (Recommended)' -X 12 -Y 290 -Width 400 -Height 24 -Checked $true -Parent $Tab

    [void](New-Nano11Button -Text 'Estimate Size & Pre-flight Check' -X 12 -Y 328 -Width 300 -Height 36 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm()
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Estimate'
        Add-MigLog $f 'Estimating...'
        $o = Invoke-MigratorJob -Form $f -Params $s -Button $this
        if ($o.Error) { Add-MigLog $f "Error: $($o.Error)" }
        elseif ($o.Result) {
            $e = $o.Result.Estimate
            Add-MigLog $f ("Files: {0}, required {1} MB, free {2} MB, enough space: {3}" -f $e.TotalFiles, $e.TotalMB, $e.DestinationFreeMB, $e.HasEnoughSpace)
            if (@($e.RunningProcesses).Count -gt 0) { Add-MigLog $f ('Close these first: ' + (@($e.RunningProcesses) -join ', ')) }
        }
    })
    [void](New-Nano11Button -Text 'Start Backup & Verify (SHA-256)' -X 326 -Y 328 -Width 320 -Height 36 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm()
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Backup'
        Add-MigLog $f "Backup started: $($s.PackagePath)"
        $o = Invoke-MigratorJob -Form $f -Params $s -Button $this
        if ($o.Error) {
            Add-MigLog $f "Error: $($o.Error)"
            Show-Nano11GuiMessage -Text "Error: $($o.Error)" -Title 'Backup' -Kind Error
        } elseif ($o.Result) {
            Add-MigLog $f ('Backup finished. ' + $o.Result.Verify.Message)
            $f.Tag.RestoreRoot.Text = $s.PackagePath
            $rp = $o.Result.ReportPath
            if ($rp -and (Test-Path -LiteralPath $rp)) { Start-Process -FilePath $rp }
        }
    })
}

# Tab 2: Restore & Reinstall
function New-MigRestoreTab {
    param([hashtable]$Gui, $Tab, [string]$PackagePath)
    $c = $script:Nano11GuiColors
    [void](New-Nano11Label -Text 'Backup to restore:' -X 12 -Y 16 -Width 110 -Height 20 -Parent $Tab)
    $Gui.RestoreRoot = New-Nano11TextBox -X 125 -Y 13 -Width 565 -Height 24 -Text $PackagePath -ForeColor $c.Text -Parent $Tab
    [void](New-Nano11Button -Text 'Browse...' -X 700 -Y 11 -Width 90 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Select the folder that contains migration-manifest.json'
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-Path -LiteralPath (Join-Path $d.SelectedPath 'migration-manifest.json')) { $f.Tag.RestoreRoot.Text = $d.SelectedPath }
            else { Show-Nano11GuiMessage -Text 'migration-manifest.json was not found in that folder.' -Title 'Restore' -Kind Warning }
        }
    })
    [void](New-Nano11Label -Text 'If a file already exists:' -X 12 -Y 56 -Width 150 -Height 20 -Parent $Tab)
    $Gui.Policy = New-Nano11ComboBox -Items @('BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite') -SelectedIndex 0 -DropList `
        -X 165 -Y 53 -Width 300 -BackColor $c.Input -ForeColor $c.Text -Parent $Tab
    [void](New-Nano11Label -Text 'BackupExisting keeps the old file as .nano11.bak' -X 475 -Y 56 -Width 380 -Height 20 -Parent $Tab)

    $restoreHandler = {
        $f = $this.FindForm(); $g2 = $f.Tag; $kind = [string]$this.Tag
        $root = $g2.RestoreRoot.Text.Trim()
        if (-not (Test-Path -LiteralPath (Join-Path $root 'migration-manifest.json'))) {
            Show-Nano11GuiMessage -Text 'Select a backup folder that contains migration-manifest.json.' -Title 'Restore' -Kind Warning
            return
        }
        $p = @{ PackagePath = $root; ConflictPolicy = [string]$g2.Policy.SelectedItem }
        if ($kind -eq 'Verify') { $p.Mode = 'Verify' } else { $p.Mode = 'Restore'; if ($kind -eq 'Retry') { $p.RetryFailedOnly = $true } }
        Add-MigLog $f "$($p.Mode) ($kind) started: $root"
        $o = Invoke-MigratorJob -Form $f -Params $p -Button $this
        if ($o.Error) { Add-MigLog $f "Error: $($o.Error)" }
        elseif ($o.Result -and $p.Mode -eq 'Verify') { Add-MigLog $f $o.Result.Message }
        elseif ($o.Result) {
            foreach ($r in @($o.Result.Results)) { Add-MigLog $f ('  {0}: {1}' -f $r.TaskId, $r.Status) }
            if ($o.Result.ReportPath -and (Test-Path -LiteralPath $o.Result.ReportPath)) { Start-Process -FilePath $o.Result.ReportPath }
        }
    }
    [void](New-Nano11Button -Text 'Verify Backup Integrity' -X 12 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Verify' -OnClick $restoreHandler -Parent $Tab)
    [void](New-Nano11Button -Text 'Restore Selected Items' -X 256 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Restore' -OnClick $restoreHandler -Parent $Tab)
    [void](New-Nano11Button -Text 'Retry Failed Tasks Only' -X 500 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Retry' -OnClick $restoreHandler -Parent $Tab)
}

function Show-Nano11MigratorDialog {
    param([string]$PackagePath = '')
    if (-not (Get-Command -Name New-Nano11Form -ErrorAction SilentlyContinue)) {
        throw "gui\Nano11Gui.ps1 (shared WinForms parts) not found next to '$script:MigratorDir'. The Migration Assistant bundle must include it."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ([string]::IsNullOrWhiteSpace($PackagePath)) { $PackagePath = $script:DefaultPackagePath }
    $c = $script:Nano11GuiColors

    $form = New-Nano11Form -Text 'Nano11 PC Migration & Backup Wizard' -Width 900 -Height 680 -StartPosition CenterScreen `
        -BackColor $c.DialogAlt -ForeColor $c.Text
    $tabs = New-Nano11TabControl -X 8 -Y 8 -Width 868 -Height 470 -Parent $form
    $t1 = New-Nano11TabPage -Text 'Export / Backup' -TabControl $tabs -BackColor $c.DialogAlt
    $t2 = New-Nano11TabPage -Text 'Restore & Reinstall' -TabControl $tabs -BackColor $c.DialogAlt
    $log = New-Nano11TextBox -X 8 -Y 486 -Width 868 -Height 150 -Multiline -ReadOnly -ScrollBars Vertical -ForeColor $c.Text -Parent $form

    $g = @{ Log = $log; KnownFolderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads') }
    $form.Tag = $g

    New-MigBackupTab -Gui $g -Tab $t1 -PackagePath $PackagePath
    New-MigRestoreTab -Gui $g -Tab $t2 -PackagePath $PackagePath

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
