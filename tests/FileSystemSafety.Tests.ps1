# FileSystemSafety.Tests.ps1 - regression tests for filesystem and mount safety (spec PR F1)
# Run with:  Invoke-Pester -Path .\tests\FileSystemSafety.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# Covers Test-IsSafePathToDelete, Test-WinEasePathHasReparsePoint, Test-WinEaseMountPathInWorkspace,
# Get-WinEaseMountedImages, Assert-WinEaseDirectorySafety, Reset-DirectoryWithRobocopy,
# Clear-DismMountConflicts and Initialize-WinEaseMountDirectory.
#
# Safety rules for this file: only per-test temp directories are touched, DISM is never run
# (Get-WinEaseMountedImages, dism.exe and every other mount helper is mocked), and links are
# removed with Directory.Delete(link, $false) before a tree is deleted so a cleanup can never
# follow a junction or symlink into its target.
#
# Tests marked -Pending document CURRENT behavior that looks unsafe; each one has a note and is
# reported as a finding. They are intentionally not "fixed" here.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock script blocks run in a different scope than the test; call counters and mocked values must be global')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Mock Start-Sleep/Set-Location to avoid delays and cwd changes during tests')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
if (-not (Get-Command -Name Test-IsSafePathToDelete -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}
# WinEaseMount.ps1 is dot-sourced by the builder, not by the helper loader.
if (-not (Get-Command -Name Initialize-WinEaseMountDirectory -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseMount.ps1")
}

function New-FsTestRoot {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_fs_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}

function New-FsTestJunction {
    param([string]$Link, [string]$Target)
    $null = & cmd.exe /c "mklink /J `"$Link`" `"$Target`"" 2>&1
    if (-not (Test-Path -LiteralPath $Link)) { throw "Could not create junction '$Link'" }
    $script:FsTestLinks.Add($Link)
}

function Remove-FsTestRoot {
    param([string]$Root)
    # Links first, so nothing below can follow them.
    foreach ($l in @($script:FsTestLinks)) {
        if (Test-Path -LiteralPath $l) { try { [System.IO.Directory]::Delete($l, $false) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
    }
    $script:FsTestLinks.Clear()
    if ($Root -and (Test-Path -LiteralPath $Root)) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
}

function Initialize-FsTestState {
    $global:FsDismCalls = 0; $global:FsPurgeCalls = 0; $global:FsResetCalls = 0; $global:FsQueryCalls = 0
    # Fresh module state for every test: no mount dirs, no workspace roots.
    $script:FsTestLinks = [System.Collections.Generic.List[string]]::new()
    $script:ManagedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:AllocatedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:PreservedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:BaseWorkDir = $null
    $script:MountAllocationRoot = $null
    $script:DismMountDir = $null
    $script:VhdxMountDir = $null
    $script:scriptDir = $null
}

# Symlinks need SeCreateSymbolicLinkPrivilege or Developer Mode; probe once.
$script:CanSymlink = $false
try {
    $probeRoot = New-FsTestRoot
    $probeTarget = Join-Path $probeRoot 'target'
    [System.IO.Directory]::CreateDirectory($probeTarget) | Out-Null
    $probeLink = Join-Path $probeRoot 'link'
    New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
    $script:CanSymlink = [bool]((Get-Item -LiteralPath $probeLink -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if (Test-Path -LiteralPath $probeLink) { [System.IO.Directory]::Delete($probeLink, $false) }
} catch {
    $script:CanSymlink = $false
} finally {
    if ($probeRoot -and (Test-Path -LiteralPath $probeRoot)) { Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
$script:FsTestLinks = [System.Collections.Generic.List[string]]::new()

Describe "Test-IsSafePathToDelete" {
    It "refuses empty and whitespace paths" {
        Test-IsSafePathToDelete -Path '' | Should Be $false
        Test-IsSafePathToDelete -Path '   ' | Should Be $false
        Test-IsSafePathToDelete -Path $null | Should Be $false
    }
    It "refuses every drive-root form" {
        foreach ($p in @('C:', 'C:\', 'c:\', 'C:/', 'C:\\', 'D:\', 'C:\.', 'C:\Temp\..')) {
            Test-IsSafePathToDelete -Path $p | Should Be $false
        }
    }
    It "refuses UNC share roots with and without trailing separators" {
        foreach ($p in @('\\server\share', '\\server\share\', '\\server\share\\', '//server/share', '\\SERVER\Share')) {
            Test-IsSafePathToDelete -Path $p | Should Be $false
        }
    }
    It "refuses a path that normalizes to a protected directory via '..'" {
        $win = [System.Environment]::GetFolderPath('Windows')
        Test-IsSafePathToDelete -Path (Join-Path $win 'System32\..') | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path ([System.IO.Path]::GetTempPath()) '..\..\..\..\..\..') | Should Be $false
    }
    It "refuses protected roots and their children regardless of case and trailing separators" {
        $win = [System.Environment]::GetFolderPath('Windows')
        Test-IsSafePathToDelete -Path $win | Should Be $false
        Test-IsSafePathToDelete -Path ($win + '\') | Should Be $false
        Test-IsSafePathToDelete -Path $win.ToUpperInvariant() | Should Be $false
        Test-IsSafePathToDelete -Path $win.ToLowerInvariant() | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $win 'System32') | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $win 'SYSTEM32\') | Should Be $false
        Test-IsSafePathToDelete -Path ([System.Environment]::GetFolderPath('ProgramFiles')) | Should Be $false
        Test-IsSafePathToDelete -Path ([System.Environment]::GetFolderPath('UserProfile')) | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $env:SystemDrive 'Users') | Should Be $false
        Test-IsSafePathToDelete -Path ((Join-Path $env:SystemDrive 'USERS') + '\') | Should Be $false
    }
    It "refuses ancestors of protected directories" {
        Test-IsSafePathToDelete -Path (Split-Path -Parent ([System.Environment]::GetFolderPath('UserProfile'))) | Should Be $false
    }
    It "refuses the repository directory, its subfolders and its parent" {
        Test-IsSafePathToDelete -Path $script:RepoRoot | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $script:RepoRoot 'lib') | Should Be $false
        Test-IsSafePathToDelete -Path (Split-Path -Parent $script:RepoRoot) | Should Be $false
    }
    It "allows an ordinary temp directory, with trailing separators and case variants" {
        $root = New-FsTestRoot
        try {
            $dir = Join-Path $root 'work'
            Test-IsSafePathToDelete -Path $dir | Should Be $true
            Test-IsSafePathToDelete -Path ($dir + '\') | Should Be $true
            Test-IsSafePathToDelete -Path ($dir + '\\') | Should Be $true
            Test-IsSafePathToDelete -Path $dir.ToUpperInvariant() | Should Be $true
            Test-IsSafePathToDelete -Path (Join-Path $dir 'a\..\b') | Should Be $true
        } finally { Remove-FsTestRoot -Root $root }
    }
    It "treats a relative path by its absolute resolution (cwd-based)" {
        # A relative path is resolved against the current directory. The repository (cwd of the
        # test run) is protected, so '.' and 'lib' are refused; '..' goes to the repo parent.
        Push-Location -LiteralPath $script:RepoRoot
        try {
            Test-IsSafePathToDelete -Path '.' | Should Be $false
            Test-IsSafePathToDelete -Path 'lib' | Should Be $false
            Test-IsSafePathToDelete -Path '..' | Should Be $false
            Test-IsSafePathToDelete -Path '..\..\..\..\..\..\..\..' | Should Be $false
        } finally { Pop-Location }
    }
    It "refuses a path under a junction that points into a protected directory (lexical check does not resolve links)" -Pending {
        # FINDING F1-1: Test-IsSafePathToDelete uses GetFullPath only. <tmp>\junc -> %windir% makes
        # <tmp>\junc\System32 evaluate as safe. Callers (Test-CanSafelyDeleteDirectory) must not rely
        # on this predicate alone for link safety. Pending: documents desired behavior, current code returns $true.
        $root = New-FsTestRoot
        Initialize-FsTestState
        try {
            $junc = Join-Path $root 'junc'
            New-FsTestJunction -Link $junc -Target ([System.Environment]::GetFolderPath('Windows'))
            Test-IsSafePathToDelete -Path (Join-Path $junc 'System32') | Should Be $false
        } finally { Remove-FsTestRoot -Root $root }
    }
}

Describe "Test-WinEasePathHasReparsePoint" {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:Outside = Join-Path $script:T 'outside'
        $script:Ws = Join-Path $script:T 'ws'
        [System.IO.Directory]::CreateDirectory((Join-Path $script:Outside 'sub')) | Out-Null
        [System.IO.Directory]::CreateDirectory($script:Ws) | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') -Value 'x'
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "returns false for a plain directory tree and for a not-yet-existing path under it" {
        $plain = Join-Path $script:Ws 'a\b'
        [System.IO.Directory]::CreateDirectory($plain) | Out-Null
        Test-WinEasePathHasReparsePoint -Path $plain -Root $script:Ws | Should Be $false
        Test-WinEasePathHasReparsePoint -Path (Join-Path $script:Ws 'a\new\file.txt') -Root $script:Ws | Should Be $false
        Test-WinEasePathHasReparsePoint -Path $plain | Should Be $false
    }
    It "returns true when the path is outside the root, and for a blank path" {
        Test-WinEasePathHasReparsePoint -Path $script:Outside -Root $script:Ws | Should Be $true
        Test-WinEasePathHasReparsePoint -Path (Join-Path $script:Ws '..\outside') -Root $script:Ws | Should Be $true
        Test-WinEasePathHasReparsePoint -Path ' ' -Root $script:Ws | Should Be $true
    }
    It "refuses a junction as the path itself, as a parent and as the root" {
        $junc = Join-Path $script:Ws 'junc'
        New-FsTestJunction -Link $junc -Target $script:Outside
        Test-WinEasePathHasReparsePoint -Path $junc -Root $script:Ws | Should Be $true
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'sub') -Root $script:Ws | Should Be $true
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'sub\keep.txt') -Root $script:Ws | Should Be $true
        # junction used as the root itself
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'sub') -Root $junc | Should Be $true
        # junction as a parent without a Root argument
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'sub') | Should Be $true
        # never followed: target content is untouched
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
    It "detects a junction case-insensitively" {
        $junc = Join-Path $script:Ws 'Junc'
        New-FsTestJunction -Link $junc -Target $script:Outside
        Test-WinEasePathHasReparsePoint -Path (Join-Path $script:Ws 'JUNC\sub') -Root $script:Ws.ToUpperInvariant() | Should Be $true
    }
    # Symlink tests are skipped (not failed) when this account cannot create symlinks:
    # needs SeCreateSymbolicLinkPrivilege (elevation) or Developer Mode.
    It "refuses a directory symlink as path and as parent (skipped without symlink privilege)" -Skip:(-not $script:CanSymlink) {
        $link = Join-Path $script:Ws 'slink'
        New-Item -ItemType SymbolicLink -Path $link -Target $script:Outside | Out-Null
        $script:FsTestLinks.Add($link)
        Test-WinEasePathHasReparsePoint -Path $link -Root $script:Ws | Should Be $true
        Test-WinEasePathHasReparsePoint -Path (Join-Path $link 'sub') -Root $script:Ws | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
    It "refuses a file symlink (skipped without symlink privilege)" -Skip:(-not $script:CanSymlink) {
        $link = Join-Path $script:Ws 'flink.txt'
        New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:Outside 'sub\keep.txt') | Out-Null
        Test-WinEasePathHasReparsePoint -Path $link -Root $script:Ws | Should Be $true
        Remove-Item -LiteralPath $link -Force
    }
    It "inspects only elements between Root and Path (a link above Root is the caller's concern)" {
        $junc = Join-Path $script:T 'jtop'
        New-FsTestJunction -Link $junc -Target $script:Ws
        # the junction is the root: the root element itself is checked
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'a') -Root $junc | Should Be $true
        # a real directory below the junction used as root: the link above it is not inspected
        [System.IO.Directory]::CreateDirectory((Join-Path $script:Ws 'a')) | Out-Null
        Test-WinEasePathHasReparsePoint -Path (Join-Path $junc 'a') -Root (Join-Path $junc 'a') | Should Be $false
    }
}

Describe "Test-WinEaseMountPathInWorkspace" {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:Base = Join-Path $script:T 'base'
        $script:Alloc = Join-Path $script:T 'alloc'
        $script:BaseWorkDir = $script:Base
        $script:MountAllocationRoot = $script:Alloc
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "accepts the roots and descendants, ignoring case and trailing separators" {
        Test-WinEaseMountPathInWorkspace -Path (Join-Path $script:Alloc 'mount_1') | Should Be $true
        Test-WinEaseMountPathInWorkspace -Path ((Join-Path $script:Alloc 'mount_1') + '\') | Should Be $true
        Test-WinEaseMountPathInWorkspace -Path (Join-Path $script:Base 'x\y').ToUpperInvariant() | Should Be $true
        Test-WinEaseMountPathInWorkspace -Path $script:Base | Should Be $true
    }
    It "rejects outside paths, sibling-prefix paths and '..' escapes" {
        Test-WinEaseMountPathInWorkspace -Path (Join-Path $script:T 'other\mount') | Should Be $false
        Test-WinEaseMountPathInWorkspace -Path ($script:Base + '2\mount') | Should Be $false
        Test-WinEaseMountPathInWorkspace -Path (Join-Path $script:Base '..\other') | Should Be $false
    }
    It "rejects empty, relative and drive-root input" {
        Test-WinEaseMountPathInWorkspace -Path '' | Should Be $false
        Test-WinEaseMountPathInWorkspace -Path $null | Should Be $false
        Test-WinEaseMountPathInWorkspace -Path 'relative\dir' | Should Be $false
        Test-WinEaseMountPathInWorkspace -Path 'C:\' | Should Be $false
    }
    It "rejects everything when no workspace root is configured" {
        $script:BaseWorkDir = $null
        $script:MountAllocationRoot = $null
        Test-WinEaseMountPathInWorkspace -Path (Join-Path $script:Alloc 'mount_1') | Should Be $false
    }
}

Describe "Get-WinEaseMountedImages" {
    BeforeEach { Initialize-FsTestState }

    It "maps Get-WindowsImage -Mounted records and does not call dism.exe on success" {
        Mock Get-WindowsImage { [PSCustomObject]@{ Path = 'C:\ws\m1'; ImagePath = 'C:\ws\a.wim'; ImageIndex = 1; MountStatus = 'Ok' } }
        Mock dism.exe { $global:FsDismCalls++; $global:LASTEXITCODE = 0 }
        $r = @(Get-WinEaseMountedImages)
        @($r | Where-Object { $_.Path -eq 'C:\ws\m1' -and $_.MountStatus -eq 'Ok' }).Count | Should Be 1
        $global:FsDismCalls | Should Be 0
    }
    It "throws (instead of returning an empty list) when both Get-WindowsImage and dism.exe fail" {
        Mock Get-WindowsImage { throw 'simulated query failure' }
        Mock dism.exe { $global:FsDismCalls++; $global:LASTEXITCODE = 5; 'Error: 5' }
        { Get-WinEaseMountedImages } | Should Throw 'Failed to query mounted images'
    }
    It "parses dism.exe /Get-MountedImageInfo output when Get-WindowsImage fails" {
        Mock Get-WindowsImage { throw 'simulated query failure' }
        Mock dism.exe {
            $global:LASTEXITCODE = 0
            'Mount Dir : C:\ws\m2'
            'Image File : C:\ws\b.wim'
            'Image Index : 2'
            'Status : Needs Remount'
            ''
        }
        $r = @(Get-WinEaseMountedImages | Where-Object { $_.Path -eq 'C:\ws\m2' })
        $r.Count | Should Be 1
        $r[0].MountStatus | Should Be 'Needs Remount'
        $r[0].ImagePath | Should Be 'C:\ws\b.wim'
    }
}

Describe "Assert-WinEaseDirectorySafety" {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:BaseWorkDir = Join-Path $script:T 'base'
        $script:MountAllocationRoot = Join-Path $script:BaseWorkDir 'mounts'
        [System.IO.Directory]::CreateDirectory($script:MountAllocationRoot) | Out-Null
        Mock Get-WinEaseMountedImages { @() }
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "refuses empty, drive-root and UNC-root targets for both operations" {
        foreach ($op in 'Reset', 'RemoveOfflineContent') {
            { Assert-WinEaseDirectorySafety -Path ' ' -Operation $op } | Should Throw 'cannot be empty'
            foreach ($p in @('C:\', 'c:/', 'C:\.', '\\server\share', '\\server\share\')) {
                { Assert-WinEaseDirectorySafety -Path $p -Operation $op } | Should Throw 'root or drive'
            }
        }
    }
    It "refuses host system directories (case and trailing-separator variants, '..' normalization)" {
        $win = [System.Environment]::GetFolderPath('Windows')
        { Assert-WinEaseDirectorySafety -Path $win -Operation 'Reset' } | Should Throw 'protected host'
        { Assert-WinEaseDirectorySafety -Path ($win.ToUpperInvariant() + '\') -Operation 'Reset' } | Should Throw 'protected host'
        { Assert-WinEaseDirectorySafety -Path (Join-Path $win 'Temp\..\System32') -Operation 'Reset' } | Should Throw 'protected host'
        { Assert-WinEaseDirectorySafety -Path ([System.Environment]::GetFolderPath('ProgramFiles')) -Operation 'Reset' } | Should Throw 'protected host'
    }
    It "refuses the base workspace itself and the host Users root even with a workspace configured" {
        { Assert-WinEaseDirectorySafety -Path $script:BaseWorkDir -Operation 'Reset' } | Should Throw 'base workspace'
        { Assert-WinEaseDirectorySafety -Path ($script:BaseWorkDir + '\') -Operation 'Reset' } | Should Throw 'base workspace'
        { Assert-WinEaseDirectorySafety -Path (Join-Path $env:SystemDrive 'Users') -Operation 'Reset' } | Should Throw 'protected host'
    }
    It "refuses a Preserved directory for Reset" {
        $d = Join-Path $script:MountAllocationRoot 'mount_pres'
        [void]$script:PreservedMountDirs.Add($d)
        { Assert-WinEaseDirectorySafety -Path $d -Operation 'Reset' } | Should Throw 'Preserved'
    }
    It "allows Reset of an unmounted directory inside the workspace" {
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:MountAllocationRoot 'mount_ok') -Operation 'Reset' } | Should Not Throw
    }
    It "refuses Reset of a directory DISM reports as mounted, a child of it, and a parent of it" {
        $global:FsMockPath = Join-Path $script:MountAllocationRoot 'mount_live'
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = 'C:\x.wim'; ImageIndex = 1; MountStatus = 'Ok' }) }
        { Assert-WinEaseDirectorySafety -Path $global:FsMockPath -Operation 'Reset' } | Should Throw 'active DISM mount'
        { Assert-WinEaseDirectorySafety -Path ($global:FsMockPath.ToUpperInvariant() + '\') -Operation 'Reset' } | Should Throw 'active DISM mount'
        { Assert-WinEaseDirectorySafety -Path (Join-Path $global:FsMockPath 'Windows') -Operation 'Reset' } | Should Throw 'active DISM mount'
        { Assert-WinEaseDirectorySafety -Path $script:MountAllocationRoot -Operation 'Reset' } | Should Throw 'active DISM mount'
    }
    It "refuses Reset for an Invalid mount (any status counts as mounted)" {
        $global:FsMockPath = Join-Path $script:MountAllocationRoot 'mount_bad'
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = ''; ImageIndex = 1; MountStatus = 'Invalid' }) }
        { Assert-WinEaseDirectorySafety -Path $global:FsMockPath -Operation 'Reset' } | Should Throw 'active DISM mount'
    }
    It "refuses Reset for a Needs Remount mount" {
        $global:FsMockPath = Join-Path $script:MountAllocationRoot 'mount_remount'
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = ''; ImageIndex = 1; MountStatus = 'Needs Remount' }) }
        { Assert-WinEaseDirectorySafety -Path $global:FsMockPath -Operation 'Reset' } | Should Throw 'active DISM mount'
    }
    It "refuses Reset when the mount state cannot be queried (fail closed)" {
        Mock Get-WinEaseMountedImages { throw 'DISM unavailable' }
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:MountAllocationRoot 'mount_x') -Operation 'Reset' } | Should Throw 'Cannot verify mounted image status'
    }
    It "refuses Reset when a mount record has an unparsable path (fail closed)" {
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = "bad`0path"; ImagePath = ''; ImageIndex = 1; MountStatus = 'Ok' }) }
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:MountAllocationRoot 'mount_x') -Operation 'Reset' } | Should Throw 'Cannot verify'
    }
    It "RemoveOfflineContent is limited to strict descendants of DismMountDir" {
        $script:DismMountDir = Join-Path $script:MountAllocationRoot 'dismmount'
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:DismMountDir 'Windows\Temp') -Operation 'RemoveOfflineContent' } | Should Not Throw
        { Assert-WinEaseDirectorySafety -Path $script:DismMountDir -Operation 'RemoveOfflineContent' } | Should Throw 'strict descendants'
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:MountAllocationRoot 'other') -Operation 'RemoveOfflineContent' } | Should Throw 'strict descendants'
        $script:DismMountDir = $null
        { Assert-WinEaseDirectorySafety -Path (Join-Path $script:MountAllocationRoot 'other') -Operation 'RemoveOfflineContent' } | Should Throw 'DismMountDir'
    }
    It "refuses the drive-relative target 'C:' regardless of the current directory" -Pending {
        # FINDING F1-5: 'C:' is drive-RELATIVE; GetFullPath resolves it to the current directory of drive C,
        # so the root/drive guard (checked after normalization) never sees a drive root, and the target
        # becomes whatever the cwd is. Desired: refuse. Pending: current behavior depends on the cwd.
        [System.IO.Directory]::CreateDirectory($script:BaseWorkDir) | Out-Null
        Push-Location -LiteralPath $script:BaseWorkDir
        try { { Assert-WinEaseDirectorySafety -Path ([System.IO.Path]::GetPathRoot($script:BaseWorkDir).Substring(0, 2)) -Operation 'Reset' } | Should Throw 'root or drive' } finally { Pop-Location }
    }
    It "refuses Reset when a mount is reported under a different 8.3 short spelling of the same directory" -Pending {
        # FINDING F1-2 (code review only; not reproduced because 8.3 names are disabled on the dev machine):
        # the overlap check compares GetFullPath() strings, which do not expand 8.3 names, so a long-name
        # target and a short-name mount record would not match. Pending: needs a volume with 8.3 names enabled.
    }
}

Describe "Reset-DirectoryWithRobocopy" -Tags 'slow' {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:BaseWorkDir = Join-Path $script:T 'base'
        $script:MountAllocationRoot = Join-Path $script:BaseWorkDir 'mounts'
        $script:Target = Join-Path $script:MountAllocationRoot 'mount_t'
        [System.IO.Directory]::CreateDirectory($script:Target) | Out-Null
        $script:Outside = Join-Path $script:T 'outside'
        [System.IO.Directory]::CreateDirectory((Join-Path $script:Outside 'sub')) | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') -Value 'keep'
        Mock Get-WinEaseMountedImages { @() }
        Mock Start-Sleep { }
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "empties a directory with real robocopy and recreates a missing one" {
        Set-Content -LiteralPath (Join-Path $script:Target 'a.txt') -Value 'a'
        [System.IO.Directory]::CreateDirectory((Join-Path $script:Target 'd\e')) | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Target 'd\e\b.txt') -Value 'b'
        Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1
        @(Get-ChildItem -LiteralPath $script:Target -Force).Count | Should Be 0
        $missing = Join-Path $script:MountAllocationRoot 'mount_new'
        Reset-DirectoryWithRobocopy -Path $missing -Retries 1
        Test-Path -LiteralPath $missing | Should Be $true
    }
    It "removes a junction child without following it into its target" {
        $junc = Join-Path $script:Target 'junc'
        New-FsTestJunction -Link $junc -Target $script:Outside
        Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1
        Test-Path -LiteralPath $junc | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
    It "refuses a junction as the reset root and leaves the target untouched" {
        $junc = Join-Path $script:MountAllocationRoot 'mount_junc'
        New-FsTestJunction -Link $junc -Target $script:Outside
        { Reset-DirectoryWithRobocopy -Path $junc -Retries 1 } | Should Throw 'reparse point'
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
    It "removes a directory symlink child without following it (skipped without symlink privilege)" -Skip:(-not $script:CanSymlink) {
        $link = Join-Path $script:Target 'slink'
        New-Item -ItemType SymbolicLink -Path $link -Target $script:Outside | Out-Null
        $script:FsTestLinks.Add($link)
        Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1
        Test-Path -LiteralPath $link | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
    It "never touches a directory that DISM reports as mounted (real robocopy would empty the marker file if it were reached)" {
        Set-Content -LiteralPath (Join-Path $script:Target 'marker.txt') -Value 'mounted content'
        $global:FsMockPath = $script:Target
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = 'C:\x.wim'; ImageIndex = 1; MountStatus = 'Ok' }) }
        { Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 } | Should Throw 'active DISM mount'
        Test-Path -LiteralPath (Join-Path $script:Target 'marker.txt') | Should Be $true
    }
    It "never touches a directory when the mount state cannot be queried" {
        Set-Content -LiteralPath (Join-Path $script:Target 'marker.txt') -Value 'maybe mounted'
        Mock Get-WinEaseMountedImages { throw 'DISM query failed' }
        { Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 } | Should Throw 'Cannot verify mounted image status'
        Test-Path -LiteralPath (Join-Path $script:Target 'marker.txt') | Should Be $true
    }
    It "does not reset the base workspace, a drive root or a Preserved directory" {
        { Reset-DirectoryWithRobocopy -Path $script:BaseWorkDir -Retries 1 } | Should Throw 'base workspace'
        { Reset-DirectoryWithRobocopy -Path 'C:\' -Retries 1 } | Should Throw 'root or drive'
        [void]$script:PreservedMountDirs.Add($script:Target)
        Set-Content -LiteralPath (Join-Path $script:Target 'marker.txt') -Value 'x'
        { Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 } | Should Throw 'Preserved'
        Test-Path -LiteralPath (Join-Path $script:Target 'marker.txt') | Should Be $true
    }

    Context "robocopy exit codes (native call mocked)" {
        # Robocopy exit codes: 0-7 are success (bit flags: copied, extra, mismatch), 8+ are failures.
        # The function only logs the "Robocopy error" warning for >= 8; the final verdict is the
        # emptiness check. The native call is mocked, so the exit code is the only variable.
        foreach ($code in 0, 1, 2, 3, 4, 5, 6, 7) {
            It "treats robocopy exit code $code as success (no error warning)" {
                Set-Content -LiteralPath (Join-Path $script:Target 'a.txt') -Value 'a'
                $global:FsFakeRoboExit = $code
                Mock robocopy.exe { $global:LASTEXITCODE = $global:FsFakeRoboExit }
                $warn = @()
                Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 -WarningVariable warn -WarningAction SilentlyContinue
                @($warn | Where-Object { "$_" -match 'Robocopy error' }).Count | Should Be 0
                @(Get-ChildItem -LiteralPath $script:Target -Force).Count | Should Be 0
            }
        }
        foreach ($code in 8, 9, 16) {
            It "reports robocopy exit code $code as an error and fails when the directory cannot be emptied" {
                $lockedPath = Join-Path $script:Target 'locked.bin'
                Set-Content -LiteralPath $lockedPath -Value 'locked'
                $global:FsFakeRoboExit = $code
                Mock robocopy.exe { $global:LASTEXITCODE = $global:FsFakeRoboExit }
                $fs = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                try {
                    $warn = @()
                    $msg = $null
                    try { Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 -WarningVariable warn -WarningAction SilentlyContinue } catch { $msg = $_.Exception.Message }
                    $msg | Should Not BeNullOrEmpty
                    $msg | Should Match 'failed to empty directory'
                    $msg | Should Match "Robocopy Exit Code: $code"
                    @($warn | Where-Object { "$_" -match "Robocopy error \(Exit code: $code\)" }).Count | Should BeGreaterThan 0
                } finally { $fs.Dispose() }
            }
        }
        It "currently succeeds with exit code 8 when the sweep still empties the directory (robocopy failure alone is not fatal)" {
            # Documents current behavior (finding F1-3, informational): exit >= 8 only warns; the post-sweep
            # emptiness assertion is the real gate. This is safe because emptiness is verified, but a caller
            # reading "robocopy exit >= 8 is failure" would be wrong.
            Set-Content -LiteralPath (Join-Path $script:Target 'a.txt') -Value 'a'
            $global:FsFakeRoboExit = 8
            Mock robocopy.exe { $global:LASTEXITCODE = $global:FsFakeRoboExit }
            { Reset-DirectoryWithRobocopy -Path $script:Target -Retries 1 -WarningAction SilentlyContinue } | Should Not Throw
        }
    }

    It "refuses to reset a directory reached through a junction PARENT (content outside the allowed root must survive)" -Pending {
        # FINDING F1-4: Assert-WinEaseDirectorySafety and Reset-DirectoryWithRobocopy only check that the
        # reset root itself is not a reparse point. <alloc>\junc -> <outside>; resetting <alloc>\junc\sub
        # passes the guard (the leaf is a normal directory) and empties <outside>\sub. Desired: refuse.
        # Pending: documents desired behavior; current code empties the external directory.
        $junc = Join-Path $script:MountAllocationRoot 'junc'
        New-FsTestJunction -Link $junc -Target $script:Outside
        { Reset-DirectoryWithRobocopy -Path (Join-Path $junc 'sub') -Retries 1 } | Should Throw
        Test-Path -LiteralPath (Join-Path $script:Outside 'sub\keep.txt') | Should Be $true
    }
}

Describe "Clear-DismMountConflicts" {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:BaseWorkDir = Join-Path $script:T 'base'
        $script:MountAllocationRoot = Join-Path $script:BaseWorkDir 'mounts'
        $script:scriptDir = $script:T
        $script:Mnt = Join-Path $script:MountAllocationRoot 'mount_c'
        [System.IO.Directory]::CreateDirectory($script:Mnt) | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Mnt 'marker.txt') -Value 'x'
        Mock Start-Sleep { }
        Mock Set-Location { }
        Mock dism.exe { $global:FsDismCalls++; $global:LASTEXITCODE = 0 }
        Mock Unmount-DismOfflineHives { $true }
        Mock Unmount-RegistryHiveWithRetry { $true }
        Mock Invoke-WinEaseMountpointCleanup { $true }
        Mock Invoke-WinEaseLevel3RegistryPurge { $global:FsPurgeCalls++ }
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "does nothing without a target" {
        Mock Get-WinEaseMountedImages { $global:FsQueryCalls++; @() }
        Clear-DismMountConflicts
        $global:FsQueryCalls | Should Be 0
        $global:FsDismCalls | Should Be 0
    }
    It "refuses a mount directory outside the workspace and outside ManagedMountDirs without touching DISM" {
        Mock Get-WinEaseMountedImages { $global:FsQueryCalls++; @() }
        $ext = Join-Path $script:T 'external'
        { Clear-DismMountConflicts -TargetMountDir $ext -Retries 1 } | Should Throw 'not in ManagedMountDirs'
        $global:FsDismCalls | Should Be 0
        $global:FsQueryCalls | Should Be 0
    }
    It "adopts a workspace child into ManagedMountDirs and succeeds when nothing is mounted" {
        Mock Get-WinEaseMountedImages { @() }
        Clear-DismMountConflicts -TargetMountDir $script:Mnt -Retries 1
        $script:ManagedMountDirs.Contains($script:Mnt) | Should Be $true
        $global:FsDismCalls | Should Be 0
    }
    It "fails closed (no unmount, no purge) when the mount state cannot be queried" {
        Mock Get-WinEaseMountedImages { throw 'DISM query failed' }
        { Clear-DismMountConflicts -TargetMountDir $script:Mnt -Retries 1 } | Should Throw 'DISM query failed'
        $global:FsDismCalls | Should Be 0
        $global:FsPurgeCalls | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
    }
    It "refuses to discard a target image that is mounted at an external unmanaged directory" {
        $ext = Join-Path $script:T 'external_mount'
        $wim = Join-Path $script:T 'a.wim'
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $ext; ImagePath = $wim; ImageIndex = 1; MountStatus = 'Ok' }) }
        { Clear-DismMountConflicts -TargetMountDir $script:Mnt -TargetWimFile $wim -Retries 1 } | Should Throw 'external unmanaged directory'
        $global:FsDismCalls | Should Be 0
    }
    It "does not purge registry metadata of a lingering mount whose status is not Invalid" {
        $global:FsMockPath = $script:Mnt
        Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = 'C:\x.wim'; ImageIndex = 1; MountStatus = 'Ok' }) }
        { Clear-DismMountConflicts -TargetMountDir $script:Mnt -Retries 1 } | Should Throw 'Failed to clear DISM mount conflict'
        $global:FsPurgeCalls | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
    }
}

Describe "Initialize-WinEaseMountDirectory" -Tags 'slow' {
    BeforeEach {
        Initialize-FsTestState
        $script:T = New-FsTestRoot
        $script:BaseWorkDir = Join-Path $script:T 'base'
        $script:MountAllocationRoot = Join-Path $script:BaseWorkDir 'mounts'
        $script:scriptDir = $script:T
        $script:Mnt = Join-Path $script:MountAllocationRoot 'mount_i'
        [System.IO.Directory]::CreateDirectory($script:Mnt) | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Mnt 'marker.txt') -Value 'x'
        [void]$script:ManagedMountDirs.Add($script:Mnt)
        Mock Start-Sleep { }
        Mock Set-Location { }
        Mock dism.exe { $global:FsDismCalls++; $global:LASTEXITCODE = 0 }
        Mock Unmount-DismOfflineHives { $true }
        Mock Unmount-RegistryHiveWithRetry { $true }
        Mock Invoke-WinEaseMountpointCleanup { $true }
        Mock Invoke-WinEaseLevel3RegistryPurge { $global:FsPurgeCalls++ }
        Mock Get-WinEaseMountedImages { @() }
    }
    AfterEach { Remove-FsTestRoot -Root $script:T }

    It "requires the directory to be in ManagedMountDirs" {
        $other = Join-Path $script:MountAllocationRoot 'mount_unmanaged'
        { Initialize-WinEaseMountDirectory -MountDir $other -Retries 1 } | Should Throw 'not in ManagedMountDirs'
    }
    It "refuses a junction as the mount directory and leaves its target untouched" {
        $outside = Join-Path $script:T 'outside'
        [System.IO.Directory]::CreateDirectory($outside) | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
        $junc = Join-Path $script:MountAllocationRoot 'mount_junc'
        New-FsTestJunction -Link $junc -Target $outside
        [void]$script:ManagedMountDirs.Add($junc)
        { Initialize-WinEaseMountDirectory -MountDir $junc -Retries 1 } | Should Throw 'reparse point'
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
        Test-Path -LiteralPath $junc | Should Be $true
    }
    Context "guards (Reset-DirectoryWithRobocopy mocked)" {
        It "refuses a Preserved directory without resetting it" {
            [void]$script:PreservedMountDirs.Add($script:Mnt)
            Mock Reset-DirectoryWithRobocopy { $global:FsResetCalls++ }
            { Initialize-WinEaseMountDirectory -MountDir $script:Mnt -Retries 1 } | Should Throw 'Preserved'
            $global:FsResetCalls | Should Be 0
            Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
        }
        It "never resets or deletes a directory that DISM reports as mounted" {
            $global:FsMockPath = $script:Mnt
            Mock Get-WinEaseMountedImages { @([PSCustomObject]@{ Path = $global:FsMockPath; ImagePath = 'C:\x.wim'; ImageIndex = 1; MountStatus = 'Ok' }) }
            Mock Reset-DirectoryWithRobocopy { $global:FsResetCalls++ }
            { Initialize-WinEaseMountDirectory -MountDir $script:Mnt -Retries 1 } | Should Throw 'Failed to clear DISM mount conflict'
            $global:FsResetCalls | Should Be 0
            Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
        }
        It "takes no destructive action when the mount state cannot be queried" {
            Mock Get-WinEaseMountedImages { throw 'DISM query failed' }
            Mock Reset-DirectoryWithRobocopy { $global:FsResetCalls++ }
            { Initialize-WinEaseMountDirectory -MountDir $script:Mnt -Retries 1 } | Should Throw 'DISM query failed'
            $global:FsResetCalls | Should Be 0
            $global:FsDismCalls | Should Be 0
            Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
        }
        It "refuses the VHDX volume mount point" {
            $script:VhdxMountDir = $script:Mnt
            Mock Reset-DirectoryWithRobocopy { $global:FsResetCalls++ }
            { Initialize-WinEaseMountDirectory -MountDir $script:Mnt -Retries 1 } | Should Throw 'VHDX volume mount point'
            $global:FsResetCalls | Should Be 0
            Test-Path -LiteralPath (Join-Path $script:Mnt 'marker.txt') | Should Be $true
        }
    }

    It "recreates an unmounted managed directory as a fresh empty directory" {
        Initialize-WinEaseMountDirectory -MountDir $script:Mnt -Retries 1
        Test-Path -LiteralPath $script:Mnt | Should Be $true
        @(Get-ChildItem -LiteralPath $script:Mnt -Force).Count | Should Be 0
        $global:FsDismCalls | Should Be 0
    }
}
