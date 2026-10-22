#!/usr/bin/env bash
# Prints the commit a tag points to on GitHub right now (annotated tags are dereferenced).
# Used by release.yml to detect a tag that was moved after the checks started.
# Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail
tag="${1:?usage: resolve-tag-commit.sh <tag>}"
ref="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${tag}")"
type="$(jq -r .object.type <<<"$ref")"
sha="$(jq -r .object.sha <<<"$ref")"
if [ "$type" = "tag" ]; then
  sha="$(gh api "repos/${GITHUB_REPOSITORY}/git/tags/${sha}" --jq .object.sha)"
fi
echo "$sha"
