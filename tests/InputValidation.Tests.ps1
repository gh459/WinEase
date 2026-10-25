# C2 - input validation (lib\WinEaseInputValidation.ps1): Test-WinEaseBuildInputs and the places that call it.
# Pester 3.4 / Windows PowerShell 5.1
. (Join-Path -Path $PSScriptRoot -ChildPath "_TestCommon.ps1")

Describe "C2 - Test-WinEaseBuildInputs (lib\WinEaseInputValidation.ps1)" {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseBuildPlan.ps1")
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseInputValidation.ps1")

    $script:C2Iso = Join-Path $TestDrive 'win11.iso'
    Set-Content -LiteralPath $script:C2Iso -Value 'x'
    $script:C2Work = Join-Path $TestDrive 'work'
    $script:C2Out = Join-Path $TestDrive 'out'
    New-Item -ItemType Directory -Path $script:C2Work, $script:C2Out | Out-Null
    $script:C2Good = @{ SourceDrive = $script:C2Iso; WorkDir = $script:C2Work; OutputDir = $script:C2Out; Index = '1'; UserName = 'Tester'; ComputerName = '*'; RequireSource = $true }

    function Get-C2 { param([hashtable]$Override = @{}, [string[]]$Remove = @())
        $p = @{} + $script:C2Good
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        foreach ($k in $Remove) { $p.Remove($k) }
        return @(Test-WinEaseBuildInputs @p)
    }
    function Get-C2Keys { param($Issues, [string]$Severity = 'Error') (@($Issues | Where-Object { $_.Severity -eq $Severity } | ForEach-Object { "$($_.Field):$($_.MessageKey)" }) -join ',') }

    It "valid inputs give no issue and every issue has Field, Severity, MessageKey and Args" {
        (Get-C2).Count | Should Be 0
        $i = @(Get-C2 @{ Index = '' })[0]
        $i.Field | Should Be 'Index'
        $i.Severity | Should Be 'Warning'
        $i.MessageKey | Should Be 'Val.Index.Unspecified'
        $i.PSObject.Properties.Name -contains 'Args' | Should Be $true
    }

    It "the UserName / ComputerName patterns are defined once in the lib and equal the builder's [ValidatePattern] literals" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        foreach ($pn in 'UserName', 'ComputerName') {
            $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $pn }
            $attr = @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidatePattern' })[0]
            $attr.PositionalArguments[0].Value | Should Be (Get-WinEaseInputPattern -Name $pn)
        }
        # no window repeats the regex text any more: they ask the shared function
        $lib = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseInputValidation.ps1'))
        $lib | Should Match 'function Get-WinEaseInputPattern'
        foreach ($f in 'gui\WinEaseGui.ps1', 'gui\winui\WinEaseGui\MainWindow.xaml.cs') {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $f))
            $text.Contains('\p{L}\p{N}') | Should Be $false
        }
    }

    It "the names: ordinary values pass, characters that break autounattend.xml fail, an empty computer name means '*'" {
        foreach ($ok in 'User', 'Tester 1', 'a.b-c_d') { (Get-C2 @{ UserName = $ok }).Count | Should Be 0 }
        foreach ($bad in '', ' x', 'a<b', 'a"b', "a'b", 'a;b', ('x' * 21)) { Get-C2Keys (Get-C2 @{ UserName = $bad }) | Should Be 'UserName:Msg.InvalidUserName.Text' }
        foreach ($ok in '*', 'PC', 'WIN-PC-01', '') { (Get-C2 @{ ComputerName = $ok }).Count | Should Be 0 }
        foreach ($bad in '-pc', 'a b', 'a_b', 'x;calc', ('A' * 16)) { Get-C2Keys (Get-C2 @{ ComputerName = $bad }) | Should Be 'ComputerName:Msg.InvalidComputerName.Text' }
    }

    It "source: an empty one is an Error only when required, a missing ISO and a drive without install.wim|esd are Errors, an existing ISO passes" {
        Get-C2Keys (Get-C2 @{ SourceDrive = '  ' }) | Should Be 'SourceDrive:Msg.SourceRequired.Text'
        (Get-C2 @{ SourceDrive = '' } -Remove 'RequireSource').Count | Should Be 0
        Get-C2Keys (Get-C2 @{ SourceDrive = (Join-Path $TestDrive 'nope.iso') }) | Should Be 'SourceDrive:Val.Source.IsoMissing'
        Get-C2Keys (Get-C2 @{ SourceDrive = '\\server\share\x' }) | Should Be 'SourceDrive:Val.Source.Invalid'
        Get-C2Keys (Get-C2 @{ SourceDrive = 'not a path' }) | Should Be 'SourceDrive:Val.Source.Invalid'
        # a directory named *.iso is not an ISO file
        $dirIso = Join-Path $TestDrive 'dir.iso'
        New-Item -ItemType Directory -Path $dirIso | Out-Null
        Get-C2Keys (Get-C2 @{ SourceDrive = $dirIso }) | Should Be 'SourceDrive:Val.Source.IsoMissing'
        $free = @([char[]]'ZYXWVUTSRQPONMLKJIHGFED' | Where-Object { -not (Test-Path -LiteralPath "${_}:\") })[0]
        if ($free) { Get-C2Keys (Get-C2 @{ SourceDrive = "${free}:\" }) | Should Be 'SourceDrive:Val.Source.NoImage' }
    }

    It "work / output folders: existing, creatable (nothing is created), a file in the way, an unusable parent and invalid text" {
        $new = Join-Path $TestDrive 'deep\er\work'
        (Get-C2 @{ WorkDir = $new }).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $TestDrive 'deep')) | Should Be $false
        $file = Join-Path $TestDrive 'afile'
        Set-Content -LiteralPath $file -Value 'x'
        Get-C2Keys (Get-C2 @{ WorkDir = $file }) | Should Be 'WorkDir:Val.Dir.NotDirectory'
        Get-C2Keys (Get-C2 @{ WorkDir = (Join-Path $file 'sub') }) | Should Be 'WorkDir:Val.Dir.NotCreatable'
        Get-C2Keys (Get-C2 @{ OutputDir = (Join-Path $file 'sub') }) | Should Be 'OutputDir:Val.Dir.NotCreatable'
        Get-C2Keys (Get-C2 @{ WorkDir = 'C:\bad|path' }) | Should Be 'WorkDir:Val.Path.Invalid'
        $free = @([char[]]'ZYXWVUTSRQPONMLKJIHGFED' | Where-Object { -not (Test-Path -LiteralPath "${_}:\") })[0]
        if ($free) { Get-C2Keys (Get-C2 @{ OutputDir = "${free}:\out" }) | Should Be 'OutputDir:Val.Dir.NotCreatable' }
        # no probe file is left behind
        @(Get-ChildItem -LiteralPath $script:C2Work -Force -Filter '.wineasetest-*').Count | Should Be 0
    }

    # Denies file creation with an ACL; when the account can still write (e.g. it owns the folder with full control rights it
    # can re-grant, or the ACL call fails) the case cannot be built here and the two tests below are skipped with that reason.
    $script:C2Locked = Join-Path $TestDrive 'locked'
    New-Item -ItemType Directory -Path $script:C2Locked | Out-Null
    $script:C2CanDeny = $false
    try {
        $who = "$env:USERDOMAIN\$env:USERNAME"
        & icacls.exe $script:C2Locked /deny "${who}:(WD,AD)" 2>&1 | Out-Null
        $script:C2CanDeny = (-not (Test-WinEaseInputDirWritable -Dir $script:C2Locked))
    } catch { $script:C2CanDeny = $false }

    It "work folder that is not writable is an Error (ACL deny; skipped when the ACL cannot be applied here)" -Skip:(-not $script:C2CanDeny) {
        Get-C2Keys (Get-C2 @{ WorkDir = $script:C2Locked }) | Should Be 'WorkDir:Val.Dir.NotWritable'
        # a folder below it is not creatable either
        Get-C2Keys (Get-C2 @{ OutputDir = (Join-Path $script:C2Locked 'sub') }) | Should Be 'OutputDir:Val.Dir.NotCreatable'
        # without the probe only the shape is checked
        (Get-C2 @{ WorkDir = $script:C2Locked; SkipWriteProbe = $true }).Count | Should Be 0
    }

    It "restores the ACL of the locked folder (cleanup)" {
        $who = "$env:USERDOMAIN\$env:USERNAME"
        & icacls.exe $script:C2Locked /remove:d $who 2>&1 | Out-Null
        (Test-WinEaseInputDirWritable -Dir $script:C2Locked) | Should Be $true
    }

    It "collisions: same folder, output inside work, source ISO inside work, output ISO over the source ISO, source drive root as work; work inside output is only a Warning" {
        Get-C2Keys (Get-C2 @{ OutputDir = $script:C2Work }) | Should Be 'OutputDir:Val.Collision.WorkOutputSame'
        Get-C2Keys (Get-C2 @{ OutputDir = ($script:C2Work + '\') }) | Should Be 'OutputDir:Val.Collision.WorkOutputSame'
        Get-C2Keys (Get-C2 @{ OutputDir = (Join-Path $script:C2Work 'iso') }) | Should Be 'OutputDir:Val.Collision.OutputInWork'
        $isoInWork = Join-Path $script:C2Work 'in.iso'
        Set-Content -LiteralPath $isoInWork -Value 'x'
        Get-C2Keys (Get-C2 @{ SourceDrive = $isoInWork }) | Should Be 'SourceDrive:Val.Collision.SourceInWork'
        $r = @(Get-C2 @{ WorkDir = (Join-Path $script:C2Out 'w') })
        $r.Count | Should Be 1
        Get-C2Keys $r 'Warning' | Should Be 'WorkDir:Val.Collision.WorkInOutput'
    }

    It "output ISO name: the same file as the source ISO is refused, a name with a path or illegal characters is refused" {
        Get-C2Keys (Get-C2 @{ OutputDir = $TestDrive; OutputIsoName = 'win11.iso' }) | Should Be 'OutputDir:Val.Collision.OutputIsSource'
        Get-C2Keys (Get-C2 @{ OutputIsoName = 'a\b' }) | Should Be 'OutputDir:Val.OutputName.Invalid'
        (Get-C2 @{ OutputIsoName = 'fine' }).Count | Should Be 0
    }

    It "source drive root used as workspace or output is refused" {
        $r = @(Test-WinEaseBuildInputs -SourceDrive 'C:\' -WorkDir 'C:\' -OutputDir $script:C2Out -SkipWriteProbe)
        (@($r | Where-Object { $_.MessageKey -eq 'Val.Collision.SourceIsFolder' -and $_.Field -eq 'WorkDir' }).Count) | Should Be 1
    }

    It "drivers: empty is fine, a missing folder and a file are Errors" {
        (Get-C2 @{ InjectDrivers = '' }).Count | Should Be 0
        (Get-C2 @{ InjectDrivers = $script:C2Out }).Count | Should Be 0
        Get-C2Keys (Get-C2 @{ InjectDrivers = (Join-Path $TestDrive 'nodrivers') }) | Should Be 'InjectDrivers:Val.Drivers.Missing'
        Get-C2Keys (Get-C2 @{ InjectDrivers = $script:C2Iso }) | Should Be 'InjectDrivers:Val.Drivers.NotDirectory'
    }

    It "edition index: empty is an explicit Warning that needs confirmation (never a guessed value), non-numeric / zero are Errors, an unknown index is an Error when the list is known" {
        $e = @(Get-C2 @{ Index = '' })
        $e.Count | Should Be 1
        $e[0].Severity | Should Be 'Warning'
        $e[0].Confirm | Should Be $true
        (@(Get-C2 @{ Index = '  ' }))[0].MessageKey | Should Be 'Val.Index.Unspecified'
        foreach ($bad in 'abc', '0', '-1', '1.5', '12345', 'x1') { Get-C2Keys (Get-C2 @{ Index = $bad }) | Should Be 'Index:Val.Index.NotNumeric' }
        (Get-C2 @{ Index = '6' }).Count | Should Be 0
        (Get-C2 @{ Index = '6'; AvailableIndices = @('1', '6') }).Count | Should Be 0
        Get-C2Keys (Get-C2 @{ Index = '3'; AvailableIndices = @('1', '6') }) | Should Be 'Index:Val.Index.NotAvailable'
        # a parameter that is not passed is not checked
        (Get-C2 -Remove 'Index').Count | Should Be 0
    }

    It "free space: insufficient is a Warning, plenty and unknown are silent (unknown is the build plan's business)" {
        $tiny = { param($p) $null = $p; [int64](1GB) }
        $plenty = { param($p) $null = $p; [int64](900GB) }
        $unknown = { param($p) $null = $p; $null }
        Get-C2Keys (Get-C2 @{ CheckDiskSpace = $true; FreeSpaceProvider = $tiny }) 'Warning' | Should Be 'WorkDir:Val.Disk.Insufficient'
        (Get-C2 @{ CheckDiskSpace = $true; FreeSpaceProvider = $plenty }).Count | Should Be 0
        (Get-C2 @{ CheckDiskSpace = $true; FreeSpaceProvider = $unknown }).Count | Should Be 0
        # it is never an Error
        Test-WinEaseInputHasError -Issues (Get-C2 @{ CheckDiskSpace = $true; FreeSpaceProvider = $tiny }) | Should Be $false
    }

    It "-Only re-checks just the listed fields (and the collision rules they take part in)" {
        $r = @(Test-WinEaseBuildInputs -UserName 'a"b' -Index 'abc' -Only @('Index') -SkipWriteProbe)
        (@($r | ForEach-Object { $_.Field }) -join ',') | Should Be 'Index'
        $r = @(Test-WinEaseBuildInputs -WorkDir $script:C2Work -OutputDir $script:C2Work -Only @('UserName') -SkipWriteProbe)
        $r.Count | Should Be 0
        $r = @(Test-WinEaseBuildInputs -WorkDir $script:C2Work -OutputDir $script:C2Work -Only @('WorkDir') -SkipWriteProbe)
        (@($r | ForEach-Object { $_.MessageKey }) -join ',') | Should Be 'Val.Collision.WorkOutputSame'
    }

    It "never changes what exists: the folders and the ISO are untouched after a full check with the write probe" {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object) -join '|'
        [void](Get-C2)
        [void](Get-C2 @{ WorkDir = (Join-Path $TestDrive 'a\b') })
        $after = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | Where-Object { $_.FullName -notlike '*\a' -and $_.FullName -notlike '*\a\*' } | ForEach-Object { $_.FullName } | Sort-Object) -join '|'
        $after | Should Be $before
    }

    It "Test-WinEaseGuiResultInputs: partial results only check what they carry, -Strict checks everything and requires a source" {
        (@(Test-WinEaseGuiResultInputs -Result @{ DryRun = $true })).Count | Should Be 0
        (@(Test-WinEaseGuiResultInputs -Result @{ UserName = 'a"b'; ComputerName = 'x;calc' } | ForEach-Object { $_.Field }) -join ',') | Should Be 'UserName,ComputerName'
        (@(Test-WinEaseGuiResultInputs -Result ([pscustomobject]@{ UserName = 'a"b' }) | ForEach-Object { $_.Field }) -join ',') | Should Be 'UserName'
        $strict = @(Test-WinEaseGuiResultInputs -Result @{ } -Strict -SkipWriteProbe)
        (Get-C2Keys $strict) | Should Be 'SourceDrive:Msg.SourceRequired.Text,UserName:Msg.InvalidUserName.Text'
    }

    It "Get-WinEaseInputIssueText / Format-WinEaseInputIssues give readable text for every message key the lib can emit" {
        $en = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\ui-strings\en.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $ja = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config\ui-strings\ja.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $lib = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'lib\WinEaseInputValidation.ps1'))
        $keys = @([regex]::Matches($lib, "'((?:Val|Msg)\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $keys.Count | Should BeGreaterThan 15
        foreach ($k in ($keys + 'Val.Title', 'Val.Index.Confirm', 'Val.Refused')) {
            if (-not $en.PSObject.Properties[$k]) { throw "en.json lacks $k" }
            if (-not $ja.PSObject.Properties[$k]) { throw "ja.json lacks $k" }
            $pe = @([regex]::Matches([string]$en.$k, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $pj = @([regex]::Matches([string]$ja.$k, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            "${k}:$pe" | Should Be "${k}:$pj"
        }
        $t = Get-WinEaseInputIssueText -Issue ([pscustomobject]@{ MessageKey = 'Val.Collision.WorkOutputSame'; Args = @('C:\w') })
        $t | Should Match 'C:\\w'
        $t | Should Not Match '\{0\}'
    }

    It "wiring: the builder loads the lib and runs the check before any destructive step; both windows and the host call it" {
        $b = [System.IO.File]::ReadAllText($script:BuilderPath)
        $b | Should Match "'WinEaseInputValidation\.ps1'"
        $b | Should Match 'Test-WinEaseBuildInputs -SourceDrive \$SourceDrive'
        $b.IndexOf('Test-WinEaseBuildInputs -SourceDrive') | Should BeLessThan $b.IndexOf('$script:BuildId = New-WinEaseBuildId')
        $b.IndexOf('Test-WinEaseBuildInputs -SourceDrive') | Should BeLessThan $b.IndexOf('if (($env:WINEASE_TEST_MODE -eq "1") -or $isDryRunMode)')
        $gui = [System.IO.File]::ReadAllText($script:GuiPath)
        $gui | Should Match 'Test-WinEaseBuildInputs @p'
        $gui | Should Match 'Update-WinEaseGuiFieldIssues -Gui \$Gui -Full'
        $gui | Should Match 'OpenFileDialog'
        $gui | Should Match 'FolderBrowserDialog'
        $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
        $cs | Should Match 'RequestAsync\("validate"'
        $cs | Should Match 'new FolderPicker'
        $cs | Should Match 'new FileOpenPicker'
        $h = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\WinEaseWinUiHost.ps1'))
        $h | Should Match "'validate'"
        $h | Should Match 'Test-WinEaseGuiResultInputs -Result \$out'
        [System.IO.File]::ReadAllText($script:GuiSessionPath) | Should Match 'Test-WinEaseGuiResultInputs -Result \$GuiResult'
        [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\scripts\verify-release-zip.py')) | Should Match 'lib/WinEaseInputValidation\.ps1'
    }
}

Describe "C2 - the command line runs the same check (WinEasebuilder.ps1 -DryRun)" {
    $script:C2CliDir = Join-Path $TestDrive 'cli'
    New-Item -ItemType Directory -Path $script:C2CliDir | Out-Null
    $script:C2CliIso = Join-Path $script:C2CliDir 'win11.iso'
    Set-Content -LiteralPath $script:C2CliIso -Value 'x'

    function Invoke-C2Builder {
        param([string[]]$Arguments)
        # The builder reports a refused input on stderr. Under -ErrorAction Stop (the CI step sets it) Windows PowerShell 5.1 turns
        # each stderr line of a native command with 2>&1 into a terminating error, so the refusal text never reaches the test.
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BuilderPath -DryRun -NonInteractive @Arguments 2>&1 | Out-String
        return @{ Exit = $LASTEXITCODE; Text = $out }
    }

    It "refuses a workspace that is the output folder, before anything is created" {
        $r = Invoke-C2Builder @('-SourceDrive', $script:C2CliIso, '-WorkDir', $script:RepoRoot)
        $r.Exit | Should Not Be 0
        $r.Text | Should Match 'Input validation failed'
        $r.Text | Should Match 'same folder'
    }

    It "refuses a source ISO inside the workspace and a missing drivers folder" {
        $r = Invoke-C2Builder @('-SourceDrive', $script:C2CliIso, '-WorkDir', $script:C2CliDir, '-InjectDrivers', (Join-Path $TestDrive 'nodrv'))
        $r.Exit | Should Not Be 0
        $r.Text | Should Match 'Input validation failed'
        $r.Text | Should Match 'inside the workspace'
        $r.Text | Should Match 'drivers folder does not exist'
    }

    It "an unknown edition index is refused (non-numeric), an empty one is reported as a warning and the dry run goes on" {
        $r = Invoke-C2Builder @('-SourceDrive', $script:C2CliIso, '-WorkDir', (Join-Path $TestDrive 'wk'), '-Index', 'abc')
        $r.Exit | Should Not Be 0
        $r.Text | Should Match 'edition index must be a positive number'
        $ok = Invoke-C2Builder @('-SourceDrive', $script:C2CliIso, '-WorkDir', (Join-Path $TestDrive 'wk'))
        $ok.Exit | Should Be 0
        $ok.Text | Should Match 'No edition \(image index\) is chosen'
        (Test-Path -LiteralPath (Join-Path $TestDrive 'wk')) | Should Be $false
    }
}
