# WinEaseLogger.ps1 - Structured logging module for WinEase
# Dot-sourced by WinEasebuilder.ps1 or tested directly.

$script:WinEaseLogWarningCount = 0
$script:WinEaseLogErrorCount = 0
$script:WinEaseLogEntries = [System.Collections.Generic.List[object]]::new()

function New-WinEaseLogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Success')]
        [string]$Level = 'Info'
    )

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Level     = $Level
        Message   = $Message
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
