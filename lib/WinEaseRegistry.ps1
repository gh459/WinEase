# WinEaseRegistry.ps1 - offline registry access for phase 10 (function definitions only).
# Dot-sourced by WinEasebuilder.ps1 into the builder's script scope.
#
#   Invoke-WinEaseReg            the one place that runs reg.exe add / delete / query
#   Mount-WinEaseRegistryHive    reg.exe load of an offline hive (throws on failure)
#   Invoke-WinEaseRegistryTable  applies a config\registry\<section>.psd1 table
#
# Keeping every reg.exe call behind Invoke-WinEaseReg is what makes phase 10 testable:
# a test replaces the function (or reg.exe itself) and records the calls instead of
# touching a hive. See tests\Registry.Tests.ps1 and tests\fixtures\registry\.

function Invoke-WinEaseReg {
    <#
    .SYNOPSIS
        Runs reg.exe add / delete / query. With -PassThru it returns $true when reg.exe exits with 0.
    .DESCRIPTION
        add     reg.exe add <Key> [/v <Name> | /ve] [/t <Type>] [/d <Data>] /f
        delete  reg.exe delete <Key> [/v <Name>] /f
        query   reg.exe query <Key> [/v <Name>]
        The output of reg.exe is discarded; callers that need to know whether the
        call worked use -PassThru (a bare call emits nothing, which matters because
        the phases are dot-sourced and their output would reach the builder's pipeline).
        -DefaultValue targets the unnamed (default)
        value of the key. An empty string has to be passed as the literal '""': a
        native call drops an empty argument, so reg.exe would take the next switch as
        the value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Add', 'Delete', 'Query')][string]$Action,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Name,
        [switch]$DefaultValue,
        [string]$Type,
        [string]$Data,
        [switch]$PassThru
    )
    $regArgs = [System.Collections.Generic.List[string]]::new()
    $regArgs.Add($Action.ToLowerInvariant())
    $regArgs.Add($Key)
    if ($DefaultValue) {
        $regArgs.Add('/ve')
    } elseif (-not [string]::IsNullOrEmpty($Name)) {
        $regArgs.Add('/v')
        $regArgs.Add($Name)
    }
    if ($Action -eq 'Add') {
        if (-not [string]::IsNullOrEmpty($Type)) {
            $regArgs.Add('/t')
            $regArgs.Add($Type)
        }
        if ($PSBoundParameters.ContainsKey('Data')) {
            $regArgs.Add('/d')
            $regArgs.Add($Data)
        }
    }
    if ($Action -ne 'Query') { $regArgs.Add('/f') }
    & reg.exe @regArgs > $null 2>&1
    if ($PassThru) { return ($LASTEXITCODE -eq 0) }
}

function Mount-WinEaseRegistryHive {
    <#
    .SYNOPSIS
        Loads an offline hive file below HKLM\<Name> and throws when reg.exe fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $loadOutput = & reg.exe load "HKLM\$Name" "$Path" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline registry hive HKLM\$Name from '$Path' (Exit code: $LASTEXITCODE): $loadOutput"
    }
}

function Get-WinEaseRegistryTableRoot {
    # config\registry in the repository (next to lib\), or the folder itself in a flat bundle.
    $libRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    foreach ($candidate in @(
            (Join-Path -Path (Split-Path -Parent $libRoot) -ChildPath 'config\registry'),
            (Join-Path -Path $libRoot -ChildPath 'registry'))) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    return $null
}

function Import-WinEaseRegistryTable {
    <#
    .SYNOPSIS
        Reads config\registry\<Section>.psd1 and returns its entries (an array of hashtables).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [string]$TableRoot
    )
    if ([string]::IsNullOrWhiteSpace($TableRoot)) { $TableRoot = Get-WinEaseRegistryTableRoot }
    $path = if ($TableRoot) { Join-Path -Path $TableRoot -ChildPath "$Section.psd1" } else { $null }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Registry table not found: config\registry\$Section.psd1"
    }
    $data = Import-PowerShellDataFile -LiteralPath $path
    return @($data.Entries)
}

function Add-WinEaseRegistryWriteFailure {
    <#
    .SYNOPSIS
        Records a registry write that reg.exe refused, for Assert-WinEaseRegistryWrites.
    #>
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Name)
    if ($null -eq $script:RegistryWriteFailures) { $script:RegistryWriteFailures = [System.Collections.Generic.List[string]]::new() }
    $script:RegistryWriteFailures.Add($(if ($Name) { "$Key [$Name]" } else { $Key }))
}

function Assert-WinEaseRegistryWrites {
    <#
    .SYNOPSIS
        Reports the registry writes that failed since the list was last cleared.
    .DESCRIPTION
        The failures are listed in a warning and kept in $script:DiagnosticData['RegistryWriteFailures'].
        With -Strict (the builder's -StrictRegistryWrites) the first call with failures throws, so
        an image with a partly applied registry is not turned into an ISO.
    #>
    [CmdletBinding()]
    param([string]$Stage = 'registry', [switch]$Strict)
    $failures = @($script:RegistryWriteFailures)
    if ($failures.Count -eq 0) { return }
    $shown = @($failures | Select-Object -First 15)
    $more = if ($failures.Count -gt $shown.Count) { " (+$($failures.Count - $shown.Count) more)" } else { '' }
    if ($script:DiagnosticData -is [System.Collections.IDictionary]) { $script:DiagnosticData['RegistryWriteFailures'] = $failures }
    $message = "$($failures.Count) registry write(s) failed in ${Stage}: $($shown -join '; ')$more"
    if ($Strict) { throw $message }
    Write-Warning $message
}

function Invoke-WinEaseRegistryTable {
    <#
    .SYNOPSIS
        Writes the entries of config\registry\<Section>.psd1 into the loaded offline hives.
    .DESCRIPTION
        Entry: @{ Tweak; Default; Hive; Path; Name; Type; Data; MinBuild; MaxBuild; OffData; OffType }
          Tweak     the setting that gates the entry (Test-TweakEnabled). Empty = always.
          OffData   optional: the data written while the setting is switched OFF (the counterpart of
                    Data, e.g. the light theme for EnableDarkTheme); OffType defaults to Type
          Default   value of the setting when no profile / preset sets it
          Hive      offline hive (zSYSTEM, zSOFTWARE, zDEFAULT, zNTUSER, zCOMPONENTS) or a
                    list of them; the entry is written to each
          Path      key below the hive
          Name      value name; empty or '(default)' = the unnamed value
          Type      REG_SZ, REG_DWORD, ... Data is passed to reg.exe as it is
          MinBuild / MaxBuild  inclusive Windows build numbers the entry applies to
                    (0 / absent = no limit); compared with $script:WinEaseTargetBuild,
                    and ignored while the target build is unknown
        -Entries runs entries the caller built instead of a table file (the registry entries that
        plugins contribute, see Get-WinEasePluginContributions); the same rules apply to them.
        -Tweak limits the run to the entries of one setting. -Unconditional skips the
        Test-TweakEnabled gate for callers that already decided (for example
        "$radicalRAM -or Test-TweakEnabled 'SvcHostConsolidation'"); the build range
        still applies.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Section')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Section')][string]$Section,
        [Parameter(Mandatory = $true, ParameterSetName = 'Entries')][AllowEmptyCollection()][object[]]$Entries,
        [string]$Tweak,
        [switch]$Unconditional,
        [Parameter(ParameterSetName = 'Section')][string]$TableRoot
    )
    $build = 0
    if ($null -ne $script:WinEaseTargetBuild) { [void][int]::TryParse([string]$script:WinEaseTargetBuild, [ref]$build) }
    $tableEntries = if ($PSCmdlet.ParameterSetName -eq 'Entries') { $Entries } else { Import-WinEaseRegistryTable -Section $Section -TableRoot $TableRoot }
    foreach ($entry in $tableEntries) {
        $entryTweak = [string]$entry.Tweak
        if ($Tweak -and $entryTweak -ne $Tweak) { continue }
        # A setting that is switched off writes the entry's OffData/OffType (its counterpart) when the
        # entry has one; an entry without OffData writes nothing, as before.
        $isOff = $false
        if ($entryTweak -and -not $Unconditional) {
            if (-not (Test-TweakEnabled $entryTweak ([bool]$entry.Default))) {
                if ($null -eq $entry.OffData) { continue }
                $isOff = $true
            }
        }
        if ($build -gt 0) {
            if ($entry.MinBuild -and $build -lt [int]$entry.MinBuild) { continue }
            if ($entry.MaxBuild -and $build -gt [int]$entry.MaxBuild) { continue }
        }
        $valueType = [string]$entry.Type
        $data = [string]$entry.Data
        if ($isOff) {
            $data = [string]$entry.OffData
            if ($entry.OffType) { $valueType = [string]$entry.OffType }
        }
        # An empty argument is dropped by a native call. A string value gets the literal ""; for
        # other types the data is left out, so reg.exe never takes the next switch as the data.
        $dataArgs = @{}
        if ($data -ne '') { $dataArgs.Data = $data }
        elseif ($valueType -in @('REG_SZ', 'REG_EXPAND_SZ')) { $dataArgs.Data = '""' }
        $isDefault = ([string]::IsNullOrEmpty([string]$entry.Name) -or [string]$entry.Name -eq '(default)')
        foreach ($hive in @($entry.Hive)) {
            $key = "HKLM\$hive\$($entry.Path)"
            # P1-01: reg.exe's exit status is read. Only an explicit $false counts as a failed write
            # (a stand-in that returns nothing is not a failure).
            $written = if ($isDefault) {
                Invoke-WinEaseReg -Action Add -Key $key -DefaultValue -Type $valueType -PassThru @dataArgs
            } else {
                Invoke-WinEaseReg -Action Add -Key $key -Name ([string]$entry.Name) -Type $valueType -PassThru @dataArgs
            }
            if ($written -is [bool] -and -not $written) {
                Add-WinEaseRegistryWriteFailure -Key $key -Name $(if ($isDefault) { '(default)' } else { [string]$entry.Name })
            }
        }
    }
}
