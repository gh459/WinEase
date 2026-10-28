#Requires -Version 5.1
<#
.SYNOPSIS
    WinEase-Migrator - Standalone PC migration and backup tool for WinEase.
.DESCRIPTION
    Backs up and restores user data, game saves and app configs between PCs.
    Runs from the repository (tools\ next to lib\) or from the ISO-bundled folder
    (this script, WinEasehelpers.ps1, WinEaseMigration.ps1 and config in one folder).
    With no -Mode the GUI opens.
.PARAMETER Mode
    ExportApps | Backup | Restore | Verify | Estimate (ListRules and RecoveryCheck are kept for older callers).
.PARAMETER PackagePath
    Folder the backup is written to / read from. Alias: BackupRoot.
.PARAMETER UserFolders
    Known personal folders to back up (Documents, Desktop, Pictures, Videos, Downloads, Music).
.PARAMETER CustomPaths
    Extra files/folders to back up. In -Mode Restore these are the locations the custom
    paths of the backup may be restored to: the manifest alone never decides where a
    file is written to, so without this list no custom path is restored.
.PARAMETER RuleIds
    Comma-separated migration rule IDs (game saves / app settings).
.PARAMETER ConflictPolicy
    Skip | BackupExisting | OverwriteIfNewer | Overwrite (default: BackupExisting)
.PARAMETER StopRunningProcess
    Restore: close running applications of a migration rule (close request, wait, then force) instead of skipping the rule.
.PARAMETER IncludeSecrets
    Include credential/token files in the backup (excluded by default).
.PARAMETER RetryFailedOnly
    Restore only the tasks that failed (or are still pending) last time.
.PARAMETER VerifyAfterBackup
    After a backup, re-read and re-hash every copied file (an extra full pass over the
    data). By default the backup reports the SHA-256 hashes recorded while copying and
    the full check stays available through -Mode Verify.
.PARAMETER DryRun
    Simulate without making changes.
.PARAMETER GUI
    Open the wizard window.
.PARAMETER UiLanguage
    Display language of the wizard window: en | ja (display only). Default: the choice saved by the WinEase GUI,
    else the OS display language.
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
    [switch]$StopRunningProcess,
    [switch]$RetryFailedOnly,
    [switch]$VerifyAfterBackup,
    [switch]$DryRun,
    [Parameter(ParameterSetName = 'CLI')]
    [string]$OutputPath = '',
    [Parameter(ParameterSetName = 'GUI')]
    [switch]$GUI,
    [ValidateSet('en', 'ja')]
    [string]$UiLanguage
)

$ErrorActionPreference = 'Stop'
$script:MigratorToolPath = $MyInvocation.MyCommand.Path
$script:MigratorDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Repository layout: <root>\tools\migrator (this script, engine, rules) + <root>\config\user (user rules) + <root>\WinEasehelpers.ps1.
# ISO bundle: everything in this folder.
function Find-WinEaseMigratorFile {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
$script:MigratorParent = Split-Path -Parent (Split-Path -Parent $script:MigratorDir)
# GUI core (language tables, default backup folder, debloat lists): lib\WinEaseGuiCore.ps1 in the repository,
# WinEaseGuiCore.ps1 in this folder when bundled. It has no WinForms part, so it is loaded on its own first.
$script:GuiCorePath = Find-WinEaseMigratorFile @(
    (Join-Path $script:MigratorParent 'lib\WinEaseGuiCore.ps1'), (Join-Path $script:MigratorDir 'WinEaseGuiCore.ps1'))
if ($script:GuiCorePath) { . $script:GuiCorePath }
# Shared WinForms parts and colour table: gui\WinEaseGui.ps1 in the repository, WinEaseGui.ps1 in this folder
# when bundled. Loaded before the helpers and the engine so those win any name clash.
$script:GuiPartsPath = Find-WinEaseMigratorFile @(
    (Join-Path $script:MigratorParent 'gui\WinEaseGui.ps1'), (Join-Path $script:MigratorDir 'WinEaseGui.ps1'))
if ($script:GuiPartsPath) { . $script:GuiPartsPath }
# The image ships a ready backup at C:\WinEaseBackup. Prefer it when it is a real
# backup (a manifest is present), otherwise fall back to the folder the build GUI
# uses on the source machine. Restore itself is always started by the user.
$script:BundledMigrationBackupPath = 'C:\WinEaseBackup'
$script:DefaultPackagePath = if (Test-Path -LiteralPath (Join-Path $script:BundledMigrationBackupPath 'migration-manifest.json')) {
    $script:BundledMigrationBackupPath
} elseif (Get-Command -Name Get-WinEaseDefaultMigrationBackupPath -ErrorAction SilentlyContinue) {
    Get-WinEaseDefaultMigrationBackupPath -Base Profile
} else {
    # Only without WinEaseGuiCore.ps1 (CLI use of a bundle that does not ship it)
    Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath 'WinEase_migration_backup'
}
$script:HelpersPath = Find-WinEaseMigratorFile @(
    (Join-Path $script:MigratorParent 'WinEasehelpers.ps1'), (Join-Path $script:MigratorDir 'WinEasehelpers.ps1'))
$script:LibPath = Find-WinEaseMigratorFile @((Join-Path $script:MigratorDir 'WinEaseMigration.ps1'))
$script:RulesPath = Find-WinEaseMigratorFile @((Join-Path $script:MigratorDir 'migration-rules.psd1'))
$script:UserRulesPath = Find-WinEaseMigratorFile @((Join-Path $script:MigratorDir 'user-migration-rules.psd1'))
if (-not $script:LibPath) { throw "WinEaseMigration.ps1 not found next to '$script:MigratorDir'." }
if ($script:HelpersPath) { . $script:HelpersPath }
# Repo checkout: user rules live in config\user (an old config\ copy still works, with a warning)
if (-not $script:UserRulesPath -and (Get-Command -Name Resolve-WinEaseUserConfigPath -ErrorAction SilentlyContinue)) {
    $ur = Resolve-WinEaseUserConfigPath -RepoRoot $script:MigratorParent -Name 'user-migration-rules.psd1'
    if (Test-Path -LiteralPath $ur) { $script:UserRulesPath = $ur }
}
. $script:LibPath

function Get-MigratorRules {
    $a = @{}
    if ($script:RulesPath) { $a.BuiltInPath = $script:RulesPath }
    if ($script:UserRulesPath) { $a.UserPath = $script:UserRulesPath }
    return (Get-WinEaseMigrationRules @a)
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
            '^Saved Games$' { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Saved Games' }
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
    $paths = [System.Collections.Generic.List[string]]::new()
    $procs = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $all) {
        if ($Ids -contains $rule.Id) {
            foreach ($sp in @($rule.SourcePaths)) { if ($sp) { $paths.Add($sp) } }
            foreach ($pn in @($rule.ProcessNames)) { if ($pn) { $procs.Add($pn) } }
        }
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
    $checked = 0; $nohash = 0
    $bad = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($m.Entries)) {
        if (-not $e -or -not $e.RelativePath) { continue }
        $sub = if ($e.Category -eq 'CustomPath') { 'Custom' } else { [string]$e.Category }
        $f = Join-Path (Join-Path $Root $sub) ([string]$e.RelativePath)
        if (-not (Test-Path -LiteralPath $f)) { $missing.Add($f); continue }
        if (-not $e.Sha256) { $nohash++; continue }
        $checked++
        if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne [string]$e.Sha256) { $bad.Add($f) }
    }
    $ok = ($bad.Count -eq 0 -and $missing.Count -eq 0)
    $msg = "Verified $checked file(s): $($bad.Count) mismatched, $($missing.Count) missing, $nohash without hash."
    return [PSCustomObject]@{ Mode = 'Verify'; Success = $ok; Checked = $checked; Mismatched = @($bad); Missing = @($missing); NoHash = $nohash; Message = $msg }
}

function Get-MigratorEstimate {
    param([string]$Root, [string[]]$FolderPaths, [string[]]$Custom, [string[]]$Ids)
    $src = Get-MigratorRuleSources -Ids $Ids
    $est = Get-WinEaseMigrationSizeEstimate -UserFolderPaths (@($FolderPaths) + @($Custom) + @($src.Paths)) -SelectedRuleIds $Ids -DestinationPath $Root
    $running = [System.Collections.Generic.List[string]]::new()
    foreach ($pn in $src.ProcessNames) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $running.Add($pn) } }
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
# Controls, colours, message boxes and the background-job loop come from gui\WinEaseGui.ps1.
# =========================================================================
function Add-MigLog {
    param($Form, [string]$Line)
    $Form.Tag.Log.AppendText($Line + [Environment]::NewLine)
}

# Runs this tool's CLI in a background job so the window stays responsive; returns the last result object.
# -Button is disabled and -Form shows the wait cursor while the job runs.
function Invoke-MigratorJob {
    param($Form, [hashtable]$Params, $Button)
    $o = Invoke-WinEaseGuiBackgroundJob -Button $Button -Form $Form -ArgumentList $script:MigratorToolPath, $Params -ScriptBlock {
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
    $g.FreeLabel.Text = Get-WinEaseUiString 'Migrator.Free.None'
    try {
        $root = [System.IO.Path]::GetPathRoot($g.BackupRoot.Text.Trim())
        if ($root) {
            $di = New-Object System.IO.DriveInfo($root)
            if ($di.IsReady) { $g.FreeLabel.Text = Get-WinEaseUiString 'Migrator.Free.Value' -Format $di.Name, ([math]::Round($di.AvailableFreeSpace / 1GB, 1)) }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

function Get-MigSelection {
    param($Form)
    $g = $Form.Tag
    $known = [System.Collections.Generic.List[string]]::new()
    $custom = [System.Collections.Generic.List[string]]::new()
    foreach ($i in $g.Folders.CheckedItems) {
        if ($g.KnownFolderNames -contains [string]$i) { $known.Add([string]$i) } else { $custom.Add([string]$i) }
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($lb in @($g.GameRules, $g.AppRules)) {
        if ($lb) {
            foreach ($i in $lb.CheckedItems) { $ids.Add((([string]$i -split ' - ')[0]).Trim()) }
        }
    }
    $root = $g.BackupRoot.Text.Trim()
    if (-not $root) { $root = $script:DefaultPackagePath; $g.BackupRoot.Text = $root }
    return @{ PackagePath = $root; UserFolders = @($known); CustomPaths = @($custom); RuleIds = ($ids -join ','); IncludeSecrets = (-not $g.ExcludeSecrets.Checked) }
}

# "ID - Name" rows for a rule list; rules with a cloud-save note get a [Cloud] mark
function Get-MigRuleRows {
    param($Rules)
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        $mark = if ($r.CloudSaveNotice) { '  [Cloud]' } else { '' }
        $rows.Add("$($r.Id) - $($r.Name)$mark")
    }
    return @($rows)
}

# Tab 1: Export / Backup
function New-MigBackupTab {
    param([hashtable]$Gui, $Tab, [string]$PackagePath)
    $c = $script:WinEaseGuiColors
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.BackupFolder') -X 12 -Y 16 -Width 95 -Height 20 -Parent $Tab)
    $Gui.BackupRoot = New-WinEaseTextBox -X 110 -Y 13 -Width 580 -Height 24 -Text $PackagePath -ForeColor $c.Text -Parent $Tab
    $Gui.BackupRoot.Add_TextChanged({ Update-MigFreeSpace -Form $this.FindForm() })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Browse') -X 700 -Y 11 -Width 90 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $f.Tag.BackupRoot.Text = $d.SelectedPath }
    })
    $Gui.FreeLabel = New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Free.None') -X 110 -Y 40 -Width 580 -Height 20 -ForeColor $c.Accent -Parent $Tab

    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.Folders') -X 12 -Y 70 -Width 270 -Height 20 -Parent $Tab)
    $Gui.Folders = New-WinEaseCheckedList -Items $Gui.KnownFolderNames -Selected @('Documents', 'Desktop', 'Pictures') -X 12 -Y 92 -Width 270 -Height 150 -Parent $Tab
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Migrator.Button.AddFolder') -X 12 -Y 246 -Width 270 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [void]$f.Tag.Folders.Items.Add($d.SelectedPath, $true) }
    })

    $rules = Get-MigratorRules
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.GameRules') -X 296 -Y 70 -Width 290 -Height 20 -Parent $Tab)
    $Gui.GameRules = New-WinEaseCheckedList -Items (Get-MigRuleRows $rules.GameRules) -X 296 -Y 92 -Width 280 -Height 182 -Parent $Tab
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.AppRules') -X 590 -Y 70 -Width 270 -Height 20 -Parent $Tab)
    $Gui.AppRules = New-WinEaseCheckedList -Items (Get-MigRuleRows $rules.AppConfigRules) -X 590 -Y 92 -Width 260 -Height 182 -Parent $Tab

    $Gui.ExcludeSecrets = New-WinEaseCheckBox -Text (Get-WinEaseUiString 'Mig.Check.ExcludeSecrets') -X 12 -Y 290 -Width 400 -Height 24 -Checked $true -Parent $Tab

    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Migrator.Button.Estimate') -X 12 -Y 328 -Width 300 -Height 36 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm()
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Estimate'
        Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.Estimating')
        $o = Invoke-MigratorJob -Form $f -Params $s -Button $this
        if ($o.Error) { Add-MigLog $f (Get-WinEaseUiString 'Msg.Error' -Format $o.Error) }
        elseif ($o.Result) {
            $e = $o.Result.Estimate
            Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.Estimate' -Format $e.TotalFiles, $e.TotalMB, $e.DestinationFreeMB, $e.HasEnoughSpace)
            if (@($e.RunningProcesses).Count -gt 0) { Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.CloseFirst' -Format (@($e.RunningProcesses) -join ', ')) }
        }
    })
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Migrator.Button.Backup') -X 326 -Y 328 -Width 320 -Height 36 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm()
        $s = Get-MigSelection -Form $f
        $s.Mode = 'Backup'
        Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.BackupStarted' -Format $s.PackagePath)
        $o = Invoke-MigratorJob -Form $f -Params $s -Button $this
        if ($o.Error) {
            Add-MigLog $f (Get-WinEaseUiString 'Msg.Error' -Format $o.Error)
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Msg.Error' -Format $o.Error) -Title (Get-WinEaseUiString 'Mig.Backup.Title') -Kind Error
        } elseif ($o.Result) {
            Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.BackupFinished' -Format $o.Result.Verify.Message)
            $f.Tag.RestoreRoot.Text = $s.PackagePath
            $rp = $o.Result.ReportPath
            if ($rp -and (Test-Path -LiteralPath $rp)) { [void](Open-WinEaseFileSafe -Path $rp) }
        }
    })
}

# Tab 2: Restore & Reinstall
function New-MigRestoreTab {
    param([hashtable]$Gui, $Tab, [string]$PackagePath)
    $c = $script:WinEaseGuiColors
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.RestoreRoot') -X 12 -Y 16 -Width 110 -Height 20 -Parent $Tab)
    $Gui.RestoreRoot = New-WinEaseTextBox -X 125 -Y 13 -Width 565 -Height 24 -Text $PackagePath -ForeColor $c.Text -Parent $Tab
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Button.Browse') -X 700 -Y 11 -Width 90 -Height 28 -ForeColor $c.Text -Parent $Tab -OnClick {
        $f = $this.FindForm(); $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = Get-WinEaseUiString 'Migrator.Dialog.RestoreFolder'
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-Path -LiteralPath (Join-Path $d.SelectedPath 'migration-manifest.json')) { $f.Tag.RestoreRoot.Text = $d.SelectedPath }
            else { Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Migrator.Msg.ManifestMissingInFolder') -Title (Get-WinEaseUiString 'Mig.Restore.Title') -Kind Warning }
        }
    })
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Label.Policy') -X 12 -Y 56 -Width 150 -Height 20 -Parent $Tab)
    $Gui.Policy = New-WinEaseComboBox -Items @('BackupExisting', 'Skip', 'OverwriteIfNewer', 'Overwrite') -SelectedIndex 0 -DropList `
        -X 165 -Y 53 -Width 300 -BackColor $c.Input -ForeColor $c.Text -Parent $Tab
    [void](New-WinEaseLabel -Text (Get-WinEaseUiString 'Migrator.Note.Policy') -X 475 -Y 56 -Width 380 -Height 20 -Parent $Tab)

    $restoreHandler = {
        $f = $this.FindForm(); $g2 = $f.Tag; $kind = [string]$this.Tag
        $root = $g2.RestoreRoot.Text.Trim()
        if (-not (Test-Path -LiteralPath (Join-Path $root 'migration-manifest.json'))) {
            Show-WinEaseGuiMessage -Text (Get-WinEaseUiString 'Migrator.Msg.SelectBackup') -Title (Get-WinEaseUiString 'Mig.Restore.Title') -Kind Warning
            return
        }
        $p = @{ PackagePath = $root; ConflictPolicy = [string]$g2.Policy.SelectedItem }
        if ($kind -eq 'Verify') { $p.Mode = 'Verify' } else { $p.Mode = 'Restore'; if ($kind -eq 'Retry') { $p.RetryFailedOnly = $true } }
        Add-MigLog $f (Get-WinEaseUiString 'Migrator.Log.Started' -Format $p.Mode, $kind, $root)
        $o = Invoke-MigratorJob -Form $f -Params $p -Button $this
        if ($o.Error) { Add-MigLog $f (Get-WinEaseUiString 'Msg.Error' -Format $o.Error) }
        elseif ($o.Result -and $p.Mode -eq 'Verify') { Add-MigLog $f $o.Result.Message }
        elseif ($o.Result) {
            foreach ($r in @($o.Result.Results)) { Add-MigLog $f ('  {0}: {1}' -f $r.TaskId, $r.Status) }
            if ($o.Result.ReportPath -and (Test-Path -LiteralPath $o.Result.ReportPath)) { [void](Open-WinEaseFileSafe -Path $o.Result.ReportPath) }
        }
    }
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Verify') -X 12 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Verify' -OnClick $restoreHandler -Parent $Tab)
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Migrator.Button.Restore') -X 256 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Restore' -OnClick $restoreHandler -Parent $Tab)
    [void](New-WinEaseButton -Text (Get-WinEaseUiString 'Mig.Button.Retry') -X 500 -Y 100 -Width 230 -Height 36 -ForeColor $c.Text -Tag 'Retry' -OnClick $restoreHandler -Parent $Tab)
}

# Window content: tabs, log and language selector. Everything here is added to $Form and can be removed and built
# again, which is how the display language is switched (Switch-MigratorLanguage keeps the entered state).
function Initialize-MigratorContent {
    param($Form, [string]$PackagePath)
    $c = $script:WinEaseGuiColors
    $g = $Form.Tag
    $Form.Text = Get-WinEaseUiString 'Migrator.Title'
    $tabs = New-WinEaseTabControl -X 8 -Y 8 -Width 868 -Height 470 -Parent $Form
    $t1 = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Migrator.Tab.Backup') -TabControl $tabs -BackColor $c.DialogAlt
    $t2 = New-WinEaseTabPage -Text (Get-WinEaseUiString 'Migrator.Tab.Restore') -TabControl $tabs -BackColor $c.DialogAlt
    $g.Log = New-WinEaseTextBox -X 8 -Y 486 -Width 868 -Height 150 -Multiline -ReadOnly -ScrollBars Vertical -ForeColor $c.Text -Parent $Form
    $g.Tabs = $tabs

    New-MigBackupTab -Gui $g -Tab $t1 -PackagePath $PackagePath
    New-MigRestoreTab -Gui $g -Tab $t2 -PackagePath $PackagePath

    # Display language selector, drawn over the empty right part of the tab strip
    $lblLang = New-WinEaseLabel -Text (Get-WinEaseUiString 'Main.Language') -X 560 -Y 11 -Width 150 -Height 20 -ForeColor $c.Muted -Parent $Form
    $lblLang.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $langNames = @($script:WinEaseUiLanguages | ForEach-Object { Get-WinEaseUiString 'Language.Name' -Language $_ -Default $_ })
    $cmbLang = New-WinEaseComboBox -Items $langNames -SelectedIndex ([array]::IndexOf($script:WinEaseUiLanguages, $script:WinEaseUiLanguage)) -DropList `
        -X 716 -Y 8 -Width 160 -BackColor $c.Input -ForeColor $c.Text -Parent $Form
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
            Switch-MigratorLanguage -Form $owner
        })
        $timer.Start()
    })
    $lblLang.BringToFront()
    $cmbLang.BringToFront()
    $g.Language = $cmbLang

    Update-MigFreeSpace -Form $Form
}

# Show the window in another display language. It is built again from what is entered now
# (folders, checked rules, paths, policy, log), so nothing is lost. -Language defaults to PendingLanguage.
function Switch-MigratorLanguage {
    param($Form, [string]$Language)
    $g = $Form.Tag
    if (-not $Language) { $Language = "$($g.PendingLanguage)" }
    if ($script:WinEaseUiLanguages -notcontains $Language -or $Language -eq $script:WinEaseUiLanguage) { return }
    $folders = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $g.Folders.Items.Count; $i++) { $folders.Add(@("$($g.Folders.Items[$i])", $g.Folders.GetItemChecked($i))) }
    $checkedRules = [System.Collections.Generic.List[string]]::new()
    foreach ($lb in @($g.GameRules, $g.AppRules)) {
        if ($lb) {
            foreach ($i in $lb.CheckedItems) { $checkedRules.Add("$i") }
        }
    }
    $state = @{
        BackupRoot = $g.BackupRoot.Text; RestoreRoot = $g.RestoreRoot.Text; Policy = $g.Policy.SelectedIndex
        ExcludeSecrets = [bool]$g.ExcludeSecrets.Checked; Folders = $folders; Rules = $checkedRules
        Log = $g.Log.Text; Tab = $g.Tabs.SelectedIndex
    }
    Set-WinEaseUiLanguage -Language $Language
    Save-WinEaseGuiLanguage -Language $Language
    $Form.SuspendLayout()
    try {
        $old = @($Form.Controls | ForEach-Object { $_ })
        $Form.Controls.Clear()
        foreach ($ctl in $old) { $ctl.Dispose() }
        foreach ($k in @($g.Keys)) { if (@('KnownFolderNames') -notcontains $k) { $g.Remove($k) } }
        Initialize-MigratorContent -Form $Form -PackagePath $state.BackupRoot
        $g.RestoreRoot.Text = $state.RestoreRoot
        $g.Policy.SelectedIndex = $state.Policy
        $g.ExcludeSecrets.Checked = $state.ExcludeSecrets
        $g.Folders.Items.Clear()
        foreach ($f in $state.Folders) { [void]$g.Folders.Items.Add($f[0], [bool]$f[1]) }
        foreach ($lb in @($g.GameRules, $g.AppRules)) {
            for ($i = 0; $i -lt $lb.Items.Count; $i++) { $lb.SetItemChecked($i, ($state.Rules -contains "$($lb.Items[$i])")) }
        }
        $g.Log.Text = $state.Log
        $g.Log.SelectionStart = $g.Log.Text.Length
        if ($state.Tab -ge 0 -and $state.Tab -lt $g.Tabs.TabPages.Count) { $g.Tabs.SelectedIndex = $state.Tab }
    } finally {
        $Form.ResumeLayout($true)
    }
}

# -NoShow returns the form without showing it (for tests)
function Show-WinEaseMigratorDialog {
    param([string]$PackagePath = '', [string]$UiLanguage, [switch]$NoShow)
    if (-not (Get-Command -Name New-WinEaseForm -ErrorAction SilentlyContinue)) {
        throw "gui\WinEaseGui.ps1 (shared WinForms parts) not found next to '$script:MigratorDir'. The Migration Assistant bundle must include it."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ([string]::IsNullOrWhiteSpace($PackagePath)) { $PackagePath = $script:DefaultPackagePath }
    $c = $script:WinEaseGuiColors
    Set-WinEaseUiLanguage -Language (Resolve-WinEaseUiLanguage -Requested $UiLanguage)

    $form = New-WinEaseForm -Text (Get-WinEaseUiString 'Migrator.Title') -Width 900 -Height 680 -StartPosition CenterScreen `
        -BackColor $c.DialogAlt -ForeColor $c.Text
    $form.Tag = @{ KnownFolderNames = @('Documents', 'Desktop', 'Pictures', 'Videos', 'Downloads') }
    Initialize-MigratorContent -Form $form -PackagePath $PackagePath
    if ($NoShow) { return $form }
    [void]$form.ShowDialog()
}


# =========================================================================
# Entry point
# =========================================================================
if ($PSCmdlet.ParameterSetName -eq 'GUI') {
    Write-Verbose "Opening GUI (-GUI: $GUI)"
    Show-WinEaseMigratorDialog -PackagePath $PackagePath -UiLanguage $UiLanguage
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
        if (@($rules.Errors).Count -gt 0) {
            Write-Host '=== Rule load errors ===' -ForegroundColor Yellow
            $rules.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
    }
    'ExportApps' {
        $out = if ($OutputPath) { $OutputPath } else { Join-Path $PackagePath 'apps-inventory.json' }
        $r = Export-WinEaseAppInventory -OutputPath $out
        Write-Host "Exported $($r.TotalApps) apps ($($r.AutoInstallable) auto-installable) to $out" -ForegroundColor Green
        [PSCustomObject]@{ Mode = 'ExportApps'; OutputPath = $out; TotalApps = $r.TotalApps }
    }
    'RecoveryCheck' {
        $rr = Test-WinEaseRecoveryReadiness -Config @{}
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
        $result = Start-WinEaseMigrationBackup -FolderMap $folderMap -BackupRoot $PackagePath -RuleIds $idList -CustomPaths $CustomPaths -IncludeSecrets:$IncludeSecrets -DryRun:$DryRun
        $verify = [PSCustomObject]@{ Success = $true; Message = 'DryRun: nothing to verify.' }
        $report = $null
        if (-not $DryRun) {
            # The SHA-256 of every copied file was recorded while copying (one read per
            # file). Re-reading and re-hashing everything only happens on request: the
            # full check is -Mode Verify / the GUI verify button, or -VerifyAfterBackup.
            if ($VerifyAfterBackup) {
                $verify = Test-MigratorBackupIntegrity -Root $PackagePath
            } else {
                $failedCount = 0
                foreach ($part in @($result.UserData, $result.CustomResult, $result.RulesResult)) {
                    if ($part -and $part.FailedFiles) {
                        foreach ($f in $part.FailedFiles) {
                            if ($f) { $failedCount++ }
                        }
                    }
                }
                $verified = @(Get-WinEaseMigrationManifestEntries -BackupRoot $PackagePath | Where-Object { $_ -and $_.Sha256 }).Count
                $ruleFiles = 0
                $ruleCount = 0
                if ($result.RulesResult) {
                    foreach ($b in @($result.RulesResult.BackedUpRules)) { $ruleFiles += [int]$b.FileCount }
                    $ruleCount = @($result.RulesResult.BackedUpRules).Count
                }
                $message = ('{0} data file(s) recorded with SHA-256 during the copy' -f $verified)
                if ($ruleCount -gt 0) { $message += ('; {0} further file(s) from {1} migration rule(s) copied as-is' -f $ruleFiles, $ruleCount) }
                $message += '. Run -Mode Verify for a full integrity check.'
                $verify = [PSCustomObject]@{
                    Success = ($failedCount -eq 0)
                    Checked = $verified
                    Message = $message
                }
            }
            $report = Join-Path $PackagePath 'migration-report.html'
            Write-Host "Backup completed. Manifest: $(Join-Path $PackagePath 'migration-manifest.json')" -ForegroundColor Green
            Write-Host $verify.Message
            Write-Host "Report: $report" -ForegroundColor Cyan
        }
        [PSCustomObject]@{ Mode = 'Backup'; Success = $verify.Success; Verify = $verify; ReportPath = $report; Manifest = $result }
    }
    'Restore' {
        $restoreArgs = @{ BackupRoot = $PackagePath; ConflictPolicy = $ConflictPolicy; RetryFailedOnly = [bool]$RetryFailedOnly; DryRun = [bool]$DryRun }
        if ($StopRunningProcess) { $restoreArgs['StopRunningProcess'] = $true }
        # The custom paths of the backup are only restored to the locations that are
        # named here. Without the list the custom path tasks are skipped.
        $allowed = @($CustomPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($allowed.Count -gt 0) { $restoreArgs['AllowedCustomPaths'] = $allowed }
        $result = Start-WinEaseMigrationRestore @restoreArgs
        Write-Host 'Restore completed.' -ForegroundColor Green
        $result.Results | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.TaskId, $_.Status) }
        $report = $null
        if (-not $DryRun) {
            $report = Join-Path $PackagePath 'migration-report.html'
            try { [void](Export-WinEaseMigrationReport -MigrationResult $result -ReportPath $report) } catch { Write-Warning "Report not written: $($_.Exception.Message)"; $report = $null }
        }
        [PSCustomObject]@{ Mode = 'Restore'; Results = @($result.Results); ReportPath = $report }
    }
}
