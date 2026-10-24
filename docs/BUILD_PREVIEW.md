# Build plan: the final confirmation before a build

Both GUI windows (WinUI 3 and the WinForms fallback) show the same summary when you press Start, after the
input checks, the dependency check and the physical-debloat consent, and before the result is returned to the
builder. The summary is `Get-WinEaseBuildPlan` in `lib/WinEaseBuildPlan.ps1`: a pure function over the window's
result and the schema (`config/schema.psd1`, `config/presets.psd1`, `config/dependencies.psd1`). The windows
only render it (`Get-WinEaseBuildPlanView` gives them localized sections and a plain-text form); neither
window has its own rules. It is recomputed from the current selection every time, never cached.

## What it shows

| Part | Content |
|------|---------|
| Mode | **DRY RUN** (the configuration is resolved and checked, no image is built) or **REAL BUILD**, as the banner of the dialog |
| Overview | source, image index (the edition name is shown as "unknown" because the window does not read the WIM), work folder, output folder and name pattern, payload format (WIM / ESD / SWM, plus VHDX), preset and whether it was modified |
| Changed | every setting that differs from the base preset (`Get-WinEaseGuiPresetState`), with the preset and the current value |
| Unchanged | settings that equal the preset |
| Skipped | components the preset does not define (the window value is kept and not compared) and Advanced Debloat items selected without consent (the build drops them) |
| Unverified | anything whose impact or origin cannot be resolved: dependency "Unknown" items, tweaks the schema does not define, unregistered debloat items, a base preset that does not exist, and a volume whose free space cannot be read. An Unverified item is never listed as Unchanged or OK |
| Dangerous items | the dependency review (conflicts, unknowns, impacts) with the concrete impact and the reversibility |
| Disk space | required vs free space per volume, or "unknown" |

## Critical warnings and the acknowledgement

A plan is critical when it contains any of: a dependency conflict or unknown, Advanced Debloat items that will
physically delete files, an item documented as not reversible in place, or a volume with less free space than
required. For a **real build** the confirm button stays disabled until the "I have read the critical warnings"
checkbox is ticked. A dry run changes nothing, so it is shown with the same warnings but needs no checkbox.

## Reversibility

`config/dependencies.psd1` entries may carry `Reversible = $true/$false` and `Recovery = '...'`, filled in only
where `docs/SECURITY_OPTIONS.md` documents it (today: `RemoveDefender`, `DisableWindowsUpdate`). Everything
else is shown as "not documented"; the plan never guesses.

## Disk space

Required space comes from numbers the project already has: the "Estimated size" of the window
(`Get-WinEaseBuildSizeEstimateMB`, now shared by both windows) for the output, and
`Get-WinEaseRecommendedFreeGB` (40 GB, the threshold `Invoke-WinEaseHostHealthCheck` warns at) for the work
folder. Needs on the same volume add up. Free space comes from `[IO.DriveInfo]`; a UNC path or an unreadable
drive gives "unknown", which is listed under Unverified and is not treated as enough. The builder's later
checks (host health, per-image capacity analysis) are unchanged.

## What the builder does with it

The window puts the confirmed plan into its result (`BuildPlan`); `Apply-WinEaseGuiResult` keeps it in
`$script:GuiBuildPlan`. At the end of configuration resolution (after the config snapshot, before a dry run
exits) `Invoke-WinEaseBuildPlanCheck`:

1. writes `logs/WinEase_<timestamp>.plan.json` and `.plan.txt`;
2. compares the resolved effective settings with the plan's `Effective` block
   (`Compare-WinEaseBuildPlanToSettings`; only keys present on both sides are compared);
3. logs every mismatch with `Write-Warning`; a mismatch of a build option (payload format, VHDX, dry run), an
   Advanced Debloat list, or a setting the dependency catalog marks Known/Unknown is an error and aborts the
   run before anything is built.

Runs without a window (command line, profile) carry no plan; the check then only prints that none was received.

## Pre-check failures do not fail open

If the dependency check itself throws (WinForms) or gets no usable reply (WinUI), the window shows the error and
asks for an explicit acknowledgement before continuing; it no longer skips the check silently. If the plan
cannot be built, the user is asked whether to continue without the summary.

## Not covered

- The edition name is not read from the image at this stage.
- The WinUI window keeps its own copy of the size estimate for the status line (`UpdateEstimate`); the plan uses
  the shared PowerShell function.
- The dialogs were compiled (WinUI) and parsed (WinForms) but not opened by hand in this change.
