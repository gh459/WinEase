# Nano11WinUiHost.ps1 - runs the WinUI 3 window (gui\winui) for nano11builder.ps1
# Dot-sourced after gui\Nano11Gui.ps1 (language tables, migration helpers, debloat lists).
#
# The window is a separate process (Nano11Gui.exe). It talks to this script over its standard streams,
# one UTF-8 JSON object per line:
#   builder -> window : the init message (definitions, presets, start-up settings), then one reply per request
#   window  -> builder: requests { id, op, lang, args }; the last one is op 'result' (the chosen settings or cancel)
# Requests that need PowerShell (dependency check, preset diff, migration engine, ...) run here, in the builder
# process, so the window never needs its own copy of the build logic.

# Nano11Gui.exe: the published build (gui\winui\bin), then a local Debug/Release build output
function Find-Nano11WinUiExe {
    $winuiDir = Join-Path -Path $script:Nano11GuiDir -ChildPath 'winui'
    $candidates = @(Join-Path -Path $winuiDir -ChildPath 'bin\Nano11Gui.exe')
    $buildDir = Join-Path -Path $winuiDir -ChildPath 'Nano11Gui\bin'
    if (Test-Path -LiteralPath $buildDir) {
        $candidates += @(Get-ChildItem -LiteralPath $buildDir -Filter 'Nano11Gui.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# PSCustomObject trees from ConvertFrom-Json -> hashtables / arrays (the build functions take hashtables)
function ConvertTo-Nano11Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Nano11Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertTo-Nano11Hashtable $_ })
    }
    return $InputObject
}

# Built-in presets resolved the way the window applies them (Set-Nano11GuiPreset): every component the preset
# names, every tweak (preset TweakSettings, then a top-level preset key, then the tweak default), payload format
function Get-Nano11WinUiPresets {
    $list = @()
    foreach ($pKey in @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')) {
        $pObj = Get-Nano11Preset -Name $pKey
        if (-not $pObj) { continue }
        $components = [ordered]@{}
        foreach ($cd in $script:ComponentDefs.Values) {
            if ($cd.Gui -and $pObj.Contains($cd.Key)) { $components[$cd.Key] = [bool]$pObj[$cd.Key] }
        }
        $pTweaks = $pObj.TweakSettings
        $tweaks = [ordered]@{}
        foreach ($tk in $script:AllTweakDefs.Keys) {
            if ($pTweaks -and $pTweaks.Contains($tk)) { $tweaks[$tk] = [bool]$pTweaks[$tk] }
            elseif ($pObj.Contains($tk)) { $tweaks[$tk] = [bool]$pObj[$tk] }
            else { $tweaks[$tk] = [bool]$script:AllTweakDefs[$tk].Default }
        }
        $fmt = "$($pObj.PayloadFormat)".ToUpper()
        if ($fmt -notin @('ESD', 'SWM')) { $fmt = 'WIM' }
        $list += , [ordered]@{ Key = $pKey; Components = $components; Tweaks = $tweaks; PayloadFormat = $fmt }
    }
    return ,$list
}

# The first message: everything the window needs to build itself
function New-Nano11WinUiInitMessage {
    param([hashtable]$InitialSettings, [string]$Language)
    $tweaks = @()
    foreach ($tk in $script:AllTweakDefs.Keys) {
        $d = $script:AllTweakDefs[$tk]
        $tweaks += , [ordered]@{ Key = $tk; Category = "$($d.Category)"; Default = [bool]$d.Default; Description = "$($d.Description)"; DescriptionJa = "$($d.DescriptionJa)" }
    }
    $components = @()
    foreach ($cd in $script:ComponentDefs.Values) {
        if (-not $cd.Gui) { continue }
        $components += , [ordered]@{
            Key = $cd.Key; Text = "$($cd.Gui.Text)"; Description = "$($cd.Gui.Description)"; Default = [bool]$cd.Gui.Default
            Tab = "$($cd.Gui.Tab)"; Order = [int]$cd.Gui.Order
        }
    }
    $initial = [ordered]@{}
    foreach ($k in @('SourceDrive', 'WorkDir', 'Index', 'InjectDrivers', 'UserName', 'ComputerName', 'PresetKey')) {
        $initial[$k] = if ($null -ne $InitialSettings[$k]) { "$($InitialSettings[$k])" } else { '' }
    }
    foreach ($k in @('UseVHDX', 'ExportESDMode', 'SplitWIMMode')) { $initial[$k] = [bool]$InitialSettings[$k] }
    $initTweaks = [ordered]@{}
    if ($InitialSettings.TweakSettings) { foreach ($k in $InitialSettings.TweakSettings.Keys) { $initTweaks[$k] = [bool]$InitialSettings.TweakSettings[$k] } }
    $initial['TweakSettings'] = $initTweaks
    $initComponents = [ordered]@{}
    foreach ($c in $components) { if ($InitialSettings.ContainsKey($c.Key)) { $initComponents[$c.Key] = [bool]$InitialSettings[$c.Key] } }
    $initial['Components'] = $initComponents
    $initial['AdvancedDebloatStandard'] = @($InitialSettings.AdvancedDebloatStandard | Where-Object { $_ })
    $initial['AdvancedDebloatExperimental'] = @($InitialSettings.AdvancedDebloatExperimental | Where-Object { $_ })

    $extRes = $script:UserExtensionsResult
    $extErrors = @()
    if ($extRes -and $extRes.Errors) { $extErrors = @($extRes.Errors | Where-Object { $_ } | ForEach-Object { "$_" }) }
    $ext = [ordered]@{
        Loaded = [bool]$extRes; UserTweakCount = [int]$extRes.UserTweakCount; UserPresetCount = [int]$extRes.UserPresetCount
        CustomScriptCount = [int]$extRes.CustomScriptCount; Errors = $extErrors
    }

    return [ordered]@{
        Op                   = 'init'
        Language             = $Language
        Languages            = $script:Nano11UiLanguages
        StringsDir           = "$(Get-Nano11UiStringsDir)"
        RepoRoot             = $script:Nano11GuiRepoRoot
        Tweaks               = $tweaks
        Components           = $components
        Presets              = (Get-Nano11WinUiPresets)
        PresetNames          = @($script:BuiltInPresets.Keys | ForEach-Object { "$_" })
        DebloatStandard      = $script:Nano11DebloatStandardItems
        DebloatExperimental  = $script:Nano11DebloatExperimentalItems
        Initial              = $initial
        DefaultWorkDir       = (Get-Nano11GuiDefaultWorkDir)
        DefaultMigrationRoot = (Get-Nano11DefaultMigrationBackupPath)
        Sources              = (Get-Nano11GuiSourceCandidates)
        Extensions           = $ext
    }
}

# Reply for a migration-engine job: @{ Kind; Text } from the outcome of Invoke-Nano11GuiMigrationJob
function Get-Nano11WinUiJobReply {
    param($Outcome, [string]$SuccessMessage)
    if ($Outcome.Error) { return @{ Kind = 'Error'; Text = (Get-Nano11UiString 'Msg.Error' -Format $Outcome.Error) } }
    $text = $SuccessMessage
    $kind = 'Info'
    if (@($Outcome.Errors).Count -gt 0) {
        $text += "`n`n" + (Get-Nano11UiString 'Msg.ErrorsReported') + "`n" + (@($Outcome.Errors) -join "`n")
        $kind = 'Warning'
    }
    return @{ Kind = $kind; Text = $text }
}

# One window request -> reply hashtable (Kind / Title / Text for a message, Data for values)
function Invoke-Nano11WinUiRequest {
    param([string]$Op, $Arguments)
    $a = ConvertTo-Nano11Hashtable $Arguments
    if (-not $a) { $a = @{} }
    $repo = $script:Nano11GuiRepoRoot
    $root = "$($a.BackupRoot)".Trim()
    if (-not $root) { $root = Get-Nano11DefaultMigrationBackupPath }
    switch ($Op) {
        'sources' { return @{ Data = (Get-Nano11GuiSourceCandidates) } }
        'saveLanguage' {
            Save-Nano11GuiLanguage -Language "$($a.Language)"
            return @{}
        }
        'dependencies' {
            $res = Test-Nano11Dependencies -Config $a.Config
            $txt = Format-Nano11DependencyReport -Result $res
            if (-not $txt) { $txt = Get-Nano11UiString 'Msg.Dependency.None' }
            return @{ Title = (Get-Nano11UiString 'Msg.Dependency.Title'); Text = "$txt"; Data = @{ HasIssues = [bool]$res.HasIssues } }
        }
        'presetDiff' {
            $resolved = @()
            foreach ($name in @("$($a.From)", "$($a.To)")) {
                if ($name -eq '__current__') { $resolved += , $a.Config } else { $resolved += , $name }
            }
            $diff = Compare-Nano11Config -ReferenceConfig $resolved[0] -DifferenceConfig $resolved[1]
            return @{ Text = "$(Format-Nano11ConfigDiff -DiffResult $diff)" }
        }
        'readiness' {
            $rr = Test-Nano11RecoveryReadiness -Config $a.Config
            $msg = Get-Nano11UiString 'Mig.Readiness.Message' -Format $rr.ReadinessScore, ($rr.SecondaryDrives -join ', '), $rr.SystemRestoreEnabled, $rr.WinReEnabledOnTarget, ($rr.Recommendations -join "`n")
            return @{ Title = (Get-Nano11UiString 'Mig.Readiness.Title'); Text = $msg }
        }
        'migrationRules' {
            $rules = @()
            try {
                . (Join-Path $repo 'tools\migrator\Nano11Migration.ps1')
                $data = Get-Nano11MigrationRules
                foreach ($r in (@($data.GameRules) + @($data.AppConfigRules))) {
                    if ($r -and $r.Id) { $rules += , [ordered]@{ Id = [string]$r.Id; Name = "$($r.Name)" } }
                }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            return @{ Data = $rules }
        }
        'exportApps' {
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $repo -Script 'param($a) Export-Nano11AppInventory -OutputPath $a.OutputPath' -Arguments @{ OutputPath = "$($a.OutputPath)" }
            $r = Get-Nano11WinUiJobReply -Outcome $o -SuccessMessage (Get-Nano11UiString 'Mig.Export.Done' -Format $a.OutputPath)
            $r.Title = Get-Nano11UiString 'Mig.Export.Title'
            return $r
        }
        'estimate' {
            $map = Get-Nano11MigrationFolderMapFromNames -Names @($a.Folders)
            $ea = @{ UserFolderPaths = @($map.Values); SelectedRuleIds = @($a.RuleIds | Where-Object { $_ }); DestinationPath = $root }
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $repo -Arguments $ea -Script 'param($a) Get-Nano11MigrationSizeEstimate -UserFolderPaths $a.UserFolderPaths -SelectedRuleIds $a.SelectedRuleIds -DestinationPath $a.DestinationPath'
            $est = $o.Result
            $msg = if ($est) { Get-Nano11UiString 'Mig.Estimate.Message' -Format $est.TotalFiles, $est.TotalMB, $est.DestinationDrive, $est.DestinationFreeMB, $est.HasEnoughSpace } else { Get-Nano11UiString 'Mig.Estimate.None' }
            $r = Get-Nano11WinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-Nano11UiString 'Mig.Button.Estimate'
            return $r
        }
        'backup' {
            $ba = @{ BackupRoot = $root; RuleIds = @($a.RuleIds | Where-Object { $_ }); FolderMap = (Get-Nano11MigrationFolderMapFromNames -Names @($a.Folders)) }
            if ($a.IncludeSecrets) { $ba['IncludeSecrets'] = $true }
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $repo -Arguments $ba -Script 'param($a) Start-Nano11MigrationBackup @a'
            $r = Get-Nano11WinUiJobReply -Outcome $o -SuccessMessage (Get-Nano11UiString 'Mig.Backup.Done' -Format $root)
            $r.Title = Get-Nano11UiString 'Mig.Backup.Title'
            if (-not $o.Error) { $r.Data = @{ Status = (Get-Nano11UiString 'Mig.Backup.Status') } }
            return $r
        }
        'verify' {
            $script = (Get-Command Test-Nano11GuiBackupIntegrity).ScriptBlock.ToString()
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $repo -Arguments @{ BackupRoot = $root } -Script $script
            $vr = $o.Result
            if ($vr -and @($vr.Problems).Count -gt 0) {
                $o.Errors = @($o.Errors) + @($vr.Problems)
                $msg = Get-Nano11UiString 'Mig.Verify.Problems' -Format $vr.Checked, @($vr.Problems).Count
            } elseif ($vr) { $msg = Get-Nano11UiString 'Mig.Verify.Ok' -Format $vr.Checked } else { $msg = Get-Nano11UiString 'Mig.Verify.None' }
            $r = Get-Nano11WinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-Nano11UiString 'Mig.Verify.Title'
            return $r
        }
        'restore' {
            $policy = "$($a.ConflictPolicy)"
            if (-not $policy) { $policy = 'BackupExisting' }
            $ra = @{ BackupRoot = $root; ConflictPolicy = $policy }
            if ($a.RetryFailedOnly) { $ra['RetryFailedOnly'] = $true }
            $o = Invoke-Nano11GuiMigrationJob -RepoRoot $repo -Arguments $ra -Script 'param($a) Start-Nano11MigrationRestore @a'
            $msg = Get-Nano11UiString 'Mig.Restore.Done'
            if ($o.Result -and $o.Result.Results) { $msg += "`n" + ($o.Result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String) }
            $r = Get-Nano11WinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-Nano11UiString 'Mig.Restore.Title'
            if (-not $o.Error) { $r.Data = @{ Status = (Get-Nano11UiString 'Mig.Restore.Done') } }
            return $r
        }
        'backupCustom' {
            $paths = @($a.Paths | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $title = Get-Nano11UiString 'Mig.Button.BackupCustom'
            if ($paths.Count -eq 0) { return @{ Kind = 'Error'; Title = $title; Text = (Get-Nano11UiString 'Msg.Error' -Format (Get-Nano11UiString 'Mig.Custom.NoPaths')) } }
            . (Join-Path $repo 'tools\migrator\Nano11Migration.ps1')
            $res = Backup-Nano11CustomPaths -Paths $paths -BackupRoot $root
            return @{ Title = $title; Text = (Get-Nano11UiString 'Mig.Custom.BackupDone' -Format $res.CopiedFiles, @($res.FailedFiles).Count)
                Data = @{ Status = (Get-Nano11UiString 'Mig.Custom.BackupStatus' -Format $res.CopiedFiles) } }
        }
        'restoreCustom' {
            $policy = "$($a.ConflictPolicy)"
            if (-not $policy) { $policy = 'BackupExisting' }
            . (Join-Path $repo 'tools\migrator\Nano11Migration.ps1')
            $res = Restore-Nano11CustomPaths -BackupRoot $root -ConflictPolicy $policy
            return @{ Title = (Get-Nano11UiString 'Mig.Button.RestoreCustom'); Text = (Get-Nano11UiString 'Mig.Custom.RestoreDone' -Format $res.RestoredFiles, @($res.FailedFiles).Count)
                Data = @{ Status = (Get-Nano11UiString 'Mig.Custom.RestoreStatus' -Format $res.RestoredFiles) } }
        }
        'wizard' {
            $migratorPath = Join-Path $repo 'tools\migrator\Nano11-Migrator.ps1'
            if (-not (Test-Path -LiteralPath $migratorPath)) { return @{ Kind = 'Warning'; Title = (Get-Nano11UiString 'Mig.Wizard.Title'); Text = (Get-Nano11UiString 'Mig.Wizard.NotFound') } }
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$migratorPath`" -GUI -BackupRoot `"$root`" -UiLanguage $($script:Nano11UiLanguage)" -WindowStyle Normal
            return @{}
        }
        'guide' {
            $guide = Join-Path $repo 'docs\EXTENSIBILITY_GUIDE.md'
            if ($script:Nano11UiLanguage -eq 'ja') {
                $guideJa = Join-Path $repo 'docs\EXTENSIBILITY_GUIDE.ja.md'
                if (Test-Path -LiteralPath $guideJa) { $guide = $guideJa }
            }
            if (-not (Test-Path -LiteralPath $guide)) { throw (Get-Nano11UiString 'Mig.Guide.NotFound' -Format $guide) }
            Start-Process -FilePath $guide
            return @{}
        }
        default { throw "Unknown request '$Op'" }
    }
}

# Window result -> the hashtable Show-Nano11GUI returns (Success, SourceDrive, TweakSettings, ...)
function ConvertFrom-Nano11WinUiResult {
    param($Result)
    $r = ConvertTo-Nano11Hashtable $Result
    if (-not $r -or -not $r.Success) { return @{ Success = $false } }
    $out = @{ Success = $true }
    $srcText = "$($r.SourceDrive)".Trim()
    $out.SourceDrive = if ($srcText) { Resolve-Nano11GuiSource -Text $srcText } else { '' }
    $wDir = "$($r.WorkDir)".Trim()
    $out.WorkDir = if ($wDir) { $wDir } else { Get-Nano11GuiDefaultWorkDir }
    foreach ($k in @('UserName', 'ComputerName', 'Index', 'InjectDrivers')) { $out[$k] = "$($r[$k])".Trim() }
    if (-not $out.ComputerName) { $out.ComputerName = '*' }
    $out.PresetKey = if ($r.PresetKey) { "$($r.PresetKey)" } else { $null }
    $out.BasePresetKey = if ($r.BasePresetKey) { "$($r.BasePresetKey)" } else { $null }
    foreach ($k in @('DryRun', 'UseVHDX', 'ExportESDMode', 'SplitWIMMode', 'PhysicalDebloatConsent')) { $out[$k] = [bool]$r[$k] }
    if ($r.Components) { foreach ($k in $r.Components.Keys) { $out[$k] = [bool]$r.Components[$k] } }
    $tweaks = [ordered]@{}
    if ($r.TweakSettings) { foreach ($k in $r.TweakSettings.Keys) { $tweaks[$k] = [bool]$r.TweakSettings[$k] } }
    $out.TweakSettings = $tweaks
    $out.AdvancedDebloatStandard = @($r.AdvancedDebloatStandard | Where-Object { $_ } | ForEach-Object { "$_" })
    $out.AdvancedDebloatExperimental = @($r.AdvancedDebloatExperimental | Where-Object { $_ } | ForEach-Object { "$_" })
    return $out
}

# Shows the WinUI 3 window and serves its requests until it sends its result (or exits).
# Returns the same hashtable as Show-Nano11GUI; throws when the window cannot be started.
function Show-Nano11WinUiGUI {
    param(
        [hashtable]$InitialSettings = @{},
        [ValidateSet('en', 'ja')][string]$UiLanguage,
        [string]$ExePath = (Find-Nano11WinUiExe)
    )
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { throw "Nano11Gui.exe not found (build it with gui\winui\build.ps1)" }
    Set-Nano11UiLanguage -Language (Resolve-Nano11UiLanguage -Requested $UiLanguage)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = '--stdio'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.WorkingDirectory = Split-Path -Parent $ExePath
    $proc = [System.Diagnostics.Process]::Start($psi)
    $writer = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $utf8)
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"

    $result = @{ Success = $false }
    try {
        $init = New-Nano11WinUiInitMessage -InitialSettings $InitialSettings -Language $script:Nano11UiLanguage
        $initJson = $init | ConvertTo-Json -Depth 12 -Compress
        # Debug aid: NANO11_WINUI_INIT_DUMP=<file> keeps the init message (Nano11Gui.exe --init <file> previews it)
        if ($env:NANO11_WINUI_INIT_DUMP) { [System.IO.File]::WriteAllText($env:NANO11_WINUI_INIT_DUMP, $initJson, $utf8) }
        $writer.WriteLine($initJson)
        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
            if (-not $line.Trim().StartsWith('{')) { continue }
            try { $msg = $line | ConvertFrom-Json } catch { Write-Verbose "Ignored line: $line"; continue }
            if ($msg.lang -and $script:Nano11UiLanguages -contains "$($msg.lang)") { Set-Nano11UiLanguage -Language "$($msg.lang)" }
            if ($msg.op -eq 'result') {
                $result = ConvertFrom-Nano11WinUiResult -Result $msg.args
                $writer.WriteLine((@{ id = $msg.id; ok = $true } | ConvertTo-Json -Compress))
                break
            }
            $reply = [ordered]@{ id = $msg.id; ok = $true }
            try {
                $r = Invoke-Nano11WinUiRequest -Op "$($msg.op)" -Arguments $msg.args
                foreach ($k in @($r.Keys)) { $reply[$k] = $r[$k] }
            } catch {
                $reply.ok = $false
                $reply.Kind = 'Error'
                $reply.Text = Get-Nano11UiString 'Msg.Error' -Format $_.Exception.Message
            }
            $writer.WriteLine(($reply | ConvertTo-Json -Depth 12 -Compress))
        }
        if (-not $proc.WaitForExit(15000)) { Write-Verbose 'Nano11Gui.exe did not exit in time' }
    } finally {
        try { $writer.Dispose() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    return $result
}
