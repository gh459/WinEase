# Build.Tests.ps1 - builder AST, unattend, DryRun and diagnostics
# Run with:  Invoke-Pester -Path .\tests\Build.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase builder - AST syntax" {
    It "parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "autounattend.xml and scripts/FirstLogon.ps1 do not contain blank password overrides" {
        $firstLogonPath = Join-Path $script:RepoRoot "scripts\FirstLogon.ps1"
        $flContent = [System.IO.File]::ReadAllText($firstLogonPath, [System.Text.Encoding]::UTF8)
        $xmlContent = [System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8)

        $flContent | Should Not Match '/passwordreq:no'
        $flContent | Should Not Match 'net\.exe user User ""'
        $xmlContent | Should Not Match '/passwordreq:no'
        $xmlContent | Should Not Match 'net\.exe user User ""'
    }
    It "gui\WinEaseGui.ps1 parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "phases\10-registry.ps1 parses with zero parser errors" {
        $p10Path = Join-Path $script:RepoRoot "phases\10-registry.ps1"
        $content = [System.IO.File]::ReadAllText($p10Path, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "phases\10-registry.ps1 TakeOwnershipContextMenu avoids cmd.exe /c %1 command injection" {
        $p10Path = Join-Path $script:RepoRoot "phases\10-registry.ps1"
        $content = [System.IO.File]::ReadAllText($p10Path, [System.Text.Encoding]::UTF8)
        $content | Should Not Match 'cmd\.exe /c takeown.*%1'
        $content | Should Match 'powershell\.exe.*takeown\.exe'
    }
    It "phases\10-registry.ps1 CmdAsAdminContextMenu escapes %V against command injection" {
        $regPath = Join-Path -Path $script:RepoRoot -ChildPath "phases\10-registry.ps1"
        $content = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8)
        $content | Should Match 'pushd,\\"%V\\"'
    }
    It "gui\WinEaseWinUiHost.ps1 and gui\WinEaseGui.ps1 Start-Process calls pass array arguments preventing command injection" {
        foreach ($file in @($script:GuiPath, (Join-Path $script:RepoRoot "gui\WinEaseWinUiHost.ps1"))) {
            $content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $content | Should Not Match 'Start-Process\s+powershell\.exe\s+-ArgumentList\s+"[^"]*\$'
            $content | Should Match 'Start-Process\s+powershell\.exe\s+-ArgumentList\s+\$migratorArgs'
        }
    }
}

Describe "WinEase builder - autounattend.xml" {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'WinEasehelpers.ps1')
    }
    It "loads as valid XML with unattend root" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $doc.DocumentElement.Name | Should Be "unattend"
        $doc.unattend.settings | Should Not Be $null
    }
    It "has no duplicate components in any pass" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $dupCount = 0
        foreach ($pass in $doc.unattend.settings) {
            $keys = @($pass.component | ForEach-Object { "$($_.name) [$($_.processorArchitecture)]" })
            $dups = $keys | Group-Object | Where-Object { $_.Count -gt 1 }
            if ($dups) { $dupCount += $dups.Count }
        }
        $dupCount | Should Be 0
    }
    It "embeds all four setup scripts" {
        $raw = [System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8)
        foreach ($s in @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1')) {
            $raw -match [regex]::Escape($s) | Should Be $true
        }
    }
    It "embedded FirstLogon.ps1 parses as valid PowerShell" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $node = $doc.unattend.Extensions.File | Where-Object { $_.path -like '*FirstLogon.ps1' }
        $content = [string]$node.'#text'
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "parameterizes UserPassword when set" {
        $xmlPath = Join-Path $script:RepoRoot "autounattend.xml"
        $raw = [System.IO.File]::ReadAllText($xmlPath, [System.Text.Encoding]::UTF8)
        $doc = [xml]$raw
        . (Join-Path $script:RepoRoot 'lib\WinEaseSecrets.ps1')
        (Set-WinEaseUnattendPassword -Document $doc -Password "TestSecretPassword123!") | Should BeGreaterThan 0
        $updatedVal = $doc.SelectSingleNode("//*[local-name()='LocalAccount']/*[local-name()='Password']/*[local-name()='Value']").InnerText
        $updatedVal | Should Be "TestSecretPassword123!"
    }
    It "passes Test-WinEaseUnattendXmlStructure on the checked-in autounattend.xml" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        (Test-WinEaseUnattendXmlStructure -XmlDocument $doc) | Should Be $true
    }
    It "Test-WinEaseUnattendXmlStructure throws on malformed or missing required elements" {
        $badDoc1 = [xml]'<root><settings /></root>'
        { Test-WinEaseUnattendXmlStructure -XmlDocument $badDoc1 } | Should Throw "must be <unattend>"

        $badDoc2 = [xml]'<unattend></unattend>'
        { Test-WinEaseUnattendXmlStructure -XmlDocument $badDoc2 } | Should Throw "contains no <settings>"

        $badDoc3 = [xml]'<unattend><settings><component name="Microsoft-Windows-Setup" /></settings></unattend>'
        { Test-WinEaseUnattendXmlStructure -XmlDocument $badDoc3 } | Should Throw "no embedded script <File> nodes"
    }
    It "phases/11-unattend.ps1 does not contain uncontrolled upstream nano11 fallback" {
        $p11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\11-unattend.ps1"), [System.Text.Encoding]::UTF8)
        $p11 | Should Not Match 'ntdevlabs/nano11'
        $p11 | Should Match '177f3631d3b172611e9c0d38a3d9a6e310b7467c'
        $p11 | Should Match 'C21459A21AB1FB10D4B01F52D829529CBAAE2B212A88FFB533A6FC85B94A6397'
        $p11 | Should Match 'AllowTemplateDownload'
    }
}

Describe "WinEase builder - IME decoupling filter logic (mock)" {
    It "ja-JP target keeps foreign IME patterns in the removal list" {
        $primaryImeLang = $null
        $patterns = @('*IME-ko-kr*', '*IME-zh-cn*', '*IME-zh-tw*', '*IME-zh-hk*', 'Microsoft-Windows-InternetExplorer-Optional-Package~*')
        # size-first decoupling: drop ONLY own-language IME patterns
        if ($primaryImeLang) {
            $patterns = @($patterns | Where-Object { $_ -notlike "*IME-$primaryImeLang*" })
        }
        ($patterns -contains '*IME-ko-kr*') | Should Be $true
        ($patterns -contains '*IME-zh-cn*') | Should Be $true
    }
    It "ko-KR target drops the ko-kr IME pattern (keeps Korean IME)" {
        $primaryImeLang = 'ko-kr'
        $patterns = @('*IME-ko-kr*', '*IME-zh-cn*', '*IME-zh-tw*', '*IME-zh-hk*')
        if ($primaryImeLang) {
            $patterns = @($patterns | Where-Object { $_ -notlike "*IME-$primaryImeLang*" })
        }
        ($patterns -contains '*IME-ko-kr*') | Should Be $false
        ($patterns -contains '*IME-zh-cn*') | Should Be $true
        ($patterns -contains '*IME-zh-tw*') | Should Be $true
    }
    It "primaryImeLang mapping covers ko/zh-cn/zh-tw/zh-hk" {
        $map = @{ 'ko-kr' = 'ko-kr'; 'zh-cn' = 'zh-cn'; 'zh-tw' = 'zh-tw'; 'zh-hk' = 'zh-tw' }
        $map['ko-kr'] | Should Be 'ko-kr'
        $map['zh-cn'] | Should Be 'zh-cn'
        $map['zh-tw'] | Should Be 'zh-tw'
        $map['zh-hk'] | Should Be 'zh-tw'
    }
}

Describe "WinEase builder - end-to-end DryRun" -Tags 'slow' {
    It "resolves extreme profile configuration without errors" {
        $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:BuilderPath`" -DryRun -NonInteractive -Profile extreme"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        $finished = $p.WaitForExit(300000)
        if (-not $finished) { $p.Kill(); throw "builder did not exit within timeout" }
        [void]$stdoutTask.Result
        [void]$stderrTask.Result
        $p.ExitCode | Should Be 0
    }
}

Describe "WinEase setup scripts - Custom Scripts Logging" {
    It "scripts/FirstLogon.ps1 contains dual-log recording and stop preference wrapper" {
        $firstLogonPath = Join-Path $script:RepoRoot "scripts\FirstLogon.ps1"
        $content = [System.IO.File]::ReadAllText($firstLogonPath, [System.Text.Encoding]::UTF8)
        $content | Should Match "custom-scripts\.log"
        $content | Should Match "Duration:"
        $content | Should Match "FAILED"
        $content | Should Match "SUCCESS"
        $content | Should Match "LASTEXITCODE = 0"
        $content.Contains("escapedScriptPath = `$scriptPath -replace") | Should Be $true
    }

    It "scripts/UserOnce.ps1 contains execution logging and redaction" {
        $userOncePath = Join-Path $script:RepoRoot "scripts\UserOnce.ps1"
        $content = [System.IO.File]::ReadAllText($userOncePath, [System.Text.Encoding]::UTF8)
        $content | Should Match "UserOnce-custom\.log"
        $content | Should Match "Redact-WinEaseUserSecret"
        $content | Should Match "Duration:"
        $content.Contains("escapedScriptPath = `$scriptPath -replace") | Should Be $true
    }
}

Describe "Builder cleanup S11" {
    BeforeAll {
        $script:S11Root = $script:RepoRoot
    }
    It "BOM-less .ps1/.psd1 files are ASCII only" {
        $bad = @()
        foreach ($f in (Get-ChildItem -LiteralPath $script:S11Root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psd1' -and $_.FullName -notmatch '[\\/](\.git|\.claude|logs)[\\/]' })) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if (-not $hasBom -and (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0)) { $bad += $f.Name }
        }
        ($bad -join ',') | Should Be ''
    }
    It "parallel WindowsApps cleanup checks containment and reports failed folders" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "phases\05-appx.ps1"))
        $src -match 'Test-WinEasePathWithin -Path \$fp -Root \$scratchDir' | Should Be $true
        $src -match 'Parallel cleanup failed for folder' | Should Be $true
    }
    It "self-test is split into per-check functions and still runs 22 checks" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "lib\WinEaseSelfTest.ps1"))
        @([regex]::Matches($src, '(?m)^function Test-WinEaseSelfCheck\d\d')).Count | Should Be 22
    }
    It "no -isAnyBound repetition remains in the builder beyond the component-switch loop" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "WinEasebuilder.ps1"))
        @([regex]::Matches($src, '& \$isAnyBound')).Count | Should Be 1
    }
}

Describe "WinEase builder - the diagnostic report survives a parallel build" {
    # The diagnostic directory of a build is empty until the build ends, so the rotation
    # of build_diagnostics (which drops the empty folders) used to delete the directory
    # of a build that was still running: the report of that build was then written into
    # a folder that no longer existed and every write failed.
    $script:BuilderSource = [System.IO.File]::ReadAllText($script:BuilderPath)

    It "the report writer creates the diagnostic directory before it writes" {
        $script:BuilderSource | Should Match 'if\s*\(-not\s*\(Test-Path\s+-LiteralPath\s+\$script:DiagDir\)\)'
        $script:BuilderSource | Should Match 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\$script:DiagDir'
    }

    It "the rotation leaves the directory of a running build alone" {
        # only the folders that existed before this build started are rotated
        $script:BuilderSource | Should Match '\$script:BuilderStartTime'
        $script:BuilderSource | Should Match '\$_\.LastWriteTime\s+-lt\s+\$script:BuilderStartTime'
    }

    It "dry runs and test mode never rotate the diagnostics of a running build" {
        $script:BuilderSource | Should Match 'if\s*\(\(-not\s+\$isDryRunMode\)\s+-and\s+\(\$env:WINEASE_TEST_MODE\s+-ne\s+"1"\)'
    }

    It "the export and verification phases recreate the diagnostic directory before they write" {
        foreach ($phaseName in @('13-export.ps1', '15-verify.ps1')) {
            $phase = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\$phaseName"))
            $phase | Should Match 'if\s*\(\$script:DiagDir\s+-and\s+-not\s+\(Test-Path\s+-LiteralPath\s+\$script:DiagDir\)\)'
            $phase | Should Match 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\$script:DiagDir'
        }
    }

    It "the physical debloat phase reports the errors of a failed engine run" {
        # the errors of the engine are the only place that says which target did not go
        # through, and they were only read when the engine exited with 0
        $phase = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\09-physical-debloat.ps1"))
        $phase | Should Match '\$physErrors\s*=\s*@\(\)'
        $phase | Should Match '\[ERROR\]\s+\$physError'
        $phase | Should Match 'The engine reported:'
    }
}

Describe "WinEase builder - upstream registry additions (sync 2026-10-22)" {
    BeforeAll {
        $script:RegistryPhasePath = Join-Path $script:RepoRoot "phases\10-registry.ps1"
        # the plain writes live in config\registry, the rest in the phase
        $script:RegistryPhaseText = [System.IO.File]::ReadAllText($script:RegistryPhasePath) + "`n" + (Get-WinEaseRegistryTableText)
        $script:UpstreamSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    }

    It "writes the search WebView2 feature overrides in both registry locations" {
        $script:RegistryPhaseText | Should Match 'FeatureManagement\\Overrides'
        $script:RegistryPhaseText | Should Match 'FeatureManagement\\Overrides\\8'
        # the two feature IDs of the ReviOS playbook, as obfuscated values
        $script:RegistryPhaseText | Should Match 'SearchWebView2_Master'
        $script:RegistryPhaseText | Should Match '37926450'
    }

    It "applies the AI app privacy values of the ReviOS ai-removal package" {
        $script:RegistryPhaseText | Should Match 'LetAppsAccessSystemAIModels'
        $script:RegistryPhaseText | Should Match 'LetAppsAccessGenerativeAI'
    }

    It "uses the ReviOS CrossDeviceResume host redirect" {
        $script:RegistryPhaseText | Should Match 'CrossDeviceResumeHost'
        $script:RegistryPhaseText | Should Match 'ShellHost\.exe'
    }

    It "never asks for a Defender sample (SubmitSamplesConsent = 2)" {
        $script:RegistryPhaseText | Should Not Match "Name = 'SubmitSamplesConsent'; Type = 'REG_DWORD'; Data = '0'"
        $script:RegistryPhaseText | Should Match "Name = 'SubmitSamplesConsent'; Type = 'REG_DWORD'; Data = '2'"
    }

    It "disables the agent connectors with the value the upstream tools use" {
        $script:RegistryPhaseText | Should Match "Name = 'DisableAgentConnectors'; Type = 'REG_DWORD'; Data = '2'"
        $script:RegistryPhaseText | Should Match "Name = 'DisableAgentWorkspaces'; Type = 'REG_DWORD'; Data = '2'"
        $script:RegistryPhaseText | Should Match "Name = 'DisableRemoteAgentConnectors'; Type = 'REG_DWORD'; Data = '2'"
    }

    It "writes the accessibility, pointer and keyboard values as REG_SZ" {
        # the values moved to config\ui-preferences.psd1 (see the Describe block below)
        $prefs = @(Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\ui-preferences.psd1")).UiPreferences
        foreach ($pair in @(
                @('Control Panel\Accessibility\StickyKeys', 'Flags'),
                @('Control Panel\Mouse', 'MouseSpeed'),
                @('Control Panel\Keyboard', 'KeyboardDelay'))) {
            $entry = @($prefs | Where-Object { $_.Path -eq $pair[0] -and $_.Name -eq $pair[1] })
            $entry.Count | Should Be 1
            $entry[0].Type | Should Be 'REG_SZ'
        }
    }

    It "registers the new tweaks in the master schema" {
        $keys = @($script:UpstreamSchema.Tweaks | ForEach-Object { $_.Key })
        ($keys -contains 'DisableSearchWebView2') | Should Be $true
        ($keys -contains 'DisableAccessibilityHotkeys') | Should Be $true
        ($keys -contains 'DisableMouseAcceleration') | Should Be $true
        ($keys -contains 'DisableKeyboardDelay') | Should Be $true
    }

    It "gives every new tweak a Japanese GUI description" {
        $jaPath = Join-Path $script:RepoRoot "config\ui-strings\ja.json"
        $ja = [System.IO.File]::ReadAllText($jaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($key in 'DisableSearchWebView2', 'DisableAccessibilityHotkeys', 'DisableMouseAcceleration', 'DisableKeyboardDelay') {
            $ja.PSObject.Properties["Tweak.$key.Description"] | Should Not BeNullOrEmpty
        }
    }

    It "never hands an empty string to reg.exe" {
        # PowerShell drops an empty argument of a native call, so reg.exe would take
        # the next switch ('/f') as the value of the registry entry instead of the
        # empty string that was asked for.
        foreach ($file in 'phases\10-registry.ps1', 'scripts\FirstLogon.ps1') {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $file))
            $text | Should Not Match '/d\s+""\s+/f'
        }
    }
}

Describe "WinEase builder - the tweak helper is available to every phase" {
    # Test-TweakEnabled is the accessor every phase uses to ask "is this option on?".
    # Phases 05, 06, 08 and lib\WinEaseDebloat.ps1 call it, and they run long before
    # phase 10 - the phase that used to carry the only definition. A helper that is
    # defined in a late phase therefore aborts the build with
    # "The term 'Test-TweakEnabled' is not recognized".
    $script:BuilderSource = [System.IO.File]::ReadAllText($script:BuilderPath)
    $script:PhasesDir = Join-Path $script:RepoRoot "phases"

    It "the builder declares the helper exactly once" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errors)
        $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-TweakEnabled' }, $true))
        $defs.Count | Should Be 1
    }

    It "the builder declares the helper before the first phase is dot-sourced" {
        $defPos = $script:BuilderSource.IndexOf('function Test-TweakEnabled')
        $defPos | Should Not Be -1
        $firstPhasePos = $script:BuilderSource.IndexOf('"01-environment.ps1"')
        $firstPhasePos | Should Not Be -1
        ($defPos -lt $firstPhasePos) | Should Be $true
    }

    It "the helper is declared before every phase that calls it" {
        $defPos = $script:BuilderSource.IndexOf('function Test-TweakEnabled')
        $defPos | Should Not Be -1
        $callers = @()
        foreach ($f in (Get-ChildItem -LiteralPath $script:PhasesDir -Filter '*.ps1' | Sort-Object Name)) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($text -notmatch 'Test-TweakEnabled') { continue }
            $callers += $f.Name
            $loadPos = $script:BuilderSource.IndexOf('"' + $f.Name + '"')
            $loadPos | Should Not Be -1
            ($defPos -lt $loadPos) | Should Be $true
        }
        # the phases that call the helper have to exist at all
        ($callers -contains '05-appx.ps1') | Should Be $true
        ($callers -contains '06-fod.ps1') | Should Be $true
        ($callers -contains '08-filesystem.ps1') | Should Be $true
    }

    It "the phase-local copies stay guarded so they cannot shadow the canonical helper" {
        foreach ($name in '10-registry.ps1', '11-unattend.ps1') {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:PhasesDir $name))
            $text | Should Match 'if\s*\(-not\s*\(Get-Command\s+-Name\s+Test-TweakEnabled'
        }
    }

    It "resolves the setting, the legacy alias, the script variable and the default" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errors)
        $fnText = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-TweakEnabled' }, $true))[0].Extent.Text
        # The helper reads the builder's script scope, so it runs in its own module
        # to keep the probe isolated from the rest of the suite.
        $probe = New-Module -Name 'WinEaseTweakHelperProbe' -ArgumentList $fnText -ScriptBlock {
            param($FnText)
            $script:TweakSettings   = [ordered]@{ 'OldKey' = $true }
            $script:TweakKeyAliases = [ordered]@{ 'OldKey' = 'SomeKey' }
            Set-Variable -Name 'Tweak_VarKey' -Scope Script -Value $true
            . ([scriptblock]::Create($FnText))
            Export-ModuleMember -Function 'Test-TweakEnabled'
        }
        Import-Module $probe -Force
        try {
            (Test-TweakEnabled 'OldKey' $false)   | Should Be $true    # a stored setting
            (Test-TweakEnabled 'SomeKey' $false)  | Should Be $true    # reached through its legacy alias
            (Test-TweakEnabled 'VarKey' $false)   | Should Be $true    # the Tweak_<Name> script variable
            (Test-TweakEnabled 'Missing' $true)   | Should Be $true    # the hard-coded default
            (Test-TweakEnabled 'Missing' $false)  | Should Be $false
        } finally {
            Remove-Module $probe -Force -ErrorAction SilentlyContinue
        }
    }

    It "Resolve-WinEaseTweakKey resolves alias keys and handles edge cases safely" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errors)
        $fnText = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-WinEaseTweakKey' }, $true))[0].Extent.Text
        $probe = New-Module -Name 'WinEaseResolveKeyProbe' -ArgumentList $fnText -ScriptBlock {
            param($FnText)
            $script:TweakKeyAliases = [ordered]@{ 'AliasKey' = 'CanonicalKey' }
            . ([scriptblock]::Create($FnText))
            Export-ModuleMember -Function 'Resolve-WinEaseTweakKey'
        }
        Import-Module $probe -Force
        try {
            (Resolve-WinEaseTweakKey 'AliasKey')       | Should Be 'CanonicalKey'
            (Resolve-WinEaseTweakKey 'CanonicalKey')   | Should Be 'CanonicalKey'
            (Resolve-WinEaseTweakKey 'NonExistentKey') | Should Be 'NonExistentKey'
            (Resolve-WinEaseTweakKey '')               | Should Be ''
            (Resolve-WinEaseTweakKey $null)            | Should Be ''
            & $probe { $script:TweakKeyAliases = $null }
            (Resolve-WinEaseTweakKey 'AliasKey')       | Should Be 'AliasKey'
        } finally {
            Remove-Module $probe -Force -ErrorAction SilentlyContinue
        }
    }

    It "every tweak of the master schema is in the JSON profile schema" {
        # config\WinEase.config.schema.json is the schema of the profile files; a tweak
        # that is missing there is rejected by every editor that validates against it.
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $json = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\WinEase.config.schema.json")) | ConvertFrom-Json
        $known = @($json.properties.PSObject.Properties.Name)
        $missing = @()
        foreach ($td in $schema.Tweaks) {
            if ($known -notcontains $td.Key) { $missing += $td.Key }
        }
        ($missing -join ', ') | Should Be ''
    }
}

Describe "WinEase builder - Enter-Phase progress tracking and checkpoints" {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errors)
        $fnAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Enter-Phase' }, $true))[0]
        $script:EnterPhaseFnText = $fnAst.Extent.Text
    }

    BeforeEach {
        $script:SavedCheckpoints = [System.Collections.ArrayList]::new()
        $script:EnterPhaseProbe = New-Module -Name 'WinEaseEnterPhaseProbe' -ArgumentList $script:EnterPhaseFnText -ScriptBlock {
            param($FnText)
            $script:CurrentPhase = 0
            $script:TotalPhases = 18
            $script:PhaseTimings = [ordered]@{}
            $script:PhaseStopwatch = $null
            $script:ResumeMode = $false
            $script:BaseWorkDir = $null
            $script:CurrentBuildPhase = $null
            $script:DiagnosticData = $null
            $script:CheckpointLog = [System.Collections.ArrayList]::new()

            function Save-WinEaseCheckpoint {
                param([int]$CompletedPhase)
                [void]$script:CheckpointLog.Add($CompletedPhase)
            }

            . ([scriptblock]::Create($FnText))

            Export-ModuleMember -Function 'Enter-Phase' -Variable 'CurrentPhase', 'TotalPhases', 'PhaseTimings', 'PhaseStopwatch', 'ResumeMode', 'BaseWorkDir', 'CurrentBuildPhase', 'DiagnosticData', 'CheckpointLog'
        }
        Import-Module $script:EnterPhaseProbe -Force
    }

    AfterEach {
        Remove-Module $script:EnterPhaseProbe -Force -ErrorAction SilentlyContinue
    }

    It "handles initial phase entry (CurrentPhase = 0) without saving checkpoints or recording prior phase timings" {
        & $script:EnterPhaseProbe {
            Enter-Phase -PhaseNumber 1 -PhaseName "Environment"

            $script:CurrentPhase | Should Be 1
            $script:CurrentBuildPhase | Should Be "Phase 1: Environment"
            $script:PhaseStopwatch | Should Not Be $null
            $script:PhaseTimings.Count | Should Be 0
            $script:CheckpointLog.Count | Should Be 0
        }
    }

    It "persists checkpoint and records previous phase timings on phase transition when BaseWorkDir is set and ResumeMode is false" {
        & $script:EnterPhaseProbe {
            $script:BaseWorkDir = "/tmp/winease-work"
            $script:ResumeMode = $false

            Enter-Phase -PhaseNumber 1 -PhaseName "Environment"
            Start-Sleep -Milliseconds 50
            Enter-Phase -PhaseNumber 2 -PhaseName "Mount"

            $script:CurrentPhase | Should Be 2
            $script:CurrentBuildPhase | Should Be "Phase 2: Mount"
            $script:PhaseTimings.Contains("Phase 1") | Should Be $true
            $script:CheckpointLog.Count | Should Be 1
            $script:CheckpointLog[0] | Should Be 1
        }
    }

    It "suppresses checkpoint saving when ResumeMode is enabled" {
        & $script:EnterPhaseProbe {
            $script:BaseWorkDir = "/tmp/winease-work"
            $script:ResumeMode = $true

            Enter-Phase -PhaseNumber 1 -PhaseName "Environment"
            Enter-Phase -PhaseNumber 2 -PhaseName "Mount"

            $script:CheckpointLog.Count | Should Be 0
        }
    }

    It "suppresses checkpoint saving when BaseWorkDir is null or empty" {
        & $script:EnterPhaseProbe {
            $script:BaseWorkDir = $null
            $script:ResumeMode = $false

            Enter-Phase -PhaseNumber 1 -PhaseName "Environment"
            Enter-Phase -PhaseNumber 2 -PhaseName "Mount"

            $script:CheckpointLog.Count | Should Be 0
        }
    }

    It "updates FailurePhase on DiagnosticData when present" {
        & $script:EnterPhaseProbe {
            $script:DiagnosticData = [pscustomobject]@{ FailurePhase = $null }

            Enter-Phase -PhaseNumber 5 -PhaseName "Appx"

            $script:DiagnosticData.FailurePhase | Should Be "Phase 5: Appx"
        }
    }

    It "gracefully handles exceptions when setting host window title" {
        & $script:EnterPhaseProbe {
            # WindowTitle access in headless/Linux pwsh will throw or silently fail inside catch {} block
            { Enter-Phase -PhaseNumber 10 -PhaseName "Registry" } | Should Not Throw
            $script:CurrentPhase | Should Be 10
        }
    }
}

Describe "WinEase builder - ConvertTo-WinEaseCliArgument" {
    BeforeAll {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcNode = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-WinEaseCliArgument'
        }, $true)
        . ([scriptblock]::Create($funcNode.Extent.Text))
    }

    It "serializes present SwitchParameter as -Name" {
        $sw = [System.Management.Automation.SwitchParameter]::new($true)
        ConvertTo-WinEaseCliArgument -Name "NonInteractive" -Value $sw | Should Be "-NonInteractive"
    }

    It "serializes absent SwitchParameter as -Name:`$false" {
        $sw = [System.Management.Automation.SwitchParameter]::new($false)
        ConvertTo-WinEaseCliArgument -Name "NonInteractive" -Value $sw | Should Be "-NonInteractive:`$false"
    }

    It "serializes boolean `$true as -Name" {
        ConvertTo-WinEaseCliArgument -Name "KeepDefender" -Value $true | Should Be "-KeepDefender"
    }

    It "serializes boolean `$false as -Name:`$false" {
        ConvertTo-WinEaseCliArgument -Name "KeepDefender" -Value $false | Should Be "-KeepDefender:`$false"
    }

    It "serializes dictionary with boolean values as Key=1;Key2=0 syntax" {
        $dict = [ordered]@{ 'NetworkStack' = $true; 'TimerBCD' = $false }
        ConvertTo-WinEaseCliArgument -Name "TweakGroupOverrides" -Value $dict | Should Be "-TweakGroupOverrides 'NetworkStack=1;TimerBCD=0'"
    }

    It "serializes empty dictionary as parameter with empty string" {
        $dict = @{}
        ConvertTo-WinEaseCliArgument -Name "TweakGroupOverrides" -Value $dict | Should Be "-TweakGroupOverrides ''"
    }

    It "serializes string with single quotes escaped correctly" {
        ConvertTo-WinEaseCliArgument -Name "UserName" -Value "User's PC" | Should Be "-UserName 'User''s PC'"
    }

    It "serializes string and numeric values wrapped in single quotes" {
        ConvertTo-WinEaseCliArgument -Name "KeepLogs" -Value 10 | Should Be "-KeepLogs '10'"
        ConvertTo-WinEaseCliArgument -Name "WorkDir" -Value "C:\WinEase Work" | Should Be "-WorkDir 'C:\WinEase Work'"
    }

    It "serializes `$null value as parameter with empty string" {
        ConvertTo-WinEaseCliArgument -Name "SourceDrive" -Value $null | Should Be "-SourceDrive ''"
    }
}

Describe "WinEase builder - leftover registry hive cleanup" {
    BeforeAll {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $pipelineNode = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.PipelineAst] -and
            $node.Extent.Text -match 'Unmount-RegistryHiveWithRetry' -and
            $node.Extent.Text -match 'zCOMPONENTS'
        }, $true)
        $script:CleanupScriptBlock = [scriptblock]::Create($pipelineNode.Extent.Text)
    }

    It "attempts unmount on all 5 hives when Unmount-RegistryHiveWithRetry succeeds" {
        $probe = New-Module -Name 'WinEaseCleanupSuccessProbe' -ArgumentList $script:CleanupScriptBlock -ScriptBlock {
            param($ScriptBlock)
            $script:Unmounted = [System.Collections.Generic.List[string]]::new()
            function Unmount-RegistryHiveWithRetry {
                param([string]$Name)
                $script:Unmounted.Add($Name)
                return $true
            }
            . $ScriptBlock
            Export-ModuleMember -Variable 'Unmounted'
        }
        Import-Module $probe -Force
        try {
            & $probe { $script:Unmounted.Count } | Should Be 5
            & $probe { $script:Unmounted -join ',' } | Should Be 'zCOMPONENTS,zDEFAULT,zNTUSER,zSOFTWARE,zSYSTEM'
        } finally {
            Remove-Module $probe -Force -ErrorAction SilentlyContinue
        }
    }

    It "catches exception from Unmount-RegistryHiveWithRetry and continues through all 5 hives" {
        $probe = New-Module -Name 'WinEaseCleanupErrorProbe' -ArgumentList $script:CleanupScriptBlock -ScriptBlock {
            param($ScriptBlock)
            $script:Attempted = [System.Collections.Generic.List[string]]::new()
            function Unmount-RegistryHiveWithRetry {
                param([string]$Name)
                $script:Attempted.Add($Name)
                throw "Simulated unmount error for $Name"
            }
            . $ScriptBlock
            Export-ModuleMember -Variable 'Attempted'
        }
        Import-Module $probe -Force
        try {
            { & $probe { } } | Should Not Throw
            & $probe { $script:Attempted.Count } | Should Be 5
            & $probe { $script:Attempted -join ',' } | Should Be 'zCOMPONENTS,zDEFAULT,zNTUSER,zSOFTWARE,zSYSTEM'
        } finally {
            Remove-Module $probe -Force -ErrorAction SilentlyContinue
        }
    }
}
