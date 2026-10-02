#!/usr/bin/env bash
# Tests for Scripts/check-bundle-licence.sh, hermetic via its env overrides.
# Run: Scripts/tests/check-bundle-licence-test.sh   (also `make test-scripts`; CI runs it on Linux)
#
# A fake bundle is a directory of text files. `cat` stands in for `strings`,
# and a small script stands in for `otool -L`: it prints the file name, then
# the lines of a sidecar file `<binary>.loads` when there is one.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-bundle-licence.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

FAKE_OTOOL="$WORK/fake-otool"
cat > "$FAKE_OTOOL" <<'EOF'
#!/usr/bin/env bash
echo "$1:"
if [[ -f "$1.loads" ]]; then
    while IFS= read -r line; do
        printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$line"
    done < "$1.loads"
fi
EOF
chmod +x "$FAKE_OTOOL"

LGPL_CONFIGURE='--prefix=/build/ffmpeg-lgpl --enable-shared --disable-static --enable-libmp3lame --enable-libopus --enable-openssl'
GPL_CONFIGURE='--prefix=/opt/homebrew/Cellar/ffmpeg/9.0.2 --enable-shared --enable-version3 --enable-gpl --enable-libx264'

# make_lib <path> <licence line> <configure line>
make_lib() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n%s\nsome other string\n' "$3" "$2" > "$1"
}

# make_app <dir>: a clean bundle, FFmpeg in Frameworks and beside fpcalc.
make_app() {
    local app="$1" dir lib
    for dir in Contents/Frameworks Contents/Resources; do
        for lib in libavcodec.63 libavformat.63 libavutil.61 libswresample.7; do
            make_lib "$app/$dir/$lib.dylib" "${lib%%.*} license: LGPL version 2.1 or later" "$LGPL_CONFIGURE"
        done
    done
    mkdir -p "$app/Contents/MacOS"
    echo "binary" > "$app/Contents/MacOS/Bocan"
    echo "binary" > "$app/Contents/Resources/fpcalc"
    chmod +x "$app/Contents/MacOS/Bocan" "$app/Contents/Resources/fpcalc"
    printf '@rpath/libavformat.63.dylib\n@rpath/libavcodec.63.dylib\n/usr/lib/libSystem.B.dylib\n' \
        > "$app/Contents/MacOS/Bocan.loads"
    printf '@loader_path/libavcodec.63.dylib\n@loader_path/libchromaprint.1.dylib\n' \
        > "$app/Contents/Resources/fpcalc.loads"
    # A Swift runtime library must never be taken for an FFmpeg library.
    echo "swift runtime" > "$app/Contents/Frameworks/libswiftCore.dylib"
}

# run_case name expected_exit expected_fragment app
run_case() {
    local name="$1" expected_exit="$2" fragment="$3" app="$4"
    local out exit_code=0
    out="$(STRINGS_CMD=cat OTOOL_CMD="$FAKE_OTOOL" bash "$SCRIPT" "$app" 2>&1)" || exit_code=$?
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

echo "check-bundle-licence.sh:"

CLEAN="$WORK/clean/Bocan.app"
make_app "$CLEAN"
run_case "a clean LGPL bundle passes" 0 "8 FFmpeg libraries" "$CLEAN"

GPL="$WORK/gpl/Bocan.app"
make_app "$GPL"
make_lib "$GPL/Contents/Frameworks/libavcodec.63.dylib" "libavcodec license: GPL version 3 or later" "$LGPL_CONFIGURE"
run_case "a GPL licence string fails" 1 "Contents/Frameworks/libavcodec.63.dylib: reports a GPL licence" "$GPL"
run_case "a GPL library also lacks the LGPL string" 1 "does not report 'LGPL version 2.1 or later'" "$GPL"

V3="$WORK/v3/Bocan.app"
make_app "$V3"
make_lib "$V3/Contents/Frameworks/libavutil.61.dylib" "libavutil license: LGPL version 3 or later" "$LGPL_CONFIGURE"
run_case "LGPL version 3 is not the chosen licence" 1 "libavutil.61.dylib: does not report 'LGPL version 2.1 or later'" "$V3"

FLAG="$WORK/flag/Bocan.app"
make_app "$FLAG"
make_lib "$FLAG/Contents/Frameworks/libavformat.63.dylib" "libavformat license: LGPL version 2.1 or later" "$GPL_CONFIGURE"
run_case "--enable-gpl in the configure line fails" 1 "libavformat.63.dylib: was configured with --enable-gpl" "$FLAG"
run_case "--enable-version3 in the configure line fails" 1 "was configured with --enable-version3" "$FLAG"

NONFREE="$WORK/nonfree/Bocan.app"
make_app "$NONFREE"
make_lib "$NONFREE/Contents/Frameworks/libavcodec.63.dylib" \
    "libavcodec license: nonfree and unredistributable" "$LGPL_CONFIGURE --enable-nonfree"
run_case "a nonfree build fails" 1 "reports a nonfree build" "$NONFREE"

X264="$WORK/x264/Bocan.app"
make_app "$X264"
echo "x264" > "$X264/Contents/Frameworks/libx264.165.dylib"
run_case "a libx264 file fails" 1 "Contents/Frameworks/libx264.165.dylib: a GPL-only library" "$X264"

EMPTY="$WORK/empty/Bocan.app"
mkdir -p "$EMPTY/Contents/MacOS"
echo "binary" > "$EMPTY/Contents/MacOS/Bocan"
run_case "no libavcodec fails" 1 "no libavcodec in the bundle" "$EMPTY"

ABS="$WORK/abs/Bocan.app"
make_app "$ABS"
printf '/opt/homebrew/opt/ffmpeg/lib/libavcodec.63.dylib\n' > "$ABS/Contents/MacOS/Bocan.loads"
run_case "an absolute Homebrew load path fails" 1 \
    "Contents/MacOS/Bocan: loads FFmpeg from outside the bundle: /opt/homebrew/opt/ffmpeg/lib/libavcodec.63.dylib" "$ABS"

RES="$WORK/res/Bocan.app"
make_app "$RES"
make_lib "$RES/Contents/Resources/libswresample.7.dylib" "libswresample license: GPL version 3 or later" "$GPL_CONFIGURE"
run_case "the Resources copy is checked as well as the Frameworks copy" 1 \
    "Contents/Resources/libswresample.7.dylib: reports a GPL licence" "$RES"

run_case "a missing bundle is a usage error" 2 "no app bundle" "$WORK/nope/Bocan.app"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all check-bundle-licence tests passed"
