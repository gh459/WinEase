# WinEasePlugins.ps1 - plugin host: loads allow-listed plugin DLLs and calls them around the build phases.
# Dot-sourced by WinEasebuilder.ps1 into the builder's script scope (function definitions only).
#
#   Import-WinEasePlugins          loads the DLLs named in the two lock files (SHA256 allow list)
#   Invoke-WinEasePluginHook       calls OnPhase of every applicable plugin (Before / After a phase)
#   Get-WinEasePluginContributions the data the plugins contribute (Registry, Appx, Fod, Service, ImageFile)
#   Test-WinEasePluginLocks        -TestSelf: verifies the hashes in the lock files
#   Get-WinEasePluginInventory / Add-WinEaseUserPlugin   what the GUI shows and registers
#
# Trust model: only a DLL that is listed in plugins\builtin\builtin.lock.psd1 or
# config\user\plugins.lock.psd1 is loaded, and only when its SHA256 matches. A lock entry may
# additionally carry an optional SignerThumbprint: when present and non-empty, the DLL's
# Authenticode signature must also be valid and its signer certificate thumbprint must match
# (whitespace-insensitive, case-insensitive); entries without it are loaded on the SHA256
# alone, exactly as before. The file is read once
# as bytes; the same bytes are hashed and handed to Assembly.Load(byte[]), so the file cannot be
# swapped between the check and the load. A plugin cannot replace a phase, so the safety gates and
# the mount handling always run. Plugin code runs in the builder process with the rights of the
# builder: the allow list is what keeps unknown code out, it is not a sandbox.
# Contract: src\WinEase.Plugins.Abstractions (documented in plugins\README.md).

$script:WinEasePluginAbstractionsName = 'WinEase.Plugins.Abstractions'
$script:WinEasePluginMaxBytes = 64MB
$script:WinEasePluginHives = @('zSYSTEM', 'zSOFTWARE', 'zDEFAULT', 'zNTUSER', 'zCOMPONENTS')
$script:WinEasePluginOnErrorValues = @('Stop', 'Warn', 'Ignore')
$script:WinEasePluginContributorMap = [ordered]@{
    Registry  = @{ Interface = 'IRegistryContributor'; Method = 'GetRegistryEntries' }
    Appx      = @{ Interface = 'IAppxRemovalContributor'; Method = 'GetAppxRemovals' }
    AppxRule  = @{ Interface = 'IAppxRemovalRuleContributor'; Method = 'GetAppxRemovalRules' }
    Fod       = @{ Interface = 'IFodRemovalContributor'; Method = 'GetFodRemovals' }
    Service   = @{ Interface = 'IServiceStartContributor'; Method = 'GetServiceStarts' }
    ImageFile = @{ Interface = 'IImageFileContributor'; Method = 'GetImageFiles' }
}
$script:WinEasePluginKinds = @($script:WinEasePluginContributorMap.Keys)
if (-not (Test-Path -Path variable:script:WinEasePlugins)) { $script:WinEasePlugins = [System.Collections.Generic.List[object]]::new() }
if (-not (Test-Path -Path variable:script:WinEasePluginRejected)) { $script:WinEasePluginRejected = [System.Collections.Generic.List[object]]::new() }
if (-not (Test-Path -Path variable:script:WinEasePluginRunLog)) { $script:WinEasePluginRunLog = [System.Collections.Generic.List[object]]::new() }

function Get-WinEasePluginPaths {
    <#
    .SYNOPSIS
        The plugin folders and lock files below a repository root.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $libRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $RepoRoot = Split-Path -Parent $libRoot
    }
    return [PSCustomObject]@{
        RepoRoot    = $RepoRoot
        PluginsDir  = Join-Path -Path $RepoRoot -ChildPath 'plugins'
        BuiltinDir  = Join-Path -Path $RepoRoot -ChildPath 'plugins\builtin'
        BuiltinLock = Join-Path -Path $RepoRoot -ChildPath 'plugins\builtin\builtin.lock.psd1'
        UserDir     = Join-Path -Path $RepoRoot -ChildPath 'plugins\user'
        UserLock    = Join-Path -Path $RepoRoot -ChildPath 'config\user\plugins.lock.psd1'
        BinDir      = Join-Path -Path $RepoRoot -ChildPath 'plugins\bin'
        SourceDir   = Join-Path -Path $RepoRoot -ChildPath 'src\WinEase.Plugins.Abstractions'
    }
}

function Get-WinEaseSha256Hex {
    # Lower-case hex SHA256 of a byte array (the bytes that are hashed are the bytes that get loaded).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function New-WinEaseCSharpAssembly {
    <#
    .SYNOPSIS
        Compiles C# source (Windows PowerShell compiler, C# 5) into a DLL file without loading it.
    .DESCRIPTION
        Used to build the contract assembly from src\ when no prebuilt DLL is shipped, and by the
        tests to build plugin DLLs on the fly. Returns the output path; throws on compile errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Source,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string[]]$References = @(),
        # "<file>,<resource name>" pairs, embedded the way <EmbeddedResource LogicalName=...> does in a project
        [string[]]$Resources = @()
    )
    $provider = New-Object -TypeName Microsoft.CSharp.CSharpCodeProvider
    try {
        $options = New-Object -TypeName System.CodeDom.Compiler.CompilerParameters
        $options.GenerateExecutable = $false
        $options.GenerateInMemory = $false
        $options.OutputAssembly = $OutputPath
        # csc reads /resource:<file>[,<name>]; each part is quoted on its own because of the spaces in the names
        $resourceOptions = foreach ($resource in @($Resources | Where-Object { $_ })) {
            $split = $resource.LastIndexOf(',')
            ' /resource:"' + $resource.Substring(0, $split) + '","' + $resource.Substring($split + 1) + '"'
        }
        $options.CompilerOptions = '/optimize+' + (@($resourceOptions) -join '')
        foreach ($ref in (@('System.dll', 'System.Core.dll') + $References)) { [void]$options.ReferencedAssemblies.Add($ref) }
        $result = $provider.CompileAssemblyFromSource($options, $Source)
        if ($result.Errors.HasErrors) {
            $messages = @($result.Errors | Where-Object { -not $_.IsWarning } | ForEach-Object { "$($_.ErrorNumber) line $($_.Line): $($_.ErrorText)" })
            throw "C# compile failed: $($messages -join '; ')"
        }
    } finally {
        $provider.Dispose()
    }
    return $OutputPath
}

function Find-WinEaseLoadedAssembly {
    param([Parameter(Mandatory = $true)][string]$Name)
    return @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $Name } | Select-Object -First 1)[0]
}

function Register-WinEasePluginAssemblyResolver {
    # Plugin DLLs are loaded from bytes, so the runtime cannot find the contract assembly by itself:
    # the contract assembly installs its own (C#) AssemblyResolve handler, once per process.
    param([Parameter(Mandatory = $true)][System.Reflection.Assembly]$Abstractions)
    $resolver = $Abstractions.GetType('WinEase.Plugins.PluginAssemblyResolver', $true)
    [void]$resolver.GetMethod('Install').Invoke($null, @(, $Abstractions))
}

function Get-WinEasePluginAbstractions {
    <#
    .SYNOPSIS
        The loaded contract assembly (WinEase.Plugins.Abstractions); loads it first if needed.
    .DESCRIPTION
        Order: the assembly that is already loaded in this process; -AbstractionsPath; a prebuilt
        plugins\bin\WinEase.Plugins.Abstractions.dll; otherwise it is compiled from
        src\WinEase.Plugins.Abstractions. Plugins only bind to the name and the major version.
    #>
    [CmdletBinding()]
    param([string]$AbstractionsPath, [string]$RepoRoot)
    $loaded = Find-WinEaseLoadedAssembly -Name $script:WinEasePluginAbstractionsName
    if ($null -eq $loaded) {
        $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
        $dll = $AbstractionsPath
        if ([string]::IsNullOrWhiteSpace($dll)) {
            $prebuilt = Join-Path -Path $paths.BinDir -ChildPath "$($script:WinEasePluginAbstractionsName).dll"
            if (Test-Path -LiteralPath $prebuilt -PathType Leaf) { $dll = $prebuilt }
        }
        if ([string]::IsNullOrWhiteSpace($dll)) {
            if (-not (Test-Path -LiteralPath $paths.SourceDir -PathType Container)) {
                throw "The plugin contract assembly is missing: no plugins\bin\$($script:WinEasePluginAbstractionsName).dll and no source in src\."
            }
            $sources = @(Get-ChildItem -LiteralPath $paths.SourceDir -Filter '*.cs' -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
            $sources += '[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]'
            # The file name is the assembly name: it has to be WinEase.Plugins.Abstractions, otherwise the plugins
            # cannot bind to it and a second import compiles (and loads) another contract assembly.
            $compileDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEasePluginAbstractions_{0}" -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $compileDir | Out-Null
            $dll = Join-Path -Path $compileDir -ChildPath "$($script:WinEasePluginAbstractionsName).dll"
            try {
                [void](New-WinEaseCSharpAssembly -Source $sources -OutputPath $dll)
                $loaded = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dll))
            } finally {
                Remove-Item -LiteralPath $compileDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            $loaded = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dll))
        }
    }
    Register-WinEasePluginAssemblyResolver -Abstractions $loaded
    return $loaded
}

# --- built-in plugins ----------------------------------------------------------------------------
# The official plugins (src\WinEase.Plugins.Builtin.*) are normally built by tools\build-binaries.ps1
# (dotnet) or by CI, which also writes plugins\builtin\builtin.lock.psd1 with their SHA256. A source
# checkout has neither the DLLs nor the lock file (both are generated and not committed). Then the
# builder compiles the plugins from src\ with the C# compiler of Windows PowerShell (the sources are
# C# 5 for this reason) and writes the lock itself, so the tweaks that live in the plugins work
# without the .NET SDK. When the sources are missing too, the builder warns and those tweaks are not
# applied; it does not stop. A DLL that was built here is rebuilt when its sources are newer; a DLL
# that was shipped (any other lock entry) is never replaced.
$script:WinEaseBuiltinPluginNames = @('Latency', 'PostInstallTools', 'UpstreamSync')
$script:WinEaseBuiltinLocalBuildMarker = 'Built on this machine from src\'

function Get-WinEaseBuiltinPluginFileName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return "WinEase.Plugins.Builtin.$Name.dll"
}

function Get-WinEaseBuiltinPluginResources {
    # "<file>,<resource name>" pairs for the plugins that embed files: the same names the EmbeddedResource
    # items of the project give (PostInstallTools embeds scripts\tools).
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$RepoRoot)
    if ($Name -ne 'PostInstallTools') { return @() }
    $toolsDir = Join-Path -Path $RepoRoot -ChildPath 'scripts\tools'
    if (-not (Test-Path -LiteralPath $toolsDir -PathType Container)) { return @() }
    $root = (Get-Item -LiteralPath $toolsDir).FullName.TrimEnd('\') + '\'
    return @(Get-ChildItem -LiteralPath $toolsDir -File -Recurse | ForEach-Object {
            "$($_.FullName),tools/$($_.FullName.Substring($root.Length).Replace('\', '/'))"
        })
}

function Initialize-WinEaseBuiltinPlugins {
    <#
    .SYNOPSIS
        Builds the built-in plugins from src\ (Windows PowerShell compiler) when their DLLs are not there.
    .DESCRIPTION
        Returns the names of the plugins it built. Never throws: a plugin that cannot be built is reported
        with a warning and its tweaks are not applied.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)
    $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
    $entries = @()
    try { $entries = @(Read-WinEasePluginLock -Path $paths.BuiltinLock) } catch { Write-Verbose "Built-in lock not readable: $($_.Exception.Message)" }
    $todo = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:WinEaseBuiltinPluginNames) {
        $file = Get-WinEaseBuiltinPluginFileName -Name $name
        $entry = @($entries | Where-Object { $_.File -ieq $file })[0]
        $dll = Join-Path -Path $paths.BuiltinDir -ChildPath $file
        $srcDir = Join-Path -Path $paths.RepoRoot -ChildPath "src\WinEase.Plugins.Builtin.$name"
        $hasSource = Test-Path -LiteralPath $srcDir -PathType Container
        if ($entry -and (Test-Path -LiteralPath $dll -PathType Leaf)) {
            $stale = $false
            if ($hasSource -and [string]$entry.Description -like "$($script:WinEaseBuiltinLocalBuildMarker)*") {
                $inputs = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File)
                $inputs += @(Get-WinEaseBuiltinPluginResources -Name $name -RepoRoot $paths.RepoRoot | ForEach-Object { Get-Item -LiteralPath ($_ -split ',')[0] })
                $newest = ($inputs | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
                $stale = $null -ne $newest -and $newest -gt (Get-Item -LiteralPath $dll).LastWriteTimeUtc
            }
            if (-not $stale) { continue }
        }
        if (-not $hasSource) {
            Write-Warning "[Plugins] Built-in plugin '$name' is not available: no $file in plugins\builtin and no source in src\. Its tweaks are not applied."
            continue
        }
        $todo.Add($name)
    }
    if ($todo.Count -eq 0) { return @() }

    $built = [System.Collections.Generic.List[string]]::new()
    $work = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEaseBuiltin_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $paths.BuiltinDir | Out-Null
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        # the contract assembly the plugins reference: the prebuilt one, or compiled from src\ like the host does
        $abstractionsRef = Join-Path -Path $paths.BinDir -ChildPath "$($script:WinEasePluginAbstractionsName).dll"
        if (-not (Test-Path -LiteralPath $abstractionsRef -PathType Leaf)) {
            $abstractionsRef = Join-Path -Path $work -ChildPath "$($script:WinEasePluginAbstractionsName).dll"
            $sources = @(Get-ChildItem -LiteralPath $paths.SourceDir -Filter '*.cs' -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
            $sources += '[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]'
            [void](New-WinEaseCSharpAssembly -Source $sources -OutputPath $abstractionsRef)
        }
        foreach ($name in $todo) {
            $srcDir = Join-Path -Path $paths.RepoRoot -ChildPath "src\WinEase.Plugins.Builtin.$name"
            $out = Join-Path -Path $paths.BuiltinDir -ChildPath (Get-WinEaseBuiltinPluginFileName -Name $name)
            try {
                $sources = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File | Sort-Object -Property Name | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
                [void](New-WinEaseCSharpAssembly -Source $sources -OutputPath $out -References @($abstractionsRef) -Resources @(Get-WinEaseBuiltinPluginResources -Name $name -RepoRoot $paths.RepoRoot))
                $built.Add($name)
            } catch {
                Write-Warning "[Plugins] Built-in plugin '$name' could not be built from src\: $($_.Exception.Message) Its tweaks are not applied."
            }
        }
        if ($built.Count -gt 0) {
            $builtFiles = @($built | ForEach-Object { Get-WinEaseBuiltinPluginFileName -Name $_ })
            $lockEntries = @($entries | Where-Object { $builtFiles -notcontains $_.File })
            foreach ($name in $built) {
                $file = Get-WinEaseBuiltinPluginFileName -Name $name
                $hash = Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes((Join-Path -Path $paths.BuiltinDir -ChildPath $file)))
                $lockEntries += [PSCustomObject]@{ File = $file; Sha256 = $hash; OnError = 'Warn'; Description = "$($script:WinEaseBuiltinLocalBuildMarker)WinEase.Plugins.Builtin.$name"; Enabled = $true }
            }
            Write-WinEasePluginLock -Path $paths.BuiltinLock -Entries @($lockEntries | Sort-Object -Property File) -Header @(
                '# WinEase built-in plugin allow list (generated by tools\build-binaries.ps1, CI, or the builder when it built the plugins from src\).',
                '# A DLL in plugins\builtin is only loaded when it is listed here with its SHA256. Not committed.')
            Write-Host "  [Plugins] Built $($built.Count) built-in plugin(s) from src\ (no prebuilt DLL): $($built -join ', ')" -ForegroundColor DarkCyan
        }
    } catch {
        Write-Warning "[Plugins] The built-in plugins could not be built from src\: $($_.Exception.Message) Their tweaks are not applied."
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $built.ToArray()
}

function Read-WinEasePluginLock {
    <#
    .SYNOPSIS
        Reads a lock file (plugins.lock.psd1 format) and returns its entries; a missing file has none.
    .DESCRIPTION
        @{ Version = 1; Plugins = @( @{ File = 'x.dll'; Sha256 = '<64 hex>'; OnError = 'Warn'; Description = '' } ) }
        File is relative to the plugin folder of the lock (plugins\builtin or plugins\user).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($data.Plugins)) {
        if ($null -eq $p) { continue }
        $onError = if ($p.OnError) { [string]$p.OnError } else { 'Warn' }
        $entries.Add([PSCustomObject]@{
                File             = [string]$p.File
                Sha256           = ([string]$p.Sha256).Trim().ToLowerInvariant()
                OnError          = $onError
                Description      = [string]$p.Description
                Enabled          = if ($p.ContainsKey('Enabled')) { [bool]$p.Enabled } else { $true }
                # Optional signer pinning (see the trust model at the top of this file):
                # empty/absent means "SHA256 only", exactly as before this property existed.
                SignerThumbprint = if ($p.ContainsKey('SignerThumbprint')) { [string]$p.SignerThumbprint } else { '' }
            })
    }
    return $entries.ToArray()
}

function Resolve-WinEasePluginFile {
    # The full path of a lock entry, or $null when it would leave the plugin folder.
    param([string]$Directory, [string]$File)
    if ([string]::IsNullOrWhiteSpace($File) -or $File -match '[\\/]' -or $File -match '^\.' -or $File -notmatch '\.dll$') { return $null }
    $full = [System.IO.Path]::GetFullPath((Join-Path -Path $Directory -ChildPath $File))
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function Add-WinEasePluginRejection {
    param([string]$Source, [string]$File, [string]$Reason)
    $script:WinEasePluginRejected.Add([PSCustomObject]@{ Source = $Source; File = $File; Reason = $Reason })
    Write-Warning "[Plugins] $Source plugin '$File' was not loaded: $Reason"
}

function Import-WinEasePluginAssembly {
    # One lock entry -> loaded plugin records (a DLL can hold several plugin classes).
    param($Entry, [string]$Directory, [string]$Source, $Abstractions)
    $file = [string]$Entry.File
    $path = Resolve-WinEasePluginFile -Directory $Directory -File $file
    if (-not $path) { Add-WinEasePluginRejection $Source $file 'the file name in the lock file is not a plain .dll name'; return }
    if (-not $Entry.Enabled) { Write-Verbose "Plugin '$file' is disabled in its lock file."; return }
    if ($Entry.Sha256 -notmatch '^[0-9a-f]{64}$') { Add-WinEasePluginRejection $Source $file 'the lock entry has no valid SHA256'; return }
    if ($script:WinEasePluginOnErrorValues -notcontains $Entry.OnError) { Add-WinEasePluginRejection $Source $file "invalid OnError '$($Entry.OnError)'"; return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-WinEasePluginRejection $Source $file 'the file is listed in the lock file but does not exist'; return }
    if ((Get-Item -LiteralPath $path).Length -gt $script:WinEasePluginMaxBytes) { Add-WinEasePluginRejection $Source $file 'the file is too large'; return }

    # TOCTOU: hash the bytes that are loaded, never the file a second time.
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $actual = Get-WinEaseSha256Hex -Bytes $bytes
    if ($actual -ne $Entry.Sha256) {
        Add-WinEasePluginRejection $Source $file "SHA256 mismatch (lock file $($Entry.Sha256), file $actual)"
        return
    }

    # Optional signer pinning: only when the lock entry carries a non-empty SignerThumbprint.
    # Entries without it keep the historical behaviour (SHA256 only), so existing lock files
    # are unaffected. The hash above proves the file's identity; this additionally proves the
    # publisher, which a hash alone cannot.
    # (Entries built outside Read-WinEasePluginLock may not carry the property at all.)
    $pinnedThumbprint = ''
    if ($null -ne $Entry.PSObject.Properties['SignerThumbprint']) {
        $pinnedThumbprint = ([string]$Entry.SignerThumbprint) -replace '\s', ''
    }
    if (-not [string]::IsNullOrWhiteSpace($pinnedThumbprint)) {
        $signature = $null
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
        } catch {
            Add-WinEasePluginRejection $Source $file "the lock entry pins signer thumbprint $pinnedThumbprint but the Authenticode signature could not be read: $($_.Exception.Message)"
            return
        }
        if ($null -eq $signature -or $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            $status = if ($null -eq $signature) { 'unavailable' } else { [string]$signature.Status }
            Add-WinEasePluginRejection $Source $file "the lock entry pins signer thumbprint $pinnedThumbprint but the Authenticode signature is not valid (status: $status)"
            return
        }
        if ($null -eq $signature.SignerCertificate) {
            Add-WinEasePluginRejection $Source $file "the lock entry pins signer thumbprint $pinnedThumbprint but the signature has no signer certificate"
            return
        }
        $actualThumbprint = ([string]$signature.SignerCertificate.Thumbprint) -replace '\s', ''
        if ($actualThumbprint -ine $pinnedThumbprint) {
            Add-WinEasePluginRejection $Source $file "signer thumbprint mismatch (lock file $pinnedThumbprint, signer $actualThumbprint)"
            return
        }
    }

    $contractMajor = $Abstractions.GetName().Version.Major
    try {
        $inspect = [System.Reflection.Assembly]::ReflectionOnlyLoad($bytes)
        $ref = @($inspect.GetReferencedAssemblies() | Where-Object { $_.Name -eq $script:WinEasePluginAbstractionsName } | Select-Object -First 1)[0]
        if ($null -eq $ref) { Add-WinEasePluginRejection $Source $file 'the DLL does not reference the plugin contract'; return }
        if ($ref.Version.Major -ne $contractMajor) {
            Add-WinEasePluginRejection $Source $file "built for contract major version $($ref.Version.Major), this builder offers $contractMajor"
            return
        }
    } catch {
        Write-Verbose "Reflection-only inspection skipped for '$file': $($_.Exception.Message)"
    }

    try {
        $assembly = [System.Reflection.Assembly]::Load($bytes)
    } catch {
        Add-WinEasePluginRejection $Source $file "the assembly could not be loaded: $($_.Exception.Message)"
        return
    }
    $ref = @($assembly.GetReferencedAssemblies() | Where-Object { $_.Name -eq $script:WinEasePluginAbstractionsName } | Select-Object -First 1)[0]
    if ($null -ne $ref -and $ref.Version.Major -ne $contractMajor) {
        Add-WinEasePluginRejection $Source $file "built for contract major version $($ref.Version.Major), this builder offers $contractMajor"
        return
    }
    $pluginInterface = $Abstractions.GetType('WinEase.Plugins.IWinEasePlugin')
    $types = @()
    try {
        $types = @($assembly.GetTypes())
    } catch [System.Reflection.ReflectionTypeLoadException] {
        $types = @($_.Exception.Types | Where-Object { $null -ne $_ })
    }
    $found = 0
    foreach ($type in $types) {
        if (-not $type.IsClass -or $type.IsAbstract -or -not $type.IsPublic) { continue }
        if (-not $pluginInterface.IsAssignableFrom($type)) { continue }
        $found++
        try {
            $instance = [System.Activator]::CreateInstance($type)
            $description = $instance.Describe()
            if ($description -and @($description.ReplacesPhases).Count -gt 0) {
                Add-WinEasePluginRejection $Source $file "plugin '$($instance.Id)' asks to replace phase(s) $(@($description.ReplacesPhases) -join ', '); phases cannot be replaced"
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$instance.Id)) { Add-WinEasePluginRejection $Source $file "class '$($type.FullName)' has no Id"; continue }
            if (@($script:WinEasePlugins | Where-Object { $_.Id -eq [string]$instance.Id }).Count -gt 0) {
                Add-WinEasePluginRejection $Source $file "a plugin with the Id '$($instance.Id)' is already loaded"
                continue
            }
            $contributes = @($script:WinEasePluginContributorMap.Keys | Where-Object {
                    $iface = $Abstractions.GetType("WinEase.Plugins.$($script:WinEasePluginContributorMap[$_].Interface)")
                    $iface.IsAssignableFrom($type)
                })
            $script:WinEasePlugins.Add([PSCustomObject]@{
                    Id            = [string]$instance.Id
                    Version       = [string]$instance.Version
                    File          = $file
                    Source        = $Source
                    Sha256        = $actual
                    OnError       = $Entry.OnError
                    Instance      = $instance
                    Description   = $description
                    Contributions = $contributes
                })
            Write-Host "  [Plugins] Loaded $($instance.Id) $($instance.Version) ($Source, $file, SHA256 $($actual.Substring(0, 12))...)" -ForegroundColor DarkCyan
        } catch {
            Add-WinEasePluginRejection $Source $file "class '$($type.FullName)' failed to start: $($_.Exception.Message)"
        }
    }
    if ($found -eq 0) { Add-WinEasePluginRejection $Source $file 'the DLL has no public class that implements IWinEasePlugin' }
}

function Import-WinEasePlugins {
    <#
    .SYNOPSIS
        Loads the plugin DLLs named in plugins\builtin\builtin.lock.psd1 and config\user\plugins.lock.psd1.
    .DESCRIPTION
        A DLL that is not in a lock file, whose SHA256 differs, or that was built for another major
        version of the contract is reported with a warning and not loaded. Never throws for a bad
        plugin: the build goes on without it. Returns a summary object.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$BuiltinLockPath,
        [string]$UserLockPath,
        [string]$BuiltinDir,
        [string]$UserDir,
        [string]$AbstractionsPath,
        # Do not build missing built-in plugins from src\ (see Initialize-WinEaseBuiltinPlugins)
        [switch]$NoBuiltinBuild
    )
    $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
    # Only the real plugin folder is completed; a caller that names its own lock file or folder (tests) gets exactly that.
    if (-not $NoBuiltinBuild -and -not $BuiltinLockPath -and -not $BuiltinDir) {
        [void](Initialize-WinEaseBuiltinPlugins -RepoRoot $paths.RepoRoot)
    }
    if (-not $BuiltinLockPath) { $BuiltinLockPath = $paths.BuiltinLock }
    if (-not $UserLockPath) { $UserLockPath = $paths.UserLock }
    if (-not $BuiltinDir) { $BuiltinDir = $paths.BuiltinDir }
    if (-not $UserDir) { $UserDir = $paths.UserDir }
    $script:WinEasePlugins = [System.Collections.Generic.List[object]]::new()
    $script:WinEasePluginRejected = [System.Collections.Generic.List[object]]::new()
    $script:WinEasePluginRunLog = [System.Collections.Generic.List[object]]::new()

    $work = @()
    foreach ($set in @(
            @{ Source = 'Builtin'; Lock = $BuiltinLockPath; Dir = $BuiltinDir },
            @{ Source = 'User'; Lock = $UserLockPath; Dir = $UserDir })) {
        $entries = @()
        try { $entries = @(Read-WinEasePluginLock -Path $set.Lock) } catch { Add-WinEasePluginRejection $set.Source (Split-Path -Leaf $set.Lock) "the lock file could not be read: $($_.Exception.Message)" }
        foreach ($e in $entries) { $work += , @{ Entry = $e; Dir = $set.Dir; Source = $set.Source } }
        # DLLs next to the lock that it does not list are never loaded; say so.
        if (Test-Path -LiteralPath $set.Dir -PathType Container) {
            $listed = @($entries | ForEach-Object { $_.File.ToLowerInvariant() })
            foreach ($dll in @(Get-ChildItem -LiteralPath $set.Dir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
                if ($listed -notcontains $dll.Name.ToLowerInvariant()) {
                    Add-WinEasePluginRejection $set.Source $dll.Name 'the DLL is not in the lock file (allow list)'
                }
            }
        }
    }
    if ($work.Count -gt 0) {
        try {
            $abstractions = Get-WinEasePluginAbstractions -AbstractionsPath $AbstractionsPath -RepoRoot $paths.RepoRoot
            foreach ($w in $work) { Import-WinEasePluginAssembly -Entry $w.Entry -Directory $w.Dir -Source $w.Source -Abstractions $abstractions }
        } catch {
            Add-WinEasePluginRejection 'Host' 'WinEase.Plugins.Abstractions' "the contract assembly is not available: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        LoadedCount   = $script:WinEasePlugins.Count
        RejectedCount = $script:WinEasePluginRejected.Count
        Loaded        = @($script:WinEasePlugins | ForEach-Object { $_.Id })
        Rejected      = @($script:WinEasePluginRejected)
    }
}

function Get-WinEaseLoadedPlugins {
    # Loaded plugins as plain rows (report, diagnostics, GUI); the plugin instance is left out.
    [CmdletBinding()]
    param()
    return @($script:WinEasePlugins | ForEach-Object {
            [PSCustomObject]@{
                Id = $_.Id; Version = $_.Version; Source = $_.Source; File = $_.File; Sha256 = $_.Sha256
                OnError = $_.OnError; Summary = [string]$_.Description.Summary
                MinBuild = [int]$_.Description.MinBuild; MaxBuild = [int]$_.Description.MaxBuild
                Phases = @($_.Description.Phases); Tweaks = @($_.Description.Tweaks); Contributions = @($_.Contributions)
            }
        })
}

function Get-WinEasePluginImageInfo {
    <#
    .SYNOPSIS
        The ImageInfo object plugins get: build, UBR, edition, architecture of the image being built.
    .DESCRIPTION
        Values come from what the builder knows at this point (build from phase 10, otherwise from
        the DISM image info read in phase 4); unknown values are 0 / empty.
    #>
    [CmdletBinding()]
    param([int]$Build = -1, [int]$Ubr = -1, [string]$Edition, [string]$Architecture)
    if ($Build -lt 0) {
        $Build = 0
        if ($null -ne $script:WinEaseTargetBuild) { [void][int]::TryParse([string]$script:WinEaseTargetBuild, [ref]$Build) }
        $wimText = if ($null -ne $script:imageInfo) { (@($script:imageInfo) -join "`n") } else { '' }
        if ($Build -le 0 -and $wimText -match 'Version\s*:\s*\d+\.\d+\.(\d+)') { $Build = [int]$Matches[1] }
    }
    if ($Ubr -lt 0) {
        $Ubr = 0
        $wimText = if ($null -ne $script:imageInfo) { (@($script:imageInfo) -join "`n") } else { '' }
        if ($wimText -match 'ServicePack Build\s*:\s*(\d+)') { $Ubr = [int]$Matches[1] }
    }
    if (-not $Edition -and $null -ne $script:targetEditionName) { $Edition = [string]$script:targetEditionName }
    if (-not $Architecture -and $null -ne $script:architecture) { $Architecture = [string]$script:architecture }
    return New-Object -TypeName WinEase.Plugins.ImageInfo -ArgumentList ([int]$Build), ([int]$Ubr), ([string]$Edition), ([string]$Architecture)
}

function New-WinEasePluginHost {
    <#
    .SYNOPSIS
        Creates the IWinEaseHost one plugin gets. Its services call the builder's own functions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PluginId,
        [string]$ScratchDir = '',
        [string]$WinEaseDir = '',
        $ImageInfo,
        [switch]$DryRun
    )
    if ($null -eq $ImageInfo) { $ImageInfo = Get-WinEasePluginImageInfo }
    $hostObject = New-Object -TypeName WinEase.Plugins.DelegateWinEaseHost -ArgumentList $ScratchDir, $WinEaseDir, $ImageInfo, ([bool]$DryRun)
    $hives = $script:WinEasePluginHives
    $logPrefix = "[Plugin $PluginId]"
    # The delegates are closures (they run in a dynamic module, which cannot see the functions of the
    # builder's script scope), so the commands they need are captured here as command objects.
    $regCommand = Get-Command -Name Invoke-WinEaseReg -ErrorAction SilentlyContinue
    $tweakCommand = Get-Command -Name Test-TweakEnabled -ErrorAction SilentlyContinue
    $dismVerbs = @('/Get-ProvisionedAppxPackages', '/Remove-ProvisionedAppxPackage', '/Get-Packages', '/Get-PackageInfo', '/Remove-Package',
        '/Get-Capabilities', '/Get-CapabilityInfo', '/Remove-Capability', '/Get-Features', '/Get-FeatureInfo', '/Disable-Feature', '/Enable-Feature', '/Get-Intl')

    $hostObject.LogAction = [System.Action[WinEase.Plugins.LogLevel, string]]({
            param($level, $message)
            $color = switch ([string]$level) { 'Error' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
            Write-Host "  $logPrefix $message" -ForegroundColor $color
        }.GetNewClosure())
    $hostObject.IsTweakEnabledFunc = [System.Func[string, bool, bool]]({
            param($key, $default)
            if ($tweakCommand) { return [bool](& $tweakCommand $key $default) }
            return [bool]$default
        }.GetNewClosure())
    $settings = Get-WinEasePluginSettingSnapshot
    $hostObject.IsComponentEnabledFunc = [System.Func[string, bool, bool]]({
            param($key, $default)
            if ($settings.Components.ContainsKey($key)) { return [bool]$settings.Components[$key] }
            return [bool]$default
        }.GetNewClosure())
    $hostObject.IsTweakGroupEnabledFunc = [System.Func[string, bool, bool]]({
            param($group, $default)
            if ($settings.Groups.ContainsKey($group)) { return [bool]$settings.Groups[$group] }
            return [bool]$default
        }.GetNewClosure())
    $hostObject.SetOfflineRegistryAction = [System.Action[string, string, string, string, string]]({
            param($hive, $path, $name, $type, $data)
            if ($hives -notcontains $hive) { throw "Registry hive '$hive' is not allowed (use one of $($hives -join ', '))." }
            if ($type -notmatch '^REG_(SZ|EXPAND_SZ|DWORD|QWORD|BINARY|MULTI_SZ)$') { throw "Registry type '$type' is not supported." }
            if (-not $regCommand) { throw 'Offline registry access is not available.' }
            $key = "HKLM\$hive\$path"
            $regData = @{}
            if ($data -ne '') { $regData.Data = [string]$data } elseif ($type -in @('REG_SZ', 'REG_EXPAND_SZ')) { $regData.Data = '""' }
            if ([string]::IsNullOrEmpty($name) -or $name -eq '(default)') {
                & $regCommand -Action Add -Key $key -DefaultValue -Type $type @regData
            } else {
                & $regCommand -Action Add -Key $key -Name $name -Type $type @regData
            }
        }.GetNewClosure())
    $hostObject.RunDismFunc = [System.Func[[string[]], WinEase.Plugins.DismResult]]({
            param($dismArgs)
            if (-not $ScratchDir) { throw 'No image is mounted.' }
            $verb = @($dismArgs | Where-Object { $_ -like '/*' } | Select-Object -First 1)[0]
            if ($dismVerbs -notcontains $verb) { throw "DISM verb '$verb' is not allowed for plugins." }
            foreach ($a in $dismArgs) {
                if ($a -match '^/(Image|Online|Mount|Unmount|WimFile|Commit|Apply|Capture|Export)') { throw "DISM argument '$a' is not allowed for plugins." }
            }
            $output = & dism.exe /English "/Image:$ScratchDir" @dismArgs 2>&1
            return (New-Object -TypeName WinEase.Plugins.DismResult -ArgumentList ([int]$LASTEXITCODE), ((@($output) | Out-String).Trim()))
        }.GetNewClosure())
    $hostObject.WriteImageFileAction = [System.Action[string, [byte[]]]]({
            param($relativePath, $content)
            if (-not $ScratchDir) { throw 'No image is mounted.' }
            [WinEase.Plugins.DelegateWinEaseHost]::CheckRelativePath($relativePath)
            $base = [System.IO.Path]::GetFullPath((Join-Path -Path $ScratchDir -ChildPath "Windows\Setup\Scripts\Plugins\$PluginId")).TrimEnd('\') + '\'
            $target = [System.IO.Path]::GetFullPath((Join-Path -Path $base -ChildPath $relativePath))
            if (-not $target.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { throw "The path leaves the plugin folder: $relativePath" }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllBytes($target, $content)
        }.GetNewClosure())
    $hostObject.WriteImageFileToRootAction = [System.Action[WinEase.Plugins.ImageFileRoot, string, [byte[]]]]({
            param($root, $relativePath, $content)
            if (-not $ScratchDir) { throw 'No image is mounted.' }
            [WinEase.Plugins.DelegateWinEaseHost]::CheckRelativePath($relativePath)
            # a plugin names one of the fixed roots, never a folder
            $rootRelative = switch ([string]$root) {
                'SetupTools' { 'Windows\Setup\Tools' }
                default { throw "Image file root '$root' is not supported." }
            }
            $base = [System.IO.Path]::GetFullPath((Join-Path -Path $ScratchDir -ChildPath $rootRelative)).TrimEnd('\') + '\'
            $target = [System.IO.Path]::GetFullPath((Join-Path -Path $base -ChildPath $relativePath))
            if (-not $target.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { throw "The path leaves the folder: $relativePath" }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllBytes($target, $content)
        }.GetNewClosure())
    return $hostObject
}

function Get-WinEasePluginComponentDefs {
    # The component settings of config\schema.psd1: the builder's copy, else the file of the repository.
    [CmdletBinding()]
    param()
    if ($null -ne $script:WinEaseSettingsDef -and $script:WinEaseSettingsDef.Components) { return @($script:WinEaseSettingsDef.Components) }
    if ($null -eq $script:WinEasePluginSchemaComponents) {
        $schemaPath = Join-Path -Path (Get-WinEasePluginPaths).RepoRoot -ChildPath 'config\schema.psd1'
        $script:WinEasePluginSchemaComponents = if (Test-Path -LiteralPath $schemaPath -PathType Leaf) { @((Import-PowerShellDataFile -LiteralPath $schemaPath).Components) } else { @() }
    }
    return @($script:WinEasePluginSchemaComponents)
}

function Get-WinEasePluginSettingSnapshot {
    <#
    .SYNOPSIS
        The values of the component settings (by schema key) and the tweak groups at this moment.
    .DESCRIPTION
        The component variables of the builder ($mmcssGaming, $atlasReviOSMode, ...) are read here, in the
        scope of the caller, because the delegates of a plugin host run in a module scope that cannot see them.
        A component whose variable is not set is left out; IsComponentEnabled then answers with the default.
    #>
    [CmdletBinding()]
    param()
    $wePluginComponentValues = @{}
    foreach ($wePluginDef in @(Get-WinEasePluginComponentDefs)) {
        if (-not $wePluginDef -or -not $wePluginDef.Variable -or [string]$wePluginDef.Type -ne 'Bool') { continue }
        $wePluginValue = Get-Variable -Name ([string]$wePluginDef.Variable) -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $wePluginValue) { $wePluginComponentValues[[string]$wePluginDef.Key] = [bool]$wePluginValue }
    }
    $wePluginGroupValues = @{}
    if ($null -ne $script:activeTweakGroups) {
        foreach ($wePluginGroup in @($script:activeTweakGroups.Keys)) { $wePluginGroupValues[[string]$wePluginGroup] = [bool]$script:activeTweakGroups[$wePluginGroup] }
    }
    return @{ Components = $wePluginComponentValues; Groups = $wePluginGroupValues }
}

function Test-WinEasePluginSetting {
    # The value of the setting that gates plugin data: a component of config\schema.psd1 when the key names
    # one, otherwise a tweak (Test-TweakEnabled, which also reads aliases and profiles).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key, [bool]$Default = $false, $Snapshot)
    if ($null -eq $Snapshot) { $Snapshot = Get-WinEasePluginSettingSnapshot }
    if ($Snapshot.Components.ContainsKey($Key)) { return [bool]$Snapshot.Components[$Key] }
    $tweakCommand = Get-Command -Name Test-TweakEnabled -ErrorAction SilentlyContinue
    if ($tweakCommand) { return [bool](& $tweakCommand $Key $Default) }
    return $Default
}

function Test-WinEasePluginApplies {
    # Build range from Describe() (ignored while the build is unknown), then AppliesTo(ImageInfo).
    param($Plugin, $ImageInfo)
    $d = $Plugin.Description
    $build = [int]$ImageInfo.Build
    if ($build -gt 0) {
        if ($d.MinBuild -gt 0 -and $build -lt $d.MinBuild) { return $false }
        if ($d.MaxBuild -gt 0 -and $build -gt $d.MaxBuild) { return $false }
    }
    return [bool]$Plugin.Instance.AppliesTo($ImageInfo)
}

function Resolve-WinEasePluginFailure {
    # OnError of the lock entry: Stop ends the build, Warn reports, Ignore is silent (same meaning as custom scripts).
    param($Plugin, [string]$Where, $ErrorRecord)
    $message = "Plugin '$($Plugin.Id)' failed in $Where`: $($ErrorRecord.Exception.Message)"
    switch ($Plugin.OnError) {
        'Stop' { throw $message }
        'Ignore' { Write-Verbose $message }
        default { Write-Warning "[Plugins] $message" }
    }
}

function Invoke-WinEasePluginHook {
    <#
    .SYNOPSIS
        Calls OnPhase of every loaded, applicable plugin for one phase and stage.
    .DESCRIPTION
        Order: Before -> (the phase script) -> After, plugins in load order (builtin before user).
        A plugin that does not apply to the image, or that listed other phases in Describe(), is
        skipped. With -DryRun the host a plugin gets records its write operations and does nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('Before', 'After')][string]$Stage,
        [string]$ScratchDir,
        [string]$WinEaseDir,
        [switch]$DryRun
    )
    if ($script:WinEasePlugins.Count -eq 0) { return }
    if (-not $PSBoundParameters.ContainsKey('ScratchDir') -and $null -ne $script:scratchDir) { $ScratchDir = [string]$script:scratchDir }
    if (-not $PSBoundParameters.ContainsKey('WinEaseDir') -and $null -ne $script:WinEaseDir) { $WinEaseDir = [string]$script:WinEaseDir }
    $image = Get-WinEasePluginImageInfo
    foreach ($plugin in @($script:WinEasePlugins)) {
        $phases = @($plugin.Description.Phases | Where-Object { $_ })
        if ($phases.Count -gt 0 -and $phases -notcontains $Phase) { continue }
        $status = 'Ran'
        try {
            if (-not (Test-WinEasePluginApplies -Plugin $plugin -ImageInfo $image)) {
                $script:WinEasePluginRunLog.Add([PSCustomObject]@{ Plugin = $plugin.Id; Phase = $Phase; Stage = $Stage; Status = 'Skipped' })
                continue
            }
            $pluginHost = New-WinEasePluginHost -PluginId $plugin.Id -ScratchDir $ScratchDir -WinEaseDir $WinEaseDir -ImageInfo $image -DryRun:$DryRun
            $stageValue = [System.Enum]::Parse([WinEase.Plugins.PhaseStage], $Stage)
            $context = New-Object -TypeName WinEase.Plugins.PhaseContext -ArgumentList $Phase, $stageValue, $pluginHost
            $plugin.Instance.OnPhase($context)
        } catch {
            $status = 'Failed'
            $script:WinEasePluginRunLog.Add([PSCustomObject]@{ Plugin = $plugin.Id; Phase = $Phase; Stage = $Stage; Status = $status })
            Resolve-WinEasePluginFailure -Plugin $plugin -Where "$Phase ($Stage)" -ErrorRecord $_
            continue
        }
        $script:WinEasePluginRunLog.Add([PSCustomObject]@{ Plugin = $plugin.Id; Phase = $Phase; Stage = $Stage; Status = $status })
    }
}

function Get-WinEasePluginContributions {
    <#
    .SYNOPSIS
        The data loaded, applicable plugins contribute: Registry, Appx, Fod, Service or ImageFile.
    .DESCRIPTION
        Registry entries come back as hashtables in the shape of the config\registry tables, so
        Invoke-WinEaseRegistryTable can run them. Entries with an invalid hive, type or path are
        dropped with a warning. Each result carries the PluginId.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Registry', 'Appx', 'AppxRule', 'Fod', 'Service', 'ImageFile')][string]$Kind)
    $map = $script:WinEasePluginContributorMap[$Kind]
    $results = [System.Collections.Generic.List[object]]::new()
    if ($script:WinEasePlugins.Count -eq 0) { return @() }
    $image = Get-WinEasePluginImageInfo
    foreach ($plugin in @($script:WinEasePlugins)) {
        $iface = $plugin.Instance.GetType().GetInterface("WinEase.Plugins.$($map.Interface)")
        if ($null -eq $iface) { continue }
        try {
            if (-not (Test-WinEasePluginApplies -Plugin $plugin -ImageInfo $image)) { continue }
            $items = @($plugin.Instance.($map.Method)($image))
        } catch {
            Resolve-WinEasePluginFailure -Plugin $plugin -Where "$($map.Method)" -ErrorRecord $_
            continue
        }
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            switch ($Kind) {
                'Registry' {
                    $problem = $null
                    if ($script:WinEasePluginHives -notcontains [string]$item.Hive) { $problem = "hive '$($item.Hive)' is not one of $($script:WinEasePluginHives -join ', ')" }
                    elseif ([string]::IsNullOrWhiteSpace([string]$item.Path) -or ([string]$item.Path).StartsWith('\')) { $problem = "path '$($item.Path)' is empty or rooted" }
                    elseif ([string]$item.Type -notmatch '^REG_(SZ|EXPAND_SZ|DWORD|QWORD|BINARY|MULTI_SZ)$') { $problem = "type '$($item.Type)' is not supported" }
                    if ($problem) { Write-Warning "[Plugins] $($plugin.Id): registry entry dropped, $problem."; continue }
                    $results.Add(@{
                            PluginId = $plugin.Id; Tweak = [string]$item.Tweak; Default = [bool]$item.Default; Hive = [string]$item.Hive
                            Path = [string]$item.Path; Name = [string]$item.Name; Type = [string]$item.Type; Data = [string]$item.Data
                            MinBuild = [int]$item.MinBuild; MaxBuild = [int]$item.MaxBuild
                        })
                }
                'Appx' {
                    if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
                    $results.Add([PSCustomObject]@{ PluginId = $plugin.Id; Pattern = [string]$item })
                }
                'AppxRule' {
                    if ([string]::IsNullOrWhiteSpace([string]$item.Pattern)) { continue }
                    # the shape of the AppxRemoval definitions of config\schema.psd1 (Get-WinEaseAppxRemovalPatterns)
                    $results.Add(@{ PluginId = $plugin.Id; Pattern = [string]$item.Pattern; Option = [string]$item.Option; Invert = [bool]$item.Invert })
                }
                'Fod' {
                    if ([string]::IsNullOrWhiteSpace([string]$item.Name) -or @('Package', 'Capability', 'Feature') -notcontains [string]$item.Kind) {
                        Write-Warning "[Plugins] $($plugin.Id): FoD removal '$($item.Kind) $($item.Name)' dropped."
                        continue
                    }
                    $results.Add([PSCustomObject]@{ PluginId = $plugin.Id; Kind = [string]$item.Kind; Name = [string]$item.Name })
                }
                'Service' {
                    if ([string]::IsNullOrWhiteSpace([string]$item.Name) -or [string]$item.Name -notmatch '^[A-Za-z0-9_.\-]+$' -or [int]$item.Start -lt 0 -or [int]$item.Start -gt 4) {
                        Write-Warning "[Plugins] $($plugin.Id): service start '$($item.Name)' dropped."
                        continue
                    }
                    $results.Add([PSCustomObject]@{ PluginId = $plugin.Id; Name = [string]$item.Name; Start = [int]$item.Start })
                }
                'ImageFile' {
                    try { [WinEase.Plugins.DelegateWinEaseHost]::CheckRelativePath([string]$item.RelativePath) } catch {
                        Write-Warning "[Plugins] $($plugin.Id): image file '$($item.RelativePath)' dropped: $($_.Exception.Message)"
                        continue
                    }
                    $results.Add([PSCustomObject]@{
                            PluginId = $plugin.Id; RelativePath = [string]$item.RelativePath; Content = [byte[]]$item.Content
                            Root = [string]$item.Root; Setting = [string]$item.Setting
                            SettingDefault = [bool]$item.SettingDefault; WhenEnabled = [bool]$item.WhenEnabled
                        })
                }
            }
        }
    }
    return $results.ToArray()
}

function Invoke-WinEasePluginImageFiles {
    <#
    .SYNOPSIS
        Phase 11: writes the files IImageFileContributor plugins hand over below Windows\Setup\Scripts\Plugins\<id>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScratchDir, [switch]$DryRun)
    $snapshot = Get-WinEasePluginSettingSnapshot
    foreach ($file in @(Get-WinEasePluginContributions -Kind ImageFile)) {
        # A file that names a setting is only written while the setting has the value the file asks for.
        if ($file.Setting -and ((Test-WinEasePluginSetting -Key $file.Setting -Default $file.SettingDefault -Snapshot $snapshot) -ne $file.WhenEnabled)) { continue }
        $pluginHost = New-WinEasePluginHost -PluginId $file.PluginId -ScratchDir $ScratchDir -DryRun:$DryRun
        try {
            $root = [System.Enum]::Parse([WinEase.Plugins.ImageFileRoot], $(if ($file.Root) { $file.Root } else { 'PluginFolder' }))
            $pluginHost.WriteImageFile($root, $file.RelativePath, $file.Content)
        } catch {
            $plugin = @($script:WinEasePlugins | Where-Object { $_.Id -eq $file.PluginId })[0]
            Resolve-WinEasePluginFailure -Plugin $plugin -Where "image file $($file.RelativePath)" -ErrorRecord $_
        }
    }
}

function Get-WinEasePluginAppxPatterns {
    <#
    .SYNOPSIS
        The AppX patterns plugins contribute for the current settings (phase 05-appx).
    .DESCRIPTION
        IAppxRemovalContributor patterns are always removed (the plugin decides); the patterns of
        IAppxRemovalRuleContributor follow the rules of AppxRemoval in config\schema.psd1
        (Get-WinEaseAppxRemovalPatterns): Option, Invert and RemoveAppxBloatware decide. The caller still
        runs the protection whitelist over the result.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([hashtable]$Settings = @{})
    $patterns = @()
    foreach ($appx in @(Get-WinEasePluginContributions -Kind Appx)) { $patterns += [string]$appx.Pattern }
    $rules = @(Get-WinEasePluginContributions -Kind AppxRule)
    if ($rules.Count -gt 0 -and (Get-Command -Name Get-WinEaseAppxRemovalPatterns -ErrorAction SilentlyContinue)) {
        $patterns += @(Get-WinEaseAppxRemovalPatterns -Settings $Settings -Definitions $rules)
    }
    return @($patterns | Select-Object -Unique)
}

function Test-WinEasePluginLocks {
    <#
    .SYNOPSIS
        -TestSelf: checks every lock entry against the file on disk. Returns one row per entry.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)
    $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($set in @(@{ Source = 'Builtin'; Lock = $paths.BuiltinLock; Dir = $paths.BuiltinDir }, @{ Source = 'User'; Lock = $paths.UserLock; Dir = $paths.UserDir })) {
        $entries = @()
        try { $entries = @(Read-WinEasePluginLock -Path $set.Lock) } catch {
            $rows.Add([PSCustomObject]@{ Source = $set.Source; File = (Split-Path -Leaf $set.Lock); Status = 'LockUnreadable'; Detail = $_.Exception.Message })
            continue
        }
        foreach ($entry in $entries) {
            $path = Resolve-WinEasePluginFile -Directory $set.Dir -File $entry.File
            $status = 'Ok'
            $detail = ''
            if (-not $path) { $status = 'BadName'; $detail = 'not a plain .dll file name' }
            elseif ($entry.Sha256 -notmatch '^[0-9a-f]{64}$') { $status = 'BadHash'; $detail = 'the lock entry has no valid SHA256' }
            elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $status = 'Missing'; $detail = 'file not found' }
            else {
                $actual = Get-WinEaseSha256Hex -Bytes ([System.IO.File]::ReadAllBytes($path))
                if ($actual -ne $entry.Sha256) { $status = 'Mismatch'; $detail = "expected $($entry.Sha256), file has $actual" }
            }
            $rows.Add([PSCustomObject]@{ Source = $set.Source; File = $entry.File; Status = $status; Detail = $detail })
        }
    }
    return $rows.ToArray()
}

function Get-WinEasePluginFileInfo {
    <#
    .SYNOPSIS
        Name, size and SHA256 of a DLL the user picked (what the GUI shows before the user confirms).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [PSCustomObject]@{ Path = $Path; Name = (Split-Path -Leaf $Path); Size = $bytes.Length; Sha256 = (Get-WinEaseSha256Hex -Bytes $bytes) }
}

function Get-WinEasePluginInventory {
    <#
    .SYNOPSIS
        The lock entries of both lock files with the state of their files (nothing is loaded).
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)
    $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
    $checks = @(Test-WinEasePluginLocks -RepoRoot $paths.RepoRoot)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($set in @(@{ Source = 'Builtin'; Lock = $paths.BuiltinLock }, @{ Source = 'User'; Lock = $paths.UserLock })) {
        foreach ($entry in @(Read-WinEasePluginLock -Path $set.Lock)) {
            $check = @($checks | Where-Object { $_.Source -eq $set.Source -and $_.File -eq $entry.File })[0]
            $loaded = @($script:WinEasePlugins | Where-Object { $_.Source -eq $set.Source -and $_.File -eq $entry.File })[0]
            $rows.Add([PSCustomObject]@{
                    Source = $set.Source; File = $entry.File; Sha256 = $entry.Sha256; OnError = $entry.OnError
                    Description = $entry.Description; Enabled = $entry.Enabled
                    Status = if ($check) { $check.Status } else { 'Unknown' }
                    Id = if ($loaded) { $loaded.Id } else { '' }; Version = if ($loaded) { $loaded.Version } else { '' }
                })
        }
    }
    return $rows.ToArray()
}

function Add-WinEaseUserPlugin {
    <#
    .SYNOPSIS
        Registers a DLL the user confirmed: copies it to plugins\user and adds it to config\user\plugins.lock.psd1.
    .DESCRIPTION
        -ExpectedSha256 is the hash the user was shown and confirmed. The file is read once; if its
        hash differs from the confirmed one nothing is written. The copy in plugins\user is the one
        that is hashed again and loaded at build time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [ValidateSet('Stop', 'Warn', 'Ignore')][string]$OnError = 'Warn',
        [string]$Description = '',
        [string]$RepoRoot
    )
    $paths = Get-WinEasePluginPaths -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $name = Split-Path -Leaf $Path
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*\.dll$') { throw "Unsupported plugin file name '$name' (letters, digits, '_', '.', '-' and a .dll extension)." }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hash = Get-WinEaseSha256Hex -Bytes $bytes
    if ($hash -ne $ExpectedSha256.Trim().ToLowerInvariant()) { throw "The file changed after the hash was shown (expected $ExpectedSha256, file has $hash). Nothing was registered." }
    $existing = @(Read-WinEasePluginLock -Path $paths.UserLock)
    if ($existing | Where-Object { $_.File -ieq $name -and $_.Sha256 -ne $hash }) { throw "A different '$name' is already registered. Remove it first." }
    if (-not (Test-Path -LiteralPath $paths.UserDir)) { New-Item -ItemType Directory -Force -Path $paths.UserDir | Out-Null }
    $target = Join-Path -Path $paths.UserDir -ChildPath $name
    [System.IO.File]::WriteAllBytes($target, $bytes)
    $entries = @($existing | Where-Object { $_.File -ine $name })
    $entries += [PSCustomObject]@{ File = $name; Sha256 = $hash; OnError = $OnError; Description = $Description; Enabled = $true }
    Write-WinEasePluginLock -Path $paths.UserLock -Entries $entries
    return [PSCustomObject]@{ File = $name; Sha256 = $hash; OnError = $OnError; Target = $target }
}

function Write-WinEasePluginLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [string[]]$Header
    )
    $q = { param([string]$s) "'" + ($s -replace "'", "''") + "'" }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Header) {
        $Header = @('# WinEase user plugin allow list. A DLL in plugins\user is only loaded when it is listed here with its SHA256.',
            '# Managed by the GUI (plugins.addUser); edit by hand only if you know the hash of the file.')
    }
    foreach ($headerLine in $Header) { $lines.Add($headerLine) }
    $lines.Add('@{')
    $lines.Add('    Version = 1')
    $lines.Add('    Plugins = @(')
    foreach ($e in $Entries) {
        $enabled = if ($e.Enabled) { '$true' } else { '$false' }
        $lines.Add("        @{ File = $(& $q $e.File); Sha256 = $(& $q $e.Sha256); OnError = $(& $q $e.OnError); Enabled = $enabled; Description = $(& $q $e.Description) }")
    }
    $lines.Add('    )')
    $lines.Add('}')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $temp = "$Path.tmp"
    [System.IO.File]::WriteAllText($temp, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
