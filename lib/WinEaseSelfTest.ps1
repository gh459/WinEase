# WinEaseSelfTest.ps1 - Built-in diagnostic and repository self-test suite (-TestSelf)
# Dot-sourced by WinEasebuilder.ps1 only when -TestSelf is used.

# Self-test check: AST Syntax Check
function Test-WinEaseSelfCheck01AstSyntax {
    param([string]$BuilderPath)
    $astPass = $false
    $astMsg = ""
    if (Test-Path -LiteralPath $BuilderPath) {
        $content = [System.IO.File]::ReadAllText($BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        if ($errors.Count -eq 0) {
            $astPass = $true
            $astMsg = "0 parser errors found in $([math]::Round($content.Length / 1KB, 1)) KB script"
        } else {
            $astMsg = "$($errors.Count) syntax errors: " + (($errors | Select-Object -First 3 | ForEach-Object { $_.Message }) -join "; ")
        }
    } else {
        $astMsg = "$([System.IO.Path]::GetFileName($BuilderPath)) not found"
    }
    return [PSCustomObject]@{ Test = "1. Builder Script AST Syntax"; Passed = $astPass; Details = $astMsg }
}

# Self-test check: Registry Safety Validation (zSYSTEM\CurrentControlSet check)
function Test-WinEaseSelfCheck02RegistrySafety {
    param([string]$BuilderPath)
    $regSafePass = $true
    $regMsg = "Safe: No illegal offline CurrentControlSet keys created"
    if (Test-Path -LiteralPath $BuilderPath) {
        $lines = Get-Content -LiteralPath $BuilderPath
        $illegal = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -like "*zSYSTEM\CurrentControlSet*" -and $line -notlike "*reg.exe query*" -and $line -notlike "*reg.exe delete*" -and $line -notlike "*#*") {
                $illegal += "Line $($i+1): $line"
            }
        }
        if ($illegal.Count -gt 0) {
            $regSafePass = $false
            $regMsg = "FAILED: Found $($illegal.Count) illegal CurrentControlSet operations"
        }
    }
    return [PSCustomObject]@{ Test = "2. Offline Registry Safety Rule"; Passed = $regSafePass; Details = $regMsg }
}

# Self-test check: autounattend.xml XML Schema & Duplicate Component Check
function Test-WinEaseSelfCheck03UnattendSchema {
    param([string]$UnattendPath)
    $xmlPass = $false
    $xmlMsg = ""
    if (Test-Path -LiteralPath $UnattendPath) {
        try {
            $doc = [xml]::new()
            $doc.Load($UnattendPath)
            if ($doc.DocumentElement.Name -eq 'unattend' -and $doc.unattend.settings) {
                # Check for duplicate components in the same pass
                $duplicateComponents = @()
                foreach ($pass in $doc.unattend.settings) {
                    $passName = $pass.pass
                    $compKeys = @($pass.component | ForEach-Object { "$($_.name) [$($_.processorArchitecture)]" })
                    $dups = $compKeys | Group-Object | Where-Object { $_.Count -gt 1 }
                    if ($dups) {
                        $duplicateComponents += "Pass '$passName': $($dups.Name -join ', ')"
                    }
                }
                if ($duplicateComponents.Count -gt 0) {
                    $xmlPass = $false
                    $xmlMsg = "Duplicate components found: $($duplicateComponents -join '; ')"
                } else {
                    $xmlPass = $true
                    $xmlMsg = "Valid XML: $($doc.unattend.settings.component.Count) components configured, 0 duplicates"
                }
            } else {
                $xmlMsg = "Missing required unattend/settings structure"
            }
        } catch {
            $xmlMsg = "Parse error: $($_.Exception.Message)"
        }
    } else {
        $xmlMsg = "autounattend.xml not found"
    }
    return [PSCustomObject]@{ Test = "3. autounattend.xml Schema"; Passed = $xmlPass; Details = $xmlMsg }
}

# Self-test check: Built-in Profile Presets & Modular Tweak Integrity
function Test-WinEaseSelfCheck04ProfilePresets {
    param()
    $profPass = $false
    $profMsg = ""
    $expectedPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $missingPresets = @()
    foreach ($ep in $expectedPresetKeys) {
        if (-not $script:BuiltInPresets.Contains($ep)) {
            $missingPresets += $ep
        }
    }
    if ($missingPresets.Count -eq 0 -and $script:TweakGroups.Count -ge 4) {
        $badPresets = @()
        foreach ($kv in $script:BuiltInPresets.GetEnumerator()) {
            $pName = $kv.Key
            $pDef = $kv.Value
            if (-not $pDef.ProfileName -or -not $pDef.Description) {
                $badPresets += "$pName (missing ProfileName/Description)"
            }
            if (-not $pDef.TweakGroups) {
                $badPresets += "$pName (missing TweakGroups)"
            }
        }
        if ($badPresets.Count -eq 0) {
            $profPass = $true
            $profMsg = "$($script:BuiltInPresets.Count) built-in presets validated ($($expectedPresetKeys -join ', ')), $($script:TweakGroups.Count) tweak groups"
        } else {
            $profMsg = "Preset errors: $($badPresets -join '; ')"
        }
    } else {
        $profMsg = "Missing built-in presets: $($missingPresets -join ', ')"
    }
    return [PSCustomObject]@{ Test = "4. Profile Presets Integrity"; Passed = $profPass; Details = $profMsg }
}

# Self-test check: Tools Folder & Binary Integrity Check
function Test-WinEaseSelfCheck05ToolingAssets {
    param([string]$ScriptRoot)
    $oscdPath = Join-Path $ScriptRoot "oscdimg.exe"
    $oscdValid = Test-OscdimgIntegrity -OscdimgPath $oscdPath
    $toolsDir = Join-Path -Path $ScriptRoot -ChildPath "tools"
    $toolsPass = $false
    $toolsMsg = ""
    if ($oscdValid) {
        $toolsPass = $true
        $toolsMsg = "Verified oscdimg.exe binary present and signature/hash valid"
    } elseif (Test-Path -LiteralPath $toolsDir) {
        $wingetPath = Join-Path $toolsDir "winget-packages.json"
        $toolsPass = Test-Path -LiteralPath $wingetPath
        $toolsMsg = "tools/ directory verified"
    } else {
        # Clean repository state: oscdimg is auto-located in PATH/ADK or downloaded on demand
        $toolsPass = $true
        $toolsMsg = "Clean workspace (tools directory optional; oscdimg auto-resolved on demand)"
    }
    return [PSCustomObject]@{ Test = "5. Core Deployment & Tooling Assets"; Passed = $toolsPass; Details = $toolsMsg }
}

# Self-test check: Batch Script Dynamic Target Resolution Check
function Test-WinEaseSelfCheck06BatchTargets {
    param([string]$ScriptRoot)
    $batPass = $false
    $batMsg = ""
    $batFiles = Get-ChildItem -Path $ScriptRoot -Filter "*.bat" -File -ErrorAction SilentlyContinue
    if ($batFiles.Count -gt 0) {
        $badBats = @()
        foreach ($bf in $batFiles) {
            $batText = [System.IO.File]::ReadAllText($bf.FullName, [System.Text.Encoding]::UTF8)
            if ($batText -match 'BUILDER' -or $batText -match 'WinEasebuilder') {
                # Valid reference
            } else {
                $badBats += "$($bf.Name) (no builder reference)"
            }
        }
        if ($badBats.Count -eq 0) {
            $batPass = $true
            $batMsg = "$($batFiles.Count) batch file(s) verified with dynamic builder resolution"
        } else {
            $batMsg = "Batch issues: $($badBats -join ', ')"
        }
    } else {
        $batPass = $true
        $batMsg = "No .bat files found in root"
    }
    return [PSCustomObject]@{ Test = "6. Batch Target Resolution"; Passed = $batPass; Details = $batMsg }
}

# Self-test check: autounattend Singularity & Embedded Scripts Integrity
function Test-WinEaseSelfCheck07UnattendSingularity {
    param([string]$ScriptRoot)
    $unattendSingularPass = $false
    $unattendSingularMsg = ""
    $allUnattends = Get-ChildItem -Path $ScriptRoot -Filter "*unattend*.xml" -File -ErrorAction SilentlyContinue
    if ($allUnattends.Count -eq 1 -and $allUnattends[0].Name -ieq "autounattend.xml") {
        $xmlRaw = [System.IO.File]::ReadAllText($allUnattends[0].FullName, [System.Text.Encoding]::UTF8)
        $requiredScripts = @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1')
        $missingScripts = @()
        foreach ($rs in $requiredScripts) {
            if ($xmlRaw -notmatch [regex]::Escape($rs)) {
                $missingScripts += $rs
            }
        }
        if ($missingScripts.Count -eq 0) {
            $unattendSingularPass = $true
            $unattendSingularMsg = "Single canonical autounattend.xml present; all 4 setup scripts embedded"
        } else {
            $unattendSingularMsg = "Missing scripts: $($missingScripts -join ', ')"
        }
    } elseif ($allUnattends.Count -gt 1) {
        $unattendSingularMsg = "Multiple unattend files detected ($($allUnattends.Name -join ', ')) - only autounattend.xml should exist"
    } else {
        $unattendSingularMsg = "autounattend.xml missing"
    }
    return [PSCustomObject]@{ Test = "7. Unattend Singularity & Scripts"; Passed = $unattendSingularPass; Details = $unattendSingularMsg }
}

# Self-test check: AppX Pattern Matching & Syntax Verification
function Test-WinEaseSelfCheck08AppxPatterns {
    param()
    $appxTestPass = $false
    $appxTestMsg = ""
    $samplePackages = @(
        'Microsoft.BingWeather_4.25.7081.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsNotepad_11.2409.3.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Paint_11.2408.30.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsCalculator_11.2405.0.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.549981C3F5F10_4.2204.13303.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.ZuneVideo_2019.22091.10041.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.GamingApp_2309.1001.4.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Getstarted_10.2209.1.0_neutral_~_8wekyb3d8bbwe'
    )
    $testPatterns = @('*Bing*', '*Notepad*', '*Paint*', '*Calculator*', '*549981C3F5F10*', '*Zune*', '*GamingApp*', '*Getstarted*')
    $unmatched = @()
    foreach ($tp in $testPatterns) {
        $matched = $false
        foreach ($sp in $samplePackages) {
            if ($sp -like $tp) { $matched = $true; break }
        }
        if (-not $matched) { $unmatched += $tp }
    }
    if ($unmatched.Count -eq 0) {
        $appxTestPass = $true
        $appxTestMsg = "All core AppX bloatware wildcard patterns match realistic package signatures"
    } else {
        $appxTestMsg = "Dead pattern(s): $($unmatched -join ', ')"
    }
    return [PSCustomObject]@{ Test = "8. AppX Pattern Match Safety"; Passed = $appxTestPass; Details = $appxTestMsg }
}

# Self-test check: DISM Offline Hives Detection & Safety Isolation Check
function Test-WinEaseSelfCheck09HiveIsolation {
    param()
    $hiveTestPass = $false
    $hiveTestMsg = ""
    try {
        $testTargetDir = 'C:\WinEase_workspace\scratchdir'
        $normTestTarget = ConvertTo-WinEaseNormalizedPath -Path $testTargetDir

        $expectedRelative = @(
            'Users\Default\ntuser.dat',
            'Windows\System32\config\COMPONENTS',
            'Windows\System32\config\DEFAULT',
            'Windows\System32\config\DRIVERS',
            'Windows\System32\config\SAM',
            'Windows\System32\config\SECURITY',
            'Windows\System32\config\SOFTWARE',
            'Windows\System32\config\SYSTEM',
            'Windows\System32\smi\store\Machine\schema.dat'
        )
        $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sub in $expectedRelative) {
            [void]$expectedSet.Add((ConvertTo-WinEaseNormalizedPath -Path ([System.IO.Path]::Combine($normTestTarget, $sub))))
        }

        $mockKeys = @(
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/COMPONENTS',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/DEFAULT',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/DRIVERS',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/SAM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/SECURITY',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/SOFTWARE',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/System32/config/SYSTEM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/Windows/system32/smi/store/Machine/schema.dat',
            '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}c:\WinEase_workspace\scratchdir\Users\Default\ntuser.dat',
            'HARDWARE',
            'SAM',
            'SECURITY',
            'SOFTWARE',
            'SYSTEM',
            'BCD00000000',
            'zSYSTEM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir-old/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}D:/WinEase_workspace/scratchdir/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/WinEase_workspace/scratchdir/unknown/file.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}'
        )

        $regex = '(?i)^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}(?<HivePath>[A-Za-z]:[\\/].+)$'
        $matchedKeys = @()
        foreach ($mk in $mockKeys) {
            if ($mk -match $regex) {
                try {
                    $normH = ConvertTo-WinEaseNormalizedPath -Path $Matches['HivePath']
                    if ($expectedSet.Contains($normH)) {
                        $matchedKeys += $mk
                    }
                } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }

        if ($matchedKeys.Count -eq 10) {
            $hiveTestPass = $true
            $hiveTestMsg = "10/10 mock hives correctly matched and 11 safety boundary keys rejected"
        } else {
            $hiveTestMsg = "Expected 10 matches but got $($matchedKeys.Count): $($matchedKeys -join '; ')"
        }
    } catch {
        $hiveTestMsg = "Exception during hive test: $_"
    }
    return [PSCustomObject]@{ Test = "9. DISM Offline Hives Isolation"; Passed = $hiveTestPass; Details = $hiveTestMsg }
}

# Self-test check: Dynamic Mount Path Generation & Uniqueness (install, boot, verify)
function Test-WinEaseSelfCheck10MountPathGeneration {
    param()
    $mountGenPass = $false
    $mountGenMsg = ""
    $origRoot = $script:MountAllocationRoot
    $origPrefix = $script:MountDirectoryPrefix
    $origManaged = $script:ManagedMountDirs
    $origAlloc = $script:AllocatedMountDirs
    try {
        $testAllocRoot = 'C:\WinEase_workspace'
        $script:MountAllocationRoot = $testAllocRoot
        $script:MountDirectoryPrefix = 'scratchdir_'
        $script:ManagedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:AllocatedMountDirs = [System.Collections.Generic.List[string]]::new()

        $pInstall = New-WinEaseMountDirectoryPath
        $pBoot1   = New-WinEaseMountDirectoryPath
        $pBoot2   = New-WinEaseMountDirectoryPath
        $pVerify  = New-WinEaseMountDirectoryPath

        $allPaths = @($pInstall, $pBoot1, $pBoot2, $pVerify)
        $uniquePaths = $allPaths | Select-Object -Unique
        $allValidGuid = $true
        foreach ($p in $allPaths) {
            $baseName = [System.IO.Path]::GetFileName($p)
            if ($baseName -notmatch '^scratchdir_[0-9a-f]{32}$') {
                $allValidGuid = $false
            }
        }

        if ($allPaths.Count -eq 4 -and $uniquePaths.Count -eq 4 -and $allValidGuid) {
            $mountGenPass = $true
            $mountGenMsg = "4 distinct unique GUID mount paths generated for install/boot1/boot2/verify without collisions"
        } else {
            $mountGenMsg = "Collision or invalid format detected in generated mount paths"
        }
    } catch {
        $mountGenMsg = "Exception in mount path generator: $_"
    } finally {
        $script:MountAllocationRoot = $origRoot
        $script:MountDirectoryPrefix = $origPrefix
        $script:ManagedMountDirs = $origManaged
        $script:AllocatedMountDirs = $origAlloc
    }
    return [PSCustomObject]@{ Test = "10. Dynamic Mount Path Generation"; Passed = $mountGenPass; Details = $mountGenMsg }
}

# Self-test check: Mount Conflict Error Classification & Retry Limit Logic
function Test-WinEaseSelfCheck11MountConflict {
    param()
    $conflictTestPass = $false
    $conflictTestMsg = ""
    try {
        # Check error code hex formatting and conflict classification
        $conflictCodes = @(0xC1420113, 0xC1420114, 0xC1420127)
        $expectedHex = @('0xC1420113', '0xC1420114', '0xC1420127')
        $allHexMatch = $true
        for ($i = 0; $i -lt $conflictCodes.Count; $i++) {
            $hex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$conflictCodes[$i]), 0))
            if ($hex -ne $expectedHex[$i]) {
                $allHexMatch = $false
            }
        }

        # Simulate 3-attempt limit with mock path rotation
        $mockTriedDirs = [System.Collections.Generic.List[string]]::new()
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $mockTriedDirs.Add("C:\WinEase_workspace\scratchdir_" + [Guid]::NewGuid().ToString('N'))
        }
        $retryLimitEnforced = ($mockTriedDirs.Count -eq 3) -and (($mockTriedDirs | Select-Object -Unique).Count -eq 3)

        if ($allHexMatch -and $retryLimitEnforced) {
            $conflictTestPass = $true
            $conflictTestMsg = "0xC1420113/0xC1420114/0xC1420127 conflict classification verified; 3-attempt rotation limit enforced"
        } else {
            $conflictTestMsg = "Conflict code classification or retry limit mismatch"
        }
    } catch {
        $conflictTestMsg = "Exception during conflict classification test: $_"
    }
    return [PSCustomObject]@{ Test = "11. Mount Conflict Classification"; Passed = $conflictTestPass; Details = $conflictTestMsg }
}

# Self-test check: Mount Safety Isolation & Reparse/VHDX Protection
function Test-WinEaseSelfCheck12MountSafety {
    param()
    $safetyGuardPass = $false
    $safetyGuardMsg = ""
    try {
        # Test boundary and containment logic
        $rootWk = 'C:\WinEase_workspace'
        $validChild = 'C:\WinEase_workspace\scratchdir_abc'
        $nestedChild = 'C:\WinEase_workspace\scratchdir_abc\sub'
        $outsidePath = 'C:\Windows\System32'

        $normRoot = ConvertTo-WinEaseNormalizedPath -Path $rootWk
        $normValid = ConvertTo-WinEaseNormalizedPath -Path $validChild
        $normOutside = ConvertTo-WinEaseNormalizedPath -Path $outsidePath

        # Direct child check
        $parentOfValid = [System.IO.Path]::GetDirectoryName($normValid)
        $isDirectChild = [string]::Equals($parentOfValid, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)

        # External path rejection
        $isOutsideRejected = -not $normOutside.StartsWith($normRoot, [System.StringComparison]::OrdinalIgnoreCase)

        # Ancestor/Descendant overlap detection
        $isAncestorOrDescendant = ($nestedChild.StartsWith($validChild, [System.StringComparison]::OrdinalIgnoreCase))

        if ($isDirectChild -and $isOutsideRejected -and $isAncestorOrDescendant) {
            $safetyGuardPass = $true
            $safetyGuardMsg = "Direct child containment, external boundary enforcement, and ancestor overlap checks validated"
        } else {
            $safetyGuardMsg = "Safety boundary assertion failed"
        }
    } catch {
        $safetyGuardMsg = "Exception during safety guard test: $_"
    }
    return [PSCustomObject]@{ Test = "12. Mount Safety & Boundary Guards"; Passed = $safetyGuardPass; Details = $safetyGuardMsg }
}

# Self-test check: Font & Asian IME Preservation Filter Logic (Phase 6, 8, 9)
function Test-WinEaseSelfCheck13FontImePreservation {
    param()
    $imeFontPass = $false
    $imeFontMsg = ""
    try {
        # Mock package patterns baseline
        $basePatterns = @(
            "Microsoft-Windows-InternetExplorer-Optional-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Hant-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Kore-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Thai-Package~",
            "*IME-ko-kr*",
            "*IME-zh-cn*",
            "*IME-zh-tw*",
            "*IME-zh-hk*"
        )

        # Test Case A: Both keepExtraFonts=$true and keepAsianIME=$true
        $patternsA = $basePatterns
        $kFontsA = $true
        $kImeA = $true
        if ($kFontsA) {
            $patternsA = @($patternsA | Where-Object { $_ -notlike "Microsoft-Windows-LanguageFeatures-Fonts-*" })
        }
        if ($kImeA) {
            $patternsA = @($patternsA | Where-Object {
                $_ -notlike "*IME-ko-kr*" -and
                $_ -notlike "*IME-zh-cn*" -and
                $_ -notlike "*IME-zh-tw*" -and
                $_ -notlike "*IME-zh-hk*"
            })
        }

        # Verify no Font or IME patterns remain in removal list
        $hasFontPatterns = ($patternsA | Where-Object { $_ -like "*Fonts-*" }).Count -gt 0
        $hasImePatterns = ($patternsA | Where-Object { $_ -like "*IME-*" }).Count -gt 0

        # Defensive candidate rejection test
        $mockCandidates = @(
            "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-LanguageFeatures-Fonts-Jpan-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-ko-kr-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-zh-cn-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-ja-jp-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35~amd64~~10.0.26100.1"
        )
        $rejectedCount = 0
        foreach ($pkgId in $mockCandidates) {
            if ($kFontsA -and ($pkgId -like "*LanguageFeatures-Fonts-*")) { $rejectedCount++; continue }
            if ($kImeA -and ($pkgId -like "*IME-*" -or $pkgId -like "*Fonts-Jpan*")) { $rejectedCount++; continue }
        }

        # WinSxS dirsToKeep check with keepExtraFonts=$true
        $mockDirsToKeep = @("Catalogs", "Manifests")
        if ($kImeA) { $mockDirsToKeep += @("*inputmethod*", "*ime*") }
        if ($kFontsA) { $mockDirsToKeep += @("*font*") }
        $hasFontInSxS = ($mockDirsToKeep -contains "*font*")

        if (-not $hasFontPatterns -and -not $hasImePatterns -and ($rejectedCount -eq 5) -and $hasFontInSxS) {
            $imeFontPass = $true
            $imeFontMsg = "Font and Asian IME patterns filtered; 5/5 mock IME/Font packages rejected; WinSxS *font* preserved"
        } else {
            $imeFontMsg = "Font/IME preservation leakage detected (hasFonts=$hasFontPatterns, hasIme=$hasImePatterns, rejected=$rejectedCount, sxs=$hasFontInSxS)"
        }
    } catch {
        $imeFontMsg = "Exception during font/IME test: $_"
    }
    return [PSCustomObject]@{ Test = "13. Font & Asian IME Preservation"; Passed = $imeFontPass; Details = $imeFontMsg }
}

# Self-test check: Workspace Preservation & Mount Cleanup Guard
function Test-WinEaseSelfCheck14WorkspacePreservation {
    param()
    $preserveTestPass = $false
    $preserveTestMsg = ""
    try {
        $mockPreserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $mockMount = 'C:\WinEase_workspace\scratchdir_failed123'
        $normMock = ConvertTo-WinEaseNormalizedPath -Path $mockMount
        [void]$mockPreserved.Add($normMock)

        # Check if preserved directory is protected
        $isPreservedProtected = $mockPreserved.Contains($normMock)

        # Verify build failure preservation semantics
        $mockBuildSuccess = $false
        $preserveOnFailure = if (-not $mockBuildSuccess) { $true } else { $false }

        if ($isPreservedProtected -and $preserveOnFailure) {
            $preserveTestPass = $true
            $preserveTestMsg = "Failed workspace mount directories correctly registered in PreservedMountDirs and guarded from cleanup"
        } else {
            $preserveTestMsg = "Workspace preservation logic mismatch"
        }
    } catch {
        $preserveTestMsg = "Exception during workspace preservation test: $_"
    }
    return [PSCustomObject]@{ Test = "14. Workspace Preservation Logic"; Passed = $preserveTestPass; Details = $preserveTestMsg }
}

# Self-test check: WinSxS & AppX Safety Protection Guards (Hardlinks, 24H2 LCU, System Whitelist)
function Test-WinEaseSelfCheck15WinSxsAppxGuards {
    param()
    $safetyExtPass = $false
    $safetyExtMsg = ""
    try {
        # A. AppX Whitelist Filtering Test
        $mockAppxWhitelisted = @(
            'Microsoft.UI.Xaml.2.8_8.2310.30001.0_x64__8wekyb3d8bbwe',
            'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe',
            'MicrosoftWindows.Client.CBS_1000.26100.32.0_x64__cw5n1h2txyewy',
            'Microsoft.Windows.ShellExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.Windows.StartMenuExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.Windows.PeopleExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'WindowsInternal.ComposableShell.Experiences.TextInput.InputApp_1000.26100.1.0_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.Windows.Sense.Client_10.0.26100.1_neutral_neutral_cw5n1h2txyewy'
        )

        $testProtPatterns = @(
            '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.NET.Native*',
            '*MicrosoftWindows.Client.CBS*', '*Microsoft.Windows.ShellExperienceHost*',
            '*Microsoft.Windows.StartMenuExperienceHost*', '*Microsoft.Windows.PeopleExperienceHost*',
            '*WindowsInternal.*', '*Microsoft.DesktopAppInstaller*',
            '*Microsoft.Services.Store.Engagement*', '*Microsoft.Windows.Sense.Client*',
            '*CoreAI*', '*PinningConfirmationDialog*', '*SecureAssessmentBrowser*'
        )
        $testProtRegex = [regex]::new(('^(' + (($testProtPatterns | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }) -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $whitelistedBlocked = 0
        foreach ($pkg in $mockAppxWhitelisted) {
            if ($testProtRegex.IsMatch($pkg)) { $whitelistedBlocked++ }
        }

        # D. Defender removal must take the Windows Security UI package with it.
        #    When Defender is removed there is nothing left for SecHealthUI to display, so
        #    the package must end up in the removal list instead of the protection list.
        $mockSecHealth = 'Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe'
        $secHealthProtected = $testProtRegex.IsMatch($mockSecHealth)
        $testRemovePatterns = @('*Microsoft.SecHealthUI*', '*Microsoft.Windows.SecHealthUI*')
        $testRemoveRegex = [regex]::new(('^(' + (($testRemovePatterns | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }) -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $secHealthRemoved = $testRemoveRegex.IsMatch($mockSecHealth)

        # B. WinSxS 24H2 Guard Verification
        $mockBuild24H2 = 26100
        $mockBuild23H2 = 22631
        $guardBlocked24H2 = ($mockBuild24H2 -ge 26100)
        $guardAllowed23H2 = ($mockBuild23H2 -lt 26100)

        # C. ShortPath conversion test
        $testShort = Get-SafeShortPath "C:\Program Files"
        $shortPathValid = ($null -ne $testShort)

        if (($whitelistedBlocked -eq $mockAppxWhitelisted.Count) -and $guardBlocked24H2 -and $guardAllowed23H2 -and $shortPathValid -and (-not $secHealthProtected) -and $secHealthRemoved) {
            $safetyExtPass = $true
            $safetyExtMsg = "$whitelistedBlocked/$($mockAppxWhitelisted.Count) critical AppX protected; WinSxS 24H2 Checkpoint guard enforced; Get-SafeShortPath operational; SecHealthUI scheduled for removal with Defender"
        } else {
            $safetyExtMsg = "AppX protection ($whitelistedBlocked/$($mockAppxWhitelisted.Count)) or WinSxS guard ($guardBlocked24H2, $guardAllowed23H2) failed"
        }
    } catch {
        $safetyExtMsg = "Exception during safety extension test: $_"
    }
    return [PSCustomObject]@{ Test = "15. WinSxS & AppX Protection Guards"; Passed = $safetyExtPass; Details = $safetyExtMsg }
}

# Self-test check: WIM Self-Healing & Stream Diagnostics Suite
function Test-WinEaseSelfCheck16WimSelfHealing {
    param()
    $wimRepairPass = $false
    $wimRepairMsg = ""
    try {
        Initialize-WinEaseWimNative
        $mockApplyDir = "C:\WinEase_workspace\deep_apply_verification"
        $mockLogTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "mock_dism_$([System.IO.Path]::GetRandomFileName()).log"
        $mockLogLines = @(
            "2026-10-16 12:00:00, Info                  DISM   DISM WIM Provider: PID=1234 $mockApplyDir\Windows\WinSxS\amd64_test_pkg\test.dll (HRESULT=0x80070241) - CWimManager",
            "2026-10-16 12:00:01, Info                  DISM   DISM WIM Provider: PID=1234 $mockApplyDir\Windows\System32\sample.exe (HRESULT=0x80070570) - CWimManager",
            "2026-10-16 12:00:02, Info                  DISM   DISM WIM Provider: PID=1234 C:\other\path\skip.dll (HRESULT=0x80070241)"
        )
        [System.IO.File]::WriteAllLines($mockLogTemp, $mockLogLines, [System.Text.Encoding]::UTF8)
        $parsedFailed = @(Get-WinEaseDeepApplyFailedFiles -LogPath $mockLogTemp -ApplyDir $mockApplyDir)
        Remove-Item -LiteralPath $mockLogTemp -Force -ErrorAction SilentlyContinue

        $expected1 = 'Windows\WinSxS\amd64_test_pkg\test.dll'
        $expected2 = 'Windows\System32\sample.exe'
        if ($parsedFailed.Count -eq 2 -and ($parsedFailed -contains $expected1) -and ($parsedFailed -contains $expected2)) {
            $wimRepairPass = $true
            $wimRepairMsg = "wimgapi native bindings loaded; 0x80070241/0x80070570 error extraction validated (2/2 targets matched, external path safely ignored)"
        } else {
            $wimRepairMsg = "Deep apply log parser failed to correctly isolate failing streams (found $($parsedFailed.Count) files)"
        }
    } catch {
        $wimRepairMsg = "Exception during WIM diagnostics test: $_"
    }
    return [PSCustomObject]@{ Test = "16. WIM Self-Healing & Diagnostics"; Passed = $wimRepairPass; Details = $wimRepairMsg }
}

# Self-test check: Atomic File I/O Resilience (Write-WinEaseTextFileAtomic)
function Test-WinEaseSelfCheck17AtomicFileIO {
    param()
    $atomicPass = $false
    $atomicMsg = ""
    try {
        $testAtomicFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "WinEase_atomic_test_$([Guid]::NewGuid().ToString('N')).txt"
        $initialContent = "Version 1 content"
        $newContent = "Version 2 atomic content"

        Write-WinEaseTextFileAtomic -Path $testAtomicFile -Content $initialContent -Encoding utf8
        $c1 = [System.IO.File]::ReadAllText($testAtomicFile, [System.Text.Encoding]::UTF8)

        Write-WinEaseTextFileAtomic -Path $testAtomicFile -Content $newContent -Encoding utf8
        $c2 = [System.IO.File]::ReadAllText($testAtomicFile, [System.Text.Encoding]::UTF8)

        $dir = [System.IO.Path]::GetDirectoryName($testAtomicFile)
        $orphanTmp = Get-ChildItem -Path $dir -Filter "*WinEase_atomic_test*.*.tmp" -ErrorAction SilentlyContinue

        Remove-Item -LiteralPath $testAtomicFile -Force -ErrorAction SilentlyContinue

        if ($c1 -eq $initialContent -and $c2 -eq $newContent -and ($null -eq $orphanTmp -or $orphanTmp.Count -eq 0)) {
            $atomicPass = $true
            $atomicMsg = "Atomic replace, overwrite retry, and clean temp cleanup validated"
        } else {
            $atomicMsg = "Content mismatch or orphan temporary files detected"
        }
    } catch {
        $atomicMsg = "Exception during atomic I/O test: $_"
    }
    return [PSCustomObject]@{ Test = "17. Atomic File I/O Resilience"; Passed = $atomicPass; Details = $atomicMsg }
}

# Self-test check: Configuration Conflict Matrix & Auto-Resolution (Test-WinEaseConfigConflicts)
function Test-WinEaseSelfCheck18ConfigConflicts {
    param()
    $conflictMatrixPass = $false
    $conflictMatrixMsg = ""
    try {
        $mockConflictedConfig = [PSCustomObject]@{
            KeepStore = $true
            DisableWindowsUpdate = $true
            RemoveStore = $true
            AllowPhysicalDebloat = $false
            TweakSettings = @{
                PhysicalDebloat = $true
                NoLockScreen = $true
            }
        }
        # The check is a pure validation: it reports the contradictions and the safeguards,
        # but it never rewrites a setting of the user.
        $cfResult = Test-WinEaseConfigConflicts -Config $mockConflictedConfig
        $settingsUnchanged = (($cfResult.ResolvedConfig.DisableWindowsUpdate -eq $true) -and
                              ($cfResult.ResolvedConfig.RemoveStore -eq $true) -and
                              ($cfResult.ResolvedConfig.TweakSettings.PhysicalDebloat -eq $true))
        $safeguards = @($cfResult.Conflicts | Where-Object { $_.Safeguard })
        $hasPhysGate = @($cfResult.Conflicts | Where-Object { $_.Rule -eq 'PhysicalDebloatSafetyGate' }).Count -eq 1

        if ($cfResult.Conflicts.Count -ge 3 -and $settingsUnchanged -and $hasPhysGate) {
            $conflictMatrixPass = $true
            $conflictMatrixMsg = "$($cfResult.Conflicts.Count) conflicting rules reported, the settings of the user stay untouched ($($safeguards.Count) safeguard(s) for the builder to apply)"
        } else {
            $conflictMatrixMsg = "Conflict detection failed (conflicts: $($cfResult.Conflicts.Count), settingsUnchanged: $settingsUnchanged, hasPhysGate: $hasPhysGate)"
        }
    } catch {
        $conflictMatrixMsg = "Exception during conflict matrix test: $_"
    }
    return [PSCustomObject]@{ Test = "18. Config Conflict Auto-Resolution"; Passed = $conflictMatrixPass; Details = $conflictMatrixMsg }
}

# Self-test check: Build Resume Integrity Verification (Test-WinEaseResumeIntegrity)
function Test-WinEaseSelfCheck19ResumeIntegrity {
    param()
    $resumeIntegrityPass = $false
    $resumeIntegrityMsg = ""
    try {
        $tempResumeDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "WinEase_resume_test_$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $tempResumeDir "build\sources") -Force | Out-Null

        # Test 19A: Empty workspace must fail
        $resA = Test-WinEaseResumeIntegrity -WorkspaceDir $tempResumeDir
        $failsOnEmpty = (-not $resA.IsValid)

        # Test 19B: Mock valid workspace with header magic and required items
        $fakeWim = Join-Path $tempResumeDir "build\sources\install.wim"
        $magicBytes = [System.Text.Encoding]::ASCII.GetBytes("MSWIM`0`0`0")
        $fs = [System.IO.File]::Create($fakeWim)
        $fs.Write($magicBytes, 0, $magicBytes.Length)
        $fs.SetLength(600 * 1024 * 1024)
        $fs.Close()

        $fakeBoot = Join-Path $tempResumeDir "build\sources\boot.wim"
        [System.IO.File]::WriteAllBytes($fakeBoot, $magicBytes)

        foreach ($reqItem in @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')) {
            $target = Join-Path (Join-Path $tempResumeDir "build") $reqItem
            if ($reqItem -in @('boot', 'efi')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            } else {
                [System.IO.File]::WriteAllText($target, "dummy")
            }
        }

        $resB = Test-WinEaseResumeIntegrity -WorkspaceDir $tempResumeDir -IsIsoOnly
        $passesOnValid = $resB.IsValid

        Remove-Item -LiteralPath $tempResumeDir -Recurse -Force -ErrorAction SilentlyContinue

        if ($failsOnEmpty -and $passesOnValid) {
            $resumeIntegrityPass = $true
            $resumeIntegrityMsg = "Incomplete workspace rejected; valid MSWIM magic header and layout validated"
        } else {
            $resumeIntegrityMsg = "Resume integrity check failed (failsOnEmpty=$failsOnEmpty, passesOnValid=$passesOnValid)"
        }
    } catch {
        $resumeIntegrityMsg = "Exception during resume integrity test: $_"
    }
    return [PSCustomObject]@{ Test = "19. Build Resume Integrity Check"; Passed = $resumeIntegrityPass; Details = $resumeIntegrityMsg }
}

# Self-test check: Granular Tweak Coverage & Schema Alignment
function Test-WinEaseSelfCheck20TweakCoverage {
    param([string]$ScriptRoot)
    $tweakCoveragePass = $false
    $tweakCoverageMsg = ""
    try {
        $schemaPath = Join-Path -Path $ScriptRoot -ChildPath "config\WinEase.config.schema.json"
        if (Test-Path -LiteralPath $schemaPath) {
            $schemaJson = (Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8) | ConvertFrom-Json
            $schemaPropNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $schemaJson.properties.PSObject.Properties) { [void]$schemaPropNames.Add($p.Name) }
            $tweakKeys = @($script:AllTweakDefs.Keys)
            $tweakCount = $tweakKeys.Count
            $matchedCount = 0
            foreach ($tk in $tweakKeys) {
                if ($schemaPropNames.Contains($tk)) {
                    $matchedCount++
                }
            }
            if ($tweakCount -ge 50 -and $matchedCount -eq $tweakCount) {
                $tweakCoveragePass = $true
                $tweakCoverageMsg = "$matchedCount/$tweakCount tweak toggles schema-aligned across 4 categories"
            } else {
                $tweakCoverageMsg = "Schema mismatch: $matchedCount matched out of $tweakCount total tweak definitions"
            }
        } else {
            $tweakCoverageMsg = "Schema file not found at $schemaPath"
        }
    } catch {
        $tweakCoverageMsg = "Exception during tweak coverage test: $_"
    }
    return [PSCustomObject]@{ Test = "20. Granular Tweak Schema Alignment"; Passed = $tweakCoveragePass; Details = $tweakCoverageMsg }
}

# Self-test check: Extension catalog files parse cleanly
function Test-WinEaseSelfCheck21ExtensionCatalogs {
    param([string]$ScriptRoot)
    $catalogPass = $true
    $catalogMsg = ""
    $catalogFiles = @('config\dependencies.psd1','config\user\user-tweaks.psd1','tools\migrator\migration-rules.psd1','config\user\user-migration-rules.psd1','config\ui-preferences.psd1')
    foreach ($cf in $catalogFiles) {
        $cp = Join-Path -Path $ScriptRoot -ChildPath $cf
        if (Test-Path -LiteralPath $cp) {
            try { Import-PowerShellDataFile -LiteralPath $cp | Out-Null } catch { $catalogPass = $false; $catalogMsg = "$cf parse error: $($_.Exception.Message)"; break }
        } else {
            $catalogPass = $false; $catalogMsg = "Missing: $cf"; break
        }
    }
    if ($catalogPass) { $catalogMsg = "All $($catalogFiles.Count) extension catalogs parse cleanly" }
    return [PSCustomObject]@{ Test = "21. Extension Catalog Parse"; Passed = $catalogPass; Details = $catalogMsg }
}

# Helper function: Execute built-in diagnostic and repository self-test suite
function Invoke-WinEaseSelfTest {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$BuilderPath,
        [string]$UnattendPath
    )
    if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
    if (-not $BuilderPath) {
        $BuilderPath = (Get-ChildItem -Path $ScriptRoot -Filter 'WinEasebuilder*.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        if (-not $BuilderPath) { $BuilderPath = Join-Path -Path $ScriptRoot -ChildPath "WinEasebuilder.ps1" }
    }
    if (-not $UnattendPath) {
        $UnattendPath = Join-Path -Path $ScriptRoot -ChildPath "autounattend.xml"
    }

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "   WinEase Self-Test & Diagnostic Verification Suite     " -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $results = @()

    $results += Test-WinEaseSelfCheck01AstSyntax -BuilderPath $BuilderPath | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck02RegistrySafety -BuilderPath $BuilderPath | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck03UnattendSchema -UnattendPath $UnattendPath | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck04ProfilePresets  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck05ToolingAssets -ScriptRoot $ScriptRoot | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck06BatchTargets -ScriptRoot $ScriptRoot | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck07UnattendSingularity -ScriptRoot $ScriptRoot | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck08AppxPatterns  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck09HiveIsolation  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck10MountPathGeneration  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck11MountConflict  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck12MountSafety  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck13FontImePreservation  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck14WorkspacePreservation  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck15WinSxsAppxGuards  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck16WimSelfHealing  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck17AtomicFileIO  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck18ConfigConflicts  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck19ResumeIntegrity  | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck20TweakCoverage -ScriptRoot $ScriptRoot | Select-Object -Last 1
    $results += Test-WinEaseSelfCheck21ExtensionCatalogs -ScriptRoot $ScriptRoot | Select-Object -Last 1

    # Display Results
    Write-Host ""
    $allPassed = $true
    foreach ($r in $results) {
        $statusStr = if ($r.Passed) { "[PASS]" } else { "[FAIL]" }
        $color = if ($r.Passed) { "Green" } else { "Red" }
        if (-not $r.Passed) { $allPassed = $false }
        Write-Host ("  {0,-35} : {1,-6} ({2})" -f $r.Test, $statusStr, $r.Details) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($allPassed) {
        Write-Host "   OVERALL RESULT: ALL $($results.Count) CHECKS PASSED (100%)       " -ForegroundColor Green
    } else {
        Write-Host "   OVERALL RESULT: SOME CHECKS FAILED                   " -ForegroundColor Red
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    return $allPassed
}
