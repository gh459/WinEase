# WinEase Pester tests

The suite targets **Pester 3.4** on **Windows PowerShell 5.1**, the same versions as the
`pester` job in `.github/workflows/ci.yml`. It does not use Pester 5 syntax.

## Layout

| File | Area |
|---|---|
| `_TestCommon.ps1` | Shared repository paths and the English UI default. Dot-sourced; not a test file. |
| `Layout.Tests.ps1` | Repository layout and folder structure. |
| `Build.Tests.ps1` | Builder AST, unattend, IME filter, DryRun, diagnostics, registry additions, tweak helper. |
| `Config.Tests.ps1` | Schema, presets, dependency catalog, user extensions, UI preference table. |
| `Helpers.Tests.ps1` | Path safety, ACLs, DISM, registry hives, telemetry, logging, shared helpers. |
| `Debloat.Tests.ps1` | Defender, AppX, security options, physical/advanced debloat. |
| `Migration.Tests.ps1` | Migration engine, Migrator, restore validation, removal/migration wiring. |
| `Gui.Tests.ps1` | WinForms/WinUI wiring, GUI smoke test, display language, UI options. |
| `Quality.Tests.ps1` | PSScriptAnalyzer and documentation path checks. |
| `Registry.Tests.ps1` | Phase 10 registry snapshots per preset (`fixtures/registry`), `Invoke-WinEaseReg`, the `config/registry` tables. `_RegistryHarness.ps1` is its shared setup. |
| `Plugins.Tests.ps1` | Plugin host (`lib/WinEasePlugins.ps1`): SHA256 allow list, hooks, OnError, DryRun, contributions. Compiles test DLLs on the fly against `src/WinEase.Plugins.Abstractions`. |
| `WinEase.Regression.Tests.ps1` | Child-process builder regressions; self-contained. |

All test files live directly under `tests\`. Do not create subdirectories: some tests use
`Split-Path -Parent $PSScriptRoot` to find the repository root.

## Run

```powershell
# Full suite (same as CI)
Invoke-Pester -Path .\tests

# Counts for a before/after comparison
Invoke-Pester -Path .\tests -PassThru -Quiet

# Fast local loop: skips integration-heavy Describes tagged slow
Invoke-Pester -Path .\tests -ExcludeTag slow

# One area
Invoke-Pester -Path .\tests\Helpers.Tests.ps1

# One test name (wildcards work)
Invoke-Pester -Path .\tests\Helpers.Tests.ps1 -TestName '*DISM*'
```

CI runs the full suite. The fast suite is a local convenience, not a CI gate.

## Adding tests

1. Put the test in the area file above, in a `Describe` block.
2. If it starts a child PowerShell, builds a WinForms form, creates long/deep trees or
   temporary migration backups, or runs PSScriptAnalyzer, tag the owning `Describe`:
   `Describe "..." -Tags 'slow' { ... }`. Pester 3.4 has no `It -Tags`.
3. Keep the Pester 3.4 syntax: `Should Be`, `Should BeGreaterThan`, `Should Throw` (no dashes).
4. Keep the file ASCII-only, UTF-8 without BOM, LF line endings.
5. New test files need the `PSUseDeclaredVarsMoreThanAssignments` file-level suppression
   used by the existing files. Add `PSAvoidUsingInvokeExpression` only if the file uses
   `Invoke-Expression`.
6. If the test is a new area, add a `*.Tests.ps1` file and update the table above.

## Notes

- Pester 3.4 discovers only `*.Tests.ps1` under `-Path`. `_TestCommon.ps1` is dot-sourced and
  is intentionally not named `*.Tests.ps1`.
- `WinEase.Regression.Tests.ps1` is included by `Invoke-Pester -Path .\tests`; it can also be
  run alone. Its four Describes are tagged `slow` because they start the builder.
- The docs path test (`Quality.Tests.ps1`) checks inline backtick paths in `README.md`,
  `CHANGELOG.md` and the extensibility guides. Keep those paths real.
