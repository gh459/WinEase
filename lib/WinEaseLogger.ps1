# WinEaseLogger.ps1 - Structured logging module for WinEase
# Dot-sourced by WinEasebuilder.ps1 or tested directly.

$script:WinEaseLogWarningCount = 0
$script:WinEaseLogErrorCount = 0
$script:WinEaseLogEntries = [System.Collections.Generic.List[object]]::new()

function Redact-WinEaseSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $masked = $Text -replace '(?i)(password|secret|token|apikey|key)\s*[:=]\s*[^\s]+', '$1: [REDACTED]'
    $masked = $masked -replace '[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}', 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'
    return $masked
}

function New-WinEaseLogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Success')]
        [string]$Level = 'Info'
    )

    $cleanMessage = Redact-WinEaseSecret -Text $Message

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Level     = $Level
        Message   = $cleanMessage
    }

    if ($null -ne $script:WinEaseLogEntries) {
        $script:WinEaseLogEntries.Add($entry)
    }

    if ($Level -eq 'Warning') {
        $script:WinEaseLogWarningCount++
    } elseif ($Level -eq 'Error') {
        $script:WinEaseLogErrorCount++
    }

    return $entry
}

function Reset-WinEaseLogState {
    [CmdletBinding()]
    param()

    $script:WinEaseLogWarningCount = 0
    $script:WinEaseLogErrorCount = 0
    $script:WinEaseLogEntries = [System.Collections.Generic.List[object]]::new()
}
