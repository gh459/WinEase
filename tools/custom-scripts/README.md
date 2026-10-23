# Custom Post-Install Scripts

Place custom automation scripts in this folder and they will be executed during initial Windows setup.

## Privilege Separation: Elevated (Admin) vs Non-Elevated (User)

To ensure minimum necessary privileges (Principle of Least Privilege), scripts are segregated into two distinct contexts:

### 1. Elevated Administrator Context (`tools/custom-scripts/`)
- **Location**: Put scripts into `tools/custom-scripts/FirstLogon/` (scripts placed directly in `tools/custom-scripts/` are still treated as FirstLogon).
- **Timing**: Executed sequentially at first logon via `FirstLogon.ps1` with **Full Administrator Privileges**.
- **Use for**: System-level drivers, Windows services, scheduled tasks, firewall rules, machine-wide software installation.
- **Log**: `C:\ProgramData\WinEase\Logs\custom-scripts.log`.

### 2. Standard User Context (`tools/custom-scripts/UserOnce/`)
- **Location**: Put scripts inside `tools/custom-scripts/UserOnce/` (the older `tools/custom-scripts/user/` folder is still treated as UserOnce).
- **Timing**: Executed after the user profile is initialized via `UserOnce.ps1` with **Standard Non-Elevated User Rights**.
- **Use for**: Per-user configurations, desktop shortcuts, taskbar pins, user environment variables, user registry keys (`HKCU`).
- **Log**: `%TEMP%\UserOnce-custom.log`.

### 3. Build-time stages
- `tools/custom-scripts/PreBuild/` and `tools/custom-scripts/OfflineImage/` hold `.ps1` scripts that run on the build machine before the build / against the mounted image.

---

## Supported File Types

| Extension | Execution Engine |
| :--- | :--- |
| `.ps1`  | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File <script>` |
| `.bat`  | `cmd.exe /c "<script>"` |
| `.cmd`  | `cmd.exe /c "<script>"` |
| `.reg`  | `reg.exe import <script>` |

---

## Security & Tamper Protection

1. **SHA-256 Manifest Verification**:
   During ISO creation (Phase 11), a cryptographic manifest (`custom-scripts-manifest.json`) is generated recording the SHA-256 hash of each custom script. At first logon, before any script is executed, its hash is verified against the build manifest. If an unauthorized script is injected or an existing script has been tampered with, execution is refused with a `[SECURITY REFUSAL]` log notice.

2. **Secret Redaction**:
   All log outputs automatically redact sensitive patterns such as passwords, tokens, API keys, and product keys with `[REDACTED]`.

3. **Resilience**:
   A failing script will not abort the pipeline; subsequent scripts continue to execute, and the failure details (exit code, error reason, duration) are recorded in the log file.

---

## Naming Convention

Use a numeric prefix to control execution order:

```text
tools/custom-scripts/
├── 01-configure-services.ps1
├── 10-install-packages.cmd
├── 20-security-hardening.reg
└── user/
    ├── 01-set-wallpaper.ps1
    └── 10-user-preferences.reg
```

The number prefix is the execution order: the scripts of a stage are run sorted by file name.

---

## Managing Scripts In The GUI (Tab 10 — Custom Scripts)

`WinEasebuilder.ps1 -GUI` (and the WinUI window) have a **10. Custom Scripts** tab:

| Action | What it does |
| :--- | :--- |
| **Add Script...** | Copies `.ps1` / `.bat` / `.cmd` / `.reg` files into the stage folder and gives them the next free number prefix. |
| **Remove** | Deletes the selected script from the repository (README and `.gitkeep` are protected). |
| **Edit Metadata** | Writes the metadata header into the file (see below). |
| **Change Order** | Renames the file with a new number prefix. |
| **Image Preview** | Shows which file ends up where in the image and with which rights. |
| **Open Folder** | Opens the stage folder in Explorer. |

The tab writes into the repository, not into an image: run the build again to bundle the change.

---

## Metadata Header

A script may start with a metadata header. The comment syntax follows the file type:

* `.ps1` → `#`
* `.bat` / `.cmd` → `REM`
* `.reg` → `;`

```powershell
# @WinEase-Id: configure-services
# @WinEase-Stage: FirstLogon
# @WinEase-Order: 10
# @WinEase-Condition: DisableWindowsUpdate
# @WinEase-OnError: Warn
# @WinEase-Description: Stops the services that are not needed
```

```bat
REM @WinEase-Order: 10
REM @WinEase-Description: Installs the tools
```

```reg
; @WinEase-Order: 20
; @WinEase-Description: Explorer settings
```

| Key | Meaning |
| :--- | :--- |
| `@WinEase-Id` | Name used in the log (default: the file name). |
| `@WinEase-Stage` | Stage of the script; the folder wins when it is set. |
| `@WinEase-Order` | Execution order. Without it the number prefix of the file name decides. |
| `@WinEase-Condition` | Name of a tweak switch: the script only runs when the switch is on. |
| `@WinEase-OnError` | `Stop` (abort the stage), `Warn` (default), `Ignore`. |
| `@WinEase-Description` | Text shown in the GUI. |

---

## Where The Scripts Run

The scripts are copied **flat** into the image — the pipelines read their folder with a
non-recursive `Get-ChildItem -File`, so a script in a sub folder never runs:

| Stage | Folder in the image | Runs as |
| :--- | :--- | :--- |
| `FirstLogon` | `C:\Windows\Setup\Scripts\Custom` | Administrator, at first logon |
| `UserOnce` | `C:\Windows\Setup\Scripts\UserCustom` | Standard user, after the profile exists |

`FirstLogon` `.ps1` scripts are additionally registered as `FirstLogonCommands` in
`autounattend.xml` (from `C:\Windows\Setup\Scripts\Custom\FirstLogon`), so they also run during
the OOBE pass. Every copied file is written into `custom-scripts-manifest.json` with its SHA-256
hash; a file that is not listed there is refused at first logon.

Scripts declared in `config/user/user-tweaks.psd1` (`CustomScripts`) are copied into the same
folders and registered in the manifest as well — a relative `Path` is resolved against the
repository root.
