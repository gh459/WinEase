# The official built-in plugins (src\WinEase.Plugins.Builtin.Latency / .PostInstallTools / .UpstreamSync) and the
# way the builder gets them (lib\WinEasePlugins.ps1: plugins\builtin, builtin.lock.psd1, build from src\).
# Pester 3.4 / Windows PowerShell 5.1. The plugins are compiled from src\ with the Windows PowerShell compiler,
# the way the builder does it on a source checkout; tools\build-binaries.ps1 and CI build the same sources with dotnet.
# The registry snapshots (tests\Registry.Tests.ps1) prove that the plugins write what phase 10 used to write.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are read from the It blocks and the helper functions of this file')]
param()
. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "Built-in plugins - what is implemented where" {
    BeforeAll {
        $script:BiWork = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEaseBuiltinTests_{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:BiWork | Out-Null
        . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEasePlugins.ps1')
        # a repository root with only what the builder needs to build the plugins: the sources and the tool scripts
        $script:BiRoot = Join-Path -Path $script:BiWork -ChildPath 'repo'
        foreach ($dir in @('WinEase.Plugins.Abstractions', 'WinEase.Plugins.Builtin.Latency', 'WinEase.Plugins.Builtin.PostInstallTools', 'WinEase.Plugins.Builtin.UpstreamSync')) {
            $target = Join-Path -Path $script:BiRoot -ChildPath "src\$dir"
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath "src\$dir") -Filter '*.cs' -File | Copy-Item -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'scripts\tools') -Destination (Join-Path $script:BiRoot 'scripts\tools') -Recurse
        $script:BiImport = Import-WinEasePlugins -RepoRoot $script:BiRoot
    }
    AfterAll {
        Remove-Item -LiteralPath $script:BiWork -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "builds and loads the three built-in plugins on a source checkout (no prebuilt DLL)" {
        $script:BiImport.LoadedCount | Should Be 3
        $script:BiImport.RejectedCount | Should Be 0
        ($script:BiImport.Loaded | Sort-Object) -join ',' | Should Be 'winease.builtin.latency,winease.builtin.postinstalltools,winease.builtin.upstreamsync'
        Test-Path -LiteralPath (Join-Path $script:BiRoot 'plugins\builtin\builtin.lock.psd1') | Should Be $true
        # the lock file written by the builder is a valid allow list for exactly those DLLs
        @(Test-WinEasePluginLocks -RepoRoot $script:BiRoot | Where-Object { $_.Source -eq 'Builtin' -and $_.Status -ne 'Ok' }).Count | Should Be 0
        @(Read-WinEasePluginLock -Path (Join-Path $script:BiRoot 'plugins\builtin\builtin.lock.psd1')).Count | Should Be 3
    }

    It "does not rebuild a DLL whose sources did not change, and rebuilds a locally built DLL when its source is newer" {
        $dll = Join-Path $script:BiRoot 'plugins\builtin\WinEase.Plugins.Builtin.Latency.dll'
        $stamp = (Get-Item -LiteralPath $dll).LastWriteTimeUtc
        $source = Join-Path $script:BiRoot 'src\WinEase.Plugins.Builtin.Latency\LatencyPlugin.cs'
        $sourceStamp = (Get-Item -LiteralPath $source).LastWriteTimeUtc
        @(Initialize-WinEaseBuiltinPlugins -RepoRoot $script:BiRoot).Count | Should Be 0
        (Get-Item -LiteralPath $dll).LastWriteTimeUtc | Should Be $stamp
        (Get-Item -LiteralPath $source).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(1)
        @(Initialize-WinEaseBuiltinPlugins -RepoRoot $script:BiRoot) -join ',' | Should Be 'Latency'
        (Get-Item -LiteralPath $source).LastWriteTimeUtc = $sourceStamp
        @(Test-WinEasePluginLocks -RepoRoot $script:BiRoot | Where-Object { $_.Status -ne 'Ok' }).Count | Should Be 0
    }

    It "never replaces a shipped DLL (a lock entry that was not written by a local build)" {
        $root = Join-Path $script:BiWork 'shipped'
        Copy-Item -LiteralPath $script:BiRoot -Destination $root -Recurse
        $lock = Join-Path $root 'plugins\builtin\builtin.lock.psd1'
        $entries = @(Read-WinEasePluginLock -Path $lock | ForEach-Object { $_.Description = 'Built by CI'; $_ })
        Write-WinEasePluginLock -Path $lock -Entries $entries
        (Get-Item -LiteralPath (Join-Path $root 'src\WinEase.Plugins.Builtin.Latency\LatencyPlugin.cs')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(1)
        @(Initialize-WinEaseBuiltinPlugins -RepoRoot $root).Count | Should Be 0
    }

    It "warns and goes on without the plugin when neither the DLL nor the source exists" {
        $root = Join-Path $script:BiWork 'nosource'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null
        $warnings = $null
        $built = @(Initialize-WinEaseBuiltinPlugins -RepoRoot $root -WarningVariable warnings 3>$null)
        $built.Count | Should Be 0
        @($warnings).Count | Should Be 3
        ($warnings -join "`n") | Should Match "Built-in plugin 'Latency' is not available"
        ($warnings -join "`n") | Should Match 'Its tweaks are not applied'
        $r = Import-WinEasePlugins -RepoRoot $root 3>$null
        $r.LoadedCount | Should Be 0
    }

    It "warns and goes on when a plugin source does not compile" {
        $root = Join-Path $script:BiWork 'broken'
        Copy-Item -LiteralPath $script:BiRoot -Destination $root -Recurse
        Remove-Item -LiteralPath (Join-Path $root 'plugins') -Recurse -Force
        Set-Content -LiteralPath (Join-Path $root 'src\WinEase.Plugins.Builtin.Latency\LatencyPlugin.cs') -Value 'this is not C#'
        $warnings = $null
        $built = @(Initialize-WinEaseBuiltinPlugins -RepoRoot $root -WarningVariable warnings 3>$null)
        ($built | Sort-Object) -join ',' | Should Be 'PostInstallTools,UpstreamSync'
        ($warnings -join "`n") | Should Match "Built-in plugin 'Latency' could not be built"
    }

    It "an Import that names its own lock file or folder gets exactly that (nothing is built)" {
        $root = Join-Path $script:BiWork 'explicit'
        Copy-Item -LiteralPath $script:BiRoot -Destination $root -Recurse
        Remove-Item -LiteralPath (Join-Path $root 'plugins') -Recurse -Force
        $r = Import-WinEasePlugins -RepoRoot $root -BuiltinLockPath (Join-Path $script:BiWork 'none.lock.psd1') -BuiltinDir (Join-Path $script:BiWork 'nonedir')
        $r.LoadedCount | Should Be 0
        Test-Path -LiteralPath (Join-Path $root 'plugins\builtin') | Should Be $false
        $r2 = Import-WinEasePlugins -RepoRoot $root -NoBuiltinBuild
        $r2.LoadedCount | Should Be 0
    }

    Context "every tweak of config\schema.psd1 is implemented, by PowerShell or by a built-in plugin" {
        BeforeAll {
            [void](Import-WinEasePlugins -RepoRoot $script:BiRoot)
            $script:BiSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
            $phaseText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'phases') -Filter '*.ps1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
            $phaseText += "`n" + [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseDebloat.ps1'))
            $script:BiPhaseText = $phaseText
            $script:BiHelperText = Get-WinEaseHelperSourceText
            # the data tables of the builder
            $script:BiTableText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'config\registry') -Filter '*.psd1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
            $script:BiTableText += "`n" + [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\ui-preferences.psd1'))
            $script:BiSchemaText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\schema.psd1'))
            $script:BiPluginTweaks = @(Get-WinEaseLoadedPlugins | Where-Object { $_.Source -eq 'Builtin' } | ForEach-Object { $_.Tweaks } | Sort-Object -Unique)
            $script:BiPluginText = Get-WinEaseBuiltinPluginSourceText
        }

        function Test-BiPowerShellImplements {
            param([Parameter(Mandatory = $true)]$Def)
            $k = [regex]::Escape($Def.Key)
            if ($script:BiPhaseText -match "Test-TweakEnabled\s+'$k'") { return $true }
            if ($script:BiPhaseText -match "['`"]$k['`"]\s*=") { return $true }
            if ($script:BiTableText -match "Tweak\s*=\s*['`"]$k['`"]") { return $true }
            if ($script:BiSchemaText -match "['`"]$k['`"]\s*=") { return $true }
            if ($Def.Variable) {
                $v = $Def.Variable
                if (($script:BiPhaseText -match "\`$$v\b") -or ($script:BiHelperText -match "\`$$v\b")) { return $true }
            }
            return $false
        }

        function Test-BiPluginImplements {
            param([Parameter(Mandatory = $true)]$Def)
            return ($script:BiPluginTweaks -contains $Def.Key) -or ($script:BiPluginText -match "IsTweakEnabled\(""$([regex]::Escape($Def.Key))""")
        }

        It "has an implementation for every tweak" {
            $missing = @(foreach ($def in $script:BiSchema.Tweaks) {
                    if (-not (Test-BiPowerShellImplements -Def $def) -and -not (Test-BiPluginImplements -Def $def)) { $def.Key }
                })
            ($missing -join ', ') | Should Be ''
        }

        It "lists in Describe() only keys that config\schema.psd1 defines (tweaks or components)" {
            $keys = @($script:BiSchema.Tweaks | ForEach-Object { $_.Key }) + @($script:BiSchema.Components | ForEach-Object { $_.Key })
            $unknown = @($script:BiPluginTweaks | Where-Object { $keys -notcontains $_ })
            ($unknown -join ', ') | Should Be ''
        }

        It "has one implementation of the Latency tweaks: the phases no longer read them" {
            $latency = @(Get-WinEaseLoadedPlugins | Where-Object { $_.Id -eq 'winease.builtin.latency' })[0]
            $latency | Should Not BeNullOrEmpty
            $both = @(foreach ($key in $latency.Tweaks) {
                    # MMCSSGaming is a component switch of the builder: its variable is still declared there
                    if ($script:BiPhaseText -match "Test-TweakEnabled\s+'$key'" -or $script:BiTableText -match "Tweak\s*=\s*'$key'") { $key }
                })
            ($both -join ', ') | Should Be ''
        }

        It "every plugin tweak that a table or phase also reads is only a source of additional values (UpstreamSync)" {
            $upstream = @(Get-WinEaseLoadedPlugins | Where-Object { $_.Id -eq 'winease.builtin.upstreamsync' })[0]
            $upstream | Should Not BeNullOrEmpty
            @($upstream.Contributions | Sort-Object) -join ',' | Should Be 'AppxRule,Registry'
            $upstream.Tweaks.Count | Should BeGreaterThan 5
        }

        It "the built-in plugins do not replace a phase and ask for the phases they use" {
            foreach ($p in @(Get-WinEaseLoadedPlugins | Where-Object { $_.Source -eq 'Builtin' })) {
                $p.OnError | Should Be 'Warn'
            }
            @((Get-WinEaseLoadedPlugins | Where-Object { $_.Id -eq 'winease.builtin.latency' })[0].Phases) -join ',' | Should Be '10-registry'
        }
    }

    Context "PostInstallTools stages the same files the builder wrote with Set-Content" {
        BeforeAll {
            [void](Import-WinEasePlugins -RepoRoot $script:BiRoot)
            $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\unattend-scripts\hashes.json') -Raw | ConvertFrom-Json
            $script:BiTools = @(foreach ($item in $fixture) { if ($item.path -like 'scripts/tools/*') { $item } })
        }

        function Test-TweakEnabled {
            param([string]$Name, [bool]$Default = $true)
            if ($script:BiTweakSettings -and $script:BiTweakSettings.Contains($Name)) { return [bool]$script:BiTweakSettings[$Name] }
            return $Default
        }

        function New-BiScratch {
            $dir = Join-Path -Path $script:BiWork -ChildPath ("scratch_{0}" -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            return $dir
        }

        It "embeds scripts\tools byte for byte (the SHA256 recorded before the extraction)" {
            $plugin = @(Get-WinEaseLoadedPlugins | Where-Object { $_.Id -eq 'winease.builtin.postinstalltools' })
            $plugin.Count | Should Be 1
            $type = ($script:WinEasePlugins | Where-Object { $_.Id -eq 'winease.builtin.postinstalltools' }).Instance.GetType()
            $read = $type.GetMethod('ReadResource')
            $script:BiTools.Count | Should Be 10
            foreach ($tool in $script:BiTools) {
                $bytes = [byte[]]$read.Invoke($null, @($tool.path.Substring('scripts/tools/'.Length)))
                (Get-WinEaseSha256Hex -Bytes $bytes) | Should Be $tool.sha256
                $bytes.Length | Should Be $tool.bytes
            }
        }

        It "writes every tool to Windows\Setup\Tools with the bytes Set-Content produced (utf8 for .ps1, ascii for the rest)" {
            $scratch = New-BiScratch
            $NoPostInstallAssets = $false
            Invoke-WinEasePluginImageFiles -ScratchDir $scratch
            foreach ($tool in $script:BiTools) {
                $relative = $tool.path.Substring('scripts/tools/'.Length).Replace('/', '\')
                $source = Join-Path $script:RepoRoot ($tool.path.Replace('/', '\'))
                # what phases\11-unattend.ps1 did before the plugin: Read-WinEaseEmbeddedScript, then Set-Content
                $text = [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
                $expectedFile = Join-Path $script:BiWork 'expected.bin'
                $encoding = if ($relative -like '*.ps1') { 'utf8' } else { 'ascii' }
                $text | Set-Content -LiteralPath $expectedFile -Encoding $encoding
                $written = Join-Path $scratch ("Windows\Setup\Tools\" + $relative)
                Test-Path -LiteralPath $written | Should Be $true
                (Get-FileHash -LiteralPath $written -Algorithm SHA256).Hash | Should Be (Get-FileHash -LiteralPath $expectedFile -Algorithm SHA256).Hash
            }
            # nothing else lands in the image folder of the plugin or below Tools
            Test-Path -LiteralPath (Join-Path $scratch 'Windows\Setup\Scripts\Plugins') | Should Be $false
            @(Get-ChildItem -LiteralPath (Join-Path $scratch 'Windows\Setup\Tools') -Recurse -File).Count | Should Be 10
        }

        It "writes nothing with -NoPostInstallAssets" {
            $scratch = New-BiScratch
            $NoPostInstallAssets = $true
            Invoke-WinEasePluginImageFiles -ScratchDir $scratch
            Test-Path -LiteralPath (Join-Path $scratch 'Windows') | Should Be $false
        }

        It "records the files and writes nothing in DryRun" {
            $scratch = New-BiScratch
            $NoPostInstallAssets = $false
            Invoke-WinEasePluginImageFiles -ScratchDir $scratch -DryRun 6>$null
            Test-Path -LiteralPath (Join-Path $scratch 'Windows') | Should Be $false
        }
    }

    Context "UpstreamSync hands the adopted AppX packages over as rules" {
        BeforeAll {
            [void](Import-WinEasePlugins -RepoRoot $script:BiRoot)
            # the packages that left AppxRemoval of config\schema.psd1 for the plugin
            $script:BiAdoptedAppx = @('*WidgetsPlatformRuntime*', '*RoyalRevolt*', 'king.com.*', '*Microsoft.PCManager*', '*Microsoft.MicrosoftStickyNotes*',
                '*Microsoft.Office.OneNote*', '*Microsoft.SkypeApp*', '*Microsoft.Microsoft3DViewer*', '*Microsoft.Messaging*', '*Microsoft.Whiteboard*')
            . (Join-Path $script:RepoRoot 'lib\WinEaseDebloat.ps1')
        }

        It "removes them with the default removal list (RemoveAppxBloatware) and not without it" {
            $on = @(Get-WinEasePluginAppxPatterns -Settings @{ RemoveAppxBloatware = $true })
            $off = @(Get-WinEasePluginAppxPatterns -Settings @{ RemoveAppxBloatware = $false })
            ($on | Sort-Object) -join ',' | Should Be (($script:BiAdoptedAppx | Sort-Object) -join ',')
            $off.Count | Should Be 0
        }

        It "no longer lists them in the AppxRemoval table of the schema" {
            $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
            $patterns = @($schema.AppxRemoval | ForEach-Object { $_.Pattern })
            @($script:BiAdoptedAppx | Where-Object { $patterns -contains $_ }).Count | Should Be 0
        }
    }

    Context "Latency through the PowerShell host" {
        BeforeAll {
            [void](Import-WinEasePlugins -RepoRoot $script:BiRoot)
            $script:BiRegCalls = [System.Collections.Generic.List[string]]::new()
        }

        function Invoke-WinEaseReg {
            param([string]$Action, [string]$Key, [string]$Name, [switch]$DefaultValue, [string]$Type, [string]$Data, [switch]$PassThru)
            $script:BiRegCalls.Add("$Action|$Key|$Name|$Type|$Data|$($DefaultValue.IsPresent)")
            if ($PassThru) { return $true }
        }
        function Test-TweakEnabled {
            param([string]$Name, [bool]$Default = $true)
            if ($null -ne $script:TweakSettings -and $script:TweakSettings.Contains($Name)) { return [bool]$script:TweakSettings[$Name] }
            return $Default
        }

        It "reads components, tweak groups and tweaks of the builder and writes through Invoke-WinEaseReg after phase 10" {
            $script:BiRegCalls.Clear()
            $script:TweakSettings = [ordered]@{ EnableHAGS = $false; DisablePowerThrottling = $false; GamingNetworkTweaks = $false }
            $script:activeTweakGroups = @{ GPULatency = $true }
            $mmcssGaming = $true
            $atlasReviOSMode = $false
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before 6>$null
            $script:BiRegCalls.Count | Should Be 0
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage After 6>$null
            @($script:BiRegCalls | Where-Object { $_ -like '*Tasks\Games|Priority|REG_DWORD|6|False' }).Count | Should Be 1
            @($script:BiRegCalls | Where-Object { $_ -like '*GraphicsDrivers|HwSchMode|REG_DWORD|2|False' }).Count | Should Be 1
            @($script:BiRegCalls | Where-Object { $_ -like '*PowerThrottlingOff*' }).Count | Should Be 0
            $script:TweakSettings = $null
            $script:activeTweakGroups = $null
        }

        It "writes nothing in DryRun" {
            $script:BiRegCalls.Clear()
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage After -DryRun 6>$null
            $script:BiRegCalls.Count | Should Be 0
        }
    }
}

Describe "Built-in plugins - build wiring" {
    It "tools\build-binaries.ps1 builds every plugin project of src\ into plugins\builtin and writes the lock file" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\build-binaries.ps1'))
        $text | Should Match 'Plugins = \{'
        $text | Should Match "WinEase\.Plugins\.Builtin\.\*"
        $text | Should Match 'builtin\.lock\.psd1'
    }

    It "CI builds the plugins in the binaries job and uploads them" {
        $ci = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\workflows\ci.yml'))
        $ci | Should Match 'plugins/builtin'
    }

    It "plugins\builtin is build output: the DLLs and the lock file are not committed" {
        $ignore = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.gitignore'))
        $ignore | Should Match '(?m)^plugins/builtin/\*\s*$'
    }

    It "the solution lists the three plugin projects" {
        $sln = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'src\WinEase.sln'))
        foreach ($name in 'Latency', 'PostInstallTools', 'UpstreamSync') { $sln | Should Match "WinEase\.Plugins\.Builtin\.$name\.csproj" }
    }

    It "the release zip check requires the plugin sources" {
        $py = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\scripts\verify-release-zip.py'))
        foreach ($name in 'Latency', 'PostInstallTools', 'UpstreamSync') { $py | Should Match "src/WinEase\.Plugins\.Builtin\.$name/WinEase\.Plugins\.Builtin\.$name\.csproj" }
    }
}
