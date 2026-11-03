# Sentinel's Journal

Security notes from the Sentinel agent. Newest entry first; format in `README.md`.

## 2026-10-30 - Path traversal normalization bypasses in plugin image file validation

**Vulnerability:** In `src/WinEase.Plugins.Abstractions/IWinEaseHost.cs`, `CheckRelativePath` only split on directory separators and checked `part == ".."`. This allowed path traversal bypasses via URL-encoded sequences (`%2e%2e` or `%2e%2e%2f`), embedded null bytes (`\0`), and Windows path normalization quirks where trailing spaces and dots (e.g. `.. `, `...`) are normalized or stripped by Win32 APIs to escape the intended directory tree.
**Learning:** Checking literal string equality for `"..\ "` or `"../"` is insufficient when OS path normalization or upstream decoders strip whitespace/dots or handle percent-encoded/null characters.
**Prevention:** URL-unescape paths (`Uri.UnescapeDataString`), reject null bytes (`\0`), and check segments for trailing space stripping and dot-only patterns before filesystem operations.

## 2026-10-22 - PowerShell command injection in custom script execution

**Vulnerability:** In `scripts/FirstLogon.ps1`, `scripts/UserOnce.ps1`, and embedded setup scripts in `autounattend.xml`, user custom script paths `$scriptPath` were interpolated directly into child `powershell.exe -Command "& { ... & '$scriptPath' ... }"` string invocations without escaping single quote characters. If a custom script path contained single quotes (e.g. `C:\Custom'Scripts\hook.ps1`), it could escape the single-quoted string literal and trigger arbitrary PowerShell code execution.
**Learning:** Interpolating paths into PowerShell script blocks wrapped in single quotes inside `-Command` strings is vulnerable to single-quote escaping command injection if path names contain quotes.
**Prevention:** Always escape single quotes in file paths (e.g., `$escapedScriptPath = $scriptPath -replace "'", "''"`) before interpolating into single-quoted string literals in child PowerShell commands.

## 2026-10-20 - HTML injection / XSS in HTML build report generation

**Vulnerability:** Dynamic properties provided to `Export-WinEaseHtmlReport` (such as build titles, profile names, timestamp, path names, etc.) were interpolated directly into the HTML string builder without HTML encoding, enabling Cross-Site Scripting (XSS) or HTML injection if untrusted inputs were passed in `$BuildInfo`.
**Learning:** HTML build reports generated from user-configurable profiles or dynamic environment metadata must sanitize/encode dynamic strings before string building.
**Prevention:** Use `[System.Net.WebUtility]::HtmlEncode([string]$text)` when formatting dynamic values into HTML content.
