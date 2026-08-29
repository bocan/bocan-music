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
#   - If no matching section is found it prints nothing and exits 1. There
#     is deliberately no fallback: the old "[Unreleased]" fallback shipped
#     v2.11.0 with an empty Added/Changed/Fixed/Removed template as its
#     release notes because the release PR had not been merged yet. A
#     release without notes must fail, not publish.

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
    echo "release-notes.sh: no '## [${VERSION}]' section in CHANGELOG.md; merge the release PR first" >&2
    exit 1
fi
printf '%s\n' "$NOTES"
