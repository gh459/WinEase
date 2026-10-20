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
