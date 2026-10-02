#!/usr/bin/env bash
# The licence gate for a built Bocan.app (ADR-096).
#
# The project has required an LGPL FFmpeg since ADR-002, and shipped Homebrew's
# GPLv3 build for five months because nothing checked. This script is the
# check: it reads the FFmpeg libraries inside an app bundle and fails when any
# of them is not an LGPL v2.1-or-later build, when a GPL-only library is in the
# bundle, or when a binary would load FFmpeg from outside the bundle.
#
# Usage:
#   Scripts/check-bundle-licence.sh path/to/Bocan.app
#
# Exit 0 only when every rule holds. Otherwise one line per failure on stderr
# and exit 1. Exit 2 for a usage error.
#
# The rules:
#   1. Every FFmpeg library in the bundle (any directory) says
#      "LGPL version 2.1 or later", and says neither "GPL version" without the
#      leading L nor "nonfree and unredistributable".
#   2. The configure line embedded in each of those libraries has none of
#      --enable-gpl, --enable-version3, --enable-nonfree.
#   3. No GPL-only library is in the bundle (libx264, libx265, libxvid,
#      libvidstab, librubberband, libpostproc).
#   4. At least one libavcodec was found. An app with no FFmpeg is a broken
#      bundle, not a clean one.
#   5. Every Mach-O in the bundle that names an FFmpeg library names it
#      relative to the bundle (@rpath, @loader_path, @executable_path).
#
# The FFmpeg libraries are matched by name, not by the glob "libsw*", so that a
# bundled Swift runtime library (libswiftCore.dylib) is never mistaken for one.
#
# Everything the script runs is overridable through the environment, so the
# hermetic tests in Scripts/tests/ also run on Linux, where there is no otool:
#   STRINGS_CMD  prints the strings of a file      (default: strings -a)
#   OTOOL_CMD    prints the load commands of a file (default: otool -L)
#   FIND_CMD     the find to use                    (default: find)

set -euo pipefail

STRINGS_CMD="${STRINGS_CMD:-strings -a}"
OTOOL_CMD="${OTOOL_CMD:-otool -L}"
FIND_CMD="${FIND_CMD:-find}"

APP="${1:-}"
if [[ -z "$APP" ]]; then
    echo "usage: $(basename "$0") path/to/Bocan.app" >&2
    exit 2
fi
if [[ ! -d "$APP" ]]; then
    echo "✗ no app bundle at $APP" >&2
    exit 2
fi

# The FFmpeg libraries, by base name.
FFMPEG_LIBS='lib(avcodec|avformat|avutil|avfilter|avdevice|swresample|swscale)'
# Libraries that exist only under the GPL (or that FFmpeg only builds with
# --enable-gpl).
GPL_ONLY='lib(x264|x265|xvid|vidstab|rubberband|postproc)'

failures=0
fail() {
    echo "✗ $1" >&2
    failures=$((failures + 1))
}

# Path of a bundle file, relative to the bundle, for readable messages.
rel() {
    echo "${1#"$APP"/}"
}

# ── rules 1, 2 and 4: the FFmpeg libraries themselves ────────────────────────

ffmpeg_count=0
avcodec_count=0
while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    name="$(basename "$lib")"
    [[ "$name" =~ ^${FFMPEG_LIBS}[.].*dylib$ ]] || continue
    ffmpeg_count=$((ffmpeg_count + 1))
    [[ "$name" == libavcodec.* ]] && avcodec_count=$((avcodec_count + 1))

    # `|| true`: a library with no printable strings is reported by the
    # missing-licence rule below, not by an aborted pipeline.
    text="$($STRINGS_CMD "$lib" 2>/dev/null || true)"

    if ! grep -q 'LGPL version 2\.1 or later' <<< "$text"; then
        fail "$(rel "$lib"): does not report 'LGPL version 2.1 or later'"
    fi
    gpl_line="$(grep -E '(^|[^L])GPL version' <<< "$text" | head -1 || true)"
    if [[ -n "$gpl_line" ]]; then
        fail "$(rel "$lib"): reports a GPL licence: ${gpl_line}"
    fi
    if grep -q 'nonfree and unredistributable' <<< "$text"; then
        fail "$(rel "$lib"): reports a nonfree build"
    fi

    configure_line="$(grep -E '^--prefix=' <<< "$text" | head -1 || true)"
    for flag in --enable-gpl --enable-version3 --enable-nonfree; do
        # The trailing space or end of line keeps --enable-gpl from matching
        # a longer option name.
        if grep -q -E -- "${flag}( |\$)" <<< "$configure_line"; then
            fail "$(rel "$lib"): was configured with ${flag}"
        fi
    done
done < <($FIND_CMD "$APP" -type f -name '*.dylib' | sort)

if [[ "$avcodec_count" -eq 0 ]]; then
    fail "no libavcodec in the bundle: an app without FFmpeg is broken, not clean"
fi

# ── rule 3: GPL-only libraries ───────────────────────────────────────────────

while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    name="$(basename "$file")"
    if [[ "$name" =~ ^${GPL_ONLY} ]]; then
        fail "$(rel "$file"): a GPL-only library is in the bundle"
    fi
done < <($FIND_CMD "$APP" -type f | sort)

# ── rule 5: FFmpeg is loaded from inside the bundle ──────────────────────────

while IFS= read -r binary; do
    [[ -n "$binary" ]] || continue
    # The first line of `otool -L` is the file name itself; a file that is not
    # a Mach-O prints nothing useful and is skipped.
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        dep_name="$(basename "$dep")"
        [[ "$dep_name" =~ ^${FFMPEG_LIBS}[.] ]] || continue
        case "$dep" in
            @rpath/* | @loader_path/* | @executable_path/*) ;;
            *) fail "$(rel "$binary"): loads FFmpeg from outside the bundle: ${dep}" ;;
        esac
    done < <($OTOOL_CMD "$binary" 2>/dev/null | awk 'NR>1 {print $1}' || true)
done < <($FIND_CMD "$APP" -type f \( -name '*.dylib' -o -perm -111 \) | sort)

# ── result ───────────────────────────────────────────────────────────────────

if [[ "$failures" -gt 0 ]]; then
    echo "✗ licence gate failed: ${failures} problem(s) in $APP" >&2
    exit 1
fi
echo "✓ licence gate passed: ${ffmpeg_count} FFmpeg libraries, all LGPL v2.1 or later, none loaded from outside the bundle"
