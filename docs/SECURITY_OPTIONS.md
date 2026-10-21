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
* **What the build does:** the Defender services are disabled and their payload is
  removed from the image, the Windows Security UI package is removed with it and the
  `SecurityHealth` / SmartScreen IFEO entries are deleted.
* **Impact:** the installed system has **no antivirus protection**. Nothing is
  downloaded, nothing is scanned, and the re-enable of Defender after an update is
  not guaranteed.
* **Recovery:** on the installed system, as administrator:
  ```powershell
  Set-MpPreference -DisableRealtimeMonitoring $false
  sc.exe config WinDefend start= delayed-auto
  sc.exe config WdBoot start= boot
  sc.exe config WdNisSvc start= delayed-auto
  ```
  A system restore point or a reinstall of the Defender platform payload
  (`DISM /Online /Add-Package /PackageName:Microsoft-Windows-Defender-Client-Package~`)
  repairs a removed payload.
* **Note:** the `extreme`, `fat32`, `handheld` and `audio` presets still switch this
  on explicitly. Selecting one of them is an explicit choice; the *default* of the
  setting itself is off.

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
* **What the build does when on:** the local account is created with an empty
  password, `AutoAdminLogon` is armed in the image, the OOBE -> first session
  transition is repaired automatically and the auto-logon is torn down again after
  the first sign-in.
* **What the build does when off:** the `AutoLogon` section is removed from
  `autounattend.xml`, so the setup does not log in automatically any more, the
  auto-logon helpers are not deployed and the `AutoAdminLogon` values are not
  written into the image. The network use of a blank password stays blocked in both
  cases (`LimitBlankPasswordUse = 1`).
* **Impact when on:** the account has no password during the setup, and the image
  contains the auto-logon keys until the first sign-in removes them.
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
  malware.
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
* **What the build does:** the Spectre / Meltdown mitigations of the CPU are
  disabled, which removes a small performance cost and a real protection.
* **Impact:** the system is exposed to the speculative-execution side channels.
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

`BypassNRO` and `BypassNetworkRequirement` control one and the same setting: the
`OOBE\BypassNRO` value of the installed system, the matching command in the specialize
pass of `autounattend.xml` (x64 and ARM64) and `Setup\LabConfig\BypassNRO`. Both default to
on. When either of them is switched off (GUI, `-BypassNRO:$false`,
`-BypassNetworkRequirement:$false`, `-TweakSettings` or a profile), none of these is written
and the specialize command is not added to the generated answer file.

### How autounattend.xml is built

`autounattend.xml` in the repository is a base template with only what every build
needs (no BypassNRO command, no AutoLogon section, no time zone or keyboard, and
`{{UserName}}` / `{{ComputerName}}` placeholders). Every optional parameter or attribute
is declared in `config\unattend-fragments.psd1` and added through the XML DOM by
`lib\WinEaseUnattendComposer.ps1` when its switch is on. A fragment tied to an existing
switch (BypassNRO, ConfigureWinlogon, SetJapaneseKeyboard) follows it; a fragment
without one gets its own switch `Unattend.<Id>` on the GUI tab "10. Answer File". A
fragment never overwrites an element that is already there, and an invalid definition
stops the build. The user and computer names are checked with the same rules as in the
GUI and are written as XML text, never as markup.

## Custom post-install scripts (integrity manifest)

Scripts from `tools\custom-scripts` (and the `FirstLogon` / `UserOnce` scripts of the
extension engine) are copied into the image, and their SHA-256 values are written to
`C:\Windows\Setup\Scripts\custom-scripts-manifest.json`. `FirstLogon.ps1` (elevated) and
`UserOnce.ps1` (standard user) both use the same check,
`C:\Windows\Setup\Scripts\WinEaseCustomScriptIntegrity.ps1`. A script runs only when the
manifest is readable and valid as a whole and lists that file with the same hash. Anything else is
refused and logged as `[SECURITY REFUSAL]` (fail-closed), including a missing or broken copy of the check
itself. A build without custom scripts writes no manifest; the pipelines then find no file and
run nothing.

**What it guarantees:** the file that runs is byte for byte the file the build recorded.
**What it does not guarantee:** that the author is trustworthy, or protection against anyone who can
change both a script and the manifest (an administrator of the installed system, or whoever can
modify the ISO). The manifest is not signed. Keep the ISO in trusted storage and compare its
checksum if that matters for you.

## What the build prints

The builder prints the active configuration before it starts and warns about the
two options with the widest impact:

```
  - Remove Windows Defender: True
  [!] Defender is removed: the installed system has NO antivirus protection.
      Recovery: 'Set-MpPreference -DisableRealtimeMonitoring $false' and 'sc.exe config WinDefend start= delayed-auto' (see docs\SECURITY_OPTIONS.md)
```
