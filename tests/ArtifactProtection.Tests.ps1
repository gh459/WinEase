# ArtifactProtection.Tests.ps1 - install.wim swap rollback, ISO size thresholds, disk image dismount checks and
# explicit -SourceDrive resolution (audit PR-B)
# Run with:  Invoke-Pester -Path .\tests\ArtifactProtection.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# Only per-test temp directories are touched; Mount-/Dismount-/Get-DiskImage and Get-Volume are mocked.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock script blocks run in a different scope than the test')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
if (-not (Get-Command -Name Invoke-WinEasePromoteExportedWim -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

function New-ArtifactTestRoot {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_artifact_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}

Describe "install.wim promotion with rollback (P2-01)" {
    BeforeEach {
        $script:Root = New-ArtifactTestRoot
        $script:Cur = Join-Path $script:Root 'install.wim'
        $script:Exp = Join-Path $script:Root 'export.wim'
        $script:Bak = Join-Path $script:Root 'backup.wim'
        [System.IO.File]::WriteAllText($script:Cur, 'original')
        [System.IO.File]::WriteAllText($script:Exp, 'exported')
        $script:DiagnosticData = @{ PreservedArtifacts = @() }
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It "swaps the exported image in and keeps the original as backup" {
        (Invoke-WinEasePromoteExportedWim -CurrentWim $script:Cur -ExportedWim $script:Exp -BackupWim $script:Bak) | Should Be $true
        [System.IO.File]::ReadAllText($script:Cur) | Should Be 'exported'
        [System.IO.File]::ReadAllText($script:Bak) | Should Be 'original'
    }

    It "restores the original install.wim when the second move fails" {
        $script:Calls = 0
        Mock Move-Item {
            $script:Calls++
            if ($script:Calls -eq 2) { throw 'simulated locked file' }
            [System.IO.File]::Move($LiteralPath, $Destination)
        }
        { Invoke-WinEasePromoteExportedWim -CurrentWim $script:Cur -ExportedWim $script:Exp -BackupWim $script:Bak } | Should Throw 'Failed to move the exported WIM'
        Test-Path -LiteralPath $script:Cur | Should Be $true
        [System.IO.File]::ReadAllText($script:Cur) | Should Be 'original'
    }

    It "records the backup as preserved when the restore also fails" {
        $script:Calls = 0
        Mock Move-Item {
            $script:Calls++
            if ($script:Calls -eq 1) { [System.IO.File]::Move($LiteralPath, $Destination); return }
            throw 'simulated failure'
        }
        { Invoke-WinEasePromoteExportedWim -CurrentWim $script:Cur -ExportedWim $script:Exp -BackupWim $script:Bak } | Should Throw 'restoring the pre-export image failed'
        @($script:DiagnosticData.PreservedArtifacts) -contains $script:Bak | Should Be $true
    }

    It "does not touch the original when the exported WIM is missing" {
        Remove-Item -LiteralPath $script:Exp -Force
        { Invoke-WinEasePromoteExportedWim -CurrentWim $script:Cur -ExportedWim $script:Exp -BackupWim $script:Bak } | Should Throw 'Exported WIM not found'
        [System.IO.File]::ReadAllText($script:Cur) | Should Be 'original'
    }
}

Describe "Size thresholds follow the payload (P2-02)" {
    It "derives the ISO minimum from the payload size" {
        Get-WinEaseMinimumIsoBytes -PayloadBytes 6GB | Should Be (6GB + 100MB)
        Get-WinEaseMinimumIsoBytes -PayloadBytes 300MB | Should Be (300MB + 100MB)
    }
    It "falls back to 1.5GB when the payload size is unknown" {
        Get-WinEaseMinimumIsoBytes | Should Be ([long]1.5GB)
    }
    It "scales the export minimum with the source image" {
        Get-WinEaseMinimumExportBytes -SourceBytes 8GB | Should Be (2GB)
        Get-WinEaseMinimumExportBytes -SourceBytes 400MB | Should Be (200MB)
        Get-WinEaseMinimumExportBytes | Should Be ([long]500MB)
    }
    It "no longer accepts a payload hash that differs from the verified one" {
        $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\18-iso.ps1') -Raw
        $src | Should Match 'does not match the verified final payload'
        $src | Should Not Match '\$script:VerifiedFinalWimSha256 = \$rehashDisk'
    }
}

Describe "Disk image dismount verification (P2-03)" {
    BeforeEach {
        $script:DiagnosticData = @{ PreservedArtifacts = @() }
        Mock Start-Sleep { }
    }
    It "returns true when the image is detached after the dismount" {
        Mock Dismount-DiskImage { }
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $false } }
        (Dismount-WinEaseDiskImageVerified -ImagePath 'C:\x.iso') | Should Be $true
    }
    It "returns false, warns and records the image when it stays attached" {
        Mock Dismount-DiskImage { }
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $true } }
        $w = $null
        $r = Dismount-WinEaseDiskImageVerified -ImagePath 'C:\x.iso' -WarningVariable w -WarningAction SilentlyContinue
        $r | Should Be $false
        (@($w) -join ' ') | Should Match 'still mounted'
        @($script:DiagnosticData['DismountFailures']) -contains 'C:\x.iso' | Should Be $true
    }
    It "retries once and succeeds when the first dismount did not detach" {
        $script:Reads = 0
        Mock Dismount-DiskImage { }
        Mock Get-DiskImage { $script:Reads++; [PSCustomObject]@{ Attached = ($script:Reads -lt 2) } }
        (Dismount-WinEaseDiskImageVerified -ImagePath 'C:\x.iso') | Should Be $true
    }
}

Describe "Explicit -SourceDrive is never replaced (P2-06)" {
    BeforeEach {
        $script:Root = New-ArtifactTestRoot
        $script:Iso = Join-Path $script:Root 'win.iso'
        [System.IO.File]::WriteAllText($script:Iso, 'iso')
        $script:DiagnosticData = @{ PreservedArtifacts = @() }
        Mock Start-Sleep { }
        # Untyped stand-in so the mocked Get-Volume accepts the plain objects the other mocks return.
        $script:Vol = $null
        function Get-Volume { param([Parameter(ValueFromPipeline = $true)]$InputObject, $DiskImage) process { $script:Vol } }
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It "stops when the specified ISO does not exist" {
        { Resolve-WinEaseExplicitSourceMedia -SourceDrive (Join-Path $script:Root 'missing.iso') } | Should Throw 'does not exist'
    }
    It "stops when the specified ISO cannot be mounted" {
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $false } }
        Mock Mount-DiskImage { throw 'mount failed' }
        { Resolve-WinEaseExplicitSourceMedia -SourceDrive $script:Iso } | Should Throw 'Not falling back'
    }
    It "stops when the specified drive does not exist" {
        { Resolve-WinEaseExplicitSourceMedia -SourceDrive 'Q:\no\such\drive.zzz' } | Should Throw 'Not falling back'
    }
    It "reports an ISO that was already mounted as not mounted by WinEase" {
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $true } }
        Mock Mount-DiskImage { [PSCustomObject]@{ ImagePath = $script:Iso } }
        $script:Vol = [PSCustomObject]@{ DriveLetter = 'Z' }
        $m = Resolve-WinEaseExplicitSourceMedia -SourceDrive $script:Iso
        $m.DriveLetter | Should Be 'Z:'
        $m.MountedByWinEase | Should Be $false
    }
    It "reports an ISO it mounted itself" {
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $false } }
        Mock Mount-DiskImage { [PSCustomObject]@{ ImagePath = $script:Iso } }
        $script:Vol = [PSCustomObject]@{ DriveLetter = 'Y' }
        $m = Resolve-WinEaseExplicitSourceMedia -SourceDrive $script:Iso
        $m.MountedByWinEase | Should Be $true
    }
    It "dismounts and stops when the ISO mounts without a drive letter" {
        Mock Get-DiskImage { [PSCustomObject]@{ Attached = $false } }
        Mock Mount-DiskImage { [PSCustomObject]@{ ImagePath = $script:Iso } }
        Mock Dismount-DiskImage { }
        { Resolve-WinEaseExplicitSourceMedia -SourceDrive $script:Iso } | Should Throw 'without a drive letter'
        Assert-MockCalled Dismount-DiskImage
    }
}
