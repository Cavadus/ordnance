#!/usr/bin/env bash
# Ordnance release helper: commit, tag, push, and guarantee a Build run starts.
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 0.4.3
#
# Expects the version bump (src-tauri/Cargo.toml, src-tauri/tauri.conf.json,
# package.json, README.md) and .github/release-notes/v<version>.md to be done
# and uncommitted. Then it commits, tags, pushes, and makes sure the release
# Build actually runs.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v${VERSION#v}"
NOTES=".github/release-notes/${TAG}.md"

cd "$(dirname "$0")/.."

[ -f "$NOTES" ] || { echo "error: missing $NOTES" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet && { echo "error: no uncommitted changes to release" >&2; exit 1; }

git add -A
git commit -m "Release ${TAG}"
git tag -a "${TAG}" -m "Ordnance ${TAG}"
git push origin HEAD
git push origin "${TAG}"

# GitHub does not run push-triggered workflows while this repo is a fork
# (the reason every release so far went out via manual dispatch). Give the
# tag-push trigger a moment anyway -- it fires natively once the fork is
# detached -- and dispatch the Build workflow if no run appeared, so the
# release build always happens.
sleep 30
if ! gh run list --branch "${TAG}" --json databaseId --jq 'length > 0' | grep -q true; then
    echo "no build started for ${TAG} on its own; dispatching Build workflow"
    gh workflow run Build --ref "${TAG}"
fi
gh run list --limit 3
