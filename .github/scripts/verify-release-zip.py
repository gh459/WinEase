#!/usr/bin/env python3
"""Verify a WinEase release ZIP before it is published (used by .github/workflows/release.yml).

Checks:
  1. the archive opens and every member passes its CRC check
  2. the file list is exactly the file list of the verified commit (git ls-tree),
     so nothing stale, generated or local can be in it and nothing is missing;
     duplicate entry names and symbolic-link entries are rejected outright
     (a name set alone would hide both)
  3. the files the builder needs to start are present
  4. no build output, log, key or credential file is included, and no file carries
     an obvious private key or token
  5. every file of the commit has exactly the content of its git blob

With --binaries <list> the ZIP is a full package (tools/package-release.ps1): the source part
is checked as above, and the files that are not part of the commit must be exactly the files
of <list> (sha256sum format: "<sha256>  <path>", the hashes of the CI build output), every one
of them on an allowed binary path (ALLOWED_BINARY_PATTERNS) with the listed hash. The
build-output ban (*/bin/*) is lifted for those allowed paths only.

Usage: verify-release-zip.py [--binaries <list>] <zip> <commit> <prefix>
Exit code 0 = all checks passed; every failure is printed as a GitHub error annotation.
"""
import argparse
import fnmatch
import hashlib
import re
import stat
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
    "config/registry/ai.psd1",
    "config/registry/cloud-content.psd1",
    "config/registry/cross-device.psd1",
    "config/registry/defender.psd1",
    "config/registry/performance.psd1",
    "config/registry/privacy.psd1",
    "config/registry/security.psd1",
    "config/registry/setup.psd1",
    "config/registry/start-search.psd1",
    "config/registry/ui.psd1",
    "lib/WinEaseSelfTest.ps1",
    "lib/WinEasePathSafety.ps1",
    "lib/WinEaseSystem.ps1",
    "lib/WinEaseFileSystem.ps1",
    "lib/WinEaseConfig.ps1",
    "lib/WinEaseBenchmarks.ps1",
    "lib/WinEaseDependencies.ps1",
    "lib/WinEaseGuiSession.ps1",
    "lib/WinEaseBuildPlan.ps1",
    "lib/WinEaseInputValidation.ps1",
    "lib/WinEaseRegistry.ps1",
    "lib/WinEaseGuiCore.ps1",
    "lib/WinEasePlugins.ps1",
    "plugins/README.md",
    "plugins/user/README.md",
    "config/user/plugins.lock.psd1",
    "src/WinEase.Plugins.Abstractions/WinEase.Plugins.Abstractions.csproj",
    "src/WinEase.Plugins.Abstractions/IWinEasePlugin.cs",
    "src/WinEase.Plugins.Abstractions/IWinEaseHost.cs",
    "src/WinEase.Plugins.Abstractions/Models.cs",
    "src/WinEase.Plugins.Abstractions/PluginAssemblyResolver.cs",
    # the official built-in plugins: a source checkout compiles them on first use (plugins/builtin is build output)
    "src/WinEase.Plugins.Builtin.Latency/WinEase.Plugins.Builtin.Latency.csproj",
    "src/WinEase.Plugins.Builtin.Latency/LatencyPlugin.cs",
    "src/WinEase.Plugins.Builtin.PostInstallTools/WinEase.Plugins.Builtin.PostInstallTools.csproj",
    "src/WinEase.Plugins.Builtin.PostInstallTools/PostInstallToolsPlugin.cs",
    "src/WinEase.Plugins.Builtin.UpstreamSync/WinEase.Plugins.Builtin.UpstreamSync.csproj",
    "src/WinEase.Plugins.Builtin.UpstreamSync/UpstreamSyncPlugin.cs",
    "scripts/tools/WinEase Control Center.bat",
    "scripts/tools/Atlas-ReviOS Tools/1. Toggle Windows Defender.bat",
    "scripts/setup/RunFirstLogon.ps1",
    "scripts/tools/Install-Browser.ps1",
    "gui/WinEaseGui.ps1",
    "phases/01-environment.ps1",
    "phases/18-iso.ps1",
    "tools/migrator/WinEaseMigration.ps1",
]

# The only paths a full package may add to the source tree (keep in sync with tools/package-release.ps1).
# Each entry is (pattern, may_contain_subfolders).
ALLOWED_BINARY_PATTERNS = [
    ("WinEase.exe", False),
    ("gui/winui/bin/*", True),
    ("plugins/builtin/*.dll", False),
    ("plugins/builtin/builtin.lock.psd1", False),
]

# What a full package must contain besides the source tree.
REQUIRED_BINARIES = [
    "WinEase.exe",
    "gui/winui/bin/WinEaseGui.exe",
    "plugins/builtin/builtin.lock.psd1",
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


def is_allowed_binary(path):
    for pattern, nested in ALLOWED_BINARY_PATTERNS:
        if fnmatch.fnmatchcase(path, pattern):
            # fnmatch's * also matches "/": outside gui/winui/bin a file must sit directly in its folder
            if nested or path.count("/") == pattern.count("/"):
                return True
    return False


def read_binaries_list(path):
    """Parses a sha256sum style list into ({path: sha256}, [problems])."""
    entries, problems = {}, []
    with open(path, encoding="utf-8") as fh:
        for number, line in enumerate(fh, 1):
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
            if not match:
                problems.append(f"{path} line {number} is not '<sha256>  <path>'")
                continue
            name = match.group(2)
            if name.startswith("./"):
                name = name[2:]
            if name in entries:
                problems.append(f"{path} lists {name} twice")
            entries[name] = match.group(1).lower()
    return entries, problems


def git_blob_sha1(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Verify a WinEase release ZIP.")
    parser.add_argument("--binaries", help="sha256sum style list of the build output a full package may add")
    parser.add_argument("zip")
    parser.add_argument("commit")
    parser.add_argument("prefix")
    args = parser.parse_args()
    zip_path, commit, prefix = args.zip, args.commit, args.prefix
    if not prefix.endswith("/"):
        prefix += "/"
    failures = 0

    listing = subprocess.run(
        ["git", "ls-tree", "-r", "-z", commit],
        check=True, capture_output=True,
    ).stdout.decode("utf-8").split("\0")
    tracked = {}  # path -> blob sha1 (None for a submodule entry)
    for row in listing:
        if not row:
            continue
        meta, path = row.split("\t", 1)
        kind, sha = meta.split(" ")[1:3]
        tracked[path] = sha if kind == "blob" else None

    binaries = {}
    if args.binaries:
        try:
            binaries, problems = read_binaries_list(args.binaries)
        except OSError as exc:
            error(f"{args.binaries} cannot be read: {exc}")
            return 1
        for problem in problems:
            error(problem)
            failures += 1
        for name in binaries:
            if not is_allowed_binary(name):
                error(f"{args.binaries} lists a path that a package may not add: {name}")
                failures += 1
            if name in tracked:
                error(f"{args.binaries} lists a file of the commit: {name}")
                failures += 1
        if not binaries:
            error(f"{args.binaries} is empty")
            failures += 1

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
        seen = set()
        for info in zf.infolist():
            if info.is_dir():
                continue
            # Duplicate entry names: readers disagree on which copy wins (first vs
            # last), so a second entry under an existing name could smuggle content
            # past the per-name checks below. Reject any repeat outright.
            if info.filename in seen:
                error(f"duplicate entry in the archive: {info.filename}")
                failures += 1
                continue
            seen.add(info.filename)
            # Symbolic links: the unix file type lives in the high 16 bits of
            # external_attr (entries written on Windows carry 0 there and pass).
            # A link entry's "content" is its target path, never commit content,
            # and extraction tools may follow it outside the target folder.
            if stat.S_ISLNK(info.external_attr >> 16):
                error(f"symbolic link entry in the archive: {info.filename}")
                failures += 1
                continue
            if not info.filename.startswith(prefix):
                error(f"entry outside the {prefix} prefix: {info.filename}")
                failures += 1
                continue
            names.add(info.filename[len(prefix):])

        extra = sorted(names - set(tracked) - set(binaries))
        missing = sorted(set(tracked) - names)
        for p in extra:
            error(f"not part of commit {commit}: {p}")
        for p in missing:
            error(f"file of commit {commit} missing from the archive: {p}")
        failures += len(extra) + len(missing)

        # a full package: every listed binary is present with the hash of the CI build output
        for p in sorted(binaries):
            if p not in names:
                error(f"binary of the build output missing from the archive: {p}")
                failures += 1
            elif hashlib.sha256(zf.read(prefix + p)).hexdigest() != binaries[p]:
                error(f"{p} differs from the CI build output (SHA-256 mismatch)")
                failures += 1
        if args.binaries:
            for p in REQUIRED_BINARIES:
                if p not in names:
                    error(f"required binary missing: {p}")
                    failures += 1
            dlls = sorted(p for p in binaries if p.startswith("plugins/builtin/") and p.endswith(".dll"))
            if not dlls:
                error("no built-in plugin DLL in the package")
                failures += 1
            lock_name = prefix + "plugins/builtin/builtin.lock.psd1"
            if lock_name in zf.namelist():
                lock = zf.read(lock_name).decode("utf-8", "replace").lower()
                for p in dlls:
                    if binaries[p] not in lock:
                        error(f"builtin.lock.psd1 does not list the SHA-256 of {p}")
                        failures += 1

        for p in REQUIRED:
            if p not in names:
                error(f"required file missing: {p}")
                failures += 1

        for p in sorted(names):
            if p not in binaries and any(fnmatch.fnmatch(p, pat) for pat in FORBIDDEN):
                error(f"file that must not be published: {p}")
                failures += 1
            data = zf.read(prefix + p)
            if tracked.get(p) and git_blob_sha1(data) != tracked[p]:
                error(f"{p} differs from its content in commit {commit}")
                failures += 1
            for pat in SECRET_PATTERNS:
                if pat.search(data):
                    error(f"possible secret ({pat.pattern.decode()[:24]}...) in {p}")
                    failures += 1

    note = f", {len(binaries)} binary file(s) against {args.binaries}" if args.binaries else ""
    print(f"{len(names)} files checked against commit {commit}{note}, {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
