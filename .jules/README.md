# Agent journals (`.jules/`)

Notes written by the automated coding agents that open pull requests against this repository.
They are **documentation, not configuration**: nothing here is read by CI, by the workflows or by
the builder. They exist so the next run of the same agent does not repeat a mistake or a
measurement, and so a human reviewer can see why a change was made.

| File | Agent | Scope | Branch prefixes |
|---|---|---|---|
| `bolt.md` | Bolt | performance measurements and PowerShell/allocations lessons | `perf/`, `perf-` |
| `sentinel.md` | Sentinel | security findings (injection, encoding, secret handling) | security fixes, `code-health/` |
| `palette.md` | Palette | WinUI 3 accessibility and UI behaviour | `test/`, `refactor/` (UI parts) |

Jules is the umbrella agent that opens the `jules-*` pull requests; its review notes end up in the
journal of the topic it worked on.

## Entry format

Newest entry first. One `##` heading per entry, then the labelled fields of the journal:

```markdown
## YYYY-MM-DD - Short title

**Learning:** what was measured or discovered (numbers where available).
**Action:** what to do differently next time.
```

`sentinel.md` uses **Vulnerability / Learning / Prevention** instead of Learning / Action.

## Rules

- Append new entries at the top; do not rewrite older ones except to fix a typo or a dead link.
- Do not copy secrets, tokens, user names or machine-specific paths into a journal.
- Keep entries short: one lesson per heading, with the measurement that justifies it.
- If an entry becomes obsolete (the code was removed), mark it `(obsolete)` in the heading instead
  of deleting it.
