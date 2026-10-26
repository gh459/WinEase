# User password handling (lib\WinEaseSecrets.ps1, scripts\setup\WinEase-oobe-autologon-repair.ps1,
# phases\10-registry.ps1, phases\11-unattend.ps1). Pester 3.4 / Windows PowerShell 5.1.
# The password is unrestricted text: it must reach the helper script, the registry and the unattend
# XML as data, never as PowerShell source or as part of a native command line.
. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
. (Join-Path -Path $script:RepoRoot -ChildPath 'lib\WinEaseSecrets.ps1')

$script:SecretCases = @(
    "it's"
    "a'; Remove-Item C:\ -Recurse #"
    'say "hi"'
    '$env:COMPUTERNAME $(calc) ${x}'
    'back`tick`n'
    'a&b<c>d;e'
    'with space  and  tabs'
    'x$1y$&z$0'
    # Japanese (U+65E5 U+672C U+8A9E) + an emoji surrogate pair; built from code points so the file stays ASCII
    ((([char[]](0x65E5, 0x672C, 0x8A9E)) -join '') + [char]::ConvertFromUtf32(0x1F600))
    "'"
    '"'
    "a''b"
    'end\'
    'Aa1!@#%^*()_+-=[]{}|,./?~'
)

function Get-WinEaseTestTemplate {
    [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'scripts\setup\WinEase-oobe-autologon-repair.ps1'), [System.Text.Encoding]::UTF8)
}

function Get-WinEaseCommandNames {
    param([string]$Source)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    return @($cmds | ForEach-Object { $_.GetCommandName() })
}

Describe "Secrets - OOBE auto-logon helper" {
    $template = Get-WinEaseTestTemplate
    $templateCommands = Get-WinEaseCommandNames -Source $template

    It "the template carries the Base64 placeholder and no raw password placeholder" {
        $template | Should Match '__WINEASE_USERPASSWORD_B64__'
        $template | Should Not Match "__WINEASE_USERPASSWORD__"
    }

    foreach ($pw in $script:SecretCases) {
        $label = ($pw -replace '[^\x20-\x7E]', '?')
        It "generates a script that parses cleanly with no extra commands for password [$label]" {
            $script = Expand-WinEaseOobeRepairScript -Template $template -UserName 'User' -Password $pw
            $tokens = $null; $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
            $errors.Count | Should Be 0
            $generated = Get-WinEaseCommandNames -Source $script
            ($generated -join '|') | Should Be ($templateCommands -join '|')
        }

        It "embeds a value that decodes to the exact password [$label]" {
            $script = Expand-WinEaseOobeRepairScript -Template $template -UserName 'User' -Password $pw
            # the secret is never written as such into the source (only its Base64 form)
            if ($pw.Length -ge 3) { $script.Contains($pw) | Should Be $false }
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
            # run the decode statements of the script itself (everything up to the 'if ($pwB64)' statement)
            $ifAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
            $decodeSource = $script.Substring(0, $ifAst.Extent.EndOffset) + "`n`$pw"
            $decoded = & ([scriptblock]::Create($decodeSource))
            [string]$decoded | Should BeExactly $pw
            (ConvertFrom-WinEaseSecretBase64 -Value (ConvertTo-WinEaseSecretBase64 -Value $pw)) | Should BeExactly $pw
        }

        It "does not print the password while generating the helper [$label]" {
            $out = (Expand-WinEaseOobeRepairScript -Template $template -UserName 'User' -Password $pw 6>&1 5>&1 4>&1 3>&1 2>&1 | Where-Object { $_ -isnot [string] -or $_.Length -lt 4096 } | Out-String)
            # the function returns the script; the script text itself only holds the Base64 form
            if ($pw.Length -ge 3) { $out.Contains($pw) | Should Be $false }
        }
    }

    It "handles an empty password" {
        $script = Expand-WinEaseOobeRepairScript -Template $template -UserName 'User' -Password ''
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        $script | Should Match "\`$pwB64 = ''"
    }

    It "doubles single quotes in the user name so it cannot break out of its literal" {
        $script = Expand-WinEaseOobeRepairScript -Template $template -UserName "o'brien" -Password 'x'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$user' }, $true)
        $assign.Right.Expression.Value | Should BeExactly "o'brien"
    }

    It "fails the build instead of emitting a helper that does not parse" {
        $broken = $template + "`n if ("
        { Expand-WinEaseOobeRepairScript -Template $broken -UserName 'User' -Password 'SecretPw-123' } | Should Throw
        $msg = try { Expand-WinEaseOobeRepairScript -Template $broken -UserName 'User' -Password 'SecretPw-123' } catch { $_.Exception.Message }
        $msg | Should Not Match 'SecretPw-123'
    }

    It "phase 11 uses the helper function and no raw String.Replace of the password" {
        $phase = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'), [System.Text.Encoding]::UTF8)
        $phase | Should Match 'Expand-WinEaseOobeRepairScript'
        $phase | Should Not Match "Replace\('__WINEASE_USERPASSWORD__'"
        $phase | Should Not Match 'net\\\.exe user User ""'
    }
}

Describe "Secrets - unattend XML" {
    foreach ($pw in $script:SecretCases) {
        $label = ($pw -replace '[^\x20-\x7E]', '?')
        It "round-trips password [$label] through the DOM without changing the structure" {
            $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
            $before = @($doc.SelectNodes('//*')).Count
            $set = Set-WinEaseUnattendPassword -Document $doc -Password $pw
            $set | Should BeGreaterThan 0
            # serialize and load again, as the build does when it writes the file
            $reloaded = [xml]$doc.OuterXml
            @($reloaded.SelectNodes('//*')).Count | Should Be $before
            $values = @($reloaded.SelectNodes("//*[local-name()='UserAccounts']//*[local-name()='Password']/*[local-name()='Value'] | //*[local-name()='AutoLogon']/*[local-name()='Password']/*[local-name()='Value']"))
            $values.Count | Should Be $set
            foreach ($v in $values) { $v.InnerText | Should BeExactly $pw }
        }
    }

    It "leaves the document untouched for an empty password" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $xmlBefore = $doc.OuterXml
        (Set-WinEaseUnattendPassword -Document $doc -Password '') | Should Be 0
        $doc.OuterXml | Should BeExactly $xmlBefore
    }

    It "the template has no blank-password net.exe user command the removed regex could have matched" {
        $raw = [System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8)
        $raw | Should Not Match 'net\.exe user User ""'
        $raw | Should Not Match 'passwordreq'
    }
}

Describe "Secrets - registry (Winlogon DefaultPassword)" {
    BeforeAll { $script:SecretKeyName = "WinEaseSecretsTest-$([guid]::NewGuid().ToString('N'))" }
    AfterAll { Remove-Item -LiteralPath "HKCU:\Software\$($script:SecretKeyName)" -Recurse -Force -ErrorAction SilentlyContinue }

    foreach ($pw in $script:SecretCases) {
        $label = ($pw -replace '[^\x20-\x7E]', '?')
        It "stores password [$label] byte-exact without a command line and without output" {
            $out = Set-WinEaseRegistrySecretString -Key "HKCU\Software\$($script:SecretKeyName)" -Name 'DefaultPassword' -Value $pw 6>&1 5>&1 3>&1 2>&1
            # only the $true result is emitted
            @($out).Count | Should Be 1
            @($out)[0] | Should Be $true
            $read = (Get-ItemProperty -LiteralPath "HKCU:\Software\$($script:SecretKeyName)" -Name 'DefaultPassword').DefaultPassword
            $read | Should BeExactly $pw
        }
    }

    It "stores an empty value and keeps the value kind REG_SZ" {
        [void](Set-WinEaseRegistrySecretString -Key "HKCU\Software\$($script:SecretKeyName)" -Name 'DefaultPassword' -Value '')
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\$($script:SecretKeyName)")
        try {
            $k.GetValue('DefaultPassword') | Should BeExactly ''
            $k.GetValueKind('DefaultPassword') | Should Be ([Microsoft.Win32.RegistryValueKind]::String)
        } finally { $k.Dispose() }
    }

    It "does not leak the password in warnings or errors when the write fails" {
        $secret = 'Zz-LeakCheck-9!'
        $out = Set-WinEaseRegistrySecretString -Key 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\' -Name 'DefaultPassword' -Value $secret 6>&1 5>&1 3>&1 2>&1 | Out-String
        $out.Contains($secret) | Should Be $false
        $msg = try { Set-WinEaseRegistrySecretString -Key 'HKXX\a' -Name 'n' -Value $secret } catch { $_.Exception.Message }
        $msg | Should Not Match 'LeakCheck'
    }

    It "phase 10 writes DefaultPassword through the secret function, not reg.exe" {
        $phase = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'), [System.Text.Encoding]::UTF8)
        $phase | Should Match "Set-WinEaseRegistrySecretString[^\r\n]*DefaultPassword"
        $phase | Should Not Match "Invoke-WinEaseReg[^\r\n]*DefaultPassword"
    }

    It "the builder loads the secrets module" {
        [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8) | Should Match "'WinEaseSecrets\.ps1'"
    }
}

Describe "Secrets - UserOnce Redact-WinEaseUserSecret and logging" {
    BeforeAll {
        $userOncePath = Join-Path $script:RepoRoot 'scripts\UserOnce.ps1'
        $userOnceText = [System.IO.File]::ReadAllText($userOncePath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($userOnceText, [ref]$tokens, [ref]$errors)
        $fnAsts = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -in @('Redact-WinEaseUserSecret', 'Write-UserScriptLog')
        }, $true)
        foreach ($fn in $fnAsts) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }

    It "returns null or empty string unchanged for null/empty input" {
        (Redact-WinEaseUserSecret -Text $null) | Should BeNullOrEmpty
        (Redact-WinEaseUserSecret -Text '') | Should Be ''
    }

    It "returns plain unredacted text unchanged when no secret keywords or product keys are present" {
        $msg = "User script starting execution for User1"
        (Redact-WinEaseUserSecret -Text $msg) | Should Be $msg
    }

    It "redacts password, secret, token, apikey, and key patterns with colon or equals signs case-insensitively" {
        (Redact-WinEaseUserSecret -Text "password: MyPassword123") | Should Be "password: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "PASSWORD=SecretPass456") | Should Be "PASSWORD: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "Secret : SuperSecretVal") | Should Be "Secret: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "token=abcdef12345") | Should Be "token: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "apiKey : xyz-987-abc") | Should Be "apiKey: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "key=my-private-key-data") | Should Be "key: [REDACTED]"
    }

    It "redacts 5x5 Windows product key patterns" {
        (Redact-WinEaseUserSecret -Text "License VK7JG-NPHTM-C97JM-9MPGT-3V66T activated") | Should Be "License XXXXX-XXXXX-XXXXX-XXXXX-XXXXX activated"
    }

    It "redacts multiple secrets and product keys in a single line" {
        $inputStr = "password: pass123 and token=tok456 with Key VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        $expected = "password: [REDACTED] and token: [REDACTED] with Key XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
        (Redact-WinEaseUserSecret -Text $inputStr) | Should Be $expected
    }

    It "Write-UserScriptLog writes formatted timestamp and redacted message to specified log file" {
        $tmpLog = Join-Path ([System.IO.Path]::GetTempPath()) ("UserOnce_test_" + [guid]::NewGuid().ToString('N') + ".log")
        try {
            $userLogFile = $tmpLog
            Write-UserScriptLog -Message "Executed script with password: MySecretPass"

            (Test-Path -LiteralPath $tmpLog) | Should Be $true
            $content = Get-Content -LiteralPath $tmpLog -Raw
            $content | Should Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] Executed script with password: \[REDACTED\]'
        } finally {
            if (Test-Path -LiteralPath $tmpLog) {
                Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Write-UserScriptLog handles file write errors gracefully without throwing an exception" {
        $invalidLogFile = Join-Path ([System.IO.Path]::GetTempPath()) ("nonexistent_dir_" + [guid]::NewGuid().ToString('N') + "\invalid\path\UserOnce.log")
        $userLogFile = $invalidLogFile
        {
            Write-UserScriptLog -Message "Log entry attempt" 3>&1 | Out-String
        } | Should Not Throw
    }
}
