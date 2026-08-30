#!/usr/bin/env bash
# release.sh: compute the next version from the squash commits on main and,
# on request, rewrite CHANGELOG.md and Info.plist for it. ADR-033, slice 3.
#
# Usage:
#   Scripts/release.sh next            Print the next version ("1.3.0"), or
#                                      exit 3 with a message if nothing since
#                                      the last tag warrants a release.
#   Scripts/release.sh apply           Rewrite CHANGELOG.md (Unreleased becomes
#                                      the new version section) and stamp
#                                      Resources/Info.plist. Prints the version.
#   Scripts/release.sh preview         Print the section `apply` would write,
#                                      without touching anything.
#
# How the version is decided (Conventional Commit subjects, first-parent
# history since the last v* tag, so exactly one line per squash-merged PR):
#   feat!: / fix!: / BREAKING CHANGE in the body  -> major
#   feat:                                         -> minor
#   fix: / perf:                                  -> patch
#   anything else only (chore, docs, ci, ...)     -> no release (exit 3)
#
# The section written to CHANGELOG.md is the maintainer's prose from
# "## [Unreleased]" (written per PR, enforced by the PR check) followed by a
# generated "### For developers" list of the squash subjects grouped by type.
# `apply` refuses (exit 4) if the prose is empty: a release without notes is
# a bug, not a release.
#
# Environment (mainly for tests):
#   RELEASE_DATE   YYYY-MM-DD to stamp instead of today (UTC).
#   RELEASE_REPO   owner/name for links (default bocan/bocan-music).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    next|apply|preview) ;;
    *) echo "usage: release.sh next|apply|preview" >&2; exit 2 ;;
esac

REPO="${RELEASE_REPO:-bocan/bocan-music}"
DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
ROOT="$(git rev-parse --show-toplevel)"
CHANGELOG="$ROOT/CHANGELOG.md"
PLIST="$ROOT/Resources/Info.plist"

die() { echo "release.sh: $1" >&2; exit "${2:-1}"; }

# --- 1. Commits since the last tag ------------------------------------------

LAST_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
[[ -n "$LAST_TAG" ]] || die "no v* tag found; tag the current release first"
PREV="${LAST_TAG#v}"

# One record per commit: subject, then body, separated by a marker that
# cannot appear in a commit message.
RECORDS="$(git -C "$ROOT" log --first-parent --reverse --format='%s%x1f%b%x1e' "$LAST_TAG..HEAD")"

bump="none"
added=""; fixed=""; changed=""; removed=""

link_pr() {
    # "subject (#431)" -> "subject ([#431](https://github.com/REPO/pull/431))"
    sed -E "s|[[:space:]]+\(#([0-9]+)\)$| ([#\1](https://github.com/$REPO/pull/\1))|"
}

while IFS= read -r -d $'\x1e' record; do
    subject="${record%%$'\x1f'*}"
    body="${record#*$'\x1f'}"
    subject="${subject#$'\n'}"
    [[ -n "$subject" ]] || continue

    # type(scope)!: description
    conventional='^([a-z]+)(\(([^)]*)\))?(!)?: (.*)$'
    if [[ "$subject" =~ $conventional ]]; then
        type="${BASH_REMATCH[1]}"
        scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"
        desc="${BASH_REMATCH[5]}"
    else
        # Not Conventional (should not happen with the PR title check); list
        # it under Changed so it is at least visible, and never bump for it.
        type="other"; scope=""; bang=""; desc="$subject"
    fi

    breaking=0
    if [[ -n "$bang" ]] || grep -q '^BREAKING CHANGE' <<<"$body"; then breaking=1; fi

    if (( breaking )); then
        bump="major"
    elif [[ "$type" == "feat" && "$bump" != "major" ]]; then
        bump="minor"
    elif [[ "$type" =~ ^(fix|perf)$ && "$bump" == "none" ]]; then
        bump="patch"
    fi

    line="$desc"
    [[ -n "$scope" ]] && line="$scope: $desc"
    (( breaking )) && line="BREAKING: $line"
    line="- $(link_pr <<<"$line")"

    case "$type" in
        feat) added+="$line"$'\n' ;;
        fix) fixed+="$line"$'\n' ;;
        perf|refactor|other) changed+="$line"$'\n' ;;
        revert) removed+="$line"$'\n' ;;
        *) ;; # chore, docs, ci, build, test, style: developer noise, hidden
    esac
done <<<"$RECORDS"

[[ "$bump" != "none" ]] || die "nothing since $LAST_TAG warrants a release (no feat, fix or perf commits)" 3

IFS=. read -r major minor patch <<<"$PREV"
case "$bump" in
    major) NEXT="$((major + 1)).0.0" ;;
    minor) NEXT="$major.$((minor + 1)).0" ;;
    patch) NEXT="$major.$minor.$((patch + 1))" ;;
esac

if [[ "$MODE" == "next" ]]; then
    echo "$NEXT"
    exit 0
fi

# --- 2. The maintainer's prose under Unreleased ------------------------------

[[ -f "$CHANGELOG" ]] || die "no CHANGELOG.md at $CHANGELOG"
grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "CHANGELOG.md has no '## [Unreleased]' section"

PROSE="$(awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    /^## \[/ { inside = 0 }
    inside { print }
' "$CHANGELOG" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

[[ -n "$(tr -d '[:space:]' <<<"$PROSE")" ]] \
    || die "the Unreleased section is empty; every feat/fix/perf PR must add a release note there" 4

# --- 3. Compose the new section ---------------------------------------------

COMPARE="https://github.com/$REPO/compare/v$PREV...v$NEXT"
section="## [$NEXT]($COMPARE) ($DATE)"$'\n\n'"$PROSE"$'\n\n'"### For developers"$'\n'
[[ -n "$added"   ]] && section+=$'\n'"**Added**"$'\n'"$added"
[[ -n "$fixed"   ]] && section+=$'\n'"**Fixed**"$'\n'"$fixed"
[[ -n "$changed" ]] && section+=$'\n'"**Changed**"$'\n'"$changed"
[[ -n "$removed" ]] && section+=$'\n'"**Removed**"$'\n'"$removed"

if [[ "$MODE" == "preview" ]]; then
    printf '%s' "$section"
    exit 0
fi

# --- 4. Apply: CHANGELOG.md and Info.plist ------------------------------------

# Replace everything between "## [Unreleased]" and the next "## [" heading
# with an empty Unreleased plus the new section. python3 rather than awk:
# BSD awk cannot take a multi-line -v string and this must run on macOS and
# Linux alike.
SECTION="$section" python3 - "$CHANGELOG" <<'PY'
import os, re, sys
path = sys.argv[1]
section = os.environ["SECTION"].rstrip("\n")
text = open(path, encoding="utf-8").read()
m = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
if not m:
    sys.exit("release.sh: no Unreleased section")
new = "## [Unreleased]\n\n" + section + "\n\n"
text = text[: m.start()] + new + text[m.end():]
open(path, "w", encoding="utf-8").write(text)
PY

[[ -f "$PLIST" ]] || die "no Info.plist at $PLIST"
tmp="$(mktemp)"
# Portable (BSD and GNU sed): replace the <string> on the line after the key.
sed -e '/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>'"$NEXT"'</string>|;}' \
    "$PLIST" > "$tmp"
grep -q "<string>$NEXT</string>" "$tmp" || die "failed to stamp CFBundleShortVersionString in Info.plist"
mv "$tmp" "$PLIST"

echo "$NEXT"
