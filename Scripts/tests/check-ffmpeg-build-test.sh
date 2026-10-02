#!/usr/bin/env bash
# Tests for Scripts/check-ffmpeg-build.sh, hermetic via its env overrides.
# Run: Scripts/tests/check-ffmpeg-build-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-ffmpeg-build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# run_case name expected_exit expected_fragment [env overrides...]
run_case() {
    local name="$1" expected_exit="$2" fragment="$3"
    shift 3
    local out exit_code=0
    out="$(env "$@" bash "$SCRIPT" 2>&1)" || exit_code=$?
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        fail "$name (exit $exit_code, expected $expected_exit)"
        echo "    output: $out" >&2
        return
    fi
    if [[ -n "$fragment" && "$out" != *"$fragment"* ]]; then
        fail "$name (output missing '$fragment')"
        echo "    output: $out" >&2
        return
    fi
    pass "$name"
}

# Fixture: a source pin of 9.0.2, bundled dylibs at .63/.61/.7 and a build
# with the same set.
SRC="$WORK/.ffmpeg-source"
printf '# comment\nFFMPEG_VERSION=9.0.2\nFFMPEG_URL=https://example.invalid/ffmpeg-9.0.2.tar.xz\nFFMPEG_SHA256=00\n' > "$SRC"
RES="$WORK/Resources"
LIB="$WORK/lib"
mkdir -p "$RES" "$LIB"
for f in libavcodec.63.dylib libavformat.63.dylib libavutil.61.dylib libswresample.7.dylib; do
    touch "$RES/$f" "$LIB/$f"
done
LGPL="libavutil license: LGPL version 2.1 or later"
GPL="libavutil license: GPL version 3 or later"

echo "check-ffmpeg-build.sh:"

run_case "an LGPL build with matching dylibs passes" 0 "FFmpeg 9.0.2 is built (LGPL version 2.1 or later)" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE="$LGPL"

run_case "a missing build fails and names the make target" 1 "make ffmpeg-lgpl" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE=""

run_case "a GPL build fails" 1 "not the LGPL build: libavutil license: GPL version 3 or later" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE="$GPL"

run_case "an LGPL version 3 build fails" 1 "not the LGPL build" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" \
    FFMPEG_LICENCE_LINE="libavutil license: LGPL version 3 or later"

run_case "missing source pin fails" 1 ".ffmpeg-source is missing" \
    FFMPEG_SOURCE_FILE="$WORK/nope" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE="$LGPL"

BAD_SRC="$WORK/bad-source"
echo "FFMPEG_URL=https://example.invalid/x.tar.xz" > "$BAD_SRC"
run_case "a source pin with no version fails" 1 "does not set FFMPEG_VERSION" \
    FFMPEG_SOURCE_FILE="$BAD_SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE="$LGPL"

# Dylib drift: the build moves to .64 while Resources still bundles .63.
LIB2="$WORK/lib2"
mkdir -p "$LIB2"
for f in libavcodec.64.dylib libavformat.64.dylib libavutil.61.dylib libswresample.7.dylib; do
    touch "$LIB2/$f"
done
run_case "bundled dylib drift fails" 1 "libavcodec major drift" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB2" FFMPEG_LICENCE_LINE="$LGPL"

# Nothing bundled yet (a fresh clone before `make bundle-fpcalc`): the dylib
# pass is skipped.
run_case "an empty Resources is skipped" 0 "is built" \
    FFMPEG_SOURCE_FILE="$SRC" RESOURCES_DIR="$WORK/absent" FFMPEG_LIB_DIR="$LIB" FFMPEG_LICENCE_LINE="$LGPL"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all check-ffmpeg-build tests passed"
