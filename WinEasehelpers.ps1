# WinEasehelpers.ps1 - compatibility loader for the split helper modules.
# Dot-source this file exactly as before; it loads the function-only modules from
# lib\ in the repository, or from the same directory in a flat migration bundle.

$helperRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:WinEaseHelperRoot = $helperRoot
$helperFiles = @(
    'WinEasePathSafety.ps1'
    'WinEaseSystem.ps1'
    'WinEaseFileSystem.ps1'
    'WinEaseConfig.ps1'
    'WinEaseBenchmarks.ps1'
    'WinEaseDependencies.ps1'
)
$helperCandidates = @(
    (Join-Path -Path $helperRoot -ChildPath 'lib')
    $helperRoot
)
foreach ($helperFile in $helperFiles) {
    $helperPath = $null
    foreach ($candidate in $helperCandidates) {
        $probe = Join-Path -Path $candidate -ChildPath $helperFile
        if (Test-Path -LiteralPath $probe) {
            $helperPath = $probe
            break
        }
    }
    if (-not $helperPath) {
        throw "WinEase helper module not found: $helperFile (searched: $($helperCandidates -join ', '))"
    }
    . $helperPath
}
# Keep the caller's scope clean: only the functions, the class and $script:WinEaseHelperRoot remain.
Remove-Variable -Name helperRoot, helperFiles, helperCandidates, helperFile, helperPath, candidate, probe -ErrorAction SilentlyContinue
