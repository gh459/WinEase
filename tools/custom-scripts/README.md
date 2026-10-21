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
   During ISO creation (Phase 11), a manifest (`custom-scripts-manifest.json`) is generated recording the SHA-256 hash of each custom script. At first logon (and in `UserOnce.ps1`), before any script is executed, its hash is verified against the build manifest by the shared check `WinEaseCustomScriptIntegrity.ps1`. The check is **fail-closed**: a script runs only with a matching entry. A missing, empty or malformed manifest, an entry without a valid hash, a hash mismatch, a file that is not listed, a file outside the script folder, a symbolic link, or a missing integrity check all refuse execution with a `[SECURITY REFUSAL]` log notice. Without any custom script no manifest is written and nothing runs.
   A copy or hash that fails at build time stops the build. Scripts staged by the M2 stage runner (`FirstLogon` / `UserOnce` entries of `config/user`) go through the same pipelines and the same manifest; two different scripts with the same file name stop the build.
   **Limits**: the hash only shows that the file is the one the build recorded. It does not prove who wrote the script, and it does not protect against anyone who can change both the script and the manifest (an administrator of the installed system, or anyone who can modify the ISO or the image). Protect the ISO itself (trusted storage, checksum of the ISO) if that matters for you.

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
