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
                # Extraction targets are restricted to the setup scripts folder:
                # the unattend file controls both the path and the content of the
                # extracted files (which later run as SYSTEM), so a path outside
                # this folder must never be written.
                # The second root is the Winhance scripts folder: the shipped unattend embeds
                # Winhancements.ps1 there and the required-scripts check below expects it there.
                $allowedExtractRoots = @('C:\Windows\Setup\Scripts\', 'C:\ProgramData\Winhance\Unattend\Scripts\')
                foreach ($file in $fileNodes) {
                    $rawPath = $file.GetAttribute('path')
                    if (-not $rawPath) { continue }
                    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($rawPath)
                    try {
                        $targetPath = [System.IO.Path]::GetFullPath($expandedPath)
                    } catch {
                        Log-Extract "[SECURITY REFUSAL] Skipped embedded file with an unresolvable path: $rawPath"
                        continue
                    }
                    $isAllowedExtractPath = $false
                    foreach ($allowedRoot in $allowedExtractRoots) { if ($targetPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $isAllowedExtractPath = $true; break } }
                    if (-not $isAllowedExtractPath) {
                        Log-Extract "[SECURITY REFUSAL] Skipped embedded file outside the allowed folder ($($allowedExtractRoots -join ', ')): $targetPath"
                        continue
                    }
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