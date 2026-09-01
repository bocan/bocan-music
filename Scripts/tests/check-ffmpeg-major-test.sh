#!/usr/bin/env bash
# Tests for Scripts/check-ffmpeg-major.sh, hermetic via its env overrides.
# Run: Scripts/tests/check-ffmpeg-major-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-ffmpeg-major.sh"
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

# Fixture: a pin of 9, bundled dylibs at .63/.61/.7, matching installed set.
PIN="$WORK/.ffmpeg-major"
echo "9" > "$PIN"
RES="$WORK/Resources"
LIB="$WORK/lib"
mkdir -p "$RES" "$LIB"
for f in libavcodec.63.dylib libavformat.63.dylib libavutil.61.dylib libswresample.7.dylib; do
    touch "$RES/$f" "$LIB/$f"
done
VER9="ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers"
VER10="ffmpeg version 10.0 Copyright (c) 2000-2027 the FFmpeg developers"

echo "check-ffmpeg-major.sh:"

run_case "matching major and dylibs passes" 0 "matches the primary pin" \
    EXPECTED_FILE="$PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE="$VER9"

run_case "major mismatch fails with remediation" 1 "re-run 'make bundle-fpcalc'" \
    EXPECTED_FILE="$PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE="$VER10"

run_case "missing ffmpeg fails" 1 "not installed" \
    EXPECTED_FILE="$PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE=""

run_case "missing pin file fails" 1 ".ffmpeg-major is missing" \
    EXPECTED_FILE="$WORK/nope" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE="$VER9"

BAD_PIN="$WORK/bad-pin"
echo "nine" > "$BAD_PIN"
run_case "garbage pin fails" 1 "bare major version" \
    EXPECTED_FILE="$BAD_PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE="$VER9"

# Dylib drift: installed set moves to .64 while Resources still bundles .63.
LIB2="$WORK/lib2"
mkdir -p "$LIB2"
for f in libavcodec.64.dylib libavformat.64.dylib libavutil.61.dylib libswresample.7.dylib; do
    touch "$LIB2/$f"
done
run_case "bundled dylib drift fails" 1 "libavcodec major drift" \
    EXPECTED_FILE="$PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB2" FFMPEG_VERSION_LINE="$VER9"

# Nothing installed to compare against (Linux CI): dylib pass is skipped.
run_case "absent installed lib dir is skipped" 0 "matches the primary pin" \
    EXPECTED_FILE="$PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$WORK/absent" FFMPEG_VERSION_LINE="$VER9"

# Accepted-list behaviour: "9 8" accepts an 8 install as secondary and skips
# the bundled-dylib comparison (the committed dylibs track the primary).
LIST_PIN="$WORK/list-pin"
echo "9 8" > "$LIST_PIN"
VER8="ffmpeg version 8.1.1 Copyright (c) 2000-2025 the FFmpeg developers"
run_case "secondary accepted major passes and skips the dylib check" 0 "secondary; primary is 9" \
    EXPECTED_FILE="$LIST_PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB2" FFMPEG_VERSION_LINE="$VER8"
run_case "primary from a list still runs the dylib check" 1 "libavcodec major drift" \
    EXPECTED_FILE="$LIST_PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB2" FFMPEG_VERSION_LINE="$VER9"
run_case "a major outside the list fails" 1 "expected one of: 9 8" \
    EXPECTED_FILE="$LIST_PIN" RESOURCES_DIR="$RES" FFMPEG_LIB_DIR="$LIB" FFMPEG_VERSION_LINE="$VER10"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all check-ffmpeg-major tests passed"
