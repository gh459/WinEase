## 2026-10-20 - HTML Injection / XSS in HTML Build Report Generation
**Vulnerability:** Dynamic properties provided to `Export-WinEaseHtmlReport` (such as build titles, profile names, timestamp, path names, etc.) were interpolated directly into the HTML string builder without HTML encoding, enabling Cross-Site Scripting (XSS) or HTML injection if untrusted inputs were passed in `$BuildInfo`.
**Learning:** HTML build reports generated from user-configurable profiles or dynamic environment metadata must sanitize/encode dynamic strings before string building.
**Prevention:** Use `[System.Net.WebUtility]::HtmlEncode([string]$text)` when formatting dynamic values into HTML content.
