# Presets

This page describes the built-in presets as they are defined in `config/presets.psd1`
(the single source of truth), on top of the defaults in `config/schema.psd1`. The
preset names and order are `none`, `extreme`, `balanced`, `fat32`, `handheld`, `vm`,
`audio`. Aliases: `Standard` and `Safe` map to `balanced`, `Gaming` to `extreme`,
`UltraSlim` to `vm`, `MinimalServices` to `handheld`, `None` to `none`.

The table values below are read from that file. The effects listed under "Trade-offs"
are the expected consequences of the options, not measurements: this project has not
measured the performance effect of any preset (see [`BENCHMARKING.md`](BENCHMARKING.md)),
and the effect of a setting depends on hardware, Windows build and drivers. Options that
disable a Windows protection are documented separately in
[`SECURITY_OPTIONS.md`](SECURITY_OPTIONS.md). Check the preset in the GUI or with
`-DryRun` before you build: this page can lag behind the file.

## How settings not covered by a preset are treated

The effective configuration is resolved in three layers, in this order (see
`Resolve-WinEaseConfiguration` in `lib/WinEaseConfig.ps1` and
`Apply-WinEaseProfileComponents` / `Apply-WinEaseProfileTweaks` in
`WinEasebuilder.ps1`):

1. The default of each setting from `config/schema.psd1`.
2. The values the preset sets.
3. Your explicit settings (profile, GUI, command line). These always win over the preset: an option you set explicitly to `$false` stays false even if the preset switches it on.

Consequences:

- A setting the preset does not mention keeps its schema default. For example, the schema declares 140 individual tweaks and 106 of them default to on. The `extreme`, `fat32`, `handheld` and `audio` presets only set `ConfigureWinlogon` among the tweaks (plus the tweak-type keys listed in the tables below, such as `RadicalRAM` and `NoHypervisor`); every other tweak stays at its default, which is mostly on. Only the `none` preset lists the tweaks explicitly, and sets all of them to off. `balanced` and `vm` set no `TweakSettings` entries either.
- `IncludeMigrationAssistant` is absent from every preset, so it keeps its default.
- Advanced Debloat target lists (`AdvancedDebloatStandard`, `AdvancedDebloatExperimental`) are not part of any preset. Selecting a preset does not select targets. Physical deletion needs `-AllowPhysicalDebloat` (or the equivalent consent in the GUI) in addition.
- Build-environment settings such as `SourceDrive` and `WorkDir` are not set by presets.

I did not trace every code path that can read a setting after resolution (for example
the dependency checker and safeguards that can still override a request; see
`Test-WinEaseConfigConflicts`). If a build prints a safeguard or conflict message, that
message is authoritative for that build.

## What each preset changes

Values are compared with `none`, whose component options are: every removal off, every
Keep option on, `HibernateMode = Keep`, `CrashDumpMode = Automatic`,
`PayloadFormat = WIM`.

### `none` - "None (no removals)"

Nothing is removed or disabled: every removal option is off, every Keep option is on
and every tweak stays at its default according to the preset description. (In the file it actually lists 137 tweaks and sets them all to off, which differs from the schema defaults, where 106 of 140 tweaks are on, so `none` is not the same as "all schema defaults".)
Only the image setup itself (name, keyboard layout, payload format)
changes. Use it as the baseline for comparisons.

Trade-offs: none beyond what the unattended setup does (the answer file and its
setup prerequisites apply regardless of the preset; see `SECURITY_OPTIONS.md`).

### `balanced` - "Balanced Pro"

Described as a safe daily debloat: Windows Update and Defender preserved, high stability.

Sets: `SafeDebloatMode`, `AtlasReviOSMode` and `SetJapaneseKeyboard` on; removes the
AppX bloatware set (`RemoveAppxBloatware`) and the Camera, Photos and Snipping
(`RemoveScreenSketchApp`) apps; `IncludeMigrationBackup` on; `KeepAudioTweaks` off.
Explicitly off: `RadicalRAM`, `NoHypervisor`, `NoKernelPaging`, `DisableMemCompression`,
`DisableUSBSuspend`, `BypassActivationRestrictions`. Not changed from `none`: Defender is
kept, Windows Update is kept, Store, recovery, Asian IME, fonts, Bluetooth, Xbox services
and search indexing are kept.

Trade-offs: the removed apps are gone from the image; `AtlasReviOSMode` applies the
timer/scheduler tuning described in the README (effect unmeasured). Updates and Defender
continue to work.

### `extreme` - "Extreme Slim & Gaming"

Described as maximum debloat, low-latency kernel/timer tuning, minimal footprint.

Sets, in addition to the `balanced` list: `RemoveDefender`, `DisableWindowsUpdate`,
`RemoveStore`, `RemoveDrivers`, `RemoveLegacyFOD`, `TrimWallpapers`, `UltraSlimMode`,
`KeepExtraFonts` off, `KeepBasicApps` off, `KeepSearchIndex` off, `KeepXboxServices` off,
`KeepRecoveryEnv` off, `MMCSSGaming`, `DisableFSE`, `NvidiaLowLatency`,
`HibernateMode = Off`, `CrashDumpMode = None`, and the tweak-type options `RadicalRAM`,
`NoHypervisor`, `NoKernelPaging`, `DisableMemCompression`, `DisableUSBSuspend`,
`BypassActivationRestrictions` on, plus the tweak `ConfigureWinlogon` (blank-password
auto-logon). Not changed from `none`: Asian IME and Bluetooth are kept.

Trade-offs:

- Defender is removed (no antivirus, not re-enableable in place) and Windows Update is disabled: see `SECURITY_OPTIONS.md`. The README notes the result is not serviceable via cumulative updates.
- No Store, no recovery environment, no hibernation or Fast Startup, no crash dumps (harder to diagnose blue screens).
- `NoHypervisor` turns the hypervisor off: WSL2, Hyper-V and virtualization-based features will not work.
- `NoKernelPaging`, `DisableMemCompression` and `RadicalRAM` trade memory behavior for intended lower overhead; they can hurt on machines with little RAM. Unmeasured.
- `DisableUSBSuspend` raises power use for USB devices.
- Blank-password auto-logon: anyone with physical access gets the desktop.
- Legacy drivers and optional features are removed; old hardware may stop working.

### `fat32` - "FAT32 USB Split-WIM"

Identical to `extreme` except `PayloadFormat = SWM`: the install payload is split into
`.swm` files so the ISO content fits a FAT32 USB stick. All `extreme` trade-offs apply.

### `handheld` - "Portable Gaming PC"

Described as tuned for handhelds (ROG Ally, Steam Deck, Legion Go): battery balance and
gamepad protection.

Same as `extreme` except: `NvidiaLowLatency` stays off, `KeepXboxServices` stays on (Xbox
services and the gaming overlay are kept), `HibernateMode = Reduced` instead of Off, and
`CrashDumpMode = Small` instead of None. Defender is still removed and Windows Update
still disabled, with the other `extreme` trade-offs.

Trade-offs: Reduced hibernation keeps a smaller hibernate file, so resume from
hibernation stays possible on a handheld; Bluetooth is kept for controllers.

### `vm` - "VM & Developer Workstation"

Described as configured for virtual machines and developers: WSL2 and Hyper-V enabled.

Sets: `WSLSupport` on, `RadicalRAM` on, `HibernateMode = Off`, `KeepBluetooth` off,
`KeepAudioTweaks` off, `KeepXboxServices` off, plus the `balanced` AppX removals,
`SafeDebloatMode` and `IncludeMigrationBackup`. `NoHypervisor` is explicitly off (the
hypervisor stays on). `BypassActivationRestrictions` is on. Not changed from `none`:
Defender and Windows Update are kept, `AtlasReviOSMode` stays off, the Store is kept.

Trade-offs: no Bluetooth stack, no hibernation. `RadicalRAM` is on, with the same caveat
as above. Defender and Windows Update remain active.

### `audio` - "Audio & DAW Production"

Described as pro-audio MMCSS priority, zero DPC latency spikes, VST compatibility
protected. ("Zero DPC latency spikes" is the description text in the file, not a
measured result.)

Sets: `DAWMode` on, `AtlasReviOSMode` on, `RemoveDefender`, `DisableWindowsUpdate`,
`KeepSearchIndex` off, `KeepXboxServices` off, `KeepRecoveryEnv` off, `KeepBluetooth` off,
`HibernateMode = Off`, `CrashDumpMode = Small`, the tweak-type options `RadicalRAM`,
`NoHypervisor`, `NoKernelPaging`, `DisableUSBSuspend`, `BypassActivationRestrictions` on,
the `balanced` AppX removals, and `ConfigureWinlogon`. Not changed from `none`: Store,
legacy drivers and optional features, wallpapers and extra fonts are kept.

Trade-offs: Defender removed and Windows Update disabled; no Bluetooth (wireless audio
devices and controllers will not work); no hypervisor; USB selective suspend is
disabled, which is intended to avoid USB audio dropouts but raises power use. Unmeasured.

## Summary table

| Option | none | balanced | extreme | fat32 | handheld | vm | audio |
|---|---|---|---|---|---|---|---|
| RemoveDefender | off | off | on | on | on | off | on |
| DisableWindowsUpdate | off | off | on | on | on | off | on |
| ConfigureWinlogon (blank-password auto-logon) | off | off (schema default) | on | on | on | off (schema default) | on |
| RemoveStore | off | off | on | on | on | off | off |
| RemoveAppxBloatware | off | on | on | on | on | on | on |
| UltraSlimMode | off | off | on | on | on | off | off |
| KeepBluetooth | on | on | on | on | on | off | off |
| KeepRecoveryEnv | on | on | off | off | off | on | off |
| HibernateMode | Keep | Keep | Off | Off | Reduced | Off | Off |
| CrashDumpMode | Automatic | Automatic | None | None | Small | Automatic | Small |
| WSLSupport | off | off | off | off | off | on | off |
| NoHypervisor | - | off | on | on | on | off | on |
| RadicalRAM | - | off | on | on | on | on | on |
| PayloadFormat | WIM | WIM | WIM | SWM | WIM | WIM | WIM |

"schema default" means the preset does not set the tweak, so the default from `config/schema.psd1` applies. "-" means the preset does not list
the key. Read the full values in `config/presets.psd1`.
