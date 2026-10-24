# Release package (R10)

A release has three ZIPs: the source ZIP `WinEase-<tag>.zip` (`git archive`, unchanged) and the full packages
`WinEase-<tag>-win-x64.zip` / `WinEase-<tag>-win-arm64.zip`. A full package is the source tree of the commit
plus exactly these build outputs and nothing else:

| Path in the ZIP | Source |
|---|---|
| `WinEase.exe` | `src/WinEase.Launcher` (net48, the same exe for both architectures) |
| `gui/winui/bin/**` | `gui/winui/build.ps1` (self-contained WinUI 3 window, per architecture) |
| `plugins/builtin/*.dll`, `plugins/builtin/builtin.lock.psd1` | `src/WinEase.Plugins.Builtin.*` (the lock file is the SHA-256 allow list the builder checks) |

arm64 is cross-built on the x64 runner (the `binaries` job of `ci.yml`). It is verified like x64 but has not been run on ARM64 hardware.

## How it is built

```
ci.yml  binaries job (x64, arm64)  ->  artifacts binaries-x64 / binaries-arm64
release.yml  package job           ->  .github/scripts/build-release-assets.sh <tag> <commit> <binaries> dist
                                          git archive           -> WinEase-<tag>.zip
                                          find + sha256sum      -> hash list of the CI build output (per arch)
                                          tools/package-release.ps1 -> WinEase-<tag>-win-<arch>.zip (+ .sha256)
                                          verify-release-zip.py [--binaries <list>] on every ZIP
release.yml  publish job           ->  attestation for every ZIP, release with 6 assets, download-and-compare
```

`verify-release-zip.py --binaries <list>` checks that (1) every file of the commit is in the ZIP with exactly its git blob content,
(2) the only other files are the ones in the hash list, (3) each of them sits on an allowed path (`ALLOWED_BINARY_PATTERNS`) and has
the listed SHA-256, and (4) `WinEase.exe`, `WinEaseGui.exe`, the lock file and at least one plugin DLL are there and every plugin DLL
is listed in the lock file. The `*/bin/*` ban stays in force for every other path. `.github/scripts/test-verify-release-zip.py`
(run by the `release-package` job of `ci.yml`) checks that damaged packages are rejected.

## Build one locally

```powershell
.\tools\build-binaries.ps1 -Architecture x64            # needs the .NET 8 SDK
.\tools\package-release.ps1 -Tag v0.0.0-local -Architecture x64   # -> dist\WinEase-v0.0.0-local-win-x64.zip (+ .sha256)
```

## Dry run of the release workflow

Actions > Release > Run workflow (or `gh workflow run release.yml --ref <branch>`; GitHub lists a workflow for manual start once the
file is on the default branch). A manual run does everything except the tag checks and the publish job and keeps the assets as the
`release-package` artifact (7 days). The `release-package` job of `ci.yml` builds and verifies the same assets on every push and PR.

## Check an unpacked package on Windows (manual, not done by CI)

1. Download `WinEase-<tag>-win-x64.zip` and its `.sha256`; compare `Get-FileHash -Algorithm SHA256 <zip>` with the file and run
   `gh attestation verify <zip> -R gh459/WinEase`. Unzip to a normal folder such as `C:\WinEase`.
2. Dry run, no administrator rights needed: in a PowerShell window in the folder run
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\WinEasebuilder.ps1 -DryRun -NonInteractive -Profile balanced`.
   Expect three `[Plugins] Loaded winease.builtin.*` lines (the DLLs are used as shipped, nothing is compiled) and
   `Exiting without modifying images or workspace.` with exit code 0. `-TestSelf` should report all checks passed.
3. Double-click `WinEase.exe`. Expect the UAC prompt, then the WinUI window. Clicking **No** in the UAC prompt must show the error box
   "Admin privileges were not granted (UAC cancelled)" and open no builder window.
4. `WinEase.exe -ClassicGui` (from a terminal in the folder): UAC prompt, then the WinForms window.
5. Error display: rename `WinEasebuilder.ps1` temporarily and start `WinEase.exe`; it must show the error box "Builder script not found" with the expected path.
6. SmartScreen warns on the first start because the exe is not signed (code signing is out of scope).

Done on the development machine for this change: the local build (`build-binaries.ps1 -Architecture x64`, which includes WinUI),
the packaging, `verify-release-zip.py --binaries`, and steps 2 (dry run and `-TestSelf` from the unpacked ZIP). Steps 3 to 5
(UAC, windows, error box) need an interactive session and are not verified.
