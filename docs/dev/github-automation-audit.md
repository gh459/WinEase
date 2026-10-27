# GitHub automation audit (2026-10-21)

> Note: this audit is a point-in-time record from 2026-10-21. Do not use it for
> current decisions; check the live repository state instead.

Review of the GitHub Actions workflows, the Claude agent, Dependabot and the test setup of
`gh459/WinEase`, with the changes made in the same branch. Baseline: `main` at `79558b9`.

Tools used for the audit: actionlint 1.7.7, zizmor 1.31.1 (offline), PowerShell 7.4.6 with
Pester 3.4.0 and PSScriptAnalyzer 1.25.0 on Linux. Windows-only behaviour (DISM, drive-letter
paths, Windows PowerShell 5.1) can only be confirmed by the Windows CI jobs.

## 1. Starting point

| Item | State on `main` |
|---|---|
| `ci.yml` | push/PR to main, `contents: read`. `-TestSelf` (pwsh), Pester 3.4.0 on Windows PowerShell 5.1 (`tests\`, split by area), `-DryRun -NonInteractive -Profile extreme` (pwsh). |
| `lint.yml` | PSScriptAnalyzer, errors fail the job, `contents: read`. |
| `claude-issue-agent.yml` | `issues: assigned`, `issue_comment`, `pull_request_review_comment`, `pull_request_review`. Workflow-wide `contents/pull-requests/issues: write`, `id-token: write`, `actions: read`. Started for **any** comment containing `@claude`. |
| `release.yml` | `v*` tag: `git archive` of HEAD to a ZIP, `softprops/action-gh-release`. No tests, no checksum, `contents: write` for the whole workflow. |
| `dependabot.yml` | GitHub Actions only, monthly. Cargo (`tools/winease-physical-debloat`) and NuGet (`gui/winui/WinEaseGui/WinEaseGui.csproj`) not covered. |
| Agent definitions | No `.github/agents/`, no Copilot instructions, no `CLAUDE.md`. `.jules/` holds notes of the Jules agent, not configuration (the former `.Jules/` directory has been merged into `.jules/`). |
| Branch protection | Not visible from the repository; must be checked in the GitHub settings (see 7). |
| Rust engine | No CI job compiled it. |
| Tests | 4,669-line Pester suite already covering the schema as single source of truth, GUI toggle wiring, CLI bindings, aliases, presets, dependency conflicts, user extensions, `-ComparePreset`, restore path validation, symbolic links and backup hashes. |

### Findings of the static audit on `main`

zizmor reported 25 findings (9 high): 8 unpinned actions (`@v1`, `@v3`, `@v4`, `@v7`),
`issue_comment` as a dangerous trigger, and persisted checkout credentials in 6 jobs.
actionlint reported nothing.

## 2. Risks found, by priority

| # | Risk | Severity | Status |
|---|---|---|---|
| R1 | Claude agent could be addressed by anyone writing `@claude` on a public repository; only the action's internal write-access check stood in the way, after the runner started with write permissions and the API key. | High | Fixed: `author_association` gate (OWNER/MEMBER/COLLABORATOR) per event type, bots excluded, permissions moved to the job. |
| R2 | Release published without running a single test, from whatever HEAD the tag resolved to, with no checksum. | High | Fixed: release runs CI, lint and workflow audit on the tagged commit, checks the tag did not move, verifies the ZIP, writes SHA-256, attests provenance. |
| R3 | **Tweaks of presets and profiles were ignored.** `Apply-ProfileSettings` collected the tweak layers but never wrote them back (regression of `0560a3c`). `-Profile extreme` built with schema defaults for every tweak (e.g. `ConfigureWinlogon` off although the preset sets it); `TweakSettings` in a JSON profile, including legacy alias names, had no effect. | High | Fixed in `WinEasebuilder.ps1`, regression test added. |
| R4 | A quoted boolean in a profile (`"RemoveDefender": "false"`) was cast with `[bool]` and became **true**. | High | Fixed: `Import-WinEaseProfile` refuses values of the wrong type, regression test added. |
| R5 | Unpinned third-party actions (supply chain). | Medium | Fixed: every action pinned to the commit SHA of its tag, resolved with `git ls-remote` against the official repository; version kept (no major upgrade). Dependabot updates the pins. |
| R6 | `config/WinEase.config.schema.json` rejected every file `-SaveProfile` writes (`additionalProperties: false` without `Settings`), lacked `DebloatEngineSelection`, and four defaults disagreed with `config/schema.psd1` (`MMCSSGaming`, `DisableFSE`, `NvidiaLowLatency`, `ConfigureWinlogon`). | Medium | Fixed; the schema now validates the checked-in profile and a saved profile (`Test-Json`), regression test added. |
| R7 | Persisted `GITHUB_TOKEN` in checkouts of read-only jobs. | Low | Fixed: `persist-credentials: false` everywhere except the agent, which pushes with it. |
| R8 | Cargo and NuGet dependencies without update PRs; Rust never compiled in CI. | Low | Fixed: Dependabot entries and a Windows `cargo build/test --locked` job. |
| R9 | Prompt injection through issue/comment text into the write-capable agent. | Medium | Reduced: trusted authors only, explicit system-prompt rule. Residual risk: a trusted author can still paste hostile text; the agent has `Bash` and a write token by design. |

Not changed, recorded:

- The config snapshot (`logs\*.config.json`) stores `[switch]` variables as `{ "IsPresent": … }`.
  It is a log, not a profile (`-LoadProfile` uses `-SaveProfile` files), so this is cosmetic;
  the regression tests read both forms.
- `lint.yml` installs the newest PSScriptAnalyzer; only errors fail, so a new rule can at most
  add warnings. Pin it if reproducibility matters more than new rules.

## 3. Overlap check (what already existed and was not re-implemented)

| Requirement | Already covered by | Action |
|---|---|---|
| GUI toggle ↔ schema mapping | `WinEase GUI wiring - every toggle is consumed by the build`, `config\schema.psd1 is the single source of truth` | none |
| CLI switch ↔ setting key | `CliSwitch matches a [switch] parameter`, `every CliBindings switch name is a builder parameter or alias` | none |
| Preset keys exist | `built-in preset and phase-read setting keys all exist` | none |
| Legacy aliases | `aliases never shadow a real key`, `legacy tweak aliases point at existing keys` (static) | added the runtime check that an alias actually reaches the build |
| Dependency conflicts | `Test-WinEaseConfigConflicts`, `WinEase dependency checker` (+S2) | none |
| User presets / tweaks | `S1 - user extensions survive -PresetsOnly`, `User Extensibility Engine` | none |
| `-ComparePreset` | `S4 … exits 0 without building` | added: no snapshot written, `-WorkDir` not created |
| Restore path safety, symlinks, backup hashes | `Migration restore - path validation`, `Migration engine S3` | added tamper and `..` escape cases with the existing file left intact |
| PR review by AI | the issue agent answers `@claude` on PRs (on demand, write-capable) | added a separate **read-only** automatic reviewer instead of widening the agent |

## 4. Changes

| File | Change | Impact |
|---|---|---|
| `.github/workflows/claude-issue-agent.yml` | Trusted-author gate per event, bots excluded, job-level permissions with reasons, SHA pins, injection rule in the system prompt. | Comments from non-collaborators no longer start a run. Assignment by a bot account no longer starts it either. Branch / draft PR flow unchanged. |
| `.github/workflows/claude-pr-review.yml` (new) | Read-only review on `pull_request` (no `pull_request_target`), same-repository PRs only, `contents: read` + `pull-requests: write`, tools limited to reading and commenting, WinEase checklist, notice instead of failure without the API key. | One Claude API call per PR push (cost, see 6). Advisory, not a required check. |
| `.github/workflows/workflow-audit.yml` (new) | actionlint (checksum-verified download) and zizmor (exact PyPI version, offline). Runs on changes under `.github/` and from the release. | New check on workflow changes. |
| `.github/zizmor.yml` (new) | Hash-pin policy; `self-repository` disabled (`./.github/workflows/…` is required to test the tagged commit). | – |
| `.github/workflows/ci.yml` | `workflow_call`; self-test on 5.1 and 7; Pester runs both test files with per-test error annotations and an NUnit artifact; dry-run of extreme/balanced/none/vm on 7 and extreme on 5.1; Rust job. | Longer CI (more Windows jobs, in parallel). |
| `.github/workflows/lint.yml` | `workflow_call`, SHA pin, no persisted credentials. | – |
| `.github/workflows/release.yml` | Rewritten as described in 5. | Release only after all checks pass; adds `.sha256` asset and an attestation. |
| `.github/scripts/verify-release-zip.py`, `resolve-tag-commit.sh` (new) | ZIP verification and tag resolution used by the release. | – |
| `.github/dependabot.yml` | Actions grouped; Cargo and NuGet added; monthly. | Up to 5 PRs per ecosystem per month. |
| `WinEasebuilder.ps1` | R3 (tweak layers written back + `Sync-WinEaseTweakVariables`) and R4 (type check). | **Behaviour change:** presets and profiles now apply their tweak settings again, as documented. Profiles with quoted booleans are refused instead of silently misread. |
| `config/WinEase.config.schema.json` | R6. | Editors/validators accept real profiles. |
| `tests/WinEase.Regression.Tests.ps1` (new) | 28 tests, see 5. | Runs in the Pester job. |
| `README.md`, `CHANGELOG.md` | Development automation section, changelog entry. | – |

## 5. Verification

### Regression tests (`tests/WinEase.Regression.Tests.ps1`)

Run as child processes with `-DryRun -NonInteractive` and stdin closed; the effective
configuration is read from the snapshot the dry-run writes. Nothing is mounted or built.

1. every preset of `PresetOrder` resolves (7 tests); preset `TweakSettings` reach the build;
   every alias names a preset; an unknown preset warns and falls back to `extreme`
2. CLI switch wins over `-LoadProfile`; profile wins over `-Profile`
3. `-NonInteractive` finishes with stdin closed, no confirmation prompt
4. legacy flat profile (version 2.0, no `Settings`, legacy tweak names) loads
5. unknown key → warning, no effect
6. malformed JSON, missing file, quoted booleans → non-zero exit
7. `-SaveProfile` → `-LoadProfile` round trip keeps every setting
8. `-ComparePreset` writes no snapshot and creates no work directory
9. JSON schema: every Bool component and tweak present with the schema.psd1 default;
   `Settings` accepted; checked-in profiles validate, wrong types and unknown keys are rejected
10. `Test-IsSafePathToDelete`, `Test-WinEasePathWithin` boundary, tampered backup not restored,
    `..` in a manifest leaves outside files untouched, atomic write leaves no temp file
    (Windows only: drive-letter paths)

Local result (PowerShell 7.4.6, Linux): **24 passed, 0 failed, 4 inconclusive** (the Windows-only
path tests). Verified that R3 and R4 tests fail against the unfixed builder.

### Existing checks, before and after the change (Linux, PowerShell 7)

- Before R1 (monolithic `tests\WinEase.Tests.ps1`): 234 passed / 53 failed on Linux/PowerShell 7; the failed set is
  identical (Windows-only tests: DISM, ACLs, drive letters, `powershell.exe`). The authoritative
  run is the Windows CI job.
- `-TestSelf`: identical results before and after (checks 9, 10, 12, 16 need Windows).
- PSScriptAnalyzer with the repository settings: 0 findings on the changed scripts.
- actionlint: 0 findings. zizmor: 0 findings (3 ignored with inline reasons, 3 suppressed low-confidence).
- `verify-release-zip.py`: passes on `git archive HEAD`; fails on an added `logs/` file and on a truncated ZIP.
- `cargo metadata --locked`: lockfile consistent (the crate itself only compiles on Windows).

### Not run here

- The Windows CI jobs (5.1 Pester run, Windows-only regression tests, Rust build): they run on the pull request.
- The release workflow: needs a `v*` tag. Manual check: push a test tag such as `v0.0.0-rc.test`
  on a fork or delete the resulting release afterwards; expect CI → package → publish, a
  `.sha256` asset, and `gh attestation verify WinEase-<tag>.zip -R gh459/WinEase` to succeed.
- The AI review and agent workflows: need `CLAUDE_CODE_OAUTH_TOKEN` and a PR / comment event.

## 6. Release pipeline

`ci`, `lint`, `audit` (reusable workflows, `contents: read`, on `github.sha`) →
`package` (`contents: read`): checkout of `github.sha`, HEAD = `GITHUB_SHA`, the tag still
resolves to `GITHUB_SHA` (annotated tags dereferenced), clean tree, `git archive $GITHUB_SHA`,
ZIP verification (CRC, file list identical to `git ls-tree` of the commit, required files,
forbidden build/log/key files, token and private-key patterns), SHA-256 →
`publish` (`contents: write`, `id-token: write`, `attestations: write`): checksum and tag
re-checked, provenance attestation, release with ZIP + `.sha256`, uploaded assets downloaded
again and compared.

A checksum detects corruption and mix-ups but proves nothing about origin; the provenance
attestation (free on public repositories) binds the ZIP to this workflow run and commit.

## 7. Open items, costs and settings outside the repository

- **Secrets:** `CLAUDE_CODE_OAUTH_TOKEN` (already used by the agent) is reused by the reviewer. No new service.
- **Cost:** one Claude review per push to a same-repository PR. To limit it, change the trigger
  to `ready_for_review` + `reopened` or add a label condition.
- **Branch protection / rulesets (GitHub settings):** require "WinEase CI", "PSScriptAnalyzer"
  and "Workflow security audit" on `main`; do not require "AI code review (advisory)"; require a
  human approval; disallow force pushes. Consider a tag ruleset restricting who may create `v*` tags.
- **Dependabot alerts / security updates:** enable in Settings → Code security. Every Dependabot
  PR goes through the full CI and a human review; there is no auto-merge.
- **Actions settings:** keep "Allow GitHub Actions to create and approve pull requests" off.
- **Residual risk:** the agent is write-capable with `Bash`; a trusted user can still feed it
  hostile text. Review its draft PRs like any external contribution.

## 8. Current state (2026-10-27)

Snapshot after the GitHub automation cleanup of 2026-10-27. Sections 1-7 are kept as the
point-in-time record above; items they describe may no longer exist (for example
`claude-pr-review.yml` was removed, and the Claude workflows now use a different secret).

| Item | State |
|---|---|
| Workflows | `ci.yml`, `lint.yml`, `workflow-audit.yml`, `release.yml`, `integration-vm.yml`, `auto-resolve-conflicts.yml`, `claude-issue-agent.yml`, `close-failed-agent-prs.yml` |
| Secret for the Claude steps | `ANTHROPIC_API_KEY` (passed as `anthropic_api_key`); `CLAUDE_CODE_OAUTH_TOKEN` is not configured in this repository |
| `auto-resolve-conflicts.yml` | merges `main` into conflicting PRs and starts CI; it **no longer enables auto-merge**, because that made `main` advance by itself and re-ran CI for every open PR on each push |
| `close-failed-agent-prs.yml` | matches the branches the agents actually push (`AGENT_BRANCH_PATTERN`: `claude/`, `jules-`, `perf*`, `refactor*`, `test*`, `bolt-`, `code-health/`) instead of `claude/*` only, which never matched in this repository |
| Agent journals | `.jules/{bolt,sentinel,palette}.md` with `.jules/README.md` defining the entry format |
| Observed run history before the cleanup | `close-failed-agent-prs.yml` 15 runs, all `skipped`; `auto-resolve-conflicts.yml` 13 runs (1 success, 2 failures, rest skipped/cancelled); 21 open PRs kept 21 `WinEase CI` runs queued |
