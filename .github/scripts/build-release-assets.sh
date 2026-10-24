#!/usr/bin/env bash
# Builds and verifies every release asset of a commit (used by release.yml and by the "release-package" job of ci.yml):
#
#   WinEase-<tag>.zip               the source tree (git archive)
#   WinEase-<tag>-win-x64.zip       source tree + x64 binaries   (tools/package-release.ps1)
#   WinEase-<tag>-win-arm64.zip     source tree + arm64 binaries
#   <each asset>.sha256
#
# Usage: build-release-assets.sh <tag> <commit> <binaries-root> <dist> [<folder to keep the hash lists in>]
#   <binaries-root>/x64 and <binaries-root>/arm64 hold the downloaded CI artifacts binaries-x64 / binaries-arm64
#   (WinEase.exe, gui/winui/bin, plugins/builtin). Their file hashes are listed here, independently of the
#   packaging script, and verify-release-zip.py --binaries checks every package against that list.
# Set PWSH to use another PowerShell executable (default: pwsh). Must run in a git checkout of <commit>.
set -euo pipefail

tag="${1:?usage: build-release-assets.sh <tag> <commit> <binaries-root> <dist>}"
commit="${2:?commit}"
binroot="${3:?binaries root}"
dist="${4:?dist folder}"
pwsh="${PWSH:-pwsh}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
python="$(command -v python3 || command -v python)"

mkdir -p "$dist"
if [ -n "${5:-}" ]; then
  lists="$5"; mkdir -p "$lists"   # kept, e.g. for test-verify-release-zip.py
else
  lists="$(mktemp -d)"; trap 'rm -rf "$lists"' EXIT
fi

echo "== Source ZIP"
src="WinEase-${tag}.zip"
git -c core.autocrlf=false archive --format=zip --prefix=WinEase/ -o "$dist/$src" "$commit"
"$python" -I "$here/verify-release-zip.py" "$dist/$src" "$commit" WinEase

for arch in x64 arm64; do
  echo "== Full package ($arch)"
  dir="$binroot/$arch"
  [ -d "$dir" ] || { echo "::error title=Binaries missing::$dir does not exist (artifact binaries-$arch)"; exit 1; }
  # the hash list of the CI build output: the three roots the package may take from
  ( cd "$dir" && find WinEase.exe gui/winui/bin plugins/builtin -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$lists/$arch.sha256"
  "$pwsh" -NoProfile -NonInteractive -File "$repo/tools/package-release.ps1" \
    -Tag "$tag" -Architecture "$arch" -Commit "$commit" -BinariesRoot "$dir" -OutputDir "$dist"
  "$python" -I "$here/verify-release-zip.py" --binaries "$lists/$arch.sha256" "$dist/WinEase-${tag}-win-${arch}.zip" "$commit" WinEase
done

echo "== Checksums"
( cd "$dist" && sha256sum "$src" > "$src.sha256" )
# every asset has a .sha256 and nothing else is in dist
( cd "$dist" && for f in WinEase-*.zip; do sha256sum -c "$f.sha256"; done )
expected=6
actual="$(find "$dist" -maxdepth 1 -type f | wc -l)"
[ "$actual" -eq "$expected" ] || { echo "::error title=Unexpected files::dist holds $actual files, expected $expected (3 ZIPs and 3 checksums)"; ls -l "$dist"; exit 1; }
