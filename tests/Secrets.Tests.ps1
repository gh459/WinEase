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

Describe "Secrets - Redact-WinEaseUserSecret" {
    BeforeAll {
        $userOncePath = Join-Path $script:RepoRoot "scripts\UserOnce.ps1"
        $content = [System.IO.File]::ReadAllText($userOncePath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcNode = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Redact-WinEaseUserSecret'
        }, $true)
        . ([scriptblock]::Create($funcNode.Extent.Text))
    }

    It "returns null or empty string untouched when input is null or empty" {
        (Redact-WinEaseUserSecret -Text $null) | Should BeNullOrEmpty
        (Redact-WinEaseUserSecret -Text '') | Should Be ''
    }

    It "redacts double-quoted JSON secret values containing spaces or special characters" {
        $input = '{"password": "my secret password 123!", "user": "admin"}'
        $expected = '{"password": [REDACTED], "user": "admin"}'
        (Redact-WinEaseUserSecret -Text $input) | Should Be $expected
    }

    It "redacts single-quoted assignment secret values" {
        $input = "`$apikey = '12345-abcde-secret'"
        $expected = "`$apikey = [REDACTED]"
        (Redact-WinEaseUserSecret -Text $input) | Should Be $expected
    }

    It "redacts unquoted key-value secret pairs" {
        (Redact-WinEaseUserSecret -Text "password: mySuperSecretPassword") | Should Be "password: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "apikey=9876543210") | Should Be "apikey: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "secret = topsecretvalue") | Should Be "secret: [REDACTED]"
        (Redact-WinEaseUserSecret -Text "token: bearer-token-xyz") | Should Be "token: [REDACTED]"
    }

    It "redacts secrets case-insensitively" {
        (Redact-WinEaseUserSecret -Text "PASSWORD: mySecretPassword") | Should Be "PASSWORD: [REDACTED]"
        (Redact-WinEaseUserSecret -Text '{"APIKEY": "secret_key_val"}') | Should Be '{"APIKEY": [REDACTED]}'
        (Redact-WinEaseUserSecret -Text "TOKEN: myToken123") | Should Be "TOKEN: [REDACTED]"
    }

    It "masks 5x5 product key license patterns" {
        $input = "Installing product key VK7JG-NPHTM-C97JM-9MPGT-3V66T into registry"
        $expected = "Installing product key XXXXX-XXXXX-XXXXX-XXXXX-XXXXX into registry"
        (Redact-WinEaseUserSecret -Text $input) | Should Be $expected
    }

    It "handles multiple secret patterns in a single log message without double-redacting" {
        $input = 'Log: password: "my secret" and key VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        $expected = 'Log: password: [REDACTED] and key XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'
        (Redact-WinEaseUserSecret -Text $input) | Should Be $expected
    }

    It "leaves non-secret strings completely untouched" {
        $input = "Process completed successfully in 2.34s with exit code 0"
        (Redact-WinEaseUserSecret -Text $input) | Should Be $input
    }

    It "maintains implementation parity between scripts/UserOnce.ps1 and autounattend.xml" {
        $userOnceContent = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "scripts\UserOnce.ps1"), [System.Text.Encoding]::UTF8)
        $unattendContent = [System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8)

        $ast1 = [System.Management.Automation.Language.Parser]::ParseInput($userOnceContent, [ref]$null, [ref]$null)
        $ast2 = [System.Management.Automation.Language.Parser]::ParseInput($unattendContent, [ref]$null, [ref]$null)

        $fn1 = $ast1.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Redact-WinEaseUserSecret' }, $true)
        $fn2 = $ast2.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Redact-WinEaseUserSecret' }, $true)

        $fn1 | Should Not BeNullOrEmpty
        $fn2 | Should Not BeNullOrEmpty
        $fn1.Body.Extent.Text.Trim() | Should Be $fn2.Body.Extent.Text.Trim()
    }
}
