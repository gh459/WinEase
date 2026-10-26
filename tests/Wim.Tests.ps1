# Wim.Tests.ps1 - tests for native WIM helpers and initialization (lib/WinEaseWim.ps1)
# Run with:  Invoke-Pester -Path .\tests\Wim.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1 / PowerShell 7

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
. (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseWim.ps1')

$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -or (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -or ($env:OS -like '*Windows*')

Describe "WinEase native WIM initialization (Initialize-WinEaseWimNative)" {
    It "function Initialize-WinEaseWimNative is defined" {
        Get-Command -Name Initialize-WinEaseWimNative -ErrorAction SilentlyContinue | Should Not BeNullOrEmpty
    }

    It "compiles and defines the WinEaseWimNative type in the current session" {
        Initialize-WinEaseWimNative
        $type = 'WinEaseWimNative' -as [type]
        $type | Should Not BeNullOrEmpty
        $type.Name | Should Be 'WinEaseWimNative'
    }

    It "defines all required P/Invoke static methods on WinEaseWimNative" {
        Initialize-WinEaseWimNative
        $type = 'WinEaseWimNative' -as [type]
        $type | Should Not BeNullOrEmpty

        $expectedMethods = @(
            'WIMCreateFile',
            'WIMSetTemporaryPath',
            'WIMGetImageCount',
            'WIMLoadImage',
            'WIMExtractImagePath',
            'WIMCloseHandle'
        )

        foreach ($methodName in $expectedMethods) {
            $method = $type.GetMethod($methodName)
            $method | Should Not BeNullOrEmpty
            $method.IsStatic | Should Be $true
            $method.IsPublic | Should Be $true
        }
    }

    It "is idempotent and can be invoked repeatedly without throwing" {
        { Initialize-WinEaseWimNative } | Should Not Throw
        { Initialize-WinEaseWimNative } | Should Not Throw
        { Initialize-WinEaseWimNative } | Should Not Throw

        $type = 'WinEaseWimNative' -as [type]
        $type | Should Not BeNullOrEmpty
    }
}

Describe "WinEase WIM helper functions" {
    It "Get-WinEaseWimImageCount returns 0 for a non-existent WIM file" -Skip:(-not $isWindowsPlatform) {
        $nonExistentWim = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_nonexistent_" + [guid]::NewGuid().ToString('N') + ".wim")
        $count = Get-WinEaseWimImageCount -WimPath $nonExistentWim
        $count | Should Be 0
    }

    It "Export-WinEaseWimFile creates target directories and returns false when handle creation fails" -Skip:(-not $isWindowsPlatform) {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_wimexport_" + [guid]::NewGuid().ToString('N'))
        $tempDir = Join-Path -Path $tempRoot -ChildPath "temp"
        $destFile = Join-Path -Path $tempRoot -ChildPath "dest\System32\kernel32.dll"
        $nonExistentWim = Join-Path -Path $tempRoot -ChildPath "missing.wim"

        try {
            $res = Export-WinEaseWimFile -WimPath $nonExistentWim -Index 1 -ImagePath "Windows\System32\kernel32.dll" -Destination $destFile -TempPath $tempDir
            $res | Should Be $false
            (Test-Path -LiteralPath $tempDir) | Should Be $true
            (Test-Path -LiteralPath (Split-Path -Path $destFile -Parent)) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Get-WinEaseDeepApplyFailedFiles returns empty array when log file does not exist" {
        $nonExistentLog = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_nolog_" + [guid]::NewGuid().ToString('N') + ".log")
        $failed = Get-WinEaseDeepApplyFailedFiles -LogPath $nonExistentLog -ApplyDir "C:\Mount"
        @($failed).Count | Should Be 0
    }

    It "Get-WinEaseDeepApplyFailedFiles parses failed file paths from DISM log" {
        $tempLog = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_dism_" + [guid]::NewGuid().ToString('N') + ".log")
        $applyDir = [System.IO.Path]::GetFullPath((Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("mount_" + [guid]::NewGuid().ToString('N'))))

        $file1 = Join-Path -Path $applyDir -ChildPath "Windows\System32\drivers\corrupt.sys"
        $file2 = Join-Path -Path $applyDir -ChildPath "Windows\System32\ntoskrnl.exe"
        $file3 = Join-Path -Path $applyDir -ChildPath "Windows\System32\normal.dll"

        $otherDir = [System.IO.Path]::GetFullPath((Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("other_" + [guid]::NewGuid().ToString('N'))))
        $ignoredFile = Join-Path -Path $otherDir -ChildPath "Windows\System32\ignored.dll"

        $logLines = @(
            "2026-10-26 12:00:00, Info                  DISM  DISM WIM Provider: PID=1234 $file1 (HRESULT=0x80070241)",
            "2026-10-26 12:00:01, Info                  DISM  DISM WIM Provider: PID=1234 $file2 (HRESULT=0x80070570)",
            "2026-10-26 12:00:02, Info                  DISM  DISM WIM Provider: PID=1234 $file1 (HRESULT=0x80070241)",
            "2026-10-26 12:00:03, Info                  DISM  DISM WIM Provider: PID=1234 $ignoredFile (HRESULT=0x80070241)",
            "2026-10-26 12:00:04, Info                  DISM  DISM WIM Provider: PID=1234 $file3 (HRESULT=0x00000000)"
        )

        [System.IO.File]::WriteAllLines($tempLog, $logLines)

        try {
            $failed = Get-WinEaseDeepApplyFailedFiles -LogPath $tempLog -ApplyDir $applyDir
            @($failed).Count | Should Be 2
            $failed[0] | Should Be (Join-Path -Path "Windows\System32\drivers" -ChildPath "corrupt.sys")
            $failed[1] | Should Be (Join-Path -Path "Windows\System32" -ChildPath "ntoskrnl.exe")
        } finally {
            if (Test-Path -LiteralPath $tempLog) {
                Remove-Item -LiteralPath $tempLog -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
