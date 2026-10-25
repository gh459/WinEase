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

Not compared (not preset data): source, work folder, index, drivers, user and computer name, `UseVHDX` (applying a preset does set it, but a hand change there does not make the window modified), Dry Run,
migration and custom-script settings.

## Settings the preset does not define

A built-in preset defines no Advanced Debloat list and no engine. The preset therefore means "no items,
default engines", and any selected item or non-default engine makes the window Modified. A user preset
(`config/user/user-tweaks.psd1`, `UserPresets`) that defines `AdvancedDebloatStandard`,
`AdvancedDebloatExperimental` or `DebloatEngineSelection` is compared against its own lists.

## Switching presets vs Revert to preset

- **Choosing a preset** in the combo sets components, tweaks, the payload format and the VHDX switch (the preset's UseVHDX; every built-in preset carries $false, so this only shows with user presets). It does **not** touch
  the Advanced Debloat selection or engines: they survive the switch exactly as they were (physical deletion
  is never changed by picking a preset). If any are selected, the new state reads "<New preset> + modified".
- **Revert to preset** resets everything the preset controls to the base preset, **including** the
  Advanced Debloat selection and engines (a preset without a list clears them). It is a separate button
  next to the combo in both windows.
- Picking "Custom" applies nothing; the values stay and the state is Custom until a preset is chosen.

## Not implemented: Save as preset

User presets live in `config/user/user-tweaks.psd1` (`UserPresets`, loaded by `Import-WinEaseUserExtensions`
over the base preset named in `BasePreset`). The GUI does not write that file: it is hand-edited and
comment-heavy, and the preset list of both windows is fixed (it is read at start-up), so a saved preset could
not be chosen without a restart. `Get-WinEaseGuiPresetState` returns the differing keys with preset and
current values, which is the input such a feature needs.
