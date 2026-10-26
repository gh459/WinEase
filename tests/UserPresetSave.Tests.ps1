# UserPresetSave.Tests.ps1 - the GUI "Save as preset" feature (G2)
# Run with:  Invoke-Pester -Path .\tests\UserPresetSave.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# Covers Save-WinEaseGuiUserPreset and its helpers (lib\WinEaseGuiCore.ps1), the per-file
# user preset folder loading of Import-WinEaseUserExtensions (lib\WinEaseExtensions.ps1) and
# the wiring of both windows. Nothing here opens a window: the WinForms part only loads the
# window with -NoShow plus the no-modal stubs and rebuilds the preset list.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock call counters must be global')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

# The schema and the presets, the way the builder builds them, plus the loader and the GUI core.
if (-not (Get-Command -Name Save-WinEaseGuiUserPreset -ErrorAction SilentlyContinue)) {
    $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $schema.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $schema.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseExtensions.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseGuiCore.ps1')
}
if (-not (Get-Command -Name Write-WinEaseTextFileAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath 'WinEasehelpers.ps1')
}
$presetFileData = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\presets.psd1')

# Get-WinEasePreset lives in the builder; the tests resolve against the fresh BuiltInPresets only.
function Get-WinEasePreset {
    param([string]$Name)
    if (-not $Name) { return $script:BuiltInPresets['extreme'] }
    $clean = $Name.Trim().ToLower()
    if ($script:BuiltInPresets.Contains($clean)) { return $script:BuiltInPresets[$clean] }
    return $null
}

function Initialize-PresetTestState {
    # A fresh temp repository: config\user\user-tweaks.psd1 (absent is fine) and config\user\presets.
    $script:TmpRepo = Join-Path -Path $TestDrive -ChildPath ("repo_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TmpRepo 'config\user\presets'))
    # Fresh preset tables: the built-ins from config\presets.psd1, no user presets.
    $script:BuiltInPresets = [ordered]@{}
    foreach ($k in @($presetFileData.PresetOrder)) {
        if ($presetFileData.Presets.Contains($k)) { $script:BuiltInPresets[$k] = $presetFileData.Presets[$k] }
    }
    foreach ($k in @($presetFileData.Presets.Keys)) {
        if (-not $script:BuiltInPresets.Contains($k)) { $script:BuiltInPresets[$k] = $presetFileData.Presets[$k] }
    }
    $script:UserPresets = [ordered]@{}
}

# A draft like Get-WinEaseGuiDraftConfig / PresetStateConfig produces, with deliberate differences
# from the balanced preset and one non-default engine.
function New-PresetDraft {
    $draft = @{}
    foreach ($cd in $script:ComponentDefs.Values) {
        if ($cd.Gui) { $draft[$cd.Key] = [bool]$cd.Gui.Default }
    }
    $draft['RemoveDefender'] = $true
    $draft['KeepBluetooth'] = $false
    $tweaks = [ordered]@{}
    foreach ($tk in $script:AllTweakDefs.Keys) { $tweaks[$tk] = [bool]$script:AllTweakDefs[$tk].Default }
    $first = @($script:AllTweakDefs.Keys)[0]
    $tweaks[$first] = (-not [bool]$script:AllTweakDefs[$first].Default)
    $draft['TweakSettings'] = $tweaks
    $draft['PayloadFormat'] = 'ESD'
    $draft['AdvancedDebloatStandard'] = @("Remove PatchCache (dir delete) [200-500MB]")
    $draft['AdvancedDebloatExperimental'] = @()
    $draft['DebloatEngineSelection'] = @{ "Remove PatchCache (dir delete) [200-500MB]" = 'Rust' }
    # values that must never reach the file
    $draft['UserPassword'] = 'Sup3rSecret!Value'
    $draft['SourceDrive'] = 'E:'
    $draft['WorkDir'] = 'C:' + '\some\workdir'
    return $draft
}

Describe "Get-WinEaseGuiUserPresetFilePath" {
    It "resolves file path given an explicit RepoRoot and Name" {
        $repo = Join-Path $TestDrive 'TestRepo'
        $expected = Join-Path (Join-Path (Join-Path $repo 'config') 'user') (Join-Path 'presets' 'my preset.psd1')
        $path = Get-WinEaseGuiUserPresetFilePath -RepoRoot $repo -Name 'My Preset'
        $path | Should Be $expected
    }

    It "normalizes preset names by trimming whitespace and lowercasing" {
        $repo = Join-Path $TestDrive 'TestRepo'
        $expected = Join-Path (Join-Path (Join-Path $repo 'config') 'user') (Join-Path 'presets' 'gaming-preset_01.psd1')
        $path = Get-WinEaseGuiUserPresetFilePath -RepoRoot $repo -Name '  Gaming-Preset_01  '
        $path | Should Be $expected
    }

    It "handles non-ASCII and Unicode preset names such as Japanese" {
        $repo = Join-Path $TestDrive 'TestRepo'
        $expected = Join-Path (Join-Path (Join-Path $repo 'config') 'user') (Join-Path 'presets' 'プリセット alpha.psd1')
        $path = Get-WinEaseGuiUserPresetFilePath -RepoRoot $repo -Name '  プリセット Alpha  '
        $path | Should Be $expected
    }

    It "falls back to `$script:WinEaseGuiRepoRoot when RepoRoot parameter is omitted or empty" {
        $orig = $script:WinEaseGuiRepoRoot
        try {
            $repo = Join-Path $TestDrive 'ScriptRepo'
            $script:WinEaseGuiRepoRoot = $repo
            $expected = Join-Path (Join-Path (Join-Path $repo 'config') 'user') (Join-Path 'presets' 'testpreset.psd1')
            $path = Get-WinEaseGuiUserPresetFilePath -Name 'TestPreset'
            $path | Should Be $expected

            $pathEmpty = Get-WinEaseGuiUserPresetFilePath -RepoRoot '' -Name 'TestPreset'
            $pathEmpty | Should Be $expected
        } finally {
            $script:WinEaseGuiRepoRoot = $orig
        }
    }

    It "falls back to Get-Location path when both RepoRoot parameter and `$script:WinEaseGuiRepoRoot are empty" {
        $orig = $script:WinEaseGuiRepoRoot
        try {
            $script:WinEaseGuiRepoRoot = ''
            $loc = (Get-Location).Path
            $expected = Join-Path (Join-Path (Join-Path $loc 'config') 'user') (Join-Path 'presets' 'testpreset.psd1')
            $path = Get-WinEaseGuiUserPresetFilePath -Name 'TestPreset'
            $path | Should Be $expected
        } finally {
            $script:WinEaseGuiRepoRoot = $orig
        }
    }

    It "throws parameter binding exception when mandatory Name is omitted" {
        { Get-WinEaseGuiUserPresetFilePath -RepoRoot (Join-Path $TestDrive 'TestRepo') } | Should Throw
    }
}

Describe "Test-WinEaseGuiUserPresetName" {
    It "accepts letters, digits, spaces, '-' and '_' (Japanese included), up to 40 characters" {
        Test-WinEaseGuiUserPresetName -Name 'abc-DEF 123' | Should Be $true
        Test-WinEaseGuiUserPresetName -Name 'プリセット 01' | Should Be $true
        Test-WinEaseGuiUserPresetName -Name ('a' * 40) | Should Be $true
        Test-WinEaseGuiUserPresetName -Name '  trimmed  ' | Should Be $true
    }
    It "refuses empty, too long, path-like and quoted names" {
        Test-WinEaseGuiUserPresetName -Name '' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name '   ' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name $null | Should Be $false
        Test-WinEaseGuiUserPresetName -Name ('a' * 41) | Should Be $false
        Test-WinEaseGuiUserPresetName -Name 'a/b' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name 'a\b' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name 'a:b' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name "it's" | Should Be $false
        Test-WinEaseGuiUserPresetName -Name 'a"b' | Should Be $false
        Test-WinEaseGuiUserPresetName -Name "a`tb" | Should Be $false
    }
}

Describe "ConvertTo-WinEasePsd1QuotedString" {
    It "doubles single quotes and keeps everything else verbatim" {
        ConvertTo-WinEasePsd1QuotedString -Value "it's" | Should Be "'it''s'"
        ConvertTo-WinEasePsd1QuotedString -Value "quote ' in 'the' middle" | Should Be "'quote '' in ''the'' middle'"
        ConvertTo-WinEasePsd1QuotedString -Value 'plain' | Should Be "'plain'"
        $generated = ConvertTo-WinEasePsd1QuotedString -Value "日 本語'name' (a[1]) \x"
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput("@{ V = $generated }", [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
        # the same way the loader reads it: as a .psd1 data file
        $tmpPsd1 = Join-Path $TestDrive 'quote-test.psd1'
        [System.IO.File]::WriteAllText($tmpPsd1, "@{`n    V = $generated`n}`n", (New-Object System.Text.UTF8Encoding($true)))
        (Import-PowerShellDataFile -LiteralPath $tmpPsd1).V | Should Be "日 本語'name' (a[1]) \x"
    }
}

Describe "Save-WinEaseGuiUserPreset" {
    BeforeEach {
        Initialize-PresetTestState
    }

    It "saves the draft, reloads it and Get-WinEaseGuiPresetValues returns the saved values" {
        $draft = New-PresetDraft
        $res = Save-WinEaseGuiUserPreset -Name 'My Preset' -Description 'work machine' -Current $draft -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $true
        $res.Key | Should Be 'my preset'
        $res.Path | Should Be (Join-Path (Join-Path (Join-Path $script:TmpRepo 'config\user') 'presets') 'my preset.psd1')
        Test-Path -LiteralPath $res.Path | Should Be $true

        $pv = Get-WinEaseGuiPresetValues -Name 'my preset'
        $pv | Should Not Be $null
        $pv.Components['RemoveDefender'] | Should Be $true
        $pv.Components['KeepBluetooth'] | Should Be $false
        $first = @($script:AllTweakDefs.Keys)[0]
        $pv.Tweaks[$first] | Should Be (-not [bool]$script:AllTweakDefs[$first].Default)
        $pv.PayloadFormat | Should Be 'ESD'
        @($pv.AdvancedDebloatStandard) -contains 'Remove PatchCache (dir delete) [200-500MB]' | Should Be $true
        $pv.DebloatEngineSelection['Remove PatchCache (dir delete) [200-500MB]'] | Should Be 'Rust'

        # the choices list (both windows rebuild from it) shows the ProfileName
        $choices = @(Get-WinEaseGuiUserPresetChoices)
        $match = @($choices | Where-Object { $_.Key -eq 'my preset' })
        $match.Count | Should Be 1
        $match[0].Label | Should Be 'My Preset'
    }

    It "the generated file is valid PowerShell data and keeps name and description verbatim" {
        $draft = New-PresetDraft
        $res = Save-WinEaseGuiUserPreset -Name 'プリセット 01' -Description "it's a 'quoted' ""description"" \path\" -Current $draft -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $true
        $text = [System.IO.File]::ReadAllText($res.Path)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
        $data = Import-PowerShellDataFile -LiteralPath $res.Path
        "$($data.ProfileName)" | Should Be 'プリセット 01'
        "$($data.Description)" | Should Be "it's a 'quoted' ""description"" \path\"
    }

    It "never stores secrets or paths in the file" {
        $draft = New-PresetDraft
        $res = Save-WinEaseGuiUserPreset -Name 'secretless' -Current $draft -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $true
        $text = [System.IO.File]::ReadAllText($res.Path)
        $text | Should Not Match 'Sup3rSecret'
        $text | Should Not Match 'SourceDrive'
        $text | Should Not Match 'WorkDir'
        $text | Should Not Match "'E:'"
        $text | Should Not Match 'some\\workdir'
    }

    It "refuses built-in preset names and the reserved names" {
        $dir = Join-Path $script:TmpRepo 'config\user\presets'
        foreach ($name in @('balanced', 'BALANCED', 'none', 'custom', 'not/valid')) {
            $res = Save-WinEaseGuiUserPreset -Name $name -Current (New-PresetDraft) -RepoRoot $script:TmpRepo
            $res.Saved | Should Be $false
        }
        (Save-WinEaseGuiUserPreset -Name 'balanced' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo).ReasonKey | Should Be 'SavePreset.Reason.ConflictBuiltin'
        (Save-WinEaseGuiUserPreset -Name 'none' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo).ReasonKey | Should Be 'SavePreset.Reason.Reserved'
        (Save-WinEaseGuiUserPreset -Name 'custom' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo).ReasonKey | Should Be 'SavePreset.Reason.Reserved'
        (Save-WinEaseGuiUserPreset -Name 'not/valid' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo).ReasonKey | Should Be 'SavePreset.Reason.InvalidName'
        @(Get-ChildItem -LiteralPath $dir -Filter '*.psd1' -File -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It "refuses an existing user preset without -Overwrite and saves it with -Overwrite" {
        $draft = New-PresetDraft
        $res1 = Save-WinEaseGuiUserPreset -Name 'overwrite me' -Current $draft -RepoRoot $script:TmpRepo
        $res1.Saved | Should Be $true
        $res2 = Save-WinEaseGuiUserPreset -Name 'Overwrite Me' -Current $draft -RepoRoot $script:TmpRepo
        $res2.Saved | Should Be $false
        $res2.ReasonKey | Should Be 'SavePreset.Reason.Exists'
        # change a value, overwrite, the read-back shows the new value
        $first = @($script:AllTweakDefs.Keys)[0]
        $draft.TweakSettings[$first] = (-not $draft.TweakSettings[$first])
        $res3 = Save-WinEaseGuiUserPreset -Name 'overwrite me' -Current $draft -RepoRoot $script:TmpRepo -Overwrite
        $res3.Saved | Should Be $true
        $pv = Get-WinEaseGuiPresetValues -Name 'overwrite me'
        $pv.Tweaks[$first] | Should Be $draft.TweakSettings[$first]
    }

    It "fails closed when the read-back does not return the saved values" {
        Mock Get-WinEaseGuiPresetValues { return $null }
        $res = Save-WinEaseGuiUserPreset -Name 'no readback' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $false
        $res.ReasonKey | Should Be 'SavePreset.Reason.Readback'
    }

    It "leaves no partial file when the atomic write fails or throws" {
        Mock Write-WinEaseTextFileAtomic { return $false }
        $res = Save-WinEaseGuiUserPreset -Name 'write fail' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $false
        $res.ReasonKey | Should Be 'SavePreset.Reason.Write'
        Test-Path -LiteralPath $res.Path | Should Be $false

        Mock Write-WinEaseTextFileAtomic { throw 'simulated disk full' }
        $res2 = Save-WinEaseGuiUserPreset -Name 'write throw' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo
        $res2.Saved | Should Be $false
        $res2.ReasonKey | Should Be 'SavePreset.Reason.Write'
        $res2.Error | Should Match 'simulated disk full'
        Test-Path -LiteralPath $res2.Path | Should Be $false
    }
}

Describe "Import-WinEaseUserExtensions loads the per-file preset folder" {
    BeforeEach {
        Initialize-PresetTestState
    }

    It "loads a saved preset file like a UserPresets entry" {
        $res = Save-WinEaseGuiUserPreset -Name 'loader test' -Current (New-PresetDraft) -RepoRoot $script:TmpRepo
        $res.Saved | Should Be $true
        $ext = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:TmpRepo 'config\user\user-tweaks.psd1') -PresetsOnly
        $ext.UserPresetFolderCount | Should Be 1
        $script:BuiltInPresets.Contains('loader test') | Should Be $true
        $pv = Get-WinEaseGuiPresetValues -Name 'loader test'
        $pv | Should Not Be $null
        $pv.PayloadFormat | Should Be 'ESD'
    }

    It "skips a hand-made file with a built-in preset name and leaves the built-in untouched" {
        $dir = Join-Path $script:TmpRepo 'config\user\presets'
        $before = "$($script:BuiltInPresets['balanced'].ProfileName)"
        Set-Content -LiteralPath (Join-Path $dir 'balanced.psd1') -Value "@{ ProfileName = 'hijacked'; RemoveDefender = `$true }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'custom.psd1') -Value "@{ ProfileName = 'reserved' }" -Encoding UTF8
        $ext = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:TmpRepo 'config\user\user-tweaks.psd1') -PresetsOnly
        $ext.UserPresetFolderCount | Should Be 0
        @($ext.Errors | Where-Object { $_ -match 'reserved or built-in preset name' }).Count | Should Be 2
        "$($script:BuiltInPresets['balanced'].ProfileName)" | Should Be $before
        $script:BuiltInPresets.Contains('custom') | Should Be $false
    }

    It "applies the BasePreset of a hand-made file before the overrides" {
        $dir = Join-Path $script:TmpRepo 'config\user\presets'
        Set-Content -LiteralPath (Join-Path $dir 'based.psd1') -Value "@{ BasePreset = 'extreme'; ProfileName = 'Based On Extreme' }" -Encoding UTF8
        $ext = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:TmpRepo 'config\user\user-tweaks.psd1') -PresetsOnly
        $ext.UserPresetFolderCount | Should Be 1
        $pv = Get-WinEaseGuiPresetValues -Name 'based'
        $pv | Should Not Be $null
        # extreme removes Defender; the saved balanced draft above did not inherit that
        $extreme = Get-WinEaseGuiPresetValues -Name 'extreme'
        $pv.Components['RemoveDefender'] | Should Be $extreme.Components['RemoveDefender']
    }
}

Describe "the windows call the shared save function and the strings exist" {
    It "the WinForms window wires the save button to the shared function" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'Button\.SavePreset'
        $guiText | Should Match 'Show-WinEaseGuiSavePresetDialog'
        $guiText | Should Match 'Save-WinEaseGuiUserPreset'
        $guiText | Should Match 'Update-WinEaseGuiPresetList'
        $guiText | Should Match 'Update-WinEaseGuiUserPresets'
        # the dialog asks before overwriting an existing preset
        $guiText | Should Match "Confirm-WinEaseGuiAction -Message \(Get-WinEaseUiString 'Dlg\.SavePreset\.Overwrite'"
    }
    It "the WinUI window and the host use the savePreset request and the shared function" {
        $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'), [System.Text.Encoding]::UTF8)
        $cs | Should Match 'Button\.SavePreset'
        $cs | Should Match '"savePreset"'
        $cs | Should Match 'SavePreset\.Reason\.Exists'
        $cs | Should Match 'Dlg\.SavePreset\.Overwrite'
        $hostText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\WinEaseWinUiHost.ps1'), [System.Text.Encoding]::UTF8)
        $hostText | Should Match 'Save-WinEaseGuiUserPreset'
        $hostText | Should Match "'presets'"
        $hostText | Should Match "'savePreset'"
    }
    It "every SavePreset ui-strings key exists in en.json and ja.json" {
        $en = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\ui-strings\en.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $ja = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\ui-strings\ja.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $keys = @('Button.SavePreset', 'Button.SavePreset.Tooltip', 'Dlg.SavePreset.Title', 'Dlg.SavePreset.Name', 'Dlg.SavePreset.Description',
            'Dlg.SavePreset.Save', 'Dlg.SavePreset.Overwrite', 'Msg.SavePreset.Success', 'Msg.SavePreset.Error',
            'SavePreset.Reason.InvalidName', 'SavePreset.Reason.Reserved', 'SavePreset.Reason.ConflictBuiltin',
            'SavePreset.Reason.Exists', 'SavePreset.Reason.Write', 'SavePreset.Reason.Readback')
        $missing = @()
        foreach ($k in $keys) {
            if (-not $en.PSObject.Properties[$k]) { $missing += "en $k" }
            if (-not $ja.PSObject.Properties[$k]) { $missing += "ja $k" }
        }
        ($missing -join '; ') | Should BeNullOrEmpty
        # placeholders match between the languages
        foreach ($k in @('Dlg.SavePreset.Overwrite', 'Msg.SavePreset.Success', 'Msg.SavePreset.Error')) {
            $enPh = @([regex]::Matches([string]$en.PSObject.Properties[$k].Value, '\{\d+\}') | ForEach-Object { $_.Value })
            foreach ($ph in $enPh) {
                (([string]$ja.PSObject.Properties[$k].Value) -match [regex]::Escape($ph)) | Should Be $true
            }
        }
    }
}

Describe "the WinForms window rebuilds the preset list without a restart" {
    BeforeEach {
        Initialize-PresetTestState
    }
    It "shows saved presets after the rebuild and keeps Custom last" {
        $script:WinEaseGuiDir = Join-Path $script:RepoRoot 'gui'
        . $script:GuiPath
        . ([scriptblock]::Create($script:GuiNoModalStubs))
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            # Save exactly what the fresh window shows (the real flow: the window saves its own state)
            $draft = Get-WinEaseGuiDraftConfig -Gui $gui
            $res = Save-WinEaseGuiUserPreset -Name 'GUI list test' -Current $draft -PayloadFormat 'WIM' -RepoRoot $script:TmpRepo
            $res.Saved | Should Be $true
            # The window reloads "its own" repository; point that reload at the test repository.
            Mock Update-WinEaseGuiUserPresets {
                $null = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:TmpRepo 'config\user\user-tweaks.psd1') -PresetsOnly
                Get-WinEaseGuiUserPresetChoices
            }
            Update-WinEaseGuiPresetList -Gui $gui
            $map = @($gui.PresetKeyMap)
            $map.Count | Should Be 7   # the built-in six + the saved preset
            $map[6] | Should Be 'gui list test'
            $gui.Preset.Items.Count | Should Be 8   # + Custom
            ([string]$gui.Preset.Items[6]) | Should Match 'GUI list test'
            ([string]$gui.Preset.Items[$gui.Preset.Items.Count - 1]) | Should Match 'Custom'
            $gui.Preset.SelectedIndex | Should Be 1   # the previous selection ('balanced') is restored
            # selecting the saved preset (what the dialog does) reads "<new preset> (unmodified)"
            $script:updatingPreset = $true
            try { $gui.Preset.SelectedIndex = 6 } finally { $script:updatingPreset = $false }
            $script:guiBasePresetKey = 'gui list test'
            $state = Get-WinEaseGuiPresetState -BasePresetKey 'gui list test' -Current (Get-WinEaseGuiDraftConfig -Gui $gui)
            $state.State | Should Be 'Preset'
        } finally {
            $gui.Form.Dispose()
        }
    }
}
