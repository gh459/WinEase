# Custom Post-Install Scripts

Place custom automation scripts in this folder and they will be executed
**sequentially (alphabetical order) at the end of first logon** by the
nano11 first-logon pipeline (see `FirstLogon.ps1` → `Custom Post-Install User
Scripts Execution Hook` in the embedded unattend scripts).

## Supported file types

| Extension | How it runs |
| :--- | :--- |
| `.ps1`  | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File <script>` |
| `.bat`  | `cmd.exe /c "<script>"` |
| `.cmd`  | `cmd.exe /c "<script>"` |
| `.reg`  | `reg.exe import <script>` |

Scripts run in the first-logon session with administrator rights. Wrap risky
work in `try/catch` - a failing script will not abort the pipeline, but its
error is recorded in `C:\ProgramData\nano11\Logs\firstlogon-child.log`.

## Naming convention

Use a numeric prefix to control order, e.g.:

```text
01-disable-hibernation.reg
10-install-winget-apps.ps1
20-restore-vm-support.ps1
```

Files are copied into the image at build time (`C:\Windows\Setup\Scripts\Custom`)
and run on every installation created with that ISO.

## Example

See `example.ps1.disabled` - remove the `.disabled` suffix to activate the
snippet.
