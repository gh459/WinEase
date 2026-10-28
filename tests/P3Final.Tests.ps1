# P3Final.Tests.ps1 - migration backup generations, checked debloat path removal, staged drivers, phase 16 reporting (audit PR-F, part 3)
# Run with:  Invoke-Pester -Path .\tests\P3Final.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "Migration backup generations" {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'tools\migrator\WinEaseMigration.ps1')
    }
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEase_bak_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($script:Dir) | Out-Null
        $script:Src = Join-Path $script:Dir 'src.txt'
        $script:Dest = Join-Path $script:Dir 'dest.txt'
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It "picks the plain name first, then numbered names" {
        (Get-WinEaseMigrationBackupPath -Path $script:Dest) | Should Be "$($script:Dest).WinEase.bak"
        [System.IO.File]::WriteAllText("$($script:Dest).WinEase.bak", 'x')
        (Get-WinEaseMigrationBackupPath -Path $script:Dest) | Should Be "$($script:Dest).WinEase.1.bak"
    }
    It "a second restore does not overwrite the backup of the original" {
        [System.IO.File]::WriteAllText($script:Dest, 'original')
        [System.IO.File]::WriteAllText($script:Src, 'first')
        Copy-WinEaseMigrationRestoreFile -SourcePath $script:Src -DestPath $script:Dest -ConflictPolicy BackupExisting | Out-Null
        [System.IO.File]::WriteAllText($script:Src, 'second')
        Copy-WinEaseMigrationRestoreFile -SourcePath $script:Src -DestPath $script:Dest -ConflictPolicy BackupExisting | Out-Null
        [System.IO.File]::ReadAllText("$($script:Dest).WinEase.bak") | Should Be 'original'
        [System.IO.File]::ReadAllText("$($script:Dest).WinEase.1.bak") | Should Be 'first'
        [System.IO.File]::ReadAllText($script:Dest) | Should Be 'second'
    }
}

Describe "Failure reporting wiring" {
    It "Remove-WinEaseDebloatPath checks that the path is gone" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'lib\WinEaseDebloat.ps1') -Raw
        $t | Should Match 'Could not fully delete \$Label'
    }
    It "the driver staging, VHDX diskpart and phase 16 report failures" {
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\11-unattend.ps1') -Raw) | Should Match 'Copying the custom drivers failed'
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\01-environment.ps1') -Raw) | Should Match 'while setting up the VHDX scratch volume'
        $p16 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\16-iso-cleanup.ps1') -Raw
        $p16 | Should Match 'Final cleanup could not remove from the ISO root'
        $p16 | Should Match 'UltraSlim trim did not remove'
    }
}
