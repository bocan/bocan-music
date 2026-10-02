#!/usr/bin/env bash
# Builds the FFmpeg that Bòcan links, from source, under the LGPL (ADR-096).
#
# Every build of the app uses this FFmpeg: Debug, the test suites, CI and the
# release. Homebrew's `ffmpeg` formula is a GPLv3 build with libx264 and
# libx265, which the project has ruled out since ADR-002; it is not used and
# need not be installed.
#
# What it does:
#   1. Reads the pinned version, URL and SHA-256 from .ffmpeg-source.
#   2. Downloads the tarball, and refuses it when the checksum differs.
#   3. Configures (the line below), builds and installs into $PREFIX.
#   4. Refuses the result unless libavutil reports "LGPL version 2.1 or later".
#
# It is idempotent: when $PREFIX was built from the same pin, the same
# configure line and the same version of this script, it does nothing.
#
# Usage:
#   Scripts/build-ffmpeg-lgpl.sh            # into build/ffmpeg-lgpl
#   FFMPEG_PREFIX=/some/dir Scripts/build-ffmpeg-lgpl.sh
#
# Needs from Homebrew: lame, opus, openssl@3, pkgconf (see Brewfile).
#
# Rules for whoever edits the configure line:
#   - --enable-gpl and --enable-version3 never appear. There is no
#     --disable-gpl: the LGPL is what you get by not asking for the GPL.
#   - Decoders, demuxers, parsers and protocols are not cut down with
#     --disable-everything. The app's promise is that an unknown file goes to
#     FFmpeg; a hand-kept allow-list would break that one format at a time.
#   - A new --enable-lib* needs the library's licence named in the PR, from
#     LICENSE.md in the pinned source.
#   - Never add `|| true` after the checksum check, the build or the licence
#     check. The defect this script fixes lasted five months because a step
#     could not fail.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="${FFMPEG_SOURCE_FILE:-$ROOT/.ffmpeg-source}"
PREFIX="${FFMPEG_PREFIX:-$ROOT/build/ffmpeg-lgpl}"
WORK="${FFMPEG_WORK_DIR:-$ROOT/build/ffmpeg-src}"
# The app's deployment target (project.yml). Without it the libraries are
# built for the build machine's macOS only.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

fail() {
    echo "✗ $1" >&2
    exit 1
}

[[ -f "$PIN_FILE" ]] || fail "$PIN_FILE is missing."
# shellcheck disable=SC1090
source "$PIN_FILE"
[[ -n "${FFMPEG_VERSION:-}" && -n "${FFMPEG_URL:-}" && -n "${FFMPEG_SHA256:-}" ]] \
    || fail "$PIN_FILE must set FFMPEG_VERSION, FFMPEG_URL and FFMPEG_SHA256."

command -v brew > /dev/null || fail "Homebrew is required for lame, opus and openssl@3."
for formula in lame opus openssl@3; do
    brew --prefix "$formula" > /dev/null 2>&1 || fail "$formula is not installed. Run: brew bundle"
    [[ -d "$(brew --prefix "$formula")/lib" ]] || fail "$formula is not installed. Run: brew bundle"
done
LAME_PREFIX="$(brew --prefix lame)"
OPUS_PREFIX="$(brew --prefix opus)"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"

CONFIGURE_ARGS=(
    --prefix="$PREFIX"
    --enable-shared --disable-static
    --disable-programs --disable-doc --disable-debug
    --disable-nonfree
    # Without this, configure links whatever it finds on the build machine
    # (libX11, libxcb and SDL2 on a machine that has them), so two machines
    # build two different libraries. The system libraries the demuxers use
    # are named instead. iconv is left out: only subtitle decoding uses it.
    --disable-autodetect
    --enable-zlib --enable-bzlib
    --disable-avdevice --disable-avfilter --disable-swscale
    --disable-encoders --enable-encoder=libmp3lame --enable-encoder=libopus
    --disable-muxers --enable-muxer=mp3 --enable-muxer=ogg --enable-muxer=opus
    --disable-hwaccels --disable-videotoolbox
    --enable-audiotoolbox
    --enable-libmp3lame --enable-libopus
    --enable-openssl
    --enable-neon
    --arch=arm64 --cc=clang
    --install-name-dir="$PREFIX/lib"
    --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -I$LAME_PREFIX/include"
    --extra-ldflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -L$LAME_PREFIX/lib"
)

# The stamp: what this prefix was built from. A change to the pin, to the
# configure line or to this script makes the next run build again.
STAMP="$(
    {
        grep -v '^#' "$PIN_FILE"
        printf '%s\n' "${CONFIGURE_ARGS[@]}"
        shasum -a 256 "$0" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
)"
if [[ -f "$PREFIX/.built-from" && "$(cat "$PREFIX/.built-from")" == "$STAMP" ]]; then
    echo "✓ FFmpeg $FFMPEG_VERSION (LGPL) is up to date in $PREFIX"
    exit 0
fi

echo "=== build-ffmpeg-lgpl: FFmpeg $FFMPEG_VERSION into $PREFIX ==="

mkdir -p "$WORK"
TARBALL="$WORK/$(basename "$FFMPEG_URL")"
if [[ ! -f "$TARBALL" ]]; then
    echo "--- download $FFMPEG_URL"
    curl -fsSL --retry 3 -o "$TARBALL.part" "$FFMPEG_URL"
    mv "$TARBALL.part" "$TARBALL"
fi

actual_sha="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$actual_sha" != "$FFMPEG_SHA256" ]]; then
    rm -f "$TARBALL"
    fail "checksum mismatch for $(basename "$TARBALL"): got $actual_sha, pinned $FFMPEG_SHA256. The download is deleted."
fi
echo "--- checksum ok"

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
rm -rf "$SRC"
tar -xf "$TARBALL" -C "$WORK"
[[ -x "$SRC/configure" ]] || fail "the tarball did not unpack to $SRC"

# A stale prefix must not leave an old library beside the new ones.
rm -rf "$PREFIX"

echo "--- configure"
(
    cd "$SRC"
    PKG_CONFIG_PATH="$OPUS_PREFIX/lib/pkgconfig:$OPENSSL_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        ./configure "${CONFIGURE_ARGS[@]}" > "$WORK/configure.log" 2>&1
) || {
    tail -30 "$WORK/configure.log" >&2
    fail "configure failed; the full log is $WORK/configure.log"
}
grep -E '^License:' "$WORK/configure.log" || true

echo "--- build ($(sysctl -n hw.ncpu) jobs)"
(
    cd "$SRC"
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" make -j"$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" make install >> "$WORK/build.log" 2>&1
) || {
    tail -30 "$WORK/build.log" >&2
    fail "the build failed; the full log is $WORK/build.log"
}

# The result must say what it is. This is the same string the release gate
# (Scripts/check-bundle-licence.sh) reads.
AVUTIL="$(ls "$PREFIX"/lib/libavutil.*.dylib 2>/dev/null | head -1)"
[[ -n "$AVUTIL" ]] || fail "no libavutil in $PREFIX/lib after the build"
# Read the strings once into a variable: `strings | grep -q` under pipefail
# fails when grep closes the pipe early, and would report a false mismatch.
AVUTIL_STRINGS="$(strings -a "$AVUTIL")"
if ! grep -q 'LGPL version 2\.1 or later' <<< "$AVUTIL_STRINGS"; then
    fail "the built libavutil does not report 'LGPL version 2.1 or later'"
fi
if grep -q -E -- '--enable-(gpl|version3|nonfree)( |$)' <<< "$AVUTIL_STRINGS"; then
    fail "the built libavutil was configured with a GPL, version 3 or nonfree flag"
fi

echo "$STAMP" > "$PREFIX/.built-from"
rm -rf "$SRC"

echo "✓ FFmpeg $FFMPEG_VERSION built under the LGPL v2.1 or later:"
ls "$PREFIX"/lib/*.dylib | sed 's/^/    /'
