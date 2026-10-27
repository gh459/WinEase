# Security notes for WinEase

WinEase builds a Windows installation image. What ends up inside that image (and in
the folders the build leaves behind) can include secrets. This page is the checklist
to go through **before you share, upload or hand over an ISO, a profile, a log or a
work folder**. The security *options* (what each tweak weakens and how to undo it)
are in [`docs/SECURITY_OPTIONS.md`](docs/SECURITY_OPTIONS.md).

To report a vulnerability in WinEase itself, open a private security advisory on the
GitHub repository (or contact the maintainer) instead of a public issue.

## The account password

* There is **no fixed default password**. `-UserPassword` defaults to an empty string,
  so the local account is created with an empty password unless you pass one
  (`-UserPassword`, or the password field of the GUI). Builds before this change used
  a fixed default password (see "Migration" below).
* A password you set is written, in clear text, into the answer file of the image
  (`autounattend.xml`, `<PlainText>true</PlainText>`, in the ISO and in the image). That is how unattended Windows
  Setup takes it. Anyone who gets the ISO can read it.
* `<AdministratorPassword>` in `autounattend.xml` defaults to an empty value (`<Value></Value>`) with
  `<PlainText>true</PlainText>`. This explicitly leaves the built-in Administrator account disabled without storing a hardcoded password, while satisfying Windows Setup unattended schema requirements.
* The network use of a blank password is blocked in every build
  (`LimitBlankPasswordUse = 1`); an empty password only works at the console.
* The password is **not saved in profiles**: `-SaveProfile` and the GUI never write
  `UserPassword`. If you load an older profile that still contains it, it is used for
  that build and the builder prints a warning; delete the key from the file.
* Set a real password after the first sign-in (`net user <name> <password>`).

## What the first logon cleans up (and what it does not)

When `ConfigureWinlogon` (auto-logon) is on, the image arms `AutoAdminLogon` and the
Winlogon `DefaultPassword`. The first logon then:

* sets `AutoAdminLogon` and `ForceAutoLogon` to 0 and removes `DefaultPassword`, reads
  the values back, and logs `OK` / `FAILED` (never the value) to
  `C:\ProgramData\WinEase\Logs\firstlogon-child.log` (`[AutoLogon-Cleanup]` lines);
* deletes the copies of the answer file that Setup keeps:
  `C:\Windows\Panther\unattend.xml` (also `Panther\unattend` and `Panther\UnattendGC`)
  and `C:\Windows\System32\Sysprep\unattend.xml` (both folders are also cleared of the
  `autounattend.xml` name the build writes), plus the OOBE helper
  `C:\Windows\Setup\Scripts\WinEase-oobe-autologon-repair.ps1` (it holds the password
  as Base64). A file that cannot be deleted is reported as a warning in the same log.

This only protects the **installed system**. It does not change the ISO you built:
the ISO itself permanently contains `autounattend.xml` with the password in plaintext.
**Never assume that post-install cleanup makes an ISO safe to publish or share.**
ISO media and post-install systems have completely different security perimeters.

## High-risk security toggles

WinEase exposes low-level Windows features that intentionally weaken security defenses when enabled:
* **`DisableUAC`**: Bypasses all User Account Control elevation prompts, executing every app with full administrative privileges. This does **not** guarantee gaming or system performance gains.
* **`DisableCPUMitigations`**: Disables speculative execution CPU hardware mitigations (Spectre/Meltdown/etc.), exposing the host to microarchitectural side-channel attacks. Performance gains are unverified and workload-dependent.
* **`ConfigureWinlogon`**: Implants unattended credentials in cleartext within ISO answer files.

Keep these disabled for daily-driver environments.

Not verified: this was checked by automated tests of the script text, not on a real
installation. How Windows Setup behaves with an empty password plus AutoLogon, and
whether the Panther files can be deleted at that point, is untested. After a test
install, read the `[AutoLogon-Cleanup]` lines and look for the files yourself.

## Checklist before you share an ISO

Tick every line, or do not share.

- [ ] **Password**: the ISO was built with an empty password, or you accept that the
      password you used is readable by everyone who gets the ISO (use a throw-away one).
- [ ] **Auto-logon**: `ConfigureWinlogon` is off unless you need it. If it is on, the
      image logs in without a password prompt until the first sign-in.
- [ ] **Answer files**: the build writes the answer file to three places: the ISO root
      (`autounattend.xml`), and inside the image to `Windows\Panther\unattend.xml` and
      `Windows\System32\Sysprep\autounattend.xml`. Open them and check the `<Password>`
      values and account names. Removing the ISO-root copy does not remove the copies
      inside `install.wim`.
- [ ] **Panther copies**: on a machine you installed from the ISO, confirm that
      `C:\Windows\Panther\unattend.xml` and `Sysprep\unattend.xml` are gone before you
      capture that machine as an image or template.
- [ ] **Logs**: `logs\` (builder transcript, `*.config.json` snapshots) and
      `C:\ProgramData\WinEase\Logs` on installed systems. Passwords, tokens and product
      keys are redacted by pattern in the custom-script logs, but read a log before you
      attach it to an issue.
- [ ] **Reports**: `WinEase_report.html` and any exported diagnostics can name your
      machine, paths and the options you chose.
- [ ] **Work directory**: the work folder (default `Documents\WinEase_workspace`) holds
      the mounted/extracted image, including the answer file with the password. Delete
      it, and do not zip it up.
- [ ] **Profiles**: JSON profiles no longer store the password; an old profile may
      still contain `UserPassword`. Remove the key. Check `SourceDrive`, `WorkDir` and
      `UserName` too.
- [ ] **Product keys**: WinEase does not ship a product key. If you added one (answer
      file, a custom script under `config\user`, a post-install tool), remove it from
      the image and from any script you share.
- [ ] **Custom scripts and plugins**: they run with full administrator rights at first
      logon. Share only what you wrote or reviewed, without embedded credentials.

## Migration note

Earlier builds used the fixed default password `WinEase123!` (builder default, answer
file and the Winlogon value). **Every ISO built before this change contains that
password** in `autounattend.xml`, and a machine installed from such an ISO may still
have it as the account password. Change it with `net user <name> <new password>`, treat
those ISOs as non-shareable, and rebuild them.

## Hardening applied (2026-10-26 review remediation)

* **Custom scripts are fail-closed.** If custom scripts are present in
  `C:\Windows\Setup\Scripts\Custom` (first logon) or `...\UserCustom` (per-user)
  but the build-time integrity manifest `custom-scripts-manifest.json` is missing
  or unreadable, **no** custom script is executed; each one is logged as
  `[SECURITY REFUSAL]` instead. This applies to `scripts\FirstLogon.ps1`,
  `scripts\UserOnce.ps1` and the copies embedded in `autounattend.xml`.
* **Browser downloads are signature-checked.** `scripts\tools\Install-Browser.ps1`
  verifies the Authenticode signature of every downloaded installer before
  running it: the signature must be `Valid` and the signer must match the
  expected publisher (Google, Mozilla, Brave, Microsoft; Floorp also accepts
  its own publisher names). A file that fails is deleted and the install aborts.
* **Presets no longer enable auto-logon.** The `extreme`, `fat32`, `handheld`
  and `audio` presets no longer set `ConfigureWinlogon`. Because that option
  embeds credentials in the ISO answer file in clear text, it must now be
  opted into explicitly per build, never via a preset bundle.
* **User tweaks are validated.** Registry actions from `user-tweaks.psd1` are
  restricted to the plugin hive allowlist (`zSYSTEM`, `zSOFTWARE`, `zDEFAULT`,
  `zNTUSER`, `zCOMPONENTS`), persistence-related paths (Run/RunOnce,
  Image File Execution Options, Winlogon) are refused, and service names must
  match a plain service-name pattern.

### Hardening applied, batch 2 (2026-10-26 review remediation)

* **DISM exit-code checks widened.** More DISM call sites now verify the exit
  code and abort the phase on failure instead of continuing silently.
* **Parallel cleanup re-validates paths.** The Phase 05 parallel cleanup
  re-checks that each target still belongs to the scratch area before deleting
  it, instead of trusting the path list captured earlier.
* **oscdimg DNS fallback removed.** The fallback that resolved the download
  host through a public DNS resolver and connected by IP address is gone; the
  download now uses the normal host name and TLS path only (the Authenticode /
  pinned SHA-256 integrity check is unchanged).
* **ExtractUnattend output is confined.** Files extracted from the answer file
  are only written under `C:\Windows\Setup\Scripts\` or the Winhance scripts
  folder (`C:\ProgramData\Winhance\Unattend\Scripts\`, where the shipped answer
  file embeds `Winhancements.ps1`); targets outside those folders are refused.
* **Optional plugin signer pinning.** A user plugin lock entry may carry a
  `SignerThumbprint`; when present, the plugin DLL's Authenticode signer must
  match it in addition to the SHA-256 in the lock file.
* **Secret redaction covers more shapes.** The log redaction patterns now also
  catch quoted values and JSON-style `"password": "..."` pairs, not only
  bare `key=value` forms.
