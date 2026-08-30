#!/usr/bin/env bash
# release-notes.sh: print the user-facing release notes for one version.
#
# Usage: release-notes.sh <version>      ("2.12.0", no leading "v")
#
# Reads the "## [<version>]" section of CHANGELOG.md and prints only the
# maintainer's prose: everything up to the generated "### For developers"
# list, followed by a "Full changelog" link to the GitHub compare view. This
# is what the GitHub release body and the Sparkle update prompt show; the
# developer bullets stay in CHANGELOG.md and on the website.
#
# There is deliberately no fallback: a missing section exits 1 so a release
# without notes fails instead of publishing (v2.11.0 once shipped an empty
# template as its notes because of a silent fallback).

set -euo pipefail

VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

if [[ -z "$VERSION" ]]; then
    echo "usage: release-notes.sh <version>" >&2
    exit 2
fi
[[ -f "$CHANGELOG" ]] || { echo "release-notes.sh: no CHANGELOG.md" >&2; exit 1; }

# The heading line carries the compare link: ## [2.12.0](https://.../compare/v2.11.0...v2.12.0) (date)
HEADING="$(grep -m1 "^## \[${VERSION}\]" "$CHANGELOG" || true)"
if [[ -z "$HEADING" ]]; then
    echo "release-notes.sh: no '## [${VERSION}]' section in CHANGELOG.md; run Scripts/release.sh apply first" >&2
    exit 1
fi
COMPARE="$(sed -n 's/^## \[[^]]*\](\([^)]*\)).*/\1/p' <<<"$HEADING")"

PROSE="$(awk -v h="## [${VERSION}]" '
    index($0, h) == 1 { inside = 1; next }
    inside && (/^## \[/ || /^### For developers/) { exit }
    inside { print }
' "$CHANGELOG" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$(tr -d '[:space:]' <<<"$PROSE")" ]]; then
    echo "release-notes.sh: the ${VERSION} section has no prose above '### For developers'" >&2
    exit 1
fi

printf '%s\n' "$PROSE"
if [[ -n "$COMPARE" ]]; then
    printf '\nFull changelog: %s\n' "$COMPARE"
fi
