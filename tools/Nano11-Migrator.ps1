#Requires -Version 5.1

param(
    [ValidateSet('Backup','Restore','ExportApps','ListRules','RecoveryCheck')]
    [string]$Mode = 'Backup',
    [string]$BackupRoot = '',
    [string]$RuleIds = '',
    [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
    [string]$ConflictPolicy = 'BackupExisting',
    [switch]$IncludeSecrets,
    [switch]$RetryFailedOnly,
    [switch]$DryRun,
    [string]$OutputPath = '',
    [string[]]$CustomPaths = @(),
    [switch]$GUI
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-Nano11MigratorDialog {
    param(
        [string]$BackupRoot = (Join-Path $env:USERPROFILE "Documents\nano11_migration_backup")
    )
    $repoRoot = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'lib\Nano11Migration.ps1'))) {
        $repoRoot = $PSScriptRoot
    }
    . (Join-Path $repoRoot 'lib\Nano11Migration.ps1')

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nano11 PC Migration & Backup Wizard"
    $form.Size = New-Object System.Drawing.Size(700, 520)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White

    $lblRoot = New-Object System.Windows.Forms.Label
    $lblRoot.Text = "Backup Root:"
    $lblRoot.Location = New-Object System.Drawing.Point(15, 15)
    $lblRoot.Size = New-Object System.Drawing.Size(90, 20)
    $form.Controls.Add($lblRoot)

    $txtRoot = New-Object System.Windows.Forms.TextBox
    $txtRoot.Text = $BackupRoot
    $txtRoot.Location = New-Object System.Drawing.Point(110, 13)
    $txtRoot.Size = New-Object System.Drawing.Size(400, 24)
    $txtRoot.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $txtRoot.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtRoot)

    $lblRules = New-Object System.Windows.Forms.Label
    $lblRules.Text = "Select migration rules:"
    $lblRules.Location = New-Object System.Drawing.Point(15, 45)
    $lblRules.Size = New-Object System.Drawing.Size(200, 20)
    $form.Controls.Add($lblRules)

    $clbRules = New-Object System.Windows.Forms.CheckedListBox
    $clbRules.Location = New-Object System.Drawing.Point(15, 70)
    $clbRules.Size = New-Object System.Drawing.Size(400, 250)
    $clbRules.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $clbRules.ForeColor = [System.Drawing.Color]::White
    $clbRules.CheckOnClick = $true
    $rules = Get-Nano11MigrationRules
    foreach ($r in ($rules.GameRules + $rules.AppConfigRules + $rules.CustomPathRules)) {
        [void]$clbRules.Items.Add("$($r.Id) - $($r.Name)")
    }
    $form.Controls.Add($clbRules)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Ready."
    $lblStatus.Location = New-Object System.Drawing.Point(15, 330)
    $lblStatus.Size = New-Object System.Drawing.Size(660, 40)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $form.Controls.Add($lblStatus)

    $btnBackup = New-Object System.Windows.Forms.Button
    $btnBackup.Text = "Run Backup"
    $btnBackup.Location = New-Object System.Drawing.Point(430, 70)
    $btnBackup.Size = New-Object System.Drawing.Size(120, 32)
    $btnBackup.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBackup.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnBackup.ForeColor = [System.Drawing.Color]::White
    $btnBackup.Add_Click({
        $btnBackup.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $root = $txtRoot.Text.Trim()
            if (-not $root) { $root = Join-Path $env:USERPROFILE "Documents\nano11_migration_backup" }
            $selectedRules = @()
            foreach ($item in $clbRules.CheckedItems) { $selectedRules += ($item -split ' - ')[0].Trim() }
            $result = Start-Nano11MigrationBackup -BackupRoot $root -RuleIds $selectedRules
            $lblStatus.Text = "Backup completed: $($result.BackupRoot)"
            [void][System.Windows.Forms.MessageBox]::Show("Backup completed.`nManifest: $($result.BackupRoot)\migration-manifest.json", "Backup", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Backup", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $btnBackup.Enabled = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $form.Controls.Add($btnBackup)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Run Restore"
    $btnRestore.Location = New-Object System.Drawing.Point(430, 110)
    $btnRestore.Size = New-Object System.Drawing.Size(120, 32)
    $btnRestore.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRestore.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnRestore.ForeColor = [System.Drawing.Color]::White
    $btnRestore.Add_Click({
        $btnRestore.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $root = $txtRoot.Text.Trim()
            if (-not $root) { $root = Join-Path $env:USERPROFILE "Documents\nano11_migration_backup" }
            $result = Start-Nano11MigrationRestore -BackupRoot $root -ConflictPolicy BackupExisting
            $msg = "Restore completed.`n" + ($result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String)
            [void][System.Windows.Forms.MessageBox]::Show($msg, "Restore", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $lblStatus.Text = "Restore completed."
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Restore", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $btnRestore.Enabled = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $form.Controls.Add($btnRestore)

    $btnRecovery = New-Object System.Windows.Forms.Button
    $btnRecovery.Text = "Recovery Check"
    $btnRecovery.Location = New-Object System.Drawing.Point(430, 150)
    $btnRecovery.Size = New-Object System.Drawing.Size(120, 32)
    $btnRecovery.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRecovery.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnRecovery.ForeColor = [System.Drawing.Color]::White
    $btnRecovery.Add_Click({
        try {
            $rr = Test-Nano11RecoveryReadiness -Config @{}
            $msg = "Readiness Score: $($rr.ReadinessScore)`nSecondary Drives: $($rr.SecondaryDrives -join ', ')`nSystem Restore: $($rr.SystemRestoreEnabled)`nWinRE on target: $($rr.WinReEnabledOnTarget)`n`n$($rr.Recommendations -join "`n")"
            [void][System.Windows.Forms.MessageBox]::Show($msg, "Recovery Readiness", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Recovery Readiness", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($btnRecovery)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "Export Apps"
    $btnExport.Location = New-Object System.Drawing.Point(430, 190)
    $btnExport.Size = New-Object System.Drawing.Size(120, 32)
    $btnExport.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnExport.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnExport.ForeColor = [System.Drawing.Color]::White
    $btnExport.Add_Click({
        $btnExport.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $outPath = Join-Path $env:USERPROFILE "Documents\apps-inventory.json"
            Export-Nano11AppInventory -OutputPath $outPath
            [void][System.Windows.Forms.MessageBox]::Show("App inventory exported to:`n$outPath", "Export Apps", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Export Apps", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $btnExport.Enabled = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })
    $form.Controls.Add($btnExport)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(560, 440)
    $btnClose.Size = New-Object System.Drawing.Size(100, 32)
    $btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)

    [void]$form.ShowDialog()
}

# CLI entry point (when run directly)
if ($MyInvocation.InvocationName -ne '.' -and -not $MyInvocation.Line.Contains('Show-Nano11MigratorDialog')) {
    # CLI mode
}
<#
.SYNOPSIS
    Nano11-Migrator - Standalone PC migration and backup tool for nano11.
.DESCRIPTION
    Backs up and restores user data, game saves and app configs between PCs.
    Can be run standalone or bundled into a nano11 image.
.PARAMETER Mode
    Backup | Restore | ExportApps | ListRules | RecoveryCheck
.PARAMETER BackupRoot
    Root directory for backup/restore operations.
.PARAMETER RuleIds
    Comma-separated migration rule IDs to include.
.PARAMETER ConflictPolicy
    Skip | BackupExisting | OverwriteIfNewer | Overwrite (default: BackupExisting)
.PARAMETER IncludeSecrets
    Include secret files (cookies, credentials, etc.) in backup.
.PARAMETER RetryFailedOnly
    Only retry previously failed restore tasks.
.PARAMETER DryRun
    Simulate without making changes.
#>

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$repoRoot = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'lib\Nano11Migration.ps1'))) {
    $repoRoot = $scriptDir
}
. (Join-Path $repoRoot 'lib\Nano11Migration.ps1')

if (-not $BackupRoot) { $BackupRoot = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\nano11_migration_backup' }

if ($GUI) {
    Show-Nano11MigratorDialog -BackupRoot $BackupRoot
    return
}

switch ($Mode) {
    'ListRules' {
        $rules = Get-Nano11MigrationRules
        Write-Host "=== Game Rules ===" -ForegroundColor Cyan
        $rules.GameRules | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Id, $_.Name) }
        Write-Host "=== App Config Rules ===" -ForegroundColor Cyan
        $rules.AppConfigRules | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Id, $_.Name) }
    }
    'ExportApps' {
        $out = if ($OutputPath) { $OutputPath } else { Join-Path $BackupRoot 'apps-inventory.json' }
        $r = Export-Nano11AppInventory -OutputPath $out
        Write-Host "Exported $($r.TotalApps) apps ($($r.AutoInstallable) auto-installable) to $out" -ForegroundColor Green
    }
    'RecoveryCheck' {
        . (Join-Path $repoRoot 'nano11builder.ps1' -ErrorAction SilentlyContinue) 2>$null
        # recovery check doesn't need builder; just run with empty config
        $rr = Test-Nano11RecoveryReadiness -Config @{}
        Write-Host "Readiness Score: $($rr.ReadinessScore)" -ForegroundColor Cyan
        Write-Host "Secondary Drives: $($rr.SecondaryDrives -join ', ')"
        Write-Host "System Restore: $($rr.SystemRestoreEnabled)"
        Write-Host "WinRE on target: $($rr.WinReEnabledOnTarget)"
        Write-Host "Migration backup found: $($rr.MigrationBackupFound)"
        $rr.Recommendations | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    'Backup' {
        $ruleIds = if ($RuleIds) { $RuleIds -split ',' | ForEach-Object { $_.Trim() } } else { @() }
        $result = Start-Nano11MigrationBackup -BackupRoot $BackupRoot -RuleIds $ruleIds -IncludeSecrets:$IncludeSecrets -DryRun:$DryRun
        if ($CustomPaths -and $CustomPaths.Count -gt 0) {
            $cpResult = Backup-Nano11CustomPaths -Paths $CustomPaths -BackupRoot $BackupRoot -DryRun:$DryRun
            Write-Host "Custom paths: $($cpResult.CopiedFiles) files copied." -ForegroundColor Green
        }
        Write-Host "Backup completed. Manifest: $($BackupRoot)\migration-manifest.json" -ForegroundColor Green
        Export-Nano11MigrationReport -MigrationResult $result -ReportPath (Join-Path $BackupRoot 'migration-report.html')
        Write-Host "Report: $(Join-Path $BackupRoot 'migration-report.html')" -ForegroundColor Cyan
    }
    'Restore' {
        $result = Start-Nano11MigrationRestore -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -RetryFailedOnly:$RetryFailedOnly -DryRun:$DryRun
        $cpResult = Restore-Nano11CustomPaths -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -DryRun:$DryRun
        Write-Host "Custom paths restored: $($cpResult.RestoredFiles) files." -ForegroundColor Green
        Write-Host "Restore completed." -ForegroundColor Green
        $result.Results | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.TaskId, $_.Status) }
        Export-Nano11MigrationReport -MigrationResult $result -ReportPath (Join-Path $BackupRoot 'migration-report.html')
    }
}
