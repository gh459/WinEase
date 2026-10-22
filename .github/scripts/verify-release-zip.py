#!/usr/bin/env python3
"""Verify a WinEase release ZIP before it is published (used by .github/workflows/release.yml).

Checks:
  1. the archive opens and every member passes its CRC check
  2. the file list is exactly the file list of the verified commit (git ls-tree),
     so nothing stale, generated or local can be in it and nothing is missing
  3. the files the builder needs to start are present
  4. no build output, log, key or credential file is included, and no file carries
     an obvious private key or token

Usage: verify-release-zip.py <zip> <commit> <prefix>
Exit code 0 = all checks passed; every failure is printed as a GitHub error annotation.
"""
import fnmatch
import re
import subprocess
import sys
import zipfile

REQUIRED = [
    "WinEasebuilder.ps1",
    "WinEasehelpers.ps1",
    "WinEase-GUI.bat",
    "autounattend.xml",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "config/schema.psd1",
    "config/presets.psd1",
    "config/dependencies.psd1",
    "config/WinEase.config.schema.json",
    "lib/WinEaseSelfTest.ps1",
    "gui/WinEaseGui.ps1",
    "phases/01-environment.ps1",
    "phases/18-iso.ps1",
    "tools/migrator/WinEaseMigration.ps1",
]

# Build output, logs and credentials (.gitignore keeps most of them out of the commit; this
# is the second line of defence for the published archive).
FORBIDDEN = [
    "logs/*", "build_diagnostics/*", "WinEase_workspace/*", "*/target/*", "*/bin/*", "*/obj/*",
    "*.iso", "*.wim", "*.esd", "*.swm", "*.vhdx", "*.iso.sha256",
    "*.local.ps1", "WinEase_report.html",
    ".env", "*/.env", "*.pfx", "*.p12", "*.pem", "*.key", "id_rsa*", "*/id_rsa*", "*.kdbx",
]

SECRET_PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{36,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{50,}\b"),
    re.compile(rb"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),
    re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
]


def error(msg):
    print(f"::error title=Release ZIP verification::{msg}")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    zip_path, commit, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
    if not prefix.endswith("/"):
        prefix += "/"
    failures = 0

    tracked = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", "-z", commit],
        check=True, capture_output=True,
    ).stdout.decode("utf-8").split("\0")
    tracked = {p for p in tracked if p}

    try:
        zf = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError) as exc:
        error(f"{zip_path} cannot be opened: {exc}")
        return 1

    with zf:
        bad = zf.testzip()
        if bad is not None:
            error(f"CRC check failed for {bad}")
            failures += 1

        names = set()
        for info in zf.infolist():
            if info.is_dir():
                continue
            if not info.filename.startswith(prefix):
                error(f"entry outside the {prefix} prefix: {info.filename}")
                failures += 1
                continue
            names.add(info.filename[len(prefix):])

        extra = sorted(names - tracked)
        missing = sorted(tracked - names)
        for p in extra:
            error(f"not part of commit {commit}: {p}")
        for p in missing:
            error(f"file of commit {commit} missing from the archive: {p}")
        failures += len(extra) + len(missing)

        for p in REQUIRED:
            if p not in names:
                error(f"required file missing: {p}")
                failures += 1

        for p in sorted(names):
            if any(fnmatch.fnmatch(p, pat) for pat in FORBIDDEN):
                error(f"file that must not be published: {p}")
                failures += 1
            data = zf.read(prefix + p)
            for pat in SECRET_PATTERNS:
                if pat.search(data):
                    error(f"possible secret ({pat.pattern.decode()[:24]}...) in {p}")
                    failures += 1

    print(f"{len(names)} files checked against commit {commit}, {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
