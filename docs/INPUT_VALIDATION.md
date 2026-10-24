# Input validation

One function decides whether the inputs of a build are usable: `Test-WinEaseBuildInputs` in
`lib\WinEaseInputValidation.ps1`. Both GUI windows, the PowerShell side of the GUI bridge and the command line call it,
so a value that is refused in one place is refused in all of them. The GUI is not the trust boundary: whatever a window
sends is checked again in PowerShell before a builder variable changes.

## What is checked

Every finding is an object `{ Field, Severity (Error | Warning), MessageKey, Args, Confirm }`; the text comes from
`config\ui-strings\en.json` / `ja.json` (`Val.*`, plus the older `Msg.InvalidUserName.Text`,
`Msg.InvalidComputerName.Text` and `Msg.SourceRequired.Text`). An empty result means everything is fine.

| Field | Rule | Severity |
| --- | --- | --- |
| SourceDrive | required in the windows (`-RequireSource`); an `.iso` must be an existing file; a drive letter (`E:`, `E:\`, or a path on that drive) must hold `sources\install.wim` or `install.esd`; anything else is invalid | Error |
| WorkDir, OutputDir | exists as a folder, or the nearest existing parent is a folder (so it can be created); a file in the way, an invalid path or a parent that cannot be written to is refused. Empty WorkDir means the default workspace (`Documents\WinEase_workspace`) and is checked like a typed one | Error |
| Collisions | work = output; output inside work (the build clears the workspace); source ISO inside work; output ISO name resolves to the source ISO; work or output is the root of the source drive | Error |
| Collisions | work inside the output folder | Warning |
| OutputIsoName | no characters that are illegal in a file name | Error |
| InjectDrivers | when given: must be an existing folder (a missing folder used to be skipped silently by phase 11) | Error |
| UserName, ComputerName | the patterns of `Get-WinEaseInputPattern`; an empty ComputerName means `*` | Error |
| Index | empty: "not chosen", a Warning with `Confirm = $true`; otherwise a positive number; when the list of editions is known (`-AvailableIndices`) it must be in it | Warning / Error |
| Disk | free space of the volumes against the build plan's figures (`Get-WinEaseRecommendedFreeGB`, `Get-WinEaseBuildSizeEstimateMB`); only with `-CheckDiskSpace`; unknown free space is silent (the build plan lists it as unverified) | Warning |

Notes:

* The patterns are defined once, in `Get-WinEaseInputPattern`. `WinEasebuilder.ps1` keeps the same two literals in its
  `[ValidatePattern]` attributes because a parameter attribute cannot call a function; `tests\InputValidation.Tests.ps1`
  asserts that they are equal. The windows no longer contain the regex text.
* The edition index is never guessed by the validation. Neither window has an edition list at Start time, so an empty
  index is reported as "no edition chosen" and Start asks for an explicit confirmation. If the user confirms (or the
  command line leaves `-Index` out), the existing behaviour of phase 3 applies: the builder lists the editions and
  asks, and an unattended run (`-NonInteractive`) uses the Pro edition or else the first one. The command line prints the
  warning but does not stop, so existing unattended scripts keep working.
* The function never creates, changes or deletes anything that exists. Writability is probed by creating one uniquely
  named file (`.wineasetest-<guid>.tmp`, `FileOptions.DeleteOnClose`) in the folder, or in its nearest existing parent.
  Nothing is created for a folder that does not exist yet. A dry run (`-DryRun`, `-WhatIf`, `WINEASE_TEST_MODE=1`) and
  the PowerShell re-check of a dry-run result skip the probe (`-SkipWriteProbe`); existence and collision rules still run.
* A free-space shortfall is only a Warning because the builder itself redirects the workspace to another volume when the
  chosen one is too small (`phases\01-environment.ps1`).

## Where it runs

| Caller | When | Effect of an Error |
| --- | --- | --- |
| WinForms (`gui\WinEaseGui.ps1`) | a media field is left (all rules), every keystroke in Index / UserName / ComputerName (pattern rules only), Start (`Complete-WinEaseGuiResult`, with disk space) | message label and icon under the field, Start is blocked, one message box lists the errors; a Warning that needs confirmation (no edition) asks Yes/No |
| WinUI 3 (`MainWindow.xaml.cs`) | typing or a picker filling a box (debounced request `validate`), Start (`validate` with disk space) | message under the field, Start is blocked and the media page is shown; the confirmation for "no edition" is a dialog |
| `ConvertFrom-WinEaseWinUiResult` (`gui\WinEaseWinUiHost.ps1`) | every `result` message of the window | returns `@{ Success = $false; Reason; Issues }`; `Invoke-WinEaseGuiSession` prints the reason and treats it as cancelled |
| `Apply-WinEaseGuiResult` (`lib\WinEaseGuiSession.ps1`) | before any builder variable changes (also for the WinForms result) | warns with the reasons, returns `$false`, changes nothing. Only fields that carry a value are checked, so partial results still work |
| `WinEasebuilder.ps1` | after the profile / GUI / command-line values are resolved and before the dry-run exit and before the build lifecycle starts | warnings are printed, errors throw `Input validation failed` |

The pickers (`OpenFileDialog` / `FolderBrowserDialog` in WinForms, `FileOpenPicker` / `FolderPicker` in WinUI) already
existed for the source (drive or ISO), the workspace and the drivers folder. There is no output-folder box: the builder
writes the ISO next to `WinEasebuilder.ps1`, and that folder is what the check uses as `OutputDir`.

## Value precedence

Read from `WinEasebuilder.ps1`, `lib\WinEaseGuiSession.ps1` and `gui\WinEaseWinUiHost.ps1`; in the order the code applies them,
later wins:

1. Defaults: the `param()` defaults (`ComputerName = '*'`, `UserName = 'User'`) and the defaults in `config\schema.psd1`.
2. Profile: `-Profile` / `-Preset` (built-in preset), then `-LoadProfile` (JSON file). For `SourceDrive`, `WorkDir`, `Index`,
   `ComputerName`, `UserName`, `UserPassword`, `SkipEiCfg`, `NoPostInstallAssets` the file value is used only when that
   parameter was not given on the command line.
3. GUI edit (`-GUI`): the window starts from the values resolved so far (`Get-WinEaseGuiInitialSettings`) and
   `Apply-WinEaseGuiResult` then assigns what the window returned. For `SourceDrive`, `WorkDir`, `UserName`,
   `ComputerName`, `Index` and `InjectDrivers` the GUI result replaces the command-line value (a non-empty GUI value is
   assigned unconditionally).
4. Explicit CLI switches for components and tweaks: they are processed after the GUI session
   (`$script:ConfigOverrides`, `$script:TweakOverrides`), so a switch such as `-RemoveDefender` or `-TweakSettings`
   entry wins over what the window returned.

So "defaults < profile < GUI edit < explicit CLI" holds for component and tweak switches. It does not hold for the media
fields listed in step 3: with `-GUI` the window's value wins there. The input check runs on the final values, after step 4.

## Tests

`tests\InputValidation.Tests.ps1` covers every rule (including collisions, creatable and non-writable folders - the
non-writable case is built with an ACL deny and skipped when the ACL cannot be applied - unknown index, free space), the
pattern equality, the localization keys, the wiring and the command line (`WinEasebuilder.ps1 -DryRun` in a child
process). `tests\GuiParity.Tests.ps1` covers the PowerShell-side refusal of a result that the window should never send.
