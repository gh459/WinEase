# Config.Tests.ps1 - schema, presets, dependencies and user extensions
# Run with:  Invoke-Pester -Path .\tests\Config.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase builder - profile presets" {
    BeforeAll {
        # Dot-source only the preset definition by extracting it via AST is overkill; instead
        # run -TestSelf which validates presets internally and capture exit code.
    }
    It "built-in presets validate via -TestSelf" {
        $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:BuilderPath`" -TestSelf"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $p.ExitCode | Should Be 0
    }
}

Describe "WinEase builder - Apply-WinEaseProfileComponents" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $builderText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "WinEasebuilder.ps1"), [System.Text.Encoding]::UTF8)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
        $fnGetVal = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-WinEaseProfileValue" }, $true).Extent.Text
        $fnApplyComp = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Apply-WinEaseProfileComponents" }, $true).Extent.Text
        . ([scriptblock]::Create($fnGetVal))
        . ([scriptblock]::Create($fnApplyComp))
    }

    BeforeEach {
        $script:ComponentDefs = [ordered]@{
            'RemoveStore'   = @{ Key = 'RemoveStore'; Type = 'Bool'; Default = $false; Variable = 'removeStore' }
            'Edition'       = @{ Key = 'Edition'; Type = 'String'; Default = 'Home'; Variable = 'edition' }
            'SourceDrive'   = @{ Key = 'SourceDrive'; Type = 'Special'; Default = 'C:'; Variable = 'sourceDrive' }
            'NoDefaultComp' = @{ Key = 'NoDefaultComp'; Type = 'Bool'; Variable = 'noDefault' }
        }
        $script:ConfigOverrides = [ordered]@{}
        $script:removeStore = $null
        $script:edition = $null
        $script:sourceDrive = 'UnchangedDrive'
        $script:noDefault = 'UnchangedNoDefault'
    }

    It "applies component defaults and preset overrides from hashtable preset when SourceIsProfile is false" {
        $preset = @{
            'RemoveStore' = $true
            'Edition'     = 'Pro'
        }
        Apply-WinEaseProfileComponents -TargetPreset $preset -SourceIsProfile $false
        $script:removeStore | Should Be $true
        $script:edition | Should Be 'Pro'
    }

    It "applies components from PSCustomObject profile when SourceIsProfile is true" {
        $profile = [PSCustomObject]@{
            'RemoveStore' = $true
            'Edition'     = 'Enterprise'
        }
        Apply-WinEaseProfileComponents -TargetPreset $profile -SourceIsProfile $true
        $script:removeStore | Should Be $true
        $script:edition | Should Be 'Enterprise'
    }

    It "skips components with Special type or missing Default key" {
        $preset = @{
            'SourceDrive'   = 'Z:'
            'NoDefaultComp' = $true
        }
        Apply-WinEaseProfileComponents -TargetPreset $preset -SourceIsProfile $false
        $script:sourceDrive | Should Be 'UnchangedDrive'
        $script:noDefault | Should Be 'UnchangedNoDefault'
    }

    It "ensures explicit ConfigOverrides take precedence over preset and profile values" {
        $preset = @{
            'RemoveStore' = $true
            'Edition'     = 'Pro'
        }
        $script:ConfigOverrides = @{
            'RemoveStore' = $false
        }
        Apply-WinEaseProfileComponents -TargetPreset $preset -SourceIsProfile $false
        $script:removeStore | Should Be $false
        $script:edition | Should Be 'Pro'
    }

    It "falls back to base defaults when preset is null or contains null raw value" {
        $preset = @{
            'RemoveStore' = $null
            'Edition'     = 'Education'
        }
        Apply-WinEaseProfileComponents -TargetPreset $preset -SourceIsProfile $false
        $script:removeStore | Should Be $false
        $script:edition | Should Be 'Education'

        Apply-WinEaseProfileComponents -TargetPreset $null -SourceIsProfile $false
        $script:removeStore | Should Be $false
        $script:edition | Should Be 'Home'
    }

    It "correctly casts string and boolean type values" {
        $preset = @{
            'RemoveStore' = 'true'
            'Edition'     = 'Workstation'
        }
        Apply-WinEaseProfileComponents -TargetPreset $preset -SourceIsProfile $false
        $script:removeStore | Should Be $true
        ($script:removeStore -is [bool]) | Should Be $true
        $script:edition | Should Be 'Workstation'
        ($script:edition -is [string]) | Should Be $true
    }
}

Describe "WinEase helpers - configuration conflict resolution (Test-WinEaseConfigConflicts)" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "detects the Store and Windows Update dependency conflict without changing the settings" {
        $cfg = [PSCustomObject]@{
            KeepStore = $true
            RemoveStore = $false
            DisableWindowsUpdate = $true
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        # the check is a pure validation: it reports, it never rewrites (AUD-14)
        $res.ResolvedConfig.DisableWindowsUpdate | Should Be $true
    }

    It "enforces safety gate on physical debloat when -AllowPhysicalDebloat is false" {
        $cfg = [PSCustomObject]@{
            AllowPhysicalDebloat = $false
            advancedDebloatExperimental = @("Physical deletion candidate")
            TweakSettings = @{ PhysicalDebloat = $true }
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        # the check reports, it never rewrites (AUD-14); the builder applies the safeguard
        $res.ResolvedConfig.TweakSettings.PhysicalDebloat | Should Be $true
        $res.ResolvedConfig.advancedDebloatExperimental.Count | Should Be 1
        $gate = @($res.Conflicts | Where-Object { $_.Rule -eq 'PhysicalDebloatSafetyGate' })
        $gate.Count | Should Be 1
        $gate[0].Safeguard.Action | Should Be 'ClearExperimental'
    }

    It "detects the Defender conflict in the experimental debloat list" {
        $cfg = [PSCustomObject]@{
            RemoveDefender = $false
            AdvancedDebloatStandard = @()
            AdvancedDebloatExperimental = @('Physical: Defender (complete removal) [~50MB]')
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $rule = @($res.Conflicts | Where-Object { $_.Rule -eq 'Defender' })
        $rule.Count | Should Be 1
        $rule[0].Safeguard.Action | Should Be 'RemoveItems'
        # "Should Contain" of Pester 3.4 checks the content of a file, so the collection
        # is checked with -contains here.
        (@($rule[0].Safeguard.Items) -contains 'Physical: Defender (complete removal) [~50MB]') | Should Be $true
    }

    It "detects the Defender conflict in the standard debloat list too" {
        # The target reaches the standard list with an older profile (the "Physical: ..."
        # entries used to be merged into that list). It disables the Defender services in
        # phase 10 exactly like the one in the experimental list, so the rule has to look
        # at both lists: only the experimental one left the Defender removable while the
        # "RemoveDefender" setting was off.
        $cfg = [PSCustomObject]@{
            RemoveDefender = $false
            AdvancedDebloatStandard = @('Physical: Defender (complete removal) [~50MB]')
            AdvancedDebloatExperimental = @()
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $rule = @($res.Conflicts | Where-Object { $_.Rule -eq 'Defender' })
        $rule.Count | Should Be 1
        $rule[0].Safeguard.Action | Should Be 'RemoveItems'
        (@($rule[0].Safeguard.Items) -contains 'Physical: Defender (complete removal) [~50MB]') | Should Be $true
    }

    It "reports no Defender conflict when the Defender is removed on purpose" {
        $cfg = [PSCustomObject]@{
            RemoveDefender = $true
            AdvancedDebloatStandard = @('Physical: Defender (complete removal) [~50MB]')
            AdvancedDebloatExperimental = @('Physical: Defender (complete removal) [~50MB]')
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        @($res.Conflicts | Where-Object { $_.Rule -eq 'Defender' }).Count | Should Be 0
    }
}

Describe "WinEase helpers - Resolve-WinEaseConfigForDiff" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "resolves configuration from a valid JSON file" {
        $tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_config_valid_$([System.Guid]::NewGuid().ToString('N')).json"
        try {
            '{"ComponentA": true, "TweakSettings": {"DisableUAC": true}}' | Set-Content -LiteralPath $tmp -Encoding UTF8
            $resolved = Resolve-WinEaseConfigForDiff -InputConfig $tmp -NameHint "HintName"
            $resolved.Data | Should Not Be $null
            $resolved.Data.ComponentA | Should Be $true
            $resolved.Name | Should Match '^test_config_valid_'
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    It "handles malformed JSON file gracefully by returning empty data and name hint" {
        $tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_config_bad_$([System.Guid]::NewGuid().ToString('N')).json"
        try {
            '{ invalid json content ...' | Set-Content -LiteralPath $tmp -Encoding UTF8
            $resolved = Resolve-WinEaseConfigForDiff -InputConfig $tmp -NameHint "BadJsonHint"
            $resolved.Data.Count | Should Be 0
            $resolved.Name | Should Be "BadJsonHint"
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    It "resolves a built-in preset when string matches script:BuiltInPresets" {
        $script:BuiltInPresets = @{ "gaming_test" = @{ "DisableWU" = $true } }
        try {
            $resolved = Resolve-WinEaseConfigForDiff -InputConfig "gaming_test" -NameHint "FallbackHint"
            $resolved.Data.DisableWU | Should Be $true
            $resolved.Name | Should Be "gaming_test"
        } finally {
            $script:BuiltInPresets = $null
        }
    }

    It "handles non-existent preset or string path by returning empty data and string as name" {
        $resolved = Resolve-WinEaseConfigForDiff -InputConfig "NonExistentPresetName" -NameHint "UnusedHint"
        $resolved.Data.Count | Should Be 0
        $resolved.Name | Should Be "NonExistentPresetName"
    }

    It "resolves configuration from a hashtable or IDictionary" {
        $dict = @{ "TweakSettings" = @{ "DisableDefender" = $true } }
        $resolved = Resolve-WinEaseConfigForDiff -InputConfig $dict -NameHint "MyHashtable"
        $resolved.Data.TweakSettings.DisableDefender | Should Be $true
        $resolved.Name | Should Be "MyHashtable"
    }

    It "resolves configuration from a PSCustomObject" {
        $obj = [PSCustomObject]@{ OptionX = $true }
        $resolved = Resolve-WinEaseConfigForDiff -InputConfig $obj -NameHint "MyObject"
        $resolved.Data.OptionX | Should Be $true
        $resolved.Name | Should Be "MyObject"
    }

    It "falls back to default name Config when NameHint is not supplied for object or null input" {
        $dict = @{ "OptionY" = $false }
        $resolved = Resolve-WinEaseConfigForDiff -InputConfig $dict
        $resolved.Name | Should Be "Config"

        $nullResolved = Resolve-WinEaseConfigForDiff -InputConfig $null
        $nullResolved.Name | Should Be "Config"
        $nullResolved.Data.Count | Should Be 0
    }
}

Describe "WinEase helpers - Format-WinEaseConfigDiff" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "formats diff result with zero differences correctly" {
        $diffMock = [PSCustomObject]@{
            ReferenceName     = 'BasePreset'
            DifferenceName    = 'UserPreset'
            ComponentDiffs    = @()
            TweakGroupDiffs   = @()
            TweakSettingDiffs = @()
            TotalDiffCount    = 0
        }

        $formatted = Format-WinEaseConfigDiff -DiffResult $diffMock
        $formatted | Should Match "Config diff: BasePreset -> UserPreset"
        $formatted | Should Match "Total differences: 0"
        $formatted | Should Not Match "\[Components\]"
        $formatted | Should Not Match "\[Tweak Groups\]"
        $formatted | Should Not Match "\[Tweak Settings\]"
    }

    It "formats diff result containing ComponentDiffs, TweakGroupDiffs, and TweakSettingDiffs" {
        $diffMock = [PSCustomObject]@{
            ReferenceName     = 'PresetA'
            DifferenceName    = 'PresetB'
            ComponentDiffs    = @(
                [PSCustomObject]@{ Key = 'RemoveStore'; ReferenceValue = $false; DifferenceValue = $true }
            )
            TweakGroupDiffs   = @(
                [PSCustomObject]@{ Key = 'Telemetry'; ReferenceValue = 'Default'; DifferenceValue = 'Disabled' }
            )
            TweakSettingDiffs = @(
                [PSCustomObject]@{ Key = 'DisableUAC'; ReferenceValue = $false; DifferenceValue = $true }
            )
            TotalDiffCount    = 3
        }

        $formatted = Format-WinEaseConfigDiff -DiffResult $diffMock
        $formatted | Should Match "Config diff: PresetA -> PresetB"
        $formatted | Should Match "Total differences: 3"
        $formatted | Should Match "\[Components\]"
        $formatted | Should Match "RemoveStore: False -> True"
        $formatted | Should Match "\[Tweak Groups\]"
        $formatted | Should Match "Telemetry: Default -> Disabled"
        $formatted | Should Match "\[Tweak Settings\]"
        $formatted | Should Match "DisableUAC: False -> True"
    }

    It "formats output generated by Compare-WinEaseConfig" {
        $refConfig = @{
            RemoveDefender = $false
            TweakSettings  = @{ DisableUAC = $false }
        }
        $diffConfig = @{
            RemoveDefender = $true
            TweakSettings  = @{ DisableUAC = $true }
        }

        $diffResult = Compare-WinEaseConfig -ReferenceConfig $refConfig -DifferenceConfig $diffConfig
        $formatted = Format-WinEaseConfigDiff -DiffResult $diffResult

        $formatted | Should Match "Config diff: Reference -> Difference"
        $formatted | Should Match "Total differences:"
        $formatted | Should Match "\[Components\]"
        $formatted | Should Match "RemoveDefender: False -> True"
        $formatted | Should Match "\[Tweak Settings\]"
        $formatted | Should Match "DisableUAC: False -> True"
    }
}

Describe "WinEase settings - config\schema.psd1 is the single source of truth" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
    $guiAst = [System.Management.Automation.Language.Parser]::ParseInput($guiText, [ref]$null, [ref]$null)
    $settingsDef =Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $tweakKeys = @($settingsDef.Tweaks | ForEach-Object { $_.Key })
    $componentKeys = @($settingsDef.Components | ForEach-Object { $_.Key })
    $allKeys = $tweakKeys + $componentKeys
    $switchNames = @($builderAst.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath })

    It "keys are unique within Tweaks and within Components" {
        @($tweakKeys | Group-Object | Where-Object Count -gt 1).Count | Should Be 0
        @($componentKeys | Group-Object | Where-Object Count -gt 1).Count | Should Be 0
    }

    It "every tweak has a valid category, boolean default and description" {
        foreach ($td in $settingsDef.Tweaks) {
            @('Security', 'Privacy', 'Performance', 'UI') -contains $td.Category | Should Be $true
            $td.Default -is [bool] | Should Be $true
            [string]::IsNullOrWhiteSpace($td.Description) | Should Be $false
        }
    }

    It "every non-special component names its script variable and type" {
        foreach ($cd in $settingsDef.Components) {
            @('Bool', 'String', 'Special') -contains $cd.Type | Should Be $true
            if ($cd.Type -ne 'Special') { [string]::IsNullOrWhiteSpace($cd.Variable) | Should Be $false }
            if ($cd.Gui) { $cd.Type | Should Be 'Bool' }
        }
    }

    It "aliases never shadow a real key" {
        foreach ($td in $settingsDef.Tweaks) {
            foreach ($a in @($td.Aliases)) { if ($a) { $tweakKeys -contains $a | Should Be $false } }
        }
    }

    It "CliSwitch matches a [switch] parameter of the builder, and every setting-named switch is marked" {
        foreach ($d in @($settingsDef.Tweaks) + @($settingsDef.Components)) {
            if ($d.CliSwitch) { $switchNames -contains $d.Key | Should Be $true }
        }
        foreach ($td in $settingsDef.Tweaks) {
            if ($switchNames -contains $td.Key) { [bool]$td.CliSwitch | Should Be $true }
        }
    }

    It "every GUI checkbox key (New-WinEaseToggleCheckBox) exists in the definition file" {
        # The GUI builds its tweak tabs from AllTweakDefs and the Services tab from $svcDefs; both
        # come from the definition file, so no literal setting key may be passed as -Key.
        $calls = [regex]::Matches($guiText, "New-WinEaseToggleCheckBox -Parent \S+ -Key (\S+) ")
        $calls.Count | Should BeGreaterThan 0
        foreach ($m in $calls) {
            $keyArg = $m.Groups[1].Value
            if ($keyArg -match '^["'']([^"'']+)["'']$') { $allKeys -contains $Matches[1] | Should Be $true }
            else { @('$tk', '$sd.Key') -contains $keyArg | Should Be $true }
        }
    }

    It "derived tables are built from the definition file, not hand-written" {
        foreach ($name in 'AllTweakDefs', 'TweakKeyAliases', 'TweakVariableMap', 'WinEaseProfileKeys') {
            $assigns = @($builderAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$script:$name"
            }, $true))
            $assigns.Count | Should Be 1
            # Only an empty initializer or a derivation from the loaded definitions is allowed
            $assigns[0].Right.Extent.Text | Should Match '^(\[ordered\]@\{\}|@\(\$script:ComponentDefs\.Keys\).*)$'
        }
        $svc = $guiAst.Find({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$svcDefs'
        }, $true)
        $svc.Right.Extent.Text | Should Match 'ComponentDefs'
    }

    It "every CliBindings switch name is a builder parameter or alias" {
        $paramNames = @(foreach ($p in $builderAst.ParamBlock.Parameters) {
            $p.Name.VariablePath.UserPath
            foreach ($a in $p.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }) { $a.PositionalArguments | ForEach-Object { $_.Value } }
        })
        @($settingsDef.CliBindings).Count | Should BeGreaterThan 0
        foreach ($cb in $settingsDef.CliBindings) {
            foreach ($grp in $cb.Switches) {
                foreach ($n in $grp.Names) { "$($cb.Tag):$n" | Should Be "$($cb.Tag):$(@($paramNames | Where-Object { $_ -eq $n })[0])" }
            }
        }
    }

    It "built-in preset and phase-read setting keys all exist in the definition file" {
        $presets = $builderAst.Find({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:BuiltInPresets'
        }, $true)
        $presetData = . ([scriptblock]::Create($presets.Right.Extent.Text))
        $meta = @('ProfileName', 'Description')
        foreach ($pn in $presetData.Keys) {
            foreach ($k in $presetData[$pn].Keys) {
                if ($meta -contains $k) { continue }
                ($allKeys -contains $k) | Should Be $true
            }
        }
        $phaseText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "phases") -Filter "*.ps1" | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        # A key missing from the definition file is an internal tweak (no GUI/profile entry yet);
        # it must at least carry its own explicit default so a typo cannot silently disable it.
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'(\s+\`$(true|false))?")) {
            if ($tweakKeys -notcontains $m.Groups[1].Value) { $m.Groups[2].Success | Should Be $true }
        }
    }

    It "profiles\*.json only use known setting keys" {
        $known = $allKeys + @('ProfileName', 'Description', 'Version', 'Timestamp', 'Architecture')
        $aliasNames = @($settingsDef.Tweaks | ForEach-Object { @($_.Aliases) } | Where-Object { $_ })
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "profiles") -Filter "*.json") {
            $data = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            $settings = if ($data.Settings) { $data.Settings } else { $data }
            foreach ($prop in $settings.PSObject.Properties) { ($known -contains $prop.Name) | Should Be $true }
            if ($settings.TweakSettings) {
                foreach ($prop in $settings.TweakSettings.PSObject.Properties) {
                    (($tweakKeys + $aliasNames) -contains $prop.Name) | Should Be $true
                }
            }
        }
    }
}

# --- Dependency / feature-impact checker tests ---
if (-not (Get-Command -Name Test-WinEaseDependencies -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "Import-WinEaseDependencyCatalog" {
    BeforeEach {
        $script:SavedCat = $script:WinEaseDependencyCatalog
        $script:SavedCatPath = $script:WinEaseDependencyCatalogPath
    }
    AfterEach {
        $script:WinEaseDependencyCatalog = $script:SavedCat
        $script:WinEaseDependencyCatalogPath = $script:SavedCatPath
    }

    It "imports default dependency catalog when Path is null, empty, or whitespace" {
        $catalog = Import-WinEaseDependencyCatalog
        $catalog | Should Not Be $null
        $catalog.Components | Should Not Be $null
        $catalog.Tweaks | Should Not Be $null
        $script:WinEaseDependencyCatalog | Should Be $catalog
        $script:WinEaseDependencyCatalogPath | Should Match 'config\\dependencies\.psd1$'

        $catalog2 = Import-WinEaseDependencyCatalog -Path "   "
        $catalog2 | Should Not Be $null
        $script:WinEaseDependencyCatalogPath | Should Match 'config\\dependencies\.psd1$'
    }

    It "imports a custom dependency catalog file from specified path" {
        $tempCatalogFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("test_catalog_" + [guid]::NewGuid().ToString('N') + ".psd1")
        try {
            '@{ Version = "9.9"; Components = @{ CustomComp = @{ Summary = "Test" } } }' | Set-Content -LiteralPath $tempCatalogFile -Encoding UTF8
            $catalog = Import-WinEaseDependencyCatalog -Path $tempCatalogFile
            $catalog | Should Not Be $null
            $catalog.Version | Should Be "9.9"
            $catalog.Components.CustomComp.Summary | Should Be "Test"
            $script:WinEaseDependencyCatalog | Should Be $catalog
            $script:WinEaseDependencyCatalogPath | Should Be $tempCatalogFile
        } finally {
            if (Test-Path -LiteralPath $tempCatalogFile) {
                Remove-Item -LiteralPath $tempCatalogFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "throws when specified path does not exist" {
        $nonExistentPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("non_existent_" + [guid]::NewGuid().ToString('N') + ".psd1")
        { Import-WinEaseDependencyCatalog -Path $nonExistentPath } | Should Throw "Dependency catalog not found:"
    }
}

Describe "WinEase dependency checker" {
    $depsPath = Join-Path -Path $script:RepoRoot -ChildPath "config\dependencies.psd1"
    $tweaksPath = Join-Path -Path $script:RepoRoot -ChildPath "config\schema.psd1"

    It "dependency catalog exists" {
        Test-Path -LiteralPath $depsPath | Should Be $true
    }

    It "covers every tweak key from config/schema.psd1" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $defs = Import-PowerShellDataFile -Path $tweaksPath
        foreach ($t in $defs.Tweaks) {
            $deps.Tweaks.ContainsKey($t.Key) | Should Be $true
        }
    }

    It "covers every component key from config/schema.psd1" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $defs = Import-PowerShellDataFile -Path $tweaksPath
        foreach ($c in $defs.Components) {
            $deps.Components.ContainsKey($c.Key) | Should Be $true
        }
    }

    It "covers every Advanced Debloat item from the GUI" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $guiLines = [System.IO.File]::ReadAllLines($script:GuiPath)
        $items = @()
        $i = 0
        while ($i -lt $guiLines.Count) {
            if ($guiLines[$i] -match '\$script:WinEaseDebloat(Standard|Experimental)Items\s*=\s*@\(') {
                $i++
                while ($i -lt $guiLines.Count -and $guiLines[$i].Trim() -ne ')') {
                    $l = $guiLines[$i].Trim().TrimEnd(',')
                    if ($l -match '"([^"]*)"') { $items += $matches[1] }
                    $i++
                }
            }
            $i++
        }
        $items = $items | Select-Object -Unique
        $items.Count | Should BeGreaterThan 0
        foreach ($it in $items) {
            $deps.AdvancedDebloat.ContainsKey($it) | Should Be $true
        }
    }

    It "detects a conflict for WSLSupport + NoHypervisor" {
        $cfg = @{ WSLSupport = $true; NoHypervisor = $true; TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Conflicts.Count | Should BeGreaterThan 0
    }

    It "WSLSupport wins over NoHypervisor: phase 11 never writes no-hypervisor.flag when WSL2 is enabled" {
        $p11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'))
        $m = [regex]::Match($p11, '(?s)if \(\$noHypervisor -or \(Test-TweakEnabled ''NoHypervisor'' \$false\)\) \{(.*?)\n    \}')
        $m.Success | Should Be $true
        $m.Groups[1].Value | Should Match 'if \(\$wslSupport\)'
        # the flag write must sit in the else branch, i.e. after the wslSupport check
        $body = $m.Groups[1].Value
        $body.IndexOf('no-hypervisor.flag') | Should BeGreaterThan $body.IndexOf('if ($wslSupport)')
    }

    It "returns impacts for RemoveStore" {
        $cfg = @{ RemoveStore = $true; TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "returns impacts for 'Remove Print Spooler'" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Print Spooler (service + binary) [20-30MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "marks 'Provisioning packages' as Unknown" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Provisioning packages [5-10MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "treats unregistered advanced debloat items as Unknown (fail-safe)" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Totally Unknown Item XYZ'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "returns no issues for a safe/empty configuration" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.HasIssues | Should Be $false
    }
}

Describe "Format-WinEaseDependencyReport" {
    BeforeAll {
        if (-not (Get-Command -Name Format-WinEaseDependencyReport -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
        }
    }

    It "returns empty string when result has no conflicts, unknowns, or impacts" {
        $result = @{ Conflicts = @(); Unknowns = @(); Impacts = @() }
        $report = Format-WinEaseDependencyReport -Result $result
        $report | Should Be ""
    }

    It "formats dependency conflicts with and without ConflictingWith property" {
        $result = @{
            Conflicts = @(
                @{ Category = 'Component'; Source = 'WSLSupport'; Summary = 'WSL2 requires hypervisor'; ConflictingWith = 'NoHypervisor' },
                @{ Category = 'Tweak'; Source = 'TweakA'; Summary = 'Direct conflict' }
            )
        }
        $report = Format-WinEaseDependencyReport -Result $result
        $report | Should Match '\[DEPENDENCY CONFLICT\]'
        $report | Should Match '  - \[Component\] WSLSupport: WSL2 requires hypervisor \(conflicts with: NoHypervisor\)'
        $report | Should Match '  - \[Tweak\] TweakA: Direct conflict'
    }

    It "formats unknown dependency items correctly" {
        $result = @{
            Unknowns = @(
                @{ Category = 'AdvancedDebloat'; Source = 'UnknownItem'; Summary = 'Unregistered item'; Reason = 'Item is not registered in catalog' }
            )
        }
        $report = Format-WinEaseDependencyReport -Result $result
        $report | Should Match '\[DEPENDENCY UNKNOWN / .*\]'
        $report | Should Match '  - \[AdvancedDebloat\] UnknownItem: Unregistered item -- Item is not registered in catalog'
    }

    It "formats feature impacts with and without AffectedFeatures list" {
        $result = @{
            Impacts = @(
                @{ Category = 'Component'; Source = 'RemoveStore'; Summary = 'Store removal affects apps'; AffectedFeatures = @('App Installer', 'Store Apps') },
                @{ Category = 'Tweak'; Source = 'DisableSpooler'; Summary = 'Print spooler disabled' }
            )
        }
        $report = Format-WinEaseDependencyReport -Result $result
        $report | Should Match '\[FEATURE IMPACT\]'
        $report | Should Match '  - \[Component\] RemoveStore: Store removal affects apps'
        $report | Should Match '      \* App Installer'
        $report | Should Match '      \* Store Apps'
        $report | Should Match '  - \[Tweak\] DisableSpooler: Print spooler disabled'
    }

    It "formats combined report containing conflicts, unknowns, and impacts" {
        $result = @{
            Conflicts = @(
                @{ Category = 'Component'; Source = 'CompA'; Summary = 'Conflict A' }
            )
            Unknowns = @(
                @{ Category = 'Tweak'; Source = 'TweakB'; Summary = 'Unknown B'; Reason = 'Reason B' }
            )
            Impacts = @(
                @{ Category = 'Component'; Source = 'CompC'; Summary = 'Impact C'; AffectedFeatures = @('Feature C') }
            )
        }
        $report = Format-WinEaseDependencyReport -Result $result
        $report | Should Match '\[DEPENDENCY CONFLICT\]'
        $report | Should Match '\[DEPENDENCY UNKNOWN / .*\]'
        $report | Should Match '\[FEATURE IMPACT\]'

        # Verify section order: CONFLICT < UNKNOWN < FEATURE IMPACT
        $idxConflict = $report.IndexOf('[DEPENDENCY CONFLICT]')
        $idxUnknown = $report.IndexOf('DEPENDENCY UNKNOWN')
        $idxImpact = $report.IndexOf('[FEATURE IMPACT]')

        ($idxConflict -lt $idxUnknown) | Should Be $true
        ($idxUnknown -lt $idxImpact) | Should Be $true

        # Verify output is trimmed at the end (no trailing newlines)
        $report.EndsWith("`n") | Should Be $false
        $report.EndsWith("`r") | Should Be $false
    }

    It "formats output correctly when integrated directly with Test-WinEaseDependencies" {
        $cfg = @{
            WSLSupport = $true
            NoHypervisor = $true
            RemoveStore = $true
            TweakSettings = @{}
            AdvancedDebloatStandard = @('Totally Unknown Item XYZ')
            AdvancedDebloatExperimental = @()
        }
        $depResult = Test-WinEaseDependencies -Config $cfg
        $report = Format-WinEaseDependencyReport -Result $depResult

        $report | Should Match '\[DEPENDENCY CONFLICT\]'
        $report | Should Match '\[DEPENDENCY UNKNOWN / .*\]'
        $report | Should Match '\[FEATURE IMPACT\]'
        $report | Should Match 'WSLSupport'
        $report | Should Match 'RemoveStore'
        $report | Should Match 'Totally Unknown Item XYZ'
    }
}

# --- User Extensibility Engine tests (M2) ---
if (-not (Get-Command -Name Import-WinEaseUserExtensions -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseExtensions.ps1")
}
if (-not (Get-Command -Name Test-WinEaseRecoveryReadiness -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "User Extensibility Engine (lib/WinEaseExtensions.ps1)" {
    It "Import-WinEaseUserExtensions returns Loaded=false for missing file" {
        $r = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\nonexistent-user-tweaks.psd1")
        $r.Loaded | Should Be $false
    }
    It "Import-WinEaseUserExtensions loads valid user-tweaks.psd1" {
        $r = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\user\user-tweaks.psd1")
        $r.Loaded | Should Be $true
        $r.Errors.Count | Should Be 0
    }
    It "Test-WinEaseRecoveryReadiness returns expected properties" {
        $rr = Test-WinEaseRecoveryReadiness -Config @{ KeepRecoveryEnv = $false }
        $rr.PSObject.Properties.Name -contains 'HasSecondaryDrive' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'ReadinessScore' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'Recommendations' | Should Be $true
        $rr.WinReEnabledOnTarget | Should Be $false
    }
    It "Test-WinEaseRecoveryReadiness finds the default profile backup" {
        $oldProfile = $env:USERPROFILE
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('winease_readiness_' + [guid]::NewGuid().ToString('N'))
        try {
            $backup = Join-Path $tmp 'WinEase_migration_backup'
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $backup 'migration-manifest.json') -Value '{}' -Encoding ASCII
            $env:USERPROFILE = $tmp
            $rr = Test-WinEaseRecoveryReadiness -Config @{ KeepRecoveryEnv = $false }
            $rr.MigrationBackupFound | Should Be $true
        } finally {
            $env:USERPROFILE = $oldProfile
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "Compare-WinEaseConfig returns a diff result" {
        $diff = Compare-WinEaseConfig -ReferenceConfig @{ TweakSettings = @{ DisableUAC = $false } } -DifferenceConfig @{ TweakSettings = @{ DisableUAC = $true } }
        $diff.TotalDiffCount | Should BeGreaterThan 0
        $diff.ReferenceName | Should Not Be $null
    }
    It "Format-WinEaseConfigDiff produces formatted string output for config diff" {
        $diff = Compare-WinEaseConfig -ReferenceConfig @{ RemoveDefender = $false; TweakGroups = @{ Gaming = $false }; TweakSettings = @{ DisableUAC = $false } } -DifferenceConfig @{ RemoveDefender = $true; TweakGroups = @{ Gaming = $true }; TweakSettings = @{ DisableUAC = $true } }
        $formatted = Format-WinEaseConfigDiff -DiffResult $diff
        $formatted | Should Match "Config diff: Reference -> Difference"
        $formatted | Should Match "Total differences: 5"
        $formatted | Should Match "\[Components\]"
        $formatted | Should Match "RemoveDefender: False -> True"
        $formatted | Should Match "\[Tweak Groups\]"
        $formatted | Should Match "Gaming: False -> True"
        $formatted | Should Match "\[Tweak Settings\]"
        $formatted | Should Match "DisableUAC: False -> True"
    }
    It "Format-WinEaseConfigDiff handles empty diffs without section headers" {
        $diff = [PSCustomObject]@{
            ReferenceName     = "Base"
            DifferenceName    = "Target"
            TotalDiffCount    = 0
            ComponentDiffs    = @()
            TweakGroupDiffs   = @()
            TweakSettingDiffs = @()
        }
        $formatted = Format-WinEaseConfigDiff -DiffResult $diff
        $formatted | Should Match "Config diff: Base -> Target"
        $formatted | Should Match "Total differences: 0"
        $formatted | Should Not Match "\[Components\]"
        $formatted | Should Not Match "\[Tweak Groups\]"
        $formatted | Should Not Match "\[Tweak Settings\]"
    }
    It "Get-WinEaseCustomScriptMetadata parses metadata headers" {
        $tempPath = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $tmp = Join-Path $tempPath "test_script_meta.ps1"
        "# @WinEase-Id: TestScript`n# @WinEase-Stage: PreBuild`n# @WinEase-Order: 42`n# @WinEase-OnError: Warn`n# @WinEase-Description: Test desc`nWrite-Host 'hi'" | Set-Content $tmp -Encoding UTF8
        $m = Get-WinEaseCustomScriptMetadata -ScriptPath $tmp
        $m.Id | Should Be 'TestScript'
        $m.Stage | Should Be 'PreBuild'
        $m.Order | Should Be 42
        $m.OnError | Should Be 'Warn'
        $m.Description | Should Be 'Test desc'
        $m.Sha256 | Should Not Be ''
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    It "Install-WinEaseExtensionHost deploys extension host script to directory" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ext_host_test_" + [Guid]::NewGuid().ToString("N"))
        try {
            $deployedPath = Install-WinEaseExtensionHost -CustomScriptsDir $tmpDir
            Test-Path -LiteralPath $deployedPath | Should Be $true
            (Get-Item -LiteralPath $deployedPath).Name | Should Be 'WinEaseExtensionHost.ps1'
            $content = Get-Content -LiteralPath $deployedPath -Raw
            $content | Should Match 'WinEase Extension Host Script'
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "Invoke-WinEaseUserExtensionActions filters by phase type and applies dry-run" {
        $origTweakDefs = $script:UserTweakDefs
        try {
            $script:UserTweakDefs = [ordered]@{
                'User_UnitTest' = @{
                    Key = 'User_UnitTest'
                    Category = 'Custom'
                    Description = 'Unit Test Tweak'
                    Actions = @(
                        @{ Type = 'AppxRemove'; Name = 'TestApp' },
                        @{ Type = 'FeatureDisable'; Name = 'TestFeature' },
                        @{ Type = 'CapabilityRemove'; Name = 'TestCap' },
                        @{ Type = 'Registry'; Hive = 'SOFTWARE'; Path = 'Test'; Name = 'Val'; Value = '1' },
                        @{ Type = 'Service'; Name = 'TestSvc'; Value = 'Disabled' }
                    )
                }
            }
            $appxRes = Invoke-WinEaseUserExtensionActions -PhaseType Appx -TweakSettings @{ 'User_UnitTest' = $true } -DryRun
            $appxRes.AppliedCount | Should Be 1
            $appxRes.Results[0].Status | Should Be 'DryRun'
            $appxRes.Results[0].Type | Should Be 'AppxRemove'

            $fodRes = Invoke-WinEaseUserExtensionActions -PhaseType FOD -TweakSettings @{ 'User_UnitTest' = $true } -DryRun
            $fodRes.AppliedCount | Should Be 2

            $regRes = Invoke-WinEaseUserExtensionActions -PhaseType Registry -TweakSettings @{ 'User_UnitTest' = $true } -DryRun
            $regRes.AppliedCount | Should Be 2

            $disabledRes = Invoke-WinEaseUserExtensionActions -PhaseType Appx -TweakSettings @{ 'User_UnitTest' = $false } -DryRun
            $disabledRes.AppliedCount | Should Be 0
        } finally {
            $script:UserTweakDefs = $origTweakDefs
        }
    }
    It "Invoke-WinEaseCustomScriptsStage evaluates conditions and handles script execution policies" {
        $origCustomScripts = $script:UserCustomScripts
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ext_test_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $sGood = Join-Path $tmpDir "01-good.ps1"
            "# @WinEase-Id: GoodScript`n# @WinEase-Stage: PreBuild`n# @WinEase-Order: 10`nWrite-Host 'OK'" | Set-Content $sGood -Encoding UTF8

            $sCond = Join-Path $tmpDir "02-cond.ps1"
            "# @WinEase-Id: CondScript`n# @WinEase-Stage: PreBuild`n# @WinEase-Condition: CondTweak`n# @WinEase-Order: 20`nWrite-Host 'Cond'" | Set-Content $sCond -Encoding UTF8

            $sFail = Join-Path $tmpDir "03-fail.ps1"
            "# @WinEase-Id: FailScript`n# @WinEase-Stage: PreBuild`n# @WinEase-OnError: Warn`n# @WinEase-Order: 30`nthrow 'test warning'" | Set-Content $sFail -Encoding UTF8

            $sStop = Join-Path $tmpDir "04-stop.ps1"
            "# @WinEase-Id: StopScript`n# @WinEase-Stage: PreBuild`n# @WinEase-OnError: Stop`n# @WinEase-Order: 40`nthrow 'test stop'" | Set-Content $sStop -Encoding UTF8

            $script:UserCustomScripts = @(
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sGood },
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sCond; Condition = 'CondTweak' },
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sFail },
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sStop }
            )

            # Dry run with condition met
            $dryRes = Invoke-WinEaseCustomScriptsStage -Stage PreBuild -Context @{ Config = @{ CondTweak = $true } } -DryRun
            $dryRes.Executed.Count | Should Be 4

            # Condition false skips script
            $condFalseRes = Invoke-WinEaseCustomScriptsStage -Stage PreBuild -Context @{ Config = @{ CondTweak = $false } } -DryRun
            $condFalseRes.Executed.Count | Should Be 3
            $condFalseRes.Skipped.Count | Should Be 1

            # Live execution with Warn error policy
            $script:UserCustomScripts = @(
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sGood },
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sFail }
            )
            $execRes = Invoke-WinEaseCustomScriptsStage -Stage PreBuild
            $execRes.Executed.Count | Should Be 1
            $execRes.Failed.Count | Should Be 1

            # Live execution with Stop error policy throws exception
            $script:UserCustomScripts = @(
                @{ Enabled = $true; Stage = 'PreBuild'; Path = $sStop }
            )
            { Invoke-WinEaseCustomScriptsStage -Stage PreBuild } | Should Throw

            # FirstLogon stage copies script file to ScratchDir
            $scratchDir = Join-Path $tmpDir "scratch"
            $sFL = Join-Path $tmpDir "05-fl.ps1"
            "# @WinEase-Id: FLScript`n# @WinEase-Stage: FirstLogon`nWrite-Host 'FL'" | Set-Content $sFL -Encoding UTF8
            $script:UserCustomScripts = @(
                @{ Enabled = $true; Stage = 'FirstLogon'; Path = $sFL }
            )
            $flRes = Invoke-WinEaseCustomScriptsStage -Stage FirstLogon -Context @{ ScratchDir = $scratchDir }
            $flRes.Executed.Count | Should Be 1
            $copiedFile = Join-Path $scratchDir "Windows\Setup\Scripts\Custom\FirstLogon\05-fl.ps1"
            Test-Path -LiteralPath $copiedFile | Should Be $true
        } finally {
            $script:UserCustomScripts = $origCustomScripts
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Get-WinEaseCustomScriptStageMap maps the post install stages to their image folder" {
        $map = @(Get-WinEaseCustomScriptStageMap)
        $map.Count | Should Be 4
        @($map | Where-Object { $_.Stage -eq 'PreBuild' })[0].ImageFolder | Should Be ''
        @($map | Where-Object { $_.Stage -eq 'FirstLogon' })[0].ImageFolder | Should Be 'Windows\Setup\Scripts\Custom'
        @($map | Where-Object { $_.Stage -eq 'UserOnce' })[0].ImageFolder | Should Be 'Windows\Setup\Scripts\UserCustom'
        @(Get-WinEaseCustomScriptExtensions) -contains '.reg' | Should Be $true
    }

    It "Add-WinEaseCustomScript prefixes the order and rejects unsupported file types" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs_add_" + [Guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools\custom-scripts\FirstLogon') | Out-Null
        try {
            $good = Join-Path $tmp 'demo.ps1'
            Set-Content -LiteralPath $good -Value "Write-Host 'demo'" -Encoding UTF8
            $bad = Join-Path $tmp 'notes.txt'
            Set-Content -LiteralPath $bad -Value 'not a script' -Encoding UTF8
            $res = Add-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Paths @($good, $bad)
            @($res.Added).Count | Should Be 1
            @($res.Errors).Count | Should Be 1
            @($res.Errors)[0] | Should Match 'Unsupported file type'
            @($res.Added)[0].Name | Should Be '01-demo.ps1'
            (Test-Path -LiteralPath (Join-Path $repo 'tools\custom-scripts\FirstLogon\01-demo.ps1')) | Should Be $true
            # the next file gets the next free number
            $second = Join-Path $tmp 'batch.cmd'
            Set-Content -LiteralPath $second -Value '@echo off' -Encoding ASCII
            $res2 = Add-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Paths @($second)
            @($res2.Added)[0].Name | Should Be '02-batch.cmd'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Set-WinEaseCustomScriptMetadata writes the comment syntax of the file type and replaces instead of duplicating" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs_meta_" + [Guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools\custom-scripts\FirstLogon') | Out-Null
        try {
            $ps1 = Join-Path $tmp 'setup.ps1'
            Set-Content -LiteralPath $ps1 -Value "Write-Host 'setup'" -Encoding UTF8
            $cmd = Join-Path $tmp 'batch.cmd'
            Set-Content -LiteralPath $cmd -Value '@echo off' -Encoding ASCII
            $reg = Join-Path $tmp 'tweak.reg'
            Set-Content -LiteralPath $reg -Value 'Windows Registry Editor Version 5.00' -Encoding ASCII
            $added = Add-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Paths @($ps1, $cmd, $reg)
            @($added.Added).Count | Should Be 3

            $mPs = Set-WinEaseCustomScriptMetadata -Path @($added.Added)[0].Path -Order 5 -Description 'setup' -OnError Stop
            $mPs.Order | Should Be 5
            $mPs.Description | Should Be 'setup'
            $mPs.OnError | Should Be 'Stop'
            $mPs.Comment | Should Be '#'

            $mCmd = Set-WinEaseCustomScriptMetadata -Path @($added.Added)[1].Path -Order 6 -Description 'batch'
            $mCmd.Order | Should Be 6
            $mCmd.Description | Should Be 'batch'
            $mCmd.Comment | Should Be 'REM'
            @([System.IO.File]::ReadAllLines(@($added.Added)[1].Path) | Where-Object { $_ -match '@WinEase-Order' })[0] | Should Match '^REM @WinEase-Order: 6$'

            $mReg = Set-WinEaseCustomScriptMetadata -Path @($added.Added)[2].Path -Order 7
            $mReg.Comment | Should Be ';'
            @([System.IO.File]::ReadAllLines(@($added.Added)[2].Path) | Where-Object { $_ -match '@WinEase-Order' })[0] | Should Match '^; @WinEase-Order: 7$'

            # A second write must replace the header line, not add another one
            $null = Set-WinEaseCustomScriptMetadata -Path @($added.Added)[0].Path -Description 'changed'
            $lines = @([System.IO.File]::ReadAllLines(@($added.Added)[0].Path) | Where-Object { $_ -match '@WinEase-Description' })
            $lines.Count | Should Be 1
            $lines[0] | Should Match 'changed'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-WinEaseCustomScriptInventory and Preview report the stage, order and image path" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs_inv_" + [Guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools\custom-scripts\FirstLogon'), (Join-Path $repo 'tools\custom-scripts\UserOnce') | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $repo 'tools\custom-scripts\FirstLogon\02-second.ps1') -Value "Write-Host 'second'" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $repo 'tools\custom-scripts\FirstLogon\01-first.ps1') -Value "Write-Host 'first'" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $repo 'tools\custom-scripts\UserOnce\05-user.cmd') -Value '@echo off' -Encoding ASCII

            $inv = @(Get-WinEaseCustomScriptInventory -RepoRoot $repo -Stage FirstLogon)
            $inv.Count | Should Be 2
            $inv[0].Name | Should Be '01-first.ps1'
            $inv[0].EffectiveOrder | Should Be 1
            $inv[1].Name | Should Be '02-second.ps1'

            $prev = @(Get-WinEaseCustomScriptPreview -RepoRoot $repo)
            @($prev | Where-Object { $_.Stage -eq 'FirstLogon' }).Count | Should Be 2
            @($prev | Where-Object { $_.Stage -eq 'UserOnce' })[0].ImagePath | Should Match '^Windows\\Setup\\Scripts\\UserCustom\\'
            @($prev | Where-Object { $_.Stage -eq 'FirstLogon' })[0].ImagePath | Should Match '^Windows\\Setup\\Scripts\\Custom\\'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Move-WinEaseCustomScriptOrder renames the file and Remove-WinEaseCustomScript refuses paths outside the repository" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs_mv_" + [Guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools\custom-scripts\FirstLogon') | Out-Null
        try {
            $src = Join-Path $tmp 'move.ps1'
            Set-Content -LiteralPath $src -Value "Write-Host 'move'" -Encoding UTF8
            $res = Add-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Paths @($src)
            $path = @($res.Added)[0].Path
            $mv = Move-WinEaseCustomScriptOrder -Path $path -NewOrder 9
            $mv.Changed | Should Be $true
            $mv.Name | Should Be '09-move.ps1'
            (Test-Path -LiteralPath $mv.Path) | Should Be $true
            (Test-Path -LiteralPath $path) | Should Be $false
            { Remove-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Path $src } | Should Throw
            $rm = Remove-WinEaseCustomScript -RepoRoot $repo -Stage FirstLogon -Path $mv.Path
            $rm.Removed | Should Be '09-move.ps1'
            (Test-Path -LiteralPath $mv.Path) | Should Be $false
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "the stage runner copies declared scripts flat into the image and registers them in the manifest" {
        $origCustomScripts = $script:UserCustomScripts
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs_run_" + [Guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools\custom-scripts\FirstLogon') | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $repo 'tools\custom-scripts\FirstLogon\01-declared.ps1') -Value "Write-Host 'declared'" -Encoding UTF8
            $scratch = Join-Path $tmp 'scratch'
            # relative path like config\user\user-tweaks.psd1 can carry it
            $script:UserCustomScripts = @(
                @{ Enabled = $true; Stage = 'FirstLogon'; Path = 'tools\custom-scripts\FirstLogon\01-declared.ps1' },
                @{ Enabled = $true; Stage = 'UserOnce'; Path = 'tools\custom-scripts\FirstLogon\01-declared.ps1'; Id = 'DeclaredUser' }
            )
            $null = Invoke-WinEaseCustomScriptsStage -Stage FirstLogon -Context @{ ScratchDir = $scratch; ScriptRoot = $repo }
            (Test-Path -LiteralPath (Join-Path $scratch 'Windows\Setup\Scripts\Custom\01-declared.ps1')) | Should Be $true
            $null = Invoke-WinEaseCustomScriptsStage -Stage UserOnce -Context @{ ScratchDir = $scratch; ScriptRoot = $repo }
            (Test-Path -LiteralPath (Join-Path $scratch 'Windows\Setup\Scripts\UserCustom\01-declared.ps1')) | Should Be $true
            $manifestPath = Join-Path $scratch 'Windows\Setup\Scripts\custom-scripts-manifest.json'
            (Test-Path -LiteralPath $manifestPath) | Should Be $true
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $names = @($manifest.PSObject.Properties.Name)
            ($names -contains '01-declared.ps1') | Should Be $true
            ($names -contains 'user/01-declared.ps1') | Should Be $true
        } finally {
            $script:UserCustomScripts = $origCustomScripts
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "S1 - user extensions survive -PresetsOnly re-import" {
    It "keeps UserTweakDefs and UserCustomScripts after a -PresetsOnly call" {
        . (Join-Path $script:RepoRoot 'lib\WinEaseExtensions.ps1')
        $dir = Join-Path $env:TEMP ("s1ext_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = Join-Path $dir 'user-tweaks.psd1'
        $lines = @(
            '@{',
            '    UserTweaks = @(',
            '        @{ Key = ''S1TestSwitch''; Category = ''Test''; Description = ''S1 test''; Default = $false }',
            '    )',
            '    UserPresets = @{',
            '        S1Preset = @{ S1TestSwitch = $true }',
            '    }',
            '    CustomScripts = @(',
            '        @{ Id = ''S1Script''; Stage = ''PreBuild''; Path = ''x.ps1'' }',
            '    )',
            '}'
        )
        Set-Content -LiteralPath $cfg -Value $lines -Encoding UTF8
        $script:AllTweakDefs = [ordered]@{}
        $script:BuiltInPresets = [ordered]@{}
        $r1 = Import-WinEaseUserExtensions -ConfigPath $cfg
        $r1.UserTweakCount | Should Be 1
        $r1.CustomScriptCount | Should Be 1
        $r2 = Import-WinEaseUserExtensions -ConfigPath $cfg -PresetsOnly
        @($script:UserTweakDefs.Keys).Count | Should Be 1
        @($script:UserCustomScripts).Count | Should Be 1
        $r2.UserTweakCount | Should Be 1
        $r2.CustomScriptCount | Should Be 1
        $script:BuiltInPresets.Contains('S1Preset') | Should Be $true
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "dot-sources WinEaseExtensions.ps1 once in the builder (the migration engine is not part of the ISO build)" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' }, $true)
        $text = @($cmds | ForEach-Object { $_.Extent.Text })
        foreach ($name in 'WinEaseExtensions.ps1') {
            $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Right.Extent.Text -like "*$name*" }, $true))
            $assigns.Count | Should Be 1
            $var = $assigns[0].Left.VariablePath.UserPath
            @($text | Where-Object { $_ -eq ". `$$var" }).Count | Should Be 1
        }
    }
}

# --- S2: dependency checker additions ---
Describe "WinEase dependency checker S2 additions" {
    $emptyLists = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }

    It "reports RemoveDrivers as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveDrivers'] = $true
        $r = Test-WinEaseDependencies -Config $cfg
        @($r.Unknowns | Where-Object { $_.Source -eq 'RemoveDrivers' }).Count | Should Be 1
    }

    It "reports AllowPhysicalDebloat as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['AllowPhysicalDebloat'] = $true
        $r = Test-WinEaseDependencies -Config $cfg
        @($r.Unknowns | Where-Object { $_.Source -eq 'AllowPhysicalDebloat' }).Count | Should Be 1
    }

    It "lists VBS among NoHypervisor affected features" {
        $c = Import-PowerShellDataFile -Path (Join-Path -Path $script:RepoRoot -ChildPath 'config\dependencies.psd1')
        ($c.Tweaks['NoHypervisor'].AffectedFeatures -contains 'VBS') | Should Be $true
    }

    It "reports an enabled user tweak without Impact as Unknown, but not when Impact is Safe" {
        $saved = $script:UserTweakDefs
        try {
            $script:UserTweakDefs = [ordered]@{
                S2NoImpact = @{ Key = 'S2NoImpact' }
                S2SafeOne  = @{ Key = 'S2SafeOne'; Impact = 'Safe' }
            }
            $cfg = @{ TweakSettings = @{ S2NoImpact = $true; S2SafeOne = $true }; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
            $r = Test-WinEaseDependencies -Config $cfg
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2NoImpact' }).Count | Should Be 1
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2SafeOne' }).Count | Should Be 0
            @($r.Impacts | Where-Object { $_.Source -eq 'S2SafeOne' }).Count | Should Be 0
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "adds a hashtable Impact of a user tweak to Impacts" {
        $saved = $script:UserTweakDefs
        try {
            $script:UserTweakDefs = [ordered]@{
                S2WithImpact = @{ Key = 'S2WithImpact'; Impact = @{ AffectedFeatures = @('Foo'); Severity = 'Warning'; Reason = 'r' } }
            }
            $cfg = @{ TweakSettings = @{ S2WithImpact = $true }; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
            $r = Test-WinEaseDependencies -Config $cfg
            @($r.Impacts | Where-Object { $_.Source -eq 'S2WithImpact' }).Count | Should Be 1
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2WithImpact' }).Count | Should Be 0
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "does not fail when UserTweakDefs is undefined" {
        $saved = $script:UserTweakDefs
        try {
            Remove-Variable -Name UserTweakDefs -Scope Script -ErrorAction SilentlyContinue
            $r = Test-WinEaseDependencies -Config $emptyLists
            $r.HasIssues | Should Be $false
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "still detects RemoveStore + KeepXboxServices and NoHypervisor + WSLSupport conflicts" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveStore'] = $true; $cfg['KeepXboxServices'] = $true
        (Test-WinEaseDependencies -Config $cfg).Conflicts.Count | Should BeGreaterThan 0
        $cfg2 = $emptyLists.Clone(); $cfg2['NoHypervisor'] = $true; $cfg2['WSLSupport'] = $true
        (Test-WinEaseDependencies -Config $cfg2).Conflicts.Count | Should BeGreaterThan 0
    }
}

# ---------------------------------------------------------------------------
# Upstream sync 2026-10-22: the FeatureManagement override IDs and the registry
# writes that came with the newest upstream releases.
# ---------------------------------------------------------------------------
Describe "WinEase helpers - FeatureManagement override IDs" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "computes the same obfuscated IDs as the ReviOS playbook and the Revision Tool" {
        # The pairs are published by ReviOS 26.10 / main
        # (src/Configuration/Tasks/registry/explorer/search.yml) and by the
        # Revision Tool 2.14.x
        # (src/lib/core/services/win_registry_service.dart).
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 43998308) | Should Be 3369582732
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 37926450) | Should Be 1694661260
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 56517033) | Should Be 1387020943
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 58375086) | Should Be 1561856655
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 63366798) | Should Be 497250959
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 58375066) | Should Be 890768015
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 61199980) | Should Be 3653481614
        (ConvertTo-WinEaseFeatureIdOverride -FeatureId 40012896) | Should Be 3245750924
    }

    It "decodes an override ID back into its feature ID" {
        (ConvertFrom-WinEaseFeatureIdOverride -OverrideId 3369582732) | Should Be 43998308
        (ConvertFrom-WinEaseFeatureIdOverride -OverrideId 1694661260) | Should Be 37926450
        (ConvertFrom-WinEaseFeatureIdOverride -OverrideId 1387020943) | Should Be 56517033
        (ConvertFrom-WinEaseFeatureIdOverride -OverrideId 3245750924) | Should Be 40012896
    }

    It "round-trips every feature ID that the builder writes" {
        foreach ($id in 43998308, 37926450) {
            $override = ConvertTo-WinEaseFeatureIdOverride -FeatureId $id
            (ConvertFrom-WinEaseFeatureIdOverride -OverrideId $override) | Should Be $id
        }
    }

    It "rejects a value outside the 32-bit range" {
        { ConvertTo-WinEaseFeatureIdOverride -FeatureId -1 } | Should Throw
        { ConvertTo-WinEaseFeatureIdOverride -FeatureId 4294967296 } | Should Throw
        { ConvertFrom-WinEaseFeatureIdOverride -OverrideId -1 } | Should Throw
        { ConvertFrom-WinEaseFeatureIdOverride -OverrideId 4294967296 } | Should Throw
    }
}

Describe "WinEase builder - the UI preference table (config\ui-preferences.psd1)" {
    # The per-user UI preferences used to be a nested array literal in phase 10.
    # The @() operator unwraps a group that holds a single entry, so the four
    # fields of that entry arrived one by one and reg.exe was called with an empty
    # value name, an empty type and an empty data. A native call drops an empty
    # argument, so reg.exe read the '/f' switch as the data and wrote a key named
    # after the first character of the data, holding a value named '/t'. The next
    # build found that value, reg.exe asked "Overwrite (Yes/No)?" and waited for a
    # key press - the build hung in phase 10 and no ISO was produced.
    BeforeAll {
        $script:UiPrefPath = Join-Path $script:RepoRoot "config\ui-preferences.psd1"
        $script:UiPrefData = Import-PowerShellDataFile -LiteralPath $script:UiPrefPath
        $script:UiPrefEntries = @($script:UiPrefData.UiPreferences)
        $script:UiPrefPhaseText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\10-registry.ps1"))
        $script:UiPrefSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    }

    It "the table holds the UI preferences" {
        $script:UiPrefEntries.Count | Should BeGreaterThan 0
    }

    It "every entry is a hashtable, so @() cannot unwrap it" {
        foreach ($entry in $script:UiPrefEntries) {
            $entry -is [System.Collections.IDictionary] | Should Be $true
        }
    }

    It "every entry names the tweak, the path, the value, the type and the data" {
        foreach ($entry in $script:UiPrefEntries) {
            foreach ($field in 'Tweak', 'Path', 'Name', 'Type', 'Data') {
                [string]::IsNullOrWhiteSpace([string]$entry[$field]) | Should Be $false
            }
        }
    }

    It "every entry writes a registry type that reg.exe knows" {
        foreach ($entry in $script:UiPrefEntries) {
            $entry.Type | Should Match '^(REG_DWORD|REG_SZ|REG_MULTI_SZ|REG_EXPAND_SZ|REG_BINARY|REG_QWORD)$'
        }
    }

    It "every tweak of the table is defined in config\schema.psd1" {
        $keys = @($script:UiPrefSchema.Tweaks | ForEach-Object { $_.Key })
        foreach ($tweak in @($script:UiPrefEntries | ForEach-Object { $_.Tweak } | Sort-Object -Unique)) {
            ($keys -contains $tweak) | Should Be $true
        }
    }

    It "the phase reads the table from the data file" {
        $script:UiPrefPhaseText | Should Match 'config\\ui-preferences\.psd1'
        $script:UiPrefPhaseText | Should Match 'Import-PowerShellDataFile'
    }

    It "the phase does not read the fields of a tuple by index any more" {
        # $v[0] / $v[1] ... is how the four fields of a tuple were read. With a
        # table that @() can unwrap, that reads the first character of a string
        # instead of a field.
        $script:UiPrefPhaseText | Should Not Match '\$v\[\d+\]'
    }

    It "the phase skips an entry with an empty field instead of calling reg.exe" {
        $script:UiPrefPhaseText | Should Match 'IsNullOrWhiteSpace'
        $script:UiPrefPhaseText | Should Match 'Skipping the UI preference'
    }

    It "the phase removes the keys that the broken table left behind" {
        $script:UiPrefPhaseText | Should Match 'Remove-WinEaseBrokenUiPreferenceKey'
        $script:UiPrefPhaseText | Should Match 'GetValueNames'
    }

    It "every reg.exe call of the repository passes the force switch" {
        # Without '/f' reg.exe asks "Overwrite (Yes/No)?" when the value already
        # exists and waits for a key press - that is what stopped the build.
        $offenders = @()
        $files = @()
        $files += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "phases") -Filter '*.ps1' -File
        $files += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "lib") -Filter '*.ps1' -File
        $files += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "scripts") -Filter '*.ps1' -File
        foreach ($file in $files) {
            $lineNo = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                $lineNo++
                if ($line -notmatch '^\s*&?\s*reg(\.exe)?\s+(add|delete)\b') { continue }
                if ($line -notmatch '/f') { $offenders += "$($file.Name):$lineNo" }
            }
        }
        ($offenders -join ', ') | Should Be ''
    }
}
