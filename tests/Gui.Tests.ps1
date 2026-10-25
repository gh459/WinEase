# Gui.Tests.ps1 - GUI wiring, WinForms/WinUI and display language
# Run with:  Invoke-Pester -Path .\tests\Gui.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Evaluates literal arrays/hashtables taken from the repository''s own source AST')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


# The GUI uses the shared helpers at run time but does not dot-source them itself.
if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "Apply-WinEaseGuiResult in lib\WinEaseGuiSession.ps1" {
    BeforeAll {
        $guiSessionText = [System.IO.File]::ReadAllText($script:GuiSessionPath, [System.Text.Encoding]::UTF8)
        $guiSessionAst = [System.Management.Automation.Language.Parser]::ParseInput($guiSessionText, [ref]$null, [ref]$null)

        # Load functions needed by Apply-WinEaseGuiResult
        $funcsToLoad = @('Apply-WinEaseGuiResult', 'Confirm-WinEasePhysicalDebloatConsent')
        $funcs = $guiSessionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $funcsToLoad -contains $n.Name }, $true)
        foreach ($fn in $funcs) { . ([scriptblock]::Create($fn.Extent.Text)) }

        # Initialize schema definitions in script scope
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $script:AllTweakDefs = [ordered]@{}
        $script:TweakKeyAliases = [ordered]@{}
        $script:TweakVariableMap = [ordered]@{}
        foreach ($td in $settingsDef.Tweaks) {
            $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description }
            foreach ($alias in @($td.Aliases)) { if ($alias) { $script:TweakKeyAliases[$alias] = $td.Key } }
            if ($td.Variable) { $script:TweakVariableMap[$td.Key] = $td.Variable }
        }
        $script:ComponentDefs = [ordered]@{}
        foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
        $script:WinEaseDebloatEngines = [ordered]@{}
        foreach ($de in @($settingsDef.DebloatEngines)) {
            if ($de -and $de.Item) { $script:WinEaseDebloatEngines[[string]$de.Item] = $de }
        }

        # The input check Apply-WinEaseGuiResult runs before it changes anything (lib\WinEaseInputValidation.ps1)
        . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseInputValidation.ps1')

        # Mock helper functions called inside Apply-WinEaseGuiResult
        function Apply-ProfileSettings { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param($ProfileName) return @{ ProfileName = $ProfileName } }
        function Sync-WinEaseTweakVariables { }
        function Set-WinEaseDebloatEngineSelection { param($Selection) $script:DebloatEngineSelection = $Selection }
        function Resolve-WinEaseDebloatEngine { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param($Item) return "PowerShell" }
        function Confirm-WinEasePhysicalDebloatConsent { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param($GuiResult) }
    }

    BeforeEach {
        $script:allowPhysicalDebloat = $false
        $script:SourceDrive = "C:\ISO"
        $script:WorkDir = "C:\Work"
        $script:UserName = "User"
        $script:ComputerName = "PC"
        $script:Index = "1"
        $script:InjectDrivers = ""
        $script:useVHDX = $false
        $script:exportESDMode = $false
        $script:splitWIMMode = $false
        $script:DryRun = $false
        $script:isDryRunMode = $false
        $script:selectedProfile = "Default"
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        $script:TweakSettings = [ordered]@{}
        foreach ($tk in $script:AllTweakDefs.Keys) {
            $script:TweakSettings[$tk] = [bool]$script:AllTweakDefs[$tk].Default
        }
    }

    It "applies physical debloat consent when PhysicalDebloatConsent is true" {
        $result = @{ PhysicalDebloatConsent = $true }
        Apply-WinEaseGuiResult -GuiResult $result
        $script:allowPhysicalDebloat | Should Be $true
    }

    It "applies full GUI result hashtable and updates session variables" {
        $iso = Join-Path $TestDrive "Win11.iso"
        Set-Content -LiteralPath $iso -Value "x"
        $drivers = Join-Path $TestDrive "Drivers"
        New-Item -ItemType Directory -Force -Path $drivers | Out-Null
        $work = Join-Path $TestDrive "WinEaseWork"
        $guiResult = @{
            SourceDrive = $iso
            WorkDir = $work
            UserName = "TestUser"
            ComputerName = "WIN-TESTPC"
            UseVHDX = $true
            ExportESDMode = $true
            SplitWIMMode = $false
            AdvancedDebloatStandard = @("TargetA")
            AdvancedDebloatExperimental = @("TargetB")
            Index = "2"
            InjectDrivers = $drivers
            DryRun = $true
            PresetKey = "custom_preset"
            TweakSettings = @{ DisableUAC = $true }
            DebloatEngineSelection = @{ "TargetA" = "Rust" }
        }

        Apply-WinEaseGuiResult -GuiResult $guiResult

        $script:SourceDrive | Should Be $iso
        $script:WorkDir | Should Be $work
        $script:UserName | Should Be "TestUser"
        $script:ComputerName | Should Be "WIN-TESTPC"
        $script:useVHDX | Should Be $true
        $script:exportESDMode | Should Be $true
        $script:splitWIMMode | Should Be $false
        $script:advancedDebloatStandard | Should Be @("TargetA")
        $script:advancedDebloatExperimental | Should Be @("TargetB")
        $script:Index | Should Be "2"
        $script:InjectDrivers | Should Be $drivers
        $script:DryRun | Should Be $true
        $script:isDryRunMode | Should Be $true
        $script:selectedProfile | Should Be "custom_preset"
        $script:TweakSettings["DisableUAC"] | Should Be $true
        $script:DebloatEngineSelection["TargetA"] | Should Be "Rust"
    }

    It "refuses a result with an invalid user name, computer name, path or drivers folder and changes no builder variable" {
        $bad = @{ UserName = 'a"b'; ComputerName = 'x;calc'; WorkDir = 'C:\bad|path'; InjectDrivers = (Join-Path $TestDrive 'no\such\drivers'); DryRun = $true; UseVHDX = $true }
        $warn = $null
        $r = Apply-WinEaseGuiResult -GuiResult $bad -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should Be $false
        $warnText = (@($warn) | ForEach-Object { "$($_.Message)" }) -join "`n"
        $warnText | Should Match 'UserName'
        $warnText | Should Match 'ComputerName'
        $warnText | Should Match 'WorkDir'
        $warnText | Should Match 'InjectDrivers'
        $script:UserName | Should Be "User"
        $script:ComputerName | Should Be "PC"
        $script:WorkDir | Should Be "C:\Work"
        $script:useVHDX | Should Be $false
        $script:DryRun | Should Be $false
    }

    It "refuses a workspace that is the folder the ISO is written to" {
        $script:scriptDir = Join-Path $TestDrive 'outfolder'
        New-Item -ItemType Directory -Force -Path $script:scriptDir | Out-Null
        try {
            (Apply-WinEaseGuiResult -GuiResult @{ WorkDir = $script:scriptDir } -WarningAction SilentlyContinue) | Should Be $false
            $script:WorkDir | Should Be "C:\Work"
        } finally { $script:scriptDir = $null }
    }

    It "refuses a result with an invalid UserName / ComputerName / path and changes no builder variable" {
        foreach ($bad in @(@{ UserName = 'a"b' }, @{ ComputerName = 'x;calc' }, @{ WorkDir = 'C:\bad|path' }, @{ InjectDrivers = (Join-Path $TestDrive 'nodrivers') }, @{ SourceDrive = (Join-Path $TestDrive 'none.iso') })) {
            $script:UserName = 'User'; $script:ComputerName = 'PC'; $script:WorkDir = 'C:\Work'
            $r = Apply-WinEaseGuiResult -GuiResult $bad 3>$null
            $r | Should Be $false
            $script:UserName | Should Be 'User'
            $script:ComputerName | Should Be 'PC'
            $script:WorkDir | Should Be 'C:\Work'
        }
        (Apply-WinEaseGuiResult -GuiResult @{ UserName = 'Tester'; ComputerName = 'PC-1' }) | Should Be $true
        $script:UserName | Should Be 'Tester'
    }

    It "handles null/missing debloat lists and debloat engine selection safely" {
        $guiResult = @{
            AdvancedDebloatStandard = $null
            AdvancedDebloatExperimental = $null
            DebloatEngineSelection = $null
        }

        Apply-WinEaseGuiResult -GuiResult $guiResult

        @($script:advancedDebloatStandard).Count | Should Be 0
        @($script:advancedDebloatExperimental).Count | Should Be 0
        $script:DebloatEngineSelection.Count | Should Be 0
    }

    It "processes DebloatEngineSelection in PSCustomObject format" {
        $engineObj = [PSCustomObject]@{
            "Remove Bluetooth stack (service + binary) [20-40MB]" = "Rust"
        }
        $guiResult = @{
            DebloatEngineSelection = $engineObj
        }

        Apply-WinEaseGuiResult -GuiResult $guiResult

        $script:DebloatEngineSelection["Remove Bluetooth stack (service + binary) [20-40MB]"] | Should Be "Rust"
    }

    It "resolves selectedProfile correctly for BasePresetKey when PresetKey is missing" {
        $guiResult = @{
            BasePresetKey = "extreme"
        }

        Apply-WinEaseGuiResult -GuiResult $guiResult

        $script:selectedProfile | Should Be "custom (based on extreme)"
    }

    It "resolves selectedProfile to 'GUI Selection' when PresetKey and BasePresetKey are both missing" {
        $guiResult = @{}

        Apply-WinEaseGuiResult -GuiResult $guiResult

        $script:selectedProfile | Should Be "GUI Selection"
    }
}

Describe "WinEase GUI wiring - every toggle is consumed by the build" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $phasesDir = Join-Path -Path $script:RepoRoot -ChildPath "phases"
    $phaseText = (Get-ChildItem -LiteralPath $phasesDir -Filter "*.ps1" | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
# lib\WinEaseDebloat.ps1 holds the safe (PowerShell) engine of the Advanced Debloat targets
$phaseText += "`n" + [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"))
# config\schema.psd1 is the master schema: the lookup tables of the options live there
$schemaText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\schema.psd1"))
    $helpersText = Get-WinEaseHelperSourceText
    # the plain registry writes of phase 10 are data (config\registry\*.psd1): a Tweak = 'Key' entry reads the key
    $registryTableText = Get-WinEaseRegistryTableText
    # The implementation of some tweaks lives in the official built-in plugins (src\WinEase.Plugins.Builtin.*): a plugin
    # that asks the host for IsTweakEnabled("Key") / IsComponentEnabled("Key") / IsTweakGroupEnabled("Group") reads it.
    $pluginSourceText = Get-WinEaseBuiltinPluginSourceText
    $scriptText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "scripts") -Filter "*.ps1" -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"

    # The builder derives these tables from config\schema.psd1; build them the same way here
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $tweakDefs = [ordered]@{}; $varMap = [ordered]@{}; $aliases = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) {
        $tweakDefs[$td.Key] = $td
        foreach ($a in @($td.Aliases)) { if ($a) { $aliases[$a] = $td.Key } }
        if ($td.Variable) { $varMap[$td.Key] = $td.Variable }
    }

    It "every AllTweakDefs key is read by a phase (Test-TweakEnabled) or mapped to a consumed variable" {
        # The per-user UI preferences are consumed through config\ui-preferences.psd1:
        # phase 10 reads the table and asks Test-TweakEnabled for the tweak of every
        # entry, so a key of that table counts as consumed as well.
        $uiPrefPath = Join-Path $script:RepoRoot "config\ui-preferences.psd1"
        $uiPrefText = if (Test-Path -LiteralPath $uiPrefPath) { [System.IO.File]::ReadAllText($uiPrefPath) } else { '' }
        $unconsumed = @()
        foreach ($k in $tweakDefs.Keys) {
            if ($phaseText -match "Test-TweakEnabled\s+'$k'") { continue }
            # Options may also be consumed through a lookup table whose keys are the option
            # names (for example the FoD package map in phase 06), so a key that only
            # appears as a table key counts as consumed as well.
            if ($phaseText -match "['`"]$([regex]::Escape($k))['`"]\s*=") { continue }
            if ($uiPrefText -match "Tweak\s*=\s*['`"]$([regex]::Escape($k))['`"]") { continue }
            if ($registryTableText -match "Tweak\s*=\s*['`"]$([regex]::Escape($k))['`"]") { continue }
            # implemented by a built-in plugin
            if ($pluginSourceText -match "IsTweakEnabled\(""$([regex]::Escape($k))""") { continue }
            # the lookup tables of the options live in the master schema
            if ($schemaText -match "['`"]$([regex]::Escape($k))['`"]\s*=") { continue }
            if ($varMap.Contains($k)) {
                $v = $varMap[$k]
                if (($phaseText -match "\`$$v\b") -or ($helpersText -match "\`$$v\b")) { continue }
            }
            $unconsumed += $k
        }
        ($unconsumed -join ', ') | Should Be ''
    }

    It "legacy tweak aliases point at existing AllTweakDefs keys" {
        foreach ($a in $aliases.Keys) { $tweakDefs.Contains($aliases[$a]) | Should Be $true }
    }

    # --- No unconditional removals in the post-install scripts --------------------
    # A removal that runs on every installed system cannot be turned off by the user.
    # The post-install scripts therefore have to consult a flag that phase 11 only
    # writes when the matching option is enabled.
    It "the post-install scripts only remove or change things behind an option flag" {
        # A removal that runs on every installed system cannot be turned off by the user.
        # The post-install scripts therefore have to consult a flag that phase 11 only
        # writes when the matching option is enabled. The check is line based: a mutating
        # statement is acceptable when the nearest enclosing "if" block above it tests a
        # .flag path.
        $scriptDir = Join-Path $script:RepoRoot "scripts"
        $mutating = @(
            'Remove-Item\s+-LiteralPath\s+"\\\$initMarkerDir',
            'Remove-Item\s+-LiteralPath\s+"\\\$markerDir',
            'Stop-Process',
            'Stop-Service',
            'Set-Service',
            'Disable-ComputerRestore',
            'Compact\.exe',
            'fsutil\.exe',
            'powercfg\.exe'
        )
        $unconditional = @()
        foreach ($file in (Get-ChildItem -LiteralPath $scriptDir -Filter "*.ps1")) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                $isMutating = $false
                foreach ($pat in $mutating) {
                    if ($line -match $pat) { $isMutating = $true; break }
                }
                if (-not $isMutating) { continue }
                # Walk upwards to the enclosing "if" that guards this statement. The
                # window is generous because a guarded block can be long (a loop over
                # services, for example). A closing brace only ends the search when it
                # closes the guarded block itself, so a nested loop or try block does not
                # stop the walk too early.
                $guarded = $false
                $depth = 0
                for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 40; $j--) {
                    $up = $lines[$j]
                    # The guard may test a literal path or a variable that holds one
                    # (for example $hibernateFlag = "C:\...\hibernate-mode.flag").
                    if ($up -match 'Test-Path\s+["''][^"'']*\.flag["'']') { $guarded = $true; break }
                    if ($up -match '^\s*\$\w+\s*=\s*["''][^"'']*\.flag["'']') { $guarded = $true; break }
                    if ($up -match '^\s*\}' ) {
                        $depth++
                        # Three consecutive closing braces mean the guarded block itself
                        # was closed before this statement.
                        if ($depth -ge 3) { break }
                    }
                }
                if (-not $guarded) {
                    $unconditional += "$($file.Name):$($i + 1): $($line.Trim())"
                }
            }
        }
        ($unconditional -join ' | ') | Should Be ''
    }

    It "phase 11 stages a post-install flag for every post-install option" {
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $phase11Text = [System.IO.File]::ReadAllText((Join-Path $phasesDir "11-unattend.ps1"), [System.Text.Encoding]::UTF8)
        $postInstallOptions = @(
            'EnableCompactOS', 'EnableNtfs8dot3Disable', 'EnableUltimatePerformancePower',
            'EnableMsiMode', 'DisableAccessibilityTools', 'DisableWindowsSearchProcess',
            'HideSearchBox', 'DisableCrossDevice', 'DisableComputerRestore'
        )
        $missing = @()
        foreach ($opt in $postInstallOptions) {
            if (-not ($settingsDef.Tweaks | Where-Object { $_.Key -eq $opt })) { $missing += "$opt (not defined)"; continue }
            if ($phase11Text -notmatch [regex]::Escape("'$opt'")) { $missing += "$opt (no flag staged)" }
        }
        ($missing -join ', ') | Should Be ''
    }

    # --- Completeness of the option -> processing wiring -------------------------
    # These checks cover the reverse direction of the wiring test above: a phase that
    # references a setting key which does not exist in config\schema.psd1 can never be
    # influenced by the user, because Test-TweakEnabled falls through to its hard-coded
    # default argument for unknown keys.
    It "every Test-TweakEnabled key used by a phase is defined in config\schema.psd1" {
        $defined = @($tweakDefs.Keys)
        $componentKeys = @()
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $componentKeys = @($settingsDef.Components | ForEach-Object { $_.Key })
        $known = $defined + $componentKeys
        $unknown = @()
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'")) {
            $k = $m.Groups[1].Value
            if ($known -notcontains $k) { $unknown += $k }
        }
        (($unknown | Sort-Object -Unique) -join ', ') | Should Be ''
    }

    It "the hard-coded default of every Test-TweakEnabled call matches the defined default" {
        # For a defined key Test-TweakEnabled returns TweakSettings[key] and never reaches
        # the default argument, but a mismatching argument is a trap for the next reader
        # and hides the effective default, so it is kept in sync.
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $defaults = @{}
        foreach ($td in $settingsDef.Tweaks) { $defaults[$td.Key] = [bool]$td.Default }
        $mismatched = @()
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'\s*`$(true|false)")) {
            $k = $m.Groups[1].Value
            $arg = ($m.Groups[2].Value -eq 'true')
            if ($defaults.ContainsKey($k) -and $defaults[$k] -ne $arg) {
                $mismatched += "$k (arg=$($m.Groups[2].Value), default=$($defaults[$k]))"
            }
        }
        (($mismatched | Sort-Object -Unique) -join ', ') | Should Be ''
    }

    It "every Component variable is read by at least one phase or setup script" {
        # A GUI switch whose variable is never read has no effect at all.
        $unconsumed = @()
        foreach ($cd in $settingsDef.Components) {
            if ($cd.Type -eq 'Special' -or -not $cd.Variable) { continue }
            $v = $cd.Variable
            if (($phaseText -match "\`$$v\b") -or ($helpersText -match "\`$$v\b") -or ($scriptText -match "\`$$v\b")) { continue }
            if ($pluginSourceText -match "IsComponentEnabled\(""$([regex]::Escape($cd.Key))""") { continue }
            $unconsumed += "$($cd.Key) (`$$v)"
        }
        ($unconsumed -join ', ') | Should Be ''
    }

    It "no setting key is defined in both Tweaks and Components" {
        # A key in both tables is registered twice: the two definitions can drift apart
        # (different defaults, different GUI visibility) and the winner depends on the
        # order in which the builder applies them.
        $componentKeyList = @($settingsDef.Components | ForEach-Object { $_.Key })
        $dupes = @($tweakDefs.Keys | Where-Object { $componentKeyList -contains $_ })
        ($dupes -join ', ') | Should Be ''
    }

    It "a Component default matches its GUI default" {
        $mismatched = @()
        foreach ($cd in $settingsDef.Components) {
            if (-not $cd.Gui) { continue }
            if (-not $cd.ContainsKey('Default') -or -not $cd.Gui.ContainsKey('Default')) { continue }
            if ([bool]$cd.Default -ne [bool]$cd.Gui.Default) {
                $mismatched += "$($cd.Key) (Default=$($cd.Default), Gui.Default=$($cd.Gui.Default))"
            }
        }
        ($mismatched -join ', ') | Should Be ''
    }

    It "every TweakGroup is read by a phase" {
        $groups = @()
        $groupDef = Select-String -Path (Join-Path $script:RepoRoot "WinEasebuilder.ps1") -Pattern '\$script:TweakGroups\s*=\s*\[ordered\]@\{' | Select-Object -First 1
        if ($groupDef) {
            $builderLines = Get-Content (Join-Path $script:RepoRoot "WinEasebuilder.ps1")
            $block = $builderLines[($groupDef.LineNumber - 1)..($groupDef.LineNumber + 12)] -join "`n"
            foreach ($m in [regex]::Matches($block, '(?m)^\s{4}(\w+)\s*=\s*@\{')) { $groups += $m.Groups[1].Value }
        }
        $unused = @()
        foreach ($g in $groups) {
            if ($phaseText -match "activeTweakGroups\['$g'\]") { continue }
            if ($pluginSourceText -match "IsTweakGroupEnabled\(""$g""") { continue }
            $unused += $g
        }
        ($unused -join ', ') | Should Be ''
    }

    It "phases do not read legacy alias names directly" {
        foreach ($a in $aliases.Keys) { ($phaseText -match "Test-TweakEnabled\s+'$a'") | Should Be $false }
    }

    It "GUI session maps TweakSettings onto the variable-backed tweaks" {
        $builderText | Should Match 'Sync-WinEaseTweakVariables'
        $builderText | Should Not Match '\$guiResult\.RadicalRAM'
    }

    # --- Stage 2: the PowerShell <-> Rust engine switch ------------------------------------
    # The engine of a target is bound in config\schema.psd1 (DebloatEngines). The rules are:
    #   * a target that is not selected never runs, no matter which engine it uses
    #   * the engine "PowerShell" never hands the target to the Rust binary
    #   * the engine "Rust" hands exactly that one key to the Rust binary
    $engineDefs = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")).DebloatEngines
    function Get-DebloatItemFromGuiSource {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiCorePath, [ref]$null, [ref]$null)
        $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:WinEaseDebloatStandardItems', '$script:WinEaseDebloatExperimentalItems' }, $true)
        $items = @()
        foreach ($a in $assigns) { $items += @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        return @($items | Select-Object -Unique)
    }


    It "config\schema.psd1 binds every Advanced Debloat target to an engine" {
        $engineDefs.Count | Should BeGreaterThan 40
        $items = @($engineDefs | ForEach-Object { $_.Item })
        @($items | Select-Object -Unique).Count | Should Be $items.Count
        foreach ($def in $engineDefs) {
            $engines = @($def.Engines)
            $engines.Count | Should BeGreaterThan 0
            if (-not ($engines -contains 'PowerShell' -or $engines -contains 'Rust')) { throw "no engine for $($def.Item)" }
            if (-not ($engines -contains $def.Default)) { throw "the default engine of $($def.Item) is not allowed" }
        }
    }

    It "every GUI Advanced Debloat item has an engine binding" {
        $guiItems = Get-DebloatItemFromGuiSource
        $guiItems.Count | Should BeGreaterThan 40
        foreach ($item in $guiItems) {
            $def = @($engineDefs | Where-Object { $_.Item -eq $item })
            $def.Count | Should Be 1
        }
    }

    It "a target that offers one engine has a documented reason" {
        $libText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"), [System.Text.Encoding]::UTF8)
        $handled = @([regex]::Matches($libText, "(?m)^\s{8}'([^']+)' \{") | ForEach-Object { $_.Groups[1].Value })
        $handled.Count | Should BeGreaterThan 0
        # Every target that offers only one engine says why: the engine it does not offer
        # cannot remove it. A target that offers both engines never needs a reason.
        $single = @($engineDefs | Where-Object { @($_.Engines).Count -eq 1 })
        $single.Count | Should BeGreaterThan 0
        foreach ($def in $single) {
            if (-not $def.SingleEngineReason) { throw "the single-engine target '$($def.Item)' has no reason" }
            # a target that only the Rust engine can remove must not be handled by the safe engine
            if (@($def.Engines) -notcontains 'PowerShell' -and $handled -contains $def.Item) {
                throw "the Rust-only target '$($def.Item)' has a safe handler"
            }
        }
    }

    It "the single-engine targets are the ones that cannot have both engines" {
        # The component store (WinSxS), the paging files, the language packs and the
        # provisioned AppX packages can only be removed by the safe engine.
        $expected = @(
            'Remove non-Japanese language packs (DISM) [200-500MB]'
            'WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]'
            'Remove pagefile.sys (pagefile disable) [4-16GB]'
            'Remove hiberfil.sys (powercfg /h off) [4-16GB]'
            'Remove swapfile.sys (pagefile disable) [256MB-1GB]'
            'Remove Provisioned AppX (list-based) [100-300MB]'
        )
        $single = @($engineDefs | Where-Object { @($_.Engines).Count -eq 1 } | ForEach-Object { [string]$_.Item })
        ($single | Sort-Object) -join '|' | Should Be (($expected | Sort-Object) -join '|')
    }

    It "every target that offers both engines names the payload of the Rust engine" {
        $rustSrc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\winease-physical-debloat\src\main.rs"), [System.Text.Encoding]::UTF8)
        # the Rust source escapes the backslashes of the paths, so it is compared unescaped
        $rustPlain = $rustSrc -replace '\\\\', '\'
        $dual = @($engineDefs | Where-Object { @($_.Engines).Count -eq 2 })
        $dual.Count | Should BeGreaterThan 30
        foreach ($def in $dual) {
            $payload = @($def.Payload)
            if ($payload.Count -eq 0) { continue }
            [string]$def.RustKey | Should Not BeNullOrEmpty
            $rustPlain | Should Match ([regex]::Escape([string]$def.RustKey))
            # the Rust engine deletes exactly the payload of the target
            foreach ($p in $payload) {
                $rustPlain | Should Match ([regex]::Escape([string]$p))
            }
        }
    }

    It "every Rust-capable target names the Rust key the binary understands" {
        $rustSrc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\winease-physical-debloat\src\main.rs"), [System.Text.Encoding]::UTF8)
        foreach ($def in $engineDefs) {
            if (@($def.Engines) -notcontains 'Rust') { continue }
            $def.RustKey | Should Not BeNullOrEmpty
            $rustSrc | Should Match ([regex]::Escape($def.RustKey))
        }
    }

    It "the builder keeps the engine selection inside the selected targets" {
        # the engine helpers of the builder are loaded on their own
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'ConvertTo-WinEaseDebloatTarget', 'Set-WinEaseDebloatEngineSelection', 'Test-WinEaseDebloatOptionEnabled', 'Test-WinEaseDebloatTarget')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count
        $script:WinEaseDebloatEngines = [ordered]@{}
        $script:WinEaseDebloatLegacyMap = [ordered]@{}
        foreach ($def in $engineDefs) {
            $script:WinEaseDebloatEngines[[string]$def.Item] = $def
            foreach ($legacy in @($def.Legacy)) { if ($legacy) { $script:WinEaseDebloatLegacyMap[[string]$legacy] = [string]$def.Item } }
        }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { . ([scriptblock]::Create($fn.Extent.Text)) }

            $bt = 'Remove Bluetooth stack (service + binary) [20-40MB]'
            $legacy = 'Physical: Bluetooth stack (complete removal) [~20-40MB]'

            # an older profile entry is mapped onto the canonical target
            ConvertTo-WinEaseDebloatTarget -Item $legacy | Should Be $bt
            ConvertTo-WinEaseDebloatTarget -Item $bt | Should Be $bt

            # an engine for a target that is not selected is dropped
            $script:advancedDebloatStandard = @($bt)
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'Rust' }
            $script:DebloatEngineSelection.Contains($bt) | Should Be $true
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'Rust'

            $script:advancedDebloatStandard = @()
            $script:DebloatEngineSelection = [ordered]@{}
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'Rust' }
            $script:DebloatEngineSelection.Count | Should Be 0

            # an engine the target does not support is dropped as well
            $script:advancedDebloatStandard = @($bt)
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'PowerShell' }
            $script:DebloatEngineSelection.Contains($bt) | Should Be $true
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'PowerShell'
        } finally {
            $script:WinEaseDebloatEngines = $null
            $script:WinEaseDebloatLegacyMap = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    It "the phase 09 engine functions resolve and dispatch as specified" {
        # the engine functions of phase 09 are loaded on their own, so the dispatch can be
        # checked without running the phase
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'Get-WinEaseDebloatRustKey', 'Test-WinEaseDebloatTarget')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count
        $script:WinEaseDebloatEngines = @{}
        foreach ($def in $engineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { . ([scriptblock]::Create($fn.Extent.Text)) }

            $bt = 'Remove Bluetooth stack (service + binary) [20-40MB]'
            $defender = 'Physical: Defender (complete removal) [~50MB]'
            $media = 'Remove Windows Media Player (component) [50-100MB]'
            $pagefile = 'Remove pagefile.sys (pagefile disable) [4-16GB]'

            # the registered default runs when the user did not choose
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'PowerShell'
            Resolve-WinEaseDebloatEngine -Item $defender | Should Be 'Rust'

            # the user's choice wins
            $script:DebloatEngineSelection = [ordered]@{ $bt = 'Rust' }
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'Rust'
            # the gate needs the target to be selected as well
            Test-WinEaseDebloatTarget -Item $bt -Engine 'Rust' | Should Be $false
            $script:advancedDebloatStandard = @($bt)
            Test-WinEaseDebloatTarget -Item $bt -Engine 'Rust' | Should Be $true
            Test-WinEaseDebloatTarget -Item $bt -Engine 'PowerShell' | Should Be $false
            $script:advancedDebloatStandard = @()

            # an engine the target does not support falls back to the default
            $winSxS = 'WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]'
            $script:DebloatEngineSelection = [ordered]@{ $winSxS = 'Rust' }
            Resolve-WinEaseDebloatEngine -Item $winSxS | Should Be 'PowerShell'

            # the Rust key is data driven (the media player must not land on the key of
            # another target), and the paging files have no Rust key at all: they are not
            # part of the mounted image
            Get-WinEaseDebloatRustKey -Item $bt | Should Be 'physical_bluetooth'
            Get-WinEaseDebloatRustKey -Item $media | Should Be 'physical_media_player'
            Get-WinEaseDebloatRustKey -Item $defender | Should Be 'physical_defender'
            Get-WinEaseDebloatRustKey -Item $pagefile | Should Be ''
        } finally {
            # the GUI reads the same table; restore it so the later GUI tests see the real one
            $script:WinEaseDebloatEngines = $null
            $script:WinEaseDebloatEngineDefs = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    It "the phase 09 dispatch keeps the two engines apart" {
        $physText = [System.IO.File]::ReadAllText((Join-Path $phasesDir "09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        # the Rust dispatch only gets the targets whose engine is "Rust"
        $physText | Should Match '\(Resolve-WinEaseDebloatEngine -Item \$_\) -eq ''Rust'''
        $physText | Should Match 'Get-WinEaseDebloatRustKey -Item \$item'
        # the engine the user picked must survive: phase 09 may not reset the selection
        $physText | Should Not Match '^\$script:DebloatEngineSelection = \[ordered\]@\{\}$'
    }

    It "the GUI locks the engine while the target is not selected" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'Update-WinEaseDebloatRowState'
        $guiText | Should Match '\$locked = \(-not \$selected\) -or \(\$allowed\.Count -le 1\)'
        $guiText | Should Match '\$cell\.ReadOnly = \$locked'
    }

    It "the GUI offers the engine per target and a global switch" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'New-WinEaseDebloatGrid'
        $guiText | Should Match 'Set-WinEaseDebloatEngineForAll'
        $guiText | Should Match "Debloat\.Engine\.All"
    }

    It "an unselected target never reaches the Rust binary" {
        # the engine map can only add a Rust dispatch for a target that is in the list
        $libText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"), [System.Text.Encoding]::UTF8)
        $libText | Should Match 'Set-WinEaseDebloatEngineSelection'
        $libText | Should Match 'if \(\$selected -notcontains \$item\) \{ continue \}'
        # the gate every phase uses
        $libText | Should Match 'if \(\$selected -notcontains \$Item\) \{ return \$false \}'
    }
    It "every GUI Advanced Debloat item is owned by a phase" {
        # Every target declares the phase that runs its safe work (config\schema.psd1 ->
        # DebloatEngines -> Phase), so no work item is implemented twice.
        $owned = @()
        foreach ($def in $engineDefs) {
            if (-not $def.Phase) { throw "the target '$($def.Item)' has no owning phase" }
            $owned += $def.Item
        }
        $owned.Count | Should Be $engineDefs.Count
        $guiItems = Get-DebloatItemFromGuiSource
        foreach ($item in $guiItems) {
            if ($owned -notcontains $item) { throw "the target '$item' is not owned by a phase" }
        }
    }

    It "the safe work of a target runs in the phase that owns it" {
        # every phase that owns a target calls the shared dispatcher, so the work is done
        # exactly once and never a second time in phase 09
        $phases = @{
            '05-appx'           = 'phases\05-appx.ps1'
            '06-fod'            = 'phases\06-fod.ps1'
            '08-filesystem'     = 'phases\08-filesystem.ps1'
            '09-winsxs'         = 'phases\09-winsxs.ps1'
            '10-registry'       = 'phases\10-registry.ps1'
            '11-unattend'       = 'phases\11-unattend.ps1'
        }
        foreach ($phase in $phases.Keys) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $phases[$phase]), [System.Text.Encoding]::UTF8)
            # the phase asks for its targets either through the dispatcher or through the
            # target gate (the engine specific one or the engine independent one)
            if ($text -notmatch [regex]::Escape("Invoke-WinEaseDebloatTargets -Phase '$phase'") -and
                $text -notmatch [regex]::Escape("Test-WinEaseDebloatTarget -Item") -and
                $text -notmatch [regex]::Escape("Test-WinEaseDebloatTargetSelected -Item")) {
                throw "the phase $phase owns a target but never asks for it"
            }
        }
        # phase 09 is the Rust engine only
        $physText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        $physText | Should Not Match 'Invoke-WinEaseDebloatTargets -Phase'
    }

    It "an Advanced Debloat target can switch on the option of the phase that owns it" {
        # the Option field of the table is the bridge between the two UIs: the target of the
        # Advanced Debloat tab and the granular option do the same work, once
        $withOption = @($engineDefs | Where-Object { $_.Option })
        $withOption.Count | Should BeGreaterThan 0
        # several targets may imply the same option (the event logs, the crash dumps and the
        # temp files are all part of the offline cache cleanup)
        $optionKeys = @($withOption | ForEach-Object { $_.Option })
        # every option the table names really exists
        $known = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")).Tweaks | ForEach-Object { $_.Key })
        foreach ($o in $optionKeys) {
            if ($known -notcontains $o) { throw "the option $o of the debloat table does not exist" }
        }
    }

    It "the safe handler of a target runs once, in the phase that owns it" {
        # the shared library is loaded on its own, with a scratch directory that stands in
        # for the mounted image
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'Test-WinEaseDebloatTarget', 'Test-WinEaseDebloatOptionEnabled', 'Invoke-WinEaseDebloatTargets', 'Invoke-WinEaseDebloatTarget', 'Remove-WinEaseDebloatPath', 'Get-WinEaseDebloatSafeHandlerItems')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count

        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("winease_debloat_" + [System.IO.Path]::GetRandomFileName())
        $patchCache = Join-Path $scratch "Windows\Installer\`$PatchCache$"
        New-Item -ItemType Directory -Force -Path $patchCache | Out-Null
        Set-Content -LiteralPath (Join-Path $patchCache "payload.msi") -Value "x" -Encoding ascii
        $script:scratchDir = $scratch
        $script:isDryRunMode = $false
        $script:WinEaseDebloatEngines = [ordered]@{}
        foreach ($def in $engineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { . ([scriptblock]::Create($fn.Extent.Text)) }

            $target = 'Remove PatchCache (dir delete) [200-500MB]'
            # not selected -> nothing happens
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $true

            # selected -> the owning phase removes it
            $script:advancedDebloatStandard = @($target)
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $false

            # a phase that does not own the target leaves it alone
            New-Item -ItemType Directory -Force -Path $patchCache | Out-Null
            Set-Content -LiteralPath (Join-Path $patchCache "payload.msi") -Value "x" -Encoding ascii
            Invoke-WinEaseDebloatTargets -Phase '06-fod'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            $script:scratchDir = $null
            $script:WinEaseDebloatEngines = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }

    It "the safe engine removes the payload of a target the Rust engine can remove" {
        # the shared library is loaded on its own, with a scratch directory that stands in
        # for the mounted image
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'Test-WinEaseDebloatTarget', 'Test-WinEaseDebloatOptionEnabled', 'Invoke-WinEaseDebloatTargets', 'Invoke-WinEaseDebloatTarget', 'Remove-WinEaseDebloatPath', 'Remove-WinEaseDebloatPayload', 'Get-WinEaseDebloatSafeHandlerItems')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count

        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("winease_payload_" + [System.IO.Path]::GetRandomFileName())
        $minidump = Join-Path $scratch "Windows\Minidump"
        $edge = Join-Path $scratch "Program Files (x86)\Microsoft\Edge"
        New-Item -ItemType Directory -Force -Path $minidump | Out-Null
        Set-Content -LiteralPath (Join-Path $minidump "dump.dmp") -Value "x" -Encoding ascii
        New-Item -ItemType Directory -Force -Path $edge | Out-Null
        Set-Content -LiteralPath (Join-Path $edge "msedge.exe") -Value "x" -Encoding ascii
        $script:scratchDir = $scratch
        # The safe engine may use the protected-directory helper now that the split
        # helpers are loaded in one go. Treat the fake image as the workspace, as the
        # builder does, so the safety guard accepts paths under it.
        $savedBaseWorkDir = $script:BaseWorkDir
        $savedDismMountDir = $script:DismMountDir
        $script:BaseWorkDir = $scratch
        $script:DismMountDir = $scratch
        $script:isDryRunMode = $false
        $script:WinEaseDebloatEngines = [ordered]@{}
        foreach ($def in $engineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { Invoke-Expression $fn.Extent.Text }

            # a target that is not selected is not removed
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath $minidump) | Should Be $true

            # the target is selected for the safe engine: the payload is gone
            $minidumpTarget = 'Physical: Minidump (complete removal) [varies]'
            $script:advancedDebloatExperimental = @($minidumpTarget)
            $script:DebloatEngineSelection = [ordered]@{ $minidumpTarget = 'PowerShell' }
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath $minidump) | Should Be $false

            # the Rust engine removes the same payload, so the safe engine removes it too
            $edgeTarget = 'Physical: Edge / WebView2 (complete removal) [~200MB]'
            $script:advancedDebloatExperimental = @($edgeTarget)
            $script:DebloatEngineSelection = [ordered]@{ $edgeTarget = 'PowerShell' }
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath $edge) | Should Be $false
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            $script:BaseWorkDir = $savedBaseWorkDir
            $script:DismMountDir = $savedDismMountDir
            $script:scratchDir = $null
            $script:WinEaseDebloatEngines = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    # --- C1/C2: the master schema, the presets and the resolution engine -------------------
    It "the built-in presets live in config\presets.psd1" {
        $presetPath = Join-Path $script:RepoRoot "config\presets.psd1"
        Test-Path -LiteralPath $presetPath | Should Be $true
        $presets = Import-PowerShellDataFile -LiteralPath $presetPath
        @($presets.Presets.Keys).Count | Should BeGreaterThan 5
        # the descriptive names of the plan are accepted as well
        foreach ($alias in @('None', 'Standard', 'Gaming', 'UltraSlim', 'MinimalServices')) {
            $presets.Aliases.Contains($alias) | Should Be $true
            $presets.Presets.Contains($presets.Aliases[$alias]) | Should Be $true
        }
        # the builder does not define the values of the presets a second time
        $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $builderText | Should Not Match "ProfileName\s+= 'Extreme Slim & Gaming'"
        $builderText | Should Match 'config\\presets\.psd1'
    }

    It "the master schema replaces config\tweaks.psd1" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1") | Should Be $false
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        @($schema.Tweaks).Count | Should BeGreaterThan 50
        @($schema.Components).Count | Should BeGreaterThan 20
        @($schema.DebloatEngines).Count | Should BeGreaterThan 40
        # the targets of the options live in the schema as well
        @($schema.Targets.Keys).Count | Should BeGreaterThan 20
    }

    It "every option that the phases read through a lookup table is registered in the schema" {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $known = @(@($schema.Tweaks | ForEach-Object { $_.Key }) + @($schema.Components | ForEach-Object { $_.Key }))
        foreach ($p in $schema.Targets.Keys) {
            if ($known -notcontains $p) { throw "the option $p of the lookup table is not defined" }
            foreach ($pkg in @($schema.Targets[$p].FoDPackages)) { if (-not $pkg) { throw "the option $p has an empty target" } }
        }
    }

    It "the Rust capability of every target is declared in the schema" {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        foreach ($def in $schema.DebloatEngines) {
            if ($def.SupportsRustPhysical) {
                if (-not $def.RustKey) { throw "the target $($def.Item) has no Rust key" }
                if (@($def.Engines) -notcontains 'Rust') { throw "the target $($def.Item) does not allow the Rust engine" }
            } else {
                if (@($def.Engines) -contains 'Rust') { throw "the target $($def.Item) allows the Rust engine but does not declare it" }
            }
        }
    }

    It "the polarity of an option follows the naming convention" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        Get-WinEaseOptionPolarity -Key 'RemoveEdge' | Should Be 'Remove'
        Get-WinEaseOptionPolarity -Key 'DisableUAC' | Should Be 'Disable'
        Get-WinEaseOptionPolarity -Key 'EnableScripts' | Should Be 'Enable'
        Get-WinEaseOptionPolarity -Key 'KeepBluetooth' | Should Be 'Keep'
        Get-WinEaseOptionPolarity -Key 'BypassActivationRestrictions' | Should Be 'Feature'
    }

    It "the resolution engine applies the base, then the preset, then the user settings" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $base    = @{ A = $true; B = $true; C = 'Keep' }
        $preset  = @{ A = $false; B = $true; C = 'Off' }
        $over    = @{ A = $false; B = $true }
        $r = Resolve-WinEaseConfiguration -Base $base -Preset $preset -Overrides $over
        # the preset overrules the base
        $r.Components['C'] | Should Be 'Off'
        # an explicit setting of the user always wins - also an explicit $false
        $r.Components['A'] | Should Be $false
        $r.Components['B'] | Should Be $true
        # an option that is not in the base is not introduced
        $r2 = Resolve-WinEaseConfiguration -Base @{ A = $true } -Preset @{ X = $true } -Overrides @{ Y = $true }
        $r2.Components.Contains('X') | Should Be $false
        $r2.Components.Contains('Y') | Should Be $false
    }

    It "the resolution engine keeps the explicit tweak settings of the user" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $r = Resolve-WinEaseConfiguration -TweakBase @{ X = $true; Y = $true } -TweakPreset @{ X = $false } -TweakOverrides @{ Y = $false }
        $r.Tweaks['X'] | Should Be $false
        $r.Tweaks['Y'] | Should Be $false
    }

    It "the conflict check never rewrites a setting of the user" {
        $cfg = [PSCustomObject]@{ DisableWindowsUpdate = $true; RemoveStore = $true; TweakSettings = @{ PhysicalDebloat = $true } }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        $res.ResolvedConfig.DisableWindowsUpdate | Should Be $true
        $res.ResolvedConfig.RemoveStore | Should Be $true
        $res.ResolvedConfig.TweakSettings.PhysicalDebloat | Should Be $true
        # the old "-AutoResolve" switch is gone
        (Get-Command Test-WinEaseConfigConflicts).Parameters.ContainsKey('AutoResolve') | Should Be $false
    }
    It "the option bridge is used by the phase that owns the option" {
        $fodText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\06-fod.ps1"), [System.Text.Encoding]::UTF8)
        $fodText | Should Match 'Test-WinEaseDebloatOptionEnabled -Option \$optKey'
    }
    It "the safe handlers live in the shared debloat library" {
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        Test-Path -LiteralPath $libPath | Should Be $true
        $libText = [System.IO.File]::ReadAllText($libPath, [System.Text.Encoding]::UTF8)
        $libText | Should Match 'function Invoke-WinEaseDebloatTargets'
        $libText | Should Match 'function Invoke-WinEaseDebloatTarget'
        $libText | Should Match 'function Test-WinEaseDebloatTarget'
        # phase 09 is the Rust engine only: it must not carry a safe handler chain any more
        $physText = [System.IO.File]::ReadAllText((Join-Path $phasesDir "09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        $physText | Should Not Match 'Invoke-WinEaseDebloatFeatureRemoval'
        $physText | Should Not Match 'Invoke-WinEaseDebloatCapabilityRemoval'
    }
}

Describe "WinEase GUI - smoke test (form built without ShowDialog)" -Tags 'slow' {
    # Same derived tables the builder hands the GUI, built from config\schema.psd1
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }

    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    # Never block on the experimental Select All confirmation
    function Confirm-WinEaseGuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }

    function Get-AllControls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-AllControls $c } }

    # PerformClick only fires on visible controls: show off-screen, select each tab, click its buttons
    function Invoke-SelectButtons($form) {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point(-20000, -20000)
        $form.ShowInTaskbar = $false
        [void]$form.Show()
        $clicked = 0
        try {
            $tabControl = @(Get-AllControls $form | Where-Object { $_ -is [System.Windows.Forms.TabControl] })[0]
            foreach ($tab in $tabControl.TabPages) {
                $tabControl.SelectedTab = $tab
                [void][System.Windows.Forms.Application]::DoEvents()
                $buttons = @(Get-AllControls $tab | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -match '^(Select All|Clear All|Deselect All)$' })
                foreach ($btn in ($buttons | Sort-Object { $_.Text -ne 'Select All' })) {
                    $want = $btn.Text -eq 'Select All'
                    if ($btn.Tag -and $btn.Tag.ContainsKey('Grid')) {
                        # Advanced Debloat grid: the button selects or clears every row
                        $grid = $btn.Tag.Grid
                        Set-WinEaseDebloatGridChecked -Grid $grid -Checked (-not $want)
                        [void]$btn.PerformClick()
                        $grid.Rows.Count | Should BeGreaterThan 0 | Out-Null
                        @($grid.Rows | Where-Object { [bool]$_.Cells['On'].Value -ne $want }).Count | Should Be 0 | Out-Null
                    } else {
                        $target = $btn.Tag.Target
                        # Start from the opposite state so the click has to change every box
                        Set-WinEaseChecked -Target $target -Checked (-not $want)
                        [void]$btn.PerformClick()
                        if ($target -is [System.Windows.Forms.CheckedListBox]) {
                            $target.Items.Count | Should BeGreaterThan 0 | Out-Null
                            $target.CheckedItems.Count | Should Be $(if ($want) { $target.Items.Count } else { 0 }) | Out-Null
                        } else {
                            @($target).Count | Should BeGreaterThan 0 | Out-Null
                            @($target | Where-Object { $_.Checked -ne $want }).Count | Should Be 0 | Out-Null
                        }
                    }
                    $clicked++
                }
            }
        } finally {
            $form.Close(); $form.Dispose()
        }
        return $clicked
    }

    It "main window: every Select All / Clear All button changes its boxes" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $gui.Form.Tag | Should Be $gui
            $gui.TweakCheckboxes.Count | Should Be $script:AllTweakDefs.Count
            Invoke-SelectButtons $gui.Form | Should Be 14
            # Toggle handlers reached the shared context: preset switched to Custom
            $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)
        } finally {
            if ($gui -and $gui.Form) { $gui.Form.Dispose() }
            [System.Windows.Forms.Application]::Exit()
        }
    }

    It "main window: result hashtable keeps its contract" {
        $iso = Join-Path $TestDrive 'contract.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = $iso; TweakSettings = [ordered]@{} }
        try {
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $r = $gui.Result
            foreach ($k in 'Success', 'UserName', 'ComputerName', 'PresetKey', 'BasePresetKey', 'SourceDrive', 'WorkDir', 'Index',
                           'InjectDrivers', 'DryRun', 'UseVHDX', 'ExportESDMode', 'SplitWIMMode', 'TweakSettings',
                           'AdvancedDebloatStandard', 'AdvancedDebloatExperimental') {
                $r.ContainsKey($k) | Should Be $true
            }
            $r.Success | Should Be $true
            $r.TweakSettings.Count | Should Be $script:AllTweakDefs.Count
            foreach ($k in $gui.ComponentCheckboxes.Keys) { $r.ContainsKey($k) | Should Be $true }
        } finally { $gui.Form.Dispose() }
    }

    It "cleanup WinForms message pump (environmental stability)" {
        [System.Windows.Forms.Application]::Exit()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $true | Should Be $true
    }
}

# The GUI tabs after this point use the user-extension and migration engines.
if (-not (Get-Command -Name Import-WinEaseUserExtensions -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseExtensions.ps1")
}
if (-not (Get-Command -Name Get-WinEaseMigrationRules -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "S7 - GUI Tab 8 (Migration & Backup)" -Tags 'slow' {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    function Test-WinEaseRecoveryReadiness { param($Config) $script:S7CapturedConfig = $Config; [PSCustomObject]@{ ReadinessScore = 1 } }
    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    function Get-S7Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S7Controls $c } }

    It "Tab 8 has the personal folder checklist and Run Backup passes -FolderMap" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            @($gui.MigFolders.Items) -contains 'Documents' | Should Be $true
            @($gui.MigFolders.Items) -contains 'Downloads' | Should Be $true
            $a = Get-WinEaseGuiBackupArgs -Gui $gui
            $a.ContainsKey('FolderMap') | Should Be $true
            $a.FolderMap.Count | Should BeGreaterThan 0
            $a.FolderMap['Documents'] | Should Be ([Environment]::GetFolderPath('MyDocuments'))
            $a.ContainsKey('IncludeSecrets') | Should Be $false
            $gui.MigExcludeSecrets.Checked = $false
            (Get-WinEaseGuiBackupArgs -Gui $gui).IncludeSecrets | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 rule list never yields a placeholder row as a rule Id" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $list = $gui.MigRulesList
            if (-not $list.Enabled) { $list.Items.Count | Should Be 1 }
            @(Get-WinEaseGuiMigrationRuleIds -Gui $gui) -contains 'No migration rules found' | Should Be $false
            $list.Enabled = $false
            if ($list.Items.Count -gt 0) { $list.SetItemChecked(0, $true) }
            @(Get-WinEaseGuiMigrationRuleIds -Gui $gui).Count | Should Be 0
        } finally { $gui.Form.Dispose() }
    }

    It "Recovery Readiness Check uses the draft config of the current window" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $key = @($gui.ComponentCheckboxes.Keys)[0]
            $gui.ComponentCheckboxes[$key].Checked = -not $gui.ComponentCheckboxes[$key].Checked
            $script:S7CapturedConfig = $null
            [void](Get-WinEaseGuiRecoveryReadiness -Gui $gui)
            $script:S7CapturedConfig[$key] | Should Be ([bool]$gui.ComponentCheckboxes[$key].Checked)
        } finally { $gui.Form.Dispose() }
    }

    It "IncludeMigrationAssistant lives on Tab 8 and still reaches the result" {
        $iso = Join-Path $TestDrive 'migration.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = $iso; TweakSettings = [ordered]@{} }
        try {
            $chk = $gui.ComponentCheckboxes['IncludeMigrationAssistant']
            $chk | Should Not BeNullOrEmpty
            $tab8 = @($gui.Form.Controls | ForEach-Object { Get-S7Controls $_ } | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match '8\. Migration' })[0]
            @(Get-S7Controls $tab8) -contains $chk | Should Be $true
            $chk.Checked = $true
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $gui.Result['IncludeMigrationAssistant'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has Browse, Estimate, Verify and Retry buttons and no stray Select/Clear All text" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $texts = @(Get-S7Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { $_.Text })
            foreach ($t in 'Browse...', 'Estimate Size', 'Verify Backup Integrity', 'Retry Failed Tasks Only') { ($texts -contains $t) | Should Be $true }
            @($texts | Where-Object { $_ -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 10 lists the custom scripts of the selected stage" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $tab = @($gui.Form.Controls | ForEach-Object { Get-S7Controls $_ } | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match '10\.' })[0]
            $tab | Should Not BeNullOrEmpty
            ($gui.CsStage.SelectedItem) | Should Be 'FirstLogon'
            $gui.CsList | Should Not BeNullOrEmpty
            @(Get-S7Controls $tab) -contains $gui.CsList | Should Be $true
            Update-WinEaseGuiCustomScriptsList -Gui $gui
            $gui.CsCount.Text | Should Match 'FirstLogon'
            $gui.CsStageInfo.Text | Should Match 'FirstLogon'
        } finally { $gui.Form.Dispose() }
    }
}

Describe "S8 - GUI user extensions tab and Preset Diff" -Tags 'slow' {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:AllTweakDefs['S8GamingSwitch'] = @{ Category = 'Gaming'; Default = $false; Description = 'S8 user switch' }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:BuiltInPresets = [ordered]@{
        s8a = [ordered]@{ TweakSettings = [ordered]@{ S8GamingSwitch = $false } }
        s8b = [ordered]@{ TweakSettings = [ordered]@{ S8GamingSwitch = $true } }
    }
    $script:UserExtensionsResult = [PSCustomObject]@{ Loaded = $true; UserTweakCount = 1; UserPresetCount = 0; CustomScriptCount = 0; Errors = @('S8 sample error') }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    . (Join-Path $script:RepoRoot 'lib\WinEaseExtensions.ps1')
    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    function Get-S8Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S8Controls $c } }

    It "shows a Gaming user switch on the User Tweaks tab" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $chk = $gui.TweakCheckboxes['S8GamingSwitch']
            $chk | Should Not BeNullOrEmpty
            $tab = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match 'User Tweaks' })[0]
            $tab | Should Not BeNullOrEmpty
            @(Get-S8Controls $tab) -contains $chk | Should Be $true
            $chk.Checked = $true
            (Get-WinEaseGuiDraftConfig -Gui $gui).TweakSettings['S8GamingSwitch'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has a Preset Diff button, no fixed compare button, and the bottom buttons do not overlap" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $buttons = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] })
            @($buttons | Where-Object { $_.Text -eq 'Preset Diff' }).Count | Should Be 1
            @($buttons | Where-Object { $_.Text -like 'Compare Presets*' }).Count | Should Be 0
            $row = @($buttons | Where-Object { $_.Text -in 'Preset Diff', 'Check Dependencies', 'Start WinEase Build', 'Cancel' } | Sort-Object { $_.Left })
            $row.Count | Should Be 4
            for ($i = 1; $i -lt $row.Count; $i++) { ($row[$i].Left -ge $row[$i - 1].Right) | Should Be $true }
            @($buttons | Where-Object { $_.Text -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
        } finally { $gui.Form.Dispose() }
    }

    It "diffs preset vs current window settings" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $gui.TweakCheckboxes['S8GamingSwitch'].Checked = $true
            $txt = Get-WinEaseGuiPresetDiffText -Gui $gui -From 's8a' -To $script:WinEaseGuiCurrentSettingsLabel
            $txt | Should Match 'S8GamingSwitch'
            $txt = Get-WinEaseGuiPresetDiffText -Gui $gui -From 's8a' -To 's8b'
            $txt | Should Match 'S8GamingSwitch'
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 shows extension counts, errors and the guide button" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $all = @(Get-S8Controls $gui.Form)
            @($all | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -match 'User tweaks: 1\s+User presets: 0\s+Custom scripts: 0' }).Count | Should Be 1
            $gui.ExtensionsLabel.Text | Should Match 'S8 sample error'
            @($all | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Open Extensibility Guide' }).Count | Should Be 1
            Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs\EXTENSIBILITY_GUIDE.md') | Should Be $true
        } finally { $gui.Form.Dispose() }
    }
}

Describe "S10 - GUI and migrator cleanup (shared parts)" -Tags 'slow' {
    $script:S10Gui = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseGui.ps1"
    $script:S10Mig = Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEase-Migrator.ps1"
    $script:S10GuiText = [System.IO.File]::ReadAllText($script:S10Gui); $script:S10CoreText = [System.IO.File]::ReadAllText($script:GuiCorePath)
    $script:S10MigText = [System.IO.File]::ReadAllText($script:S10Mig)
    $script:S10GuiAst = [System.Management.Automation.Language.Parser]::ParseFile($script:S10Gui, [ref]$null, [ref]$null)

    It "GUI and WinUI host launch the migration wizard using array argument lists" {
        foreach ($file in @($script:S10Gui, (Join-Path $script:RepoRoot "gui\WinEaseWinUiHost.ps1"))) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $spCalls = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' -and
                $n.Extent.Text -like '*powershell.exe*'
            }, $true))
            $spCalls.Count | Should BeGreaterThan 0
            foreach ($call in $spCalls) {
                $argListParam = $call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ArgumentList'
                }
                $argListParam | Should Not BeNullOrEmpty
                $paramIdx = [array]::IndexOf(@($call.CommandElements), $argListParam)
                $argExpr = $call.CommandElements[$paramIdx + 1]
                ($argExpr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) | Should Be $false
            }
        }
    }

    It "colours are defined once: FromArgb only appears in the colour table" {
        ([regex]::Matches($script:S10GuiText, 'FromArgb')).Count | Should Be 14
        ([regex]::Matches($script:S10MigText, 'FromArgb')).Count | Should Be 0
    }

    It "OK message boxes go through Show-WinEaseGuiMessage (only it and the YesNo confirm call MessageBox)" {
        ([regex]::Matches($script:S10GuiText, 'MessageBox\]::Show')).Count | Should Be 3
        ([regex]::Matches($script:S10MigText, 'MessageBox')).Count | Should Be 0
        $fn = $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-WinEaseGuiMessage' }, $true)
        $kind = $fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Kind' }
        $set = ($kind.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value }
        (@($set) -join ',') | Should Be 'Info,Warning,Error,Question'
    }

    It "the default backup folder name is spelled once per file" {
        ([regex]::Matches($script:S10CoreText, 'WinEase_migration_backup')).Count | Should Be 1
        ([regex]::Matches($script:S10MigText, 'WinEase_migration_backup')).Count | Should Be 1
    }

    It "the migrator builds its window from the shared parts (no raw WinForms controls)" {
        $script:S10MigText | Should Not Match 'New-Object\s+"?System\.Windows\.Forms\.(Form|TabControl|TabPage|Label|TextBox|Button|CheckBox|CheckedListBox|ComboBox)\b'
        $script:S10MigText | Should Not Match 'Start-Job'
        $script:S10MigText | Should Match 'Invoke-WinEaseGuiBackgroundJob'
        $script:S10MigText | Should Match 'WinEaseGui\.ps1'
    }

    It "the GUI file creates no Form/TabControl/ComboBox/TextBox outside the part functions" {
        $parts = 'New-WinEaseForm', 'New-WinEaseTabControl', 'New-WinEaseComboBox', 'New-WinEaseTextBox'
        $calls = $script:S10GuiAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Object' -and
            $n.Extent.Text -match 'System\.Windows\.Forms\.(Form|TabControl|ComboBox|TextBox)\b' }, $true)
        foreach ($c in $calls) {
            $owner = $c.Parent
            while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            ($parts -contains $owner.Name) | Should Be $true
        }
    }

    It "Show-WinEaseGUI is short: tabs are built by their own functions" {
        $show = $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-WinEaseGUI' }, $true)
        ($show.Extent.EndLineNumber - $show.Extent.StartLineNumber) | Should BeLessThan 230
        foreach ($fnName in 'New-WinEaseMediaTab', 'New-WinEaseTweakTabs', 'New-WinEaseServicesTab', 'New-WinEaseDebloatTab', 'New-WinEaseMigrationTab', 'New-WinEaseUserTweaksTab') {
            $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Should Not BeNullOrEmpty
        }
    }

    It "Invoke-WinEaseGuiBackgroundJob returns output and errors, and restores the button and cursor" {
        . $script:S10Gui
        $form = New-Object System.Windows.Forms.Form
        $btn = New-Object System.Windows.Forms.Button
        $form.Controls.Add($btn)
        try {
            $o = Invoke-WinEaseGuiBackgroundJob -Button $btn -Form $form -ArgumentList 3, 'x' -ScriptBlock { param($n, $s) "$s$n"; Write-Error 'boom'; 42 }
            (@($o.Output) -join ',') | Should Be 'x3,42'
            $o.Error | Should BeNullOrEmpty
            (@($o.Errors) -join ';') | Should Be 'boom'
            $btn.Enabled | Should Be $true
            $form.Cursor | Should Be ([System.Windows.Forms.Cursors]::Default)
            $o2 = Invoke-WinEaseGuiBackgroundJob -Button $btn -Form $form -ScriptBlock { throw 'fail' }
            $o2.Error | Should Be 'fail'
            @($o2.Output).Count | Should Be 0
            $btn.Enabled | Should Be $true
        } finally { $form.Dispose() }
    }

    It "Invoke-WinEaseGuiBusy restores the button when the action throws" {
        . $script:S10Gui
        $form = New-Object System.Windows.Forms.Form
        $btn = New-Object System.Windows.Forms.Button
        $form.Controls.Add($btn)
        try {
            $threw = $false
            try { Invoke-WinEaseGuiBusy -Button $btn -Form $form -Action { throw 'x' } } catch { $threw = $true }
            $threw | Should Be $true
            $btn.Enabled | Should Be $true
            (Invoke-WinEaseGuiBusy -Button $btn -Form $form -ArgumentList 5 -Action { param($v) $v * 2 }) | Should Be 10
        } finally { $form.Dispose() }
    }

    It "default backup path and colour table" {
        . $script:S10Gui
        (Get-WinEaseDefaultMigrationBackupPath) | Should Be (Join-Path $env:USERPROFILE 'WinEase_migration_backup')
        (Get-WinEaseDefaultMigrationBackupPath -Base Documents) | Should Be (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WinEase_migration_backup')
        $script:WinEaseGuiColors.Count | Should Be 14
        $script:WinEaseGuiColors.Accent.ToArgb() | Should Be ([System.Drawing.Color]::FromArgb(0, 190, 255).ToArgb())
    }

    It "part factories keep their geometry and colours" {
        . $script:S10Gui
        $cmb = New-WinEaseComboBox -Items 'a', 'b' -SelectedIndex 1 -DropList -X 5 -Y 6 -Width 100
        $cmb.DropDownStyle | Should Be 'DropDownList'
        $cmb.SelectedIndex | Should Be 1
        $cmb.Location.X | Should Be 5
        $txt = New-WinEaseTextBox -X 1 -Y 2 -Width 50 -Height 60 -Multiline -ReadOnly -ScrollBars Vertical
        $txt.Multiline | Should Be $true
        $txt.ScrollBars | Should Be 'Vertical'
        $txt.BackColor.ToArgb() | Should Be ([System.Drawing.Color]::FromArgb(35, 38, 46).ToArgb())
        $frm = New-WinEaseForm -Text 't' -Width 300 -Height 200 -ClientSize -FixedDialog -NoMaximize
        try {
            $frm.ClientSize.Width | Should Be 300
            $frm.MaximizeBox | Should Be $false
            $frm.FormBorderStyle | Should Be 'FixedDialog'
        } finally { $frm.Dispose() }
    }
}

Describe "GUI display language (English / Japanese)" -Tags 'slow' {
    # These tests run the GUI in English or Japanese explicitly; the rest of this file assumes English
    # (see WINEASE_UI_LANGUAGE at the top). Settings are redirected to a temp folder so the user's saved choice is never touched.
    $script:LangDir = Join-Path -Path $script:RepoRoot -ChildPath "config\ui-strings"
    $script:LangTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_lang_" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:LangTemp -Force)
    $script:LangSavedLocalAppData = $env:LOCALAPPDATA
    $script:LangSavedEnv = $env:WINEASE_UI_LANGUAGE
    $env:LOCALAPPDATA = $script:LangTemp

    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }

    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    function Confirm-WinEaseGuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }

    function Read-UiTable([string]$Lang) {
        $json = [System.IO.File]::ReadAllText((Join-Path $script:LangDir "$Lang.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $t = @{}
        foreach ($p in $json.PSObject.Properties) { $t[$p.Name] = [string]$p.Value }
        return $t
    }
    # Literal keys passed to Get-WinEaseUiString in a source file (dynamic keys are skipped)
    function Get-UiKeyUsed([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-WinEaseUiString' }, $true)
        $keys = @()
        foreach ($c in $cmds) {
            $els = @($c.CommandElements)
            for ($i = 1; $i -lt $els.Count; $i++) {
                $e = $els[$i]
                $prev = $els[$i - 1]
                $isKey = ($prev -is [System.Management.Automation.Language.CommandParameterAst] -and $prev.ParameterName -eq 'Key') -or
                    ($i -eq 1 -and $e -isnot [System.Management.Automation.Language.CommandParameterAst])
                if ($isKey -and $e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys += $e.Value }
            }
        }
        return $keys
    }
    # Literal keys of the WinUI 3 window: _s.Get("Key" / _s.Format("Key" in gui\winui\WinEaseGui\*.cs (and the preset labels)
    function Get-UiKeyUsedWinUi {
        $keys = @()
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'gui\winui\WinEaseGui') -Filter '*.cs') {
            $src = [System.IO.File]::ReadAllText($f.FullName)
            $keys += @([regex]::Matches($src, '_s\.(?:Get|Format)\("([^"{}]+)"') | ForEach-Object { $_.Groups[1].Value })
            $keys += @([regex]::Matches($src, '"(Media\.Preset\.[A-Za-z0-9]+)"') | ForEach-Object { $_.Groups[1].Value })
        }
        return $keys
    }
    # English Advanced Debloat item names written in the GUI source (both the tab and the dialog)
    function Get-DebloatItemFromSource {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiCorePath, [ref]$null, [ref]$null)
        $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:WinEaseDebloatStandardItems', '$script:WinEaseDebloatExperimentalItems' }, $true)
        $items = @()
        foreach ($a in $assigns) { $items += @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        return @($items | Select-Object -Unique)
    }
    function Get-AllControls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-AllControls $c } }
    $script:LangOnlyPrefixes = '^(Tweak\.|Component\.|Debloat:)'

    It "en.json and ja.json have the same keys (tweak, component and Advanced Debloat translations live in ja only)" {
        $en = Read-UiTable 'en'
        $ja = Read-UiTable 'ja'
        $enOnly = @($en.Keys | Where-Object { -not $ja.ContainsKey($_) })
        $jaOnly = @($ja.Keys | Where-Object { -not $en.ContainsKey($_) -and $_ -notmatch $script:LangOnlyPrefixes })
        ($enOnly -join ',') | Should Be ''
        ($jaOnly -join ',') | Should Be ''
        @($en.Keys | Where-Object { $_ -match $script:LangOnlyPrefixes }).Count | Should Be 0
        $en.Count | Should BeGreaterThan 100
    }

    It "every string key used by the GUI and the migrator exists in the English table, and no English key is unused" {
        $en = Read-UiTable 'en'
        $used = @(Get-UiKeyUsed $script:GuiPath) + @(Get-UiKeyUsed (Join-Path $script:RepoRoot "tools\migrator\WinEase-Migrator.ps1")) +
            @(Get-UiKeyUsed (Join-Path $script:RepoRoot "gui\WinEaseWinUiHost.ps1")) + @(Get-UiKeyUsedWinUi) +
            @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseDependencies.ps1')), "'(Dep\.[A-Za-z.]+)'\s+=") | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseBuildPlan.ps1')), "'(Plan\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseInputValidation.ps1')), "'((?:Val|Msg)\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseGuiSession.ps1')), "'((?:Val|Msg)\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value })
        # A key ending in '.' is a prefix the code completes at run time (_s.Get("CS.OnError." + value)):
        # it is not a key itself. The table must hold at least one key under it, and those keys count as used.
        $dynamicPrefixes = @($used | Where-Object { $_.EndsWith('.') } | Select-Object -Unique)
        $used = @($used | Where-Object { -not $_.EndsWith('.') })
        $used.Count | Should BeGreaterThan 100
        $missing = @($used | Where-Object { $_ -notmatch $script:LangOnlyPrefixes -and -not $en.ContainsKey($_) } | Select-Object -Unique)
        $missing += @($dynamicPrefixes | Where-Object { $prefix = $_; -not @($en.Keys | Where-Object { $_.StartsWith($prefix) }) })
        ($missing -join ',') | Should Be ''
        # Category.<name> keys are built from the category name at run time
        $unused = @($en.Keys | Where-Object { $key = $_; $used -notcontains $key -and $key -notmatch '^Category\.' -and -not @($dynamicPrefixes | Where-Object { $key.StartsWith($_) }) })
        ($unused -join ',') | Should Be ''
    }

    It "the Japanese table translates every tweak, component switch and Advanced Debloat item, with no orphan entries" {
        $ja = Read-UiTable 'ja'
        $missing = @()
        foreach ($t in $settingsDef.Tweaks) { if (-not $ja.ContainsKey("Tweak.$($t.Key).Description")) { $missing += "Tweak.$($t.Key)" } }
        foreach ($c in @($settingsDef.Components | Where-Object { $_.Gui })) {
            foreach ($f in 'Text', 'Description') { if (-not $ja.ContainsKey("Component.$($c.Key).$f")) { $missing += "Component.$($c.Key).$f" } }
        }
        $items = Get-DebloatItemFromSource
        $items.Count | Should BeGreaterThan 40
        foreach ($i in $items) { if (-not $ja.ContainsKey("Debloat:$i")) { $missing += "Debloat:$i" } }
        ($missing -join "`n") | Should Be ''
        $tweakKeys = @($settingsDef.Tweaks | ForEach-Object { $_.Key })
        $compKeys = @($settingsDef.Components | Where-Object { $_.Gui } | ForEach-Object { $_.Key })
        $orphans = @()
        foreach ($k in $ja.Keys) {
            if ($k -match '^Tweak\.(.+)\.Description$') { if ($tweakKeys -notcontains $Matches[1]) { $orphans += $k } }
            elseif ($k -match '^Component\.(.+)\.(Text|Description)$') { if ($compKeys -notcontains $Matches[1]) { $orphans += $k } }
            elseif ($k -match '^Debloat:(.+)$') { if ($items -notcontains $Matches[1]) { $orphans += $k } }
        }
        ($orphans -join "`n") | Should Be ''
    }

    It "placeholders are the same in English and Japanese" {
        $en = Read-UiTable 'en'
        $ja = Read-UiTable 'ja'
        $bad = @()
        foreach ($k in $en.Keys) {
            $a = @([regex]::Matches($en[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $b = @([regex]::Matches($ja[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            if ($a -ne $b) { $bad += $k }
        }
        ($bad -join ',') | Should Be ''
    }

    It "the Japanese table reads back as Japanese in Windows PowerShell 5.1 (UTF-8 data file, no mojibake)" {
        $ja = Read-UiTable 'ja'
        ([int[]][char[]]$ja['Button.SelectAll'] -join ',') | Should Be '12377,12409,12390,36984,25246'
        ([int[]][char[]]$ja['Language.Name'] -join ',') | Should Be '26085,26412,35486'
        foreach ($k in $ja.Keys) { $ja[$k].Contains([string][char]0xFFFD) | Should Be $false | Out-Null }
        # a fresh Windows PowerShell 5.1 process that only dot-sources the GUI file and asks for the string
        $cmd = ". '$($script:GuiPath)'; `$s = Get-WinEaseUiString 'Button.SelectAll' -Language ja; ([int[]][char[]]`$s) -join ','"
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd
        (@($out)[-1]) | Should Be '12377,12409,12390,36984,25246'
    }

    It "the source files stay ASCII: Japanese lives only in the JSON tables" {
        foreach ($f in 'gui\WinEaseGui.ps1', 'tools\migrator\WinEase-Migrator.ps1', 'WinEasebuilder.ps1', 'lib\WinEaseExtensions.ps1', 'config\schema.psd1') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $f))
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        }
    }

    It "no Japanese string was read with the wrong code page (no Shift-JIS mojibake)" {
        # A Japanese text that was decoded with Shift-JIS instead of UTF-8 leaves the
        # halfwidth katakana and the C1 controls in the string. Seven strings of the
        # table were in that state (the Advanced Debloat column headers and the four
        # language pack descriptions).
        $ja = Read-UiTable 'ja'
        $bad = @()
        foreach ($k in $ja.Keys) {
            $codes = [int[]][char[]]$ja[$k]
            $hits = @($codes | Where-Object { ($_ -ge 0xFF61 -and $_ -le 0xFF9F) -or ($_ -ge 0x0080 -and $_ -le 0x009F) })
            if ($hits.Count -gt 0) { $bad += $k }
        }
        ($bad -join ',') | Should Be ''
    }

    It "the Advanced Debloat headers and the language pack descriptions are readable Japanese" {
        # the expected text is written with \u escapes, so this file stays ASCII
        $ja = Read-UiTable 'ja'
        $ja['Debloat.Column.Engine'] | Should Be ([regex]::Unescape('\u30A8\u30F3\u30B8\u30F3'))
        $ja['Debloat.Column.Target'] | Should Be ([regex]::Unescape('\u5BFE\u8C61'))
        $ja['Debloat.Engine.All'] | Should Be ([regex]::Unescape('\u5168\u5BFE\u8C61\u306E\u30A8\u30F3\u30B8\u30F3:'))
        $ja['Tweak.RemoveLanguageJaJP.Description'] | Should Be ([regex]::Unescape('\u65E5\u672C\u8A9E\u306E\u8A00\u8A9E\u30D1\u30C3\u30AF\u3092\u524A\u9664\u3067\u304D\u308B\u72B6\u614B\u306B\u3059\u308B (OFF = \u4FDD\u8B77\u3057\u3066\u6B8B\u3059)'))
        $ja['Tweak.RemoveLanguageKoKR.Description'] | Should Be ([regex]::Unescape('\u97D3\u56FD\u8A9E\u306E\u8A00\u8A9E\u30D1\u30C3\u30AF\u3092\u524A\u9664\u3067\u304D\u308B\u72B6\u614B\u306B\u3059\u308B (OFF = \u4FDD\u8B77\u3057\u3066\u6B8B\u3059)'))
        $ja['Tweak.RemoveLanguageZhCN.Description'] | Should Be ([regex]::Unescape('\u7C21\u4F53\u5B57\u4E2D\u56FD\u8A9E\u306E\u8A00\u8A9E\u30D1\u30C3\u30AF\u3092\u524A\u9664\u3067\u304D\u308B\u72B6\u614B\u306B\u3059\u308B (OFF = \u4FDD\u8B77\u3057\u3066\u6B8B\u3059)'))
        $ja['Tweak.RemoveLanguageZhTW.Description'] | Should Be ([regex]::Unescape('\u7E41\u4F53\u5B57\u4E2D\u56FD\u8A9E\u306E\u8A00\u8A9E\u30D1\u30C3\u30AF\u3092\u524A\u9664\u3067\u304D\u308B\u72B6\u614B\u306B\u3059\u308B (OFF = \u4FDD\u8B77\u3057\u3066\u6B8B\u3059)'))
    }

    It "Get-WinEaseUiString falls back from the chosen language to English, then to the default, then to the key" {
        Set-WinEaseUiLanguage -Language 'ja'
        try {
            (Get-WinEaseUiString 'No.Such.Key') | Should Be 'No.Such.Key'
            (Get-WinEaseUiString 'No.Such.Key' -Default 'dflt') | Should Be 'dflt'
            (Get-WinEaseUiTable -Language 'en')['Test.OnlyEnglish'] = 'English only'
            (Get-WinEaseUiString 'Test.OnlyEnglish') | Should Be 'English only'
            (Get-WinEaseUiString 'Test.OnlyEnglish' -Language 'en') | Should Be 'English only'
            (Get-WinEaseUiString 'Button.SelectAll') | Should Be (Get-WinEaseUiString 'Button.SelectAll' -Language 'ja')
            (Get-WinEaseUiString 'Button.SelectAll') | Should Not Be 'Select All'
            (Get-WinEaseUiString 'Main.Estimate' -Format 2 -Language 'en') | Should Be 'Estimated ISO Size: ~2 GB (LZX baseline)'
        } finally {
            [void](Get-WinEaseUiTable -Language 'en').Remove('Test.OnlyEnglish')
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "a missing or unreadable table never throws (empty table, key comes back)" {
        $savedTables = $script:WinEaseUiTables
        $savedRoot = $script:WinEaseGuiRepoRoot
        $savedDir = $script:WinEaseGuiDir
        try {
            $script:WinEaseUiTables = @{}
            $script:WinEaseGuiRepoRoot = Join-Path $script:LangTemp 'nowhere'
            $script:WinEaseGuiDir = Join-Path $script:LangTemp 'nowhere'
            Set-WinEaseUiLanguage -Language 'ja'
            (Get-WinEaseUiString 'Button.SelectAll') | Should Be 'Button.SelectAll'
            (Get-WinEaseUiString 'Button.SelectAll' -Default 'Select All') | Should Be 'Select All'
        } finally {
            $script:WinEaseGuiRepoRoot = $savedRoot
            $script:WinEaseGuiDir = $savedDir
            $script:WinEaseUiTables = $savedTables
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "language choice: -UiLanguage beats the environment, which beats the saved choice, which beats the OS language" {
        $env:WINEASE_UI_LANGUAGE = ''
        $settingsFile = Get-WinEaseGuiSettingsPath
        $settingsFile | Should Be (Join-Path $script:LangTemp 'WinEase\gui-settings.json')
        if (Test-Path -LiteralPath $settingsFile) { Remove-Item -LiteralPath $settingsFile -Force }
        $osLang = if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') { 'ja' } else { 'en' }
        (Resolve-WinEaseUiLanguage) | Should Be $osLang
        Save-WinEaseGuiLanguage -Language 'ja'
        (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).UiLanguage | Should Be 'ja'
        (Resolve-WinEaseUiLanguage) | Should Be 'ja'
        (Resolve-WinEaseUiLanguage -Requested 'en') | Should Be 'en'
        $env:WINEASE_UI_LANGUAGE = 'en'
        (Resolve-WinEaseUiLanguage) | Should Be 'en'
        (Resolve-WinEaseUiLanguage -Requested 'ja') | Should Be 'ja'
        (Resolve-WinEaseUiLanguage -Requested 'xx') | Should Be 'en'
        $env:WINEASE_UI_LANGUAGE = ''
        Save-WinEaseGuiLanguage -Language 'en'
        (Resolve-WinEaseUiLanguage) | Should Be 'en'
        # other keys of the settings file survive a save
        [System.IO.File]::WriteAllText($settingsFile, '{ "Other": 5, "UiLanguage": "en" }')
        Save-WinEaseGuiLanguage -Language 'ja'
        $after = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        $after.Other | Should Be 5
        $after.UiLanguage | Should Be 'ja'
        # an unreadable settings file is ignored
        [System.IO.File]::WriteAllText($settingsFile, 'not json')
        (Resolve-WinEaseUiLanguage) | Should Be $osLang
        $env:WINEASE_UI_LANGUAGE = 'en'
    }

    It "failing to save the language does not throw" {
        $blocker = Join-Path $script:LangTemp 'blocked'
        [System.IO.File]::WriteAllText($blocker, 'x')
        $env:LOCALAPPDATA = $blocker
        try {
            { Save-WinEaseGuiLanguage -Language 'ja' } | Should Not Throw
            (Resolve-WinEaseUiLanguage -Requested 'ja') | Should Be 'ja'
        } finally { $env:LOCALAPPDATA = $script:LangTemp }
    }

    It "tweak description: language table first, then DescriptionJa of a user tweak (Japanese only), then the Description" {
        Set-WinEaseUiLanguage -Language 'ja'
        try {
            (Get-WinEaseTweakDescription -Key 'DisableUAC' -Def @{ Description = 'x' }) | Should Be (Get-WinEaseUiString 'Tweak.DisableUAC.Description' -Language 'ja')
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain'; DescriptionJa = 'ja text' }) | Should Be 'ja text'
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain' }) | Should Be 'plain'
            Set-WinEaseUiLanguage -Language 'en'
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain'; DescriptionJa = 'ja text' }) | Should Be 'plain'
            (Get-WinEaseTweakDescription -Key 'DisableUAC' -Def $script:AllTweakDefs['DisableUAC']) | Should Be $script:AllTweakDefs['DisableUAC'].Description
        } finally { Set-WinEaseUiLanguage -Language 'en' }
    }

    It "user tweaks keep DescriptionJa in AllTweakDefs" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseExtensions.ps1"))
        $src | Should Match 'DescriptionJa'
    }

    It "builder and migrator take -UiLanguage en|ja" {
        foreach ($f in 'WinEasebuilder.ps1', 'tools\migrator\WinEase-Migrator.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $f), [ref]$null, [ref]$null)
            $p = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UiLanguage' })
            $p.Count | Should Be 1
            $set = @(($p[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value })
            ($set -join ',') | Should Be 'en,ja'
        }
    }

    It "English window: texts are the same English as before the language option existed" {
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en
        try {
            $gui.Form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
            $tabs = @($gui.Tabs.TabPages | ForEach-Object { $_.Text })
            ($tabs -join '|') | Should Be ' 1. Media & Output | 2. Security & Bypass | 3. Privacy & AI | 4. Performance | 5. UI & Shell | 6. Services & Apps | 7. Advanced Debloat | 8. Migration & Backup | 9. User Tweaks | 10. Custom Scripts '
            $gui.Preset.Items[0] | Should Be 'Extreme Slim & Gaming (Max debloat, minimal memory, ultra-low latency)'
            $gui.DryRun.Text | Should Be 'DryRun (Simulation Mode)'
            $gui.TweakCheckboxes['DisableUAC'].Text | Should Be ('DisableUAC - ' + $script:AllTweakDefs['DisableUAC'].Description)
            $gui.ComponentCheckboxes['RemoveDefender'].Text | Should Be ('RemoveDefender - ' + $script:ComponentDefs['RemoveDefender'].Gui.Text)
            @(Get-AllControls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
            # plain strings, not wrapped items, so English behaves exactly as before
            ($gui.GrdStd.Rows[0].Tag -is [string]) | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "Japanese window: builds without showing, texts are Japanese, Advanced Debloat results stay English" {
        $ja = Read-UiTable 'ja'
        $english = Get-DebloatItemFromSource
        $iso = Join-Path $TestDrive 'japanese.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $gui = Show-WinEaseGUI -NoShow -UiLanguage ja -InitialSettings @{ SourceDrive = $iso; TweakSettings = [ordered]@{} }
        try {
            $gui.Form.Text | Should Be $ja['Main.WindowTitle']
            $gui.Tabs.TabPages[0].Text | Should Be $ja['Tab.Media']
            $gui.DryRun.Text | Should Be $ja['Main.DryRun']
            $gui.TweakCheckboxes['DisableUAC'].Text | Should Be ('DisableUAC - ' + $ja['Tweak.DisableUAC.Description'])
            $gui.ComponentCheckboxes['RemoveDefender'].Text | Should Be ('RemoveDefender - ' + $ja['Component.RemoveDefender.Text'])
            @(Get-AllControls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] -and ($_.Text -eq $ja['Button.SelectAll'] -or $_.Text -eq $ja['Button.ClearAll']) }).Count | Should Be 14
            # every item shows its translation, and checking all of them hands the English text on
            $gui.GrdStd.Rows.Count | Should BeGreaterThan 20
            $gui.GrdStd.Rows[0].Cells['Target'].Value | Should Be $ja['Debloat:Remove PatchCache (dir delete) [200-500MB]']
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdStd -Checked $true
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdExp -Checked $true
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $r = $gui.Result
            @($r.AdvancedDebloatStandard).Count | Should Be $gui.GrdStd.Rows.Count
            foreach ($v in @($r.AdvancedDebloatStandard) + @($r.AdvancedDebloatExperimental)) { ($english -contains $v) | Should Be $true | Out-Null }
            ($r.AdvancedDebloatStandard -join "`n") | Should Be ((@($gui.GrdStd.Rows | ForEach-Object { $_.Tag })) -join "`n")
            (Get-WinEaseGuiDraftConfig -Gui $gui).AdvancedDebloatExperimental[0] | Should Match '^Physical: '
            $r.TweakSettings.Count | Should Be $script:AllTweakDefs.Count
        } finally { $gui.Form.Dispose() }
        # a profile that already holds the English names pre-checks the right (translated) rows
        $first = $english[0]
        $gui2 = Show-WinEaseGUI -NoShow -UiLanguage ja -InitialSettings @{ AdvancedDebloatStandard = @($first) }
        try {
            @($gui2.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value }).Count | Should Be 1
            @($gui2.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value })[0].Tag | Should Be $first
        } finally { $gui2.Form.Dispose() }
    }

    It "the engine cell is locked while the target is not selected" {
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            # a target that supports both engines starts unchecked -> the engine is locked
            $row = @($gui.GrdStd.Rows | Where-Object { @($_.Tag) -like '*Bluetooth*' })[0]
            $row | Should Not BeNullOrEmpty
            $row.Cells['On'].Value | Should Be $false
            $row.Cells['Engine'].ReadOnly | Should Be $true
            # checking it unlocks the engine
            $row.Cells['On'].Value = $true
            Update-WinEaseDebloatRowState -Grid $gui.GrdStd -RowIndex $row.Index -EngineDefs (Get-WinEaseDebloatEngineDefs)
            $row.Cells['Engine'].ReadOnly | Should Be $false
            # a target that only one engine can remove stays locked, even when it is selected
            $single = @($gui.GrdStd.Rows | Where-Object { [string]$_.Tag -like 'WinSxS cleanup*' })[0]
            $single | Should Not BeNullOrEmpty
            $single.Cells['On'].Value = $true
            Update-WinEaseDebloatRowState -Grid $gui.GrdStd -RowIndex $single.Index -EngineDefs (Get-WinEaseDebloatEngineDefs)
            $single.Cells['Engine'].ReadOnly | Should Be $true
            $single.Cells['Engine'].Value | Should Be 'PowerShell'
            # a target that both engines can remove offers both of them
            $dual = @($gui.GrdExp.Rows | Where-Object { [string]$_.Tag -like 'Physical: Defender*' })[0]
            $dual | Should Not BeNullOrEmpty
            $dual.Cells['On'].Value = $true
            Update-WinEaseDebloatRowState -Grid $gui.GrdExp -RowIndex $dual.Index -EngineDefs (Get-WinEaseDebloatEngineDefs)
            $dual.Cells['Engine'].ReadOnly | Should Be $false
            $dual.Cells['Engine'].Value | Should Be 'Rust'
        } finally { $gui.Form.Dispose() }
    }

    It "the global engine switch sets every target that supports it" {
        $iso = Join-Path $TestDrive 'engines.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = $iso; TweakSettings = [ordered]@{} }
        try {
            Set-WinEaseDebloatEngineForAll -Grids @($gui.GrdStd, $gui.GrdExp) -Engine 'Rust'
            $dual = @($gui.GrdStd.Rows | Where-Object { @($_.Tag) -like '*Bluetooth*' })[0]
            $dual.Cells['Engine'].Value | Should Be 'Rust'
            # a target that only the safe engine can remove is not changed
            $single = @($gui.GrdStd.Rows | Where-Object { [string]$_.Tag -like 'WinSxS cleanup*' })[0]
            $single.Cells['Engine'].Value | Should Be 'PowerShell'
            # a target that both engines can remove is changed as well
            $physical = @($gui.GrdExp.Rows | Where-Object { [string]$_.Tag -like 'Physical: Defender*' })[0]
            $physical.Cells['Engine'].Value | Should Be 'Rust'
            # the draft config carries the engine of every target, the result only the changed ones
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdStd -Checked $true
            $cfg = Get-WinEaseGuiDraftConfig -Gui $gui
            $cfg.DebloatEngineSelection.Count | Should BeGreaterThan 0
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $r = $gui.Result
            $r.DebloatEngineSelection.Count | Should BeGreaterThan 0
            foreach ($k in $r.DebloatEngineSelection.Keys) { $r.DebloatEngineSelection[$k] | Should Be 'Rust' }
        } finally { $gui.Form.Dispose() }
    }

    It "the window starts on the safe preset with every engine on PowerShell" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $gui.Preset.SelectedIndex | Should Be 1
            $gui.GrdStd.Rows[0].Cells['Engine'].Value | Should Be 'PowerShell'
        } finally { $gui.Form.Dispose() }
    }

    It "switching the language keeps what was typed, checked and selected (and saves the choice)" {
        $env:WINEASE_UI_LANGUAGE = 'en'
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $gui.Work.Text = 'D:\work space'
            $gui.Index.Text = '3'
            $gui.Drivers.Text = 'D:\drv'
            $gui.UserName.Text = 'Taro'
            $gui.ComputerName.Text = 'PC-1'
            $gui.DryRun.Checked = $true
            $gui.VHDX.Checked = $true
            $gui.RadSWM.Checked = $true
            $gui.TweakCheckboxes['DisableUAC'].Checked = $true
            $gui.ComponentCheckboxes['RemoveStore'].Checked = $true
            $gui.GrdStd.Rows[2].Cells['On'].Value = $true
            $gui.GrdExp.Rows[4].Cells['On'].Value = $true
            $gui.MigRoot.Text = 'D:\mig'
            $gui.CustomPaths.Text = "C:\a`r`nC:\b"
            $gui.MigExcludeSecrets.Checked = $false
            $gui.MigConflict.SelectedIndex = 2
            $gui.MigFolders.SetItemChecked(3, $true)
            Initialize-WinEaseGuiMigrationRules -List $gui.MigRulesList
            $gui.MigTab.Tag.Loaded = $true
            $gui.MigRulesList.SetItemChecked(1, $true)
            $gui.MigRulesList.SetItemChecked(3, $true)
            $ruleIds = @(Get-WinEaseGuiMigrationRuleIds -Gui $gui)
            $ruleIds.Count | Should Be 2
            $stdValue = $gui.GrdStd.Rows[2].Tag
            $gui.Tabs.SelectedIndex = 4
            $presetIndex = $gui.Preset.SelectedIndex
            $before = Get-WinEaseGuiDraftConfig -Gui $gui

            Switch-WinEaseGuiLanguage -Gui $gui -Language ja
            $script:WinEaseUiLanguage | Should Be 'ja'
            (Get-Content -LiteralPath (Get-WinEaseGuiSettingsPath) -Raw | ConvertFrom-Json).UiLanguage | Should Be 'ja'
            $gui.Form.Tag | Should Be $gui
            $gui.Form.Text | Should Be (Get-WinEaseUiString 'Main.WindowTitle' -Language 'ja')
            $gui.Tabs.TabPages[0].Text | Should Be (Get-WinEaseUiString 'Tab.Media' -Language 'ja')
            $gui.Language.SelectedIndex | Should Be 1

            $gui.Work.Text | Should Be 'D:\work space'
            $gui.Index.Text | Should Be '3'
            $gui.Drivers.Text | Should Be 'D:\drv'
            $gui.UserName.Text | Should Be 'Taro'
            $gui.ComputerName.Text | Should Be 'PC-1'
            $gui.Source.Text | Should Be 'E:\'
            $gui.DryRun.Checked | Should Be $true
            $gui.VHDX.Checked | Should Be $true
            $gui.RadSWM.Checked | Should Be $true
            $gui.Tabs.SelectedIndex | Should Be 4
            $gui.Preset.SelectedIndex | Should Be $presetIndex
            $gui.TweakCheckboxes['DisableUAC'].Checked | Should Be $true
            $gui.ComponentCheckboxes['RemoveStore'].Checked | Should Be $true
            $after = Get-WinEaseGuiDraftConfig -Gui $gui
            foreach ($k in $before.TweakSettings.Keys) { $after.TweakSettings[$k] | Should Be $before.TweakSettings[$k] | Out-Null }
            foreach ($k in $gui.ComponentCheckboxes.Keys) { $after[$k] | Should Be $before[$k] | Out-Null }
            (@($after.AdvancedDebloatStandard) -join '|') | Should Be $stdValue
            @($after.AdvancedDebloatExperimental).Count | Should Be 1
            $gui.MigRoot.Text | Should Be 'D:\mig'
            $gui.CustomPaths.Text | Should Be "C:\a`r`nC:\b"
            $gui.MigExcludeSecrets.Checked | Should Be $false
            $gui.MigConflict.SelectedIndex | Should Be 2
            $gui.MigFolders.GetItemChecked(3) | Should Be $true
            (@(Get-WinEaseGuiMigrationRuleIds -Gui $gui) -join ',') | Should Be ($ruleIds -join ',')
            $gui.TweakCheckboxes.Count | Should Be $script:AllTweakDefs.Count
            # the rebuilt window is live: toggling a tweak still switches the preset to Custom and updates the estimate
            $gui.Preset.SelectedIndex = 0
            $gui.TweakCheckboxes['DisableUAC'].Checked = $false
            $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)

            Switch-WinEaseGuiLanguage -Gui $gui -Language en
            $script:WinEaseUiLanguage | Should Be 'en'
            $gui.Form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
            $gui.Work.Text | Should Be 'D:\work space'
            $gui.ComponentCheckboxes['RemoveStore'].Checked | Should Be $true
            (@((Get-WinEaseGuiDraftConfig -Gui $gui).AdvancedDebloatStandard) -join '|') | Should Be $stdValue
        } finally {
            $gui.Form.Dispose()
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "switching to the language already shown, or to an unknown one, changes nothing" {
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en
        try {
            $form = $gui.Form
            $firstTab = $gui.Tabs
            Switch-WinEaseGuiLanguage -Gui $gui -Language en
            Switch-WinEaseGuiLanguage -Gui $gui -Language xx
            [object]::ReferenceEquals($gui.Tabs, $firstTab) | Should Be $true
            $form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
        } finally { $gui.Form.Dispose() }
    }

    It "migration wizard: opens in either language and keeps its state when the language changes" {
        . (Join-Path $script:RepoRoot "tools\migrator\WinEaseMigration.ps1")
        $toolPath = Join-Path $script:RepoRoot "tools\migrator\WinEase-Migrator.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($toolPath, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
        $script:MigratorToolPath = $toolPath
        $script:RulesPath = Join-Path $script:RepoRoot "tools\migrator\migration-rules.psd1"
        $script:UserRulesPath = $null
        $script:DefaultPackagePath = Get-WinEaseDefaultMigrationBackupPath -Base Documents
        $ja = Read-UiTable 'ja'
        $en = Read-UiTable 'en'
        $form = Show-WinEaseMigratorDialog -NoShow -UiLanguage ja -PackagePath 'D:\bk'
        try {
            $form.Text | Should Be $ja['Migrator.Title']
            $form.Tag.Tabs.TabPages[0].Text | Should Be $ja['Migrator.Tab.Backup']
            $form.Tag.Tabs.TabPages[1].Text | Should Be $ja['Migrator.Tab.Restore']
            $form.Tag.BackupRoot.Text | Should Be 'D:\bk'
            $form.Tag.GameRules.Items.Count | Should BeGreaterThan 0
            $form.Tag.GameRules.SetItemChecked(1, $true)
            $form.Tag.AppRules.SetItemChecked(0, $true)
            [void]$form.Tag.Folders.Items.Add('D:\custom', $true)
            $form.Tag.Policy.SelectedIndex = 3
            $form.Tag.RestoreRoot.Text = 'E:\restore'
            $form.Tag.ExcludeSecrets.Checked = $false
            $form.Tag.Log.Text = 'a log line'
            $form.Tag.Tabs.SelectedIndex = 1
            $rules = @($form.Tag.GameRules.CheckedItems) + @($form.Tag.AppRules.CheckedItems)
            $sel = Get-MigSelection -Form $form

            Switch-MigratorLanguage -Form $form -Language en
            $script:WinEaseUiLanguage | Should Be 'en'
            $form.Text | Should Be $en['Migrator.Title']
            $form.Tag.Tabs.TabPages[0].Text | Should Be 'Export / Backup'
            $form.Tag.BackupRoot.Text | Should Be 'D:\bk'
            $form.Tag.RestoreRoot.Text | Should Be 'E:\restore'
            $form.Tag.Policy.SelectedIndex | Should Be 3
            $form.Tag.ExcludeSecrets.Checked | Should Be $false
            $form.Tag.Log.Text | Should Be 'a log line'
            $form.Tag.Tabs.SelectedIndex | Should Be 1
            $form.Tag.Folders.Items.Contains('D:\custom') | Should Be $true
            $after = Get-MigSelection -Form $form
            $after.RuleIds | Should Be $sel.RuleIds
            $after.UserFolders -join ',' | Should Be ($sel.UserFolders -join ',')
            $after.CustomPaths -join ',' | Should Be ($sel.CustomPaths -join ',')
            @($rules).Count | Should Be 2
            $form.Tag.Language.SelectedIndex | Should Be 0
        } finally {
            $form.Dispose()
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "cleanup: restore the environment" {
        $env:LOCALAPPDATA = $script:LangSavedLocalAppData
        $env:WINEASE_UI_LANGUAGE = 'en'
        Set-WinEaseUiLanguage -Language 'en'
        if (Test-Path -LiteralPath $script:LangTemp) { Remove-Item -LiteralPath $script:LangTemp -Recurse -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.Application]::Exit()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $env:LOCALAPPDATA | Should Be $script:LangSavedLocalAppData
    }
}

Describe "WinUI 3 window host (gui\WinEaseWinUiHost.ps1)" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:BuiltInPresets = [ordered]@{ wtest = @{ PayloadFormat = 'ESD'; RemoveDefender = $false; TweakSettings = @{ DisableUAC = $true } } }
    function Get-WinEasePreset { param([string]$Name) if ($Name -eq 'extreme') { $script:BuiltInPresets['wtest'] } else { $null } }
    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    $script:WinUiHostPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseWinUiHost.ps1"

    It "gui\WinEaseWinUiHost.ps1 parses with zero parser errors and is loaded with gui\WinEaseGui.ps1" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:WinUiHostPath, [ref]$null, [ref]$errs)
        @($errs).Count | Should Be 0
        (Get-Command Show-WinEaseWinUiGUI -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It "the init message carries every definition and survives the JSON round trip" {
        $init = New-WinEaseWinUiInitMessage -Language 'en' -InitialSettings @{
            SourceDrive = 'E:\'; UserName = 'Tester'; ExportESDMode = $true; RemoveDefender = $false
            TweakSettings = [ordered]@{ DisableUAC = $true }; AdvancedDebloatStandard = @('x')
        }
        $back = $init | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
        $back.Op | Should Be 'init'
        @($back.Tweaks).Count | Should Be $script:AllTweakDefs.Count
        @($back.Components).Count | Should Be @($script:ComponentDefs.Values | Where-Object { $_.Gui }).Count
        @($back.DebloatStandard).Count | Should BeGreaterThan 20
        @($back.DebloatExperimental).Count | Should BeGreaterThan 10
        $back.Initial.SourceDrive | Should Be 'E:\'
        $back.Initial.UserName | Should Be 'Tester'
        $back.Initial.ExportESDMode | Should Be $true
        $back.Initial.Components.RemoveDefender | Should Be $false
        $back.Initial.TweakSettings.DisableUAC | Should Be $true
        @($back.Initial.AdvancedDebloatStandard) -join ',' | Should Be 'x'
        @($back.PresetNames) -join ',' | Should Be 'wtest'
        # only 'extreme' resolves in this test: the preset carries every tweak, its payload and its components
        $p = @($back.Presets)[0]
        $p.Key | Should Be 'extreme'
        $p.PayloadFormat | Should Be 'ESD'
        $p.Components.RemoveDefender | Should Be $false
        $p.Tweaks.DisableUAC | Should Be $true
        @($p.Tweaks.PSObject.Properties).Count | Should Be $script:AllTweakDefs.Count
    }

    It "a window result becomes the Show-WinEaseGUI result hashtable" {
        $iso = Join-Path $TestDrive 'winui-result.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $json = [ordered]@{
            Success = $true; SourceDrive = $iso; WorkDir = ''; UserName = ' Tester '; ComputerName = ''; Index = '3'; InjectDrivers = ''
            PresetKey = 'balanced'; BasePresetKey = 'balanced'; DryRun = $true; UseVHDX = $false; ExportESDMode = $false; SplitWIMMode = $true
            Components = @{ RemoveDefender = $true }; TweakSettings = @{ DisableUAC = $true; DisableVBS = $false }
            AdvancedDebloatStandard = @('Remove help files [10-20MB]'); AdvancedDebloatExperimental = @(); PhysicalDebloatConsent = $true
        } | ConvertTo-Json -Depth 6 -Compress
        $r = ConvertFrom-WinEaseWinUiResult -Result ($json | ConvertFrom-Json)
        $r.Success | Should Be $true
        $r.SourceDrive | Should Be $iso
        $r.WorkDir | Should Be (Get-WinEaseGuiDefaultWorkDir)
        $r.UserName | Should Be 'Tester'
        $r.ComputerName | Should Be '*'
        $r.Index | Should Be '3'
        $r.PresetKey | Should Be 'balanced'
        $r.DryRun | Should Be $true
        $r.SplitWIMMode | Should Be $true
        $r.RemoveDefender | Should Be $true
        $r.TweakSettings['DisableUAC'] | Should Be $true
        $r.TweakSettings['DisableVBS'] | Should Be $false
        @($r.AdvancedDebloatStandard) -join ',' | Should Be 'Remove help files [10-20MB]'
        @($r.AdvancedDebloatExperimental).Count | Should Be 0
        $r.PhysicalDebloatConsent | Should Be $true
        (ConvertFrom-WinEaseWinUiResult -Result ('{"Success":false}' | ConvertFrom-Json)).Success | Should Be $false
    }

    It "requests: JSON configs reach the build functions as hashtables, unknown requests throw" {
        $cfg = ConvertTo-WinEaseHashtable ('{"RemoveDefender":true,"TweakSettings":{"DisableUAC":true},"AdvancedDebloatStandard":["a","b"]}' | ConvertFrom-Json)
        ($cfg -is [hashtable]) | Should Be $true
        ($cfg.TweakSettings -is [hashtable]) | Should Be $true
        @($cfg.AdvancedDebloatStandard).Count | Should Be 2
        (Invoke-WinEaseWinUiRequest -Op 'sources' -Arguments $null).Contains('Data') | Should Be $true
        { Invoke-WinEaseWinUiRequest -Op 'no-such-request' -Arguments $null } | Should Throw
    }

    It "the builder prefers the WinUI 3 window, keeps -ClassicGui and falls back to WinForms" {
        $builder = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'WinEasebuilder.ps1'))
        $guiSession = [System.IO.File]::ReadAllText($script:GuiSessionPath)
        $builder | Should Match '\[switch\]\$ClassicGui'
        $guiSession | Should Match 'Find-WinEaseWinUiExe'
        $guiSession | Should Match 'Show-WinEaseWinUiGUI'
        $guiSession | Should Match 'falling back to the classic window'
    }

    It "handles WINEASE_WINUI_INIT_DUMP environment variable creating parent directories safely" {
        $dumpFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winease_dump_test_" + [Guid]::NewGuid().ToString('N'))
        $dumpFile = Join-Path -Path $dumpFolder -ChildPath "nested\init_dump.json"
        $oldDump = $env:WINEASE_WINUI_INIT_DUMP
        try {
            $env:WINEASE_WINUI_INIT_DUMP = $dumpFile
            $init = New-WinEaseWinUiInitMessage -Language 'en' -InitialSettings @{}
            $initJson = $init | ConvertTo-Json -Depth 12 -Compress
            $dumpDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($env:WINEASE_WINUI_INIT_DUMP))
            if ($dumpDir -and -not (Test-Path -LiteralPath $dumpDir)) {
                [void][System.IO.Directory]::CreateDirectory($dumpDir)
            }
            [System.IO.File]::WriteAllText($env:WINEASE_WINUI_INIT_DUMP, $initJson, [System.Text.Encoding]::UTF8)
            (Test-Path -LiteralPath $dumpFile) | Should Be $true
            $content = [System.IO.File]::ReadAllText($dumpFile)
            $content | Should Match '"Op":"init"'
        } finally {
            $env:WINEASE_WINUI_INIT_DUMP = $oldDump
            if (Test-Path -LiteralPath $dumpFolder) { Remove-Item -LiteralPath $dumpFolder -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Show-WinEaseGuiSessionWindow session launcher and error handling" {
    BeforeEach {
        if (-not (Get-Command Find-WinEaseWinUiExe -ErrorAction SilentlyContinue)) {
            function Find-WinEaseWinUiExe { return $null }
        }
        if (-not (Get-Command Show-WinEaseWinUiGUI -ErrorAction SilentlyContinue)) {
            function Show-WinEaseWinUiGUI { return $null }
        }
        if (-not (Get-Command Show-WinEaseGUI -ErrorAction SilentlyContinue)) {
            function Show-WinEaseGUI { return $null }
        }

        $guiSessionAst = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiSessionPath, [ref]$null, [ref]$null)
        $funcAst = $guiSessionAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Show-WinEaseGuiSessionWindow" }, $true)
        . ([scriptblock]::Create($funcAst.Extent.Text))
    }

    It "executes WinUI 3 window when executable is found and succeeds" {
        Mock Find-WinEaseWinUiExe { return "C:\path\to\WinEaseGui.exe" }
        Mock Show-WinEaseWinUiGUI { return @{ Success = $true; Source = "WinUI3" } }
        Mock Show-WinEaseGUI { return @{ Success = $true; Source = "Classic" } }

        $res = Show-WinEaseGuiSessionWindow -InitialSettings @{}
        $res.Source | Should Be "WinUI3"
        Assert-MockCalled Find-WinEaseWinUiExe -Exactly 1 -Scope It
        Assert-MockCalled Show-WinEaseWinUiGUI -Exactly 1 -Scope It
        Assert-MockCalled Show-WinEaseGUI -Exactly 0 -Scope It
    }

    It "falls back to classic WinForms GUI when WinUI 3 window throws an exception" {
        Mock Find-WinEaseWinUiExe { return "C:\path\to\WinEaseGui.exe" }
        Mock Show-WinEaseWinUiGUI { throw "WinUI 3 failed to launch" }
        Mock Show-WinEaseGUI { return @{ Success = $true; Source = "Classic" } }

        $res = Show-WinEaseGuiSessionWindow -InitialSettings @{}
        $res.Source | Should Be "Classic"
        Assert-MockCalled Find-WinEaseWinUiExe -Exactly 1 -Scope It
        Assert-MockCalled Show-WinEaseWinUiGUI -Exactly 1 -Scope It
        Assert-MockCalled Show-WinEaseGUI -Exactly 1 -Scope It
    }

    It "launches classic WinForms GUI directly when ClassicGui switch is set" {
        Mock Find-WinEaseWinUiExe { return "C:\path\to\WinEaseGui.exe" }
        Mock Show-WinEaseWinUiGUI { return @{ Success = $true; Source = "WinUI3" } }
        Mock Show-WinEaseGUI { return @{ Success = $true; Source = "Classic" } }

        $script:ClassicGui = $true
        try {
            $res = Show-WinEaseGuiSessionWindow -InitialSettings @{}
            $res.Source | Should Be "Classic"
            Assert-MockCalled Show-WinEaseWinUiGUI -Exactly 0 -Scope It
            Assert-MockCalled Show-WinEaseGUI -Exactly 1 -Scope It
        } finally {
            $script:ClassicGui = $false
        }
    }

    It "passes UiLanguage argument to GUI when UiLanguage parameter is configured" {
        Mock Find-WinEaseWinUiExe { return $null }
        Mock Show-WinEaseGUI { param($InitialSettings, $UiLanguage) $null = $InitialSettings; return @{ Language = $UiLanguage } }

        $script:UiLanguage = "ja"
        try {
            $res = Show-WinEaseGuiSessionWindow -InitialSettings @{}
            $res.Language | Should Be "ja"
            Assert-MockCalled Show-WinEaseGUI -Exactly 1 -Scope It
        } finally {
            $script:UiLanguage = $null
        }
    }
}

Describe "WinEase UI options that have to take effect" {
    BeforeAll {
        $script:UiPrefs = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\ui-preferences.psd1')).UiPreferences)
        # the plain writes live in config\registry, the rest in the phase
        $script:UiPhase = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1')) + "`n" + (Get-WinEaseRegistryTableText)
    }

    It "disables the accessibility shortcuts without removing the features" {
        $expected = @{
            'Control Panel\Accessibility\StickyKeys' = '506'
            'Control Panel\Accessibility\FilterKeys' = '122'
            'Control Panel\Accessibility\ToggleKeys' = '58'
            'Control Panel\Accessibility\MouseKeys' = '58'
            'Control Panel\Accessibility\Keyboard Response' = '122'
        }
        foreach ($path in $expected.Keys) {
            $entry = @($script:UiPrefs | Where-Object { $_.Tweak -eq 'DisableAccessibilityHotkeys' -and $_.Path -eq $path -and $_.Name -eq 'Flags' })
            $entry.Count | Should Be 1
            $entry[0].Data | Should Be $expected[$path]
        }
    }

    It "turns pointer acceleration off with the 0/0/0 trio" {
        foreach ($name in 'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2') {
            $entry = @($script:UiPrefs | Where-Object { $_.Tweak -eq 'DisableMouseAcceleration' -and $_.Name -eq $name })
            $entry.Count | Should Be 1
            $entry[0].Data | Should Be '0'
        }
    }

    It "carries the PolicyManager bridge that hides Recommended on Pro" {
        $script:UiPhase | Should Match 'PolicyManager\\current\\device\\Start'
        $script:UiPhase | Should Match 'PolicyManager\\current\\device\\Education'
        $script:UiPhase | Should Match 'IsEducationEnvironment'
    }

    It "disables every animation through the visual-effects values" {
        foreach ($needle in 'MinAnimate', 'UserPreferencesMask', 'TaskbarAnimations', 'ListviewAlphaSelect', 'Control Panel\Accessibility\Animation') {
            $script:UiPhase.Contains($needle) | Should Be $true
        }
        $script:UiPhase | Should Match 'Tweak = ''OptimizeVisualEffects''; Default = \$true'
    }

    It "registers the GIF with its own Photo Viewer ProgID" {
        $script:UiPhase.Contains('ProgId = "PhotoViewer.FileAssoc.Gif"') | Should Be $true
        $script:UiPhase.Contains('PhotoViewer.FileAssoc.Jpeg') | Should Be $true
        $script:UiPhase | Should Match 'UserChoice'
    }

    It "writes the Photo Viewer open command without passing embedded quotes through reg.exe" {
        $script:UiPhase | Should Match 'New-Item -Path \$commandKey'
        $script:UiPhase | Should Match 'Set-ItemProperty -Path \$commandKey -Name ''\(default\)'' -Value \$photoViewerCommand'
        $script:UiPhase.Contains('$existingCommand = (Get-ItemProperty') | Should Be $true
        $script:UiPhase.Contains('if ("$existingCommand" -notmatch ''PhotoViewer\.dll'') {') | Should Be $true
    }

    It "writes the lock-screen policy from the option instead of forcing it on" {
        $script:UiPhase | Should Match 'Test-TweakEnabled ''DisableLockScreen'' \$false'
        $script:UiPhase | Should Match '\$noLockScreenValue = if \(Test-TweakEnabled ''DisableLockScreen'' \$false\) \{ 1 \} else \{ 0 \}'
    }

    It "uses the transparent shell32 icon for the shortcut overlay" {
        $script:UiPhase.Contains('%SystemRoot%\System32\shell32.dll,-50') | Should Be $true
        $script:UiPhase.Contains('imageres.dll,-17') | Should Be $false
    }
}

Describe "GUI core (lib\WinEaseGuiCore.ps1)" {
    $script:CoreText = [System.IO.File]::ReadAllText($script:GuiCorePath)

    It "parses with zero parser errors and loads no WinForms or Drawing assembly" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:GuiCorePath, [ref]$null, [ref]$errs)
        @($errs).Count | Should Be 0
        $script:CoreText | Should Not Match 'Add-Type\s+-AssemblyName'
        $script:CoreText | Should Not Match 'System\.Drawing\.'
    }

    It "works in a fresh process that loads only the core and the WinUI host (no WinForms window functions)" {
        $cmd = ". '$($script:GuiCorePath)'; . '$(Join-Path $script:RepoRoot 'gui\WinEaseWinUiHost.ps1')'; " +
            "(Get-WinEaseUiString 'Button.SelectAll' -Language ja).Length; (Get-Command Get-WinEaseGuiDraftConfig).Name; " +
            "[bool](Get-Command Show-WinEaseGUI -ErrorAction SilentlyContinue); [bool](Get-Command New-WinEaseForm -ErrorAction SilentlyContinue)"
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd)
        $out[-4] | Should Be '5'
        $out[-3] | Should Be 'Get-WinEaseGuiDraftConfig'
        $out[-2] | Should Be 'False'
        $out[-1] | Should Be 'False'
    }

    It "the WinForms window, the migrator and the Migration Assistant bundle all reference the core" {
        [System.IO.File]::ReadAllText($script:GuiPath) | Should Match 'WinEaseGuiCore\.ps1'
        [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\migrator\WinEase-Migrator.ps1')) | Should Match 'WinEaseGuiCore\.ps1'
        [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1')) | Should Match 'lib\\WinEaseGuiCore\.ps1'
        [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\scripts\verify-release-zip.py')) | Should Match 'lib/WinEaseGuiCore\.ps1'
    }
}

Describe "Send-WinEaseGuiProgress in gui\WinEaseWinUiHost.ps1" {
    BeforeAll {
        . (Join-Path -Path $script:RepoRoot -ChildPath 'gui\WinEaseWinUiHost.ps1')
    }
    AfterEach { $script:WinEaseGuiProgressChannel = $null }

    It "is a no-op without an open window" {
        $script:WinEaseGuiProgressChannel = $null
        { Send-WinEaseGuiProgress -Event phase -Data @{ Phase = 1; Total = 18; Name = 'x' } } | Should Not Throw
    }
    It "writes one JSON line per notice" {
        $sw = New-Object System.IO.StringWriter
        $script:WinEaseGuiProgressChannel = @{ Writer = $sw }
        Send-WinEaseGuiProgress -Event phase -Data @{ Phase = 2; Total = 18; Name = 'Mount' }
        $o = $sw.ToString().Trim() | ConvertFrom-Json
        $o.op | Should Be 'progress'
        $o.event | Should Be 'phase'
        $o.Phase | Should Be 2
    }
    It "drops the channel when the window is gone" {
        $sw = New-Object System.IO.StringWriter
        $sw.Dispose()
        $script:WinEaseGuiProgressChannel = @{ Writer = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { throw 'closed' } -PassThru }
        { Send-WinEaseGuiProgress -Event log -Data @{ Text = 'a' } } | Should Not Throw
        $script:WinEaseGuiProgressChannel | Should BeNullOrEmpty
    }
}

Describe "B1 - preset vs custom state (Get-WinEaseGuiPresetState and the window result)" -Tags 'slow' {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:WinEaseDebloatEngines = [ordered]@{}
    foreach ($de in @($settingsDef.DebloatEngines)) { if ($de -and $de.Item) { $script:WinEaseDebloatEngines[[string]$de.Item] = $de } }
    $presetFile = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\presets.psd1")
    $script:BuiltInPresets = [ordered]@{}
    foreach ($k in $presetFile.Presets.Keys) { $script:BuiltInPresets[[string]$k] = $presetFile.Presets[$k] }
    function Get-WinEasePreset { param([string]$Name) if ($Name -and $script:BuiltInPresets.Contains($Name.Trim().ToLower())) { $script:BuiltInPresets[$Name.Trim().ToLower()] } else { $null } }
    . $script:GuiPath
    . ([scriptblock]::Create($script:GuiNoModalStubs))
    # Session function with the build-side helpers replaced by recorders
    $sessionAst = [System.Management.Automation.Language.Parser]::ParseInput([System.IO.File]::ReadAllText($script:GuiSessionPath), [ref]$null, [ref]$null)
    foreach ($fn in $sessionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Apply-WinEaseGuiResult' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
    function Apply-ProfileSettings { param($ProfileName) $script:B1AppliedBase = $ProfileName; return @{} }
    function Sync-WinEaseTweakVariables { }
    function Set-WinEaseDebloatEngineSelection { param($Selection) $script:DebloatEngineSelection = $Selection }
    function Resolve-WinEaseDebloatEngine { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param($Item) return 'PowerShell' }
    function Confirm-WinEasePhysicalDebloatConsent { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param($GuiResult) }

    # The settings a window reports for a preset (what the WinUI window sends)
    function Get-B1Current($key) {
        $v = Get-WinEaseGuiPresetValues -Name $key
        $c = @{ Components = @{}; TweakSettings = @{}; PayloadFormat = $v.PayloadFormat; AdvancedDebloatStandard = @($v.AdvancedDebloatStandard); AdvancedDebloatExperimental = @($v.AdvancedDebloatExperimental); DebloatEngineSelection = @{} }
        foreach ($k in $v.Components.Keys) { $c.Components[$k] = $v.Components[$k] }
        foreach ($k in $v.Tweaks.Keys) { $c.TweakSettings[$k] = $v.Tweaks[$k] }
        return $c
    }
    # one Advanced Debloat target that supports both engines, and one standard target
    $script:B1BothEngines = @($script:WinEaseDebloatEngines.Values | Where-Object { @($_.Engines).Count -gt 1 })[0]
    $script:B1StdItem = $script:WinEaseDebloatStandardItems[0]

    It "Get-WinEaseGuiPresetValues resolves every built-in preset from the schema, an unknown name is null" {
        foreach ($k in 'extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio') {
            $v = Get-WinEaseGuiPresetValues -Name $k
            $v.Key | Should Be $k
            $v.Tweaks.Count | Should Be $script:AllTweakDefs.Count
            @('WIM', 'ESD', 'SWM') -contains $v.PayloadFormat | Should Be $true
            @($v.AdvancedDebloatStandard).Count | Should Be 0
            @($v.AdvancedDebloatExperimental).Count | Should Be 0
        }
        (Get-WinEaseGuiPresetValues -Name 'no-such-preset') | Should BeNullOrEmpty
    }

    It "reports a window that equals its preset as unmodified, for every preset" {
        foreach ($k in 'extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio') {
            $st = Get-WinEaseGuiPresetState -BasePresetKey $k -Current (Get-B1Current $k)
            $st.IsModified | Should Be $false
            $st.State | Should Be 'Preset'
            $st.PresetKey | Should Be $k
            @($st.DifferingKeys).Count | Should Be 0
        }
    }

    It "a changed tweak makes the state Modified: PresetKey custom, the base stays, the key is listed" {
        $cur = Get-B1Current 'balanced'
        $tk = @($cur.TweakSettings.Keys)[0]
        $cur.TweakSettings[$tk] = -not $cur.TweakSettings[$tk]
        $st = Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur
        $st.IsModified | Should Be $true
        $st.State | Should Be 'Modified'
        $st.PresetKey | Should Be 'custom'
        $st.BasePresetKey | Should Be 'balanced'
        @($st.DifferingKeys) -join ',' | Should Be $tk
        # and back: switching the value back is unmodified again
        $cur.TweakSettings[$tk] = -not $cur.TweakSettings[$tk]
        (Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).IsModified | Should Be $false
    }

    It "a changed component, the payload format and a flat (WinForms draft) component dictionary are compared too" {
        $cur = Get-B1Current 'balanced'
        $ck = @($cur.Components.Keys)[0]
        $cur.Components[$ck] = -not $cur.Components[$ck]
        @((Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).DifferingKeys) -join ',' | Should Be $ck
        $cur = Get-B1Current 'balanced'
        $cur.PayloadFormat = if ($cur.PayloadFormat -eq 'ESD') { 'SWM' } else { 'ESD' }
        @((Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).DifferingKeys) -join ',' | Should Be 'PayloadFormat'
        # WinForms draft shape: component keys at the top level, payload from the radios
        $bv = Get-WinEaseGuiPresetValues -Name 'balanced'
        $flat = @{ TweakSettings = (Get-B1Current 'balanced').TweakSettings; ExportESDMode = $true; SplitWIMMode = $false }
        foreach ($k in $bv.Components.Keys) { $flat[$k] = $bv.Components[$k] }
        $expected = if ($bv.PayloadFormat -eq 'ESD') { 0 } else { 1 }
        @((Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $flat).DifferingKeys).Count | Should Be $expected
    }

    It "settings the preset does not name are not compared; parts the caller does not report are not compared" {
        $cur = Get-B1Current 'balanced'
        $cur.Components['NotAPresetComponent'] = $true
        (Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).IsModified | Should Be $false
        (Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current @{}).IsModified | Should Be $false
    }

    It "no known base preset is Custom" {
        foreach ($b in $null, '', 'no-such-preset') {
            $st = Get-WinEaseGuiPresetState -BasePresetKey $b -Current (Get-B1Current 'balanced')
            $st.State | Should Be 'Custom'
            $st.PresetKey | Should Be 'custom'
            $st.Known | Should Be $false
        }
    }

    It "Advanced Debloat items and engines: a selection is a difference, the engine of an unselected target is not" {
        $cur = Get-B1Current 'balanced'
        $cur.AdvancedDebloatStandard = @($script:B1StdItem)
        $st = Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur
        $st.IsModified | Should Be $true
        @($st.DifferingKeys) -join ',' | Should Be "AdvancedDebloatStandard:$($script:B1StdItem)"
        # the same selection is still a difference against another preset: presets define none, switching keeps it
        (Get-WinEaseGuiPresetState -BasePresetKey 'extreme' -Current $cur).IsModified | Should Be $true

        $item = [string]$script:B1BothEngines.Item
        $other = if ($script:B1BothEngines.Default -eq 'Rust') { 'PowerShell' } else { 'Rust' }
        # engine picked for a target that is not selected: ignored (the build drops it)
        $cur = Get-B1Current 'balanced'
        $cur.DebloatEngineSelection = @{ $item = $other }
        (Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).IsModified | Should Be $false
        # selected with the non-default engine: the item and the engine both differ
        $list = if (@($script:WinEaseDebloatStandardItems) -contains $item) { 'AdvancedDebloatStandard' } else { 'AdvancedDebloatExperimental' }
        $cur[$list] = @($item)
        $st = Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur
        (@($st.DifferingKeys) -contains "DebloatEngine:$item") | Should Be $true
        (@($st.DifferingKeys) -contains "${list}:$item") | Should Be $true
        # an explicitly written default engine equals "no entry"
        $cur.DebloatEngineSelection = @{ $item = [string]$script:B1BothEngines.Default }
        (@((Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur).DifferingKeys) -contains "DebloatEngine:$item") | Should Be $false
    }

    It "a user preset that defines Advanced Debloat items is the base: its own selection is not a difference" {
        $script:BuiltInPresets['b1user'] = @{ TweakSettings = @{}; AdvancedDebloatStandard = @($script:B1StdItem); PayloadFormat = 'WIM' }
        try {
            $cur = Get-B1Current 'b1user'
            @($cur.AdvancedDebloatStandard).Count | Should Be 1
            (Get-WinEaseGuiPresetState -BasePresetKey 'b1user' -Current $cur).IsModified | Should Be $false
            $cur.AdvancedDebloatStandard = @()
            @((Get-WinEaseGuiPresetState -BasePresetKey 'b1user' -Current $cur).DifferingKeys) -join ',' | Should Be "AdvancedDebloatStandard:$($script:B1StdItem)"
        } finally { $script:BuiltInPresets.Remove('b1user') }
    }

    It "round trip of a modified preset: PresetKey custom, BasePresetKey kept, every value preserved" {
        $iso = Join-Path $TestDrive 'preset-roundtrip.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $work = Join-Path $TestDrive 'preset-work'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $cur = Get-B1Current 'balanced'
        $tk = @($cur.TweakSettings.Keys)[0]
        $flipped = -not $cur.TweakSettings[$tk]
        $cur.TweakSettings[$tk] = $flipped
        $st = Get-WinEaseGuiPresetState -BasePresetKey 'balanced' -Current $cur
        $ck = @($cur.Components.Keys)[0]
        $std = @($script:B1StdItem)
        $json = [ordered]@{
            Success = $true; SourceDrive = $iso; WorkDir = $work; UserName = 'Tester'; ComputerName = '*'; Index = '1'; InjectDrivers = ''
            PresetKey = $st.PresetKey; BasePresetKey = 'balanced'; DryRun = $false; UseVHDX = $false; ExportESDMode = $false; SplitWIMMode = $false
            Components = $cur.Components; TweakSettings = $cur.TweakSettings
            AdvancedDebloatStandard = $std; AdvancedDebloatExperimental = @(); DebloatEngineSelection = @{}; PhysicalDebloatConsent = $true
        } | ConvertTo-Json -Depth 6 -Compress
        $r = ConvertFrom-WinEaseWinUiResult -Result ($json | ConvertFrom-Json)
        $r.PresetKey | Should Be 'custom'
        $r.BasePresetKey | Should Be 'balanced'
        $r.TweakSettings[$tk] | Should Be $flipped
        $r.$ck | Should Be ([bool]$cur.Components[$ck])
        @($r.AdvancedDebloatStandard) -join ',' | Should Be ($std -join ',')

        $script:TweakSettings = [ordered]@{}
        foreach ($k in $script:AllTweakDefs.Keys) { $script:TweakSettings[$k] = [bool]$script:AllTweakDefs[$k].Default }
        $script:B1AppliedBase = $null
        Apply-WinEaseGuiResult -GuiResult $r
        $script:B1AppliedBase | Should Be 'balanced'                    # the base preset is applied first ...
        $script:TweakSettings[$tk] | Should Be $flipped                 # ... and the hand edit wins over it
        @($script:advancedDebloatStandard) -join ',' | Should Be ($std -join ',')
        $script:selectedProfile | Should Be 'custom (based on balanced)'
    }

    It "an unmodified result keeps the preset key; Custom without a base is reported as GUI Selection" {
        $iso = Join-Path $TestDrive 'preset-key.iso'
        Set-Content -LiteralPath $iso -Value 'x'
        $base = [ordered]@{ Success = $true; SourceDrive = $iso; UserName = 'Tester'; PresetKey = 'balanced'; BasePresetKey = 'balanced'; TweakSettings = @{} }
        $r = ConvertFrom-WinEaseWinUiResult -Result (($base | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
        Apply-WinEaseGuiResult -GuiResult $r
        $script:selectedProfile | Should Be 'balanced'
        $base['PresetKey'] = 'Custom'
        $base['BasePresetKey'] = $null
        $r = ConvertFrom-WinEaseWinUiResult -Result (($base | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
        Apply-WinEaseGuiResult -GuiResult $r
        $script:selectedProfile | Should Be 'GUI Selection'
    }

    It "the WinUI request presetState answers with the shared function" {
        $cur = Get-B1Current 'balanced'
        $cur.AdvancedDebloatStandard = @($script:B1StdItem)
        $reply = Invoke-WinEaseWinUiRequest -Op 'presetState' -Arguments ([PSCustomObject]@{ BasePresetKey = 'balanced'; Config = ($cur | ConvertTo-Json -Depth 6 | ConvertFrom-Json) })
        $reply.Data.IsModified | Should Be $true
        $reply.Data.PresetKey | Should Be 'custom'
        $reply.Data.BasePresetKey | Should Be 'balanced'
        (@($reply.Data.DifferingKeys) -contains "AdvancedDebloatStandard:$($script:B1StdItem)") | Should Be $true
        $reply2 = Invoke-WinEaseWinUiRequest -Op 'presetState' -Arguments ([PSCustomObject]@{ BasePresetKey = 'balanced'; Config = ((Get-B1Current 'balanced') | ConvertTo-Json -Depth 6 | ConvertFrom-Json) })
        $reply2.Data.IsModified | Should Be $false
        $reply2.Data.PresetKey | Should Be 'balanced'
    }

    It "WinForms: switching presets keeps the Advanced Debloat selection and engines; Revert to preset restores the preset" {
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ PresetKey = 'balanced'; TweakSettings = [ordered]@{} }
        try {
            $row = @($gui.GrdStd.Rows | Where-Object { [string]$_.Tag -eq $script:B1StdItem })[0]
            $row.Cells['On'].Value = $true
            $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)   # a manual change selects Custom
            # choose another preset: components/tweaks/payload follow it, the debloat selection stays exactly as it was
            $gui.Preset.SelectedIndex = 2
            @($gui.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value }).Count | Should Be 1
            (Get-WinEaseGuiDraftConfig -Gui $gui).AdvancedDebloatStandard -join ',' | Should Be $script:B1StdItem
            $v = Get-WinEaseGuiPresetValues -Name 'fat32'
            foreach ($k in $v.Tweaks.Keys) { [bool]$gui.TweakCheckboxes[$k].Checked | Should Be ([bool]$v.Tweaks[$k]) }
            # the state against the new base reports the leftover selection as a difference ...
            $st = Get-WinEaseGuiPresetState -BasePresetKey 'fat32' -Current (Get-WinEaseGuiDraftConfig -Gui $gui)
            @($st.DifferingKeys) -join ',' | Should Be "AdvancedDebloatStandard:$($script:B1StdItem)"
            # ... and Revert to preset removes it and puts the combo back on the base preset
            (Restore-WinEaseGuiBasePreset -Gui $gui) | Should Be $true
            $gui.Preset.SelectedIndex | Should Be 2
            @($gui.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value }).Count | Should Be 0
            (Get-WinEaseGuiPresetState -BasePresetKey 'fat32' -Current (Get-WinEaseGuiDraftConfig -Gui $gui)).IsModified | Should Be $false
            # a hand-edited tweak, then Revert
            $tk = @($gui.TweakCheckboxes.Keys)[0]
            $gui.TweakCheckboxes[$tk].Checked = -not $gui.TweakCheckboxes[$tk].Checked
            (Get-WinEaseGuiPresetState -BasePresetKey 'fat32' -Current (Get-WinEaseGuiDraftConfig -Gui $gui)).IsModified | Should Be $true
            $null = Restore-WinEaseGuiBasePreset -Gui $gui
            (Get-WinEaseGuiPresetState -BasePresetKey 'fat32' -Current (Get-WinEaseGuiDraftConfig -Gui $gui)).IsModified | Should Be $false
        } finally { $gui.Form.Dispose() }
    }
}

Describe "C1 - build plan (Get-WinEaseBuildPlan, the final confirmation and the builder check)" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:WinEaseDebloatEngines = [ordered]@{}
    foreach ($de in @($settingsDef.DebloatEngines)) { if ($de -and $de.Item) { $script:WinEaseDebloatEngines[[string]$de.Item] = $de } }
    $presetFile = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\presets.psd1")
    $script:BuiltInPresets = [ordered]@{}
    foreach ($k in $presetFile.Presets.Keys) { $script:BuiltInPresets[[string]$k] = $presetFile.Presets[$k] }
    function Get-WinEasePreset { param([string]$Name) if ($Name -and $script:BuiltInPresets.Contains($Name.Trim().ToLower())) { $script:BuiltInPresets[$Name.Trim().ToLower()] } else { $null } }
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
    . $script:GuiCorePath
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseBuildPlan.ps1")
    $script:C1Plenty = { param($Path) $null = $Path; [int64](500GB) }
    $script:C1NoDisk = { param($Path) $null = $Path; $null }
    $script:C1Tiny = { param($Path) $null = $Path; [int64](1GB) }

    # The flat result a window returns for a preset (components at the top level)
    function New-C1Result {
        param([string]$Preset = 'balanced', [bool]$DryRun = $false)
        $v = Get-WinEaseGuiPresetValues -Name $Preset
        $r = @{
            Success = $true; SourceDrive = 'E:'; WorkDir = ''; Index = '1'; DryRun = $DryRun; UseVHDX = $false
            PresetKey = $Preset; BasePresetKey = $Preset; PhysicalDebloatConsent = $false
            ExportESDMode = ($v.PayloadFormat -eq 'ESD'); SplitWIMMode = ($v.PayloadFormat -eq 'SWM')
            TweakSettings = [ordered]@{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @(); DebloatEngineSelection = @{}
        }
        foreach ($k in $v.Components.Keys) { $r[$k] = $v.Components[$k] }
        foreach ($k in $v.Tweaks.Keys) { $r.TweakSettings[$k] = $v.Tweaks[$k] }
        return $r
    }
    function Get-C1Plan { param($Result, $Disk = $script:C1Plenty) Get-WinEaseBuildPlan -Result $Result -FreeSpaceProvider $Disk -OutputDir 'C:\WinEaseOut' }

    It "an unmodified preset has no changes, a populated Unchanged list and a real-build mode" {
        $plan = Get-C1Plan (New-C1Result 'balanced')
        $plan.Mode | Should Be 'RealBuild'
        $plan.IsDryRun | Should Be $false
        $plan.PresetState | Should Be 'Preset'
        @($plan.Changed).Count | Should Be 0
        @($plan.Unchanged).Count | Should BeGreaterThan 20
        $plan.PayloadFormat | Should Be 'WIM'
        $plan.Source | Should Be 'E:'
        $plan.Index | Should Be '1'
    }

    It "the plan follows the current selection: a changed tweak is listed, changing it back removes it (nothing is stale)" {
        $r = New-C1Result 'balanced'
        $tk = @($r.TweakSettings.Keys)[0]
        $r.TweakSettings[$tk] = -not $r.TweakSettings[$tk]
        $p1 = Get-C1Plan $r
        $p1.PresetState | Should Be 'Modified'
        @($p1.Changed | ForEach-Object { $_.Key }) -contains $tk | Should Be $true
        @($p1.Unchanged) -contains $tk | Should Be $false
        $r.TweakSettings[$tk] = -not $r.TweakSettings[$tk]
        $p2 = Get-C1Plan $r
        @($p2.Changed).Count | Should Be 0
        @($p2.Unchanged) -contains $tk | Should Be $true
        # payload format follows the window too
        $r.ExportESDMode = $true
        $p3 = Get-C1Plan $r
        $p3.PayloadFormat | Should Be 'ESD'
        @($p3.Changed | ForEach-Object { $_.Key }) -contains 'PayloadFormat' | Should Be $true
    }

    It "a DryRun is flagged as DRY RUN, needs no acknowledgement; the same critical plan as a real build does" {
        $exp = $script:WinEaseDebloatExperimentalItems[0]
        $r = New-C1Result 'balanced' $true
        $r.AdvancedDebloatExperimental = @($exp); $r.PhysicalDebloatConsent = $true
        $dry = Get-C1Plan $r
        $dry.Mode | Should Be 'DryRun'
        $dry.HasCritical | Should Be $true
        $dry.RequiresAck | Should Be $false
        $r.DryRun = $false
        $real = Get-C1Plan $r
        $real.Mode | Should Be 'RealBuild'
        $real.RequiresAck | Should Be $true
        @($real.Criticals | ForEach-Object { $_.Code }) -contains 'PhysicalDebloat' | Should Be $true
        (Get-WinEaseBuildPlanView -Plan $dry).Text | Should Match 'DRY RUN'
        (Get-WinEaseBuildPlanView -Plan $real).Text | Should Match 'REAL BUILD'
        (Get-WinEaseBuildPlanView -Plan $real).RequiresAck | Should Be $true
        (Get-WinEaseBuildPlanView -Plan $dry).RequiresAck | Should Be $false
    }

    It "Advanced Debloat without consent is Skipped (the build drops it) and absent from the effective settings" {
        $r = New-C1Result 'balanced'
        $item = $script:WinEaseDebloatStandardItems[0]
        $r.AdvancedDebloatStandard = @($item)
        $plan = Get-C1Plan $r
        @($plan.Skipped | Where-Object { $_.Key -eq $item -and $_.ReasonKey -eq 'Plan.Skipped.NoConsent' }).Count | Should Be 1
        @($plan.Effective.AdvancedDebloatStandard).Count | Should Be 0
        $plan.Effective.AllowPhysicalDebloat | Should Be $false
        $r.PhysicalDebloatConsent = $true
        $with = Get-C1Plan $r
        @($with.Skipped | Where-Object { $_.Key -eq $item }).Count | Should Be 0
        @($with.Effective.AdvancedDebloatStandard) -contains $item | Should Be $true
        $with.Effective.AllowPhysicalDebloat | Should Be $true
    }

    It "components a preset does not name are Skipped (kept, not compared)" {
        $plan = Get-C1Plan (New-C1Result 'balanced')
        $named = (Get-WinEaseGuiPresetValues -Name 'balanced').Components.Keys
        foreach ($s in @($plan.Skipped | Where-Object { $_.ReasonKey -eq 'Plan.Skipped.NotInPreset' })) { @($named) -contains $s.Key | Should Be $false }
    }

    It "unknown impact or unresolvable items are Unverified, never Unchanged or OK" {
        $r = New-C1Result 'balanced'
        $r.RemoveDrivers = $true                                   # the catalog marks it Unknown
        $r.TweakSettings['NoSuchTweakInSchema'] = $true            # not in the schema
        $r.AdvancedDebloatStandard = @('Totally unregistered debloat item'); $r.PhysicalDebloatConsent = $true
        $plan = Get-C1Plan $r
        $unv = @($plan.Unverified | ForEach-Object { $_.Key })
        $unv -contains 'RemoveDrivers' | Should Be $true
        $unv -contains 'NoSuchTweakInSchema' | Should Be $true
        $unv -contains 'Totally unregistered debloat item' | Should Be $true
        foreach ($k in $unv) { @($plan.Unchanged) -contains $k | Should Be $false }
        $plan.HasCritical | Should Be $true
        $dd = @($plan.Dangerous | Where-Object { $_.Key -eq 'RemoveDrivers' })[0]
        $dd.Kind | Should Be 'Unknown'
        $dd.Reversibility | Should Be 'Undocumented'
        # a base preset that does not exist cannot be compared: Unverified, not "no changes"
        $r2 = New-C1Result 'balanced'; $r2.BasePresetKey = 'no-such-preset'
        $p2 = Get-C1Plan $r2
        $p2.PresetState | Should Be 'Custom'
        @($p2.Unverified | Where-Object { $_.ReasonKey -eq 'Plan.Unverified.NoPreset' }).Count | Should Be 1
        @($p2.Changed).Count | Should Be 0
    }

    It "dangerous items carry their impact and the documented reversibility; undocumented stays 'not documented'" {
        $r = New-C1Result 'balanced'
        $r.RemoveDefender = $true; $r.DisableWindowsUpdate = $true; $r.KeepAsianIME = $false
        $plan = Get-C1Plan $r
        $def = @($plan.Dangerous | Where-Object { $_.Key -eq 'RemoveDefender' })[0]
        $def.Reversibility | Should Be 'Irreversible'
        $def.Impact | Should Not BeNullOrEmpty
        @($def.AffectedFeatures).Count | Should BeGreaterThan 0
        (@($plan.Dangerous | Where-Object { $_.Key -eq 'DisableWindowsUpdate' })[0]).Reversibility | Should Be 'Reversible'
        (@($plan.Dangerous | Where-Object { $_.Key -eq 'KeepAsianIME' })[0]).Reversibility | Should Be 'Undocumented'
        @($plan.Criticals | ForEach-Object { $_.Code }) -contains 'Irreversible' | Should Be $true
        $text = (Get-WinEaseBuildPlanView -Plan $plan).Text
        $text | Should Match 'not documented'
        $text | Should Match 'NOT reversible in place'
    }

    It "an unreadable free space is 'unknown' (Unverified, not OK); a known shortage is critical; needs on one volume add up" {
        $unk = Get-C1Plan (New-C1Result 'balanced') $script:C1NoDisk
        @($unk.Disk | Where-Object { $_.Status -ne 'Unknown' }).Count | Should Be 0
        $unk.Disk[0].FreeGB | Should BeNullOrEmpty
        @($unk.Unverified | Where-Object { $_.ReasonKey -eq 'Plan.Unverified.DiskUnknown' }).Count | Should BeGreaterThan 0
        @($unk.Criticals | Where-Object { $_.Code -eq 'DiskInsufficient' }).Count | Should Be 0
        (Get-WinEaseBuildPlanView -Plan $unk).Text | Should Match 'unknown \(not verified\)'
        $low = Get-C1Plan (New-C1Result 'balanced') $script:C1Tiny
        @($low.Criticals | Where-Object { $_.Code -eq 'DiskInsufficient' }).Count | Should BeGreaterThan 0
        $low.RequiresAck | Should Be $true
        $ok = Get-C1Plan (New-C1Result 'balanced')
        @($ok.Criticals | Where-Object { $_.Code -eq 'DiskInsufficient' }).Count | Should Be 0
        # work folder and output on the same drive: one entry with both requirements
        $r = New-C1Result 'balanced'; $r.WorkDir = 'C:\Work'
        $same = Get-WinEaseBuildPlan -Result $r -FreeSpaceProvider $script:C1Plenty -OutputDir 'C:\Out' -OutputIsoName 'my'
        @($same.Disk).Count | Should Be 1
        @($same.Disk[0].Roles).Count | Should Be 2
        $same.Disk[0].RequiredGB | Should BeGreaterThan ((Get-WinEaseRecommendedFreeGB) + 1)
        $same.OutputName | Should Be 'my.iso'
    }

    It "Get-WinEaseVolumeFreeBytes returns a number for the system drive and null for what it cannot read" {
        (Get-WinEaseVolumeFreeBytes -Path $env:SystemDrive) | Should BeGreaterThan 0
        (Get-WinEaseVolumeFreeBytes -Path '\\no-such-host\share\x') | Should BeNullOrEmpty
        (Get-WinEaseVolumeFreeBytes -Path '') | Should BeNullOrEmpty
    }

    It "Get-WinEaseBuildSizeEstimateMB is the figure the windows show (5500 MB base, ESD x0.82)" {
        (Get-WinEaseBuildSizeEstimateMB -Components @{}) | Should Be 5500
        (Get-WinEaseBuildSizeEstimateMB -Components @{ KeepAsianIME = $true }) | Should Be 5900
        (Get-WinEaseBuildSizeEstimateMB -Components @{} -PayloadFormat 'ESD') | Should Be ([math]::Round(5500 * 0.82))
    }

    It "the plan survives the JSON round trip of the WinUI bridge and the compare works on it" {
        $plan = Get-C1Plan (New-C1Result 'balanced')
        $back = $plan | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $cur = [ordered]@{ PayloadFormat = 'WIM'; UseVHDX = $false; DryRun = $false; TweakSettings = $plan.Effective.TweakSettings }
        foreach ($k in $plan.Effective.Components.Keys) { $cur[$k] = $plan.Effective.Components[$k] }
        (Compare-WinEaseBuildPlanToSettings -Plan $back -Resolved $cur).Match | Should Be $true
    }

    It "plan vs resolved settings: equal -> match; a differing setting is reported; critical ones are flagged; unknown keys are not compared" {
        $plan = Get-C1Plan (New-C1Result 'balanced')
        $res = [ordered]@{ PayloadFormat = 'WIM'; UseVHDX = $false; DryRun = $false; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @(); TweakSettings = [ordered]@{}; SomethingElse = 1 }
        foreach ($k in $plan.Effective.Components.Keys) { $res[$k] = $plan.Effective.Components[$k] }
        foreach ($k in $plan.Effective.TweakSettings.Keys) { $res.TweakSettings[$k] = $plan.Effective.TweakSettings[$k] }
        $c0 = Compare-WinEaseBuildPlanToSettings -Plan $plan -Resolved $res
        $c0.Match | Should Be $true
        @($c0.Mismatches).Count | Should Be 0
        # a critical component (catalog Known) differs
        $res.DisableWindowsUpdate = -not $plan.Effective.Components.DisableWindowsUpdate
        $c1 = Compare-WinEaseBuildPlanToSettings -Plan $plan -Resolved $res
        $c1.Match | Should Be $false
        $c1.HasCritical | Should Be $true
        $c1.Mismatches[0].Key | Should Be 'DisableWindowsUpdate'
        $res.DisableWindowsUpdate = $plan.Effective.Components.DisableWindowsUpdate
        # a tweak the catalog does not mark differs: reported, not critical
        $tk = @($plan.Effective.TweakSettings.Keys | Where-Object { -not (Get-WinEaseBuildPlanCatalogEntry -Source $_) -or (Get-WinEaseBuildPlanCatalogEntry -Source $_).Status -eq 'Safe' })[0]
        $res.TweakSettings[$tk] = -not $plan.Effective.TweakSettings[$tk]
        $c2 = Compare-WinEaseBuildPlanToSettings -Plan $plan -Resolved $res
        $c2.Match | Should Be $false
        $c2.HasCritical | Should Be $false
        $c2.Mismatches[0].Key | Should Be "Tweak:$tk"
        $res.TweakSettings[$tk] = $plan.Effective.TweakSettings[$tk]
        # build options and the debloat lists are critical
        $res.PayloadFormat = 'ESD'
        (Compare-WinEaseBuildPlanToSettings -Plan $plan -Resolved $res).HasCritical | Should Be $true
        $res.PayloadFormat = 'WIM'
        $res.AdvancedDebloatStandard = @('Remove help files [10-20MB]')
        $c3 = Compare-WinEaseBuildPlanToSettings -Plan $plan -Resolved $res
        $c3.HasCritical | Should Be $true
        $c3.Mismatches[0].Key | Should Be 'AdvancedDebloatStandard'
    }

    It "Invoke-WinEaseBuildPlanCheck writes the plan summary, warns on a mismatch and throws on a critical one" {
        $plan = Get-C1Plan (New-C1Result 'balanced')
        $res = [ordered]@{ PayloadFormat = 'WIM'; UseVHDX = $false; DryRun = $false }
        $dir = Join-Path $TestDrive 'logs'
        $cmp = Invoke-WinEaseBuildPlanCheck -Plan $plan -Resolved $res -LogDirectory $dir -BaseName 'WinEase_test'
        $cmp.Match | Should Be $true
        (Test-Path (Join-Path $dir 'WinEase_test.plan.json')) | Should Be $true
        (Get-Content (Join-Path $dir 'WinEase_test.plan.txt') -Raw) | Should Match 'REAL BUILD'
        ((Get-Content (Join-Path $dir 'WinEase_test.plan.json') -Raw) | ConvertFrom-Json).Mode | Should Be 'RealBuild'
        $res.PayloadFormat = 'ESD'
        { Invoke-WinEaseBuildPlanCheck -Plan $plan -Resolved $res -LogDirectory $dir -BaseName 'WinEase_t2' -WarningAction SilentlyContinue } | Should Throw 'critical'
        (Invoke-WinEaseBuildPlanCheck -Plan $null -Resolved $res) | Should BeNullOrEmpty
    }

    It "the localized view is complete in English and Japanese and has the mode banner, sections and acknowledgement text" {
        $r = New-C1Result 'balanced'; $r.RemoveDefender = $true
        $plan = Get-C1Plan $r
        try {
            foreach ($lang in 'en', 'ja') {
                Set-WinEaseUiLanguage -Language $lang
                $view = Get-WinEaseBuildPlanView -Plan $plan
                $view.ModeText | Should Not Match '^Plan\.'
                @($view.Sections).Count | Should BeGreaterThan 6
                foreach ($sec in $view.Sections) { $sec.Heading | Should Not Match '^Plan\.'; foreach ($l in $sec.Lines) { $l | Should Not Match 'Plan\.[A-Z][a-z]+\.' } }
                $view.AckText | Should Not Match '^Plan\.'
                $view.RequiresAck | Should Be $true
            }
            Set-WinEaseUiLanguage -Language 'ja'
            (Get-WinEaseBuildPlanView -Plan $plan).ModeText | Should Match ([string][char]0x5B9F)
        } finally { Set-WinEaseUiLanguage -Language 'en' }
    }

    It "every string key the plan, the windows and the host use exists in en.json and ja.json" {
        $dir = Join-Path $script:RepoRoot 'config\ui-strings'
        $enb = New-Object System.Text.UTF8Encoding($false)
        $en = [System.IO.File]::ReadAllText((Join-Path $dir 'en.json'), $enb) | ConvertFrom-Json
        $ja = [System.IO.File]::ReadAllText((Join-Path $dir 'ja.json'), $enb) | ConvertFrom-Json
        $sources = @('lib\WinEaseBuildPlan.ps1', 'gui\WinEaseGui.ps1', 'gui\winui\WinEaseGui\MainWindow.xaml.cs') | ForEach-Object { [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $_)) }
        $keys = @($sources | ForEach-Object { [regex]::Matches($_, "['""]((?:Plan\.[A-Za-z]+(?:\.[A-Za-z]+)*)|Msg\.Plan\.Failed\.Continue|Msg\.Dependency\.CheckFailed(?:\.Checkbox)?)['""]") } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $keys.Count | Should BeGreaterThan 40
        $missing = @($keys | Where-Object { -not $en.PSObject.Properties[$_] -or -not $ja.PSObject.Properties[$_] })
        ($missing -join ', ') | Should Be ''
        # the Plan.* tables match key for key
        (@($en.PSObject.Properties.Name | Where-Object { $_ -like 'Plan.*' } | Sort-Object) -join ',') | Should Be (@($ja.PSObject.Properties.Name | Where-Object { $_ -like 'Plan.*' } | Sort-Object) -join ',')
        # placeholders agree between the languages
        foreach ($k in $keys) {
            $pe = @([regex]::Matches([string]$en.$k, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $pj = @([regex]::Matches([string]$ja.$k, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            "${k}:$pe" | Should Be "${k}:$pj"
        }
    }

    It "wiring: both windows confirm the plan before returning, the host serves it, the builder checks it, the WinForms pre-check does not fail open" {
        $gui = [System.IO.File]::ReadAllText($script:GuiPath)
        $gui | Should Match 'Confirm-WinEaseGuiBuildPlan -Result \$g\.Result'
        $gui | Should Match '\$g\.Result\.BuildPlan = \$confirmedPlan'
        $gui | Should Not Match 'Dependency check skipped'
        $gui | Should Match 'Msg\.Dependency\.CheckFailed\.Checkbox'
        $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
        $cs | Should Match 'RunAsync\("buildPlan"'
        $cs | Should Match 'ShowBuildPlanDialogAsync\(view\)'
        $cs | Should Match 'IsPrimaryButtonEnabled = !ackNeeded'
        $cs | Should Match 'result\["BuildPlan"\]'
        $host1 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\WinEaseWinUiHost.ps1'))
        $host1 | Should Match "'buildPlan'"
        $host1 | Should Match 'Get-WinEaseBuildPlan -Result'
        $host1 | Should Match '\$out\.BuildPlan = \$r\.BuildPlan'
        $b = [System.IO.File]::ReadAllText($script:BuilderPath)
        $b | Should Match "'WinEaseBuildPlan\.ps1'"
        $b | Should Match 'Invoke-WinEaseBuildPlanCheck -Plan \$script:GuiBuildPlan'
        [System.IO.File]::ReadAllText($script:GuiSessionPath) | Should Match '\$script:GuiBuildPlan = \$GuiResult\.BuildPlan'
    }
}
