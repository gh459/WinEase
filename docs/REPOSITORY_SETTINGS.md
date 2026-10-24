# Repository settings (intended state)

These settings live in GitHub, not in the repository, so a pull request cannot enforce them.
This file records what they should be. **Nothing here is applied by code in this repository.**

## Verified state (read-only, 2026-10-25, `gh` authenticated as `gh459`)

| Query (read-only `gh api`) | Result |
|---|---|
| `repos/gh459/WinEase/branches/main/protection` | HTTP 404 "Branch not protected" |
| `repos/gh459/WinEase/branches/main` (`.protected`) | `false` |
| `repos/gh459/WinEase/rulesets` | `[]` (no rulesets) |
| `repos/gh459/WinEase/actions/permissions/workflow` | `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false` |
| `repos/gh459/WinEase` | public, default branch `main` |

Consequence: **`main` is currently not protected.** The write-capable Claude agent
(`claude-issue-agent.yml`) and every collaborator can push to `main` directly; the workflow only
keeps the agent off `main` through its tool allow-list and prompt, which are not a boundary.
Enable the protection below.

Not verified (not queried or not readable with this token): required-review counts of any future
rule, secret-scanning / push-protection, Dependabot alerts, environments, the list of
collaborators, fork-PR workflow approval policy.

## Intended branch protection (or an equivalent ruleset) for `main`

- Require a pull request before merging; at least 1 approving review; dismiss stale approvals on
  new commits; require approval of the most recent push by someone other than the pusher.
- Require status checks to pass, branch up to date. Required checks (names as shown in the
  Checks tab): `WinEase CI` jobs (self-test, Pester test suite, dry-run, binaries, Rust engine,
  plugin contract), `PSScriptAnalyzer`, `Workflow security audit` (actionlint, zizmor).
- Block force pushes and branch deletion; require linear history (optional); apply to
  administrators too (no bypass for the agent's token or app).
- Restrict who can push to matching branches; the agent pushes only `claude/*` branches.
- Protect `v*` tags with a tag ruleset (restrict creation/update/deletion to maintainers):
  a tag push starts `release.yml`.

## Intended Actions settings

- Workflow permissions: read-only default (already the case); "Allow GitHub Actions to create and
  approve pull requests" off (already the case) unless the agent's draft PRs need it.
- Fork pull requests: require approval for all outside collaborators.
- Allow only actions pinned by SHA (all are; Dependabot keeps pins current).
- Secrets: `ANTHROPIC_API_KEY` only as a repository secret; no environment-less deploy secrets.
