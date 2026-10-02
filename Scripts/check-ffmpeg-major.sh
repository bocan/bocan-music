#!/usr/bin/env bash
# Guards the FFmpeg the build links: its major version, and its licence.
#
# Every build links the project's own LGPL source build of FFmpeg (ADR-096),
# made by Scripts/build-ffmpeg-lgpl.sh from the release pinned in
# `.ffmpeg-source`. This script, run by `make doctor` locally and in CI, fails
# when:
#   - the pinned release is not of the major in `.ffmpeg-major` (decoder APIs
#     move between majors, so a major bump is a deliberate act);
#   - the build is not there, or does not report "LGPL version 2.1 or later";
#   - the fpcalc dylibs bundled under Resources/ come from a different major
#     than the build (CLAUDE.md: re-run `make bundle-fpcalc` after a bump).
#
# Everything is overridable via environment for the hermetic tests in
# Scripts/tests/ (which also run on Linux, where there is no FFmpeg build):
#   EXPECTED_FILE        path to the major pin           (default: repo/.ffmpeg-major)
#   FFMPEG_SOURCE_FILE   path to the source pin          (default: repo/.ffmpeg-source)
#   RESOURCES_DIR        bundled dylib directory         (default: repo/Resources)
#   FFMPEG_LIB_DIR       the build's dylib directory     (default: repo/build/ffmpeg-lgpl/lib)
#   FFMPEG_LICENCE_LINE  the licence the build reports   (default: read from libavutil)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_FILE="${EXPECTED_FILE:-$ROOT/.ffmpeg-major}"
FFMPEG_SOURCE_FILE="${FFMPEG_SOURCE_FILE:-$ROOT/.ffmpeg-source}"
RESOURCES_DIR="${RESOURCES_DIR:-$ROOT/Resources}"
FFMPEG_LIB_DIR="${FFMPEG_LIB_DIR:-${FFMPEG_PREFIX:-$ROOT/build/ffmpeg-lgpl}/lib}"

fail() {
    echo "✗ $1" >&2
    shift
    local line
    for line in "$@"; do echo "  $line" >&2; done
    exit 1
}

# ── the two pins agree ────────────────────────────────────────────────────────

[[ -f "$EXPECTED_FILE" ]] || fail ".ffmpeg-major is missing." \
    "Create it with the FFmpeg major the codebase supports, e.g.: echo 9 > .ffmpeg-major"
read -r -a accepted_majors <<< "$(tr '\n' ' ' < "$EXPECTED_FILE")"
[[ "${#accepted_majors[@]}" -ge 1 ]] || fail ".ffmpeg-major is empty." \
    "Put the supported FFmpeg major in it, e.g.: echo 9 > .ffmpeg-major"
primary="${accepted_majors[0]}"
[[ "$primary" =~ ^[0-9]+$ ]] || fail ".ffmpeg-major must hold a bare major version, got '$primary'."

[[ -f "$FFMPEG_SOURCE_FILE" ]] || fail ".ffmpeg-source is missing." \
    "It pins the FFmpeg release that Scripts/build-ffmpeg-lgpl.sh builds."
# Read the one value; the file is not sourced, so a test fixture cannot run code.
version="$(sed -nE 's/^FFMPEG_VERSION=(.*)$/\1/p' "$FFMPEG_SOURCE_FILE" | head -1)"
[[ -n "$version" ]] || fail ".ffmpeg-source does not set FFMPEG_VERSION."
actual="${version%%.*}"
[[ "$actual" =~ ^[0-9]+$ ]] || fail "Could not parse a major from FFMPEG_VERSION=$version in .ffmpeg-source."

if [[ "$actual" != "$primary" ]]; then
    fail "FFmpeg major mismatch: .ffmpeg-source pins $version, .ffmpeg-major says $primary." \
        "If the upgrade is intentional:" \
        "  1. update .ffmpeg-major," \
        "  2. run 'make ffmpeg-lgpl' and 'make bundle-fpcalc' ('make generate' too if dylib filenames changed)," \
        "  3. run the full test suites before committing (decoder APIs move between majors)."
fi

# ── the build exists and is the LGPL build ───────────────────────────────────

# ${VAR-default} (no colon) so tests can force "no build" with an empty override.
if [[ -z "${FFMPEG_LICENCE_LINE+set}" ]]; then
    avutil="$(ls "$FFMPEG_LIB_DIR"/libavutil.*.dylib 2>/dev/null | head -1 || true)"
    if [[ -n "$avutil" ]]; then
        # Read the strings into a variable first: `strings | grep` under
        # pipefail fails when grep closes the pipe early.
        avutil_strings="$(strings -a "$avutil")"
        FFMPEG_LICENCE_LINE="$(grep -E '^libavutil license: ' <<< "$avutil_strings" | head -1 || true)"
    else
        FFMPEG_LICENCE_LINE=""
    fi
fi
[[ -n "$FFMPEG_LICENCE_LINE" ]] || fail "The LGPL FFmpeg build is not there ($FFMPEG_LIB_DIR)." \
    "Build it with: make ffmpeg-lgpl"
if [[ "$FFMPEG_LICENCE_LINE" != *"LGPL version 2.1 or later"* ]]; then
    fail "The FFmpeg build is not the LGPL build: $FFMPEG_LICENCE_LINE" \
        "The project links only an LGPL v2.1-or-later FFmpeg (ADR-096)." \
        "Rebuild it with: make ffmpeg-lgpl"
fi

# ── the bundled fpcalc dylibs come from the same majors ──────────────────────
# Skipped per-library when either side has nothing to compare.
mismatches=0
for lib in libavcodec libavformat libavutil libswresample; do
    # `|| true` keeps pipefail from aborting when a directory does not exist.
    bundled_major="$(ls "$RESOURCES_DIR" 2>/dev/null | sed -nE "s/^$lib\.([0-9]+)\.dylib$/\1/p" | head -1 || true)"
    [[ -n "$bundled_major" ]] || continue
    built_major="$(ls "$FFMPEG_LIB_DIR" 2>/dev/null | sed -nE "s/^$lib\.([0-9]+)\.dylib$/\1/p" | head -1 || true)"
    [[ -n "$built_major" ]] || continue
    if [[ "$bundled_major" != "$built_major" ]]; then
        echo "✗ $lib major drift: Resources/ bundles .$bundled_major, the FFmpeg build provides .$built_major" >&2
        mismatches=$((mismatches + 1))
    fi
done
if [[ "$mismatches" -gt 0 ]]; then
    fail "Bundled fpcalc dylibs disagree with the FFmpeg build." \
        "Re-run 'make bundle-fpcalc' (and 'make generate' if dylib filenames changed)."
fi

echo "✓ FFmpeg $version (${FFMPEG_LICENCE_LINE#libavutil license: }) matches the pin (.ffmpeg-major); bundled dylib majors agree"
