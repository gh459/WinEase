# Build progress protocol (builder to window)

After the window sends its result, the builder keeps the pipe open and writes one JSON
line per event: `{ "op": "progress", "event": "<name>", ... }`. The window ignores events
it does not know, so older and newer windows and builders work together.

| event | fields | meaning |
|---|---|---|
| `state` | `State` | `Preparing`, `Running`, `Verifying`, `Succeeded`, `NotVerified`, `Failed`, `Cancelling` (reserved), `Cancelled` (reserved) |
| `phase` | `Phase`, `Total`, `Name`, `EstimatedSeconds` (first event only) | a build step started; the bar counts steps, not time |
| `log` | `Text` | one log line, secrets masked, at most 500 characters; the window keeps the newest 500 |
| `failure` | `State`, `FailedPhase`, `FailedPhaseNumber`, `MessageKey`, `Summary`, `LogPath`, `ReportPath`, `OutputPath`, `DiagnosticsPath`, `DocsPath` | sent as soon as a phase fails |
| `done` | `Success`, `Message` (old fields), `State`, `Verification`, the failure fields, and the paths | the builder finished |

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
