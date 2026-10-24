# WinEase plugins

A plugin is a .NET DLL that the builder calls **before and after a build phase**, and that can hand the
builder data (registry values, AppX / FoD removals, service start types, files for the image). It is the
way to follow a new Windows build without changing the builder.

| Folder | Content |
|---|---|
| `plugins\builtin` | the official plugins (build output, not committed), allow list: `builtin\builtin.lock.psd1` (generated) |
| `plugins\user` | your own plugins (DLLs are not committed), allow list: `config\user\plugins.lock.psd1` |
| `src\WinEase.Plugins.Abstractions` | the contract (netstandard2.0, C# 5 syntax) |
| `src\WinEase.Plugins.Builtin.*` | the official plugins: `Latency`, `PostInstallTools`, `UpstreamSync` (netstandard2.0, C# 5 syntax) |
| `src\WinEase.Plugins.Tests` | xUnit tests of the contract |

## Trust model

* Only a DLL that is listed in a lock file **with its SHA256** is loaded. The builder reads the file once
  as bytes, hashes those bytes, and loads the same bytes (`Assembly.Load(byte[])`), so the file cannot be
  swapped between the check and the load.
* A DLL that is not listed, whose hash differs, that was built for another major version of the contract, or
  that asks to replace a phase, is reported with a warning and **not loaded**. The build goes on without it.
* A plugin runs in the builder process with the rights of the builder (administrator). The allow list keeps
  unknown code out; it is not a sandbox. Only register DLLs you built or reviewed.
* A plugin **cannot replace a phase**, so the safety gates (for example the physical debloat consent) and
  the mount handling always run. It also never runs in the guest: a script that has to run there is handed
  over as a file (`IImageFileContributor`) and runs like a custom script.
* `-TestSelf` (check 22) verifies the hashes of both lock files. The HTML report and the diagnostic report
  list the loaded and the refused plugins.

## The contract

```csharp
public interface IWinEasePlugin {
    string Id { get; }
    string Version { get; }
    PluginDescription Describe();          // tweaks, MinBuild/MaxBuild, phases it wants to be called for
    bool AppliesTo(ImageInfo image);       // build, UBR, edition, architecture
    void OnPhase(PhaseContext context);    // context.Phase ("05-appx"), context.Stage (Before/After), context.Host
}
```

Optional data interfaces (implement any of them):

| Interface | Applied in |
|---|---|
| `IRegistryContributor` (`RegistryEntry`) | phase 10, through the same runner as `config\registry` |
| `IAppxRemovalContributor` (patterns) | phase 05-appx, with the protection whitelist |
| `IAppxRemovalRuleContributor` (`AppxRemovalRule`: pattern, option, invert) | phase 05-appx, like `AppxRemoval` of `config\schema.psd1`: the setting decides, then the protection whitelist |
| `IFodRemovalContributor` (`Package` / `Capability` / `Feature`) | phase 06-fod |
| `IServiceStartContributor` (name, 0-4) | phase 10, services section |
| `IImageFileContributor` (`ImageFile`: path, bytes, root, optional gating setting) | phase 11, below `Windows\Setup\Scripts\Plugins\<plugin id>` or, with `Root = SetupTools`, in `Windows\Setup\Tools` (a plugin names one of the two fixed roots, never a folder) |

`IWinEaseHost` (`context.Host`) offers `Log`, `IsTweakEnabled`, `IsComponentEnabled` (a component of
`config\schema.psd1`, for example `AtlasReviOSMode`), `IsTweakGroupEnabled` (for example `GPULatency`), `SetOfflineRegistry`,
`RunDism`, `WriteImageFile` and the read-only `ScratchDir`, `WinEaseDir`, `ImageInfo`, `DryRun`. With **DryRun** the
write operations are only recorded and do nothing. `RunDism` allows read and remove verbs on the mounted
image only (the builder adds `/Image`); `SetOfflineRegistry` only writes into the offline hives.

The build range (`MinBuild` / `MaxBuild` of `Describe()`) is checked by the builder before `AppliesTo`; it
is ignored while the build is still unknown (before phase 4 has read the image).

## The built-in plugins

The tweak **definitions** (key, alias, CLI switch, default) stay in `config\schema.psd1`, which is the one source of
truth for the CLI, the GUI and the profiles. A built-in plugin only **implements** tweaks, and every key of the schema is
implemented either by the PowerShell phases or by a built-in plugin (checked by `tests\BuiltinPlugins.Tests.ps1`).
What stays in PowerShell is everything that decides whether the image boots or is safe: mount and unmount, the OOBE and
requirement bypasses, the unattend core, the basic AppX and FoD lists, and the safety gates of the physical debloat.

| Plugin | Implements |
|---|---|
| `WinEase.Plugins.Builtin.Latency` | `EnableHAGS` (and the `GPULatency` group), `DisablePowerThrottling`, `ThreadDpcEnable` and the foreground quantum (`AtlasReviOSMode`), the MMCSS Games / Pro Audio profiles (`MMCSSGaming`, `LowLatencyAudioMMCSS`, `KeepAudioTweaks`, `DAWMode`), `GamingNetworkTweaks`. Runs after phase 10-registry through `IsTweakEnabled` / `SetOfflineRegistry`. |
| `WinEase.Plugins.Builtin.PostInstallTools` | Browser Grabber, WinEase Control Center and the Atlas-ReviOS tools: the files of `scripts\tools`, embedded byte for byte, written to `Windows\Setup\Tools` unless `-NoPostInstallAssets` is set. |
| `WinEase.Plugins.Builtin.UpstreamSync` | The registry values and AppX packages adopted from the credited tools (`docs\dev\upstream-sync-2026-10.md`). The next upstream sync changes this data and raises its version. |

Where the DLLs come from: `tools\build-binaries.ps1` (and CI) build them into `plugins\builtin` and write
`builtin.lock.psd1` with their SHA256. Neither is committed. On a source checkout without the .NET SDK the builder compiles
the plugins from `src\` with the C# compiler of Windows PowerShell the first time it starts (that is why the sources are
C# 5), writes the lock file itself, and rebuilds a DLL it built when the sources are newer; a DLL that was shipped is never
replaced. If a plugin can be neither found nor built, the builder **warns and goes on without it**: the tweaks of that plugin
are not applied (and, for `PostInstallTools`, the tools are not staged), the build does not stop.

## Errors

The `OnError` value of the lock entry decides what a failing plugin does, like `@WinEase-OnError` of a custom
script: `Stop` ends the build, `Warn` (default) reports and goes on, `Ignore` goes on silently.

## Writing a plugin

1. Reference `WinEase.Plugins.Abstractions` (project reference, or the DLL built from `src\`).
2. Implement `IWinEasePlugin` in a public class with a public parameterless constructor.
3. Build the DLL, copy it to `plugins\user`, and register it (the WinUI window requests `plugins.addUser`: it shows the SHA256 and registers the file
   only after you confirm) or add it to `config\user\plugins.lock.psd1`:

```powershell
@{
    Version = 1
    Plugins = @(
        @{ File = 'Contoso.WinEase.dll'; Sha256 = '<64 hex characters>'; OnError = 'Warn'; Description = 'Contoso tweaks' }
    )
}
```

`(Get-FileHash .\Contoso.WinEase.dll -Algorithm SHA256).Hash.ToLower()` prints the hash. Rebuilding the DLL
changes the hash: register it again.

The contract assembly is taken from `plugins\bin\WinEase.Plugins.Abstractions.dll` when it exists (not committed),
otherwise the builder compiles `src\WinEase.Plugins.Abstractions` with the C# compiler of Windows PowerShell.
Plugins bind to the assembly name and the **major version** only.
