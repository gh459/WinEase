# Harness for the registry snapshot tests (tests\Registry.Tests.ps1).
# Dot-sourced by that test file. Not a test file, so Pester does not discover it.
#
# Invoke-WinEaseRegistryPhaseRecording dot-sources phases\10-registry.ps1 with reg.exe,
# regini.exe and the offline hives replaced by recording stubs, so no real registry is
# touched, and returns one line per reg.exe call:
#   <ACTION><TAB><key><TAB><value name><TAB><type><TAB><data>
# Value name is "(default)" for /ve and empty for a key-only call.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are consumed by the dot-sourced phase')]
param()

$script:RegistryPresets = @('default', 'none', 'extreme', 'balanced', 'vm', 'handheld', 'audio')

function Get-WinEaseRegistryPhaseVariables {
    # The variables the builder derives from a preset (components, variable-mapped tweaks,
    # tweak groups), without running the builder. 'default' = no preset at all.
    param([string]$Preset)
    $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
    $presetData = $null
    if ($Preset -ne 'default') {
        $presetData = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\presets.psd1')).Presets[$Preset]
    }
    $vars = @{}
    foreach ($c in $schema.Components) {
        if (-not $c.Variable -or $c.Type -ne 'Bool') { continue }
        $value = [bool]$c.Default
        if ($presetData -and $presetData.Contains($c.Key)) { $value = [bool]$presetData[$c.Key] }
        $vars[$c.Variable] = $value
    }
    $tweakSettings = [ordered]@{}
    if ($presetData -and $presetData.Contains('TweakSettings')) {
        foreach ($k in $presetData.TweakSettings.Keys) { $tweakSettings[$k] = [bool]$presetData.TweakSettings[$k] }
    }
    foreach ($t in $schema.Tweaks) {
        if ($t.Variable -and $tweakSettings.Contains($t.Key)) { $vars[$t.Variable] = [bool]$tweakSettings[$t.Key] }
    }
    $groups = [ordered]@{ GPULatency = $true; ServiceTrim = $true }
    if ($presetData -and $presetData.Contains('TweakGroups')) {
        foreach ($k in @($groups.Keys)) { if ($presetData.TweakGroups.Contains($k)) { $groups[$k] = [bool]$presetData.TweakGroups[$k] } }
    }
    return @{ Variables = $vars; TweakSettings = $tweakSettings; Groups = $groups }
}

function Invoke-WinEaseRegistryPhaseRecording {
    param([Parameter(Mandatory = $true)][string]$Preset)

    $info = Get-WinEaseRegistryPhaseVariables -Preset $Preset
    $script:RegCalls = [System.Collections.Generic.List[string]]::new()
    $script:TweakSettings = if ($Preset -eq 'default') { $null } else { $info.TweakSettings }
    $script:TweakKeyAliases = [ordered]@{}
    $script:activeTweakGroups = $info.Groups
    foreach ($name in $info.Variables.Keys) { Set-Variable -Name $name -Value $info.Variables[$name] }

    $scratchDir = 'Z:\WinEaseTest\scratch'
    $scriptDir = $script:RepoRoot
    $UserName = 'TestUser'
    $DryRun = $false
    # every Advanced Debloat target that owns a service, so all service branches run
    $script:advancedDebloatStandard = @(
        'Remove Print Spooler (service + binary) [20-30MB]',
        'Remove Bluetooth stack (service + binary) [20-40MB]',
        'Remove Remote Desktop host (service + binary) [30-50MB]',
        'Remove touch/pen/ink components [20-30MB]',
        'Physical: BitLocker (complete removal) [~30-50MB]',
        'Physical: Defender (complete removal) [~50MB]',
        'Physical: Windows Firewall (complete removal) [~20-40MB]',
        'Remove SNMP service [2MB]',
        'Remove Fax service [5MB]',
        'Remove Telnet/TFTP client [1MB]'
    )
    $script:advancedDebloatExperimental = @()
    $script:WinEaseRemovedAppxPackages = @([pscustomobject]@{ FullName = 'Test.App_1.0.0.0_x64__abc'; ShortName = 'Test.App'; PublisherId = 'abc' })
    $script:WinEaseTargetBuild = $null

    # --- stubs --------------------------------------------------------------------------
    function reg.exe {
        $a = @($args | ForEach-Object { [string]$_ })
        $verb = $a[0]
        $key = $a[1]
        if ($verb -eq 'add' -or $verb -eq 'delete') {
            $name = ''; $type = ''; $data = ''
            for ($i = 2; $i -lt $a.Count; $i++) {
                switch ($a[$i]) {
                    '/v' { $name = $a[++$i] }
                    '/ve' { $name = '(default)' }
                    '/t' { $type = $a[++$i] }
                    '/d' { $data = $a[++$i] }
                    '/f' { }
                    default { $script:RegCalls.Add("UNPARSED`t$($a -join ' ')") }
                }
            }
            $script:RegCalls.Add("$($verb.ToUpperInvariant())`t$key`t$name`t$type`t$data")
            $global:LASTEXITCODE = 0
            return
        }
        if ($verb -eq 'load') {
            $script:RegCalls.Add("LOAD`t$key")
            $global:LASTEXITCODE = 0
            return
        }
        if ($verb -eq 'query') {
            # present: the services the Advanced Debloat targets disable, the optional Microsoft
            # Security drivers and the staged AppX registrations of the removed package
            $present = $key -match '\\ControlSet001\\Services\\(MsSecCore|MsSecFlt|Spooler|PrintNotify|bthserv|BthAvctpSvc|BluetoothUserService|TermService|UmRdpService|TabletInputService|fvevc|MpsSvc|SNMP|Fax|Telnet|TFTP|WinDefend|MDCoreSvc|WdNisSvc|Sense|SecurityHealthService)$' -or
                $key -match 'AppxAllUserStore\\InboxApp\\Test\.App'
            # a deleted Defender service key is gone again (the phase verifies the delete)
            if ($key -match '\\Services\\(WinDefend|MDCoreSvc|WdNisSvc|Sense|SecurityHealthService)$' -and $script:RegCalls.Contains("DELETE`t$key`t`t`t")) { $present = $false }
            $script:RegCalls.Add("QUERY`t$key")
            $global:LASTEXITCODE = if ($present) { 0 } else { 1 }
            return
        }
        $script:RegCalls.Add("UNPARSED`t$($a -join ' ')")
        $global:LASTEXITCODE = 1
    }
    function regini.exe { $script:RegCalls.Add("REGINI`t$($args -join ' ')"); $global:LASTEXITCODE = 0 }

    . (Join-Path $script:RepoRoot 'WinEasehelpers.ps1')
    . (Join-Path $script:RepoRoot 'lib\WinEaseDebloat.ps1')
    $registryLib = Join-Path $script:RepoRoot 'lib\WinEaseRegistry.ps1'
    if (Test-Path -LiteralPath $registryLib) { . $registryLib }
    . (Join-Path $script:RepoRoot 'lib\WinEaseSecrets.ps1')
    # The Winlogon password is written through the .NET registry API (not reg.exe); record it in the same
    # line format as a reg.exe call ('""' = empty data) so the snapshots stay comparable.
    function Set-WinEaseRegistrySecretString {
        param([string]$Key, [string]$Name, [string]$Value)
        $data = if ($Value) { $Value } else { '""' }
        $script:RegCalls.Add("ADD`t$Key`t$Name`tREG_SZ`t$data")
        return $true
    }

    # The built-in plugins (Latency, UpstreamSync) are part of the phase: the hook after phase 10 and the
    # contributions at its end run exactly like in the builder. The delegates of a plugin host run in a
    # module scope, so the recording stubs are also visible globally while the phase runs.
    . (Join-Path $script:RepoRoot 'lib\WinEasePlugins.ps1')
    if (-not $script:RegistryHarnessPlugins) {
        $script:RegistryHarnessPlugins = Import-WinEasePlugins -RepoRoot $script:RepoRoot
        if ($script:RegistryHarnessPlugins.LoadedCount -lt 3) { throw "The built-in plugins did not load: $(@($script:RegistryHarnessPlugins.Rejected | ForEach-Object { $_.Reason }) -join '; ')" }
    }
    Set-Item -Path 'Function:\global:reg.exe' -Value ${function:reg.exe}
    Set-Item -Path 'Function:\global:regini.exe' -Value ${function:regini.exe}
    try {
        $null = . (Join-Path $script:RepoRoot 'phases\10-registry.ps1') 6>$null 3>$null
        Invoke-WinEasePluginHook -Phase '10-registry' -Stage After 6>$null 3>$null
    } finally {
        Remove-Item -Path 'Function:\global:reg.exe', 'Function:\global:regini.exe' -ErrorAction SilentlyContinue
    }
    return @($script:RegCalls | Where-Object { $_ -notlike 'QUERY*' -and $_ -notlike 'REGINI*' })
}

function ConvertTo-WinEaseRegistryFinalState {
    # Sequential semantics of a call list: a key delete drops everything below the key and
    # leaves a DELETED marker, a value delete leaves the marker for the value, an add sets it. The result maps "key|value name" to
    # "type|data" (last write wins). Values written more than once are returned in Duplicates.
    param([string[]]$Calls)
    $state = @{}
    $seen = @{}
    $duplicates = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Calls) {
        $f = $line -split "`t"
        $action = $f[0]
        if ($action -eq 'LOAD') { continue }
        $key = $f[1].ToLowerInvariant()
        $name = $f[2].ToLowerInvariant()
        if ($action -eq 'ADD') {
            $id = "$key|$name"
            $value = "$($f[3])|$($f[4])"
            if ($seen.ContainsKey($id) -and $state[$id] -ne $value) { $duplicates.Add("$id $($state[$id]) -> $value") }
            $seen[$id] = $true
            $state[$id] = $value
        } elseif ($action -eq 'DELETE') {
            if ($name) {
                $state["$key|$name"] = 'DELETED'
            } else {
                foreach ($id in @($state.Keys)) {
                    if ($id.StartsWith("$key|") -or $id.StartsWith("$key\")) { $state.Remove($id) }
                }
                $state["$key|"] = 'DELETED'
            }
        }
    }
    return @{ State = $state; Duplicates = $duplicates }
}
