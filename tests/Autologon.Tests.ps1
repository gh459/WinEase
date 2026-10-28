# Autologon.Tests.ps1 - default (empty) password, AutoLogon on/off and the cleanup after the first logon.
# Pester 3.4 / Windows PowerShell 5.1. Nothing here touches the real registry, the Panther folder or an image.
#
# Covered: ConfigureWinlogon on/off x password empty/non-empty
#   - generated unattend XML (AutoLogon nodes, password values, no old default password anywhere)
#   - the OOBE helper scripts that are deployed or dropped (phase 11)
#   - the phase 10 registry write plan (Winlogon DefaultPassword only when on)
#   - the cleanup script block of scripts\FirstLogon.ps1 and its embedded copy in autounattend.xml
# The parts of phases\11-unattend.ps1 that decide this are cut out with the PowerShell parser and run on
# their own, so the tests exercise the shipped code and not a copy of it.
. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath '_RegistryHarness.ps1')
. (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseSecrets.ps1')

# the former fixed default password, assembled so this file does not contain it as a literal
$script:OldDefaultPassword = 'WinEase' + '123' + '!'

function Test-TweakEnabled {
    param([string]$Name, [bool]$Default = $true)
    if ($null -ne $script:TweakSettings -and ([System.Collections.IDictionary]$script:TweakSettings).Contains($Name)) { return [bool]$script:TweakSettings[$Name] }
    return $Default
}

function Get-AutologonPhaseSnippets {
    $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'), [System.Text.Encoding]::UTF8)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $ifs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    $xmlIf = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -match "ConfigureWinlogon" -and $_.Extent.Text -match "local-name\(\)='AutoLogon'" })
    $helperIf = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -eq '-not $configureWinlogon' })
    $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$configureWinlogon' }, $true))
    return @{ XmlIf = $xmlIf; HelperIf = $helperIf; Assign = $assign }
}

function Invoke-AutologonXmlModel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The extracted phase code is run with its console output silenced')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Test password, plain text by design')]
    # Template -> AutoLogon section decision -> password, as phases\11-unattend.ps1 does it
    param([bool]$Winlogon, [string]$Password)
    $snip = $script:AutologonSnippets
    $script:TweakSettings = [ordered]@{ ConfigureWinlogon = $Winlogon }
    function Write-Host { }
    $xmlDoc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
    . ([scriptblock]::Create($snip.XmlIf[0].Extent.Text))
    [void](Set-WinEaseUnattendPassword -Document $xmlDoc -Password $Password)
    return $xmlDoc
}

function Invoke-AutologonHelperModel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The extracted phase code is run with its console output silenced')]
    param([bool]$Winlogon)
    $snip = $script:AutologonSnippets
    $script:TweakSettings = [ordered]@{ ConfigureWinlogon = $Winlogon }
    function Write-Host { }
    $helperScripts = [ordered]@{
        'ExtractUnattend.ps1'                = 'a'
        'RunFirstLogon.ps1'                  = 'b'
        'WinEase-oobe-autologon-repair.ps1'  = 'c'
        'WinEase-transition-watchdog.ps1'    = 'd'
    }
    . ([scriptblock]::Create($snip.Assign[0].Extent.Text))
    . ([scriptblock]::Create($snip.HelperIf[0].Extent.Text))
    return @($helperScripts.Keys)
}

Describe "Autologon - no fixed default password" {
    It "the builder default is empty and the old default appears nowhere in the repository" {
        $builder = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $builder | Should Match "\[string\]\`$UserPassword = ''"
        $needle = $script:OldDefaultPassword
        $hits = [System.Collections.Generic.List[string]]::new()
        $skipDirs = '\\(\.git|\.claude|logs|bin|obj|node_modules)\\'
        foreach ($f in Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $rel = $f.FullName.Substring($script:RepoRoot.Length)
            if ($rel -match $skipDirs -or $f.Length -gt 2MB) { continue }
            if ($f.Extension -match '^\.(exe|dll|wim|iso|png|ico|jpg|zip|pdb|esd)$') { continue }
            $content = [System.IO.File]::ReadAllText($f.FullName)
            # CHANGELOG.md names the old default on purpose (migration note)
            if ($content.Contains($needle) -and $f.Name -ne 'CHANGELOG.md' -and $f.Name -ne 'SECURITY.md') { $hits.Add($f.FullName) }
        }
        ($hits -join '; ') | Should Be ''
    }
    It "the template carries empty Password values only" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $values = @($doc.SelectNodes("//*[local-name()='Password']/*[local-name()='Value'] | //*[local-name()='AdministratorPassword']/*[local-name()='Value']"))
        $values.Count | Should BeGreaterThan 3
        foreach ($v in $values) { $v.InnerText | Should BeExactly '' }
    }
}

Describe "Autologon - generated unattend XML (ConfigureWinlogon x password)" {
    BeforeAll { $script:AutologonSnippets = Get-AutologonPhaseSnippets }

    It "finds exactly the code to test in phase 11" {
        @($script:AutologonSnippets.XmlIf).Count | Should Be 1
        @($script:AutologonSnippets.HelperIf).Count | Should Be 1
        @($script:AutologonSnippets.Assign).Count | Should Be 1
    }

    foreach ($winlogon in @($true, $false)) {
        foreach ($pw in @('', 'Sample-Pw 1!')) {
            $label = "ConfigureWinlogon=$winlogon, password " + $(if ($pw) { 'set' } else { 'empty' })
            It "[$label] keeps or removes the AutoLogon section and sets the right password values" {
                $doc = Invoke-AutologonXmlModel -Winlogon $winlogon -Password $pw
                $reloaded = [xml]$doc.OuterXml
                $autoLogon = @($reloaded.SelectNodes("//*[local-name()='AutoLogon']"))
                if ($winlogon) {
                    $autoLogon.Count | Should BeGreaterThan 0
                    foreach ($node in $autoLogon) {
                        $node.SelectSingleNode("*[local-name()='Password']/*[local-name()='Value']").InnerText | Should BeExactly $pw
                    }
                } else {
                    $autoLogon.Count | Should Be 0
                }
                $accountValues = @($reloaded.SelectNodes("//*[local-name()='LocalAccount']/*[local-name()='Password']/*[local-name()='Value']"))
                $accountValues.Count | Should BeGreaterThan 0
                foreach ($v in $accountValues) { $v.InnerText | Should BeExactly $pw }
                $doc.OuterXml.Contains($script:OldDefaultPassword) | Should Be $false
                # the administrator password stays empty in every case
                foreach ($v in @($reloaded.SelectNodes("//*[local-name()='AdministratorPassword']/*[local-name()='Value']"))) { $v.InnerText | Should BeExactly '' }
                # the FirstLogon command (cleanup runs from it) is still part of the file
                $doc.OuterXml | Should Match 'RunFirstLogon\.ps1'
            }
        }
    }
}

Describe "Autologon - helper scripts deployed by phase 11" {
    BeforeAll { $script:AutologonSnippets = Get-AutologonPhaseSnippets }

    It "ConfigureWinlogon on deploys the repair helper and the watchdog" {
        $names = Invoke-AutologonHelperModel -Winlogon $true
        ($names -contains 'WinEase-oobe-autologon-repair.ps1') | Should Be $true
        ($names -contains 'WinEase-transition-watchdog.ps1') | Should Be $true
        $names.Count | Should Be 4
    }
    It "ConfigureWinlogon off drops both helpers and keeps the others" {
        $names = Invoke-AutologonHelperModel -Winlogon $false
        ($names -contains 'WinEase-oobe-autologon-repair.ps1') | Should Be $false
        ($names -contains 'WinEase-transition-watchdog.ps1') | Should Be $false
        ($names -join ',') | Should Be 'ExtractUnattend.ps1,RunFirstLogon.ps1'
    }
    It "the repair helper parses for an empty and for a non-empty password" {
        $template = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'scripts\setup\WinEase-oobe-autologon-repair.ps1'), [System.Text.Encoding]::UTF8)
        foreach ($pw in @('', "it's a 'test' `$x")) {
            $generated = Expand-WinEaseOobeRepairScript -Template $template -UserName 'User' -Password $pw
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($generated, [ref]$null, [ref]$e)
            $e.Count | Should Be 0
        }
    }
}

Describe "Autologon - phase 10 registry write plan" {
    foreach ($pw in @('', 'Sample-Pw 1!')) {
        $pwLabel = if ($pw) { 'non-empty' } else { 'empty' }
        It "[ConfigureWinlogon on, password $pwLabel] writes AutoAdminLogon and DefaultPassword (value only from the build setting)" {
            $calls = @(Invoke-WinEaseRegistryPhaseRecording -Preset default -TweakOverride @{ ConfigureWinlogon = $true } -UserPassword $pw)
            $key = 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            $dp = @($calls | Where-Object { $_ -like "ADD`t$key`tDefaultPassword`t*" })
            $dp.Count | Should Be 1
            $expected = if ($pw) { $pw } else { '""' }
            $dp[0] | Should BeExactly "ADD`t$key`tDefaultPassword`tREG_SZ`t$expected"
            @($calls | Where-Object { $_ -like "ADD`t$key`tAutoAdminLogon`tREG_SZ`t1" }).Count | Should Be 1
            @($calls | Where-Object { $_ -like "ADD`t$key`tForceAutoLogon`tREG_SZ`t1" }).Count | Should Be 1
        }
        It "[ConfigureWinlogon off, password $pwLabel] writes no auto-logon value and never the password" {
            $calls = @(Invoke-WinEaseRegistryPhaseRecording -Preset default -TweakOverride @{ ConfigureWinlogon = $false } -UserPassword $pw)
            @($calls | Where-Object { $_ -match '\\Winlogon\t(DefaultPassword|AutoAdminLogon|ForceAutoLogon)\t' }).Count | Should Be 0
            if ($pw) { @($calls | Where-Object { $_.Contains($pw) }).Count | Should Be 0 }
            # blank passwords stay blocked on the network in every case
            @($calls | Where-Object { $_ -match 'LimitBlankPasswordUse\tREG_DWORD\t1$' }).Count | Should Be 1
        }
    }
}

Describe "Autologon - cleanup after the first logon" {
    BeforeAll {
        $script:FlPath = Join-Path $script:RepoRoot 'scripts\FirstLogon.ps1'
        $script:FlText = [System.IO.File]::ReadAllText($script:FlPath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n")
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $script:FlXmlText = ([string]($doc.unattend.Extensions.File | Where-Object { $_.path -like '*FirstLogon.ps1' }).'#text').Replace("`r`n", "`n")
        function Get-CleanupBlock {
            param([string]$Text)
            $start = $Text.IndexOf('# Security cleanup after the first logon')
            $endMarker = "`n`t};"
            $end = $Text.IndexOf($endMarker, $start)
            if ($start -lt 0 -or $end -lt 0) { return '' }
            return $Text.Substring($start, $end - $start)
        }
        $script:FlCleanup = Get-CleanupBlock -Text $script:FlText
        $script:FlXmlCleanup = Get-CleanupBlock -Text $script:FlXmlText
    }

    foreach ($which in @('scripts\FirstLogon.ps1', 'embedded copy in autounattend.xml')) {
        It "[$which] parses cleanly" {
            $text = if ($which -like 'scripts*') { $script:FlText } else { $script:FlXmlText }
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$e)
            $e.Count | Should Be 0
        }
        It "[$which] removes DefaultPassword, resets the auto-logon values and reads the result back" {
            $c = if ($which -like 'scripts*') { $script:FlCleanup } else { $script:FlXmlCleanup }
            $c | Should Not BeNullOrEmpty
            $c | Should Match "Remove-ItemProperty[^\r\n]*'DefaultPassword'[^\r\n]*-ErrorAction Stop"
            $c | Should Match "'AutoAdminLogon'[^\r\n]*-Value '0'"
            $c | Should Match "'ForceAutoLogon'[^\r\n]*-Value '0'"
            $c | Should Match "GetValue\('DefaultPassword'"
            $c | Should Match "\[AutoLogon-Cleanup\] OK"
            $c | Should Match "\[AutoLogon-Cleanup\] FAILED"
            # no silent failure on the password removal any more
            $c | Should Not Match "Remove-ItemProperty[^\r\n]*SilentlyContinue"
        }
        It "[$which] deletes the Setup copies of the answer file and logs failures without a value" {
            $c = if ($which -like 'scripts*') { $script:FlCleanup } else { $script:FlXmlCleanup }
            $c | Should Match 'C:\\Windows\\Panther'
            $c | Should Match 'UnattendGC'
            $c | Should Match 'C:\\Windows\\System32\\Sysprep'
            $c | Should Match "unattend\.xml"
            $c | Should Match 'Remove-Item -LiteralPath \$secretFile -Force -ErrorAction Stop'
            $c | Should Match "WARN: could not delete"
            # the log lines only ever name the value, they never print it
            $c | Should Not Match 'GetValue\(.DefaultPassword.[^\r\n]*Write-Output'
            $c | Should Not Match '\+ \$wlItem\.GetValue\(.DefaultPassword'
        }
    }
    It "the embedded copy and scripts\FirstLogon.ps1 hold the same cleanup block" {
        $script:FlCleanup | Should Not BeNullOrEmpty
        $script:FlXmlCleanup | Should BeExactly $script:FlCleanup
    }
    It "the cleanup runs last and does not keep the old silent version" {
        $script:FlText.IndexOf('# Security cleanup after the first logon') | Should BeGreaterThan $script:FlText.IndexOf('firstlogon.done')
        $script:FlText | Should Not Match "Remove-ItemProperty -LiteralPath 'Registry::HKLM[^\r\n]*DefaultPassword' -Force -ErrorAction SilentlyContinue"
        $script:FlText | Should Not Match '/passwordreq:no'
    }
}

Describe "Autologon - RunFirstLogon logging" {
    BeforeAll {
        $runFlPath = Join-Path $script:RepoRoot 'scripts\setup\RunFirstLogon.ps1'
        $scriptText = [System.IO.File]::ReadAllText($runFlPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors)
        $funcAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-FirstLogonLog' }, $true)
        . ([scriptblock]::Create($funcAst.Extent.Text))
    }

    BeforeEach {
        $script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ('winease_log_test_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:TestLogDir | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TestLogDir) {
            Remove-Item -Recurse -Force -LiteralPath $script:TestLogDir -ErrorAction SilentlyContinue
        }
    }

    It "writes log entries using AppendAllText on the happy path" {
        $wrapperLogFile = Join-Path $script:TestLogDir 'firstlogon-wrapper.log'
        Write-FirstLogonLog -Message 'Happy path log entry' -Level 'INFO'
        (Test-Path -LiteralPath $wrapperLogFile) | Should Be $true
        $content = Get-Content -LiteralPath $wrapperLogFile -Raw
        $content | Should Match '\[INFO\] Happy path log entry'
    }

    It "falls back to Add-Content when AppendAllText throws an exception" {
        $wrapperLogFile = Join-Path $script:TestLogDir 'invalid_dir_as_file'
        New-Item -ItemType Directory -Force -Path $wrapperLogFile | Out-Null

        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Add-Content {
            $capturedCalls.Add(@{ LiteralPath = $LiteralPath; Value = $Value })
        }

        Write-FirstLogonLog -Message 'Fallback path log entry' -Level 'ERROR'

        Assert-MockCalled Add-Content -Exactly 1 -Scope It
        $capturedCalls.Count | Should Be 1
        $capturedCalls[0].LiteralPath | Should Be $wrapperLogFile
        $capturedCalls[0].Value | Should Match '\[ERROR\] Fallback path log entry'
    }
}

Describe "Autologon - transition watchdog Test-InteractiveSession" {
    BeforeAll {
        $watchdogPath = Join-Path $script:RepoRoot 'scripts\setup\WinEase-transition-watchdog.ps1'
        $scriptText = [System.IO.File]::ReadAllText($watchdogPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors)
        $funcAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-InteractiveSession' }, $true)
        . ([scriptblock]::Create($funcAst.Extent.Text))
    }

    It "returns true when quser succeeds with active user rows" {
        function quser.exe {
            $global:LASTEXITCODE = 0
            return @(
                " USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME",
                ">admin                 console             1  Active      .      3/30/2026 10:00"
            )
        }
        try {
            (Test-InteractiveSession) | Should Be $true
        } finally {
            Remove-Item Function:\quser.exe -ErrorAction SilentlyContinue
        }
    }

    It "falls back to Get-Process and returns true when quser fails but explorer session exists" {
        function quser.exe {
            $global:LASTEXITCODE = 1
            return $null
        }
        Mock Get-Process {
            return [PSCustomObject]@{ ProcessName = 'explorer'; SessionId = 1 }
        }
        try {
            (Test-InteractiveSession) | Should Be $true
        } finally {
            Remove-Item Function:\quser.exe -ErrorAction SilentlyContinue
        }
    }

    It "handles exceptions in quser and Get-Process gracefully returning false" {
        function quser.exe {
            throw "quser.exe not found"
        }
        Mock Get-Process {
            throw "Access denied"
        }
        try {
            (Test-InteractiveSession) | Should Be $false
        } finally {
            Remove-Item Function:\quser.exe -ErrorAction SilentlyContinue
        }
    }
}

Remove-Item Function:\reg.exe -ErrorAction SilentlyContinue
