# WinEaseCustomScriptIntegrity.ps1 - shared integrity check for the custom post-install scripts
#
# This file is the single implementation of the check. The build copies it to
# C:\Windows\Setup\Scripts\WinEaseCustomScriptIntegrity.ps1 and both runtime paths dot-source it:
#   - FirstLogon.ps1 (elevated, scripts in C:\Windows\Setup\Scripts\Custom, manifest key '<name>')
#   - UserOnce.ps1   (standard user, scripts in C:\Windows\Setup\Scripts\UserCustom, key 'user/<name>')
# The runtime scripts treat a missing or broken copy of this file as "verification unknown" and run
# nothing (fail-closed).
#
# What the check guarantees: a script runs only when its SHA-256 equals the value recorded in
# custom-scripts-manifest.json at build time. It does NOT prove who wrote the script, and it does not
# protect against anyone who can rewrite both the script and the manifest (for example an
# administrator of the installed system or someone who can modify the ISO). See docs\SECURITY_OPTIONS.md.
#
# PowerShell 5.1 compatible. The file only defines functions and sets no variables, so dot-sourcing it
# cannot change the state of the calling script.

function Read-WinEaseCustomScriptManifest {
    # Returns @{ Ok; Entries; Error }. Ok is $true only for a manifest whose every entry is valid:
    # one bad entry makes the whole manifest untrusted, since a partially corrupt file is no
    # evidence of what the build wrote.
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = @{ Ok = $false; Entries = $null; Error = $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $result.Error = "the manifest does not exist ($Path)"
            return $result
        }
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $result.Error = 'the manifest is empty'
            return $result
        }
        try {
            $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        } catch {
            $result.Error = "the manifest is not valid JSON: $($_.Exception.Message)"
            return $result
        }
        if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
            $result.Error = 'the manifest is not a JSON object of file name to SHA-256'
            return $result
        }
        $entries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($prop in @($parsed.psobject.Properties)) {
            $key = [string]$prop.Name
            if ($key -notmatch '^(?:user/)?[^\\/:*?"<>|]+$' -or $key -match '(^|/)\.\.?$') {
                $result.Error = "the manifest holds an invalid file name entry '$key'"
                return $result
            }
            $value = $prop.Value
            if ($value -isnot [string] -or $value -notmatch '^[0-9A-Fa-f]{64}$') {
                $result.Error = "the manifest entry '$key' has no valid SHA-256 value"
                return $result
            }
            if ($entries.ContainsKey($key)) {
                $result.Error = "the manifest holds the entry '$key' twice"
                return $result
            }
            $entries[$key] = $value.ToUpperInvariant()
        }
        if ($entries.Count -eq 0) {
            $result.Error = 'the manifest holds no entry'
            return $result
        }
        $result.Entries = $entries
        $result.Ok = $true
    } catch {
        $result.Error = "the manifest could not be read: $($_.Exception.Message)"
    }
    return $result
}

function Get-WinEaseCustomScriptSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fs = $null
    $sha = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return [System.BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '')
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

function Test-WinEaseCustomScriptAllowed {
    # Decides whether one custom script may run. Returns @{ Allowed; Reason; Key }.
    # Every check that cannot be completed counts as a refusal.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedDirectory,
        [AllowEmptyString()][string]$KeyPrefix = '',
        [Parameter(Mandatory = $true)]$Manifest
    )
    $verdict = @{ Allowed = $false; Reason = $null; Key = $null }
    try {
        if ($null -eq $Manifest -or -not $Manifest.Ok) {
            $why = if ($null -ne $Manifest -and $Manifest.Error) { $Manifest.Error } else { 'the manifest was not loaded' }
            $verdict.Reason = "The custom script manifest is missing or invalid ($why)"
            return $verdict
        }
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDir = [System.IO.Path]::GetFullPath($ExpectedDirectory).TrimEnd('\', '/')
        $parent = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not [string]::Equals($parent, $fullDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            $verdict.Reason = "The file is not directly inside the custom script folder '$fullDir'"
            return $verdict
        }
        $name = [System.IO.Path]::GetFileName($fullPath)
        $key = "$KeyPrefix$name"
        $verdict.Key = $key
        if ($key -notmatch '^(?:user/)?[^\\/:*?"<>|]+$') {
            $verdict.Reason = "The file name '$name' is not allowed"
            return $verdict
        }
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $verdict.Reason = 'The path is a folder, not a file'
            return $verdict
        }
        $reparse = [System.IO.FileAttributes]::ReparsePoint
        if (($item.Attributes -band $reparse) -ne 0) {
            $verdict.Reason = 'The file is a symbolic link or another reparse point'
            return $verdict
        }
        $dirItem = Get-Item -LiteralPath $fullDir -Force -ErrorAction Stop
        if (($dirItem.Attributes -band $reparse) -ne 0) {
            $verdict.Reason = 'The custom script folder is a junction or another reparse point'
            return $verdict
        }
        if (-not $Manifest.Entries.ContainsKey($key)) {
            $verdict.Reason = 'File is not listed in build-time integrity manifest'
            return $verdict
        }
        $expected = $Manifest.Entries[$key]
        $actual = $null
        try { $actual = Get-WinEaseCustomScriptSha256 -Path $fullPath } catch {
            $verdict.Reason = "The SHA-256 of the file could not be computed: $($_.Exception.Message)"
            return $verdict
        }
        if (-not [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            $verdict.Reason = "Hash mismatch (Expected: $expected, Got: $actual)"
            return $verdict
        }
        $verdict.Allowed = $true
        $verdict.Reason = 'SHA-256 matches the build-time manifest'
    } catch {
        $verdict.Allowed = $false
        $verdict.Reason = "The integrity check failed: $($_.Exception.Message)"
    }
    return $verdict
}

function Get-WinEaseCustomScriptMissingEntries {
    # Manifest entries of one folder whose file is gone. They do not run anything, but are logged so
    # that a script that was expected and silently did not run is visible.
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [AllowEmptyString()][string]$KeyPrefix = '',
        [Parameter(Mandatory = $true)]$Manifest
    )
    $missing = @()
    if ($null -eq $Manifest -or -not $Manifest.Ok) { return $missing }
    foreach ($key in @($Manifest.Entries.Keys)) {
        if ($KeyPrefix) {
            if (-not $key.StartsWith($KeyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $name = $key.Substring($KeyPrefix.Length)
        } else {
            if ($key.Contains('/')) { continue }
            $name = $key
        }
        if (-not (Test-Path -LiteralPath (Join-Path -Path $Directory -ChildPath $name) -PathType Leaf)) { $missing += $key }
    }
    return $missing
}
