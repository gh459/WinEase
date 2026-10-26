#!/usr/bin/env python3
"""Negative tests for verify-release-zip.py --binaries (run by the "release-package" job of ci.yml).

Usage: test-verify-release-zip.py <full-package.zip> <binaries-list> <commit>
Takes a package that passes the verifier, damages a copy of it in several ways and expects the
verifier to reject every copy. Exit code 0 = the unchanged package passes and every damaged copy fails.
"""
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.path.join(HERE, "verify-release-zip.py")
PREFIX = "WinEase/"


def verify(zip_path, listing, commit):
    run = subprocess.run(
        [sys.executable, "-I", VERIFIER, "--binaries", listing, zip_path, commit, "WinEase"],
        capture_output=True, text=True,
    )
    return run.returncode


def damaged_copy(src, dst, change):
    """Copies src to dst, letting change(name, data) -> data|None rewrite or drop members; change(None, None) -> [(name, data)] adds some."""
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            if info.is_dir():
                continue
            data = change(info.filename, zin.read(info.filename))
            if data is not None:
                zout.writestr(info.filename, data)
        for name, data in change(None, None) or []:
            zout.writestr(name, data)


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    package, listing, commit = sys.argv[1:4]
    failures = 0

    if verify(package, listing, commit) != 0:
        print("::error title=Verifier self-test::the unchanged package was rejected")
        return 1

    def flip(name):
        def change(n, data):
            if n is None:
                return None
            return data[:-1] + bytes([data[-1] ^ 1]) if n == PREFIX + name else data
        return change

    def add(name):
        def change(n, data):
            return [(PREFIX + name, b"x")] if n is None else data
        return change

    def drop(name):
        def change(n, data):
            if n is None:
                return None
            return None if n == PREFIX + name else data
        return change

    cases = {
        "a binary differs from the CI build output": flip("WinEase.exe"),
        "a WinUI file differs from the CI build output": flip("gui/winui/bin/WinEaseGui.exe"),
        "a source file differs from the commit": flip("README.md"),
        "a plugin DLL that is not in the build output": add("plugins/builtin/Evil.dll"),
        "a file in a folder that is not allowed": add("scripts/Evil.dll"),
        "an extra file under plugins/builtin that is not a DLL": add("plugins/builtin/readme.txt"),
        "a build log": add("logs/build.log"),
        "the launcher is missing": drop("WinEase.exe"),
        "the lock file is missing": drop("plugins/builtin/builtin.lock.psd1"),
        "a source file is missing": drop("LICENSE"),
    }
    with tempfile.TemporaryDirectory() as tmp:
        for label, change in cases.items():
            path = os.path.join(tmp, "damaged.zip")
            damaged_copy(package, path, change)
            if verify(path, listing, commit) == 0:
                print(f"::error title=Verifier self-test::the verifier accepted a package where {label}")
                failures += 1
            else:
                print(f"rejected as expected: {label}")
            os.remove(path)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
