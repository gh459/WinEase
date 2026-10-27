# Debloat.Tests.ps1 - Defender, AppX, security options and debloat engines
# Run with:  Invoke-Pester -Path .\tests\Debloat.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase - the Defender stays usable unless its removal was asked for" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        $script:Phase05 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\05-appx.ps1"), [System.Text.Encoding]::UTF8)
        # the plain registry writes live in config\registry, so the guards read the tables too
        $script:Phase10 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\10-registry.ps1"), [System.Text.Encoding]::UTF8) + "`n" + (Get-WinEaseRegistryTableText)
        $script:Phase11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\11-unattend.ps1"), [System.Text.Encoding]::UTF8)
        $script:FirstLogon = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "scripts\FirstLogon.ps1"), [System.Text.Encoding]::UTF8)
        $script:DefenderEnforce = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "scripts\WinEase-DefenderEnforce.ps1"), [System.Text.Encoding]::UTF8)
    }

    It "does not set DisableRealtimeMonitoring policy in registry phase, FirstLogon or DefenderEnforce scripts" {
        $script:Phase10 | Should Not Match 'DisableRealtimeMonitoring'
        $script:FirstLogon | Should Not Match 'DisableRealtimeMonitoring'
        $script:DefenderEnforce | Should Not Match 'DisableRealtimeMonitoring'
    }

    It "phase 10 only disables the Defender services when the Defender is removed on purpose" {
        # The "Physical: Defender" target of the Advanced Debloat tab disables the
        # Defender services. It must never do that on its own: the conflict matrix
        # removes the target when the Defender is kept, and this guard is the second
        # line of defence against a target that reaches the phase anyway.
        $script:Phase10 | Should Match ([regex]::Escape('$removeDefender -and (Test-WinEaseDebloatTargetSelected -Item ''Physical: Defender (complete removal) [~50MB]'')'))
    }

    It "phase 10 outputs a security warning when disabling Defender real-time protection" {
        $script:Phase10 | Should Match ([regex]::Escape('[SECURITY WARNING] Disabling Windows Defender Real-Time Protection and security policies...'))
    }

    It "phase 15 verifies boot-start Defender drivers as disabled, not deleted" {
        $phase15 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\15-verify.ps1'))
        $phase15 | Should Match 'Defender driver keys disabled'
        $phase15 | Should Match ([regex]::Escape('[int]$drvStart -ne 4'))
        # WdBoot must not be in the list of service keys that are expected to be gone.
        $phase15 | Should Not Match ([regex]::Escape("`$defSvc = @('WinDefend','MDCoreSvc','WdNisSvc','Sense','SecurityHealthService','wscsvc','webthreatdefsvc','webthreatdefusersvc','WdBoot'"))
    }

    It "phase 05 records every package it removed from the image" {
        $script:Phase05 | Should Match ([regex]::Escape('$script:WinEaseRemovedAppxPackages'))
        # the identity name is the part before the first underscore, it is what
        # Get-AppxPackage -Name matches against
        $script:Phase05 | Should Match ([regex]::Escape("ShortName"))
    }

    It "phase 10 takes the staged AppX registration of the removed packages out of the hive" {
        # The staged copy of an inbox app lives in AppxAllUserStore\InboxApp. Windows
        # installs it for the first user, so an app whose payload folder was deleted
        # starts and renders a white window.
        $script:Phase10 | Should Match ([regex]::Escape('AppxAllUserStore\InboxApp'))
        $script:Phase10 | Should Match ([regex]::Escape('$script:WinEaseRemovedAppxPackages'))
    }

    It "phase 11 stages the per-user cleanup of every removed package" {
        # The list used to hold three hardcoded names while the offline pass removes every
        # package of the removal list, so the other apps stayed registered for the first
        # user with a payload that was gone.
        $script:Phase11 | Should Match ([regex]::Escape('$script:WinEaseRemovedAppxPackages'))
        $script:Phase11 | Should Match ([regex]::Escape('remove-appx-packages.flag'))
    }

    It "the first logon cleanup matches the identity name of a package" {
        $script:FirstLogon | Should Match ([regex]::Escape('Get-AppxPackage -AllUsers -Name $appxName'))
    }

    It "the builder applies the safeguards without breaking on the experimental list" {
        # List[string].AddRange does not accept a plain Object[]: the method binder throws a
        # MethodException, so the build died in the conflict check whenever the physical
        # debloat needed its explicit consent.
        $builder = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "WinEasebuilder.ps1"), [System.Text.Encoding]::UTF8)
        $builder | Should Match ([regex]::Escape('AddRange([string[]]@($script:advancedDebloatExperimental))'))
        $builder | Should Not Match ([regex]::Escape('AddRange(@($script:advancedDebloatExperimental))'))
    }

    It "a list of strings only accepts a cast array" {
        $list = [System.Collections.Generic.List[string]]::new()
        { $list.AddRange(@('a')) } | Should Throw
        $list.AddRange([string[]]@('a'))
        $list.Count | Should Be 1
    }
}

Describe "WinEase - the safe engine never deletes a binary of the system directory" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseDebloat.ps1")
        $script:Schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    }

    It "recognizes the binaries of the system directory" {
        Test-WinEaseSystem32BinaryPath -Path 'Windows\System32\snmp.exe' | Should Be $true
        Test-WinEaseSystem32BinaryPath -Path 'Windows\System32\drivers\mpsdrv.sys' | Should Be $true
        Test-WinEaseSystem32BinaryPath -Path 'Windows\SysWOW64\foo.dll' | Should Be $true
        Test-WinEaseSystem32BinaryPath -Path 'ProgramData\Microsoft\Windows Defender' | Should Be $false
        Test-WinEaseSystem32BinaryPath -Path 'Program Files\WindowsApps\MicrosoftEdge*' | Should Be $false
        Test-WinEaseSystem32BinaryPath -Path 'Windows\System32Backup\foo.dll' | Should Be $false
    }

    It "the payload of a target holds no shared library" {
        # wmisnmp.dll and snmpapi.dll belong to WMI, WinFax.dll is the fax API of the
        # whole system: deleting one of them breaks components that have nothing to do
        # with the target.
        foreach ($def in @($script:Schema.DebloatEngines)) {
            foreach ($path in @($def.Payload)) {
                $path | Should Not Match '(?i)^Windows\\System32\\(snmpapi|wmisnmp|WinFax)\.dll$'
            }
        }
    }

    It "the firewall target declares no payload for the safe engine" {
        # The binary of the firewall service and its driver live in System32. The safe
        # engine disables the service instead, the forced engine removes the binary.
        $fw = @($script:Schema.DebloatEngines | Where-Object { $_.Item -like 'Physical: Windows Firewall*' })
        $fw.Count | Should Be 1
        $fw[0].Payload | Should BeNullOrEmpty
    }
}

Describe "WinEase helpers - BuildContext advanced debloat lists" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $script:SavedStd = $script:advancedDebloatStandard
        $script:SavedExp = $script:advancedDebloatExperimental
    }
    AfterAll {
        $script:advancedDebloatStandard = $script:SavedStd
        $script:advancedDebloatExperimental = $script:SavedExp
    }

    It "defaults both lists to empty string arrays" {
        $ctx = [BuildContext]::new()
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps `$null as an empty list" {
        $script:advancedDebloatStandard = $null
        $script:advancedDebloatExperimental = $null
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps an empty array empty" {
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps a single element" {
        $script:advancedDebloatStandard = @('OnlyOne')
        $script:advancedDebloatExperimental = @('SoleExp')
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 1
        $ctx.AdvancedDebloatStandard[0] | Should Be 'OnlyOne'
        $ctx.AdvancedDebloatExperimental[0] | Should Be 'SoleExp'
    }

    It "keeps multiple elements in order through context" {
        $std = @('Zeta', 'Alpha', 'Mid')
        $exp = @('E2', 'E1')
        $script:advancedDebloatStandard = $std
        $script:advancedDebloatExperimental = $exp
        $ctx = New-BuildContextFromScriptScope
        ($ctx.AdvancedDebloatStandard -join '|') | Should Be 'Zeta|Alpha|Mid'
        ($ctx.AdvancedDebloatExperimental -join '|') | Should Be 'E2|E1'
        ($ctx.AdvancedDebloatStandard -is [string[]]) | Should Be $true
        ($ctx.AdvancedDebloatExperimental -is [string[]]) | Should Be $true
    }
}

Describe "WinEase debloat - Test-WinEaseAppxPackageRemovable" {
    BeforeAll {
        if (-not (Get-Command -Name Test-WinEaseAppxPackageRemovable -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseDebloat.ps1")
        }
    }

    Context "Get-WinEaseAppxPatternRegex" {
        It "returns null for empty or missing patterns array" {
            Get-WinEaseAppxPatternRegex -Patterns @() | Should BeNullOrEmpty
        }

        It "escapes special regex characters and converts wildcards" {
            $regex = Get-WinEaseAppxPatternRegex -Patterns @('*Microsoft.ZuneVideo[1]*')
            $regex | Should Not BeNullOrEmpty
            $regex.IsMatch('Microsoft.ZuneVideo[1]123') | Should Be $true
            $regex.IsMatch('Microsoft.ZuneVideo123') | Should Be $false
        }

        It "deduplicates identical patterns and builds a case-insensitive regex" {
            $regex = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*', '*Zune*', '*PAINT*')
            $regex.IsMatch('microsoft.zunemusic') | Should Be $true
            $regex.IsMatch('MICROSOFT.PAINT') | Should Be $true
            $regex.IsMatch('Microsoft.Calculator') | Should Be $false
        }
    }

    Context "Test-WinEaseAppxPackageRemovable" {
        $removalRegex = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*', '*Bing*')
        $protectedRegex = Get-WinEaseAppxPatternRegex -Patterns @('*Microsoft.VCLibs*', '*SecHealthUI*')

        It "returns false when RemovalRegex is null" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic' -DisplayName 'Zune Music' -RemovalRegex $null | Should Be $false
        }

        It "returns false when Name and DisplayName are null or whitespace" {
            Test-WinEaseAppxPackageRemovable -Name $null -DisplayName $null -RemovalRegex $removalRegex | Should Be $false
            Test-WinEaseAppxPackageRemovable -Name '' -DisplayName '   ' -RemovalRegex $removalRegex | Should Be $false
        }

        It "returns false when neither Name nor DisplayName matches RemovalRegex" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.WindowsCalculator' -DisplayName 'Calculator' -RemovalRegex $removalRegex | Should Be $false
        }

        It "returns true when Name matches RemovalRegex and ProtectedRegex is null or unmatched" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_8wekyb3d8bbwe' -DisplayName 'Music App' -RemovalRegex $removalRegex | Should Be $true
        }

        It "returns true when DisplayName matches RemovalRegex and ProtectedRegex is null or unmatched" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.UnknownPackage_1.0' -DisplayName 'Bing News' -RemovalRegex $removalRegex | Should Be $true
        }

        It "returns false when Name matches RemovalRegex but matches ProtectedRegex (whitelist protection)" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.Zune_Microsoft.VCLibs_1.0' -DisplayName 'Protected Zune' -RemovalRegex $removalRegex -ProtectedRegex $protectedRegex | Should Be $false
        }

        It "returns false when DisplayName matches RemovalRegex but matches ProtectedRegex" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.Zune_1.0' -DisplayName 'Bing SecHealthUI' -RemovalRegex $removalRegex -ProtectedRegex $protectedRegex | Should Be $false
        }

        It "returns false when Name matches RemovalRegex and DisplayName matches ProtectedRegex" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_8wekyb3d8bbwe' -DisplayName 'Microsoft.VCLibs' -RemovalRegex $removalRegex -ProtectedRegex $protectedRegex | Should Be $false
        }

        It "returns false when DisplayName matches RemovalRegex and Name matches ProtectedRegex" {
            Test-WinEaseAppxPackageRemovable -Name 'Microsoft.SecHealthUI_8wekyb3d8bbwe' -DisplayName 'Bing Search' -RemovalRegex $removalRegex -ProtectedRegex $protectedRegex | Should Be $false
        }

        It "is case-insensitive for both removal and protection matching" {
            Test-WinEaseAppxPackageRemovable -Name 'MICROSOFT.ZUNEMUSIC_1.0' -DisplayName 'zune' -RemovalRegex $removalRegex | Should Be $true
            Test-WinEaseAppxPackageRemovable -Name 'MICROSOFT.ZUNEMUSIC_1.0' -DisplayName 'sechealthui' -RemovalRegex $removalRegex -ProtectedRegex $protectedRegex | Should Be $false
        }
    }
}

Describe "AppX removal - the settings decide what is removed" {
    BeforeAll {
        if (-not (Get-Command -Name Get-WinEaseAppxRemovalPatterns -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1")
        }
        $script:AppxSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $script:AppxDefinitions = @($script:AppxSchema.AppxRemoval)
    }

    It "the AppX list lives in the master schema" {
        @($script:AppxDefinitions).Count | Should BeGreaterThan 40
        foreach ($d in $script:AppxDefinitions) {
            $d.Pattern | Should Not BeNullOrEmpty
            $d.Group | Should Not BeNullOrEmpty
            # a controlling setting must exist
            if ($d.Option) {
                $known = @(@($script:AppxSchema.Tweaks | ForEach-Object { $_.Key }) + @($script:AppxSchema.Components | ForEach-Object { $_.Key }))
                ($known -contains $d.Option) | Should Be $true
            }
        }
    }

    It "nothing is removed when RemoveAppxBloatware and every independent app option are off" {
        $patterns = @(Get-WinEaseAppxRemovalPatterns -Definitions $script:AppxDefinitions -Settings @{
            RemoveAppxBloatware = $false; RemoveDefender = $false; RemoveStore = $false
            RemoveCameraApp = $false; RemovePhotosApp = $false; RemoveScreenSketchApp = $false
            KeepBasicApps = $false; KeepXboxServices = $false
        })
        $patterns.Count | Should Be 0
    }

    It "Camera, Photos and Screen Sketch are independent of RemoveAppxBloatware" {
        $patterns = @(Get-WinEaseAppxRemovalPatterns -Definitions $script:AppxDefinitions -Settings @{
            RemoveAppxBloatware = $false; RemoveDefender = $false; RemoveStore = $false
            RemoveCameraApp = $true; RemovePhotosApp = $true; RemoveScreenSketchApp = $true
            KeepBasicApps = $false; KeepXboxServices = $false
        })
        ($patterns -contains '*Microsoft.WindowsCamera*') | Should Be $true
        ($patterns -contains '*Microsoft.Windows.Photos*') | Should Be $true
        ($patterns -contains '*Microsoft.ScreenSketch*') | Should Be $true
        # the default bloatware list stays off
        ($patterns -contains '*Zune*') | Should Be $false
        ($patterns -contains '*Clipchamp*') | Should Be $false
        ($patterns -contains '*Paint*') | Should Be $false
    }

    It "the default removal list is applied when the option is on" {
        $patterns = @(Get-WinEaseAppxRemovalPatterns -Definitions $script:AppxDefinitions -Settings @{ RemoveAppxBloatware = $true; RemoveDefender = $false; RemoveStore = $false; KeepBasicApps = $true; KeepXboxServices = $true })
        $patterns.Count | Should BeGreaterThan 40
        # the basic apps and the Xbox apps stay when they are kept
        ($patterns -contains '*Paint*') | Should Be $false
        ($patterns -contains '*WindowsCalculator*') | Should Be $false
        ($patterns -contains '*Xbox*') | Should Be $false
        # the default list is there
        ($patterns -contains '*Zune*') | Should Be $true
        ($patterns -contains '*Clipchamp*') | Should Be $true
        # the Store and the Security UI follow their own setting
        ($patterns -contains 'Microsoft.WindowsStore_*') | Should Be $false
        ($patterns -contains '*Microsoft.SecHealthUI*') | Should Be $false
    }

    It "the basic apps and the Xbox apps follow their own setting" {
        $patterns = @(Get-WinEaseAppxRemovalPatterns -Definitions $script:AppxDefinitions -Settings @{ RemoveAppxBloatware = $true; RemoveDefender = $false; RemoveStore = $false; KeepBasicApps = $false; KeepXboxServices = $false })
        ($patterns -contains '*Paint*') | Should Be $true
        ($patterns -contains '*Notepad*') | Should Be $true
        ($patterns -contains '*WindowsCalculator*') | Should Be $true
        ($patterns -contains '*Xbox*') | Should Be $true
        ($patterns -contains '*Gaming*') | Should Be $true
    }

    It "the Store and the Security UI follow their own setting" {
        $patterns = @(Get-WinEaseAppxRemovalPatterns -Definitions $script:AppxDefinitions -Settings @{ RemoveAppxBloatware = $true; RemoveDefender = $true; RemoveStore = $true; KeepBasicApps = $true; KeepXboxServices = $true })
        ($patterns -contains 'Microsoft.WindowsStore_*') | Should Be $true
        ($patterns -contains 'Microsoft.StorePurchaseApp_*') | Should Be $true
        ($patterns -contains '*Microsoft.SecHealthUI*') | Should Be $true
        ($patterns -contains '*Microsoft.Windows.SecHealthUI*') | Should Be $true
    }

    It "the installed and the provisioned packages are decided by the same rule" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*', '*Paint*')
        $protected = Get-WinEaseAppxPatternRegex -Patterns @('*Microsoft.VCLibs*')
        # a package of the removal list
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_2019.22091.10041.0_neutral_~_8wekyb3d8bbwe' -DisplayName 'Zune Music' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $true
        # a protected package is never removed
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe' -DisplayName 'VCLibs' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
        # a package that is in neither list stays
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.WindowsCalculator_11.2405.0.0_neutral_~_8wekyb3d8bbwe' -DisplayName 'Calculator' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
        # an empty removal list removes nothing
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_neutral_~_8wekyb3d8bbwe' -DisplayName 'Zune' -RemovalRegex $null -ProtectedRegex $protected | Should Be $false
    }

    It "a package that does not exist does not break the removal" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*')
        $protected = Get-WinEaseAppxPatternRegex -Patterns @('*Microsoft.VCLibs*')
        # a package without a name and without a display name is never removed
        Test-WinEaseAppxPackageRemovable -Name '' -DisplayName '' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
        # an unknown package is simply not in the list
        Test-WinEaseAppxPackageRemovable -Name 'Contoso.App_1.0_x64__abc' -DisplayName 'Contoso' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
    }

    It "Test-WinEaseAppxPackageRemovable returns false when RemovalRegex is null" {
        $protected = Get-WinEaseAppxPatternRegex -Patterns @('*VCLibs*')
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Zune Music' -RemovalRegex $null -ProtectedRegex $protected | Should Be $false
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Zune Music' | Should Be $false
    }

    It "Test-WinEaseAppxPackageRemovable evaluates removal matching by Name, DisplayName, or both" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*', '*Xbox*')

        # Match by Name only (DisplayName is empty or non-matching)
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName 'OtherApp' -RemovalRegex $removal | Should Be $true
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName '' -RemovalRegex $removal | Should Be $true
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName $null -RemovalRegex $removal | Should Be $true

        # Match by DisplayName only (Name is empty or non-matching)
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.Unknown_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Xbox Gaming' -RemovalRegex $removal | Should Be $true
        Test-WinEaseAppxPackageRemovable -Name '' -DisplayName 'Xbox Gaming' -RemovalRegex $removal | Should Be $true
        Test-WinEaseAppxPackageRemovable -Name $null -DisplayName 'Xbox Gaming' -RemovalRegex $removal | Should Be $true

        # Match by both Name and DisplayName
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Zune Music' -RemovalRegex $removal | Should Be $true

        # Match by neither Name nor DisplayName
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.WindowsCalculator_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Calculator' -RemovalRegex $removal | Should Be $false
    }

    It "Test-WinEaseAppxPackageRemovable prioritizes protection rules over removal rules" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*', '*Paint*', '*SecHealth*')
        $protected = Get-WinEaseAppxPatternRegex -Patterns @('*SecHealth*', '*ProtectedApp*')

        # Protected by Name match (DisplayName matches RemovalRegex)
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.SecHealthUI_1.0_x64__8wekyb3d8bbwe' -DisplayName 'Zune Music' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false

        # Protected by DisplayName match (Name matches RemovalRegex)
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe' -DisplayName 'ProtectedApp' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false

        # Both match ProtectedRegex and RemovalRegex
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.SecHealthUI_1.0_x64__8wekyb3d8bbwe' -DisplayName 'SecHealthUI' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false

        # ProtectedRegex is null -> removal proceeds
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.SecHealthUI_1.0_x64__8wekyb3d8bbwe' -DisplayName 'SecHealthUI' -RemovalRegex $removal -ProtectedRegex $null | Should Be $true
    }

    It "Test-WinEaseAppxPackageRemovable handles null and empty arguments safely" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*Zune*')
        $protected = Get-WinEaseAppxPatternRegex -Patterns @('*VCLibs*')

        Test-WinEaseAppxPackageRemovable -Name $null -DisplayName $null -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
        Test-WinEaseAppxPackageRemovable -Name '' -DisplayName '' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
        Test-WinEaseAppxPackageRemovable -Name '   ' -DisplayName '   ' -RemovalRegex $removal -ProtectedRegex $protected | Should Be $false
    }

    It "Test-WinEaseAppxPackageRemovable supports case-insensitive matching" {
        $removal = Get-WinEaseAppxPatternRegex -Patterns @('*zunemusic*')

        # Uppercase / mixed case Name
        Test-WinEaseAppxPackageRemovable -Name 'MICROSOFT.ZUNEMUSIC_1.0_X64__8WEKYB3D8BBWE' -DisplayName 'ZUNE MUSIC' -RemovalRegex $removal | Should Be $true

        # Uppercase / mixed case DisplayName
        Test-WinEaseAppxPackageRemovable -Name 'Microsoft.Unknown_1.0' -DisplayName 'ZuNeMuSiC' -RemovalRegex $removal | Should Be $true
    }

    It "phase 05 uses the shared list and the shared decision" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\05-appx.ps1"))
        $src | Should Match 'Get-WinEaseAppxRemovalPatterns'
        $src | Should Match 'Test-WinEaseAppxPackageRemovable'
        # the fixed pattern list is gone
        $src | Should Not Match "\*Zune\*', '\*Bing\*'"
        # a dry run does not remove anything
        $src | Should Match '\$isDryRunMode'
    }

    It "the second AppX pass of the Advanced Debloat target uses the same decision" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"))
        $src | Should Match 'Test-WinEaseAppxPackageRemovable'
    }

    It "the GUI and the CLI resolve the same AppX setting" {
        $presets = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\presets.psd1")
        foreach ($key in $presets.PresetOrder) {
            $preset = $presets.Presets[$key]
            # every preset names the option, so the GUI and the CLI cannot drift apart
            $preset.Contains('RemoveAppxBloatware') | Should Be $true
        }
        $component = @($script:AppxSchema.Components | Where-Object { $_.Key -eq 'RemoveAppxBloatware' })
        $component.Count | Should Be 1
        $component[0].Variable | Should Be 'removeAppxBloatware'
    }
}

Describe "Security options - the defaults and the execution paths agree" {
    BeforeAll {
        $script:SecSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $script:SecPresets = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\presets.psd1")
    }

    It "the security options that disable a protection default to off" {
        $defender = @($script:SecSchema.Components | Where-Object { $_.Key -eq 'RemoveDefender' })[0]
        [bool]$defender.Default | Should Be $false
        [bool]$defender.Gui.Default | Should Be $false
        $wu = @($script:SecSchema.Components | Where-Object { $_.Key -eq 'DisableWindowsUpdate' })[0]
        [bool]$wu.Default | Should Be $false
        [bool]$wu.Gui.Default | Should Be $false
        $winlogon = @($script:SecSchema.Tweaks | Where-Object { $_.Key -eq 'ConfigureWinlogon' })[0]
        [bool]$winlogon.Default | Should Be $false
        $uac = @($script:SecSchema.Tweaks | Where-Object { $_.Key -eq 'DisableUAC' })[0]
        [bool]$uac.Default | Should Be $false
    }

    It "the JSON profile schema carries the same defaults" {
        $json = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\WinEase.config.schema.json")) | ConvertFrom-Json
        [bool]$json.properties.RemoveDefender.default | Should Be $false
        [bool]$json.properties.DisableWindowsUpdate.default | Should Be $false
        $json.properties.RemoveAppxBloatware | Should Not BeNullOrEmpty
    }

    It "the aggressive presets still ask for the aggressive security options but never bundle auto-logon" {
        foreach ($key in @('extreme', 'fat32', 'handheld', 'audio')) {
            $preset = $script:SecPresets.Presets[$key]
            [bool]$preset['RemoveDefender'] | Should Be $true
            [bool]$preset['DisableWindowsUpdate'] | Should Be $true
            # ConfigureWinlogon is deliberately NOT bundled into presets any
            # more (separated in the 2026-10-26 review remediation): enabling
            # auto-logon must be an explicit opt-in, never a preset side effect.
            [bool]$preset.TweakSettings['ConfigureWinlogon'] | Should Be $false
        }
    }

    It "the none preset removes nothing" {
        $none = $script:SecPresets.Presets['none']
        # every removal option is off
        [bool]$none['RemoveDefender'] | Should Be $false
        [bool]$none['RemoveStore'] | Should Be $false
        [bool]$none['RemoveLegacyFOD'] | Should Be $false
        [bool]$none['RemoveDrivers'] | Should Be $false
        [bool]$none['DisableWindowsUpdate'] | Should Be $false
        [bool]$none['RemoveAppxBloatware'] | Should Be $false
        [bool]$none['UltraSlimMode'] | Should Be $false
        # every "Keep ..." option is on
        [bool]$none['KeepAsianIME'] | Should Be $true
        [bool]$none['KeepExtraFonts'] | Should Be $true
        [bool]$none['KeepBluetooth'] | Should Be $true
        [bool]$none['KeepRecoveryEnv'] | Should Be $true
        [bool]$none['KeepBasicApps'] | Should Be $true
        [bool]$none['KeepXboxServices'] | Should Be $true
        [bool]$none['KeepSearchIndex'] | Should Be $true
        [bool]$none['KeepAudioTweaks'] | Should Be $true
    }

    It "the none preset names every option of the master schema" {
        $none = $script:SecPresets.Presets['none']
        $tweakKeys = @($script:SecSchema.Tweaks | ForEach-Object { $_.Key })
        # the three prerequisites of the unattended setup keep their default
        $bypass = @('BypassHardwareRequirements', 'BypassNetworkRequirement', 'BypassNRO')
        foreach ($tk in $tweakKeys) {
            if ($bypass -contains $tk) {
                ([System.Collections.IDictionary]$none.TweakSettings).Contains($tk) | Should Be $false
                continue
            }
            ([System.Collections.IDictionary]$none.TweakSettings).Contains($tk) | Should Be $true
            [bool]$none.TweakSettings[$tk] | Should Be $false
        }
        $componentKeys = @($script:SecSchema.Components | Where-Object { $_.Type -ne 'Special' -and ([System.Collections.IDictionary]$_).Contains('Default') } | ForEach-Object { $_.Key })
        foreach ($ck in $componentKeys) {
            ([System.Collections.IDictionary]$none).Contains($ck) | Should Be $true
        }
    }

    It "the none preset removes no AppX package" {
        if (-not (Get-Command -Name Get-WinEaseAppxRemovalPatterns -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1")
        }
        $none = $script:SecPresets.Presets['none']
        $definitions = @($script:SecSchema.AppxRemoval)
        $settings = @{
            RemoveAppxBloatware = [bool]$none['RemoveAppxBloatware']
            RemoveDefender      = [bool]$none['RemoveDefender']
            RemoveStore         = [bool]$none['RemoveStore']
            KeepBasicApps       = [bool]$none['KeepBasicApps']
            KeepXboxServices    = [bool]$none['KeepXboxServices']
        }
        @(Get-WinEaseAppxRemovalPatterns -Definitions $definitions -Settings $settings).Count | Should Be 0
    }

    It "the blank-password auto-logon follows the option everywhere" {
        # the unattend file: the AutoLogon section is removed when the option is off
        $phase11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\11-unattend.ps1"))
        $phase11 | Should Match 'Test-TweakEnabled ''ConfigureWinlogon'' \$false'
        $phase11 | Should Match 'local-name\(\)=.AutoLogon.'
        # the registry phase: the Winlogon values are only written when the option is on
        $phase10 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\10-registry.ps1"))
        $phase10 | Should Match 'Test-TweakEnabled ''ConfigureWinlogon'' \$false'
        # the network use of a blank password is blocked in every configuration
        $phase10 | Should Match 'LimitBlankPasswordUse'
        # the OOBE helpers are only deployed when the option is on
        $phase11 | Should Match 'WinEase-oobe-autologon-repair\.ps1'
        $phase11 | Should Match '\$configureWinlogon'
    }

    It "the unattend file loses the auto-logon section when the option is off" {
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "autounattend.xml"), [System.Text.Encoding]::UTF8)
        $doc = [xml]$raw
        # the option is off: the AutoLogon section is removed, the account stays
        $doc = [xml]$raw
        foreach ($n in @($doc.SelectNodes("//*[local-name()='AutoLogon']"))) { [void]$n.ParentNode.RemoveChild($n) }
        @($doc.SelectNodes("//*[local-name()='AutoLogon']")).Count | Should Be 0
        @($doc.SelectNodes("//*[local-name()='LocalAccount']")).Count | Should BeGreaterThan 0
        # the option is on: the section stays untouched
        $doc2 = [xml]$raw
        @($doc2.SelectNodes("//*[local-name()='AutoLogon']")).Count | Should BeGreaterThan 0
    }

    It "the first logon removes the AppX packages only behind the flag" {
        $firstLogon = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "scripts\FirstLogon.ps1"))
        $firstLogon | Should Match 'remove-appx-packages\.flag'
        # the unconditional per-user removal is gone
        $firstLogon | Should Not Match 'Get-AppxPackage -AllUsers -Name \*WindowsBackupApp\*'
        # the phase stages the list
        $phase11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\11-unattend.ps1"))
        $phase11 | Should Match 'remove-appx-packages\.flag'
    }

    It "the security options are documented with their recovery" {
        $doc = Join-Path $script:RepoRoot "docs\SECURITY_OPTIONS.md"
        Test-Path -LiteralPath $doc | Should Be $true
        $text = [System.IO.File]::ReadAllText($doc)
        foreach ($key in @('RemoveDefender', 'DisableWindowsUpdate', 'ConfigureWinlogon', 'DisableUAC', 'EnableScripts', 'DisableCPUMitigations', 'PreventDeviceEncryption')) {
            $text | Should Match ([regex]::Escape($key))
        }
        $text | Should Match 'Recovery'
    }
}

Describe "WinEase forced physical deletion - the Rust engine" {
    $script:PhysRustPath = Join-Path $script:RepoRoot "tools\winease-physical-debloat\src\main.rs"
    $script:PhysRustSrc = [System.IO.File]::ReadAllText($script:PhysRustPath, [System.Text.Encoding]::UTF8)
    $script:PhysSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:PhysEngineDefs = @($script:PhysSchema.DebloatEngines)

    # The components whose payload was only removed by the safe engine. Every one of
    # them has to be removable by the Rust engine now.
    $script:PhysNewRustTargets = @(
        @{ Item = 'Remove event logs [10-50MB]'; Key = 'physical_event_logs' }
        @{ Item = 'Remove non-essential fonts (file delete) [50-100MB]'; Key = 'physical_fonts' }
        @{ Item = 'Remove non-Japanese IME [5-15MB]'; Key = 'physical_ime' }
    )

    It "the components without a forced physical deletion can run on the Rust engine" {
        foreach ($t in $script:PhysNewRustTargets) {
            $def = @($script:PhysEngineDefs | Where-Object { $_.Item -eq $t.Item })
            $def.Count | Should Be 1
            (@($def[0].Engines) -contains 'Rust') | Should Be $true
            [bool]$def[0].SupportsRustPhysical | Should Be $true
            [string]$def[0].RustKey | Should Be $t.Key
            # the binary knows the key
            $script:PhysRustSrc | Should Match ([regex]::Escape($t.Key))
        }
    }

    It "the binary accepts the new keys and rejects the unknown ones" {
        $allowlist = [regex]::Match($script:PhysRustSrc, '(?s)KNOWN_EXPERIMENTAL_KEYS: &\[&str\] = &\[(.*?)\];').Groups[1].Value
        foreach ($t in $script:PhysNewRustTargets) {
            $allowlist | Should Match ([regex]::Escape($t.Key))
        }
    }

    It "every deletion path of the binary takes the ownership and grants the delete right" {
        # the ownership and the delete right are the two steps that turn a plain delete
        # into a forced one
        $script:PhysRustSrc | Should Match 'fn take_ownership'
        $script:PhysRustSrc | Should Match 'fn grant_full_control'
        $script:PhysRustSrc | Should Match 'fn force_access'
        $script:PhysRustSrc | Should Match 'DACL_SECURITY_INFORMATION'
        $script:PhysRustSrc | Should Match 'fn remove_directory_forced'
        $script:PhysRustSrc | Should Match 'fn delete_by_handle'
        # the directory is no longer removed with a bare RemoveDirectoryW whose result
        # was dropped
        $script:PhysRustSrc | Should Not Match 'let _ = RemoveDirectoryW'
        # the delete-on-close disposition is the last step of the forced deletion
        $script:PhysRustSrc | Should Match 'FileDispositionInfoEx'
        $script:PhysRustSrc | Should Match 'FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE'
    }

    It "the event log target removes the log files but keeps the log folder" {
        $script:PhysRustSrc | Should Match 'Windows\\\\System32\\\\winevt\\\\Logs'
        $script:PhysRustSrc | Should Match 'fn delete_directory_contents'
    }

    It "the image language reaches the binary so that the own IME engine and fonts stay" {
        $phase09 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        $phase09 | Should Match 'primary_ime_lang'
        $script:PhysRustSrc | Should Match 'primary_ime_lang'
        $script:PhysRustSrc | Should Match 'fn font_keep_patterns'
        $script:PhysRustSrc | Should Match 'fn ime_directory_for_language'
    }

    It "the Rust key of the new targets is resolved by the fallback as well" {
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Get-WinEaseDebloatRustKey')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count
        $script:WinEaseDebloatEngines = @{}
        foreach ($def in $script:PhysEngineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        try {
            foreach ($fn in $funcs) { . ([scriptblock]::Create($fn.Extent.Text)) }
            foreach ($t in $script:PhysNewRustTargets) {
                Get-WinEaseDebloatRustKey -Item $t.Item | Should Be $t.Key
            }
        } finally {
            $script:WinEaseDebloatEngines = $null
        }
    }

    It "the safe engine and the Rust engine stay apart for the new targets" {
        # the targets keep the safe engine as their default, so a build without the
        # Rust engine behaves exactly as before
        foreach ($t in $script:PhysNewRustTargets) {
            $def = @($script:PhysEngineDefs | Where-Object { $_.Item -eq $t.Item })[0]
            [string]$def.Default | Should Be 'PowerShell'
            (@($def.Engines) -contains 'PowerShell') | Should Be $true
        }
    }
}

Describe "WinEase advanced debloat - every engine can remove its target" {
    # The engine column of the Advanced Debloat tab must never offer an engine that
    # cannot remove the target: the user would pick an engine and nothing would happen.
    $script:EngSchema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:EngDefs = @($script:EngSchema.DebloatEngines)
    $script:EngLibText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"), [System.Text.Encoding]::UTF8)
    $script:EngRustSrc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\winease-physical-debloat\src\main.rs"), [System.Text.Encoding]::UTF8)
    # the items the safe engine removes in the shared library
    $script:EngHandled = @([regex]::Matches($script:EngLibText, "(?m)^\s{8}'([^']+)' \{") | ForEach-Object { $_.Groups[1].Value })

    It "every target that offers the Rust engine has a Rust key the binary accepts" {
        $allowlist = [regex]::Match($script:EngRustSrc, '(?s)KNOWN_EXPERIMENTAL_KEYS: &\[&str\] = &\[(.*?)\];').Groups[1].Value
        foreach ($def in $script:EngDefs) {
            if (@($def.Engines) -notcontains 'Rust') { continue }
            [string]$def.RustKey | Should Not BeNullOrEmpty
            $allowlist | Should Match ([regex]::Escape([string]$def.RustKey))
        }
    }

    It "every target that offers the PowerShell engine is removed by it" {
        foreach ($def in $script:EngDefs) {
            if (@($def.Engines) -notcontains 'PowerShell') { continue }
            $reachable = ($script:EngHandled -contains $def.Item)
            if (-not $reachable) {
                # the phase that owns the target asks for it (the engine gate or the
                # engine independent one) or the option of the target switches the work on
                $phasePath = Join-Path $script:RepoRoot ("phases\{0}.ps1" -f $def.Phase)
                if (Test-Path -LiteralPath $phasePath) {
                    $phaseText = [System.IO.File]::ReadAllText($phasePath, [System.Text.Encoding]::UTF8)
                    $reachable = ($phaseText -match [regex]::Escape("Test-WinEaseDebloatTarget -Item '{0}'" -f $def.Item)) -or
                        ($phaseText -match [regex]::Escape("Test-WinEaseDebloatTargetSelected -Item '{0}'" -f $def.Item))
                    if (-not $reachable -and $def.Option) {
                        # the target carries the option of the phase that owns it, so the
                        # phase asks for the option mechanism
                        $reachable = ($phaseText -match 'Test-WinEaseDebloatOptionEnabled')
                    }
                }
            }
            if (-not $reachable) {
                throw "the target '$($def.Item)' offers the PowerShell engine, but neither the shared library nor the phase '$($def.Phase)' removes it"
            }
        }
    }

    It "the paging files belong to the safe engine only" {
        # hiberfil.sys, pagefile.sys and swapfile.sys are created by Windows on the running
        # system, so they are not part of the mounted image and the Rust engine could only
        # ever report "file not found"
        foreach ($key in @('physical_hiberfil', 'physical_pagefile', 'physical_swapfile')) {
            $script:EngRustSrc | Should Not Match ([regex]::Escape($key))
        }
        foreach ($item in @('Remove hiberfil.sys (powercfg /h off) [4-16GB]', 'Remove pagefile.sys (pagefile disable) [4-16GB]', 'Remove swapfile.sys (pagefile disable) [256MB-1GB]')) {
            $def = @($script:EngDefs | Where-Object { $_.Item -eq $item })
            $def.Count | Should Be 1
            (@($def[0].Engines) -join ',') | Should Be 'PowerShell'
            [string]$def[0].RustKey | Should BeNullOrEmpty
            [bool]$def[0].SupportsRustPhysical | Should Be $false
        }
    }

    It "the swap file is removed by the safe engine together with the page file" {
        # the swap file is created with the paging file, so the post-install switch of
        # phase 11 removes both
        $phase11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\11-unattend.ps1"), [System.Text.Encoding]::UTF8)
        $phase11 | Should Match ([regex]::Escape("Test-WinEaseDebloatTarget -Item 'Remove swapfile.sys (pagefile disable) [256MB-1GB]'"))
        $phase11 | Should Match 'remove-pagefile\.flag'
    }

    It "a target that no engine can remove does not exist" {
        # the toggles that were removed: the WinRE cleanup is done by the KeepRecoveryEnv
        # option (the Rust engine must not touch winre.wim, the setup needs it) and the
        # Store cache lives in the user profile, not in the image
        $guiAst = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiCorePath, [ref]$null, [ref]$null)
        $assigns = $guiAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:WinEaseDebloatStandardItems', '$script:WinEaseDebloatExperimentalItems' }, $true)
        $guiItems = @()
        foreach ($a in $assigns) { $guiItems += @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        $ja = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\ui-strings\ja.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $depText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\dependencies.psd1"), [System.Text.Encoding]::UTF8)
        foreach ($gone in @('Remove WinRE (reagentc /disable + file delete) [500-700MB]', 'Remove Windows Store cache [varies]')) {
            @($script:EngDefs | Where-Object { $_.Item -eq $gone }).Count | Should Be 0
            ($guiItems -contains $gone) | Should Be $false
            ($ja.PSObject.Properties.Name -contains "Debloat:$gone") | Should Be $false
            $depText | Should Not Match ([regex]::Escape("'$gone'"))
        }
    }

    It "the services of the service targets are disabled on both engines" {
        # the binaries are removed by the engine the user picked, but the services have to
        # be disabled in any case - otherwise the image keeps a service whose binary the
        # Rust engine has just deleted
        $phase10 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\10-registry.ps1"), [System.Text.Encoding]::UTF8)
        foreach ($item in @(
            'Remove Print Spooler (service + binary) [20-30MB]',
            'Remove Bluetooth stack (service + binary) [20-40MB]',
            'Remove Remote Desktop host (service + binary) [30-50MB]',
            'Remove touch/pen/ink components [20-30MB]',
            'Physical: BitLocker (complete removal) [~30-50MB]'
        )) {
            $phase10 | Should Match ([regex]::Escape("Test-WinEaseDebloatTargetSelected -Item '{0}'" -f $item))
        }
    }

    It "the services of the targets that can run on both engines are disabled too" {
        # the targets below remove a service and its binary. The binary is removed by the
        # engine the user picked, so the service is disabled in any case.
        $phase10 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\10-registry.ps1"), [System.Text.Encoding]::UTF8)
        foreach ($item in @(
            'Physical: Defender (complete removal) [~50MB]',
            'Physical: Windows Firewall (complete removal) [~20-40MB]',
            'Remove SNMP service [2MB]',
            'Remove Fax service [5MB]',
            'Remove Telnet/TFTP client [1MB]'
        )) {
            $phase10 | Should Match ([regex]::Escape("Test-WinEaseDebloatTargetSelected -Item '{0}'" -f $item))
        }
    }
}

# Describe 67 builds the full GUI, which uses the shared helpers, the user-extension
# engine and the migration engine. The monolith loaded all three before the test run.
if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}
if (-not (Get-Command -Name Import-WinEaseUserExtensions -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseExtensions.ps1")
}
if (-not (Get-Command -Name Get-WinEaseMigrationRules -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "WinEase advanced debloat - the engine choice is explained" -Tags 'slow' {
    # The engine column is not obvious: a help mark next to the engine label explains
    # what the two engines do.
    $script:HelpEn = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\ui-strings\en.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    $script:HelpJa = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\ui-strings\ja.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json

    It "the help text is in both language tables" {
        $en = [string]$script:HelpEn.PSObject.Properties['Debloat.Engine.Help'].Value
        $ja = [string]$script:HelpJa.PSObject.Properties['Debloat.Engine.Help'].Value
        $en | Should Not BeNullOrEmpty
        $ja | Should Not BeNullOrEmpty
        # both texts name the two engines and what they do
        $en | Should Match 'PowerShell'
        $en | Should Match 'Rust'
        $ja | Should Match 'PowerShell'
        $ja | Should Match 'Rust'
    }

    It "the classic window shows the help mark next to the engine label" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'Debloat\.Engine\.Help'
        $guiText | Should Match "SetToolTip\(\`$engineHelpMark"
        # the mark sits left of the engine label
        $guiText | Should Match "engineHelpMark = New-WinEaseLabel -Text '\?' -X 431"
        $guiText | Should Match "Debloat\.Engine\.All'\) -X 455"
    }

    It "the WinUI window shows the help mark next to the engine label" {
        $winuiText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
        $winuiText | Should Match 'Debloat\.Engine\.Help'
        $winuiText | Should Match 'ToolTipService\.SetToolTip\(engineHelp'
    }

    It "the help mark of the classic window shows the explanation on hover" -Skip:(-not ('System.Windows.Forms.Form' -as [type])) {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $script:AllTweakDefs = [ordered]@{}
        foreach ($td in $schema.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
        $script:ComponentDefs = [ordered]@{}
        foreach ($cd in $schema.Components) { $script:ComponentDefs[$cd.Key] = $cd }
        function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
        $script:WinEaseDebloatEngines = [ordered]@{}
        foreach ($d in $schema.DebloatEngines) { $script:WinEaseDebloatEngines[[string]$d.Item] = $d }
        . $script:GuiPath
        . ([scriptblock]::Create($script:GuiNoModalStubs))
        function Confirm-WinEaseGuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $mark = @($gui.Form.Controls.Find('WinEaseEngineHelp', $true))
            $mark.Count | Should Be 1
            $mark[0].Text | Should Be '?'
            $gui.ToolTip.GetToolTip($mark[0]) | Should Be ([string]$script:HelpEn.PSObject.Properties['Debloat.Engine.Help'].Value)
            # the mark sits left of the engine label
            $mark[0].Right | Should BeLessThan 455
        } finally { $gui.Form.Dispose() }
    }
}
