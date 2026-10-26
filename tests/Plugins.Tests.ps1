# Plugin host (lib\WinEasePlugins.ps1, src\WinEase.Plugins.Abstractions, plugins\, config\user\plugins.lock.psd1).
# Pester 3.4 / Windows PowerShell 5.1. The test plugins are compiled on the fly with the C# compiler of
# Windows PowerShell against the contract assembly that is compiled from src\ the same way.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are read from the It blocks and the helper functions of this file')]
param()
. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "Plugin host" {
    $script:PluginWork = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEasePluginTests_{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:PluginWork | Out-Null
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEasePlugins.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseRegistry.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseReport.ps1')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseSelfTest.ps1')

    function Test-TweakEnabled {
        param([string]$Name, [bool]$Default = $true)
        if ($null -ne $script:TweakSettings -and ([System.Collections.IDictionary]$script:TweakSettings).Contains($Name)) { return [bool]$script:TweakSettings[$Name] }
        return $Default
    }

    function New-TestAbstractions {
        param([string]$Path, [string]$Version = '1.0.0.0')
        $srcDir = Join-Path -Path $script:RepoRoot -ChildPath 'src\WinEase.Plugins.Abstractions'
        $sources = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
        $sources += "[assembly: System.Reflection.AssemblyVersion(`"$Version`")]"
        [void](New-WinEaseCSharpAssembly -Source $sources -OutputPath $Path)
        return $Path
    }

    $script:AbstractionsDll = New-TestAbstractions -Path (Join-Path $script:PluginWork 'WinEase.Plugins.Abstractions.dll')

    # One test plugin per DLL. Rec.Events lists "<phase>:<stage>" for every OnPhase call.
    function New-TestPluginDll {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$OnPhase = '',
            [string]$Describe = '',
            [string]$Reference = $script:AbstractionsDll
        )
        $source = @'
using System;
using System.Collections;
using System.Collections.Generic;
using WinEase.Plugins;
namespace @@NS@@ {
  public static class Rec { public static ArrayList Events = new ArrayList(); }
  public class P : IWinEasePlugin, IRegistryContributor, IAppxRemovalContributor, IFodRemovalContributor, IServiceStartContributor, IImageFileContributor {
    public string Id { get { return "@@NS@@"; } }
    public string Version { get { return "1.2.3"; } }
    public PluginDescription Describe() { PluginDescription d = new PluginDescription(); d.Summary = "test plugin"; @@DESCRIBE@@ return d; }
    public bool AppliesTo(ImageInfo image) { return true; }
    public void OnPhase(PhaseContext c) { Rec.Events.Add(c.Phase + ":" + c.Stage); @@ONPHASE@@ }
    public IEnumerable<RegistryEntry> GetRegistryEntries(ImageInfo image) {
      RegistryEntry good = new RegistryEntry(); good.Hive = "zSYSTEM"; good.Path = "Software\\Plugin"; good.Name = "Value"; good.Type = "REG_DWORD"; good.Data = "1"; good.Tweak = "PluginTweak"; good.Default = true;
      RegistryEntry bad = new RegistryEntry(); bad.Hive = "HKLM"; bad.Path = "Software\\Evil"; bad.Name = "Value"; bad.Type = "REG_DWORD"; bad.Data = "1";
      return new RegistryEntry[] { good, bad };
    }
    public IEnumerable<string> GetAppxRemovals(ImageInfo image) { return new string[] { "Contoso.*" }; }
    public IEnumerable<FodRemoval> GetFodRemovals(ImageInfo image) { return new FodRemoval[] { new FodRemoval("Capability", "Contoso.Cap~~~~0.0.1.0") }; }
    public IEnumerable<ServiceStart> GetServiceStarts(ImageInfo image) { return new ServiceStart[] { new ServiceStart("ContosoSvc", 4), new ServiceStart("bad name", 9) }; }
    public IEnumerable<ImageFile> GetImageFiles(ImageInfo image) {
      return new ImageFile[] { new ImageFile("run.cmd", new byte[] { 1, 2, 3 }), new ImageFile("..\\escape.txt", new byte[] { 9 }) };
    }
  }
}
'@
        $source = $source.Replace('@@NS@@', $Name).Replace('@@ONPHASE@@', $OnPhase).Replace('@@DESCRIBE@@', $Describe)
        $path = Join-Path -Path $script:PluginWork -ChildPath "$Name.dll"
        [void](New-WinEaseCSharpAssembly -Source @($source) -OutputPath $path -References @($Reference))
        return $path
    }

    # Copies a DLL into a fresh plugin folder, writes the lock file for it and imports.
    function Import-TestPlugin {
        param(
            [Parameter(Mandatory = $true)][string]$Dll,
            [string]$Sha256,
            [string]$OnError = 'Warn',
            [switch]$NotInLock
        )
        $dir = Join-Path -Path $script:PluginWork -ChildPath ("set_{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $name = Split-Path -Leaf $Dll
        Copy-Item -LiteralPath $Dll -Destination (Join-Path $dir $name)
        if (-not $Sha256) { $Sha256 = Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes($Dll)) }
        $lock = Join-Path -Path $dir -ChildPath 'user.lock.psd1'
        $entries = @()
        if (-not $NotInLock) { $entries = @([PSCustomObject]@{ File = $name; Sha256 = $Sha256; OnError = $OnError; Description = ''; Enabled = $true }) }
        Write-WinEasePluginLock -Path $lock -Entries $entries
        return Import-WinEasePlugins -RepoRoot $script:RepoRoot -UserDir $dir -UserLockPath $lock -BuiltinLockPath (Join-Path $dir 'none.psd1') -BuiltinDir (Join-Path $script:PluginWork 'emptybuiltin') -AbstractionsPath $script:AbstractionsDll
    }

    function Get-TestRecEvents {
        param([string]$Namespace)
        $asm = @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $Namespace } | Select-Object -Last 1)[0]
        if ($null -eq $asm) { return @() }
        return @($asm.GetType("$Namespace.Rec").GetField('Events').GetValue($null))
    }
    function Clear-TestRecEvents {
        param([string]$Namespace)
        $asm = @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $Namespace } | Select-Object -Last 1)[0]
        if ($null -ne $asm) { $asm.GetType("$Namespace.Rec").GetField('Events').GetValue($null).Clear() }
    }

    BeforeEach {
        $script:WinEaseTargetBuild = $null
        $script:TweakSettings = [ordered]@{}
        $script:RegCalls = [System.Collections.Generic.List[string]]::new()
    }

    function Invoke-WinEaseReg {
        param([string]$Action, [string]$Key, [string]$Name, [switch]$DefaultValue, [string]$Type, [string]$Data, [switch]$PassThru)
        $script:RegCalls.Add("$Action|$Key|$Name|$Type|$Data|$($DefaultValue.IsPresent)")
        if ($PassThru) { return $true }
    }

    Context "Loading and the allow list" {
        It "loads a DLL whose SHA256 matches the lock file" {
            $dll = New-TestPluginDll -Name 'LoadOk'
            $r = Import-TestPlugin -Dll $dll
            $r.LoadedCount | Should Be 1
            $r.Rejected.Count | Should Be 0
            $plugin = @($script:WinEasePlugins)[0]
            $plugin.Id | Should Be 'LoadOk'
            $plugin.Version | Should Be '1.2.3'
            $plugin.Sha256 | Should Be (Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes($dll)))
            (Get-WinEaseLoadedPlugins)[0].Contributions -contains 'Registry' | Should Be $true
        }

        It "does not load a DLL whose hash differs from the lock file" {
            $dll = New-TestPluginDll -Name 'HashBad'
            $r = Import-TestPlugin -Dll $dll -Sha256 ('0' * 64) 3>$null
            $r.LoadedCount | Should Be 0
            $r.RejectedCount | Should Be 1
            $r.Rejected[0].Reason | Should Match 'SHA256 mismatch'
            @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'HashBad' }).Count | Should Be 0
        }

        It "does not load a DLL that is not in the lock file" {
            $dll = New-TestPluginDll -Name 'NotListed'
            $r = Import-TestPlugin -Dll $dll -NotInLock 3>$null
            $r.LoadedCount | Should Be 0
            $r.Rejected[0].Reason | Should Match 'not in the lock file'
            @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'NotListed' }).Count | Should Be 0
        }

        It "refuses a lock entry whose file name leaves the plugin folder" {
            $dir = Join-Path $script:PluginWork 'trav'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $lock = Join-Path $dir 'l.psd1'
            Write-WinEasePluginLock -Path $lock -Entries @([PSCustomObject]@{ File = '..\x.dll'; Sha256 = ('a' * 64); OnError = 'Warn'; Description = ''; Enabled = $true })
            $r = Import-WinEasePlugins -RepoRoot $script:RepoRoot -UserDir $dir -UserLockPath $lock -BuiltinLockPath (Join-Path $dir 'none.psd1') -BuiltinDir (Join-Path $script:PluginWork 'emptybuiltin') -AbstractionsPath $script:AbstractionsDll 3>$null
            $r.LoadedCount | Should Be 0
            $r.Rejected[0].Reason | Should Match 'plain .dll name'
        }

        It "does not load a DLL built for another major version of the contract" {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:PluginWork 'v2') | Out-Null
            $abs2 = New-TestAbstractions -Path (Join-Path $script:PluginWork 'v2\WinEase.Plugins.Abstractions.dll') -Version '2.0.0.0'
            $dll = New-TestPluginDll -Name 'MajorTwo' -Reference $abs2
            $r = Import-TestPlugin -Dll $dll 3>$null
            $r.LoadedCount | Should Be 0
            $r.Rejected[0].Reason | Should Match 'major version 2'
        }

        It "refuses a plugin that asks to replace a phase" {
            $dll = New-TestPluginDll -Name 'Replacer' -Describe 'd.ReplacesPhases = new string[] { "09-physical-debloat" };'
            $r = Import-TestPlugin -Dll $dll 3>$null
            $r.LoadedCount | Should Be 0
            $r.Rejected[0].Reason | Should Match 'cannot be replaced'
        }

        It "reads the file once: the hashed bytes are the loaded bytes" {
            $src = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEasePlugins.ps1'))
            $src | Should Match 'Assembly\]::Load\(\$bytes\)'
            $src | Should Not Match 'LoadFrom|LoadFile|Add-Type'
        }

        It "loads nothing and warns nothing when both lock files are empty" {
            # the repository's own user lock file, with an empty built-in folder (the built-in plugins have their own tests)
            $r = Import-WinEasePlugins -RepoRoot $script:RepoRoot -BuiltinLockPath (Join-Path $script:PluginWork 'empty-builtin.lock.psd1') -BuiltinDir (Join-Path $script:PluginWork 'emptybuiltin')
            $r.LoadedCount | Should Be 0
            $r.RejectedCount | Should Be 0
        }
    }

    Context "Hooks around a phase" {
        It "calls Before then After with the phase name" {
            $dll = New-TestPluginDll -Name 'Order'
            [void](Import-TestPlugin -Dll $dll)
            Clear-TestRecEvents -Namespace 'Order'
            Invoke-WinEasePluginHook -Phase '05-appx' -Stage Before
            Invoke-WinEasePluginHook -Phase '05-appx' -Stage After
            (Get-TestRecEvents -Namespace 'Order') -join ',' | Should Be '05-appx:Before,05-appx:After'
        }

        It "skips a plugin whose phase list does not contain the phase" {
            $dll = New-TestPluginDll -Name 'OnlyFod' -Describe 'd.Phases = new string[] { "06-fod" };'
            [void](Import-TestPlugin -Dll $dll)
            Clear-TestRecEvents -Namespace 'OnlyFod'
            Invoke-WinEasePluginHook -Phase '05-appx' -Stage Before
            Invoke-WinEasePluginHook -Phase '06-fod' -Stage Before
            (Get-TestRecEvents -Namespace 'OnlyFod') -join ',' | Should Be '06-fod:Before'
        }

        It "skips a plugin outside its build range and runs it inside" {
            $dll = New-TestPluginDll -Name 'Ranged' -Describe 'd.MinBuild = 26100; d.MaxBuild = 26199;'
            [void](Import-TestPlugin -Dll $dll)
            Clear-TestRecEvents -Namespace 'Ranged'
            $script:WinEaseTargetBuild = 22631
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before
            (Get-TestRecEvents -Namespace 'Ranged').Count | Should Be 0
            $script:WinEaseTargetBuild = 26100
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before
            (Get-TestRecEvents -Namespace 'Ranged').Count | Should Be 1
            $script:WinEaseTargetBuild = 26200
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before
            (Get-TestRecEvents -Namespace 'Ranged').Count | Should Be 1
        }

        It "runs every phase as Before -> phase script -> After in the builder" {
            $src = [System.IO.File]::ReadAllText($script:BuilderPath)
            $before = $src.IndexOf('Invoke-WinEasePluginHook -Phase $phaseId -Stage Before')
            $phase = $src.IndexOf('. $phaseFile')
            $after = $src.IndexOf('Invoke-WinEasePluginHook -Phase $phaseId -Stage After')
            ($before -gt 0 -and $phase -gt $before -and $after -gt $phase) | Should Be $true
            $src.IndexOf('Import-WinEasePlugins') | Should BeGreaterThan $src.IndexOf('Import-WinEaseUserExtensions')
        }
    }

    Context "OnError" {
        $throwing = 'throw new InvalidOperationException("boom");'
        It "Warn reports the failure and goes on" {
            $dll = New-TestPluginDll -Name 'ThrowWarn' -OnPhase $throwing
            [void](Import-TestPlugin -Dll $dll -OnError Warn)
            $w = $null
            { Invoke-WinEasePluginHook -Phase '05-appx' -Stage Before -WarningVariable w 3>$null } | Should Not Throw
            @($script:WinEasePluginRunLog)[-1].Status | Should Be 'Failed'
        }
        It "Ignore goes on" {
            $dll = New-TestPluginDll -Name 'ThrowIgnore' -OnPhase $throwing
            [void](Import-TestPlugin -Dll $dll -OnError Ignore)
            { Invoke-WinEasePluginHook -Phase '05-appx' -Stage Before } | Should Not Throw
            @($script:WinEasePluginRunLog)[-1].Status | Should Be 'Failed'
        }
        It "Stop ends the build" {
            $dll = New-TestPluginDll -Name 'ThrowStop' -OnPhase $throwing
            [void](Import-TestPlugin -Dll $dll -OnError Stop)
            { Invoke-WinEasePluginHook -Phase '05-appx' -Stage Before } | Should Throw 'boom'
        }
    }

    Context "Host services and DryRun" {
        $touch = 'c.Host.SetOfflineRegistry("zSOFTWARE", "Software\\Plugin", "Flag", "REG_DWORD", "1"); c.Host.WriteImageFile("note.txt", new byte[] { 1 }); Rec.Events.Add("dryrun=" + c.Host.DryRun);'
        It "writes the registry value through Invoke-WinEaseReg when it is not a DryRun" {
            $dll = New-TestPluginDll -Name 'HostReal' -OnPhase $touch
            [void](Import-TestPlugin -Dll $dll)
            $scratch = Join-Path $script:PluginWork 'scratch_real'
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before -ScratchDir $scratch
            @($script:RegCalls | Where-Object { $_ -like 'Add|HKLM\zSOFTWARE\Software\Plugin|Flag|REG_DWORD|1|*' }).Count | Should Be 1
            Test-Path -LiteralPath (Join-Path $scratch 'Windows\Setup\Scripts\Plugins\HostReal\note.txt') | Should Be $true
        }
        It "only records the write operations in a DryRun" {
            $dll = New-TestPluginDll -Name 'HostDry' -OnPhase $touch
            [void](Import-TestPlugin -Dll $dll)
            $scratch = Join-Path $script:PluginWork 'scratch_dry'
            Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before -ScratchDir $scratch -DryRun
            $script:RegCalls.Count | Should Be 0
            Test-Path -LiteralPath $scratch | Should Be $false
            (Get-TestRecEvents -Namespace 'HostDry') -contains 'dryrun=True' | Should Be $true
        }
        It "refuses a registry hive that is not an offline hive" {
            $dll = New-TestPluginDll -Name 'HostHive' -OnPhase 'c.Host.SetOfflineRegistry("HKLM", "Software\\Evil", "V", "REG_DWORD", "1");'
            [void](Import-TestPlugin -Dll $dll -OnError Stop)
            { Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before } | Should Throw
            $script:RegCalls.Count | Should Be 0
        }
        It "does not let a plugin run DISM verbs that change the mount" {
            $dll = New-TestPluginDll -Name 'HostDism' -OnPhase 'c.Host.RunDism(new string[] { "/Unmount-Image", "/MountDir:C:\\x", "/Discard" });'
            [void](Import-TestPlugin -Dll $dll -OnError Stop)
            { Invoke-WinEasePluginHook -Phase '10-registry' -Stage Before -ScratchDir $script:PluginWork } | Should Throw
        }
    }

    Context "Contributions" {
        It "returns registry entries in the table shape and drops invalid ones" {
            $dll = New-TestPluginDll -Name 'ContribReg'
            [void](Import-TestPlugin -Dll $dll)
            $entries = @(Get-WinEasePluginContributions -Kind Registry 3>$null)
            $entries.Count | Should Be 1
            $entries[0].Hive | Should Be 'zSYSTEM'
            $entries[0].PluginId | Should Be 'ContribReg'
        }
        It "runs plugin registry entries through Invoke-WinEaseRegistryTable with the tweak gate" {
            $dll = New-TestPluginDll -Name 'ContribTable'
            [void](Import-TestPlugin -Dll $dll)
            $entries = @(Get-WinEasePluginContributions -Kind Registry 3>$null)
            Invoke-WinEaseRegistryTable -Entries $entries
            @($script:RegCalls | Where-Object { $_ -like 'Add|HKLM\zSYSTEM\Software\Plugin|Value|REG_DWORD|1|*' }).Count | Should Be 1
            $script:RegCalls.Clear()
            $script:TweakSettings['PluginTweak'] = $false
            Invoke-WinEaseRegistryTable -Entries $entries
            $script:RegCalls.Count | Should Be 0
        }
        It "returns appx, fod, service and image file contributions and drops invalid ones" {
            $dll = New-TestPluginDll -Name 'ContribAll'
            [void](Import-TestPlugin -Dll $dll)
            @(Get-WinEasePluginContributions -Kind Appx)[0].Pattern | Should Be 'Contoso.*'
            $fod = @(Get-WinEasePluginContributions -Kind Fod)
            $fod[0].Kind | Should Be 'Capability'
            $svc = @(Get-WinEasePluginContributions -Kind Service 3>$null)
            $svc.Count | Should Be 1
            $svc[0].Name | Should Be 'ContosoSvc'
            $files = @(Get-WinEasePluginContributions -Kind ImageFile 3>$null)
            $files.Count | Should Be 1
            $files[0].RelativePath | Should Be 'run.cmd'
        }
        It "writes image files below Windows\Setup\Scripts\Plugins\<id> and not in a DryRun" {
            $dll = New-TestPluginDll -Name 'ContribFiles'
            [void](Import-TestPlugin -Dll $dll)
            $scratch = Join-Path $script:PluginWork 'scratch_files'
            Invoke-WinEasePluginImageFiles -ScratchDir $scratch -DryRun 3>$null
            Test-Path -LiteralPath $scratch | Should Be $false
            Invoke-WinEasePluginImageFiles -ScratchDir $scratch 3>$null
            [System.IO.File]::ReadAllBytes((Join-Path $scratch 'Windows\Setup\Scripts\Plugins\ContribFiles\run.cmd')) -join ',' | Should Be '1,2,3'
            Test-Path -LiteralPath (Join-Path $scratch 'Windows\Setup\Scripts\Plugins\escape.txt') | Should Be $false
        }
        It "has no contributions without plugins" {
            [void](Import-WinEasePlugins -RepoRoot $script:RepoRoot -BuiltinLockPath (Join-Path $script:PluginWork 'empty-builtin.lock.psd1') -BuiltinDir (Join-Path $script:PluginWork 'emptybuiltin'))
            @(Get-WinEasePluginContributions -Kind Registry).Count | Should Be 0
        }
        It "returns unique appx patterns via Get-WinEasePluginAppxPatterns" {
            $script:WinEasePlugins = [System.Collections.Generic.List[object]]::new()
            $mockInstance = [PSCustomObject]@{
                GetAppxRemovals = { return @('PackageA.*', 'PackageB.*') }
                AppliesTo       = { return $true }
            }
            $script:WinEasePlugins.Add([PSCustomObject]@{
                Id          = 'MockPlugin'
                Instance    = $mockInstance
                Description = [PSCustomObject]@{ MinBuild = 0; MaxBuild = 0 }
            })
            $patterns = Get-WinEasePluginAppxPatterns
            $patterns -contains 'PackageA.*' | Should Be $true
            $patterns -contains 'PackageB.*' | Should Be $true
        }
    }

    Context "Lock files, self test and user registration" {
        It "Test-WinEasePluginLocks reports Ok, Mismatch and Missing" {
            $root = Join-Path $script:PluginWork 'repo'
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'plugins\user'), (Join-Path $root 'plugins\builtin'), (Join-Path $root 'config\user') | Out-Null
            $good = New-TestPluginDll -Name 'LockGood'
            Copy-Item -LiteralPath $good -Destination (Join-Path $root 'plugins\user\LockGood.dll')
            Copy-Item -LiteralPath $good -Destination (Join-Path $root 'plugins\user\LockBad.dll')
            $hash = Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes($good))
            Write-WinEasePluginLock -Path (Join-Path $root 'config\user\plugins.lock.psd1') -Entries @(
                [PSCustomObject]@{ File = 'LockGood.dll'; Sha256 = $hash; OnError = 'Warn'; Description = ''; Enabled = $true },
                [PSCustomObject]@{ File = 'LockBad.dll'; Sha256 = ('1' * 64); OnError = 'Warn'; Description = ''; Enabled = $true },
                [PSCustomObject]@{ File = 'LockGone.dll'; Sha256 = $hash; OnError = 'Warn'; Description = ''; Enabled = $true })
            $rows = @(Test-WinEasePluginLocks -RepoRoot $root)
            ($rows | Where-Object { $_.File -eq 'LockGood.dll' }).Status | Should Be 'Ok'
            ($rows | Where-Object { $_.File -eq 'LockBad.dll' }).Status | Should Be 'Mismatch'
            ($rows | Where-Object { $_.File -eq 'LockGone.dll' }).Status | Should Be 'Missing'
        }
        It "the lock files of the repository verify (self-test check 22)" {
            $result = Test-WinEaseSelfCheck22PluginLocks -ScriptRoot $script:RepoRoot
            $result.Passed | Should Be $true
        }
        It "Add-WinEaseUserPlugin registers a file only with the hash the user confirmed" {
            $root = Join-Path $script:PluginWork 'repo_add'
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $dll = New-TestPluginDll -Name 'UserAdd'
            $info = Get-WinEasePluginFileInfo -Path $dll
            { Add-WinEaseUserPlugin -Path $dll -ExpectedSha256 ('2' * 64) -RepoRoot $root } | Should Throw 'Nothing was registered'
            Test-Path -LiteralPath (Join-Path $root 'config\user\plugins.lock.psd1') | Should Be $false
            $added = Add-WinEaseUserPlugin -Path $dll -ExpectedSha256 $info.Sha256 -OnError Stop -RepoRoot $root
            $added.File | Should Be 'UserAdd.dll'
            $inventory = @(Get-WinEasePluginInventory -RepoRoot $root)
            $inventory.Count | Should Be 1
            $inventory[0].Status | Should Be 'Ok'
            $inventory[0].OnError | Should Be 'Stop'
            $r = Import-WinEasePlugins -RepoRoot $root -AbstractionsPath $script:AbstractionsDll
            $r.Loaded -contains 'UserAdd' | Should Be $true
        }
        It "ignores DLLs in plugins\user in the repository checkout (the folder holds only the README)" {
            @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'plugins\user') -Filter '*.dll' -ErrorAction SilentlyContinue).Count | Should Be 0
        }
    }

    Context "WinUI host requests (plugins.list, plugins.addUser)" {
        It "lists nothing, shows the hash first and registers only after the confirmation" {
            $root = Join-Path $script:PluginWork 'repo_host'
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'config\ui-strings') -Destination (Join-Path $root 'config\ui-strings') -Recurse
            $dll = New-TestPluginDll -Name 'HostReq'
            $hash = (Get-WinEasePluginFileInfo -Path $dll).Sha256
            $runner = Join-Path -Path $script:PluginWork -ChildPath 'host_requests.ps1'
            $lines = @(
                ". '$($script:GuiCorePath)'"
                ". '$(Join-Path $script:RepoRoot 'gui\WinEaseWinUiHost.ps1')'"
                ". '$(Join-Path $script:RepoRoot 'lib\WinEasePlugins.ps1')'"
                "`$script:WinEaseGuiRepoRoot = '$root'"
                "`$none = [pscustomobject]@{}"
                "`$list0 = @((Invoke-WinEaseWinUiRequest -Op 'plugins.list' -Arguments `$none).Data).Count"
                "`$step1 = Invoke-WinEaseWinUiRequest -Op 'plugins.addUser' -Arguments ([pscustomobject]@{ Path = '$dll' })"
                "`$locked = Test-Path -LiteralPath '$root\config\user\plugins.lock.psd1'"
                "`$step2 = Invoke-WinEaseWinUiRequest -Op 'plugins.addUser' -Arguments ([pscustomobject]@{ Path = '$dll'; ConfirmSha256 = `$step1.Data.Sha256 })"
                "`$list1 = @((Invoke-WinEaseWinUiRequest -Op 'plugins.list' -Arguments `$none).Data)"
                "'RESULT ' + (@(`$list0, `$step1.Data.NeedsConfirm, `$step1.Data.Sha256, `$locked, `$step2.Data.NeedsConfirm, `$list1.Count, `$list1[0].Status) -join '|')"
            )
            [System.IO.File]::WriteAllText($runner, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner)
            $out[-1] | Should Be "RESULT 0|True|$hash|False|False|1|Ok"
        }
    }

    Context "Report" {
        It "lists loaded and refused plugins in the HTML report, HTML-encoded" {
            $report = Join-Path $script:PluginWork 'report.html'
            $rows = @([PSCustomObject]@{ Id = 'Evil<b>'; Version = '1'; Source = 'User'; File = 'e.dll'; Sha256 = ('f' * 64); OnError = 'Warn'; Summary = 's'; Contributions = @('Registry') })
            $rej = @([PSCustomObject]@{ Source = 'User'; File = 'x.dll'; Reason = 'SHA256 mismatch' })
            Export-WinEaseHtmlReport -OutputPath $report -BuildInfo @{ Plugins = $rows; PluginRejected = $rej }
            $html = [System.IO.File]::ReadAllText($report)
            $html | Should Match 'Plugins'
            $html | Should Match 'Evil&lt;b&gt;'
            $html | Should Not Match 'Evil<b>'
            $html | Should Match 'SHA256 mismatch'
        }
    }

    Remove-Item -LiteralPath $script:PluginWork -Recurse -Force -ErrorAction SilentlyContinue
}
