# WinEaseSecrets.ps1 - handling of the user password (function definitions only).
# Dot-sourced by WinEasebuilder.ps1 into the builder's script scope.
#
# The password is unrestricted text and must never become PowerShell source or part of a
# native command line. It is passed as data:
#   ConvertTo-WinEaseSecretBase64        Base64 of the UTF-16LE bytes (A-Za-z0-9+/= only)
#   Expand-WinEaseOobeRepairScript       fills the OOBE helper template (literal String.Replace)
#   Set-WinEaseRegistrySecretString      writes a REG_SZ through the .NET registry API (no reg.exe)
# The helper script decodes the Base64 value at run time (see scripts\setup\WinEase-oobe-autologon-repair.ps1).

function ConvertTo-WinEaseSecretBase64 {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Value))
}

function ConvertFrom-WinEaseSecretBase64 {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Value))
}

function Expand-WinEaseOobeRepairScript {
    <#
    .SYNOPSIS
        Fills the account name and password into the OOBE auto-logon repair helper template.
    .DESCRIPTION
        The password is embedded as Base64 (safe inside a single-quoted literal) and the user
        name has its single quotes doubled. Both substitutions are literal String.Replace calls,
        so no replacement-pattern syntax ($1, $&) is interpreted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The unattended-setup password is a plain string by design (UserPassword builder parameter)')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Account name and password of the unattended setup, not a credential prompt')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][string]$UserName,
        [AllowNull()][AllowEmptyString()][string]$Password
    )
    $safeUser = $UserName.Replace("'", "''")
    $script = $Template.Replace('__WINEASE_USERNAME__', $safeUser).Replace('__WINEASE_USERPASSWORD_B64__', (ConvertTo-WinEaseSecretBase64 -Value $Password))
    # The helper runs with $ErrorActionPreference = 'SilentlyContinue' on the installed system, where a
    # parse error would fail without any message. Fail the build instead (the error text is not shown:
    # it could quote the generated source).
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "The generated OOBE auto-logon helper does not parse ($($parseErrors.Count) error(s))." }
    return $script
}

function Set-WinEaseRegistrySecretString {
    <#
    .SYNOPSIS
        Writes a REG_SZ value below HKLM\ (a loaded offline hive such as HKLM\zSOFTWARE) or HKCU\
        without a command line, so quotes, backslashes and spaces in the value cannot be misparsed.
    .DESCRIPTION
        The value is never written to any output stream or error message. Returns $true on success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )
    if ($Key -notmatch '^(HKLM|HKCU)\\(.+)$') { throw "Unsupported registry key '$Key' (only HKLM\ and HKCU\ are supported)." }
    $root = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $sub = $Matches[2]
    $handle = $null
    try {
        $handle = $root.CreateSubKey($sub)
        if ($null -eq $handle) { Write-Warning "Could not open registry key '$Key'."; return $false }
        $handle.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String)
        return $true
    } catch {
        Write-Warning "Could not write registry value '$Name' below '$Key': $($_.Exception.GetType().Name)"
        return $false
    } finally {
        if ($handle) { $handle.Dispose() }
    }
}

function Set-WinEaseUnattendPassword {
    <#
    .SYNOPSIS
        Sets the password of the local account and of the AutoLogon section in an unattend XML document.
    .DESCRIPTION
        Uses the DOM (InnerText), so XML special characters are escaped by the serializer.
        Returns the number of Value nodes that were set.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The unattended-setup password is a plain string by design (UserPassword builder parameter)')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [AllowNull()][AllowEmptyString()][string]$Password
    )
    if ([string]::IsNullOrEmpty($Password)) { return 0 }
    $nodes = @($Document.SelectNodes("//*[local-name()='UserAccounts']//*[local-name()='Password']/*[local-name()='Value'] | //*[local-name()='AutoLogon']/*[local-name()='Password']/*[local-name()='Value']"))
    foreach ($node in $nodes) { $node.InnerText = $Password }
    return $nodes.Count
}
