# Layout.Tests.ps1 - repository layout and folder structure
# Run with:  Invoke-Pester -Path .\tests\Layout.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase builder - repository layout" {
    It "builder script exists" {
        Test-Path -LiteralPath $script:BuilderPath | Should Be $true
    }
    It "autounattend.xml exists" {
        Test-Path -LiteralPath $script:UnattendPath | Should Be $true
    }
    It "LICENSE exists (MIT)" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "LICENSE") | Should Be $true
    }
    It "tools/custom-scripts skeleton exists" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "tools\custom-scripts") | Should Be $true
    }
    It "CHANGELOG.md exists" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "CHANGELOG.md") | Should Be $true
    }
}

Describe "Folder structure S9" {
    BeforeAll {
        $script:S9Root = $script:RepoRoot
        . (Join-Path -Path $script:S9Root -ChildPath "WinEasehelpers.ps1")
        . (Join-Path -Path $script:S9Root -ChildPath "lib\WinEaseExtensions.ps1")
    }
    It "migrator files live under tools/migrator and the old paths are gone" {
        foreach ($f in 'WinEaseMigration.ps1', 'WinEase-Migrator.ps1', 'migration-rules.psd1') {
            Test-Path -LiteralPath (Join-Path $script:S9Root "tools\migrator\$f") | Should Be $true
        }
        Test-Path -LiteralPath (Join-Path $script:S9Root "lib\WinEaseMigration.ps1") | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:S9Root "tools\WinEase-Migrator.ps1") | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\migration-rules.psd1") | Should Be $false
    }
    It "user config files live under config/user" {
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user\user-tweaks.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user\user-migration-rules.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user-tweaks.psd1") | Should Be $false
    }
    It "the builder does not load the migration engine" {
        $text = [System.IO.File]::ReadAllText($script:BuilderPath)
        $text.Contains('WinEaseMigration.ps1') | Should Be $false
    }
    It "the GUI loads the migration engine from tools/migrator, and only inside a function" {
        $gui = Join-Path $script:S9Root "lib\WinEaseGuiCore.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gui, [ref]$null, [ref]$null)
        $hits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' -and $n.Extent.Text -like '*WinEaseMigration.ps1*' }, $true))
        $hits.Count | Should Be 2
        foreach ($h in $hits) {
            $h.Extent.Text.Contains('tools\migrator\WinEaseMigration.ps1') | Should Be $true
            $fn = $h.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $fn -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $fn = $fn.Parent }
            ($null -ne $fn) | Should Be $true
        }
    }
    It "Resolve-WinEaseUserConfigPath prefers config/user, falls back to config with one warning" {
        $root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'config\user-tweaks.psd1') -Value '@{}'
        $script:WinEaseLegacyConfigWarned = $null
        $first = Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' -WarningVariable w1 -WarningAction SilentlyContinue
        [void](Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' -WarningVariable w2 -WarningAction SilentlyContinue)
        $first | Should Be (Join-Path $root 'config\user-tweaks.psd1')
        @($w1).Count | Should Be 1
        @($w2).Count | Should Be 0
        New-Item -ItemType Directory -Path (Join-Path $root 'config\user') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'config\user\user-tweaks.psd1') -Value '@{}'
        Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' | Should Be (Join-Path $root 'config\user\user-tweaks.psd1')
    }
    It "Get-WinEaseCustomScriptFiles maps stage folders and the older layout" {
        $root = Join-Path $TestDrive 'cs'
        $base = Join-Path $root 'tools\custom-scripts'
        foreach ($d in 'FirstLogon', 'UserOnce', 'user', 'PreBuild') { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        foreach ($f in 'a.ps1', 'README.md', 'FirstLogon\b.ps1', 'FirstLogon\.gitkeep', 'user\c.ps1', 'UserOnce\d.ps1', 'PreBuild\e.ps1') { Set-Content -LiteralPath (Join-Path $base $f) -Value 'x' }
        $names = { param($st, $legacy) @(Get-WinEaseCustomScriptFiles -RepoRoot $root -Stage $st -IncludeLegacy:$legacy | ForEach-Object { $_.Name } | Sort-Object) -join ',' }
        (& $names 'FirstLogon' $false) | Should Be 'b.ps1'
        (& $names 'FirstLogon' $true) | Should Be 'a.ps1,b.ps1'
        (& $names 'UserOnce' $true) | Should Be 'c.ps1,d.ps1'
        (& $names 'PreBuild' $false) | Should Be 'e.ps1'
        (& $names 'OfflineImage' $true) | Should Be ''
    }
    It "scripts/custom is not used and every stage folder under tools/custom-scripts has a .gitkeep" {
        Test-Path -LiteralPath (Join-Path $script:S9Root "scripts\custom") | Should Be $false
        foreach ($st in 'PreBuild', 'OfflineImage', 'FirstLogon', 'UserOnce') {
            Test-Path -LiteralPath (Join-Path $script:S9Root "tools\custom-scripts\$st\.gitkeep") | Should Be $true
        }
    }
    It "WinEase_report.html is ignored by git and templates/report.html remains" {
        ([System.IO.File]::ReadAllText((Join-Path $script:S9Root ".gitignore")) -split "`r?`n") -contains 'WinEase_report.html' | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "templates\report.html") | Should Be $true
    }
}

Describe "R3 - setup and tool scripts are files, not here-strings" {
    BeforeAll {
        $fixtureJson = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\unattend-scripts\hashes.json') -Raw | ConvertFrom-Json
        $script:R3Fixture = @(foreach ($item in $fixtureJson) { $item })
        $script:R3PhasePath = Join-Path $script:RepoRoot 'phases\11-unattend.ps1'
        $script:R3PhaseText = [System.IO.File]::ReadAllText($script:R3PhasePath)
    }
    It "the fixture lists 5 setup helpers and 10 tool scripts" {
        @($script:R3Fixture | Where-Object { $_.path -like 'scripts/setup/*' }).Count | Should Be 5
        @($script:R3Fixture | Where-Object { $_.path -like 'scripts/tools/*' }).Count | Should Be 10
    }
    It "every extracted file matches the SHA256 recorded before the extraction" {
        foreach ($e in $script:R3Fixture) {
            $p = Join-Path $script:RepoRoot ($e.path.Replace('/', '\'))
            Test-Path -LiteralPath $p | Should Be $true
            (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() | Should Be $e.sha256
            (Get-Item -LiteralPath $p).Length | Should Be $e.bytes
        }
    }
    It "Read-WinEaseEmbeddedScript returns the recorded content for every file" {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:R3PhaseText, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-WinEaseEmbeddedScript' }, $true)
        $fn | Should Not BeNullOrEmpty
        $scriptDir = $script:RepoRoot
        . ([scriptblock]::Create($fn.Extent.Text))
        foreach ($e in $script:R3Fixture) {
            $content = Read-WinEaseEmbeddedScript -RelativePath $e.path.Replace('/', '\')
            $hash = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '').ToLower()
            $hash | Should Be $e.sha256
        }
    }
    It "the phase no longer embeds them and references every file" {
        $script:R3PhaseText | Should Not Match "(?m)^\s*\S+\s*=\s*@'\s*$"
        foreach ($e in $script:R3Fixture) {
            $script:R3PhaseText.Contains($e.path.Replace('/', '\')) | Should Be $true
        }
    }
    It "the username placeholder stays in the autologon repair helper and is still substituted" {
        $helper = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'scripts\setup\WinEase-oobe-autologon-repair.ps1'))
        $helper.Contains('__WINEASE_USERNAME__') | Should Be $true
        $script:R3PhaseText.Contains(".Replace('__WINEASE_USERNAME__', `$UserName)") | Should Be $true
    }
    It "every .ps1 under scripts/setup and scripts/tools parses" {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'scripts') -Recurse -Filter *.ps1 | Where-Object { $_.FullName -match '[\\/]scripts[\\/](setup|tools)[\\/]' }) {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
            @($errs).Count | Should Be 0
        }
    }
    It ".gitattributes keeps line endings of the extracted scripts untouched" {
        $ga = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.gitattributes') -Raw
        $ga | Should Match '(?m)^scripts/setup/\*\* -text\s*$'
        $ga | Should Match '(?m)^scripts/tools/\*\* -text\s*$'
    }
}


Describe "Launcher exe (R8)" {
    BeforeAll {
        $script:LauncherDir = Join-Path -Path $script:RepoRoot -ChildPath 'src\WinEase.Launcher'
    }
    It "launcher sources, manifest and icon exist" {
        foreach ($f in 'WinEase.Launcher.csproj', 'Program.cs', 'LauncherLogic.cs', 'app.manifest', 'app.ico') {
            Test-Path -LiteralPath (Join-Path -Path $script:LauncherDir -ChildPath $f) | Should Be $true
        }
    }
    It "manifest requests asInvoker" {
        (Get-Content -LiteralPath (Join-Path -Path $script:LauncherDir -ChildPath 'app.manifest') -Raw) | Should Match 'level="asInvoker"'
    }
    It "app.ico holds the nine frame sizes" {
        $bytes = [IO.File]::ReadAllBytes((Join-Path -Path $script:LauncherDir -ChildPath 'app.ico'))
        [BitConverter]::ToInt16($bytes, 2) | Should Be 1
        $sizes = foreach ($i in 0..([BitConverter]::ToInt16($bytes, 4) - 1)) { $w = $bytes[6 + 16 * $i]; if ($w -eq 0) { 256 } else { [int]$w } }
        ($sizes -join ',') | Should Be '16,20,24,32,40,48,64,128,256'
    }
    It "New-WinEaseIcon.ps1 turns a PNG into a transparent-background icon" {
        Add-Type -AssemblyName System.Drawing
        $dir = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('we-icon-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $png = Join-Path -Path $dir -ChildPath 'in.png'
            $bmp = New-Object System.Drawing.Bitmap -ArgumentList 300, 300
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
            $g.FillEllipse([System.Drawing.Brushes]::Teal, 50, 50, 200, 200)
            $g.Dispose(); $bmp.Save($png); $bmp.Dispose()
            $ico = Join-Path -Path $dir -ChildPath 'out.ico'
            & (Join-Path -Path $script:RepoRoot -ChildPath 'tools\New-WinEaseIcon.ps1') -Source $png -Destination $ico | Out-Null
            $bytes = [IO.File]::ReadAllBytes($ico)
            [BitConverter]::ToInt16($bytes, 4) | Should Be 9
            $icon = New-Object System.Drawing.Icon -ArgumentList $ico
            $icon.Dispose()
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "build-binaries.ps1 builds the launcher and the solution lists it" {
        (Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'tools\build-binaries.ps1') -Raw) | Should Match 'Launcher = \{'
        (Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'src\WinEase.sln') -Raw) | Should Match 'WinEase\.Launcher\.csproj'
    }
}
