# Security options of WinEase

Every option in this document changes something that Windows protects by default.
The list is intentionally short: each entry says what the build does, what it costs
you and how you get the protection back.

The settings live in `config\schema.psd1` (the single source of truth) and are
reached through the GUI ("Services & Apps" tab), the command line, a preset
(`config\presets.psd1`) or a JSON profile (`-LoadProfile`).

## Rule of thumb

| Situation | Recommended |
|---|---|
| A daily driver | keep Defender and Windows Update on (the `balanced` preset) |
| A build machine or a test VM | the `extreme` preset is fine, the risk is contained |
| A machine that goes to a customer / a colleague | `none` (nothing is removed) |

## The options

### RemoveDefender (GUI: "Remove Windows Defender & Security UI")

* **Default:** off
* **What the build does:** the Defender user-mode service keys are deleted, the
  boot-start filter drivers are taken out of the boot path (`Start=4`, no Early-Launch
  group), and their payload is removed from the image (including the CBS package when
  DISM allows it), the Windows
  Security UI (`Microsoft.SecHealthUI`) package and its staged registration are
  removed with it, and the `SecurityHealth` / SmartScreen IFEO entries are deleted.
  This is a removal, not a disable: `Set-MpPreference` cannot switch it back on.
* **Impact:** the installed system has **no antivirus protection** and no Windows
  Security app. Nothing is downloaded, nothing is scanned, and Windows Update may
  fail or re-stage parts of the platform.
* **Recovery:** there is no supported in-place re-enable. The reliable recovery is a
  repair install or reinstall of Windows. A DISM
  `/Online /Add-Package /PackageName:Microsoft-Windows-Defender-Client-Package~`
  only works if the package payload still exists in `WinSxS`; a system restore point
  is the only fast rollback if one was created before the build.
* **Note:** the `extreme`, `fat32`, `handheld` and `audio` presets still switch this
  on explicitly. Selecting one of them is an explicit choice; the *default* of the
  setting itself is off.
* **Note:** the Advanced Debloat tab has its own target for the same thing
  (`Physical: Defender (complete removal) [~50MB]`). It is a *second* way to ask for the
  removal, not an independent one: while this setting is off, the builder reports the
  conflict and drops the target from the debloat lists, and phase 10 does not disable a
  single Defender service without this setting being on. The target is also not covered
  by the `-AllowPhysicalDebloat` gate, so it never removes the Defender payload on its
  own either.

### DisableWindowsUpdate (GUI: "Disable Automatic Windows Update")

* **Default:** off
* **What the build does:** automatic patching, driver updates and the delivery of
  FoD / language packs are blocked.
* **Impact:** the system never receives security patches on its own. A machine that
  is online for a long time accumulates known vulnerabilities.
* **Recovery:** `Windows Update > Settings > Windows Update > Pause updates` (off)
  or, on the command line, re-enable the `wuauserv` service and the update policy.
* **Dependency:** the Microsoft Store cannot install or update anything while
  Windows Update is disabled. The builder reports this conflict.

### ConfigureWinlogon (GUI: "Configure Winlogon auto-logon" / Security tab)

* **Default:** off
* **The password:** there is no fixed default password. `-UserPassword` defaults to
  an empty string, so the local account has an empty password unless you pass one
  (`-UserPassword`, or the GUI field). The value is not saved in profiles. An older
  profile that still contains `UserPassword` is loaded (compatibility) with a warning
  that recommends removing it.
* **What the build does when on:** the local account is created with the configured
  password (empty by default), `AutoAdminLogon` is armed in the image (the password is
  written to the Winlogon `DefaultPassword` value, empty by default), the OOBE ->
  first session transition is repaired automatically and the auto-logon is torn down
  again after the first sign-in: the first logon sets `AutoAdminLogon` and
  `ForceAutoLogon` to 0, removes `DefaultPassword`, reads the values back and logs the
  result (never the value) to `C:\ProgramData\WinEase\Logs\firstlogon-child.log`. It
  also deletes the copies of the answer file that Setup keeps
  (`C:\Windows\Panther\unattend.xml`, `Panther\unattend`, `Panther\UnattendGC`,
  `C:\Windows\System32\Sysprep\unattend.xml`, and the `autounattend.xml` name the build
  writes into those folders) and the OOBE helper script, which holds
  the password as Base64. A file that cannot be deleted is logged as a warning.
* **Not verified:** how Windows Setup treats an empty account password together with
  an `AutoLogon` section, and that the cleanup can delete the Panther copies while
  Setup is still finishing, was not tested on a real image or VM. Check
  `firstlogon-child.log` (`[AutoLogon-Cleanup]` lines) after a test install.
* **What the build does when off:** the `AutoLogon` section is removed from
  `autounattend.xml`, so the setup does not log in automatically any more, the
  auto-logon helpers are not deployed and the `AutoAdminLogon` values are not
  written into the image. The network use of a blank password stays blocked in both
  cases (`LimitBlankPasswordUse = 1`).
* **Impact when on:** the account has the configured password (none by default)
  during the setup, and the image, its Setup answer-file copies and the OOBE helper
  contain the password in clear text or Base64 until the first sign-in removes them.
  **CRITICAL: First-logon cleanup only cleans the local disk copies inside the installed
  system. It does NOT retroactively remove or sanitize credentials from the generated ISO.**
  An ISO built with a non-empty password permanently contains that password in cleartext:
  do not distribute or share it (see `SECURITY.md`).
* **Residual risk when off:** the local account still has an empty password, so a
  user at the console can sign in without one. Set a password after the first
  sign-in (`net user <name> <password>`). The empty password was not removed from
  the unattend file on purpose: an account without a password element is not
  documented, and a setup that cannot create the account would leave the machine
  unusable.
* **Recovery:** set a password for the account after the first sign-in
  (`net user <name> <password>`) and clear the auto-logon keys
  (`AutoAdminLogon = 0`, `ForceAutoLogon = 0`, remove `DefaultPassword`).

### DisableUAC (GUI: Security tab)

* **Default:** off
* **What the build does:** the User Account Control consent prompts are disabled.
* **Impact:** every process runs with full administrative rights without a prompt.
  This is the single most effective way to make a Windows system vulnerable to
  malware. **Disabling UAC does not guarantee any measurable performance improvement**
  and should never be treated as an optimization tweak.
* **Recovery:** set `ConsentPromptBehaviorAdmin = 5` and `EnableLUA = 1` under
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`.

### EnableScripts (GUI: Security tab)

* **Default:** on (the PowerShell execution policy is relaxed to `RemoteSigned`)
* **What the build does:** the execution policy of the machine is set to
  `RemoteSigned`, so local scripts run without a signature.
* **Impact:** scripts that arrive from the internet still need a signature, but a
  downloaded script that was renamed to `.ps1` runs.
* **Recovery:** `Set-ExecutionPolicy -ExecutionPolicy AllSigned -Scope LocalMachine`.

### DisableCPUMitigations (GUI: Security tab)

* **Default:** off
* **What the build does:** the Spectre / Meltdown speculative execution mitigations
  of the CPU are disabled.
* **Impact:** the system is exposed to hardware speculative-execution side-channel
  vulnerabilities (Spectre, Meltdown, Foreshadow, etc.). **Performance improvements
  are workload-dependent, unmeasured in baseline, and not guaranteed.**
* **Recovery:** `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory
  \SystemAudit` / re-enable the mitigation policies through the Windows Security
  processor mitigation settings.

### PreventDeviceEncryption (GUI: Security tab)

* **Default:** off
* **What the build does:** the automatic device encryption (BitLocker on a small
  partition) is prevented during OOBE.
* **Impact:** the data on the system is not encrypted at rest.
* **Recovery:** turn on BitLocker in the installed system
  (`manage-bde -on C:`).

### RemoveBitLockerFeature (GUI: Privacy tab)

* **Default:** on (the optional feature is removed from the image)
* **Impact:** the BitLocker management tools are missing from the image, so the
  encryption cannot be configured until the feature is added back.
* **Recovery:** `DISM /Online /Add-Capability /CapabilityName:BitLocker~`.

### RemoveWindowsBackup / RemoveWebExperienceHost (GUI: Privacy tab)

* **Default:** on
* **What the build does:** the Windows Backup app and the Web Experience (Widgets)
  host are removed from the image, including the per-user packages that are
  removed after the first sign-in.
* **Impact:** the Windows Backup app and the Widgets board do not work.
* **Recovery:** reinstall the app from the Microsoft Store.

### DisableWindowsAI / DisableRecall (GUI: Privacy tab)

* **Default:** on
* **What the build does:** the Windows AI features, Recall and Click-To-Do are
  disabled and the optional feature is removed from the image.
* **Impact:** no AI features in the shell; the feature cannot be enabled without
  adding the optional package back.
* **Recovery:** `DISM /Online /Add-Capability /CapabilityName:Recall~`.

## The presets

| Preset | Defender | Windows Update | Blank-password auto-logon | AppX bloatware |
|---|---|---|---|---|
| `none` | kept | kept | off | kept |
| `balanced` | kept | kept | off | removed |
| `extreme` | removed | disabled | on | removed |
| `fat32` | removed | disabled | on | removed |
| `handheld` | removed | disabled | on | removed |
| `vm` | kept | kept | off | removed |
| `audio` | removed | disabled | on | removed |

`none` means "nothing is removed or disabled": every removal option is off, every
"Keep ..." option is on and every tweak stays at its default. Only the three
prerequisites of the unattended setup (`BypassHardwareRequirements`,
`BypassNetworkRequirement`, `BypassNRO`) stay enabled.

## What the build prints

The builder prints the active configuration before it starts and warns about the
two options with the widest impact:

```
  - Remove Windows Defender: True
  [!] Defender is removed: the installed system has NO antivirus protection.
      Recovery: Defender cannot be re-enabled in place; use a repair install or reinstall (see docs\SECURITY_OPTIONS.md).
```
