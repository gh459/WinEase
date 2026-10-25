# GuiParity.Tests.ps1 - WinUI 3 / WinForms / command line parity (PR B3)
# Run with:  Invoke-Pester -Path .\tests\GuiParity.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# What is checked here (everything that can be checked without a rendered window):
#   a. the toggles both windows build come from config\schema.psd1 and carry en / ja labels
#   b. the same selections give the same result hashtable in both windows, the same builder
#      variables after Apply-WinEaseGuiResult, and the same meaning through -LoadProfile
#   c. save -> load -> save loses nothing, a language switch keeps values, Dry Run never starts
#      a build, physical deletion needs the consent, invalid input is refused
#   d. no button / toggle of MainWindow.xaml is left without a handler
# What cannot be checked here (layout, DPI, narrator, contrast, ...) is listed in
# docs\GUI_MANUAL_CHECKLIST.md.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Evaluates function text taken from the repository''s own source AST')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers only change test state')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Test helper names')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "GUI parity (WinUI 3 / WinForms / command line)" {
    BeforeAll {
        $script:ParityRoot = $script:RepoRoot

        # --- the builder's derived tables, built from config\schema.psd1 exactly as WinEasebuilder.ps1 does ---
        $def = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ParityRoot 'config\schema.psd1')
        $script:SchemaDef = $def
        $script:AllTweakDefs = [ordered]@{}
        $script:TweakKeyAliases = [ordered]@{}
        $script:TweakVariableMap = [ordered]@{}
        foreach ($td in $def.Tweaks) {
            $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description }
            foreach ($alias in @($td.Aliases)) { if ($alias) { $script:TweakKeyAliases[$alias] = $td.Key } }
            if ($td.Variable) { $script:TweakVariableMap[$td.Key] = $td.Variable }
        }
        $script:ComponentDefs = [ordered]@{}
        foreach ($cd in $def.Components) { $script:ComponentDefs[$cd.Key] = $cd }
        $script:WinEaseProfileKeys = @($script:ComponentDefs.Keys) + @($script:AllTweakDefs.Keys) + @('DebloatEngineSelection')
        $script:WinEaseDebloatEngines = [ordered]@{}
        $script:WinEaseDebloatLegacyMap = [ordered]@{}
        foreach ($de in @($def.DebloatEngines)) {
            if (-not $de -or -not $de.Item) { continue }
            $script:WinEaseDebloatEngines[[string]$de.Item] = $de
            foreach ($legacyItem in @($de.Legacy)) { if ($legacyItem) { $script:WinEaseDebloatLegacyMap[[string]$legacyItem] = [string]$de.Item } }
        }
        $script:WinEaseVersion = '2.1'
        $script:NonInteractive = $true

        $presetFile = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ParityRoot 'config\presets.psd1')
        $script:PresetFile = $presetFile
        $script:BuiltInPresets = [ordered]@{}
        foreach ($presetKey in @($presetFile.PresetOrder)) {
            if ($presetFile.Presets.Contains($presetKey)) { $script:BuiltInPresets[$presetKey] = $presetFile.Presets[$presetKey] }
        }
        $script:BuiltInPresetAliases = [ordered]@{ '1' = 'extreme'; '2' = 'balanced'; '3' = 'fat32'; '4' = 'handheld'; '5' = 'vm'; '6' = 'audio' }
        foreach ($aliasKey in @($presetFile.Aliases.Keys)) { $script:BuiltInPresetAliases[[string]$aliasKey] = [string]$presetFile.Aliases[$aliasKey] }

        # --- the real function bodies of the builder (profile load / save path) and of the session bridge ---
        . (Join-Path $script:ParityRoot 'lib\WinEaseDebloat.ps1')
        $builderAst = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        foreach ($name in @('Resolve-WinEaseTweakKey', 'Sync-WinEaseTweakVariables', 'Get-WinEaseComponentValue', 'Get-WinEaseCurrentConfig',
                            'Export-WinEaseProfile', 'Get-WinEasePreset', 'Get-WinEaseProfileValue', 'Apply-WinEaseProfileComponents',
                            'Apply-WinEaseProfileDebloat', 'Apply-WinEaseProfileTweakGroupsAndFormat', 'Apply-WinEaseProfileTweaks',
                            'Apply-ProfileSettings', 'Import-WinEaseProfile')) {
            $fn = $builderAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            if (-not $fn) { throw "builder function not found: $name" }
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        $sessionText = [System.IO.File]::ReadAllText($script:GuiSessionPath, [System.Text.Encoding]::UTF8)
        $sessionAst = [System.Management.Automation.Language.Parser]::ParseInput($sessionText, [ref]$null, [ref]$null)
        foreach ($name in @('Get-WinEaseGuiInitialSettings', 'Apply-WinEaseGuiResult')) {
            $fn = $sessionAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        # The consent fallback of the session bridge, with its modal MessageBox replaced by a stub so the
        # No / Yes answer can be scripted (the function body is otherwise the production text).
        $consentFn = $sessionAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-WinEasePhysicalDebloatConsent' }, $true)
        $consentText = $consentFn.Extent.Text.Replace('[System.Windows.Forms.MessageBox]::Show(', 'Show-ParityConsentBox(')
        if ($consentText -eq $consentFn.Extent.Text) { throw 'the consent function no longer calls MessageBox::Show: update this test' }
        . ([scriptblock]::Create($consentText))

        # --- both windows ---
        Add-Type -AssemblyName System.Windows.Forms
        . $script:GuiPath
        # The WinForms window asks for the consent through this function: scripted, never modal
        $script:ParityConfirmAnswer = $true
        function Confirm-WinEaseGuiAction { param([string]$Message, [string]$Title) $null = $Message; $null = $Title; return [bool]$script:ParityConfirmAnswer }
        $script:ParityMessages = @()
        function Show-WinEaseGuiMessage { param([string]$Text, [string]$Title, $Kind) $null = $Title; $null = $Kind; $script:ParityMessages += $Text }
        # Never write the user's real gui-settings.json
        function Save-WinEaseGuiLanguage { param([string]$Language) $null = $Language }
        $script:ParityConsentPrompts = 0
        $script:ParityConsentAnswer = [System.Windows.Forms.DialogResult]::No
        function Show-ParityConsentBox { param($Text, $Caption, $Buttons, $Icon) $null = $Text; $null = $Caption; $null = $Buttons; $null = $Icon; $script:ParityConsentPrompts++; return $script:ParityConsentAnswer }

        # --- helpers ---
        $script:ParityExtraBuilderVars = @('SourceDrive', 'WorkDir', 'UserName', 'ComputerName', 'Index', 'InjectDrivers', 'useVHDX', 'exportESDMode',
                                           'splitWIMMode', 'DryRun', 'isDryRunMode', 'selectedProfile', 'allowPhysicalDebloat')
        function Reset-ParityBuilderState {
            foreach ($cd in $script:ComponentDefs.Values) {
                if ($cd.Type -eq 'Special' -or -not $cd.Variable) { continue }
                $v = if ($cd.ContainsKey('Default')) { $cd.Default } elseif ($cd.Type -eq 'String') { '' } else { $false }
                Set-Variable -Name $cd.Variable -Scope Script -Value $v
            }
            $script:TweakSettings = [ordered]@{}
            foreach ($tk in $script:AllTweakDefs.Keys) { $script:TweakSettings[$tk] = [bool]$script:AllTweakDefs[$tk].Default }
            foreach ($tk in $script:TweakVariableMap.Keys) { Set-Variable -Name $script:TweakVariableMap[$tk] -Scope Script -Value ([bool]$script:AllTweakDefs[$tk].Default) }
            $script:advancedDebloatStandard = @()
            $script:advancedDebloatExperimental = @()
            $script:DebloatEngineSelection = [ordered]@{}
            $script:ConfigOverrides = [ordered]@{}
            $script:TweakGroups = [ordered]@{}
            $script:activeTweakGroups = [ordered]@{}
            $script:SourceDrive = ''; $script:WorkDir = ''; $script:UserName = 'User'; $script:ComputerName = '*'
            $script:Index = ''; $script:InjectDrivers = ''
            $script:exportESDMode = $false; $script:splitWIMMode = $false
            $script:DryRun = $false; $script:isDryRunMode = $false
            $script:selectedProfile = $null
            $script:allowPhysicalDebloat = $false
            $script:UserPassword = 'x'
        }

        # Everything the build reads, as sorted text lines (a diff is readable in the failure message)
        function Get-ParitySnapshot {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($n in $script:ParityExtraBuilderVars) {
                $v = Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                $lines.Add("$n=$v")
            }
            foreach ($cd in $script:ComponentDefs.Values) {
                if ($cd.Type -eq 'Special' -or -not $cd.Variable) { continue }
                $v = Get-Variable -Name $cd.Variable -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                $lines.Add("component.$($cd.Key)=$v")
            }
            foreach ($k in $script:TweakSettings.Keys) { $lines.Add("tweak.$k=$([bool]$script:TweakSettings[$k])") }
            foreach ($tk in $script:TweakVariableMap.Keys) {
                $v = Get-Variable -Name $script:TweakVariableMap[$tk] -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                $lines.Add("tweakvar.$tk=$([bool]$v)")
            }
            $lines.Add('debloatStd=' + ((@($script:advancedDebloatStandard) | Sort-Object) -join '|'))
            $lines.Add('debloatExp=' + ((@($script:advancedDebloatExperimental) | Sort-Object) -join '|'))
            foreach ($k in $script:DebloatEngineSelection.Keys) { $lines.Add("engine.$k=$($script:DebloatEngineSelection[$k])") }
            return @($lines | Sort-Object)
        }

        # Differences between two snapshots as short lines
        function Compare-ParityText {
            param([string[]]$Left, [string[]]$Right)
            $d = [System.Collections.Generic.List[string]]::new()
            foreach ($l in $Left) { if ($Right -notcontains $l) { $d.Add("only left: $l") } }
            foreach ($r in $Right) { if ($Left -notcontains $r) { $d.Add("only right: $r") } }
            return @($d)
        }

        # The keys of a GUI result hashtable the builder consumes (Apply-WinEaseGuiResult), flattened to lines
        function Get-ParityResultLines {
            param([hashtable]$Result, [string[]]$Skip = @())
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($k in @('Success', 'SourceDrive', 'WorkDir', 'UserName', 'ComputerName', 'Index', 'InjectDrivers', 'PresetKey', 'BasePresetKey',
                             'DryRun', 'UseVHDX', 'ExportESDMode', 'SplitWIMMode', 'PhysicalDebloatConsent')) {
                if ($Skip -contains $k) { continue }
                $lines.Add("$k=$($Result[$k])")
            }
            foreach ($cd in $script:ComponentDefs.Values) {
                if ($cd.Gui) { $lines.Add("component.$($cd.Key)=$([bool]$Result[$cd.Key])") }
            }
            foreach ($k in $Result.TweakSettings.Keys) { $lines.Add("tweak.$k=$([bool]$Result.TweakSettings[$k])") }
            $lines.Add('debloatStd=' + ((@($Result.AdvancedDebloatStandard) | Sort-Object) -join '|'))
            $lines.Add('debloatExp=' + ((@($Result.AdvancedDebloatExperimental) | Sort-Object) -join '|'))
            foreach ($k in $Result.DebloatEngineSelection.Keys) { $lines.Add("engine.$k=$($Result.DebloatEngineSelection[$k])") }
            return @($lines | Sort-Object)
        }

        # What the WinUI 3 window (MainWindow.xaml.cs ResultObject) sends: JSON that goes through the real conversion.
        # -SkipValidation only for tests of the mapping itself (C2 has its own refusal tests).
        function ConvertTo-ParityWinUiResult {
            param([hashtable]$Window, [switch]$SkipValidation)
            $json = $Window | ConvertTo-Json -Depth 8 -Compress
            return (ConvertFrom-WinEaseWinUiResult -Result ($json | ConvertFrom-Json) -SkipValidation:$SkipValidation)
        }

        # The init message the window gets, round-tripped through JSON like the real pipe
        function Get-ParityInit {
            param([hashtable]$InitialSettings = @{}, [string]$Language = 'en')
            return ((New-WinEaseWinUiInitMessage -Language $Language -InitialSettings $InitialSettings) | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json)
        }

        # A window result as the window would build it from the init message (all selections unchanged)
        function New-ParityWindowFromInit {
            param($Init)
            $tweaks = [ordered]@{}
            foreach ($t in @($Init.Tweaks)) {
                $iv = $Init.Initial.TweakSettings.PSObject.Properties[$t.Key]
                $tweaks[$t.Key] = if ($iv) { [bool]$iv.Value } else { [bool]$t.Default }
            }
            $components = [ordered]@{}
            foreach ($c in @($Init.Components)) {
                $iv = $Init.Initial.Components.PSObject.Properties[$c.Key]
                $components[$c.Key] = if ($iv) { [bool]$iv.Value } else { [bool]$c.Default }
            }
            $engines = [ordered]@{}
            foreach ($p in $Init.Initial.DebloatEngineSelection.PSObject.Properties) { $engines[$p.Name] = [string]$p.Value }
            return @{
                Success = $true
                SourceDrive = "$($Init.Initial.SourceDrive)"; WorkDir = "$($Init.Initial.WorkDir)"; Index = "$($Init.Initial.Index)"
                InjectDrivers = "$($Init.Initial.InjectDrivers)"; UserName = "$($Init.Initial.UserName)"; ComputerName = "$($Init.Initial.ComputerName)"
                PresetKey = $null; BasePresetKey = $null; DryRun = $false
                UseVHDX = [bool]$Init.Initial.UseVHDX; ExportESDMode = [bool]$Init.Initial.ExportESDMode; SplitWIMMode = [bool]$Init.Initial.SplitWIMMode
                Components = $components; TweakSettings = $tweaks
                AdvancedDebloatStandard = @($Init.Initial.AdvancedDebloatStandard); AdvancedDebloatExperimental = @($Init.Initial.AdvancedDebloatExperimental)
                DebloatEngineSelection = $engines; PhysicalDebloatConsent = $false
            }
        }

        function Close-ParityGui { param($Gui) if ($Gui -and $Gui.Form) { $Gui.Form.Dispose() } }

        # --- the fixture: a profile that touches every kind of setting (read through the real -LoadProfile path) ---
        $flip = {
            param($Default, [int]$Index)
            if (($Index % 3) -eq 0) { return (-not [bool]$Default) }
            return [bool]$Default
        }
        $fxTweaks = [ordered]@{}
        $i = 0
        foreach ($tk in $script:AllTweakDefs.Keys) { $fxTweaks[$tk] = [bool](& $flip $script:AllTweakDefs[$tk].Default $i); $i++ }
        $fxSettings = [ordered]@{}
        $i = 0
        foreach ($cd in $script:ComponentDefs.Values) {
            if ($cd.Type -eq 'Bool' -and $cd.Gui) { $fxSettings[$cd.Key] = [bool](& $flip $cd.Gui.Default $i); $i++ }
        }
        $fxStd = @($script:WinEaseDebloatStandardItems[0], $script:WinEaseDebloatStandardItems[1])
        $fxExp = @($script:WinEaseDebloatExperimentalItems[0])
        $fxSettings['PayloadFormat'] = 'SWM'
        $fxSettings['UseVHDX'] = $true
        $fxSettings['TweakSettings'] = $fxTweaks
        $fxSettings['AdvancedDebloatStandard'] = $fxStd
        $fxSettings['AdvancedDebloatExperimental'] = $fxExp
        # PatchCache supports both engines and runs on PowerShell by default
        $script:FxEngineItem = $script:WinEaseDebloatStandardItems[0]
        $fxSettings['DebloatEngineSelection'] = [ordered]@{ $script:FxEngineItem = 'Rust' }
        $script:FixtureSettings = $fxSettings
        $script:FixtureTweaks = $fxTweaks
        $script:FixtureStd = $fxStd
        $script:FixtureExp = $fxExp
        $script:FixtureProfilePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("parity_fixture_" + [guid]::NewGuid().ToString('N') + '.json')
        ([ordered]@{ ProfileName = 'parity-fixture'; Version = '2.1'; Settings = $fxSettings } | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $script:FixtureProfilePath -Encoding UTF8

        # C2: both windows run the shared input check on Start and on the WinUI result, so the fixture paths must exist
        $parityTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winease_parity_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $parityTemp | Out-Null
        $script:ParityTemp = $parityTemp
        $parityIso = Join-Path $parityTemp 'win11.iso'
        Set-Content -LiteralPath $parityIso -Value 'x'
        $parityWork = Join-Path $parityTemp 'work'
        $parityDrivers = Join-Path $parityTemp 'drivers'
        New-Item -ItemType Directory -Force -Path $parityWork, $parityDrivers | Out-Null
        $script:Fx = @{
            SourceDrive = $parityIso; WorkDir = $parityWork; Index = '2'; InjectDrivers = $parityDrivers; UserName = 'Tester 1'; ComputerName = 'WIN-PARITY'
        }
    }

    AfterAll {
        if ($script:FixtureProfilePath -and (Test-Path -LiteralPath $script:FixtureProfilePath)) { Remove-Item -LiteralPath $script:FixtureProfilePath -Force -ErrorAction SilentlyContinue }
        if ($script:ParityTemp -and (Test-Path -LiteralPath $script:ParityTemp)) { Remove-Item -LiteralPath $script:ParityTemp -Recurse -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.Application]::Exit()
    }

    # =========================================================================================
    # a. the toggles of both windows come from the schema and carry en / ja labels
    # =========================================================================================
    Context "a. toggles and labels" {
        BeforeAll {
            $script:GuiA = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = 'Q:\' }
            $script:InitA = Get-ParityInit
            $script:GuiComponentKeys = @($script:ComponentDefs.Values | Where-Object { $_.Gui } | ForEach-Object { $_.Key })
        }
        AfterAll { Close-ParityGui $script:GuiA }

        It "WinForms builds exactly the schema tweaks (no key missing, none invented)" {
            $schema = @($script:AllTweakDefs.Keys | Sort-Object)
            $form = @($script:GuiA.TweakCheckboxes.Keys | Sort-Object)
            (Compare-ParityText $schema $form) -join '; ' | Should BeNullOrEmpty
            $form.Count | Should Be $script:SchemaDef.Tweaks.Count
        }

        It "WinUI init data carries exactly the schema tweaks with the schema category and default" {
            $schema = @($script:AllTweakDefs.Keys | Sort-Object)
            $ui = @(@($script:InitA.Tweaks) | ForEach-Object { $_.Key } | Sort-Object)
            (Compare-ParityText $schema $ui) -join '; ' | Should BeNullOrEmpty
            $bad = @(@($script:InitA.Tweaks) | Where-Object { $_.Category -ne $script:AllTweakDefs[$_.Key].Category -or [bool]$_.Default -ne $script:AllTweakDefs[$_.Key].Default })
            ($bad | ForEach-Object { $_.Key }) -join ',' | Should BeNullOrEmpty
        }

        It "every tweak category of the schema has a tab in both windows" {
            $cats = @($script:AllTweakDefs.Values | ForEach-Object { $_.Category } | Sort-Object -Unique)
            ($cats -join ',') | Should Be 'Performance,Privacy,Security,UI'
            # WinForms: New-WinEaseTweakTabs loops over exactly these four; WinUI: nav items security/privacy/performance/ui
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            foreach ($tag in 'security', 'privacy', 'performance', 'ui') { $cs | Should Match ('\("' + $tag + '",') }
        }

        It "WinForms and WinUI show the same Services and Apps components, and they are the schema Gui components" {
            $schema = @($script:GuiComponentKeys | Sort-Object)
            $form = @($script:GuiA.ComponentCheckboxes.Keys | Sort-Object)
            $ui = @(@($script:InitA.Components) | ForEach-Object { $_.Key } | Sort-Object)
            (Compare-ParityText $schema $form) -join '; ' | Should BeNullOrEmpty
            (Compare-ParityText $schema $ui) -join '; ' | Should BeNullOrEmpty
        }

        It "both windows list the same debloat targets, and every target has an engine binding in the schema" {
            $init = $script:InitA
            (@($init.DebloatStandard) -join "`n") | Should Be (@($script:WinEaseDebloatStandardItems) -join "`n")
            (@($init.DebloatExperimental) -join "`n") | Should Be (@($script:WinEaseDebloatExperimentalItems) -join "`n")
            @($script:GuiA.GrdStd.Rows | ForEach-Object { [string]$_.Tag }) -join "`n" | Should Be (@($script:WinEaseDebloatStandardItems) -join "`n")
            @($script:GuiA.GrdExp.Rows | ForEach-Object { [string]$_.Tag }) -join "`n" | Should Be (@($script:WinEaseDebloatExperimentalItems) -join "`n")
            $unbound = @(@($script:WinEaseDebloatStandardItems) + @($script:WinEaseDebloatExperimentalItems) | Where-Object { -not $script:WinEaseDebloatEngines.Contains($_) })
            ($unbound -join '; ') | Should BeNullOrEmpty
        }

        It "both windows offer the same presets, and each one exists in config\presets.psd1" {
            $formKeys = @($script:GuiA.PresetKeyMap)
            $uiKeys = @(@($script:InitA.Presets) | ForEach-Object { $_.Key })
            ($formKeys -join ',') | Should Be ($uiKeys -join ',')
            foreach ($k in $formKeys) { $script:PresetFile.Presets.ContainsKey($k) | Should Be $true }
            # NOTE: presets.psd1 PresetOrder also lists 'none'; neither window offers it (same in both, so not a parity bug)
        }

        It "every GUI-visible schema entry has a Japanese label in ui-strings\ja.json (tweaks, components)" {
            $ja = Get-WinEaseUiTable -Language 'ja'
            $missing = @()
            foreach ($tk in $script:AllTweakDefs.Keys) {
                if (-not "$($ja["Tweak.$tk.Description"])".Trim()) { $missing += "Tweak.$tk.Description" }
            }
            foreach ($cd in $script:ComponentDefs.Values) {
                if (-not $cd.Gui) { continue }
                foreach ($f in 'Text', 'Description') {
                    if (-not "$($ja["Component.$($cd.Key).$f"])".Trim()) { $missing += "Component.$($cd.Key).$f" }
                }
            }
            ($missing -join '; ') | Should BeNullOrEmpty
        }

        It "every GUI-visible schema entry has an English label (the schema text, en.json overrides it) that resolves in both windows' code path" {
            $missing = @()
            foreach ($tk in $script:AllTweakDefs.Keys) {
                $label = Get-WinEaseUiString -Key "Tweak.$tk.Description" -Language 'en' -Default "$($script:AllTweakDefs[$tk].Description)"
                if (-not "$label".Trim() -or $label -eq "Tweak.$tk.Description") { $missing += $tk }
            }
            foreach ($cd in $script:ComponentDefs.Values) {
                if (-not $cd.Gui) { continue }
                foreach ($f in 'Text', 'Description') {
                    $label = Get-WinEaseUiString -Key "Component.$($cd.Key).$f" -Language 'en' -Default "$($cd.Gui.$f)"
                    if (-not "$label".Trim() -or $label -like 'Component.*') { $missing += "$($cd.Key).$f" }
                }
            }
            ($missing -join '; ') | Should BeNullOrEmpty
        }

        It "WinUI and WinForms look the labels up under the same ui-strings keys" {
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            $ps = [System.IO.File]::ReadAllText($script:GuiPath) + [System.IO.File]::ReadAllText($script:GuiCorePath)
            $cs | Should Match 'Tweak\.\{t\.Key\}\.Description'
            $ps | Should Match 'Tweak\.\$Key\.Description'
            $cs | Should Match 'Component\.\{c\.Key\}\.Text'
            $cs | Should Match 'Component\.\{c\.Key\}\.Description'
            $ps | Should Match 'Component\.\$\(\$_\.Key\)\.Text'
            $ps | Should Match 'Component\.\$\(\$_\.Key\)\.Description'
            $cs | Should Match '"Debloat:" \+ item'
            $ps | Should Match 'Debloat:\$Item'
        }

        It "every debloat target has a Japanese translation under 'Debloat:<English text>'" {
            $ja = Get-WinEaseUiTable -Language 'ja'
            $missing = @(@($script:WinEaseDebloatStandardItems) + @($script:WinEaseDebloatExperimentalItems) | Where-Object { -not "$($ja["Debloat:$_"])".Trim() })
            ($missing -join '; ') | Should BeNullOrEmpty
        }

        It "en.json and ja.json define the same UI keys" {
            $en = Get-WinEaseUiTable -Language 'en'
            $ja = Get-WinEaseUiTable -Language 'ja'
            # ja.json holds the extra per-tweak / per-component / per-debloat translations; en falls back to the schema for those
            $isSchemaDerived = { param($k) $k -match '^(Tweak|Component)\.' -or $k -like 'Debloat:*' }
            $onlyEn = @($en.Keys | Where-Object { -not $ja.ContainsKey($_) })
            $onlyJa = @($ja.Keys | Where-Object { -not $en.ContainsKey($_) -and -not (& $isSchemaDerived $_) })
            ($onlyEn -join '; ') | Should BeNullOrEmpty
            ($onlyJa -join '; ') | Should BeNullOrEmpty
        }
    }

    # =========================================================================================
    # b. the same selections give the same meaning everywhere
    # =========================================================================================
    Context "b. preset + custom selections" {
        BeforeAll {
            $script:guiBasePresetKey = $null
            $script:GuiB = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{
                SourceDrive = $script:Fx.SourceDrive; WorkDir = $script:Fx.WorkDir; Index = $script:Fx.Index; InjectDrivers = $script:Fx.InjectDrivers
                UserName = $script:Fx.UserName; ComputerName = $script:Fx.ComputerName
                AdvancedDebloatStandard = $script:FixtureStd; AdvancedDebloatExperimental = $script:FixtureExp
                DebloatEngineSelection = @{ $script:FxEngineItem = 'Rust' }
            }
            # 'balanced' is preset number 2; the preset sets every tweak, component and the payload format
            Set-WinEaseGuiPreset -Gui $script:GuiB -PresetIndex 1
            $script:PresetCheck = @{
                Tweaks = @{}; Components = @{}
            }
            foreach ($k in $script:GuiB.TweakCheckboxes.Keys) { $script:PresetCheck.Tweaks[$k] = $script:GuiB.TweakCheckboxes[$k].Checked }
            foreach ($k in $script:GuiB.ComponentCheckboxes.Keys) { $script:PresetCheck.Components[$k] = $script:GuiB.ComponentCheckboxes[$k].Checked }
            $script:PresetCheck.Esd = $script:GuiB.RadESD.Checked
            $script:PresetCheck.Swm = $script:GuiB.RadSWM.Checked
            # custom changes on top of the preset: a few tweaks, the payload, VHDX, dry run
            $script:CustomFlips = @($script:FixtureTweaks.Keys | Select-Object -First 4)
            foreach ($k in $script:CustomFlips) { $script:GuiB.TweakCheckboxes[$k].Checked = -not $script:GuiB.TweakCheckboxes[$k].Checked }
            $script:GuiB.RadESD.Checked = $true
            $script:GuiB.VHDX.Checked = $true
            $script:GuiB.DryRun.Checked = $true
            $script:GuiB.Preset.SelectedIndex = $script:GuiB.Preset.Items.Count - 1   # Custom

            $script:ParityConfirmAnswer = $true
            $script:FormResultB = $null
            if (Complete-WinEaseGuiResult -Gui $script:GuiB) { $script:FormResultB = $script:GuiB.Result }

            # the WinUI 3 window: preset values come from the init message, then the same custom changes
            $init = Get-ParityInit -Language 'en'
            $p = @($init.Presets | Where-Object { $_.Key -eq 'balanced' })[0]
            $script:UiPreset = $p
            $tw = [ordered]@{}
            foreach ($t in @($init.Tweaks)) { $tw[$t.Key] = [bool]$p.Tweaks.PSObject.Properties[$t.Key].Value }
            foreach ($k in $script:CustomFlips) { $tw[$k] = -not $tw[$k] }
            $cm = [ordered]@{}
            foreach ($c in @($init.Components)) {
                $pv = $p.Components.PSObject.Properties[$c.Key]
                $cm[$c.Key] = if ($pv) { [bool]$pv.Value } else { [bool]$c.Default }
            }
            $script:UiWindowB = @{
                Success = $true; SourceDrive = $script:Fx.SourceDrive; WorkDir = $script:Fx.WorkDir; Index = $script:Fx.Index
                InjectDrivers = $script:Fx.InjectDrivers; UserName = $script:Fx.UserName; ComputerName = $script:Fx.ComputerName
                PresetKey = $null; BasePresetKey = 'balanced'; DryRun = $true; UseVHDX = $true; ExportESDMode = $true; SplitWIMMode = $false
                Components = $cm; TweakSettings = $tw
                AdvancedDebloatStandard = $script:FixtureStd; AdvancedDebloatExperimental = $script:FixtureExp
                DebloatEngineSelection = @{ $script:FxEngineItem = 'Rust' }; PhysicalDebloatConsent = $true
            }
            $script:UiResultB = ConvertTo-ParityWinUiResult $script:UiWindowB
        }
        AfterAll { Close-ParityGui $script:GuiB }

        It "the preset values of both windows are the same (WinForms Set-WinEaseGuiPreset vs. WinUI init Presets)" {
            $diff = @()
            $p = $script:UiPreset
            $gui = Show-WinEaseGUI -NoShow -UiLanguage en
            try {
                Set-WinEaseGuiPreset -Gui $gui -PresetIndex 1
                foreach ($k in $gui.TweakCheckboxes.Keys) {
                    if ($gui.TweakCheckboxes[$k].Checked -ne [bool]$p.Tweaks.PSObject.Properties[$k].Value) { $diff += "tweak $k" }
                }
                foreach ($k in $gui.ComponentCheckboxes.Keys) {
                    $pv = $p.Components.PSObject.Properties[$k]
                    if ($pv -and $gui.ComponentCheckboxes[$k].Checked -ne [bool]$pv.Value) { $diff += "component $k" }
                }
                $fmt = if ($gui.RadESD.Checked) { 'ESD' } elseif ($gui.RadSWM.Checked) { 'SWM' } else { 'WIM' }
                if ($fmt -ne $p.PayloadFormat) { $diff += "payload $fmt vs $($p.PayloadFormat)" }
            } finally { Close-ParityGui $gui }
            ($diff -join '; ') | Should BeNullOrEmpty
        }

        It "a preset reaches the toggles: every preset tweak is what the builder's own preset table says" {
            $balanced = $script:BuiltInPresets['balanced']
            $bad = @()
            foreach ($k in $script:PresetCheck.Tweaks.Keys) {
                $exp = if ($balanced.TweakSettings -and $balanced.TweakSettings.Contains($k)) { [bool]$balanced.TweakSettings[$k] }
                       elseif ($balanced.Contains($k)) { [bool]$balanced[$k] } else { [bool]$script:AllTweakDefs[$k].Default }
                if ($script:PresetCheck.Tweaks[$k] -ne $exp) { $bad += $k }
            }
            ($bad -join ',') | Should BeNullOrEmpty
        }

        It "the WinForms result and the WinUI JSON -> ConvertFrom-WinEaseWinUiResult hashtable agree on every key the builder reads" {
            $script:FormResultB | Should Not BeNullOrEmpty
            $skip = @('PhysicalDebloatConsent')   # asserted separately below
            $form = Get-ParityResultLines $script:FormResultB -Skip $skip
            $ui = Get-ParityResultLines $script:UiResultB -Skip $skip
            ((Compare-ParityText $form $ui) -join "`n") | Should BeNullOrEmpty
            $script:FormResultB.PresetKey | Should BeNullOrEmpty
            $script:FormResultB.BasePresetKey | Should Be 'balanced'
            $script:FormResultB.DryRun | Should Be $true
            $script:FormResultB.ExportESDMode | Should Be $true
            $script:FormResultB.UseVHDX | Should Be $true
        }

        It "both windows report the consent the same way" {
            $script:FormResultB.PhysicalDebloatConsent | Should Be $true
            $script:UiResultB.PhysicalDebloatConsent | Should Be $true
            # engines: only the non-default engine is reported, by both windows
            @($script:FormResultB.DebloatEngineSelection.Keys) -join '|' | Should Be $script:FxEngineItem
            @($script:UiResultB.DebloatEngineSelection.Keys) -join '|' | Should Be $script:FxEngineItem
        }

        It "after Apply-WinEaseGuiResult the builder variables are identical for both windows" {
            Reset-ParityBuilderState
            Apply-WinEaseGuiResult -GuiResult $script:FormResultB
            $fromForm = Get-ParitySnapshot
            Reset-ParityBuilderState
            Apply-WinEaseGuiResult -GuiResult $script:UiResultB
            $fromUi = Get-ParitySnapshot
            ((Compare-ParityText $fromForm $fromUi) -join "`n") | Should BeNullOrEmpty
            ($fromForm -contains 'selectedProfile=custom (based on balanced)') | Should Be $true
            ($fromForm -contains 'DryRun=True') | Should Be $true
            ($fromForm -contains 'isDryRunMode=True') | Should Be $true
            ($fromForm -contains 'allowPhysicalDebloat=True') | Should Be $true
            ($fromForm -contains 'exportESDMode=True') | Should Be $true
            ($fromForm -contains "engine.$($script:FxEngineItem)=Rust") | Should Be $true
        }

        It "the custom changes win over the preset in the applied builder state" {
            Reset-ParityBuilderState
            Apply-WinEaseGuiResult -GuiResult $script:UiResultB
            foreach ($k in $script:CustomFlips) {
                [bool]$script:TweakSettings[$k] | Should Be ([bool]$script:UiWindowB.TweakSettings[$k])
            }
        }
    }

    Context "b. profile load (command line path) <-> both windows" {
        BeforeAll {
            # command line path: -LoadProfile = Import-WinEaseProfile + Apply-ProfileSettings -ProfileObject
            Reset-ParityBuilderState
            $loaded = Import-WinEaseProfile -FilePath $script:FixtureProfilePath
            $null = Apply-ProfileSettings -ProfileObject $loaded
            # -SourceDrive takes the resolved form of the window's 'Q:\' (Resolve-WinEaseGuiSource)
            $script:SourceDrive = Resolve-WinEaseGuiSource -Text $script:Fx.SourceDrive; $script:WorkDir = $script:Fx.WorkDir; $script:Index = $script:Fx.Index
            $script:InjectDrivers = $script:Fx.InjectDrivers; $script:UserName = $script:Fx.UserName; $script:ComputerName = $script:Fx.ComputerName
            $script:CliSnapshot = Get-ParitySnapshot
            $script:CliInitial = Get-WinEaseGuiInitialSettings

            # both windows start from what the profile resolved to, nothing is touched, the result must say the same
            $script:guiBasePresetKey = $null
            $script:GuiProf = Show-WinEaseGUI -NoShow -UiLanguage ja -InitialSettings $script:CliInitial
            $script:GuiProf.Preset.SelectedIndex = $script:GuiProf.Preset.Items.Count - 1
            $script:ParityConfirmAnswer = $false
            [void](Complete-WinEaseGuiResult -Gui $script:GuiProf -SkipPhysicalDebloatConsent)
            $script:FormResultProf = $script:GuiProf.Result
            $script:InitProf = Get-ParityInit -InitialSettings $script:CliInitial -Language 'ja'
            $script:UiResultProf = ConvertTo-ParityWinUiResult (New-ParityWindowFromInit $script:InitProf)
        }
        AfterAll { Close-ParityGui $script:GuiProf }

        It "the profile reaches the builder variables (components, tweaks, payload format, debloat lists, engine)" {
            ($script:CliSnapshot -contains 'exportESDMode=False') | Should Be $true
            ($script:CliSnapshot -contains 'splitWIMMode=True') | Should Be $true
            ($script:CliSnapshot -contains 'useVHDX=True') | Should Be $true
            ($script:CliSnapshot -contains "engine.$($script:FxEngineItem)=Rust") | Should Be $true
            ($script:CliSnapshot -contains ('debloatStd=' + ((@($script:FixtureStd) | Sort-Object) -join '|'))) | Should Be $true
            ($script:CliSnapshot -contains ('debloatExp=' + ((@($script:FixtureExp) | Sort-Object) -join '|'))) | Should Be $true
            $bad = @()
            foreach ($k in $script:FixtureTweaks.Keys) { if ($script:CliSnapshot -notcontains "tweak.$k=$($script:FixtureTweaks[$k])") { $bad += $k } }
            ($bad -join ',') | Should BeNullOrEmpty
            foreach ($cd in $script:ComponentDefs.Values) {
                if ($cd.Type -eq 'Bool' -and $cd.Gui) {
                    ($script:CliSnapshot -contains "component.$($cd.Key)=$($script:FixtureSettings[$cd.Key])") | Should Be $true
                }
            }
        }

        It "the initial settings of the profile survive both windows unchanged (WinForms result == WinUI result)" {
            $skip = @('PresetKey', 'BasePresetKey', 'PhysicalDebloatConsent')
            $form = Get-ParityResultLines $script:FormResultProf -Skip $skip
            $ui = Get-ParityResultLines $script:UiResultProf -Skip $skip
            ((Compare-ParityText $form $ui) -join "`n") | Should BeNullOrEmpty
        }

        It "profile -> window -> Apply-WinEaseGuiResult gives the same builder state as the command line load" {
            foreach ($result in @($script:FormResultProf, $script:UiResultProf)) {
                Reset-ParityBuilderState
                # without consent the debloat lists would be cleared by the fallback dialog: grant it for this comparison
                $result.PhysicalDebloatConsent = $true
                Apply-WinEaseGuiResult -GuiResult $result
                $snap = Get-ParitySnapshot
                # the GUI sets selectedProfile / allowPhysicalDebloat itself; the other variables must match the CLI path
                $a = @($snap | Where-Object { $_ -notmatch '^(selectedProfile|allowPhysicalDebloat)=' })
                $b = @($script:CliSnapshot | Where-Object { $_ -notmatch '^(selectedProfile|allowPhysicalDebloat)=' })
                ((Compare-ParityText $a $b) -join "`n") | Should BeNullOrEmpty
            }
        }

        It "the same settings reach the command line parameters' meaning: legacy tweak aliases resolve to the keys the windows show" {
            foreach ($alias in $script:TweakKeyAliases.Keys) {
                $script:AllTweakDefs.Contains((Resolve-WinEaseTweakKey $alias)) | Should Be $true
            }
        }
    }

    # =========================================================================================
    # c. save -> load -> save, language switch, dry run, consent, validation
    # =========================================================================================
    Context "c. save -> load -> save" {
        It "exporting the applied state, loading it and exporting again loses nothing" {
            Reset-ParityBuilderState
            $loaded = Import-WinEaseProfile -FilePath $script:FixtureProfilePath
            $null = Apply-ProfileSettings -ProfileObject $loaded
            $p1 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("parity_s1_" + [guid]::NewGuid().ToString('N') + '.json')
            $p2 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("parity_s2_" + [guid]::NewGuid().ToString('N') + '.json')
            try {
                $snap1 = Get-ParitySnapshot
                $null = Export-WinEaseProfile -FilePath $p1 -Config (Get-WinEaseCurrentConfig -ProfileName 'rt')
                Reset-ParityBuilderState
                $null = Apply-ProfileSettings -ProfileObject (Import-WinEaseProfile -FilePath $p1)
                $snap2 = Get-ParitySnapshot
                ((Compare-ParityText $snap1 $snap2) -join "`n") | Should BeNullOrEmpty
                $null = Export-WinEaseProfile -FilePath $p2 -Config (Get-WinEaseCurrentConfig -ProfileName 'rt')
                $s1 = (([System.IO.File]::ReadAllText($p1) | ConvertFrom-Json).Settings | ConvertTo-Json -Depth 6)
                $s2 = (([System.IO.File]::ReadAllText($p2) | ConvertFrom-Json).Settings | ConvertTo-Json -Depth 6)
                $s2 | Should Be $s1
                # every fixture value is still in the saved file
                $saved = ([System.IO.File]::ReadAllText($p2) | ConvertFrom-Json).Settings
                $saved.PayloadFormat | Should Be 'SWM'
                (@($saved.AdvancedDebloatStandard) -join '|') | Should Be (@($script:FixtureStd) -join '|')
                (@($saved.AdvancedDebloatExperimental) -join '|') | Should Be (@($script:FixtureExp) -join '|')
                $saved.DebloatEngineSelection.PSObject.Properties[$script:FxEngineItem].Value | Should Be 'Rust'
                @($saved.TweakSettings.PSObject.Properties).Count | Should Be $script:AllTweakDefs.Count
            } finally {
                Remove-Item -LiteralPath $p1, $p2 -Force -ErrorAction SilentlyContinue
            }
        }

        It "every profile key the builder writes is a key the windows know (schema tweak or component), or an engine / payload / list key" {
            $known = @($script:AllTweakDefs.Keys) + @($script:ComponentDefs.Keys) + @('DebloatEngineSelection')
            $unknown = @($script:WinEaseProfileKeys | Where-Object { $known -notcontains $_ })
            ($unknown -join ',') | Should BeNullOrEmpty
        }
    }

    Context "c. display language switch" {
        It "WinForms: switching en -> ja -> en keeps every value (the window is rebuilt from the current state)" {
            $env:WINEASE_UI_LANGUAGE = 'en'
            $oldLocal = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = Join-Path $TestDrive 'local'
            $script:guiBasePresetKey = $null
            $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{
                SourceDrive = $script:Fx.SourceDrive; WorkDir = $script:Fx.WorkDir; Index = $script:Fx.Index; InjectDrivers = $script:Fx.InjectDrivers
                UserName = $script:Fx.UserName; ComputerName = $script:Fx.ComputerName; UseVHDX = $true; SplitWIMMode = $true
                TweakSettings = $script:FixtureTweaks
                AdvancedDebloatStandard = $script:FixtureStd; AdvancedDebloatExperimental = $script:FixtureExp
                DebloatEngineSelection = @{ $script:FxEngineItem = 'Rust' }
            }
            try {
                $gui.DryRun.Checked = $true
                $gui.Preset.SelectedIndex = $gui.Preset.Items.Count - 1
                $script:ParityConfirmAnswer = $true
                [void](Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent)
                $before = Get-ParityResultLines (@{} + $gui.Result)
                $labelEn = $gui.Tabs.TabPages[0].Text

                Switch-WinEaseGuiLanguage -Gui $gui -Language 'ja'
                $labelJa = $gui.Tabs.TabPages[0].Text
                $labelJa | Should Not Be $labelEn
                [void](Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent)
                ((Compare-ParityText $before (Get-ParityResultLines (@{} + $gui.Result))) -join "`n") | Should BeNullOrEmpty
                $gui.Result.DryRun | Should Be $true

                Switch-WinEaseGuiLanguage -Gui $gui -Language 'en'
                $gui.Tabs.TabPages[0].Text | Should Be $labelEn
                [void](Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent)
                ((Compare-ParityText $before (Get-ParityResultLines (@{} + $gui.Result))) -join "`n") | Should BeNullOrEmpty
            } finally {
                $env:LOCALAPPDATA = $oldLocal
                Set-WinEaseUiLanguage -Language 'en'
                Close-ParityGui $gui
            }
        }

        It "WinUI: the init message is the same data in en and ja (only the language differs); the value space never depends on it" {
            $en = New-WinEaseWinUiInitMessage -Language 'en' -InitialSettings @{ UserName = 'Tester' }
            $ja = New-WinEaseWinUiInitMessage -Language 'ja' -InitialSettings @{ UserName = 'Tester' }
            $en.Language | Should Be 'en'
            $ja.Language | Should Be 'ja'
            ((@($en.Tweaks) | ForEach-Object { "$($_.Key)=$($_.Default)" }) -join ',') | Should Be ((@($ja.Tweaks) | ForEach-Object { "$($_.Key)=$($_.Default)" }) -join ',')
            (@($en.DebloatStandard) -join '|') | Should Be (@($ja.DebloatStandard) -join '|')
            ($en.Initial | ConvertTo-Json -Depth 6) | Should Be ($ja.Initial | ConvertTo-Json -Depth 6)
        }

        It "WinUI: the language handler re-renders without resetting the stored selections (static check)" {
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            $m = [regex]::Match($cs, 'private void ApplyLanguage\(\)\s*\{(?<body>.*?)\n    \}\r?\n', 'Singleline')
            $m.Success | Should Be $true
            $body = $m.Groups['body'].Value
            # selections live in _tweaks / _components / _debloat*: none of them may be cleared or re-created by the language switch
            $body | Should Not Match '_(tweaks|components|debloatStd|debloatExp|debloatEngines|payload|source|userName|computerName)\s*(=|\.Clear)'
        }

        It "debloat targets keep their English value in both languages (the display text is translated only)" {
            $gui = Show-WinEaseGUI -NoShow -UiLanguage ja
            try {
                $values = @($gui.GrdStd.Rows | ForEach-Object { [string]$_.Tag })
                ($values -join "`n") | Should Be (@($script:WinEaseDebloatStandardItems) -join "`n")
            } finally { Set-WinEaseUiLanguage -Language 'en'; Close-ParityGui $gui }
        }
    }

    Context "c. Dry Run never starts a build" {
        It "a GUI result with DryRun sets both DryRun flags the builder checks" {
            Reset-ParityBuilderState
            Apply-WinEaseGuiResult -GuiResult @{ DryRun = $true }
            $script:DryRun | Should Be $true
            $script:isDryRunMode | Should Be $true
        }

        It "a GUI result without DryRun does not set them" {
            Reset-ParityBuilderState
            Apply-WinEaseGuiResult -GuiResult @{ DryRun = $false }
            $script:isDryRunMode | Should Be $false
        }

        It "WinForms and WinUI report DryRun as a boolean the same way" {
            (ConvertTo-ParityWinUiResult @{ Success = $true; DryRun = $true } -SkipValidation).DryRun | Should Be $true
            (ConvertTo-ParityWinUiResult @{ Success = $true } -SkipValidation).DryRun | Should Be $false
        }

        It "the builder exits before the build lifecycle and before every phase when isDryRunMode is set - also after the GUI" {
            $b = [System.IO.File]::ReadAllText($script:BuilderPath)
            $guiCall = $b.IndexOf('Invoke-WinEaseGuiSession')
            $exitBlock = [regex]::Match($b, 'if \(\(\$env:WINEASE_TEST_MODE -eq "1"\) -or \$isDryRunMode\) \{(?<body>.*?)\n\}', 'Singleline')
            $exitBlock.Success | Should Be $true
            $exitBlock.Groups['body'].Value | Should Match 'exit 0'
            $lifecycle = $b.IndexOf('# Main Build Lifecycle')
            $phaseRun = $b.IndexOf('Invoke-WinEasePluginHook -Phase $phaseId -Stage Before')
            $guiCall | Should BeGreaterThan 0
            $exitBlock.Index | Should BeGreaterThan $guiCall
            $exitBlock.Index | Should BeLessThan $lifecycle
            $exitBlock.Index | Should BeLessThan $phaseRun
            # the flag the GUI sets is the flag the exit block reads
            $sessionText = [System.IO.File]::ReadAllText($script:GuiSessionPath)
            $sessionText | Should Match '\$script:isDryRunMode\s*=\s*\$true'
        }

        It "the WinUI window closes on a dry run instead of opening the build progress view (static check)" {
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            $cs | Should Match 'InitData\.Bool\(result\["DryRun"\]\)'
            $cs | Should Match '\["DryRun"\] = DryRunCheck\.IsChecked == true'
        }
    }

    Context "c. physical deletion needs the consent" {
        BeforeEach {
            Reset-ParityBuilderState
            $script:ParityConsentPrompts = 0
        }

        It "a selection without consent asks, and answering No clears the lists and keeps the gate shut" {
            $script:ParityConsentAnswer = [System.Windows.Forms.DialogResult]::No
            Apply-WinEaseGuiResult -GuiResult @{ AdvancedDebloatStandard = @('a'); AdvancedDebloatExperimental = @('b'); PhysicalDebloatConsent = $false }
            $script:ParityConsentPrompts | Should Be 1
            $script:allowPhysicalDebloat | Should Be $false
            @($script:advancedDebloatStandard).Count | Should Be 0
            @($script:advancedDebloatExperimental).Count | Should Be 0
        }

        It "answering Yes opens the gate for this session only" {
            $script:ParityConsentAnswer = [System.Windows.Forms.DialogResult]::Yes
            Apply-WinEaseGuiResult -GuiResult @{ AdvancedDebloatStandard = @('a'); PhysicalDebloatConsent = $false }
            $script:allowPhysicalDebloat | Should Be $true
        }

        It "a result that carries the consent does not ask again" {
            Apply-WinEaseGuiResult -GuiResult @{ AdvancedDebloatStandard = @('a'); PhysicalDebloatConsent = $true }
            $script:ParityConsentPrompts | Should Be 0
            $script:allowPhysicalDebloat | Should Be $true
        }

        It "no selection means no consent and no prompt" {
            Apply-WinEaseGuiResult -GuiResult @{}
            $script:ParityConsentPrompts | Should Be 0
            $script:allowPhysicalDebloat | Should Be $false
        }

        It "a window result cannot open the gate through any key other than PhysicalDebloatConsent" {
            $r = ConvertTo-ParityWinUiResult @{ Success = $true; AllowPhysicalDebloat = $true; DryRun = $false } -SkipValidation
            $r.ContainsKey('AllowPhysicalDebloat') | Should Be $false
            $r.PhysicalDebloatConsent | Should Be $false
            $script:ParityConsentAnswer = [System.Windows.Forms.DialogResult]::No
            Apply-WinEaseGuiResult -GuiResult @{ AdvancedDebloatStandard = @('a'); AllowPhysicalDebloat = $true }
            $script:allowPhysicalDebloat | Should Be $false
        }

        It "WinForms: declining the consent clears the selections in the result, accepting keeps them" {
            $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = $script:Fx.SourceDrive; WorkDir = $script:Fx.WorkDir; Index = $script:Fx.Index; AdvancedDebloatStandard = $script:FixtureStd; AdvancedDebloatExperimental = $script:FixtureExp }
            try {
                $script:ParityConfirmAnswer = $false
                [void](Complete-WinEaseGuiResult -Gui $gui)
                $gui.Result.PhysicalDebloatConsent | Should Be $false
                @($gui.Result.AdvancedDebloatStandard).Count | Should Be 0
                @($gui.Result.AdvancedDebloatExperimental).Count | Should Be 0
                $script:ParityConfirmAnswer = $true
                [void](Complete-WinEaseGuiResult -Gui $gui)
                $gui.Result.PhysicalDebloatConsent | Should Be $true
                @($gui.Result.AdvancedDebloatStandard).Count | Should Be @($script:FixtureStd).Count
            } finally { Close-ParityGui $gui }
        }

        It "the builder's conflict check strips the experimental deletions and the PhysicalDebloat tweak when the gate is closed" {
            $cfg = @{ advancedDebloatStandard = @(); advancedDebloatExperimental = @($script:FixtureExp[0]); TweakSettings = @{ PhysicalDebloat = $true }; AllowPhysicalDebloat = $false; RemoveDefender = $true }
            $res = Test-WinEaseConfigConflicts -Config $cfg
            $rule = @($res.Conflicts | Where-Object { $_.Rule -eq 'PhysicalDebloatSafetyGate' })
            $rule.Count | Should Be 1
            $rule[0].Safeguard.Action | Should Be 'ClearExperimental'
            $cfg.AllowPhysicalDebloat = $true
            $res2 = Test-WinEaseConfigConflicts -Config $cfg
            @($res2.Conflicts | Where-Object { $_.Rule -eq 'PhysicalDebloatSafetyGate' }).Count | Should Be 0
        }

        It "the gate has one source: no schema tweak, component or profile key can set AllowPhysicalDebloat" {
            ($script:WinEaseProfileKeys -contains 'AllowPhysicalDebloat') | Should Be $false
            ($script:WinEaseProfileKeys -contains 'allowPhysicalDebloat') | Should Be $false
        }

        It "phase 09 refuses the Rust (physical deletion) engine unless the gate variable is true, before it looks for the binary" {
            $p = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\09-physical-debloat.ps1'))
            $p | Should Match '\$physGateAllowed = \$false'
            $p | Should Match '\$physGateAllowed = \[bool\]\$script:allowPhysicalDebloat'
            $dispatch = $p.IndexOf('$rustTargetItems = @(')
            $gate = $p.IndexOf('if (-not $physGateAllowed)', $dispatch)
            $binary = $p.IndexOf('Test-Path -LiteralPath $rustBinary', $dispatch)
            $dispatch | Should BeGreaterThan 0
            $gate | Should BeGreaterThan $dispatch
            $binary | Should BeGreaterThan $gate
            $p | Should Match 'BLOCKED: -AllowPhysicalDebloat was not specified'
        }

        It "the WinUI window sends the consent only from its own confirmation dialog (static check)" {
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            $cs | Should Match 'consent = await ConfirmAsync\(_s\.Get\("Msg\.PhysicalConsent\.Title"\)'
            $cs | Should Match 'bool consent = false;'
            $cs | Should Match '\["PhysicalDebloatConsent"\] = consent'
            # declining clears the selection
            $cs | Should Match '(?s)if \(!consent\)\s*\{\s*_debloatStd\.Clear\(\);\s*_debloatExp\.Clear\(\);'
        }
    }

    Context "c. invalid input is refused" {
        BeforeAll {
            $script:PatUser = [regex]::Match([System.IO.File]::ReadAllText($script:BuilderPath), "\[ValidatePattern\('(?<p>[^']*\\p\{L\}[^']*)'\)\]\s*\[string\]\`$UserName").Groups['p'].Value
            $script:PatComputer = [regex]::Match([System.IO.File]::ReadAllText($script:BuilderPath), "\[ValidatePattern\('(?<p>[^']*\\\*[^']*)'\)\]\s*\[string\]\`$ComputerName").Groups['p'].Value
            $script:GuiV = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = $script:Fx.SourceDrive; WorkDir = $script:Fx.WorkDir; Index = $script:Fx.Index; UserName = 'Tester'; ComputerName = '*' }
        }
        AfterAll { Close-ParityGui $script:GuiV }
        BeforeEach { $script:ParityMessages = @() }

        It "the UserName / ComputerName patterns live once in the shared input check and equal the builder's [ValidatePattern]" {
            $script:PatUser | Should Not BeNullOrEmpty
            $script:PatComputer | Should Not BeNullOrEmpty
            $lib = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseInputValidation.ps1'))
            $lib.Contains("'" + $script:PatUser + "'") | Should Be $true
            $lib.Contains("'" + $script:PatComputer + "'") | Should Be $true
            # The windows no longer carry their own copy: they ask the shared check through the validate request.
            $ps = [System.IO.File]::ReadAllText($script:GuiPath)
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
            $ps.Contains("'" + $script:PatUser + "'") | Should Be $false
            $ps.Contains("'" + $script:PatComputer + "'") | Should Be $false
            $cs.Contains('@"' + $script:PatUser + '"') | Should Be $false
            $cs.Contains('@"' + $script:PatComputer + '"') | Should Be $false
        }

        It "the patterns accept ordinary names and refuse characters that would break autounattend.xml" {
            foreach ($ok in 'User', 'Tester 1', 'a.b-c_d', 'taro') { $ok -match $script:PatUser | Should Be $true }
            foreach ($bad in '', ' x', 'a<b', 'a"b', "a'b", 'a;b', 'a&b', ('x' * 21), 'a`b', 'a$b') { $bad -match $script:PatUser | Should Be $false }
            foreach ($ok in '*', 'PC', 'WIN-PC-01', ('A' * 15)) { $ok -match $script:PatComputer | Should Be $true }
            foreach ($bad in '', '-pc', 'a b', 'a_b', 'a;b', "a'b", ('A' * 16), 'a<b', 'pc.local') { $bad -match $script:PatComputer | Should Be $false }
        }

        It "WinForms refuses an invalid user name and computer name and returns no result" {
            $gui = $script:GuiV
            $gui.UserName.Text = 'bad"name'
            $gui.ComputerName.Text = '*'
            $gui.Result.Success = $false
            (Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent) | Should Be $false
            $script:ParityMessages.Count | Should Be 1
            $gui.Result.Success | Should Be $false
            $gui.UserName.Text = 'Tester'
            $gui.ComputerName.Text = 'bad_name;calc'
            (Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent) | Should Be $false
            $script:ParityMessages.Count | Should Be 2
            $gui.ComputerName.Text = '*'
            (Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent) | Should Be $true
        }

        It "WinForms refuses an empty source" {
            $gui = $script:GuiV
            $gui.UserName.Text = 'Tester'
            $old = $gui.Source.Text
            $gui.Source.Text = '   '
            try {
                (Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent) | Should Be $false
                $script:ParityMessages.Count | Should Be 1
            } finally { $gui.Source.Text = $old }
        }

        It "Resolve-WinEaseGuiSource turns a drive spec into a drive letter, keeps an ISO path or UNC path as typed and never throws on a missing drive" {
            Resolve-WinEaseGuiSource -Text 'Q:\' | Should Be 'Q:'
            Resolve-WinEaseGuiSource -Text 'q:\some\folder' | Should Be 'q:'
            Resolve-WinEaseGuiSource -Text '\\server\share\win11.iso' | Should Be '\\server\share\win11.iso'
            { Resolve-WinEaseGuiSource -Text 'Z:\no\such\thing.iso' } | Should Not Throw
            $iso = Join-Path $TestDrive 'fake.iso'
            Set-Content -LiteralPath $iso -Value 'x'
            Resolve-WinEaseGuiSource -Text $iso | Should Be $iso
        }

        It "the builder rejects an invalid UserName / ComputerName on the command line (parameter validation)" {
            $b = [System.IO.File]::ReadAllText($script:BuilderPath)
            $b | Should Match "ValidatePattern\('\^\(\\\*\|\[A-Za-z0-9\]"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
            foreach ($pn in 'UserName', 'ComputerName') {
                $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $pn }
                @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidatePattern' }).Count | Should Be 1
            }
        }

        It "the session bridge refuses an invalid user name / computer name coming from the WinUI 3 window" {
            # The window is not the trust boundary: ConvertFrom-WinEaseWinUiResult runs the same shared input check and
            # returns Success = $false with the reason, so a message that does not come from the shipped window (or a
            # window bug) never reaches $script:UserName / $script:ComputerName.
            $iso = Join-Path $TestDrive 'parity-bridge.iso'
            Set-Content -LiteralPath $iso -Value 'x'
            $r = ConvertTo-ParityWinUiResult @{ Success = $true; SourceDrive = $iso; WorkDir = $script:Fx.WorkDir; Index = '2'; UserName = 'a"b'; ComputerName = 'x;calc' }
            $r.Success | Should Be $false
            $r.Reason | Should Match 'UserName'
            $r.Reason | Should Match 'ComputerName'
            $ok = ConvertTo-ParityWinUiResult @{ Success = $true; SourceDrive = $iso; WorkDir = $script:Fx.WorkDir; Index = '2'; UserName = 'Tester'; ComputerName = 'PC-1' }
            $ok.Success | Should Be $true
        }
    }

    # =========================================================================================
    # d. nothing is left unwired in MainWindow.xaml
    # =========================================================================================
    Context "d. WinUI controls are wired" {
        BeforeAll {
            $guiDir = Join-Path $script:RepoRoot 'gui\winui\WinEaseGui'
            $script:XamlPath = Join-Path $guiDir 'MainWindow.xaml'
            $script:CsText = [System.IO.File]::ReadAllText((Join-Path $guiDir 'MainWindow.xaml.cs'))
            [xml]$script:Xaml = [System.IO.File]::ReadAllText($script:XamlPath)
            $script:XNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
            # Controls that deliberately have no event handler. Each entry needs the reason and a proof that the code reads it.
            $script:PassiveControls = @{
                'DryRunCheck' = @{ Reason = 'a plain value the result reads when Start is pressed'; Proof = 'DryRunCheck\.IsChecked' }
            }
            $script:InteractiveTypes = @('Button', 'ToggleSwitch', 'CheckBox', 'RadioButton', 'ToggleButton', 'ComboBox', 'HyperlinkButton', 'MenuFlyoutItem', 'AppBarButton')
            $script:EventAttrs = @('Click', 'Toggled', 'Checked', 'Unchecked', 'SelectionChanged', 'Tapped', 'TextChanged', 'ValueChanged')
        }

        It "MainWindow.xaml is well formed and declares the expected interactive controls" {
            $names = @($script:Xaml.SelectNodes('//*') | Where-Object { $script:InteractiveTypes -contains $_.LocalName } | ForEach-Object { $_.GetAttribute('Name', $script:XNs) })
            foreach ($n in 'StartButton', 'CancelButton', 'PresetDiffButton', 'DependenciesButton', 'DryRunCheck', 'LanguageCombo') { $names -contains $n | Should Be $true }
        }

        It "every Button / ToggleSwitch / CheckBox / ComboBox in the XAML has an existing handler or is a documented passive control" {
            $problems = @()
            foreach ($node in @($script:Xaml.SelectNodes('//*') | Where-Object { $script:InteractiveTypes -contains $_.LocalName })) {
                $name = $node.GetAttribute('Name', $script:XNs)
                $handlers = @($script:EventAttrs | Where-Object { $node.HasAttribute($_) } | ForEach-Object { $node.GetAttribute($_) })
                if ($handlers.Count -gt 0) {
                    foreach ($h in $handlers) {
                        if ($script:CsText -notmatch ('void\s+' + [regex]::Escape($h) + '\s*\(')) { $problems += "$($node.LocalName) '$name': handler '$h' not found in MainWindow.xaml.cs" }
                    }
                } elseif ($script:PassiveControls.ContainsKey($name)) {
                    if ($script:CsText -notmatch $script:PassiveControls[$name].Proof) { $problems += "$($node.LocalName) '$name': passive but never read" }
                } else {
                    $problems += "$($node.LocalName) '$name': no handler and not in the passive allow-list"
                }
            }
            ($problems -join "`n") | Should BeNullOrEmpty
        }

        It "every event handler named anywhere in the XAML exists in the code-behind" {
            $problems = @()
            foreach ($node in @($script:Xaml.SelectNodes('//*'))) {
                foreach ($attr in @($node.Attributes)) {
                    if ($script:EventAttrs -notcontains $attr.LocalName -and $attr.LocalName -ne 'Loaded' -and $attr.LocalName -ne 'Closed') { continue }
                    if ($attr.Value -notmatch '^[A-Za-z_]\w*$') { continue }
                    if ($script:CsText -notmatch ('void\s+' + [regex]::Escape($attr.Value) + '\s*\(')) { $problems += "$($node.LocalName).$($attr.LocalName)=$($attr.Value)" }
                }
            }
            ($problems -join "`n") | Should BeNullOrEmpty
        }

        It "every named XAML control is used by the code-behind (nothing left behind)" {
            $unused = @()
            foreach ($node in @($script:Xaml.SelectNodes('//*[@*[local-name()="Name"]]'))) {
                $name = $node.GetAttribute('Name', $script:XNs)
                if (-not $name) { continue }
                # pure layout containers (RootGrid, ...) are named for the designer only
                if (@('Grid', 'StackPanel', 'Border', 'ScrollViewer') -contains $node.LocalName) { continue }
                if ($script:CsText -notmatch ('\b' + [regex]::Escape($name) + '\b')) { $unused += "$($node.LocalName) $name" }
            }
            ($unused -join '; ') | Should BeNullOrEmpty
        }

        It "every Button / ToggleSwitch / CheckBox / RadioButton the code-behind creates gets an event subscription" {
            $lines = $script:CsText -split "`r?`n"
            $problems = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $m = [regex]::Match($lines[$i], '\b(?:var|Button|ToggleSwitch|CheckBox|RadioButton)\s+(?<v>\w+)\s*=\s*new\s+(?<t>Button|ToggleSwitch|CheckBox|RadioButton)\b')
                if (-not $m.Success) { continue }
                $v = $m.Groups['v'].Value
                $window = ($lines[$i..([math]::Min($i + 14, $lines.Count - 1))]) -join "`n"
                if ($window -notmatch ('\b' + [regex]::Escape($v) + '\.(Click|Toggled|Checked|Unchecked)\s*\+=')) {
                    $problems += "line $($i + 1): $($m.Groups['t'].Value) '$v' has no event subscription within 14 lines"
                }
            }
            ($problems -join "`n") | Should BeNullOrEmpty
        }
    }
}
