# WinEaseInputValidation.ps1 - the one place that decides whether the inputs of a build are usable.
# Function definitions only. See docs\INPUT_VALIDATION.md.
#
# Test-WinEaseBuildInputs   inputs -> array of { Field, Severity (Error|Warning), MessageKey, Args, Confirm } (empty = all fine)
# Get-WinEaseInputIssueText issue -> localized text (ui-strings key, falls back to the key + arguments)
# Get-WinEaseInputPattern   the UserName / ComputerName patterns (also used by the window code through the host)
#
# Callers: both GUI windows (on Start and when a field is left), ConvertFrom-WinEaseWinUiResult and Apply-WinEaseGuiResult
# (the GUI is not the trust boundary) and WinEasebuilder.ps1 (command line). The function is pure with respect to the
# build: it never creates, changes or deletes anything that exists. The only write is an optional probe file that is
# created exclusively in a folder (FileOptions.DeleteOnClose, random name) to learn whether the folder is writable.

# UserName / ComputerName are inserted verbatim into autounattend.xml and its embedded scripts, so only these patterns
# are accepted. WinEasebuilder.ps1 keeps the same literals in its [ValidatePattern] attributes (a parameter attribute
# cannot call a function); tests assert that the three places agree.
function Get-WinEaseInputPattern {
    param([Parameter(Mandatory = $true)][ValidateSet('UserName', 'ComputerName')][string]$Name)
    if ($Name -eq 'UserName') { return '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$' }
    return '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$'
}

# Absolute path without a trailing separator; $null when the text is not a valid path
function ConvertTo-WinEaseInputFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
        return $full
    } catch { return $null }
}

# $true when -Child is -Parent or lies below it (both full paths, compared case-insensitively)
function Test-WinEaseInputPathWithin {
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    $p = $Parent.TrimEnd('\')
    if ($Child.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Child.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Can a file be created in -Dir? A uniquely named probe file is created with DeleteOnClose, so it never outlives the call
function Test-WinEaseInputDirWritable {
    param([string]$Dir)
    $probe = Join-Path -Path $Dir -ChildPath ('.wineasetest-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $fs = New-Object System.IO.FileStream($probe, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        $fs.Dispose()
        return $true
    } catch { return $false }
}

# The check of one folder the build writes to. Returns the issues (empty = fine).
#   exists            -> must be a folder (and writable when -Probe)
#   does not exist    -> the nearest existing ancestor must be a folder (and writable when -Probe): then it is creatable
function Test-WinEaseInputWritableFolder {
    param([string]$Field, [string]$Path, [string]$Full, [bool]$Probe)
    $issues = @()
    if (-not $Full) {
        return @([pscustomobject]@{ Field = $Field; Severity = 'Error'; MessageKey = 'Val.Path.Invalid'; Args = @($Path); Confirm = $false })
    }
    if (Test-Path -LiteralPath $Full -PathType Leaf) {
        return @([pscustomobject]@{ Field = $Field; Severity = 'Error'; MessageKey = 'Val.Dir.NotDirectory'; Args = @($Full); Confirm = $false })
    }
    if (Test-Path -LiteralPath $Full -PathType Container) {
        if ($Probe -and -not (Test-WinEaseInputDirWritable -Dir $Full)) {
            $issues += [pscustomobject]@{ Field = $Field; Severity = 'Error'; MessageKey = 'Val.Dir.NotWritable'; Args = @($Full); Confirm = $false }
        }
        return @($issues)
    }
    $anc = $Full
    while ($anc -and -not (Test-Path -LiteralPath $anc)) {
        $parent = [System.IO.Path]::GetDirectoryName($anc)
        if (-not $parent -or $parent -eq $anc) { $anc = $null; break }
        $anc = $parent
    }
    if (-not $anc -or -not (Test-Path -LiteralPath $anc -PathType Container)) {
        return @([pscustomobject]@{ Field = $Field; Severity = 'Error'; MessageKey = 'Val.Dir.NotCreatable'; Args = @($Full); Confirm = $false })
    }
    if ($Probe -and -not (Test-WinEaseInputDirWritable -Dir $anc)) {
        $issues += [pscustomobject]@{ Field = $Field; Severity = 'Error'; MessageKey = 'Val.Dir.NotCreatable'; Args = @($Full); Confirm = $false }
    }
    return @($issues)
}

# -SourceDrive   an ISO file, a drive letter (E: / E:\) or a path on a drive that holds sources\install.wim|esd
# -WorkDir       empty = the builder's default workspace (Documents\WinEase_workspace)
# -OutputDir     the folder the ISO is written to (the builder: its own folder); empty = not checked
# -OutputIsoName optional ISO file name; checked against the source ISO
# -Index         empty = not chosen (a Warning that needs confirmation, never a guessed default); otherwise a positive number;
#                with -AvailableIndices (when known) it must be one of them
# -RequireSource a missing source is an Error (the windows); the command line may leave it out (auto-detect)
# -SkipWriteProbe  no probe file at all (dry runs, and callers that only care about the shape of the values)
# -CheckDiskSpace  free space of the volumes vs. the plan's requirement (Get-WinEaseBuildPlan's figures); Warning only
# -Only          limit the result to these fields (cheap re-validation when one field changes); the checks that need
#                several fields (collisions) run when any of the fields they involve is listed
# A parameter that is not passed is not checked (Apply-WinEaseGuiResult is called with partial results).
function Test-WinEaseBuildInputs {
    [CmdletBinding()]
    param(
        [string]$SourceDrive,
        [string]$WorkDir,
        [string]$OutputDir,
        [string]$OutputIsoName,
        [string]$Index,
        [string]$InjectDrivers,
        [string]$UserName,
        [string]$ComputerName,
        [string[]]$AvailableIndices,
        $Components,
        [string]$PayloadFormat = 'WIM',
        [scriptblock]$FreeSpaceProvider,
        [string[]]$Only,
        [switch]$RequireSource,
        [switch]$SkipWriteProbe,
        [switch]$CheckDiskSpace
    )
    $bound = $PSBoundParameters
    $issues = [System.Collections.Generic.List[object]]::new()
    $add = { param($f, $s, $k, $a, $c) $issues.Add([pscustomobject]@{ Field = $f; Severity = $s; MessageKey = $k; Args = @($a); Confirm = [bool]$c }) }
    $probe = -not $SkipWriteProbe.IsPresent
    $want = { param($names) (-not $Only) -or (@($names | Where-Object { $Only -contains $_ }).Count -gt 0) }

    # --- source ---
    $srcText = "$SourceDrive".Trim().Trim('"')
    $srcIso = $null      # full path of the source ISO
    $srcRoot = $null     # root of the source drive (E:\)
    if (& $want @('SourceDrive')) {
        if ($bound.ContainsKey('SourceDrive') -or $RequireSource) {
            if (-not $srcText) {
                if ($RequireSource) { & $add 'SourceDrive' 'Error' 'Msg.SourceRequired.Text' @() $false }
            } elseif ($srcText.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Test-Path -LiteralPath $srcText -PathType Leaf)) { & $add 'SourceDrive' 'Error' 'Val.Source.IsoMissing' @($srcText) $false }
            } elseif ($srcText -match '^([A-Za-z]):?(\\.*)?$') {
                $letter = $Matches[1]
                if (-not (Test-Path -LiteralPath "${letter}:\sources\install.wim") -and -not (Test-Path -LiteralPath "${letter}:\sources\install.esd")) {
                    & $add 'SourceDrive' 'Error' 'Val.Source.NoImage' @("${letter}:") $false
                }
            } else {
                & $add 'SourceDrive' 'Error' 'Val.Source.Invalid' @($srcText) $false
            }
        }
    }
    if ($srcText) {
        if ($srcText.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) { $srcIso = ConvertTo-WinEaseInputFullPath $srcText }
        elseif ($srcText -match '^([A-Za-z]):?(\\.*)?$') { $srcRoot = "$($Matches[1].ToUpper()):\" }
    }

    # --- work / output folders ---
    $workText = "$WorkDir".Trim()
    $workChecked = $bound.ContainsKey('WorkDir')
    if ($workChecked -and -not $workText) {
        $workText = if (Get-Command -Name Get-WinEaseGuiDefaultWorkDir -ErrorAction SilentlyContinue) { Get-WinEaseGuiDefaultWorkDir }
                    else {
                        $docs = [Environment]::GetFolderPath('MyDocuments')
                        if (-not $docs) { $docs = Join-Path $env:USERPROFILE 'Documents' }
                        Join-Path -Path $docs -ChildPath 'WinEase_workspace'
                    }
    }
    $workFull = if ($workText) { ConvertTo-WinEaseInputFullPath $workText } else { $null }
    $outText = "$OutputDir".Trim()
    $outFull = if ($outText) { ConvertTo-WinEaseInputFullPath $outText } else { $null }
    if ($workText -and (& $want @('WorkDir'))) {
        foreach ($i in @(Test-WinEaseInputWritableFolder -Field 'WorkDir' -Path $workText -Full $workFull -Probe $probe)) { $issues.Add($i) }
    }
    if ($outText -and (& $want @('OutputDir'))) {
        foreach ($i in @(Test-WinEaseInputWritableFolder -Field 'OutputDir' -Path $outText -Full $outFull -Probe $probe)) { $issues.Add($i) }
    }

    # --- collisions (a folder the build empties or writes into must not hold another input or output) ---
    if (& $want @('SourceDrive', 'WorkDir', 'OutputDir')) {
        if ($workFull -and $outFull) {
            if ($workFull.Equals($outFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                & $add 'OutputDir' 'Error' 'Val.Collision.WorkOutputSame' @($workFull) $false
            } elseif (Test-WinEaseInputPathWithin -Child $outFull -Parent $workFull) {
                & $add 'OutputDir' 'Error' 'Val.Collision.OutputInWork' @($outFull, $workFull) $false
            } elseif (Test-WinEaseInputPathWithin -Child $workFull -Parent $outFull) {
                & $add 'WorkDir' 'Warning' 'Val.Collision.WorkInOutput' @($workFull, $outFull) $false
            }
        }
        if ($srcIso) {
            if ($workFull -and (Test-WinEaseInputPathWithin -Child $srcIso -Parent $workFull)) {
                & $add 'SourceDrive' 'Error' 'Val.Collision.SourceInWork' @($srcIso, $workFull) $false
            }
        }
        if ($srcRoot) {
            foreach ($pair in @(@('WorkDir', $workFull), @('OutputDir', $outFull))) {
                if ($pair[1] -and ($pair[1].TrimEnd('\') + '\').Equals($srcRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    & $add $pair[0] 'Error' 'Val.Collision.SourceIsFolder' @($pair[1]) $false
                }
            }
        }
    }
    if ("$OutputIsoName".Trim() -and (& $want @('SourceDrive', 'OutputDir'))) {
        $isoName = "$OutputIsoName".Trim()
        if (-not $isoName.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) { $isoName += '.iso' }
        if ($isoName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            & $add 'OutputDir' 'Error' 'Val.OutputName.Invalid' @($OutputIsoName) $false
        } elseif ($srcIso -and $outFull) {
            $target = ConvertTo-WinEaseInputFullPath (Join-Path -Path $outFull -ChildPath $isoName)
            if ($target -and $target.Equals($srcIso, [System.StringComparison]::OrdinalIgnoreCase)) {
                & $add 'OutputDir' 'Error' 'Val.Collision.OutputIsSource' @($target) $false
            }
        }
    }

    # --- drivers ---
    if ((& $want @('InjectDrivers')) -and "$InjectDrivers".Trim()) {
        $drv = "$InjectDrivers".Trim().Trim('"')
        if (Test-Path -LiteralPath $drv -PathType Leaf) { & $add 'InjectDrivers' 'Error' 'Val.Drivers.NotDirectory' @($drv) $false }
        elseif (-not (Test-Path -LiteralPath $drv -PathType Container)) { & $add 'InjectDrivers' 'Error' 'Val.Drivers.Missing' @($drv) $false }
    }

    # --- names (same patterns as the builder's [ValidatePattern]) ---
    if ((& $want @('UserName')) -and ($bound.ContainsKey('UserName'))) {
        if ("$UserName" -notmatch (Get-WinEaseInputPattern -Name UserName)) { & $add 'UserName' 'Error' 'Msg.InvalidUserName.Text' @() $false }
    }
    if ((& $want @('ComputerName')) -and ($bound.ContainsKey('ComputerName'))) {
        $cn = if ("$ComputerName".Trim()) { "$ComputerName".Trim() } else { '*' }
        if ($cn -notmatch (Get-WinEaseInputPattern -Name ComputerName)) { & $add 'ComputerName' 'Error' 'Msg.InvalidComputerName.Text' @() $false }
    }

    # --- edition index: never guessed ---
    if ((& $want @('Index')) -and ($bound.ContainsKey('Index'))) {
        $ix = "$Index".Trim()
        if (-not $ix) {
            & $add 'Index' 'Warning' 'Val.Index.Unspecified' @() $true
        } elseif ($ix -notmatch '^[0-9]{1,4}$' -or [int]$ix -lt 1) {
            & $add 'Index' 'Error' 'Val.Index.NotNumeric' @($ix) $false
        } elseif ($AvailableIndices -and (@($AvailableIndices | ForEach-Object { "$_".Trim() }) -notcontains $ix.TrimStart('0'))) {
            & $add 'Index' 'Error' 'Val.Index.NotAvailable' @($ix, (@($AvailableIndices) -join ', ')) $false
        }
    }

    # --- free space (Warning only: the builder itself redirects the workspace when a volume is too small) ---
    if ($CheckDiskSpace -and $workFull -and $outFull -and (& $want @('WorkDir', 'OutputDir')) `
            -and (Get-Command -Name Get-WinEaseBuildSizeEstimateMB -ErrorAction SilentlyContinue)) {
        $provider = if ($FreeSpaceProvider) { $FreeSpaceProvider } else { { param($p) Get-WinEaseVolumeFreeBytes -Path $p } }
        $estimateGB = [math]::Round((Get-WinEaseBuildSizeEstimateMB -Components $Components -PayloadFormat $PayloadFormat) / 1024, 2)
        $byVolume = [ordered]@{}
        foreach ($n in @(@{ Path = $workFull; GB = [double](Get-WinEaseRecommendedFreeGB) }, @{ Path = $outFull; GB = $estimateGB })) {
            $vol = [System.IO.Path]::GetPathRoot($n.Path).ToUpper()
            if (-not $byVolume.Contains($vol)) { $byVolume[$vol] = @{ Path = $n.Path; GB = 0.0 } }
            $byVolume[$vol].GB += $n.GB
        }
        foreach ($vol in $byVolume.Keys) {
            $free = $null
            try { $free = & $provider $byVolume[$vol].Path } catch { $free = $null }
            if ($null -eq $free) { continue }   # unknown is reported by the build plan, not here
            $freeGB = [math]::Round([double]$free / 1GB, 1)
            $need = [math]::Round($byVolume[$vol].GB, 1)
            if ($freeGB -lt $need) { & $add 'WorkDir' 'Warning' 'Val.Disk.Insufficient' @($vol, $freeGB, $need) $false }
        }
    }

    return @($issues.ToArray())
}

# $true when any issue is an Error (-Issues: the result of Test-WinEaseBuildInputs)
function Test-WinEaseInputHasError {
    param($Issues)
    return (@(@($Issues) | Where-Object { $_ -and $_.Severity -eq 'Error' }).Count -gt 0)
}

# The same checks for a GUI result (hashtable or object with SourceDrive / WorkDir / Index / InjectDrivers / UserName /
# ComputerName). -Strict (the window's own result): every field is checked, an empty source is an Error, an empty user
# name fails the pattern. Without -Strict (Apply-WinEaseGuiResult is also called with partial results) only the fields
# that carry a value are checked. -OutputDir: where the builder writes the ISO.
function Test-WinEaseGuiResultInputs {
    [CmdletBinding()]
    param(
        $Result,
        [string]$OutputDir,
        [switch]$Strict,
        [switch]$SkipWriteProbe,
        [switch]$CheckDiskSpace
    )
    $get = {
        param($k)
        if ($null -eq $Result) { return $null }
        if ($Result -is [System.Collections.IDictionary]) { if ($Result.Contains($k)) { return $Result[$k] } else { return $null } }
        $p = $Result.PSObject.Properties[$k]
        if ($p) { return $p.Value }
        return $null
    }
    $splat = @{}
    foreach ($k in @('SourceDrive', 'WorkDir', 'Index', 'InjectDrivers', 'UserName', 'ComputerName')) {
        $v = & $get $k
        if ($Strict) { $splat[$k] = "$v" }
        elseif ($null -ne $v -and "$v".Trim()) { $splat[$k] = "$v" }
    }
    if ($OutputDir) { $splat['OutputDir'] = $OutputDir }
    if ($Strict) { $splat['RequireSource'] = $true }
    if ($SkipWriteProbe) { $splat['SkipWriteProbe'] = $true }
    if ($CheckDiskSpace) {
        $splat['CheckDiskSpace'] = $true
        $splat['Components'] = $Result
        $splat['PayloadFormat'] = if ($true -eq (& $get 'ExportESDMode')) { 'ESD' } elseif ($true -eq (& $get 'SplitWIMMode')) { 'SWM' } else { 'WIM' }
    }
    return @(Test-WinEaseBuildInputs @splat)
}

# Localized string for -Key (the window language through Get-WinEaseUiString when the GUI core is loaded, else the English
# table config\ui-strings\en.json next to this lib, else the key); {0}, {1}, ... are filled from -Format
function Get-WinEaseInputText {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Format = @())
    if (Get-Command -Name Get-WinEaseUiString -ErrorAction SilentlyContinue) {
        return (Get-WinEaseUiString $Key -Format $Format)
    }
    if (-not $script:WinEaseInputEnglish) {
        $script:WinEaseInputEnglish = @{}
        try {
            $file = Join-Path -Path (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'config\ui-strings') -ChildPath 'en.json'
            if (Test-Path -LiteralPath $file) {
                $json = [System.IO.File]::ReadAllText($file, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $script:WinEaseInputEnglish[$p.Name] = [string]$p.Value }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $text = if ($script:WinEaseInputEnglish.ContainsKey($Key)) { $script:WinEaseInputEnglish[$Key] } else { $Key }
    if (@($Format).Count -gt 0) { try { $text = $text -f @($Format) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
    return $text
}

# Localized text of one issue
function Get-WinEaseInputIssueText {
    param([Parameter(Mandatory = $true)]$Issue)
    return (Get-WinEaseInputText -Key "$($Issue.MessageKey)" -Format @($Issue.Args | ForEach-Object { "$_" }))
}

# One text with a line per issue ("Field: message"), errors first
function Format-WinEaseInputIssues {
    param($Issues)
    $sorted = @(@($Issues) | Sort-Object { if ($_.Severity -eq 'Error') { 0 } else { 1 } })
    return ((@($sorted | ForEach-Object { "$($_.Field): $(Get-WinEaseInputIssueText -Issue $_)" })) -join "`n")
}