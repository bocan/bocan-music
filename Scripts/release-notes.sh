#!/usr/bin/env bash
# release-notes.sh — Extracts a single version's section from CHANGELOG.md.
#
# Usage: release-notes.sh <version>
# Where <version> is the semver string ("0.2.0"), without the leading "v".
#
# Behaviour:
#   - Reads CHANGELOG.md from repo root.
#   - Finds the heading "## [<version>]" (Keep-a-Changelog format) and prints
#     everything until the next "## [" heading or EOF.
#   - If no matching section is found, falls back to the "## [Unreleased]"
#     section so a release tagged before the changelog is bumped still has
#     useful notes.
#   - Always exits 0; the worst case is empty output, which the caller can
#     handle.

set -euo pipefail

VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

if [[ -z "$VERSION" ]]; then
    echo "usage: release-notes.sh <version>" >&2
    exit 2
fi

if [[ ! -f "$CHANGELOG" ]]; then
    echo "_No CHANGELOG.md found._"
    exit 0
fi

# Try the requested version first, then [Unreleased].
extract() {
    local heading="$1"
    awk -v h="$heading" '
        BEGIN { in_section = 0 }
        /^## \[/ {
            if (in_section) { exit }
            if (index($0, h) > 0) { in_section = 1; next }
        }
        in_section { print }
    ' "$CHANGELOG"
}

NOTES="$(extract "[$VERSION]")"
if [[ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]]; then
    NOTES="$(extract "[Unreleased]")"
fi

if [[ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]]; then
    echo "_No release notes available for ${VERSION}._"
else
    printf '%s\n' "$NOTES"
fi
