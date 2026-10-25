# Preset state in the GUI (preset, modified, custom)

The WinUI 3 window and the WinForms fallback share one rule for "is the window still the preset I chose?".
The rule is `Get-WinEaseGuiPresetState` in `lib/WinEaseGuiCore.ps1`; the windows never compare values
themselves (the WinUI window asks the builder through the `presetState` request). A preset's values come from
`Get-WinEaseGuiPresetValues` (same file), which reads `config/presets.psd1` and `config/schema.psd1`.

## States

| State    | Meaning                                                        | Result `PresetKey` | Result `BasePresetKey` |
|----------|----------------------------------------------------------------|--------------------|------------------------|
| Preset   | every preset-controlled value equals the base preset            | the preset key     | the preset key         |
| Modified | something differs ("Balanced + modified (3 setting(s) differ)") | `Custom`           | the preset it started from |
| Custom   | no base preset (started on an unknown name, or "Custom" picked) | `Custom`           | none (or the last base) |

The builder applies `BasePresetKey` first and then every value the window reports, so a hand edit always
wins over the preset. `Apply-WinEaseGuiResult` names such a run `custom (based on <base>)`.

## What counts as a difference

Compared, in this order, and only when the window reports the part:

- **Components** (the Gui switches of `schema.psd1`) that the preset names. A component the preset does not
  name keeps whatever value the window has: it is neither changed by a preset switch nor compared.
- **Tweaks.** Every tweak is compared. A tweak the preset does not name means its schema default (that is
  what applying the preset sets).
- **Payload format** (WIM / ESD / SWM).
- **Advanced Debloat items** (Standard and Experimental, as sets) and the **engine** of every selected item
  (the registered default filled in, so an explicit default equals "no entry"). The engine of an item that is
  not selected is ignored, because the build drops it.

Not compared (not preset data): source, work folder, index, drivers, user and computer name, `UseVHDX`, Dry Run,
migration and custom-script settings.

## Settings the preset does not define

A built-in preset defines no Advanced Debloat list and no engine. The preset therefore means "no items,
default engines", and any selected item or non-default engine makes the window Modified. A user preset
(`config/user/user-tweaks.psd1`, `UserPresets`) that defines `AdvancedDebloatStandard`,
`AdvancedDebloatExperimental` or `DebloatEngineSelection` is compared against its own lists.

## Switching presets vs Revert to preset

- **Choosing a preset** in the combo sets components, tweaks and the payload format. It does **not** touch
  the Advanced Debloat selection or engines: they survive the switch exactly as they were (physical deletion
  is never changed by picking a preset). If any are selected, the new state reads "<New preset> + modified".
- **Revert to preset** resets everything the preset controls to the base preset, **including** the
  Advanced Debloat selection and engines (a preset without a list clears them). It is a separate button
  next to the combo in both windows.
- Picking "Custom" applies nothing; the values stay and the state is Custom until a preset is chosen.

## Save as preset

Both windows save the current settings as a **user preset**: the "Save as preset…" button next to
"Revert to preset" asks for a name (and an optional description), then calls
`Save-WinEaseGuiUserPreset` in `lib/WinEaseGuiCore.ps1` - the one shared function; the windows
never write the file themselves.

- **The file.** One preset per file under `config\user\presets\<key>.psd1` (the key is the
  trimmed, lower-case name). `user-tweaks.psd1` is never rewritten; the loader
  (`Import-WinEaseUserExtensions`) reads the folder like the `UserPresets` entries of
  `user-tweaks.psd1`, so a hand-written preset and a saved one behave the same. The file stores
  only preset data: every Gui component, every tweak, the payload format and the Advanced Debloat
  selection with its engines. Secrets (the schema marks `UserPassword` `Secret = $true`) and paths
  (source, work folder, drivers) are never stored.
- **The name.** 1-40 characters: letters (any script, so Japanese names work), digits, spaces,
  `-` and `_`. A built-in preset name and the reserved names `custom` / `none` are refused.
  Saving over an existing user preset asks first (WinForms: `Confirm-WinEaseGuiAction`, WinUI: a
  confirm dialog triggered by the `SavePreset.Reason.Exists` reason).
- **The write.** `Write-WinEaseTextFileAtomic` (UTF-8 with BOM, so Japanese survives the way
  `Import-PowerShellDataFile` reads it). After the write the file is read back through the same
  loader and `Get-WinEaseGuiPresetValues` must return exactly the saved values; only then does
  the window report success, so a half-written or mis-parsed file never claims "saved".
- **After the save.** Both windows rebuild their preset list without a restart
  (`Update-WinEaseGuiUserPresets` re-reads the folder; the WinUI window gets the refreshed list
  with the `savePreset` reply / a `presets` request), select the new preset and show its state as
  "<new preset> (unmodified)" - the values are by definition what the preset holds.

User presets appear in the preset combo after the built-in six (labelled with their `ProfileName`)
and before "Custom"; the "Preset Diff" dialog lists them too, and the CLI accepts their key like
any preset name.
