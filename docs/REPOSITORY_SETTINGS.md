# Repository settings (intended state)

These settings live in GitHub, not in the repository, so a pull request cannot enforce them.
This file records what they should be. **Nothing here is applied by code in this repository.**

## Verified state (read-only, 2026-10-27, `gh` authenticated as `gh459`)

| Query (read-only `gh api`) | Result |
|---|---|
| `repos/gh459/WinEase/rulesets` | one ruleset, `test` (id 25870780), enforcement `active` |
| ruleset target | `~DEFAULT_BRANCH` (`main`) only |
| ruleset rules | pull request required (0 approvals), required status checks (below, not strict), no force push (`non_fast_forward`), no deletion, `copilot_code_review` |
| ruleset required checks | `Pester test suite`, `PSScriptAnalyzer`, `Self-test (powershell)`, `Self-test (pwsh)`, `.NET binaries (x64)`, `.NET binaries (arm64)`, `Rust engine (cargo build + test)`, `Plugin contract (dotnet build + xUnit)`, `Release package (dry run)` |
| `repos/gh459/WinEase/branches/main/protection` | HTTP 404 "Branch not protected" (classic protection unused; the ruleset covers `main`) |
| `repos/gh459/WinEase` | public, default branch `main`, `allow_auto_merge: true`, `delete_branch_on_merge: true` |
| `repos/gh459/WinEase/actions/permissions/workflow` | `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false` (2026-10-25) |

Required check names must match the check run names exactly as reported on a PR (no `CI / `
prefix, no unexpanded `${{ matrix.* }}`). A required name that is never reported leaves the PR
waiting forever. `actionlint` / `zizmor` run only for `.github/**` changes and `Dry-run ...` is a
profile matrix, so none of them are required.

Known gaps: the ruleset requires no approving review and has a broad bypass list (repository
roles and several GitHub Apps with `always`), so it does not bind those actors. The ruleset
name is still `test`. A `v*` tag ruleset does not exist.

Not verified (not queried or not readable with this token): secret-scanning / push-protection,
Dependabot alerts, environments, the list of collaborators, fork-PR workflow approval policy.

## Intended branch protection (or an equivalent ruleset) for `main`

- Require a pull request before merging; at least 1 approving review; dismiss stale approvals on
  new commits; require approval of the most recent push by someone other than the pusher.
- Require status checks to pass, branch up to date. Required checks (names as shown in the
  Checks tab): `WinEase CI` jobs (self-test, Pester test suite, dry-run, binaries, Rust engine,
  plugin contract), `PSScriptAnalyzer`, `Workflow security audit` (actionlint, zizmor).
- Enable "Allow auto-merge" only if a human workflow needs it: `auto-resolve-conflicts.yml` no
  longer enables auto-merge (2026-10-27), it starts CI on the updated branch and leaves the merge
  to a person. The repository setting is still `true`, so nothing merges by itself unless a
  workflow or a person asks for it.
- Block force pushes and branch deletion; require linear history (optional); apply to
  administrators too (no bypass for the agent's token or app).
- Restrict who can push to matching branches; the agents push only their own branch prefixes
  (`claude/*`, `jules-*`, `perf*`, `refactor*`, `test*`, `bolt-*`, `code-health/*`).
- Protect `v*` tags with a tag ruleset (restrict creation/update/deletion to maintainers):
  a tag push starts `release.yml`.

## Intended Actions settings

- Workflow permissions: read-only default (already the case); "Allow GitHub Actions to create and
  approve pull requests" off (already the case) unless the agent's draft PRs need it.
- Fork pull requests: require approval for all outside collaborators.
- Allow only actions pinned by SHA (all are; Dependabot keeps pins current).
- Secrets: `ANTHROPIC_API_KEY` (API key, billed per token) only as a repository secret; no
  environment-less deploy secrets. The `CLAUDE_CODE_OAUTH_TOKEN` variant (Claude subscription
  quota) is not configured here, so the workflows pass `anthropic_api_key`.

## Automated agents and their workflows

| Workflow | Trigger | What it does | Branch / secret |
|---|---|---|---|
| `claude-issue-agent.yml` | issue assigned to `vars.CLAUDE_AGENT_ASSIGNEE`, `@claude` in a comment or review (trusted authors only) | implements the request and opens a draft PR | pushes `claude/*`, `ANTHROPIC_API_KEY` |
| `auto-resolve-conflicts.yml` | push to `main`, manual | merges `main` into conflicting PRs, resolves conflicts with Claude, starts CI (no auto-merge) | `ANTHROPIC_API_KEY` |
| `close-failed-agent-prs.yml` | `WinEase CI` completed, manual | closes an agent PR whose CI failed and deletes its branch (`AGENT_BRANCH_PATTERN`) | `GITHUB_TOKEN` only |
| `ci.yml`, `lint.yml`, `workflow-audit.yml` | PR / push / release | tests, PSScriptAnalyzer, actionlint + zizmor | `GITHUB_TOKEN`, read-only |
| `release.yml` | `v*` tag | runs the checks on the tagged commit, verifies the ZIP, publishes + attests | `contents: write` |

The agent journals in `.jules/` are notes, not configuration (see `.jules/README.md`).

## Automated agent security boundary (`claude-issue-agent.yml`)

1. **Branch Isolation**: The agent workflow is prohibited from pushing directly to `main`. All
   agent-generated work must land on an ephemeral agent branch (`claude/*` for this workflow,
   `jules-*` / `perf*` / `refactor*` / `test*` / `bolt-*` / `code-health/*` for the other agents) and
   undergo human code review via pull requests before merging.
2. **Secret Perimeter**: The automated agent operates strictly with `GITHUB_TOKEN` read/contents-write permissions on matching branches. It has zero access to release publishing tokens, signing keys, or self-hosted integration runner credentials.
3. **Execution Safety**: Tests or scripts submitted or altered in issue threads must never be executed within runners containing ambient credentials or elevated privileges.
4. **Untrusted Input Handling**: Issue and PR contents from external contributors are treated strictly as untrusted user data, never as system instructions or workflow override commands.
5. **Runner Isolation**: Automated agent workflows run exclusively on disposable, ephemeral GitHub-hosted runners; they must never run on self-hosted or integration hypervisor infrastructure.
