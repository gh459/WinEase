# Known issues, irreversible changes and recovery

WinEase builds a modified Windows image. Several of its options cannot be undone on
the installed system. Read this page before you build and test every build in a
virtual machine first. For the verification status of the project (what CI does and does
not test) see "Supported and verified" in the [README](../README.md).

## Known issues and limits

- **Not verified by CI on a real image.** CI runs `-TestSelf`, Pester and `-DryRun` builds only. No real-ISO or VM install test is run by CI. Results on your hardware, ISO and Windows build may differ.
- **ARM64 is untested.** The `win-arm64` package is cross-built in CI; nothing has been run on ARM64 hardware or a VM. The builder checks the `boot.wim` architecture in Phase 14 and warns on a mismatch.
- **Performance effects are not measured.** See [`BENCHMARKING.md`](BENCHMARKING.md). No results are published.
- **The stripped system is not serviceable via cumulative updates** when the Component Store (WinSxS) is stripped (README, "Before you begin"). If you need long-term servicing, keep Windows Update and Defender and do not use the aggressive options.
- **Windows 11 24H2 (build 26100+) component cleanup is risky.** `-ForceWinSxSCleanup` (experimental, off by default) forces offline `/StartComponentCleanup` (and `/ResetBase` with it) and overrides a safety block. The README lists the risk as checkpoint LCU corruption (0x80070570 / 0x800f081f). The build runs a deep-apply verification and an ISO payload hash check as a safety net, not a guarantee.
- **Do not use `MediaCreationTool.exe` ISOs.** They contain `install.esd`; modifying it with DISM frequently fails with data stream corruption (0x80070570). Use the official ISO download from Microsoft (README, "Prerequisites").
- **Setup may still stop in rare cases** with "Windows could not complete the installation" when the answer file is not used. The manual workaround is in the README troubleshooting section (see Recovery below).
- **Unattended setup wording in the README is a design goal, not a verified guarantee.** The README describes setup as zero-click; this is not checked by CI.
- **The `WinEase.exe` launcher is not code-signed.** Windows SmartScreen may warn on first launch. Verify the release checksums and attestation as described in the README.
- **Safeguards can override a request.** The builder applies protective resolutions for some conflicts (for example a "keep" request that contradicts a debloat target, or physical debloat without consent) and reports them in the build output.
- **Some options conflict.** For example, with Windows Update disabled the Microsoft Store cannot install or update anything ([`SECURITY_OPTIONS.md`](SECURITY_OPTIONS.md)). Use "Check Dependencies" in the GUI or `-StrictDependencyCheck` to see conflicts before building.
- **The WinForms GUI is frozen**; new features land only in the WinUI window.

## Irreversible changes

These are made in the image (or on the installed system by first-logon scripts) and
have no supported in-place undo. The only way back is usually to rebuild the image
without the option and reinstall.

| Change | What happens | Why it cannot be undone in place |
|---|---|---|
| Defender removal (`RemoveDefender`, or the Advanced Debloat target for the same thing) | The engine and payload are removed, service keys deleted, filter drivers taken out of the boot path, the Windows Security UI package removed | It is a removal, not a disable; `Set-MpPreference` cannot switch it back on. A DISM re-add only works if the package payload still exists in WinSxS. Details and steps: [`SECURITY_OPTIONS.md`](SECURITY_OPTIONS.md) |
| WinSxS / Component Store cleanup (`-SafeDebloat` default; `-AggressiveWinSxS` stronger; `-ForceWinSxSCleanup` strongest) | DISM `StartComponentCleanup /ResetBase` and cache pruning; the aggressive mode trims more of the store | `/ResetBase` makes superseded components permanent: installed updates can no longer be uninstalled. Removed components cannot be re-added without a source |
| Physical debloat (Advanced Debloat, Phase 09) | Files are deleted from the mounted image by the Rust tool `tools/winease-physical-debloat` | Deletion is permanent in the produced image. It needs explicit consent (`-AllowPhysicalDebloat` or the equivalent GUI consent); selections in a profile alone do not authorize it |
| Edge, WebView2 post-OOBE removal, Store, Photos, Camera, Snipping Tool, legacy FODs and similar packages | Removed from the image | Some can be reinstalled from the Microsoft Store or Windows optional features if the machine is online and Windows Update works; otherwise they need a reinstall of Windows |
| Recovery environment (WinRE) | Kept during setup, then disabled and deleted on first logon unless `-KeepRecovery` / `-KeepWinRE` | Without WinRE, Reset this PC and the repair tools are not available |
| Hibernation off, crash dumps off | `powercfg /hibernate off`, `CrashDumpEnabled = 0` depending on `HibernateMode` / `CrashDumpMode` | These can be changed back with `powercfg` and registry settings; listed here because blue-screen diagnosis and hibernation are lost until you do |
| Security-relevant options (UAC, Windows Update, blank-password auto-logon, CPU mitigations, ...) | Protections are disabled | Each has documented recovery steps in [`SECURITY_OPTIONS.md`](SECURITY_OPTIONS.md) |

Before you apply any of these to a machine you care about:

1. Build and install in a VM first.
2. Keep a copy of the original ISO and of the profile JSON you built from.
3. Back up the data on the target (the PC migration tool in `tools/migrator` can help).
4. Create a system restore point before changing settings on an installed system; for Defender removal this is the only fast rollback.

## Recovery methods

- **Setup halts with "Windows could not complete the installation":** use the manual recovery procedure in the [README troubleshooting section](../README.md#-troubleshooting-manual-recovery-procedure--fallback) (Shift+F10, set `HKLM\SYSTEM\Setup\Status\ChildCompletion` `setup.exe` to 3, click OK). The README gives both the Registry Editor and the one-line `reg add` variant.
- **A protection was disabled and you want it back:** follow the per-option recovery in [`SECURITY_OPTIONS.md`](SECURITY_OPTIONS.md) (Windows Update, UAC, auto-logon, and so on).
- **Defender or the WinSxS store was removed:** repair install or a clean reinstall from a stock ISO (or a rebuild with those options off). See the table above.
- **The build itself failed:** the builder keeps its working directory on error for troubleshooting, and `-ResumeIsoOnly` can rebuild just the ISO from the payload verified by the previous run. See the README parameter table.
- **Anything else on an installed system:** restore from a restore point or backup if you made one; otherwise reinstall.
