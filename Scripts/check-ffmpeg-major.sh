#!/usr/bin/env bash
# Guards the FFmpeg major version the build links against.
#
# Homebrew formulae cannot be pinned (old bottles stop resolving after a few
# months), so `brew bundle` always installs the current FFmpeg, on developer
# machines and CI runners alike. This script makes the drift loud instead of
# silent: the supported major lives in `.ffmpeg-major`, and `make doctor`
# (run locally and in CI) fails when the installed FFmpeg disagrees, or when
# the bundled fpcalc dylibs under Resources/ were built from a different
# major than the one installed (CLAUDE.md: re-run `make bundle-fpcalc`
# after a major bump).
#
# Everything is overridable via environment for the hermetic tests in
# Scripts/tests/ (which also run on Linux, where ffmpeg is absent):
#   EXPECTED_FILE        path to the pin file        (default: repo/.ffmpeg-major)
#   RESOURCES_DIR        bundled dylib directory      (default: repo/Resources)
#   FFMPEG_LIB_DIR       installed dylib directory    (default: /opt/homebrew/opt/ffmpeg/lib)
#   FFMPEG_VERSION_LINE  first line of `ffmpeg -version`

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_FILE="${EXPECTED_FILE:-$ROOT/.ffmpeg-major}"
RESOURCES_DIR="${RESOURCES_DIR:-$ROOT/Resources}"
FFMPEG_LIB_DIR="${FFMPEG_LIB_DIR:-/opt/homebrew/opt/ffmpeg/lib}"
# ${VAR-default} (no colon) so tests can force "not installed" with an empty override.
FFMPEG_VERSION_LINE="${FFMPEG_VERSION_LINE-$(ffmpeg -version 2>/dev/null | head -1 || true)}"

fail() {
    echo "✗ $1" >&2
    shift
    local line
    for line in "$@"; do echo "  $line" >&2; done
    exit 1
}

[[ -f "$EXPECTED_FILE" ]] || fail ".ffmpeg-major is missing." \
    "Create it with the FFmpeg major(s) the codebase supports, e.g.: echo 9 > .ffmpeg-major"
# The file holds one or more accepted majors, whitespace-separated. The FIRST
# is the primary: the major the committed fpcalc dylibs in Resources/ were
# built from. Later entries are also accepted (e.g. the CI runner image
# lagging one major behind the dev machines until it catches up).
read -r -a accepted_majors <<< "$(tr '\n' ' ' < "$EXPECTED_FILE")"
[[ "${#accepted_majors[@]}" -ge 1 ]] || fail ".ffmpeg-major is empty." \
    "List the accepted FFmpeg majors, primary first, e.g.: echo 9 > .ffmpeg-major"
for major in "${accepted_majors[@]}"; do
    [[ "$major" =~ ^[0-9]+$ ]] || fail ".ffmpeg-major must hold a bare major version per entry, got '$major'."
done
primary="${accepted_majors[0]}"

[[ -n "$FFMPEG_VERSION_LINE" ]] || fail "ffmpeg is not installed (or not on PATH)." \
    "Install it with: brew bundle"
# "ffmpeg version 9.0.1 Copyright ..." -> 9
actual="$(echo "$FFMPEG_VERSION_LINE" | awk '{print $3}' | cut -d. -f1)"
[[ "$actual" =~ ^[0-9]+$ ]] || fail "Could not parse an FFmpeg version from: $FFMPEG_VERSION_LINE"

accepted=false
for major in "${accepted_majors[@]}"; do
    [[ "$actual" == "$major" ]] && accepted=true
done
if [[ "$accepted" != true ]]; then
    fail "FFmpeg major mismatch: installed $actual, expected one of: ${accepted_majors[*]} (.ffmpeg-major)." \
        "The build links FFmpeg at fixed majors and Homebrew cannot pin them (see Brewfile)." \
        "If this upgrade is intentional:" \
        "  1. update .ffmpeg-major (primary first: the major the committed fpcalc dylibs track)," \
        "  2. re-run 'make bundle-fpcalc' if any dylib major changed ('make generate' too if filenames changed)," \
        "  3. run the full test suites before committing (decoder APIs move between majors)."
fi

if [[ "$actual" != "$primary" ]]; then
    # A secondary accepted major (e.g. a CI runner lagging the dev machines).
    # The committed fpcalc dylibs track the primary, so comparing them against
    # this install would always disagree; the primary machines keep that guard.
    echo "✓ FFmpeg major $actual accepted (secondary; primary is $primary); bundled-dylib check skipped"
    exit 0
fi

# Bundled fpcalc dylibs must come from the same majors as the installed
# FFmpeg, or a release ships a mixed set. Skipped per-library when either
# side has nothing to compare (e.g. Linux CI, where neither exists).
mismatches=0
for lib in libavcodec libavformat libavutil libswresample; do
    # `|| true` keeps pipefail from aborting when a directory does not exist.
    bundled_major="$(ls "$RESOURCES_DIR" 2>/dev/null | sed -nE "s/^$lib\.([0-9]+)\.dylib$/\1/p" | head -1 || true)"
    [[ -n "$bundled_major" ]] || continue
    installed_major="$(ls "$FFMPEG_LIB_DIR" 2>/dev/null | sed -nE "s/^$lib\.([0-9]+)\.dylib$/\1/p" | head -1 || true)"
    [[ -n "$installed_major" ]] || continue
    if [[ "$bundled_major" != "$installed_major" ]]; then
        echo "✗ $lib major drift: Resources/ bundles .$bundled_major, installed FFmpeg provides .$installed_major" >&2
        mismatches=$((mismatches + 1))
    fi
done
if [[ "$mismatches" -gt 0 ]]; then
    fail "Bundled fpcalc dylibs disagree with the installed FFmpeg." \
        "Re-run 'make bundle-fpcalc' (and 'make generate' if dylib filenames changed)."
fi

echo "✓ FFmpeg major $actual matches the primary pin (.ffmpeg-major); bundled dylib majors agree"
