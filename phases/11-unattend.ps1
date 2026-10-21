# Phase 11: 11-unattend
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator

# Helper function to evaluate individual toggle settings.
# The same helper is defined in phase 10; it is repeated here because the phases are
# dot-sourced independently and phase 11 reads the same TweakSettings table.
if (-not (Get-Command -Name Test-TweakEnabled -ErrorAction SilentlyContinue)) {
    function Test-TweakEnabled {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Name,
            [bool]$Default = $true
        )
        if ($null -ne $script:TweakSettings -and $script:TweakSettings.Contains($Name)) {
            return [bool]$script:TweakSettings[$Name]
        }
        if ($null -ne $script:TweakSettings -and $script:TweakKeyAliases) {
            foreach ($alias in $script:TweakKeyAliases.Keys) {
                if ($script:TweakKeyAliases[$alias] -eq $Name -and $script:TweakSettings.Contains($alias)) {
                    return [bool]$script:TweakSettings[$alias]
                }
            }
        }
        $varName = "Tweak_$Name"
        $v = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $v) { return [bool]$v.Value }
        return $Default
    }
}


# 11. Copy autounattend.xml with Architecture Support & Self-healing (Resolves Issues #3, #18, #21, #2, #8, #20)
Write-Host "Configuring autounattend.xml for target architecture ($architecture)..." -ForegroundColor Green
$unattendSource = Join-Path -Path $scriptDir -ChildPath "autounattend.xml"

# Self-healing if autounattend.xml was not downloaded with script
if (-not (Test-Path -LiteralPath $unattendSource)) {
    Write-Host "autounattend.xml not found locally. Attempting to download from repository..." -ForegroundColor Yellow
    $unattendUrl = "https://raw.githubusercontent.com/gh459/WinEase/main/autounattend.xml"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $unattendUrl -OutFile $unattendSource -UseBasicParsing -ErrorAction Stop
        Write-Host "Successfully downloaded autounattend.xml." -ForegroundColor Green
    } catch {
        $fallbackUrl = "https://raw.githubusercontent.com/ntdevlabs/nano11/main/autounattend.xml"
        try {
            Invoke-WebRequest -Uri $fallbackUrl -OutFile $unattendSource -UseBasicParsing -ErrorAction Stop
            Write-Host "Successfully downloaded autounattend.xml from upstream." -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not retrieve autounattend.xml automatically." -ForegroundColor Yellow
        }
    }
}

if (Test-Path -LiteralPath $unattendSource) {
    $xmlContent = Get-Content -LiteralPath $unattendSource -Raw -Encoding utf8
    # Dynamically sanitize invalid ProductKey tags that cause Setup to abort with "cannot read <ProductKey>"
    $xmlContent = $xmlContent -replace '(?s)<ProductKey>\s*<WillShowUI>[^<]*</WillShowUI>\s*</ProductKey>', ''
    # Dynamically normalize all Password and AdministratorPassword Value tags to single-line empty values (prevents blank-password login failure)
    $xmlContent = $xmlContent -replace '(?s)<Value>\s+</Value>', '<Value></Value>'
    # Dynamically purge any harmful ChildCompletion or SystemSetupInProgress forging that breaks Setup state machine
    $xmlContent = $xmlContent -replace '(?s)<RunSynchronousCommand[^>]*>\s*<Order>\d+</Order>\s*<Path>[^<]*ChildCompletion[^<]*</Path>\s*</RunSynchronousCommand>', ''
    $xmlContent = $xmlContent -replace '(?s)\t*\{\s*#[^\r\n]*Zero-Click Setup Completion[^\}]*\}\s*;\r?\n', ''
    # Dynamically parameterize ComputerName and UserName
    $xmlContent = $xmlContent -replace '<ComputerName>WinEase</ComputerName>', "<ComputerName>$ComputerName</ComputerName>"
    $xmlContent = $xmlContent -replace '<Username>User</Username>', "<Username>$UserName</Username>"
    $xmlContent = $xmlContent -replace '<Name>User</Name>', "<Name>$UserName</Name>"
    $xmlContent = $xmlContent -replace '<DisplayName>User</DisplayName>', "<DisplayName>$UserName</DisplayName>"
    $xmlContent =$xmlContent -replace 'net\.exe user User ', "net.exe user `"$UserName`" "
    $xmlContent =$xmlContent -replace 'Set-LocalUser -Name "User"', "Set-LocalUser -Name `"$UserName`""
    $xmlContent = $xmlContent -replace "-Name 'DefaultUserName' -Type 'String' -Force -Value 'User'", "-Name 'DefaultUserName' -Type 'String' -Force -Value '$UserName'"

    # Clean and match target architecture via XML DOM (Resolves P0-07 Duplicate Component Bug)
    try {
        $xmlDoc = [xml]$xmlContent
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace("u", $xmlDoc.DocumentElement.NamespaceURI)

        # The blank-password auto-logon is only armed when the user asked for it
        # (ConfigureWinlogon). Without that option the AutoLogon section is removed
        # from the unattend file: setup then does not log in automatically any more.
        # The password of the local account is left untouched on purpose: an account
        # without a password element is not documented, and a setup that cannot create
        # the account would leave the machine unusable. The empty password of the local
        # account is therefore only a console login; the user sets a password after the
        # first sign-in (docs\SECURITY_OPTIONS.md).
        if (-not (Test-TweakEnabled 'ConfigureWinlogon' $false)) {
            $autoLogonNodes = @($xmlDoc.SelectNodes("//*[local-name()='AutoLogon']"))
            foreach ($alNode in $autoLogonNodes) { [void]$alNode.ParentNode.RemoveChild($alNode) }
            Write-Host "  [AutoLogon] ConfigureWinlogon is off: the auto-logon section was removed from autounattend.xml (no automatic logon)." -ForegroundColor Yellow
        }

        # A2: External script injection - if scripts/ folder exists, override embedded File node contents
        $scriptsDir = Join-Path -Path $scriptDir -ChildPath "scripts"
        if (Test-Path -LiteralPath $scriptsDir) {
            $fileNodes = $xmlDoc.SelectNodes("//*[local-name()='Extensions']/*[local-name()='File']")
            foreach ($fn in $fileNodes) {
                $fnPath = $fn.GetAttribute("path")
                $scriptFileName = [System.IO.Path]::GetFileName($fnPath)
                $scriptFilePath = Join-Path -Path $scriptsDir -ChildPath $scriptFileName
                if (Test-Path -LiteralPath $scriptFilePath) {
                    $externalContent = [System.IO.File]::ReadAllText($scriptFilePath, [System.Text.Encoding]::UTF8)
                    $fn.InnerText = $externalContent.Trim()
                    Write-Host "  [A2] Injected external script: $scriptFileName" -ForegroundColor DarkCyan
                }
            }
        }

        # 1. Prune components matching other architectures if target architecture is explicitly present
        $allComponents = $xmlDoc.SelectNodes("//u:component", $nsMgr)
        $compNodesToRemove = @()
        foreach ($comp in $allComponents) {
            $compArch = $comp.GetAttribute("processorArchitecture")
            if ($compArch -and ($compArch -notin @($architecture, "neutral", "wow64"))) {
                $compNodesToRemove += $comp
            }
        }
        foreach ($c in $compNodesToRemove) {
            [void]$c.ParentNode.RemoveChild($c)
        }

        # 2. If target architecture has no specific components but amd64 exists, map amd64 to target
        $hasTargetComp = $false
        foreach ($comp in $xmlDoc.SelectNodes("//u:component", $nsMgr)) {
            if ($comp.GetAttribute("processorArchitecture") -eq $architecture) {
                $hasTargetComp = $true
                break
            }
        }
        if (-not $hasTargetComp) {
            foreach ($comp in $xmlDoc.SelectNodes("//u:component[@processorArchitecture='amd64']", $nsMgr)) {
                $comp.SetAttribute("processorArchitecture", $architecture)
            }
        }

        # 3. Inject Japanese 106/109 Keyboard & Tokyo TimeZone if enabled
        if ($setJapaneseKeyboard) {
            $shellComp = $xmlDoc.SelectSingleNode("//u:component[@name='Microsoft-Windows-Shell-Setup']", $nsMgr)
            if ($shellComp) {
                $tzNode = $shellComp.SelectSingleNode("u:TimeZone", $nsMgr)
                if (-not $tzNode) {
                    $newTz = $xmlDoc.CreateElement("TimeZone", $xmlDoc.DocumentElement.NamespaceURI)
                    $newTz.InnerText = "Tokyo Standard Time"
                    [void]$shellComp.AppendChild($newTz)
                }
            }
            $specPass = $xmlDoc.SelectSingleNode("//u:settings[@pass='specialize']", $nsMgr)
            if ($specPass) {
                $intlComp = $specPass.SelectSingleNode("u:component[@name='Microsoft-Windows-International-Core']", $nsMgr)
                if (-not $intlComp) {
                    $newComp = $xmlDoc.CreateElement("component", $xmlDoc.DocumentElement.NamespaceURI)
                    $newComp.SetAttribute("name", "Microsoft-Windows-International-Core")
                    $newComp.SetAttribute("processorArchitecture", $architecture)
                    $newComp.SetAttribute("publicKeyToken", "31bf3856ad364e35")
                    $newComp.SetAttribute("language", "neutral")
                    $newComp.SetAttribute("versionScope", "nonSxS")
                    $inpLoc = $xmlDoc.CreateElement("InputLocale", $xmlDoc.DocumentElement.NamespaceURI)
                    $inpLoc.InnerText = "0411:00000411"
                    [void]$newComp.AppendChild($inpLoc)
                    [void]$specPass.AppendChild($newComp)
                }
            }
        }

        # Parameterize ComputerName in specialize pass via DOM (robust against template variations)
        if ($ComputerName) {
            $specPass = $xmlDoc.SelectSingleNode("//u:settings[@pass='specialize']", $nsMgr)
            if ($specPass) {
                foreach ($comp in $specPass.SelectNodes("u:component[@name='Microsoft-Windows-Shell-Setup']", $nsMgr)) {
                    $cnNode = $comp.SelectSingleNode("u:ComputerName", $nsMgr)
                    if ($cnNode) {
                        $cnNode.InnerText = $ComputerName
                    } else {
                        $newCn = $xmlDoc.CreateElement("ComputerName", $xmlDoc.DocumentElement.NamespaceURI)
                        $newCn.InnerText = $ComputerName
                        [void]$comp.AppendChild($newCn)
                    }
                }
            }
        }

        # 4. Safe windowsPE pass normalization:
        # Hardware bypasses (LabConfig) are permanently patched into boot.wim registry (Phase 14).
        # Retain pass="windowsPE" attribute while clearing child elements to keep interactive setup intact.
        $winPePass = $xmlDoc.SelectSingleNode("//u:settings[@pass='windowsPE']", $nsMgr)
        if ($winPePass) {
            while ($winPePass.HasChildNodes) {
                [void]$winPePass.RemoveChild($winPePass.FirstChild)
            }
        }

        # 5. DOM Schema Validation: Verify all RunSynchronousCommand Path lengths <= 259 characters
        $allRunSync = $xmlDoc.SelectNodes("//u:RunSynchronousCommand", $nsMgr)
        foreach ($rsc in $allRunSync) {
            $pathNode = $rsc.SelectSingleNode("u:Path", $nsMgr)
            if ($pathNode) {
                $pathText = $pathNode.InnerText.Trim()
                if ($pathText.Length -gt 259) {
                    $orderNode = $rsc.SelectSingleNode("u:Order", $nsMgr)
                    $order = if ($orderNode) { $orderNode.InnerText } else { "?" }
                    $comp = $rsc.ParentNode.ParentNode.GetAttribute("name")
                    $pass = $rsc.ParentNode.ParentNode.ParentNode.GetAttribute("pass")
                    throw "Validation failed: RunSynchronousCommand Path exceeds 259 characters limit (Pass: '$pass', Component: '$comp', Order: '$order', Length: $($pathText.Length)): $pathText"
                }
            }
        }
    } catch {
        throw "XML DOM architecture normalization and validation failed: $_"
    }

    # Save canonical unattend XML directly via Save-WinEaseUnattendXml (No double BOM, verified UTF-8)
    # The destinations are kept in script scope so that later modifications of the same
    # document (for example the custom FirstLogon script registration further down) can be
    # written back to exactly the same set of files. Without this the nodes that are added
    # after this point were never persisted.
    $isoRootUnattend = Join-Path -Path $WinEaseDir -ChildPath "autounattend.xml"
    $script:UnattendSaveTargets = [System.Collections.Generic.List[string]]::new()
    $script:UnattendSaveTargets.Add($isoRootUnattend)
    Save-WinEaseUnattendXml -XmlDocument $xmlDoc -DestinationPath $isoRootUnattend

    $sysprepDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Sysprep"
    if (Test-Path -LiteralPath $sysprepDir) {
        $sysprepUnattend = Join-Path -Path $sysprepDir -ChildPath "autounattend.xml"
        $script:UnattendSaveTargets.Add($sysprepUnattend)
        Save-WinEaseUnattendXml -XmlDocument $xmlDoc -DestinationPath $sysprepUnattend
    }
    $pantherDir = Join-Path -Path $scratchDir -ChildPath "Windows\Panther"
    if (-not (Test-Path -LiteralPath $pantherDir)) {
        New-Item -Path $pantherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $pantherUnattend = Join-Path -Path $pantherDir -ChildPath "unattend.xml"
    $script:UnattendSaveTargets.Add($pantherUnattend)
    Save-WinEaseUnattendXml -XmlDocument $xmlDoc -DestinationPath $pantherUnattend

    # 6. Pre-extract all 5 embedded setup scripts directly into mounted image ($scratchDir)
    Write-Host "Pre-extracting embedded setup scripts directly into mounted image ($scratchDir)..." -ForegroundColor Cyan
    $fileNodes = $xmlDoc.SelectNodes("//*[local-name()='Extensions']/*[local-name()='File']")
    if (-not $fileNodes -or $fileNodes.Count -eq 0) {
        throw "Pre-extraction failed: No embedded File nodes found in autounattend.xml Extensions block!"
    }

    $scratchFullRoot = [System.IO.Path]::GetFullPath($scratchDir).TrimEnd('\', '/')
    $extractedCount = 0
    $requiredScriptNames = @('Winhancements.ps1', 'Specialize.ps1', 'UserOnce.ps1', 'DefaultUser.ps1', 'FirstLogon.ps1')
    $foundScriptNames = @()
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)

    foreach ($f in $fileNodes) {
        $targetRaw = $f.GetAttribute('path')
        if (-not $targetRaw) { continue }

        $relPath = $targetRaw -replace '^(?:[A-Za-z]:|%SystemDrive%)[\\/]+', ''
        if ($relPath -match '\.\.') {
            throw "Pre-extraction security violation: Path traversal '..' detected in target path: $targetRaw"
        }
        $targetImageFile = [System.IO.Path]::GetFullPath((Join-Path -Path $scratchFullRoot -ChildPath $relPath))
        if (-not (Test-WinEasePathWithin -Path $targetImageFile -Root $scratchFullRoot)) {
            throw "Pre-extraction security violation: Target path '$targetImageFile' escapes mount root '$scratchFullRoot'"
        }

        $targetParent = Split-Path -Path $targetImageFile -Parent
        if ($targetParent -and -not (Test-Path -LiteralPath $targetParent)) {
            New-Item -Path $targetParent -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $scriptContent = $f.InnerText.Trim()
        if ([string]::IsNullOrWhiteSpace($scriptContent)) {
            throw "Pre-extraction failed: Embedded script content for $targetRaw is empty!"
        }

        # Verify PowerShell 5.1 syntax
        $parseErrors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $errDetails = ($parseErrors | ForEach-Object { "$($_.Message) at line $($_.Extent.StartLineNumber)" }) -join "; "
            throw "Pre-extraction syntax error in $($targetRaw): $errDetails"
        }

        [System.IO.File]::WriteAllText($targetImageFile, $scriptContent, $utf8WithBom)

        $fi = Get-Item -LiteralPath $targetImageFile -ErrorAction Stop
        if ($fi.Length -eq 0) {
            throw "Pre-extraction failed: Written file has 0 bytes at $targetImageFile"
        }

        $baseName = [System.IO.Path]::GetFileName($targetImageFile)
        $foundScriptNames += $baseName
        $extractedCount++
        Write-Host "  [Pre-extracted] $targetRaw -> $targetImageFile ($($fi.Length) bytes, PS 5.1 syntax valid)" -ForegroundColor Green
    }

    foreach ($rs in $requiredScriptNames) {
        if ($foundScriptNames -notcontains $rs) {
            throw "Pre-extraction verification failed: Required script '$rs' was not found or not extracted!"
        }
    }
    Write-Host "Successfully pre-extracted all $extractedCount setup scripts into mounted image." -ForegroundColor Green

    # 7. Deploy helper scripts (ExtractUnattend.ps1, ApplyDefaultUser.ps1, RunFirstLogon.ps1)
    $setupScriptsDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts"
    if (-not (Test-Path -LiteralPath $setupScriptsDir)) {
        New-Item -Path $setupScriptsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $helperScripts = [ordered]@{
        "ExtractUnattend.ps1" = @'
# ExtractUnattend.ps1 - Fallback dynamic script extractor from unattend.xml
$markerDir = "C:\ProgramData\WinEase"
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null
}
$logDir = "$markerDir\Logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
}
$logFile = "$logDir\extract.log"

function Log-Extract {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $Message" | Add-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath "$markerDir\extract.succeeded", "$markerDir\extract.failed", "$markerDir\extract.skipped" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath "$markerDir\extract.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
Log-Extract "ExtractUnattend.ps1 started."

try {
    # 1. Pre-check: If all required scripts and wrappers already pre-staged and valid, skip extraction
    $requiredScripts = @(
        'C:\ProgramData\Winhance\Unattend\Scripts\Winhancements.ps1',
        'C:\Windows\Setup\Scripts\Specialize.ps1',
        'C:\Windows\Setup\Scripts\UserOnce.ps1',
        'C:\Windows\Setup\Scripts\DefaultUser.ps1',
        'C:\Windows\Setup\Scripts\FirstLogon.ps1',
        'C:\Windows\Setup\Scripts\ApplyDefaultUser.ps1',
        'C:\Windows\Setup\Scripts\RunFirstLogon.ps1',
        'C:\Windows\Setup\Scripts\SetupComplete.cmd'
    )
    $missingPreStaged = @()
    foreach ($rs in $requiredScripts) {
        if (-not (Test-Path -LiteralPath $rs)) {
            $missingPreStaged += $rs
        } else {
            $item = Get-Item -LiteralPath $rs -ErrorAction SilentlyContinue
            if ($null -eq $item -or $item.Length -eq 0) {
                $missingPreStaged += "$rs (0 bytes)"
            }
        }
    }

    if ($missingPreStaged.Count -eq 0) {
        Log-Extract "All $($requiredScripts.Count) required setup scripts and wrappers pre-staged with non-zero size. Extraction skipped."
        Set-Content -LiteralPath "$markerDir\extract.skipped" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
        exit 0
    }

    Log-Extract "Missing scripts detected: $($missingPreStaged -join ', '). Initiating fallback XML extraction..."
    $candidates = @(
        'C:\Windows\Panther\unattend.xml',
        'C:\Windows\Panther\autounattend.xml',
        'C:\Windows\System32\Sysprep\autounattend.xml',
        'C:\Windows\System32\Sysprep\unattend.xml'
    )
    $found = $false
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            Log-Extract "Found unattend candidate at $p"
            $xml = [xml]::new()
            $xml.Load($p)
            $nsmgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $nsmgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            $nsmgr.AddNamespace('ext', 'https://schneegans.de/windows/unattend-generator/')

            $fileNodes = $xml.SelectNodes('//ext:File | //u:File | //File', $nsmgr)
            if ($fileNodes -and $fileNodes.Count -gt 0) {
                Log-Extract "Found $($fileNodes.Count) embedded file nodes."
                foreach ($file in $fileNodes) {
                    $rawPath = $file.GetAttribute('path')
                    if (-not $rawPath) { continue }
                    $targetPath = [System.Environment]::ExpandEnvironmentVariables($rawPath)
                    if (-not (Test-Path -LiteralPath $targetPath)) {
                        $parent = Split-Path -Path $targetPath -Parent
                        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                            New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        $encoding = switch ([System.IO.Path]::GetExtension($targetPath).ToLower()) {
                            { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8 }
                            { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true) }
                            default { [System.Text.Encoding]::Default }
                        }
                        [System.IO.File]::WriteAllBytes($targetPath, ($encoding.GetPreamble() + $encoding.GetBytes($file.InnerText.Trim())))
                        Log-Extract "Extracted missing file: $targetPath"
                    } else {
                        Log-Extract "Already present: $targetPath"
                    }
                }
                $found = $true
                break
            }
        }
    }

    # Verify again after fallback extraction attempt
    $stillMissing = @()
    foreach ($rs in $requiredScripts) {
        if (-not (Test-Path -LiteralPath $rs)) { $stillMissing += $rs }
    }
    if ($stillMissing.Count -gt 0) {
        throw "Fallback extraction failed: required scripts still missing: $($stillMissing -join ', ')"
    }

    Set-Content -LiteralPath "$markerDir\extract.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
    Log-Extract "ExtractUnattend.ps1 fallback extraction completed successfully."
} catch {
    $err = "$($_ | Out-String)"
    Log-Extract "ERROR during extraction: $err"
    Set-Content -LiteralPath "$markerDir\extract.failed" -Value $err -Encoding UTF8 -ErrorAction SilentlyContinue
    exit 1
}
'@

        "ApplyDefaultUser.ps1" = @'
# ApplyDefaultUser.ps1 - Safely load HKU\DefaultUser, apply DefaultUser.ps1, unload hive
$markerDir = "C:\ProgramData\WinEase"
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null
}
$logDir = "$markerDir\Logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
}
$logFile = "$logDir\defaultuser.log"

function Log-DefUser {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $Message" | Add-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath "$markerDir\defaultuser.succeeded", "$markerDir\defaultuser.failed" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath "$markerDir\defaultuser.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
Log-DefUser "ApplyDefaultUser.ps1 started."
$hiveLoaded = $false
$hasError = $false
$ntUserDat = 'C:\Users\Default\NTUSER.DAT'

try {
    if (-not (Test-Path -LiteralPath $ntUserDat)) {
        throw "NTUSER.DAT not found at $ntUserDat"
    }

    & reg.exe load HKU\DefaultUser $ntUserDat
    $loadExit = $LASTEXITCODE
    if ($loadExit -ne 0) {
        throw "reg.exe load HKU\DefaultUser failed with exit code $loadExit"
    }
    $hiveLoaded = $true
    Log-DefUser "Successfully loaded HKU\DefaultUser"

    $defUserScript = 'C:\Windows\Setup\Scripts\DefaultUser.ps1'
    if (Test-Path -LiteralPath $defUserScript) {
        Log-DefUser "Executing $defUserScript (out-of-process)..."
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File $defUserScript
        $defExit = $LASTEXITCODE
        Log-DefUser "$defUserScript process finished with exit code: $defExit"
        if ($defExit -ne 0) {
            throw "$defUserScript exited with non-zero exit code: $defExit"
        }
        Log-DefUser "Execution of $defUserScript finished successfully."
    } else {
        throw "Required script $defUserScript not found."
    }

    # Post-verification: verify critical DefaultUser registry values applied before hive unload
    $runOnceVal = (Get-ItemProperty -LiteralPath 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UnattendedSetup' -ErrorAction SilentlyContinue).UnattendedSetup
    if ([string]::IsNullOrWhiteSpace($runOnceVal)) {
        throw "Post-verification failed: HKU\DefaultUser RunOnce UnattendedSetup value is missing or empty!"
    }
    Log-DefUser "Post-verification passed: RunOnce UnattendedSetup registered."
} catch {
    $hasError = $true
    $err = "$($_ | Out-String)"
    Log-DefUser "ERROR in ApplyDefaultUser.ps1: $err"
    Remove-Item -LiteralPath "$markerDir\defaultuser.succeeded" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$markerDir\defaultuser.failed" -Value $err -Encoding ascii -ErrorAction SilentlyContinue
} finally {
    if ($hiveLoaded) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1

        $unloaded = $false
        for ($i = 1; $i -le 5; $i++) {
            & reg.exe unload HKU\DefaultUser
            $unloadExit = $LASTEXITCODE
            if ($unloadExit -eq 0) {
                $unloaded = $true
                Log-DefUser "Successfully unloaded HKU\DefaultUser on attempt $i."
                break
            }
            Log-DefUser "Attempt $i to unload HKU\DefaultUser returned exit code $unloadExit, retrying in 1s..."
            Start-Sleep -Seconds 1
        }
        if (-not $unloaded) {
            $hasError = $true
            Log-DefUser "ERROR: Failed to unload HKU\DefaultUser after 5 attempts."
            Set-Content -LiteralPath "$markerDir\defaultuser_unload.failed" -Value "Failed to unload HKU\DefaultUser" -Encoding ascii -ErrorAction SilentlyContinue
        } else {
            # Post-verification: verify HKU\DefaultUser is no longer accessible
            if (Test-Path -LiteralPath 'Registry::HKU\DefaultUser') {
                $hasError = $true
                Log-DefUser "ERROR: Post-verification failed: HKU\DefaultUser hive is still accessible after unload!"
                Set-Content -LiteralPath "$markerDir\defaultuser_unload.failed" -Value "Hive still mounted after unload" -Encoding ascii -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($hasError) {
    Log-DefUser "ApplyDefaultUser.ps1 completed WITH ERRORS."
    exit 1
} else {
    Set-Content -LiteralPath "$markerDir\defaultuser.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
    Log-DefUser "ApplyDefaultUser.ps1 completed successfully."
    exit 0
}
'@

        "RunFirstLogon.ps1" = @'
# RunFirstLogon.ps1 - Unified FirstLogon single entry point
$markerDir = "C:\ProgramData\WinEase"
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null
}
$logDir = "$markerDir\Logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
}
$wrapperLogFile  = "$logDir\firstlogon-wrapper.log"
$winhanceSysLog  = "$logDir\winhancements-system.log"
$flChildLog      = "$logDir\firstlogon-child.log"
$winhanceUserLog = "$logDir\winhancements-user.log"

function Write-FirstLogonLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    try {
        [System.IO.File]::AppendAllText($wrapperLogFile, "$entry`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        Add-Content -LiteralPath $wrapperLogFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Invoke-ChildScriptWithLog {
    param(
        [string]$ScriptPath,
        [string]$Arguments,
        [string]$LogPath,
        [string]$Description
    )
    Write-FirstLogonLog "Starting $Description (Script: $ScriptPath, Log: $LogPath)"

    $targetLogDir = [System.IO.Path]::GetDirectoryName($LogPath)
    if (-not (Test-Path -LiteralPath $targetLogDir)) {
        New-Item -ItemType Directory -Force -Path $targetLogDir -ErrorAction Stop | Out-Null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argPart = if ($Arguments) { " $Arguments" } else { "" }
    $psi.Arguments = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -Command `"[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$ScriptPath'$argPart; exit `$LASTEXITCODE`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()

    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result

    $combined = ""
    if (-not [string]::IsNullOrEmpty($stdoutText)) {
        $combined += $stdoutText
    }
    if (-not [string]::IsNullOrEmpty($stderrText)) {
        if (-not [string]::IsNullOrEmpty($combined) -and -not $combined.EndsWith("`r`n") -and -not $combined.EndsWith("`n")) {
            $combined += "`r`n"
        }
        $combined += "[STDERR]`r`n" + $stderrText
    }

    if (-not [string]::IsNullOrEmpty($combined)) {
        try {
            [System.IO.File]::AppendAllText($LogPath, $combined, [System.Text.Encoding]::UTF8)
        } catch {
            Write-FirstLogonLog "ERROR: Failed to write to child log '$LogPath': $($_.Exception.Message)" "ERROR"
            Add-Content -LiteralPath $LogPath -Value $combined -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }

    $exitCode = $proc.ExitCode
    Write-FirstLogonLog "Finished $Description with exit code $exitCode"
    return $exitCode
}

Remove-Item -LiteralPath "$markerDir\firstlogon.succeeded", "$markerDir\firstlogon.failed", "$markerDir\firstlogon.done", "$markerDir\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath "$markerDir\firstlogon.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction SilentlyContinue

Write-FirstLogonLog "===== RunFirstLogon.ps1 execution started ====="

# User Identity and Execution Context Tracking
$currentUser = $env:USERNAME
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = if ($currentIdentity.User) { $currentIdentity.User.Value } else { "UNKNOWN" }
$currentPrincipal = [System.Security.Principal.WindowsPrincipal]$currentIdentity
$isAdmin = $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$userProfile = $env:USERPROFILE
$sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

$targetUser = $currentUser
try {
    $csUser = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($csUser -and $csUser -notlike "*NT AUTHORITY*") {
        $targetUser = $csUser.Split('\')[-1]
    }
} catch {}

$targetHivePath = "Registry::HKEY_USERS\$currentSid"
$isHiveAccessible = Test-Path -LiteralPath $targetHivePath -ErrorAction SilentlyContinue

Write-FirstLogonLog "===== Execution Context & Identity Tracking ====="
Write-FirstLogonLog "Execution UserName:    $currentUser"
Write-FirstLogonLog "Execution User SID:    $currentSid"
Write-FirstLogonLog "User Profile Path:     $userProfile"
Write-FirstLogonLog "Session ID:            $sessionId"
Write-FirstLogonLog "Is Elevated Admin:     $isAdmin"
Write-FirstLogonLog "Target Applied User:   $targetUser"
Write-FirstLogonLog "Target HKCU Hive Root: $targetHivePath (Accessible: $isHiveAccessible)"
Write-FirstLogonLog "================================================="

try {
    # 1. Verify existence of required setup scripts
    $winhanceScript = 'C:\ProgramData\Winhance\Unattend\Scripts\Winhancements.ps1'
    $firstLogonScript = 'C:\Windows\Setup\Scripts\FirstLogon.ps1'

    if (-not (Test-Path -LiteralPath $winhanceScript)) {
        throw "CRITICAL ERROR: Winhancements.ps1 not found at $winhanceScript"
    }
    if (-not (Test-Path -LiteralPath $firstLogonScript)) {
        throw "CRITICAL ERROR: FirstLogon.ps1 not found at $firstLogonScript"
    }

    # Steps 2-4 always all run: FirstLogon.ps1 contains the AutoLogon teardown and WinRE cleanup,
    # so a Winhancements.ps1 failure must not skip it. Failures are collected and reported afterwards.
    $stepErrors = @()

    # 2. System optimizations: Winhancements.ps1 (System mode)
    $winExit = Invoke-ChildScriptWithLog -ScriptPath $winhanceScript -Arguments "" -LogPath $winhanceSysLog -Description "Winhancements.ps1 (System optimization mode)"
    if ($winExit -ne 0) {
        $stepErrors += "Winhancements.ps1 failed with exit code $winExit"
        Write-FirstLogonLog "Winhancements.ps1 failed with exit code $winExit - continuing with FirstLogon.ps1" "ERROR"
    }

    # 3. Finalization: FirstLogon.ps1
    $flExit = Invoke-ChildScriptWithLog -ScriptPath $firstLogonScript -Arguments "" -LogPath $flChildLog -Description "FirstLogon.ps1 (Service shutdown, tasks, desktop tools)"
    if ($flExit -ne 0) {
        $stepErrors += "FirstLogon.ps1 failed with exit code $flExit"
    }
    if (Test-Path -LiteralPath "$markerDir\firstlogon_script.failed") {
        $stepErrors += "FirstLogon.ps1 reported internal errors in $markerDir\firstlogon_script.failed"
    }

    # 4. User optimizations: Winhancements.ps1 -UserCustomizations
    $userExit = Invoke-ChildScriptWithLog -ScriptPath $winhanceScript -Arguments "-UserCustomizations" -LogPath $winhanceUserLog -Description "Winhancements.ps1 -UserCustomizations"
    if ($userExit -ne 0) {
        $stepErrors += "Winhancements.ps1 -UserCustomizations failed with exit code $userExit"
    }

    if ($stepErrors.Count -gt 0) {
        throw ($stepErrors -join "; ")
    }

    # 5. Post-verification of system and user state
    Write-FirstLogonLog "Verifying post-setup state..."
    if (-not (Test-Path -LiteralPath "$markerDir\firstlogon.done")) {
        throw "Post-verification failed: FirstLogon.ps1 did not create completion marker firstlogon.done"
    }
    if (Test-Path -LiteralPath 'C:\Windows\Setup\Scripts\remove-defender.flag') {
        $chkSvcs = @('MDCoreSvc', 'WinDefend')
        foreach ($cs in $chkSvcs) {
            $svcPath = "Registry::HKLM\SYSTEM\CurrentControlSet\Services\$cs"
            $svcKeyExists = $false
            try {
                $svcKeyExists = Test-Path -LiteralPath $svcPath -ErrorAction Stop
            } catch {
                throw "Post-verification failed: Cannot access Service $cs key ($svcPath): $($_.Exception.Message)"
            }
            if (-not $svcKeyExists) {
                Write-FirstLogonLog "Service $cs key does not exist (absent / removed) - OK"
                continue
            }
            try {
                $prop = Get-ItemProperty -LiteralPath $svcPath -Name "Start" -ErrorAction Stop
            } catch {
                throw "Post-verification failed: Access denied or query failed for Service $cs Start value: $($_.Exception.Message)"
            }
            if ($null -eq $prop -or $null -eq $prop.Start) {
                throw "Post-verification failed: Service $cs exists but Start value is missing or null"
            }
            if ($prop.Start -ne 4) {
                throw "Post-verification failed: Service $cs Start is $($prop.Start) (expected 4 / disabled)"
            }
            Write-FirstLogonLog "Service $cs Start value verified as 4 (disabled) - OK"
        }
    }
    Write-FirstLogonLog "Post-verification passed: all required state verified."

    # 6. Success marker - ONLY created when ALL steps exit 0 AND post-verification passes
    Set-Content -LiteralPath "$markerDir\firstlogon.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction Stop
    Write-FirstLogonLog "===== RunFirstLogon.ps1 completed successfully =====" "SUCCESS"
} catch {
    $err = "$($_ | Out-String)"
    Write-FirstLogonLog "EXCEPTION in RunFirstLogon.ps1: $err" "ERROR"
    Remove-Item -LiteralPath "$markerDir\firstlogon.succeeded", "$markerDir\firstlogon.done" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$markerDir\firstlogon.failed" -Value $err -Encoding UTF8 -ErrorAction SilentlyContinue
    exit 1
}
'@

        "WinEase-oobe-autologon-repair.ps1" = @'
# WinEase-oobe-autologon-repair.ps1
# Re-assert the Winlogon auto-logon target for the OOBE -> first user session transition.
# msoobe rewrites these values to the temporary defaultuser0 account at the end of OOBE,
# which makes the transition logon fail (1326) and stalls setup on the "Just a moment..." screen.
# Runs from SetupComplete.cmd as the LAST writer before the transition logon is attempted.
$ErrorActionPreference = 'SilentlyContinue'
$user = '__WINEASE_USERNAME__'
$key  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

Set-ItemProperty -LiteralPath $key -Name 'AutoAdminLogon'  -Value '1'    -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'DefaultUserName' -Value $user -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'DefaultPassword' -Value ''    -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'ForceAutoLogon'  -Value '1'    -Type String -Force

$sid = $null
try {
    $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch { $sid = $null }

if ($sid) {
    Set-ItemProperty -LiteralPath $key -Name 'AutoLogonSID' -Value $sid -Type String -Force
    Write-Output "[OOBE-AutoLogon] keys re-armed for '$user' (AutoLogonSID=$sid)"
} else {
    Remove-ItemProperty -LiteralPath $key -Name 'AutoLogonSID' -Force
    Write-Output "[OOBE-AutoLogon] keys re-armed for '$user' (AutoLogonSID unresolved; stale value removed)"
}
Remove-ItemProperty -LiteralPath $key -Name 'AutoLogonCount' -Force

$check = Get-ItemProperty -LiteralPath $key
Write-Output ("[OOBE-AutoLogon] verified: AutoAdminLogon=" + $check.AutoAdminLogon + " DefaultUserName=" + $check.DefaultUserName + " ForceAutoLogon=" + $check.ForceAutoLogon)
'@

        "WinEase-transition-watchdog.ps1" = @'
# WinEase-transition-watchdog.ps1
# One-shot safety net for the first-boot OOBE -> user session transition.
# If no interactive user session appears while auto-logon is still armed, trigger exactly
# one recovery reboot so the boot-time auto-logon (proven path) can complete the transition.
$ErrorActionPreference = 'SilentlyContinue'
$markerDir = 'C:\ProgramData\WinEase'
$logDir    = "$markerDir\Logs"
$logFile   = "$logDir\transition-watchdog.log"
$guardFile = "$markerDir\watchdog.rebooted"
$taskName  = 'WinEase-TransitionWatchdog'
$winlogon  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
function Write-WLog { param([string]$m) try { Add-Content -LiteralPath $logFile -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {} }
function Remove-WatchdogTask { & schtasks.exe /delete /tn "$taskName" /f 2>&1 | Out-Null }
function Test-InteractiveSession {
    try {
        $out = & quser.exe 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $rows = @($out | Where-Object { $_ -match '\S' })
            if ($rows.Count -ge 2) { return $true }
        }
    } catch {}
    try {
        $expl = Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 }
        if ($expl) { return $true }
    } catch {}
    return $false
}

if (Test-Path -LiteralPath $guardFile) {
    Write-WLog ("post-reboot run: guard marker present, session-active=" + (Test-InteractiveSession))
    Remove-WatchdogTask
    Write-WLog 'watchdog stood down after recovery reboot'
    exit 0
}

Write-WLog 'watchdog armed (first-run instance)'
$deadline = (Get-Date).AddMinutes(15)
$extended = $false
$sessionSeen = $false
$lastBeat = Get-Date

while ($true) {
    if (Test-InteractiveSession) { $sessionSeen = $true; break }
    if ((Get-Date) -ge $deadline) {
        if (-not $extended) {
            $oobe = Get-Process -Name 'msoobe','CloudExperienceHost','CloudExperienceHostBroker' -ErrorAction SilentlyContinue
            if ($oobe) {
                $deadline = (Get-Date).AddMinutes(5)
                $extended = $true
                Write-WLog 'OOBE processes still running; extending wait by 5 minutes'
                continue
            }
        }
        break
    }
    if (((Get-Date) - $lastBeat).TotalMinutes -ge 5) { Write-WLog 'waiting for an interactive session'; $lastBeat = Get-Date }
    Start-Sleep -Seconds 45
}

if ($sessionSeen) {
    Write-WLog 'interactive user session detected; transition OK'
    Remove-WatchdogTask
    exit 0
}

$auto = [string](Get-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon
if ($auto -ne '1') {
    Write-WLog ("no session yet but AutoAdminLogon='" + $auto + "'; autologon phase already finished - no action")
    Remove-WatchdogTask
    exit 0
}

Write-WLog 'no user session detected while auto-logon is armed; triggering one-shot recovery reboot'
Set-Content -LiteralPath $guardFile -Value ("recovery reboot at " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ascii
& shutdown.exe /r /t 5 /f
exit 0
'@
    }

    # Inject the configured account name into the OOBE transition repair helper
    $helperScripts['WinEase-oobe-autologon-repair.ps1'] = $helperScripts['WinEase-oobe-autologon-repair.ps1'].Replace('__WINEASE_USERNAME__', $UserName)

    # The blank-password auto-logon is only armed when the user asked for it
    # (ConfigureWinlogon). Without that option the OOBE -> first session transition
    # helpers are not deployed at all, so nothing re-arms the Winlogon keys.
    $configureWinlogon = (Test-TweakEnabled 'ConfigureWinlogon' $false)
    if (-not $configureWinlogon) {
        foreach ($autoHelper in @('WinEase-oobe-autologon-repair.ps1', 'WinEase-transition-watchdog.ps1')) {
            if ($helperScripts.Contains($autoHelper)) { $helperScripts.Remove($autoHelper) }
        }
        Write-Host "  [AutoLogon] ConfigureWinlogon is off: the blank-password auto-logon helpers are not deployed." -ForegroundColor Yellow
    }

    foreach ($hName in $helperScripts.Keys) {
        $hContent = $helperScripts[$hName]
        $hDest = Join-Path -Path $setupScriptsDir -ChildPath $hName

        $hErrors = $null
        $hTokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($hContent, [ref]$hTokens, [ref]$hErrors)
        if ($hErrors -and $hErrors.Count -gt 0) {
            $errDetails = ($hErrors | ForEach-Object { "$($_.Message) at line $($_.Extent.StartLineNumber)" }) -join "; "
            throw "Helper script syntax error in $($hName): $errDetails"
        }

        [System.IO.File]::WriteAllText($hDest, $hContent, $utf8WithBom)
        $fi = Get-Item -LiteralPath $hDest -ErrorAction Stop
        if ($fi.Length -eq 0) {
            throw "Failed writing helper script $($hName): File is 0 bytes."
        }
        Write-Host "  [Helper Script Deployed] $hDest ($($fi.Length) bytes, PS 5.1 syntax valid)" -ForegroundColor Green
    }

    # 8. SetupComplete.cmd two-stage verification marker creation & System-level Finalization
    $setupCompleteLines = [System.Collections.Generic.List[string]]::new()
    $setupCompleteLines.AddRange([string[]]@(
        "@echo off",
        "setlocal enabledelayedexpansion",
        "if not exist `"%SystemDrive%\ProgramData\WinEase`" mkdir `"%SystemDrive%\ProgramData\WinEase`"",
        "set `"LOGFILE=%SystemDrive%\ProgramData\WinEase\setupcomplete.log`"",
        "rem Purge any stale markers from prior runs to prevent false-positive contamination",
        "if exist `"%SystemDrive%\ProgramData\WinEase\setupcomplete.succeeded`" del /f /q `"%SystemDrive%\ProgramData\WinEase\setupcomplete.succeeded`" 2>nul",
        "if exist `"%SystemDrive%\ProgramData\WinEase\setupcomplete.failed`" del /f /q `"%SystemDrive%\ProgramData\WinEase\setupcomplete.failed`" 2>nul",
        "echo %DATE% %TIME% SetupComplete Started > `"%SystemDrive%\ProgramData\WinEase\setupcomplete.started`"",
        "echo [%DATE% %TIME%] ===== SetupComplete.cmd execution started ===== >> `"!LOGFILE!`"",
        "set `"SC_FAIL_COUNT=0`""
    ))
    if ($removeDefender) {
        $setupCompleteLines.AddRange([string[]]@(
            "rem --- Stage 1: Configure Defender services to disabled with separated result and state tracking ---",
            "for %%S in (WinDefend MDCoreSvc WdBoot WdFilter Sense SecurityHealthService WdNisSvc) do (",
            "    sc.exe query %%S >nul 2>&1",
            "    if !errorlevel! equ 1060 (",
            "        echo [%DATE% %TIME%] [SKIP] Service %%S is not installed >> `"!LOGFILE!`"",
            "    ) else if !errorlevel! equ 0 (",
            "        sc.exe config %%S start= disabled >> `"!LOGFILE!`" 2>&1",
            "        if !errorlevel! neq 0 (",
            "            echo [%DATE% %TIME%] [WARN] sc config %%S returned non-zero code !errorlevel! >> `"!LOGFILE!`"",
            "        ) else (",
            "            echo [%DATE% %TIME%] [INFO] sc config %%S disabled request accepted >> `"!LOGFILE!`"",
            "        )",
            "        reg.exe query `"HKLM\SYSTEM\CurrentControlSet\Services\%%S`" /v `"Start`" 2>&1 | findstr /i `"0x4`" >nul 2>&1",
            "        if !errorlevel! equ 0 (",
            "            echo [%DATE% %TIME%] [OK] Service %%S start type verified as disabled [0x4] >> `"!LOGFILE!`"",
            "        ) else (",
            "            echo [%DATE% %TIME%] [FAIL] Service %%S start type verification failed [not 0x4] >> `"!LOGFILE!`"",
            "            set /a SC_FAIL_COUNT+=1",
            "        )",
            "    ) else (",
            "        echo [%DATE% %TIME%] [FAIL] Unable to query service %%S - code: !errorlevel! >> `"!LOGFILE!`"",
            "        set /a SC_FAIL_COUNT+=1",
            "    )",
            ")",
            "rem --- Stage 2: Stop active Defender services and verify STOPPED state with bounded wait ---",
            "for %%S in (WinDefend MDCoreSvc) do (",
            "    sc.exe query %%S >nul 2>&1",
            "    if !errorlevel! equ 1060 (",
            "        echo [%DATE% %TIME%] [SKIP] Service %%S not installed, skip stop >> `"!LOGFILE!`"",
            "    ) else if !errorlevel! equ 0 (",
            "        sc.exe stop %%S >> `"!LOGFILE!`" 2>&1",
            "        if !errorlevel! neq 0 (",
            "            echo [%DATE% %TIME%] [WARN] sc stop %%S returned non-zero code !errorlevel! >> `"!LOGFILE!`"",
            "        ) else (",
            "            echo [%DATE% %TIME%] [INFO] sc stop %%S request accepted >> `"!LOGFILE!`"",
            "        )",
            "        set `"SVC_STOPPED=0`"",
            "        for /l %%I in (1,1,5) do (",
            "            if !SVC_STOPPED! equ 0 (",
            "                sc.exe query %%S 2>&1 | findstr /i `"STATE`" | findstr /i `"STOPPED`" >nul 2>&1",
            "                if !errorlevel! equ 0 (",
            "                    set `"SVC_STOPPED=1`"",
            "                ) else (",
            "                    ping.exe 127.0.0.1 -n 2 >nul 2>&1",
            "                )",
            "            )",
            "        )",
            "        if !SVC_STOPPED! equ 1 (",
            "            echo [%DATE% %TIME%] [OK] Service %%S confirmed STOPPED >> `"!LOGFILE!`"",
            "        ) else (",
            "            echo [%DATE% %TIME%] [FAIL] Service %%S failed to reach STOPPED state within timeout >> `"!LOGFILE!`"",
            "            set /a SC_FAIL_COUNT+=1",
            "        )",
            "    ) else (",
            "        echo [%DATE% %TIME%] [FAIL] Unable to query service %%S for stop - code: !errorlevel! >> `"!LOGFILE!`"",
            "        set /a SC_FAIL_COUNT+=1",
            "    )",
            ")",
            "rem --- Stage 3: Delete autostart entries and IFEO traps ---",
            "reg.exe delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v `"SecurityHealth`" /f >> `"!LOGFILE!`" 2>&1",
            "reg.exe delete `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe`" /f >> `"!LOGFILE!`" 2>&1",
            "reg.exe delete `"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe`" /f >> `"!LOGFILE!`" 2>&1",
            "rem --- Stage 4: Post-Verification of Registry States with Direct Key Inspection ---",
            "rem Distinguish nonexistence (exit 0) from existing key/value (exit 1) and exception/denial (exit 2)",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"try { `$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Run'); if (`$null -eq `$k) { exit 0 } `$v = `$k.GetValue('SecurityHealth'); `$k.Close(); if (`$null -ne `$v) { exit 1 } else { exit 0 } } catch { exit 2 }`" >nul 2>&1",
            "if !errorlevel! equ 0 (",
            "    echo [%DATE% %TIME%] [OK] SecurityHealth autostart verified absent >> `"!LOGFILE!`"",
            ") else if !errorlevel! equ 1 (",
            "    echo [%DATE% %TIME%] [FAIL] SecurityHealth autostart still exists! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ") else (",
            "    echo [%DATE% %TIME%] [FAIL] SecurityHealth autostart check exception or access denied - code: !errorlevel! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ")",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"try { `$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe'); if (`$null -ne `$k) { `$k.Close(); exit 1 } else { exit 0 } } catch { exit 2 }`" >nul 2>&1",
            "if !errorlevel! equ 0 (",
            "    echo [%DATE% %TIME%] [OK] Standard smartscreen.exe IFEO verified absent >> `"!LOGFILE!`"",
            ") else if !errorlevel! equ 1 (",
            "    echo [%DATE% %TIME%] [FAIL] Standard smartscreen.exe IFEO still exists! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ") else (",
            "    echo [%DATE% %TIME%] [FAIL] Standard smartscreen.exe IFEO check exception or access denied - code: !errorlevel! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ")",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"try { `$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe'); if (`$null -ne `$k) { `$k.Close(); exit 1 } else { exit 0 } } catch { exit 2 }`" >nul 2>&1",
            "if !errorlevel! equ 0 (",
            "    echo [%DATE% %TIME%] [OK] WOW6432Node smartscreen.exe IFEO verified absent >> `"!LOGFILE!`"",
            ") else if !errorlevel! equ 1 (",
            "    echo [%DATE% %TIME%] [FAIL] WOW6432Node smartscreen.exe IFEO still exists! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ") else (",
            "    echo [%DATE% %TIME%] [FAIL] WOW6432Node smartscreen.exe IFEO check exception or access denied - code: !errorlevel! >> `"!LOGFILE!`"",
            "    set /a SC_FAIL_COUNT+=1",
            ")"
        ))
    }
    # OOBE -> first user session transition hardening:
    #  - Re-assert the Winlogon auto-logon target (msoobe can re-point it at the temporary
    #    defaultuser0 account, which makes the transition logon fail with 1326 and stalls setup).
    #  - Arm a one-shot watchdog that reboots exactly once if no interactive session appears.
    # Both steps re-arm the blank-password auto-logon, so they only run when the user
    # asked for it (ConfigureWinlogon).
    if ($configureWinlogon) {
        $setupCompleteLines.AddRange([string[]]@(
            "rem --- Stage 5: OOBE->user transition auto-logon repair and one-shot watchdog ---",
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%SystemDrive%\Windows\Setup\Scripts\WinEase-oobe-autologon-repair.ps1`" >> `"!LOGFILE!`" 2>&1",
            "if !errorlevel! neq 0 echo [%DATE% %TIME%] [WARN] OOBE auto-logon repair returned error code !errorlevel! >> `"!LOGFILE!`"",
            "schtasks.exe /create /f /tn `"WinEase-TransitionWatchdog`" /sc onstart /delay 0003:00 /ru SYSTEM /tr `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File %SystemDrive%\Windows\Setup\Scripts\WinEase-transition-watchdog.ps1`" >> `"!LOGFILE!`" 2>&1",
            "if !errorlevel! neq 0 echo [%DATE% %TIME%] [WARN] Transition watchdog task creation failed with code !errorlevel! >> `"!LOGFILE!`"",
            "schtasks.exe /run /tn `"WinEase-TransitionWatchdog`" >> `"!LOGFILE!`" 2>&1"
        ))
    } else {
        $setupCompleteLines.AddRange([string[]]@(
            "rem --- Stage 5: skipped (ConfigureWinlogon is off: no auto-logon is armed) ---"
        ))
    }
    $setupCompleteLines.AddRange([string[]]@(
        "if !SC_FAIL_COUNT! equ 0 (",
        "    if exist `"%SystemDrive%\ProgramData\WinEase\setupcomplete.failed`" del /f /q `"%SystemDrive%\ProgramData\WinEase\setupcomplete.failed`" 2>nul",
        "    echo %DATE% %TIME% SetupComplete Succeeded > `"%SystemDrive%\ProgramData\WinEase\setupcomplete.succeeded`"",
        "    echo [%DATE% %TIME%] ===== SetupComplete finished successfully with 0 errors ===== >> `"!LOGFILE!`"",
        "    exit /b 0",
        ") else (",
        "    if exist `"%SystemDrive%\ProgramData\WinEase\setupcomplete.succeeded`" del /f /q `"%SystemDrive%\ProgramData\WinEase\setupcomplete.succeeded`" 2>nul",
        "    echo %DATE% %TIME% SetupComplete Completed with !SC_FAIL_COUNT! errors > `"%SystemDrive%\ProgramData\WinEase\setupcomplete.failed`"",
        "    echo [%DATE% %TIME%] ===== SetupComplete failed with !SC_FAIL_COUNT! errors ===== >> `"!LOGFILE!`"",
        "    exit /b 1",
        ")"
    ))
    $setupCompleteLines -join "`r`n" | Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "SetupComplete.cmd") -Encoding ascii
    Write-Host "  [SetupComplete] Configured two-stage markers with individual logging and explicit exit codes" -ForegroundColor Green

    # Bundle winget-packages.json for post-setup automated app installation if present
    $repoWingetJson = Join-Path -Path $scriptDir -ChildPath "tools\winget-packages.json"
    if (Test-Path -LiteralPath $repoWingetJson) {
        Copy-Item -LiteralPath $repoWingetJson -Destination (Join-Path -Path $setupScriptsDir -ChildPath "winget-packages.json") -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repoWingetJson -Destination (Join-Path -Path $WinEaseDir -ChildPath "sources\winget-packages.json") -Force -ErrorAction SilentlyContinue
        Write-Host "  - Bundled winget-packages.json for post-setup automated app installation" -ForegroundColor Green
    }

    # $OEM$ Custom Hardware Driver Injection (-InjectDrivers)
    if ($InjectDrivers -and (Test-Path -LiteralPath $InjectDrivers)) {
        Write-Host "Injecting custom hardware drivers from $InjectDrivers..." -ForegroundColor Cyan
        $destDriversDir = Join-Path -Path $WinEaseDir -ChildPath "sources\`$OEM`$\`$1\Drivers"
        New-Item -ItemType Directory -Force -Path $destDriversDir | Out-Null
        Copy-Item -Path "$InjectDrivers\*" -Destination $destDriversDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  - Drivers staged in sources\`$OEM`$\`$1\Drivers" -ForegroundColor Green
    }

    # Stage feature flags for FirstLogon.ps1 automation
    if ($removeDefender) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "remove-defender.flag") -Value "1" -Encoding ascii -Force
        Write-Host "  - Staged remove-defender.flag" -ForegroundColor Green
    }
    if ($disableMemCompression -or (Test-TweakEnabled 'DisableMemCompression' $false)) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-memcompression.flag") -Value "1" -Encoding ascii -Force
    }
    # The hypervisor is turned off when the user asked for it (the NoHypervisor tweak, which
    # also disables it for the extreme/handheld/audio profiles through the preset value).
    # The previous condition additionally forced it off for those profiles regardless of the
    # user's selection, which silently overrode the GUI switch.
    # WSL2 and the Virtual Machine Platform cannot run with hypervisorlaunchtype=Off, so an
    # explicit "Enable WSL2" request wins over the NoHypervisor tweak (which is on by default).
    # Otherwise the two settings contradicted each other and WSL2 silently never started.
    if ($noHypervisor -or (Test-TweakEnabled 'NoHypervisor' $false)) {
        if ($wslSupport) {
            Write-Host "  - NoHypervisor skipped: WSL2 support is enabled and needs the hypervisor" -ForegroundColor Yellow
        } else {
            Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "no-hypervisor.flag") -Value "1" -Encoding ascii -Force
        }
    }
    if ($script:activeTweakGroups -and $script:activeTweakGroups.Contains('NetworkStack') -and $script:activeTweakGroups['NetworkStack']) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-netbios.flag") -Value "1" -Encoding ascii -Force
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "network-stack.flag") -Value "1" -Encoding ascii -Force
    }
    if ($script:activeTweakGroups -and $script:activeTweakGroups.Contains('TimerBCD') -and $script:activeTweakGroups['TimerBCD']) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "timer-bcd.flag") -Value "1" -Encoding ascii -Force
    }
    if ($removeWebViewPostOOBE) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "remove-webview.flag") -Value "1" -Encoding ascii -Force
    }
    # Post-install (first logon) flags. Each of these used to run unconditionally on the
    # installed system; they are now only staged when the matching option is enabled.
    $postInstallFlags = [ordered]@{
        'EnableCompactOS'              = 'enable-compactos.flag'
        'EnableNtfs8dot3Disable'       = 'enable-ntfs8dot3.flag'
        'EnableUltimatePerformancePower' = 'enable-ultimate-power.flag'
        'EnableMsiMode'                = 'enable-msimode.flag'
        'DisableAccessibilityTools'    = 'disable-accessibility.flag'
        'DisableWindowsSearchProcess'  = 'disable-search-process.flag'
        'DisableComputerRestore'      = 'disable-computer-restore.flag'
        'HideSearchBox'                = 'enable-hide-searchbox.flag'
        'DisableCrossDevice'           = 'disable-crossdevice.flag'
    }
    foreach ($flagKey in $postInstallFlags.Keys) {
        # An Advanced Debloat target can switch the same work on (the target carries the
        # option of the phase that owns it), so both are asked.
        $flagOn = Test-TweakEnabled $flagKey $false
        if (-not $flagOn -and (Get-Command -Name Test-WinEaseDebloatOptionEnabled -ErrorAction SilentlyContinue)) {
            $flagOn = Test-WinEaseDebloatOptionEnabled -Option $flagKey
        }
        if ($flagOn) {
            Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath $postInstallFlags[$flagKey]) -Value "1" -Encoding ascii -Force
        }
    }
    # Residual per-user AppX removal: the per-user packages of the apps the offline
    # pass removed from the image. The list follows the same options as the offline
    # removal, so nothing is removed when the matching option is off.
    $appxResidualPackages = @()
    if (Test-TweakEnabled 'RemoveWindowsBackup' $true)    { $appxResidualPackages += 'WindowsBackupApp' }
    if (Test-TweakEnabled 'RemoveWebExperienceHost' $true) { $appxResidualPackages += 'Client.WebExperience' }
    if ($removeAppxBloatware)                               { $appxResidualPackages += 'Getstarted' }
    if ($appxResidualPackages.Count -gt 0) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "remove-appx-packages.flag") -Value ($appxResidualPackages -join "`r`n") -Encoding ascii -Force
        Write-Host "  - Staged remove-appx-packages.flag ($($appxResidualPackages -join ', '))" -ForegroundColor Green
    }
    if ($bypassActivationRestrictions) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "bypass-activation.flag") -Value "1" -Encoding ascii -Force
    }
    if (-not $keepSearchIndex) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-search.flag") -Value "1" -Encoding ascii -Force
        Write-Host "  - Staged disable-search.flag (FirstLogon will stop & disable WSearch online)" -ForegroundColor Green
    }
    # The radical-ram, keep-xbox, keep-basic-apps, keep-windows-update and gpu-latency flags
    # were removed: each of those options is already applied offline (phase 05 removes the
    # AppX packages, phase 10 sets the service Start values and the GPU scheduler mode), so
    # the flags were never read and only added noise to the image.
    if ($disableUSBSuspend -or (Test-TweakEnabled 'DisableUSBSuspend' $false)) {
        # USB selective suspend can only be changed on the running system (powercfg), not in the
        # offline image, so the online step is staged here and executed by FirstLogon.ps1.
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-usb-suspend.flag") -Value "1" -Encoding ascii -Force
    }
    # HibernateMode is a Component whose variable is only initialised when a profile or
    # the GUI supplied a value, so it can be $null here. Reading it defensively keeps the
    # "no profile" path working.
    $hibernateModeValue = if ($null -ne $HibernateMode) { "$HibernateMode" } else { 'Keep' }
    # The Advanced Debloat tab can ask for the hibernation file to be removed as well.
    if ((Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue) -and
        (Test-WinEaseDebloatTarget -Item 'Remove hiberfil.sys (powercfg /h off) [4-16GB]')) {
        $hibernateModeValue = 'Off'
    }
    if ($hibernateModeValue -and $hibernateModeValue -ne 'Keep') {
        # The mode name is carried in the flag: Off disables hibernation and removes
        # hiberfil.sys, Reduced turns off fast startup but keeps hibernation.
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "hibernate-mode.flag") -Value $hibernateModeValue -Encoding ascii -Force
    }
    # The Advanced Debloat tab can ask for the page file to be removed as well. The page
    # file cannot be deleted from the offline image (Windows recreates it), so the switch
    # is a post-install one: the page file is disabled and the file is deleted on the
    # installed system.
    # The swap file is created together with the paging file, so switching the paging
    # file off removes both - there is no separate switch for it.
    $removePageFile = $false
    if (Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue) {
        $removePageFile = (Test-WinEaseDebloatTarget -Item 'Remove pagefile.sys (pagefile disable) [4-16GB]') -or
            (Test-WinEaseDebloatTarget -Item 'Remove swapfile.sys (pagefile disable) [256MB-1GB]')
    }
    if ($removePageFile) {
        Write-Host "  - Page file removal requested (Advanced Debloat): staging the post-install switch" -ForegroundColor Cyan
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "remove-pagefile.flag") -Value "1" -Encoding ascii -Force
    }

    # Save build traceability manifest (WinEase-build-info.json)
    $buildInfoObj = [ordered]@{
        BuilderVersion        = $script:WinEaseVersion
        BuildUtc              = [DateTime]::UtcNow.ToString("o")
        Profile               = $selectedProfile
        Architecture          = $architecture
        ComputerName          = $ComputerName
        UserName              = $UserName
        RadicalRAM            = $radicalRAM
        JapaneseKeyboard      = $setJapaneseKeyboard
        KeepBasicApps         = $keepBasicApps
        KeepXboxServices      = [bool]$keepXboxServices
        RemoveAppxBloatware   = [bool]$removeAppxBloatware
        KeepSearchIndex       = [bool]$keepSearchIndex
        KeepAudioTweaks       = [bool]($KeepAudioTweaks -or $DAWMode)
        DAWMode               = [bool]$DAWMode
        DisableWindowsUpdate  = [bool]$disableWU
        HibernateMode         = $hibernateModeValue
        RemoveDefender        = [bool]$removeDefender
        BypassActivation      = $bypassActivationRestrictions
        NetworkStack          = [bool]($script:activeTweakGroups -and $script:activeTweakGroups.Contains('NetworkStack') -and $script:activeTweakGroups['NetworkStack'])
        SourceDrive           = $DriveLetter
        PayloadFormat         = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
    }
    $buildInfoJson = $buildInfoObj | ConvertTo-Json -Depth 4
    $buildInfoJson | Set-Content -LiteralPath (Join-Path -Path $WinEaseDir -ChildPath "WinEase-build-info.json") -Encoding utf8
    $buildInfoJson | Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "WinEase-build-info.json") -Encoding utf8
}

# Bundle Custom Post-Install Scripts if provided in tools\custom-scripts (FirstLogon\ and the older top-level files
# run at first logon; UserOnce\ and the older user\ folder run as the user)
$customScriptsDir = Join-Path -Path $scriptDir -ChildPath "tools\custom-scripts"
if (Test-Path -LiteralPath $customScriptsDir) {
    $targetCustomDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\Custom"
    New-Item -Path $targetCustomDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $customManifest = [ordered]@{}
    foreach ($f in @(Get-WinEaseCustomScriptFiles -RepoRoot $scriptDir -Stage 'FirstLogon' -IncludeLegacy)) {
        Copy-Item -LiteralPath $f.FullName -Destination $targetCustomDir -Force -ErrorAction SilentlyContinue
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $customManifest[$f.Name] = $hash
    }
    $userFiles = @(Get-WinEaseCustomScriptFiles -RepoRoot $scriptDir -Stage 'UserOnce' -IncludeLegacy)
    if ($userFiles.Count -gt 0) {
        $targetUserDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\UserCustom"
        New-Item -Path $targetUserDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($f in $userFiles) {
            Copy-Item -LiteralPath $f.FullName -Destination $targetUserDir -Force -ErrorAction SilentlyContinue
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $customManifest["user/$($f.Name)"] = $hash
        }
    }
    if ($customManifest.Count -gt 0) {
        $manifestPath = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\custom-scripts-manifest.json"
        $manifestJson = $customManifest | ConvertTo-Json -Depth 2
        if (Get-Command -Name "Write-WinEaseTextFileAtomic" -ErrorAction SilentlyContinue) {
            Write-WinEaseTextFileAtomic -Path $manifestPath -Content $manifestJson | Out-Null
        } else {
            [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.Encoding]::UTF8)
        }
    }
    Write-Host "  - Bundled custom post-install scripts ($($customManifest.Count) files) with SHA256 manifest to Windows\Setup\Scripts\Custom" -ForegroundColor Green
}

# Deploy Zero-Footprint Browser Grabber and WinEase Control Center to Public Desktop & Setup Tools
$pubDesktop = Join-Path -Path $scratchDir -ChildPath "Users\Public\Desktop"
$setupTools = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Tools"
New-Item -Path $pubDesktop -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path $setupTools -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$browserPs1Content = @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]'Tls13'
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
$ErrorActionPreference = 'Stop'

Clear-Host
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               WinEase Browser Installer" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Edge was removed for minimal footprint. Select a browser" -ForegroundColor Gray
Write-Host "to download and install directly from its official CDN:" -ForegroundColor Gray
Write-Host ""
Write-Host "  [1] Google Chrome         (Official Silent Installer)" -ForegroundColor Green
Write-Host "  [2] Mozilla Firefox        (Official Silent Installer - Japanese)" -ForegroundColor Yellow
Write-Host "  [3] Brave Browser          (Official Standalone Installer)" -ForegroundColor Magenta
Write-Host "  [4] Floorp Browser         (Japanese High-Privacy Gecko)" -ForegroundColor Cyan
Write-Host "  [5] Microsoft Edge         (Official Standalone Installer)" -ForegroundColor Blue
Write-Host "  [0] Exit" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Cyan

$choice = Read-Host "Select option [1-5, 0]"
if (-not $choice -or $choice.Trim() -eq '0') { exit }

$tempDir = Join-Path -Path $env:TEMP -ChildPath "WinEase_browser_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    switch ($choice.Trim()) {
        '1' {
            Write-Host "`nDownloading Google Chrome..." -ForegroundColor Green
            $installer = Join-Path -Path $tempDir -ChildPath "ChromeSetup.exe"
            Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Google Chrome silently..." -ForegroundColor Green
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Google Chrome installation completed!" -ForegroundColor Green
        }
        '2' {
            Write-Host "`nDownloading Mozilla Firefox..." -ForegroundColor Yellow
            $installer = Join-Path -Path $tempDir -ChildPath "FirefoxSetup.exe"
            Invoke-WebRequest -Uri "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=ja" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Mozilla Firefox silently..." -ForegroundColor Yellow
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Mozilla Firefox installation completed!" -ForegroundColor Green
        }
        '3' {
            Write-Host "`nDownloading Brave Browser..." -ForegroundColor Magenta
            $installer = Join-Path -Path $tempDir -ChildPath "BraveSetup.exe"
            Invoke-WebRequest -Uri "https://laptop-updates.brave.com/latest/winx64" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Brave Browser silently..." -ForegroundColor Magenta
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Brave Browser installation completed!" -ForegroundColor Green
        }
        '4' {
            Write-Host "`nDownloading Floorp Browser..." -ForegroundColor Cyan
            $installer = Join-Path -Path $tempDir -ChildPath "FloorpSetup.exe"
            Invoke-WebRequest -Uri "https://github.com/Floorp-Projects/Floorp/releases/latest/download/floorp-windows-x86_64-setup.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Floorp Browser silently..." -ForegroundColor Cyan
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Floorp Browser installation completed!" -ForegroundColor Green
        }
        '5' {
            Write-Host "`nDownloading Microsoft Edge..." -ForegroundColor Blue
            $installer = Join-Path -Path $tempDir -ChildPath "MicrosoftEdgeSetup.exe"
            Invoke-WebRequest -Uri "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/latest/MicrosoftEdgeSetup.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Microsoft Edge silently..." -ForegroundColor Blue
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Microsoft Edge installation completed!" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "Download/installation error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
'@

$browserCmdContent = @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Browser.ps1"
'@

$controlCenterContent = @'
@echo off
setlocal enabledelayedexpansion
title WinEase Control Center

:: Elevate with UAC administrator privileges if not already elevated
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c `\"%~f0`\"' -Verb RunAs"
    exit /b
)

:MENU
cls
echo ========================================================
echo                 WinEase Control Center
echo ========================================================
echo   [1] Toggle Windows Defender (Enable / Disable)
echo   [2] Toggle Windows Update   (Enable / Disable)
echo   [3] Toggle Hibernation      (Save RAM-sized GBs on SSD)
echo   [4] Toggle Bluetooth        (Enable / Disable Services)
echo   [5] Toggle Print Spooler    (Enable / Disable Service)
echo   [6] Free Memory ^& Clear Temp (Trim Working Sets ^& Temp)
echo   [7] Install Web Browser     (Chrome, Firefox, Brave...)
echo   [0] Exit
echo ========================================================
set /p choice="Select option [1-7, 0]: "
if "%choice%"=="1" goto DEFENDER
if "%choice%"=="2" goto WU
if "%choice%"=="3" goto HIBERNATE
if "%choice%"=="4" goto BLUETOOTH
if "%choice%"=="5" goto SPOOLER
if "%choice%"=="6" goto FREEMEM
if "%choice%"=="7" goto BROWSER
if "%choice%"=="0" exit /b
goto MENU

:DEFENDER
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service WinDefend -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Windows Defender...
    sc config WinDefend start= disabled >nul 2>&1
    sc stop WinDefend >nul 2>&1
    sc config WdNisSvc start= disabled >nul 2>&1
    sc stop WdNisSvc >nul 2>&1
    sc config Sense start= disabled >nul 2>&1
    sc stop Sense >nul 2>&1
    echo Windows Defender is now DISABLED.
) else (
    echo Enabling Windows Defender...
    sc config WinDefend start= auto >nul 2>&1
    sc start WinDefend >nul 2>&1
    sc config WdNisSvc start= demand >nul 2>&1
    sc start WdNisSvc >nul 2>&1
    sc config Sense start= demand >nul 2>&1
    sc start Sense >nul 2>&1
    echo Windows Defender is now ENABLED.
)
pause
goto MENU

:WU
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service wuauserv -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Windows Update...
    sc config wuauserv start= disabled >nul 2>&1
    sc stop wuauserv >nul 2>&1
    sc config UsoSvc start= disabled >nul 2>&1
    sc stop UsoSvc >nul 2>&1
    echo Windows Update is now DISABLED.
) else (
    echo Enabling Windows Update...
    sc config wuauserv start= auto >nul 2>&1
    sc start wuauserv >nul 2>&1
    sc config UsoSvc start= demand >nul 2>&1
    sc start UsoSvc >nul 2>&1
    echo Windows Update is now ENABLED.
)
pause
goto MENU

:HIBERNATE
echo.
if exist "%SystemDrive%\hiberfil.sys" (
    echo Disabling Hibernation and deleting hiberfil.sys...
    powercfg.exe /hibernate off
    echo Hibernation is now DISABLED.
) else (
    echo Enabling Hibernation...
    powercfg.exe /hibernate on
    echo Hibernation is now ENABLED.
)
pause
goto MENU

:BLUETOOTH
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service bthserv -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Bluetooth...
    sc config bthserv start= disabled >nul 2>&1
    sc stop bthserv >nul 2>&1
    sc config BthAvctpSvc start= disabled >nul 2>&1
    sc stop BthAvctpSvc >nul 2>&1
    echo Bluetooth is now DISABLED.
) else (
    echo Enabling Bluetooth...
    sc config bthserv start= auto >nul 2>&1
    sc start bthserv >nul 2>&1
    sc config BthAvctpSvc start= auto >nul 2>&1
    sc start BthAvctpSvc >nul 2>&1
    echo Bluetooth is now ENABLED.
)
pause
goto MENU

:SPOOLER
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service Spooler -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Print Spooler...
    sc config Spooler start= disabled >nul 2>&1
    sc stop Spooler >nul 2>&1
    echo Print Spooler is now DISABLED.
) else (
    echo Enabling Print Spooler...
    sc config Spooler start= auto >nul 2>&1
    sc start Spooler >nul 2>&1
    echo Print Spooler is now ENABLED.
)
pause
goto MENU

:FREEMEM
echo.
echo Cleaning temporary files...
del /s /f /q "%TEMP%\*.*" >nul 2>&1
del /s /f /q "%SystemRoot%\Temp\*.*" >nul 2>&1
powershell.exe -NoProfile -Command "try { $sig = '[DllImport(\"psapi.dll\")] public static extern int EmptyWorkingSet(IntPtr h);'; Add-Type -MemberDefinition $sig -Name 'Mem' -Namespace 'Win32' -ErrorAction SilentlyContinue; Get-Process | ForEach-Object { try { [Win32.Mem]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }; [GC]::Collect(); Write-Host 'RAM working sets trimmed.' -ForegroundColor Green } catch {}"
echo Done.
pause
goto MENU

:BROWSER
start "" "%~dp0Install-Browser.cmd"
goto MENU
'@

if (-not $NoPostInstallAssets) {
    # Keep maintenance tools safely in Windows\Setup\Tools (do not pollute Public Desktop)
    $browserPs1Content | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.ps1") -Encoding utf8
    $browserCmdContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.cmd") -Encoding ascii
    $controlCenterContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "WinEase Control Center.bat") -Encoding ascii
    Write-Host "  - Staged Browser Grabber and WinEase Control Center to Windows\Setup\Tools" -ForegroundColor Green

    $atlasDir = Join-Path -Path $setupTools -ChildPath "Atlas-ReviOS Tools"
    if (-not (Test-Path -LiteralPath $atlasDir)) {
        New-Item -Path $atlasDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $tool1Def = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Windows Defender
echo ========================================================
sc query WinDefend | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Defender...
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiVirus /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableRealtimeMonitoring /t REG_DWORD /d 1 /f >nul 2>&1
    sc config WinDefend start= disabled >nul 2>&1
    sc stop WinDefend >nul 2>&1
    sc config WdNisSvc start= disabled >nul 2>&1
    sc stop WdNisSvc >nul 2>&1
    sc config Sense start= disabled >nul 2>&1
    sc stop Sense >nul 2>&1
    echo Windows Defender has been DISABLED.
) else (
    echo Enabling Windows Defender...
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiVirus /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableRealtimeMonitoring /f >nul 2>&1
    sc config WinDefend start= auto >nul 2>&1
    sc start WinDefend >nul 2>&1
    sc config WdNisSvc start= demand >nul 2>&1
    sc start WdNisSvc >nul 2>&1
    sc config Sense start= demand >nul 2>&1
    sc start Sense >nul 2>&1
    echo Windows Defender has been ENABLED.
)
pause
'@

    $tool2WU = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Windows Update
echo ========================================================
sc query wuauserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Update...
    sc config wuauserv start= disabled >nul 2>&1
    sc stop wuauserv >nul 2>&1
    sc config UsoSvc start= disabled >nul 2>&1
    sc stop UsoSvc >nul 2>&1
    sc config WaaSMedicSvc start= disabled >nul 2>&1
    sc stop WaaSMedicSvc >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul 2>&1
    echo Windows Update has been DISABLED.
) else (
    echo Enabling Windows Update...
    sc config wuauserv start= demand >nul 2>&1
    sc start wuauserv >nul 2>&1
    sc config UsoSvc start= demand >nul 2>&1
    sc start UsoSvc >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f >nul 2>&1
    echo Windows Update has been ENABLED.
)
pause
'@

    $tool3Hiber = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Hibernation
echo ========================================================
if exist "%SystemDrive%\hiberfil.sys" (
    echo Disabling Hibernation and deleting hiberfil.sys...
    powercfg.exe /h off
    echo Hibernation is now DISABLED (Disk space freed).
) else (
    echo Enabling Hibernation...
    powercfg.exe /h on
    echo Hibernation is now ENABLED.
)
pause
'@

    $tool4BT = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Bluetooth Services
echo ========================================================
sc query bthserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Bluetooth...
    sc config bthserv start= disabled >nul 2>&1
    sc stop bthserv >nul 2>&1
    sc config BthAvctpSvc start= disabled >nul 2>&1
    sc stop BthAvctpSvc >nul 2>&1
    echo Bluetooth services DISABLED.
) else (
    echo Enabling Bluetooth...
    sc config bthserv start= auto >nul 2>&1
    sc start bthserv >nul 2>&1
    sc config BthAvctpSvc start= auto >nul 2>&1
    sc start BthAvctpSvc >nul 2>&1
    echo Bluetooth services ENABLED.
)
pause
'@

    $tool5Spool = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Print Spooler
echo ========================================================
sc query Spooler | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Print Spooler...
    sc config Spooler start= disabled >nul 2>&1
    sc stop Spooler >nul 2>&1
    echo Print Spooler is now DISABLED.
) else (
    echo Enabling Print Spooler...
    sc config Spooler start= auto >nul 2>&1
    sc start Spooler >nul 2>&1
    echo Print Spooler is now ENABLED.
)
pause
'@

    $tool6Mem = @'
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Free Memory & Clear Temp
echo ========================================================
echo Cleaning temporary files...
del /s /f /q "%TEMP%\*.*" >nul 2>&1
del /s /f /q "%SystemRoot%\Temp\*.*" >nul 2>&1
powershell.exe -NoProfile -Command "try { $sig = '[DllImport(\"psapi.dll\")] public static extern int EmptyWorkingSet(IntPtr h);'; Add-Type -MemberDefinition $sig -Name 'Mem' -Namespace 'Win32' -ErrorAction SilentlyContinue; Get-Process | ForEach-Object { try { [Win32.Mem]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }; [GC]::Collect(); Write-Host 'RAM working set trimmed successfully.' -ForegroundColor Green } catch {}"
echo Done.
pause
'@

    $tool7MAS = @'
@echo off
setlocal
title Windows Activation Status
echo ========================================================
echo   WinEase Tool: Windows Activation Status & Helper
echo ========================================================
echo Checking Windows license status...
cscript.exe //nologo %SystemRoot%\System32\slmgr.vbs /dli
echo.
echo To activate Windows with a legitimate digital product key:
echo   slmgr.vbs /ipk YOUR-PRODUCT-KEY
echo   slmgr.vbs /ato
echo.
pause
'@

    $tool1Def   | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "1. Toggle Windows Defender.bat") -Encoding ascii
    $tool2WU    | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "2. Toggle Windows Update.bat") -Encoding ascii
    $tool3Hiber | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "3. Toggle Hibernation.bat") -Encoding ascii
    $tool4BT    | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "4. Toggle Bluetooth.bat") -Encoding ascii
    $tool5Spool | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "5. Toggle Print Spooler.bat") -Encoding ascii
    $tool6Mem   | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "6. Free Memory & Clear Temp.bat") -Encoding ascii
    $tool7MAS   | Set-Content -LiteralPath (Join-Path -Path $atlasDir -ChildPath "7. Check Activation Status.bat") -Encoding ascii
    Write-Host "  - Staged Atlas-ReviOS maintenance tools to Windows\Setup\Tools\Atlas-ReviOS Tools" -ForegroundColor Green

    # Ensure Public Desktop is clean of tools folders
    $cleanItems = @("Atlas-ReviOS Tools", "Install-Browser.cmd", "Install-Browser.ps1", "WinEase Control Center.bat", "WinEase Control Center.cmd")
    foreach ($ci in $cleanItems) {
        $ciPath = Join-Path -Path $pubDesktop -ChildPath $ci
        if (Test-Path -LiteralPath $ciPath) {
            Remove-Item -LiteralPath $ciPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host "  - Skipping staging of post-install assets (-NoPostInstallAssets specified)." -ForegroundColor Yellow
}

# Ensure CurrentControlSet does NOT exist in offline SYSTEM hive
# Creating CurrentControlSet as a real key in an offline hive causes Bug Check 0x67 (CONFIG_INITIALIZATION_FAILED)
# because the NT kernel fails to create the CurrentControlSet symbolic link at boot time.
& reg.exe query "HKLM\zSYSTEM\CurrentControlSet" > $null 2>&1
if ($LASTEXITCODE -eq 0) {
    reg.exe delete "HKLM\zSYSTEM\CurrentControlSet" /f > $null 2>&1
}

# Unmount Registry Hives
Write-Host "Unmounting offline registry hives..." -ForegroundColor Cyan
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
    [void](Unmount-RegistryHiveWithRetry -Name $_)
}
$script:HivesLoaded = $false

# Capture post-debloat metrics and calculate component savings
Write-Host "Capturing post-debloat image metrics and calculating savings..." -ForegroundColor Cyan
$pkgAfterPath = Join-Path -Path $logDir -ChildPath "packages-after.txt"
$featAfterPath = Join-Path -Path $logDir -ChildPath "features-after.txt"
$winsxsAfterPath = Join-Path -Path $logDir -ChildPath "winsxs-after.txt"

# DISM creates its servicing-stack shim folder under <image>\Windows\Temp; if debloat removed it,
# every /image: query fails with 0x80070003 (exit 87). Recreate it before querying.
$imageTempDir = Join-Path -Path $scratchDir -ChildPath 'Windows\Temp'
if (-not (Test-Path -LiteralPath $imageTempDir)) {
    New-Item -ItemType Directory -Path $imageTempDir -Force | Out-Null
    Write-Host "  - Recreated missing $imageTempDir (required by DISM servicing stack)" -ForegroundColor Yellow
}

Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Packages", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $pkgAfterPath -Encoding utf8
Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Features", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $featAfterPath -Encoding utf8
if ($safeDebloatMode) {
    Write-Host "SafeDebloatMode enabled: Skipping /AnalyzeComponentStore scan prior to commit to preserve memory and stream stability." -ForegroundColor Cyan
    $script:WinsxsAfterRaw = @("Actual Size of Component Store : 0 MB", "(AnalyzeComponentStore skipped in SafeDebloatMode)")
    $script:WinsxsAfterRaw | Set-Content -LiteralPath $winsxsAfterPath -Encoding utf8
} else {
    $script:WinsxsAfterRaw = Invoke-Dism -DismArgs @("/image:$scratchDir", "/Cleanup-Image", "/AnalyzeComponentStore") -CaptureOutput
    $script:WinsxsAfterRaw | Set-Content -LiteralPath $winsxsAfterPath -Encoding utf8
}

$pkgsBefore = Get-Content -LiteralPath $pkgBeforePath -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Package_' }
$pkgsAfter  = Get-Content -LiteralPath $pkgAfterPath -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Package_' }
$script:RemovedPackages = @()
if ($pkgsBefore -and $pkgsAfter) {
    $diff = Compare-Object -ReferenceObject $pkgsBefore -DifferenceObject $pkgsAfter -ErrorAction SilentlyContinue
    $script:RemovedPackages = @($diff | Where-Object SideIndicator -eq '<=' | ForEach-Object { $_.InputObject.Trim() })
}
$script:RemovedPackages | Set-Content -LiteralPath (Join-Path -Path $logDir -ChildPath "removed-packages.txt") -Encoding utf8
Write-Host "Component Store Diff: $($script:RemovedPackages.Count) package(s) removed from image." -ForegroundColor Green

$parseSizeHelper = {
    param($lines)
    foreach ($l in $lines) {
        if ($l -match 'Actual Size of Component Store\s*:\s*([\d\.]+)\s*(GB|MB)') {
            $val = [double]$matches[1]
            if ($matches[2] -ieq 'GB') { return [math]::Round($val * 1024, 1) }
            return $val
        }
    }
    return 0
}
$script:WinSxsBeforeMB = & $parseSizeHelper $script:WinsxsBeforeRaw
$script:WinSxsAfterMB  = & $parseSizeHelper $script:WinsxsAfterRaw
$script:WinSxsSavedMB  = if ($script:WinSxsBeforeMB -gt 0 -and $script:WinSxsAfterMB -gt 0) { [math]::Max(0, [math]::Round($script:WinSxsBeforeMB - $script:WinSxsAfterMB, 1)) } else { 0 }

# M2: User extension actions (SetupScripts)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType SetupScripts -ScratchDir $scratchDir -DryRun:$DryRun -Context @{ ScratchDir = $scratchDir; Config = $resolvedConfig } | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}
# M2: Custom scripts (OfflineImage stage) - runs after the registry/unattend work, before FirstLogon/UserOnce staging
if (Get-Command -Name Invoke-WinEaseCustomScriptsStage -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseCustomScriptsStage -Stage 'OfflineImage' -Context @{ ScratchDir = $scratchDir; WinEaseDir = $WinEaseDir; Config = $resolvedConfig } -DryRun:$DryRun | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}
# M2: Custom scripts (FirstLogon & UserOnce stages -> copy to offline image)
$customFirstLogonDir = Join-Path -Path $scratchDir -ChildPath 'Windows\Setup\Scripts\Custom\FirstLogon'
$customUserOnceDir = Join-Path -Path $scratchDir -ChildPath 'Windows\Setup\Scripts\Custom\UserOnce'
Write-Verbose "Custom dirs: $customFirstLogonDir, $customUserOnceDir"
if (Get-Command -Name Invoke-WinEaseCustomScriptsStage -ErrorAction SilentlyContinue) {
    try {
        Invoke-WinEaseCustomScriptsStage -Stage 'FirstLogon' -Context @{ ScratchDir = $scratchDir; Config = $resolvedConfig } -DryRun:$DryRun | Out-Null
        Invoke-WinEaseCustomScriptsStage -Stage 'UserOnce' -Context @{ ScratchDir = $scratchDir; Config = $resolvedConfig } -DryRun:$DryRun | Out-Null
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# M2: Register custom FirstLogon scripts in autounattend.xml FirstLogonCommands
try {
    $customScripts = @()
    if (Test-Path -LiteralPath $customFirstLogonDir) {
        $customScripts = @(Get-ChildItem -LiteralPath $customFirstLogonDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    }
    if ($customScripts.Count -gt 0 -and -not $DryRun) {
        $firstLogonPass = $xmlDoc.SelectSingleNode("//u:settings[@pass='oobeSystem']", $nsMgr)
        if ($firstLogonPass) {
            $shellComp = $firstLogonPass.SelectSingleNode("u:component[@name='Microsoft-Windows-Shell-Setup']", $nsMgr)
            if ($shellComp) {
                $flc = $shellComp.SelectSingleNode("u:FirstLogonCommands", $nsMgr)
                if (-not $flc) {
                    $flc = $xmlDoc.CreateElement("FirstLogonCommands", $xmlDoc.DocumentElement.NamespaceURI)
                    [void]$shellComp.AppendChild($flc)
                }
                # Determine next order number
                $existingOrders = @($flc.SelectNodes("u:SynchronousCommand/u:Order", $nsMgr) | ForEach-Object { [int]$_.InnerText })
                $nextOrder = if ($existingOrders.Count -gt 0) { ($existingOrders | Measure-Object -Maximum).Maximum + 1 } else { 1 }
                foreach ($cs in $customScripts) {
                    $relPath = "C:\Windows\Setup\Scripts\Custom\FirstLogon\$($cs.Name)"
                    $cmd = $xmlDoc.CreateElement("SynchronousCommand", $xmlDoc.DocumentElement.NamespaceURI)
                    $cmd.SetAttribute("wcm:action", "add", "http://schemas.microsoft.com/WMIConfig/2002/State")
                    $orderNode = $xmlDoc.CreateElement("Order", $xmlDoc.DocumentElement.NamespaceURI)
                    $orderNode.InnerText = "$nextOrder"
                    [void]$cmd.AppendChild($orderNode)
                    $descNode = $xmlDoc.CreateElement("Description", $xmlDoc.DocumentElement.NamespaceURI)
                    $descNode.InnerText = "Custom FirstLogon script: $($cs.Name)"
                    [void]$cmd.AppendChild($descNode)
                    $pathNode = $xmlDoc.CreateElement("Path", $xmlDoc.DocumentElement.NamespaceURI)
                    $pathNode.InnerText = "powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$relPath`""
                    [void]$cmd.AppendChild($pathNode)
                    [void]$flc.AppendChild($cmd)
                    $nextOrder++
                }
                Write-Host "  Registered $($customScripts.Count) custom FirstLogon script(s) in autounattend.xml" -ForegroundColor Green
                # AUD-01: the nodes added above only exist in the in-memory DOM. The document
                # was written to disk much earlier in this phase, so without an explicit save
                # here the custom FirstLogon commands were silently dropped and never ran.
                foreach ($dest in $script:UnattendSaveTargets) {
                    try {
                        Save-WinEaseUnattendXml -XmlDocument $xmlDoc -DestinationPath $dest
                    } catch {
                        Write-Warning "  - Could not persist the custom FirstLogon commands to '$dest': $($_.Exception.Message)"
                    }
                }
            }
        }
    }
} catch {
    Write-Verbose "Ignored: $($_.Exception.Message)"
}

# Migration Assistant bundle: tool + engine + rule files only (no personal data) and a desktop launcher
if ($includeMigrationAssistant -eq $true) {
    try {
        $migrationFiles = @(
            'tools\migrator\WinEase-Migrator.ps1',
            'tools\migrator\WinEaseMigration.ps1',
            'tools\migrator\migration-rules.psd1',
            'config\user\user-migration-rules.psd1'
        )
        $migrationDestDir = Join-Path -Path $scratchDir -ChildPath 'Windows\Setup\Scripts\Migration'
        $migrationDesktopDir = Join-Path -Path $scratchDir -ChildPath 'Users\Public\Desktop'
        $migrationLauncherPath = Join-Path -Path $migrationDesktopDir -ChildPath 'Launch-MigrationAssistant.cmd'
        $migrationLauncherLines = @(
            '@echo off',
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\Migration\WinEase-Migrator.ps1" -GUI'
        )
        if ($DryRun) {
            Write-Host "  [DryRun] Would copy Migration Assistant files to $migrationDestDir" -ForegroundColor DarkYellow
            foreach ($mf in $migrationFiles) { Write-Host "    - $mf" -ForegroundColor DarkYellow }
            Write-Host "  [DryRun] Would create $migrationLauncherPath" -ForegroundColor DarkYellow
        } else {
            New-Item -ItemType Directory -Path $migrationDestDir -Force | Out-Null
            New-Item -ItemType Directory -Path $migrationDesktopDir -Force | Out-Null
            foreach ($mf in $migrationFiles) {
                $mfSrc = Join-Path -Path $scriptDir -ChildPath $mf
                if ((Split-Path -Path $mf -Leaf) -eq 'user-migration-rules.psd1') { $mfSrc = Resolve-WinEaseUserConfigPath -RepoRoot $scriptDir -Name 'user-migration-rules.psd1' }
                if (Test-Path -LiteralPath $mfSrc) {
                    Copy-Item -LiteralPath $mfSrc -Destination (Join-Path -Path $migrationDestDir -ChildPath (Split-Path -Path $mf -Leaf)) -Force
                } else {
                    Write-Warning "Migration Assistant file not found, skipped: $mfSrc"
                }
            }
            Set-Content -LiteralPath $migrationLauncherPath -Value $migrationLauncherLines -Encoding ASCII
            Write-Host "  Migration Assistant bundled into the image" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Migration Assistant bundling failed: $($_.Exception.Message)"
    }
}
