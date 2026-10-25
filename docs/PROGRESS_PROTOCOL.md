# Build progress protocol (builder to window)

After the window sends its result, the builder keeps the pipe open and writes one JSON
line per event: `{ "op": "progress", "event": "<name>", ... }`. The window ignores events
it does not know, so older and newer windows and builders work together.

| event | fields | meaning |
|---|---|---|
| `hello` | `Capabilities` (`Cancel`: true/false), `CancelRequestPath` | sent once, first: what this builder can do (see Cancel below) |
| `state` | `State` | `Preparing`, `Running`, `Verifying`, `Succeeded`, `NotVerified`, `Failed`, `Cancelling`, `Cancelled` |
| `phase` | `Phase`, `Total`, `Name`, `EstimatedSeconds` (first event only) | a build step started; the bar counts steps, not time |
| `log` | `Text` | one log line, secrets masked, at most 500 characters; the window keeps the newest 500 |
| `failure` | `State`, `FailedPhase`, `FailedPhaseNumber`, `MessageKey`, `Summary`, `LogPath`, `ReportPath`, `OutputPath`, `DiagnosticsPath`, `DocsPath` | sent as soon as a phase fails |
| `done` | `Success`, `Message` (old fields), `State`, `Verification`, the failure fields, the paths, and after a cancel `Cancelled`, `CleanupOk`, `CleanupProblems` | the builder finished |

## Success is verified, not assumed

`Verification` is `Verified` only when the deep apply of `install.wim` (phase 15,
`$script:FinalPayloadVerified`) and the ISO payload hash check (phase 18,
`$script:IsoPayloadVerified`) both passed. Anything else (false, null, phase not run, for
example `-ResumeIsoOnly`) is `NotVerified`, and the final state is then `NotVerified`,
never `Succeeded`. A window that receives a `done` without `State` or `Verification`
(an older builder) also shows "not verified". `Success` keeps its old meaning: the builder
ended without an error.

## Secrets

`Summary`, `log` text, `build_errors.log` and the diagnostic report fields are passed
through `Hide-WinEaseSecretText` (`lib\WinEaseGuiSession.ps1`): the configured account
password, unattend password elements, `password`/`token`/`secret`/`api key` assignments,
`-UserPassword`-style parameters and bearer tokens are replaced by `********`.
`MessageKey` is a ui-strings key (`Progress.Failure.*`); unknown keys show the generic text.

## Window

The Open log, Open report, Open output folder, Open diagnostics folder and Open recovery
help buttons are enabled only when the path exists. They start the shell with the path as
`FileName` (no command line) and only open folders and data files (.log, .txt, .html, .json, .md).
Open output folder uses the folder that holds `OutputPath`; before the ISO exists (an early
failure) it is the folder the ISO would be written to, so the button is still useful.
Recovery text: [KNOWN_ISSUES.md](KNOWN_ISSUES.md), "Recovery methods".

## Cancel

Capability: the window enables its Cancel button only when it received `hello` with `Capabilities.Cancel = true`
and a `CancelRequestPath` that is an absolute path to a file named `cancel.request` in an existing folder. A builder
that sends no `hello` (an older one) or `Cancel = false` leaves the button disabled, with a tooltip and a visible text
that say why (use Ctrl+C in the console).

Request channel: the window creates the file `<diagnostics folder>\cancel.request` (the path comes from `hello`;
the folder is `build_diagnostics\<build id>` and exists before the build starts). A file was chosen over a named
event or a pipe message because the builder stops reading the window's output after the settings were sent, a file
needs no extra handle in either process, and it survives a window that is closed right after the request. The window
only creates this one file; the builder only tests for it (`Test-WinEaseCancelRequested`) and never deletes it
(the folder is per build).

When the builder looks: only at a phase boundary, before `Enter-Phase` of the next phase. A phase that is running
(a DISM mount/unmount/export, WIM verification, ISO creation) is never interrupted, so a cancel can wait several
minutes. There is no check inside phases today.

On a request the builder: stops starting phases, sends `state` `Cancelling`, runs the same cleanup as for a failed
build (the `finally` block of `WinEasebuilder.ps1`: unload registry hives, unmount DISM images with discard,
detach the VHDX scratch disk, dismount the source ISO, remove the Defender exclusion; the work folder and partly built
files are kept, as after any build that did not succeed), then checks what is left (loaded hives, DISM mounts of this
build, VHDX, ISO). Nothing left: `state` `Cancelled`, `done` with `State = Cancelled`, `Success = false`,
`Cancelled = true`, `CleanupOk = true`, exit code 3. Something left: `done` with `State = Failed`,
`Cancelled = true`, `CleanupOk = false`, `MessageKey = Progress.Cancel.CleanupFailed`, `Summary` and
`CleanupProblems` listing it (secrets masked), exit code 1. A cancel is never reported as `Failed` only because it
was a cancel, and never as `Cancelled` over a half-cleaned state.

Window: clicking Cancel writes the request and shows "Cancelling... (waiting for a safe point)". It never shows
the build as cancelled until `state` `Cancelled` / `done` arrives. If the build ends before the request is honoured
the window says so. If the cleanup failed it shows the failure panel with the pointer to
[KNOWN_ISSUES.md](KNOWN_ISSUES.md), "Cancelling and interrupted builds".

Closing the window during a build asks: Cancel build (only when cancel is supported), Keep running in console, or
Stay (default). Keep running in console closes the window and the build continues; the window can not be reopened
for that build. Without a running build (finished, dry run, settings page) the window closes without asking.
