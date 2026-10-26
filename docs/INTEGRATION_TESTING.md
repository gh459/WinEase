# Integration testing (real ISO build + VM boot)

> **Status: UNVERIFIED SCAFFOLD.** Nothing described here has been run against a real Windows ISO or a
> real Hyper-V host. **A green CI run is not verification on real hardware**: `ci.yml` runs the
> self-test, the Pester suite and `-DryRun` builds only. It never builds a real ISO, never boots a
> VM and never touches DISM against a real image. The same holds for the Pester tests of this scaffold:
> they prove that the plan, the secret scrub and the pass/fail logic behave, not that a build boots.

## Purpose

Close the gap between "the PowerShell is correct" and "an ISO produced by WinEase installs and reaches
first logon". The path is independent of the fast CI: it is started by hand (or by a weekly schedule that
is off by default), runs on a dedicated self-hosted Hyper-V machine and is never a required check for pull
requests.

Files:

| File | Role |
| --- | --- |
| `.github/workflows/integration-vm.yml` | `workflow_dispatch` + weekly schedule, self-hosted runner, scrub + upload |
| `tools/Test-WinEaseIntegration.ps1` | The test itself (stages, result JSON, scrub) |
| `tests/Integration.Scaffold.Tests.ps1` | Pester tests of the pure logic and the workflow shape |

## Runner requirements

* Windows 11/Server with the **Hyper-V** role and PowerShell module, `vmms` running, runner account in the
  *Hyper-V Administrators* and local *Administrators* groups (DISM needs elevation).
* Windows PowerShell 5.1 (the supported runtime of the builder) and the Windows ADK/oscdimg as for any build
  (the repo ships `oscdimg.exe`).
* Self-hosted runner labels exactly `self-hosted`, `windows`, `hyperv`. Use a **dedicated, disposable
  machine** that is not shared with other work and is registered only for this repository; self-hosted runners
  must never serve untrusted pull requests, which is why this workflow has no PR trigger.
* At least 80 GB free on the drive that holds the work directory (`$RUNNER_TEMP`), 8 GB RAM free, nested or bare
  metal with virtualization enabled. No stale DISM mounts (`dism /Get-MountedImageInfo` must be empty).
* A Windows 11 ISO that you obtained and are licensed to use, stored on the runner. The ISO is **never**
  uploaded or committed.
* Optional repository variables: `INTEGRATION_ENABLED` (`true` turns the weekly schedule on),
  `INTEGRATION_ISO_PATH` (ISO path for scheduled runs). No secrets are used or needed.

## Target matrix (TARGET only: nothing below is verified)

| Dimension | Target values |
| --- | --- |
| Windows 11 builds | 24H2 (26100.x), 25H2 (26200.x); N-1 feature update as a regression leg |
| Editions (builder `-Index`) | Home, Pro, Enterprise (index differs per ISO, check with `dism /Get-WimInfo`) |
| Languages | en-US first; ja-JP second (the builder has Japanese keyboard options); others untested by design |
| Architectures | x64 in a Gen2 VM. **arm64 is not covered** (needs an arm64 Hyper-V host) |
| Profiles | `balanced` first, then `extreme`, `none`, `vm` |
| Firmware | Gen2, Secure Boot on, vTPM enabled |

Each cell becomes "verified" only after a human has reviewed a real run's artifacts and recorded the
build label; the result JSON has `"verified": false` and the script never sets it to true.

### Release gating and verification criteria

A release candidate or configuration is deemed **Verified** if and only if it satisfies the following stepwise gates:

1. **Phase Rollout Order:**
   - **Baseline Gate (Primary):** x64 architecture, Windows 11 24H2 (build 26100.x), `balanced` preset.
   - **Extended Matrix Gate:** `extreme`, `none`, and `vm` presets; Japanese environment (`ja-JP` keyboard/IME); Windows 11 Pro and Home editions.
   - **Isolation Policy:** Experimental physical debloat (`-AllowPhysicalDebloat`) and deep component store pruning (`-ForceWinSxSCleanup`) are quarantined from standard integration suites and tested only on isolated disposable runs.
2. **Success Assertions (All mandatory):**
   - **Full ISO Generation:** Builder completes all 19 phases (18 numbered, plus the optional Phase 9.5 Physical Debloat), passes Phase 15 deep-apply verification and Phase 18 ISO payload hash verification.
   - **Unattended VM Boot & Setup:** Gen2 VM boots, processes unattended setup passes (`windowsPE`, `specialize`, `oobeSystem`) without manual intervention.
   - **First Logon Execution:** System reaches desktop, executes `FirstLogon.ps1`, and produces the completion signal `C:\ProgramData\WinEase\firstlogon.done` with zero `firstlogon_script.failed` triggers.
   - **Residue & Teardown Zero-Tolerance:** Host teardown destroys the VM, unmounts all DISM images, unloads temporary registry hives (`z*`), detaches VHDX scratch drives, and deletes the work folder. `dism /Get-MountedImageInfo` must remain clean.
   - **Secret Scrub:** Diagnostic artifacts pass recursive regex scrubbing for sensitive tokens and user passwords before export.
3. **Audit Trail Record:**
   - Every verified run logs the source Windows build, source ISO SHA-256, architecture, edition index, preset name, test timestamp, and runner ID in `integration-result.json`.

## How to run

Plan only (safe anywhere, touches nothing):

```powershell
.\tools\Test-WinEaseIntegration.ps1 -DryRunPlanOnly
```

Real run (on the runner, elevated):

```powershell
.\tools\Test-WinEaseIntegration.ps1 -IsoPath D:\iso\Win11_24H2_x64.iso -Profile balanced -Index 6 `
    -WindowsBuild '26100.1742 24H2' -TimeoutMinutes 90
```

Through GitHub: Actions, "Integration VM (manual)", Run workflow, fill `iso_path`, `edition_index`, `profile`,
`windows_build`. Exit code 0 means every stage passed; the result is still labelled `passed-unverified`.

Stages: `preflight` (Hyper-V present, disk space, no stale mounts via `Get-WinEaseMountedImages` from
`lib/WinEaseMount.ps1`, VM name free), `build-iso` (`WinEasebuilder.ps1 -NonInteractive`), `create-vm`
(Gen2, VHDX, vTPM, ISO as first boot device; sends Space keystrokes for "press any key"),
`wait-firstlogon`, `collect-logs`, `teardown`, `post-assert` (no mounts, no work directory, no VM), `scrub`.
Teardown, assertions and scrub run even when an earlier stage failed.

### First-logon detection (untested design)

`scripts/FirstLogon.ps1` writes `C:\ProgramData\WinEase\firstlogon.done` as its last block and
`firstlogon_script.failed` (and removes the `.done` marker) if any block failed. The host polls both files every
30 seconds through **PowerShell Direct** (`Invoke-Command -VMName`) with the build's local account and a
random per-run password (generated on the host, passed to the builder as `-UserPassword`, never stored).
Unreachable guest during setup reboots is expected and retried until `-TimeoutMinutes`. Known weak points:
the account may not exist until after OOBE, autologon timing, and PowerShell Direct needs the guest to have
reached a signed-in or at least booted OS state.

The password is a process argument of the builder for the duration of the build; on a dedicated runner that is
accepted, on a shared machine it would not be.

## Artifacts

Uploaded as `integration-vm-<run id>` (14 days): `integration-result.json` (stage status, profile, index,
Windows build label, problems), `builder.log`, `WinEase_report.html`, `build_diagnostics/`, and the guest
`C:\ProgramData\WinEase` logs plus Panther setup logs under `guest/`. The built ISO and VHDX are deleted.
The profile and index used are recorded in the result JSON.

**Scrub:** before the upload the artifact folder is scanned (UTF-8 and UTF-16) for the run password, the
builder's default password and known token shapes (GitHub tokens, AWS key ids, private-key blocks, bearer
tokens, Anthropic keys). A hit deletes the offending file, fails the step, and the upload step only runs after
a successful scrub, so a leak is not published. The scrub is a safety net, not proof that no sensitive data
exists (logs can contain machine names, paths and user names).

## Failure-injection plan

Mockable in Pester today (`tests/Integration.Scaffold.Tests.ps1`): low disk space (`Test-WinEaseIntegrationDiskSpace`),
a stale/invalid DISM mount record at preflight and as a post-run leftover, leftover work directory or VM, a
locked file that blocks cleanup (`Test-WinEaseFileLocked`, `Remove-WinEaseIntegrationPath`), planted secrets.

Manual scenarios on the real runner (all unexecuted so far; record the outcome and the build label):

| ID | Scenario | How | Expected |
| --- | --- | --- | --- |
| M1 | DISM mount failure | Mount an image yourself (`dism /Mount-Image ... /MountDir C:\stale`) and start the test | Preflight fails naming the mount; nothing built; no teardown damage. Repeat with a mount killed mid-build (stop the builder with Ctrl+C during phase 10) and expect the next run's preflight to refuse until `dism /Cleanup-Mountpoints` |
| M2 | DISM unmount failure | Hold a handle in the mount directory (open a file in a shell with that directory as cwd) while the builder unmounts | Build fails, builder diagnostics preserved, `post-assert` reports the leftover mount, job fails; nothing is reported green |
| M3 | Low disk space | Fill the work drive until under 80 GB free (or lower `$script:RequiredFreeBytes` for a rehearsal) | Preflight fails with the free/required numbers before anything is created |
| M4 | File lock on teardown | Open the VHDX or a log from another process during teardown | `teardown` retries three times, then reports `Could not remove work directory`; job fails, VM is already removed |
| M5 | Interrupt + resume | Kill the runner process mid-build, restart, run again; also try the builder's own `-Resume` path (`lib/WinEaseResume.ps1`) | Second run fails preflight on the stale `WorkDir`/mount rather than silently reusing it; after manual cleanup a fresh run succeeds. Whether builder resume is safe inside this harness is undecided |
| M6 | First-logon failure | Use a deliberately failing custom FirstLogon script (`tools/custom-scripts/FirstLogon`) | `firstlogon_script.failed` is detected, stage `wait-firstlogon` fails, logs collected, teardown clean |
| M7 | Hung guest | Break the unattend so setup never finishes | Timeout after `-TimeoutMinutes`, VM turned off and removed |

## Limits

* No real run exists yet; commands, parameters of Hyper-V cmdlets and the keystroke workaround are untested.
* Only x64, only Hyper-V Gen2; no physical hardware, no GPU/driver/Wi-Fi coverage, no real-world update path.
* Reaching first logon (marker file) is the only success signal; it does not assert that tweaks behave,
  that Windows Update works, or that the system is stable after the first reboot.
* Self-hosted runner hygiene (patching, isolation, credentials) is the operator's responsibility.
* **CI green does not mean verified on real hardware.** Treat any claim of "tested on Windows 11" as
  unsupported until a reviewed integration run (and, for physical-debloat paths, a hardware test) is on record.
