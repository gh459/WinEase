# WinEaseWinUiHost.ps1 - runs the WinUI 3 window (gui\winui) for WinEasebuilder.ps1
# Dot-sourced after gui\WinEaseGui.ps1 (language tables, migration helpers, debloat lists).
#
# The window is a separate process (WinEaseGui.exe). It talks to this script over its standard streams,
# one UTF-8 JSON object per line:
#   builder -> window : the init message (definitions, presets, start-up settings), then one reply per request
#   window  -> builder: requests { id, op, lang, args }; the last one is op 'result' (the chosen settings or cancel)
# Requests that need PowerShell (dependency check, preset diff, migration engine, ...) run here, in the builder
# process, so the window never needs its own copy of the build logic.

# WinEaseGui.exe: the published build (gui\winui\bin), then a local Debug/Release build output
function Find-WinEaseWinUiExe {
    $winuiDir = Join-Path -Path $script:WinEaseGuiDir -ChildPath 'winui'
    $candidates = @(Join-Path -Path $winuiDir -ChildPath 'bin\WinEaseGui.exe')
    $buildDir = Join-Path -Path $winuiDir -ChildPath 'WinEaseGui\bin'
    if (Test-Path -LiteralPath $buildDir) {
        $candidates += @(Get-ChildItem -LiteralPath $buildDir -Filter 'WinEaseGui.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# PSCustomObject trees from ConvertFrom-Json -> hashtables / arrays (the build functions take hashtables)
function ConvertTo-WinEaseHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WinEaseHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertTo-WinEaseHashtable $_ })
    }
    return $InputObject
}

# Built-in presets resolved the way the window applies them (Set-WinEaseGuiPreset): every component the preset
# names, every tweak (preset TweakSettings, then a top-level preset key, then the tweak default), payload format
function Get-WinEaseWinUiPresets {
    $list = @(
        foreach ($pKey in @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')) {
            $pObj = Get-WinEasePreset -Name $pKey
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
            [ordered]@{ Key = $pKey; Components = $components; Tweaks = $tweaks; PayloadFormat = $fmt }
        }
    )
    return ,$list
}

# The first message: everything the window needs to build itself
function New-WinEaseWinUiInitMessage {
    param([hashtable]$InitialSettings, [string]$Language)
    $tweaks = @()
    foreach ($tk in $script:AllTweakDefs.Keys) {
        $d = $script:AllTweakDefs[$tk]
        $tweaks += , [ordered]@{ Key = $tk; Category = "$($d.Category)"; Default = [bool]$d.Default; Description = "$($d.Description)"; DescriptionJa = "$($d.DescriptionJa)" }
    }
    $components = @(foreach ($cd in $script:ComponentDefs.Values) {
        if (-not $cd.Gui) { continue }
        [ordered]@{
            Key = $cd.Key; Text = "$($cd.Gui.Text)"; Description = "$($cd.Gui.Description)"; Default = [bool]$cd.Gui.Default
            Tab = "$($cd.Gui.Tab)"; Order = [int]$cd.Gui.Order
        }
    })
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
    $initial['AdvancedDebloatStandard'] = @(($InitialSettings.AdvancedDebloatStandard).Where({ $_ }))
    $initial['AdvancedDebloatExperimental'] = @(($InitialSettings.AdvancedDebloatExperimental).Where({ $_ }))
    # The engine the user picked for a target (the rest runs on the registered default)
    $initEngines = [ordered]@{}
    if ($InitialSettings.DebloatEngineSelection) {
        foreach ($k in $InitialSettings.DebloatEngineSelection.Keys) {
            $initEngines[[string]$k] = [string]$InitialSettings.DebloatEngineSelection[$k]
        }
    }
    $initial['DebloatEngineSelection'] = $initEngines

    # The engine bindings of every Advanced Debloat target (config\schema.psd1 -> DebloatEngines)
    $engineDefs = [ordered]@{}
    $allEngineDefs = Get-WinEaseDebloatEngineDefs
    foreach ($item in (@($script:WinEaseDebloatStandardItems) + @($script:WinEaseDebloatExperimentalItems))) {
        if (-not $allEngineDefs.Contains($item)) { continue }
        $engineDefs[$item] = [ordered]@{
            Engines = @($allEngineDefs[$item].Engines)
            Default = [string]$allEngineDefs[$item].Default
        }
    }

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
        Languages            = $script:WinEaseUiLanguages
        StringsDir           = "$(Get-WinEaseUiStringsDir)"
        RepoRoot             = $script:WinEaseGuiRepoRoot
        Tweaks               = $tweaks
        Components           = $components
        Presets              = (Get-WinEaseWinUiPresets)
        PresetNames          = @($script:BuiltInPresets.Keys | ForEach-Object { "$_" })
        DebloatStandard      = $script:WinEaseDebloatStandardItems
        DebloatExperimental  = $script:WinEaseDebloatExperimentalItems
        DebloatEngines       = $engineDefs
        Initial              = $initial
        DefaultWorkDir       = (Get-WinEaseGuiDefaultWorkDir)
        DefaultMigrationRoot = (Get-WinEaseDefaultMigrationBackupPath)
        Sources              = (Get-WinEaseGuiSourceCandidates)
        Extensions           = $ext
    }
}

# Reply for a migration-engine job: @{ Kind; Text } from the outcome of Invoke-WinEaseGuiMigrationJob
function Get-WinEaseWinUiJobReply {
    param($Outcome, [string]$SuccessMessage)
    if ($Outcome.Error) { return @{ Kind = 'Error'; Text = (Get-WinEaseUiString 'Msg.Error' -Format $Outcome.Error) } }
    $text = $SuccessMessage
    $kind = 'Info'
    if (@($Outcome.Errors).Count -gt 0) {
        $text += "`n`n" + (Get-WinEaseUiString 'Msg.ErrorsReported') + "`n" + (@($Outcome.Errors) -join "`n")
        $kind = 'Warning'
    }
    return @{ Kind = $kind; Text = $text }
}

# One window request -> reply hashtable (Kind / Title / Text for a message, Data for values)
function Invoke-WinEaseWinUiRequest {
    param([string]$Op, $Arguments)
    $a = ConvertTo-WinEaseHashtable $Arguments
    if (-not $a) { $a = @{} }
    $repo = $script:WinEaseGuiRepoRoot
    $root = "$($a.BackupRoot)".Trim()
    if (-not $root) { $root = Get-WinEaseDefaultMigrationBackupPath }
    switch ($Op) {
        'sources' { return @{ Data = (Get-WinEaseGuiSourceCandidates) } }
        'saveLanguage' {
            Save-WinEaseGuiLanguage -Language "$($a.Language)"
            return @{}
        }
        'dependencies' {
            $res = Test-WinEaseDependencies -Config $a.Config
            $txt = Format-WinEaseDependencyReport -Result $res
            if (-not $txt) { $txt = Get-WinEaseUiString 'Msg.Dependency.None' }
            return @{ Title = (Get-WinEaseUiString 'Msg.Dependency.Title'); Text = "$txt"; Data = @{ HasIssues = [bool]$res.HasIssues } }
        }
        'presetDiff' {
            $resolved = @()
            foreach ($name in @("$($a.From)", "$($a.To)")) {
                if ($name -eq '__current__') { $resolved += , $a.Config } else { $resolved += , $name }
            }
            $diff = Compare-WinEaseConfig -ReferenceConfig $resolved[0] -DifferenceConfig $resolved[1]
            return @{ Text = "$(Format-WinEaseConfigDiff -DiffResult $diff)" }
        }
        'readiness' {
            $rr = Test-WinEaseRecoveryReadiness -Config $a.Config
            $msg = Get-WinEaseUiString 'Mig.Readiness.Message' -Format $rr.ReadinessScore, ($rr.SecondaryDrives -join ', '), $rr.SystemRestoreEnabled, $rr.WinReEnabledOnTarget, ($rr.Recommendations -join "`n")
            return @{ Title = (Get-WinEaseUiString 'Mig.Readiness.Title'); Text = $msg }
        }
        'migrationRules' {
            $rules = @(
                try {
                    . (Join-Path $repo 'tools\migrator\WinEaseMigration.ps1')
                    $data = Get-WinEaseMigrationRules
                    foreach ($r in (@($data.GameRules) + @($data.AppConfigRules))) {
                        if ($r -and $r.Id) { [ordered]@{ Id = [string]$r.Id; Name = "$($r.Name)" } }
                    }
                } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            )
            return @{ Data = $rules }
        }
        'exportApps' {
            $o = Invoke-WinEaseGuiMigrationJob -RepoRoot $repo -Script 'param($a) Export-WinEaseAppInventory -OutputPath $a.OutputPath' -Arguments @{ OutputPath = "$($a.OutputPath)" }
            $r = Get-WinEaseWinUiJobReply -Outcome $o -SuccessMessage (Get-WinEaseUiString 'Mig.Export.Done' -Format $a.OutputPath)
            $r.Title = Get-WinEaseUiString 'Mig.Export.Title'
            return $r
        }
        'estimate' {
            $map = Get-WinEaseMigrationFolderMapFromNames -Names @($a.Folders)
            $ea = @{ UserFolderPaths = @($map.Values); SelectedRuleIds = @($a.RuleIds | Where-Object { $_ }); DestinationPath = $root }
            $o = Invoke-WinEaseGuiMigrationJob -RepoRoot $repo -Arguments $ea -Script 'param($a) Get-WinEaseMigrationSizeEstimate -UserFolderPaths $a.UserFolderPaths -SelectedRuleIds $a.SelectedRuleIds -DestinationPath $a.DestinationPath'
            $est = $o.Result
            $msg = if ($est) { Get-WinEaseUiString 'Mig.Estimate.Message' -Format $est.TotalFiles, $est.TotalMB, $est.DestinationDrive, $est.DestinationFreeMB, $est.HasEnoughSpace } else { Get-WinEaseUiString 'Mig.Estimate.None' }
            $r = Get-WinEaseWinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-WinEaseUiString 'Mig.Button.Estimate'
            return $r
        }
        'backup' {
            $ba = @{ BackupRoot = $root; RuleIds = @($a.RuleIds | Where-Object { $_ }); FolderMap = (Get-WinEaseMigrationFolderMapFromNames -Names @($a.Folders)) }
            if ($a.IncludeSecrets) { $ba['IncludeSecrets'] = $true }
            $o = Invoke-WinEaseGuiMigrationJob -RepoRoot $repo -Arguments $ba -Script 'param($a) Start-WinEaseMigrationBackup @a'
            $r = Get-WinEaseWinUiJobReply -Outcome $o -SuccessMessage (Get-WinEaseUiString 'Mig.Backup.Done' -Format $root)
            $r.Title = Get-WinEaseUiString 'Mig.Backup.Title'
            if (-not $o.Error) { $r.Data = @{ Status = (Get-WinEaseUiString 'Mig.Backup.Status') } }
            return $r
        }
        'verify' {
            $script = (Get-Command Test-WinEaseGuiBackupIntegrity).ScriptBlock.ToString()
            $o = Invoke-WinEaseGuiMigrationJob -RepoRoot $repo -Arguments @{ BackupRoot = $root } -Script $script
            $vr = $o.Result
            if ($vr -and @($vr.Problems).Count -gt 0) {
                $o.Errors = @($o.Errors) + @($vr.Problems)
                $msg = Get-WinEaseUiString 'Mig.Verify.Problems' -Format $vr.Checked, @($vr.Problems).Count
            } elseif ($vr) { $msg = Get-WinEaseUiString 'Mig.Verify.Ok' -Format $vr.Checked } else { $msg = Get-WinEaseUiString 'Mig.Verify.None' }
            $r = Get-WinEaseWinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-WinEaseUiString 'Mig.Verify.Title'
            return $r
        }
        'restore' {
            $policy = "$($a.ConflictPolicy)"
            if (-not $policy) { $policy = 'BackupExisting' }
            $ra = @{ BackupRoot = $root; ConflictPolicy = $policy }
            if ($a.RetryFailedOnly) { $ra['RetryFailedOnly'] = $true }
            $o = Invoke-WinEaseGuiMigrationJob -RepoRoot $repo -Arguments $ra -Script 'param($a) Start-WinEaseMigrationRestore @a'
            $msg = Get-WinEaseUiString 'Mig.Restore.Done'
            if ($o.Result -and $o.Result.Results) { $msg += "`n" + ($o.Result.Results | ForEach-Object { "$($_.TaskId): $($_.Status)" } | Out-String) }
            $r = Get-WinEaseWinUiJobReply -Outcome $o -SuccessMessage $msg
            $r.Title = Get-WinEaseUiString 'Mig.Restore.Title'
            if (-not $o.Error) { $r.Data = @{ Status = (Get-WinEaseUiString 'Mig.Restore.Done') } }
            return $r
        }
        'backupCustom' {
            $paths = @($a.Paths | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $title = Get-WinEaseUiString 'Mig.Button.BackupCustom'
            if ($paths.Count -eq 0) { return @{ Kind = 'Error'; Title = $title; Text = (Get-WinEaseUiString 'Msg.Error' -Format (Get-WinEaseUiString 'Mig.Custom.NoPaths')) } }
            . (Join-Path $repo 'tools\migrator\WinEaseMigration.ps1')
            $res = Backup-WinEaseCustomPaths -Paths $paths -BackupRoot $root
            return @{ Title = $title; Text = (Get-WinEaseUiString 'Mig.Custom.BackupDone' -Format $res.CopiedFiles, @($res.FailedFiles).Count)
                Data = @{ Status = (Get-WinEaseUiString 'Mig.Custom.BackupStatus' -Format $res.CopiedFiles) } }
        }
        'restoreCustom' {
            $policy = "$($a.ConflictPolicy)"
            if (-not $policy) { $policy = 'BackupExisting' }
            . (Join-Path $repo 'tools\migrator\WinEaseMigration.ps1')
            $res = Restore-WinEaseCustomPaths -BackupRoot $root -ConflictPolicy $policy
            return @{ Title = (Get-WinEaseUiString 'Mig.Button.RestoreCustom'); Text = (Get-WinEaseUiString 'Mig.Custom.RestoreDone' -Format $res.RestoredFiles, @($res.FailedFiles).Count)
                Data = @{ Status = (Get-WinEaseUiString 'Mig.Custom.RestoreStatus' -Format $res.RestoredFiles) } }
        }
        'wizard' {
            $migratorPath = Join-Path $repo 'tools\migrator\WinEase-Migrator.ps1'
            if (-not (Test-Path -LiteralPath $migratorPath)) { return @{ Kind = 'Warning'; Title = (Get-WinEaseUiString 'Mig.Wizard.Title'); Text = (Get-WinEaseUiString 'Mig.Wizard.NotFound') } }
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$migratorPath`" -GUI -BackupRoot `"$root`" -UiLanguage $($script:WinEaseUiLanguage)" -WindowStyle Normal
            return @{}
        }
        'guide' {
            $guide = Join-Path $repo 'docs\EXTENSIBILITY_GUIDE.md'
            if ($script:WinEaseUiLanguage -eq 'ja') {
                $guideJa = Join-Path $repo 'docs\EXTENSIBILITY_GUIDE.ja.md'
                if (Test-Path -LiteralPath $guideJa) { $guide = $guideJa }
            }
            if (-not (Test-Path -LiteralPath $guide)) { throw (Get-WinEaseUiString 'Mig.Guide.NotFound' -Format $guide) }
            Start-Process -FilePath $guide
            return @{}
        }
        default { throw "Unknown request '$Op'" }
    }
}

# Window result -> the hashtable Show-WinEaseGUI returns (Success, SourceDrive, TweakSettings, ...)
function ConvertFrom-WinEaseWinUiResult {
    param($Result)
    $r = ConvertTo-WinEaseHashtable $Result
    if (-not $r -or -not $r.Success) { return @{ Success = $false } }
    $out = @{ Success = $true }
    $srcText = "$($r.SourceDrive)".Trim()
    $out.SourceDrive = if ($srcText) { Resolve-WinEaseGuiSource -Text $srcText } else { '' }
    $wDir = "$($r.WorkDir)".Trim()
    $out.WorkDir = if ($wDir) { $wDir } else { Get-WinEaseGuiDefaultWorkDir }
    foreach ($k in @('UserName', 'ComputerName', 'Index', 'InjectDrivers')) { $out[$k] = "$($r[$k])".Trim() }
    if (-not $out.ComputerName) { $out.ComputerName = '*' }
    $out.PresetKey = if ($r.PresetKey) { "$($r.PresetKey)" } else { $null }
    $out.BasePresetKey = if ($r.BasePresetKey) { "$($r.BasePresetKey)" } else { $null }
    foreach ($k in @('DryRun', 'UseVHDX', 'ExportESDMode', 'SplitWIMMode', 'PhysicalDebloatConsent')) { $out[$k] = [bool]$r[$k] }
    if ($r.Components) { foreach ($k in $r.Components.Keys) { $out[$k] = [bool]$r.Components[$k] } }
    $tweaks = [ordered]@{}
    if ($r.TweakSettings) { foreach ($k in $r.TweakSettings.Keys) { $tweaks[$k] = [bool]$r.TweakSettings[$k] } }
    $out.TweakSettings = $tweaks
    $out.AdvancedDebloatStandard = @(($r.AdvancedDebloatStandard).Where({ $_ }).ForEach({ "$_" }))
    $out.AdvancedDebloatExperimental = @(($r.AdvancedDebloatExperimental).Where({ $_ }).ForEach({ "$_" }))
    # The engine per Advanced Debloat target (PowerShell / Rust)
    $engines = [ordered]@{}
    if ($r.DebloatEngineSelection) {
        foreach ($k in $r.DebloatEngineSelection.Keys) { $engines[[string]$k] = [string]$r.DebloatEngineSelection[$k] }
    }
    $out.DebloatEngineSelection = $engines
    return $out
}

# Shows the WinUI 3 window and serves its requests until it sends its result (or exits).
# Returns the same hashtable as Show-WinEaseGUI; throws when the window cannot be started.
function Show-WinEaseWinUiGUI {
    param(
        [hashtable]$InitialSettings = @{},
        [ValidateSet('en', 'ja')][string]$UiLanguage,
        [string]$ExePath = (Find-WinEaseWinUiExe)
    )
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { throw "WinEaseGui.exe not found (build it with gui\winui\build.ps1)" }
    Set-WinEaseUiLanguage -Language (Resolve-WinEaseUiLanguage -Requested $UiLanguage)

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
        $init = New-WinEaseWinUiInitMessage -InitialSettings $InitialSettings -Language $script:WinEaseUiLanguage
        $initJson = $init | ConvertTo-Json -Depth 12 -Compress
        # Debug aid: WINEASE_WINUI_INIT_DUMP=<file> keeps the init message (WinEaseGui.exe --init <file> previews it)
        if ($env:WINEASE_WINUI_INIT_DUMP) {
            try {
                $dumpPath = $env:WINEASE_WINUI_INIT_DUMP
                $dumpDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($dumpPath))
                if ($dumpDir -and -not (Test-Path -LiteralPath $dumpDir)) {
                    [void][System.IO.Directory]::CreateDirectory($dumpDir)
                }
                [System.IO.File]::WriteAllText($dumpPath, $initJson, $utf8)
            } catch {
                Write-Verbose "Failed to dump init JSON to '$env:WINEASE_WINUI_INIT_DUMP': $($_.Exception.Message)"
            }
        }
        $writer.WriteLine($initJson)
        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
            if (-not $line.Trim().StartsWith('{')) { continue }
            try { $msg = $line | ConvertFrom-Json } catch { Write-Verbose "Ignored line: $line"; continue }
            if ($msg.lang -and $script:WinEaseUiLanguages -contains "$($msg.lang)") { Set-WinEaseUiLanguage -Language "$($msg.lang)" }
            if ($msg.op -eq 'result') {
                $result = ConvertFrom-WinEaseWinUiResult -Result $msg.args
                $writer.WriteLine((@{ id = $msg.id; ok = $true } | ConvertTo-Json -Compress))
                break
            }
            $reply = [ordered]@{ id = $msg.id; ok = $true }
            try {
                $r = Invoke-WinEaseWinUiRequest -Op "$($msg.op)" -Arguments $msg.args
                foreach ($k in @($r.Keys)) { $reply[$k] = $r[$k] }
            } catch {
                $reply.ok = $false
                $reply.Kind = 'Error'
                $reply.Text = Get-WinEaseUiString 'Msg.Error' -Format $_.Exception.Message
            }
            $writer.WriteLine(($reply | ConvertTo-Json -Depth 12 -Compress))
        }
        if (-not $proc.WaitForExit(15000)) { Write-Verbose 'WinEaseGui.exe did not exit in time' }
    } finally {
        try { $writer.Dispose() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    return $result
}
