#!/usr/bin/env bash
# build-fpcalc.sh — builds fpcalc from source against the project's LGPL
# FFmpeg and bundles it, with every dylib it needs, into Resources/ with paths
# rewritten to @loader_path, so the app is self-contained and works in the
# sandbox.
#
# fpcalc is not taken from Homebrew: Homebrew's `chromaprint` depends on
# Homebrew's `ffmpeg`, which is a GPLv3 build (ADR-096). Building it here
# makes fpcalc use the same FFmpeg as the app.
#
# What it does:
#   1. Builds the LGPL FFmpeg if it is not there (Scripts/build-ffmpeg-lgpl.sh).
#   2. Downloads the pinned Chromaprint source (.chromaprint-source), refuses a
#      wrong checksum, and builds fpcalc and libchromaprint with CMake.
#   3. Empties Resources/ of the previous fpcalc and dylibs, then copies fpcalc
#      and, recursively, every dylib it needs that is not a system library.
#   4. Rewrites every such reference to @loader_path/<name> so they resolve
#      relative to Resources/ at runtime.
#   5. Ad-hoc or developer-signs every binary (ad-hoc works for Debug builds;
#      CI/release builds pass a real identity via $SIGNING_IDENTITY).
#
# Prerequisites: brew bundle (cmake, lame, opus, openssl@3).
# Run once after bootstrap; re-run when .ffmpeg-source or .chromaprint-source
# changes.
#
# Usage:
#   bash Scripts/build-fpcalc.sh                  # ad-hoc sign
#   bash Scripts/build-fpcalc.sh "Developer ID"   # real sign for distribution
#   SIGNING_IDENTITY="Developer ID" bash Scripts/build-fpcalc.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$(cd "$ROOT/Resources" && pwd)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${1:-"-"}}"

PIN_FILE="${CHROMAPRINT_SOURCE_FILE:-$ROOT/.chromaprint-source}"
FFMPEG_PREFIX="${FFMPEG_PREFIX:-$ROOT/build/ffmpeg-lgpl}"
CHROMA_PREFIX="${CHROMAPRINT_PREFIX:-$ROOT/build/chromaprint}"
WORK="${CHROMAPRINT_WORK_DIR:-$ROOT/build/chromaprint-src}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# Temp file tracking which dylib basenames we've already bundled (replaces
# associative arrays, which require bash 4+ and macOS ships 3.2).
SEEN_FILE="$(mktemp)"
trap 'rm -f "$SEEN_FILE"' EXIT

# ── the LGPL FFmpeg ───────────────────────────────────────────────────────────

FFMPEG_PREFIX="$FFMPEG_PREFIX" bash "$SCRIPT_DIR/build-ffmpeg-lgpl.sh"
# Canonical paths: the install names inside the dylibs are compared with these.
FFMPEG_PREFIX="$(cd "$FFMPEG_PREFIX" && pwd -P)"

# ── Chromaprint from source ───────────────────────────────────────────────────

[[ -f "$PIN_FILE" ]] || fail "$PIN_FILE is missing."
# shellcheck disable=SC1090
source "$PIN_FILE"
[[ -n "${CHROMAPRINT_VERSION:-}" && -n "${CHROMAPRINT_URL:-}" && -n "${CHROMAPRINT_SHA256:-}" ]] \
    || fail "$PIN_FILE must set CHROMAPRINT_VERSION, CHROMAPRINT_URL and CHROMAPRINT_SHA256."
command -v cmake > /dev/null || fail "cmake is not installed. Run: brew bundle"

# What this prefix was built from: the pin, the FFmpeg it links, this script.
STAMP="$(
    {
        grep -v '^#' "$PIN_FILE"
        cat "$FFMPEG_PREFIX/.built-from"
        shasum -a 256 "$0" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
)"

if [[ -f "$CHROMA_PREFIX/.built-from" && "$(cat "$CHROMA_PREFIX/.built-from")" == "$STAMP" ]]; then
    echo "✓ Chromaprint $CHROMAPRINT_VERSION is up to date in $CHROMA_PREFIX"
else
    echo "=== build-fpcalc: Chromaprint $CHROMAPRINT_VERSION into $CHROMA_PREFIX ==="
    mkdir -p "$WORK"
    TARBALL="$WORK/$(basename "$CHROMAPRINT_URL")"
    if [[ ! -f "$TARBALL" ]]; then
        echo "--- download $CHROMAPRINT_URL"
        curl -fsSL --retry 3 -o "$TARBALL.part" "$CHROMAPRINT_URL"
        mv "$TARBALL.part" "$TARBALL"
    fi
    actual_sha="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [[ "$actual_sha" != "$CHROMAPRINT_SHA256" ]]; then
        rm -f "$TARBALL"
        fail "checksum mismatch for $(basename "$TARBALL"): got $actual_sha, pinned $CHROMAPRINT_SHA256. The download is deleted."
    fi
    echo "--- checksum ok"

    SRC="$WORK/chromaprint-$CHROMAPRINT_VERSION"
    rm -rf "$SRC" "$WORK/cmake-build" "$CHROMA_PREFIX"
    tar -xzf "$TARBALL" -C "$WORK"
    [[ -f "$SRC/CMakeLists.txt" ]] || fail "the tarball did not unpack to $SRC"

    echo "--- configure and build"
    # FFMPEG_ROOT and the prefix-only PKG_CONFIG_PATH keep CMake away from a
    # Homebrew FFmpeg. vDSP (Accelerate) does the FFT, so no FFT library is
    # linked.
    (
        PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig" cmake \
            -S "$SRC" -B "$WORK/cmake-build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CHROMA_PREFIX" \
            -DCMAKE_INSTALL_NAME_DIR="$CHROMA_PREFIX/lib" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
            -DFFMPEG_ROOT="$FFMPEG_PREFIX" \
            -DBUILD_TOOLS=ON -DBUILD_TESTS=OFF -DBUILD_SHARED_LIBS=ON \
            -DFFT_LIB=vdsp -DAUDIO_PROCESSOR_LIB=swresample
        cmake --build "$WORK/cmake-build" --parallel "$(sysctl -n hw.ncpu)"
        cmake --install "$WORK/cmake-build"
    ) > "$WORK/build.log" 2>&1 || {
        tail -30 "$WORK/build.log" >&2
        fail "the Chromaprint build failed; the full log is $WORK/build.log"
    }
    [[ -x "$CHROMA_PREFIX/bin/fpcalc" ]] || fail "fpcalc was not built at $CHROMA_PREFIX/bin/fpcalc"
    echo "$STAMP" > "$CHROMA_PREFIX/.built-from"
    rm -rf "$SRC" "$WORK/cmake-build"
fi
CHROMA_PREFIX="$(cd "$CHROMA_PREFIX" && pwd -P)"

# ── helpers ───────────────────────────────────────────────────────────────────

is_system_path() {
    local p="$1"
    [[ "$p" == /usr/lib/*             ]] && return 0
    [[ "$p" == /System/*              ]] && return 0
    [[ "$p" == @rpath/*               ]] && return 0
    [[ "$p" == @loader_path/*         ]] && return 0
    [[ "$p" == @executable_path/*     ]] && return 0
    return 1
}

# A dylib we must carry: one from the two source builds, or one of the
# Homebrew libraries the LGPL FFmpeg links (lame, opus, openssl).
is_bundled_path() {
    local p="$1"
    [[ "$p" == "$FFMPEG_PREFIX"/* ]] && return 0
    [[ "$p" == "$CHROMA_PREFIX"/* ]] && return 0
    [[ "$p" == /opt/homebrew/*    ]] && return 0
    [[ "$p" == /usr/local/*       ]] && return 0
    return 1
}

already_seen() {
    grep -qxF "$1" "$SEEN_FILE" 2>/dev/null
}

mark_seen() {
    echo "$1" >> "$SEEN_FILE"
}

# bundle_lib <src-path>
#   Copies a dylib into Resources/, rewrites its install name and all the
#   references it holds to other bundled dylibs, then recurses into its deps.
bundle_lib() {
    local src="$1"
    local name
    name="$(basename "$src")"

    already_seen "$name" && return 0
    mark_seen "$name"

    local dst="$RESOURCES/$name"
    echo "  bundle  $name"
    # -L dereferences symlinks so we copy the real file, not a symlink.
    cp -L "$src" "$dst"
    chmod 755 "$dst"

    # Fix this dylib's own install name so other binaries can link it.
    local own_id
    own_id="$(otool -D "$dst" 2>/dev/null | tail -1)"
    if is_bundled_path "$own_id"; then
        install_name_tool -id "@loader_path/$name" "$dst"
    fi

    # Rewrite all bundled-path deps to @loader_path/<name>.
    while IFS= read -r dep; do
        is_system_path "$dep"  && continue
        is_bundled_path "$dep" || continue
        local dep_name
        dep_name="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$dst"
    done < <(otool -L "$dst" 2>/dev/null | awk 'NR>1{print $1}')

    # Recurse: bundle the libs this lib itself depends on.
    while IFS= read -r dep; do
        is_system_path "$dep"  && continue
        is_bundled_path "$dep" || continue
        bundle_lib "$dep"
    done < <(otool -L "$src" 2>/dev/null | awk 'NR>1{print $1}')
}

# relink_exe <dst-path>
#   Rewrites bundled-path dep references in an already-copied executable.
relink_exe() {
    local dst="$1"
    echo "  relink  $(basename "$dst")"
    while IFS= read -r dep; do
        is_system_path "$dep"  && continue
        is_bundled_path "$dep" || continue
        local dep_name
        dep_name="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$dst"
    done < <(otool -L "$dst" 2>/dev/null | awk 'NR>1{print $1}')
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "=== build-fpcalc: bundling self-contained fpcalc into Resources/ ==="
echo "    fpcalc : $CHROMA_PREFIX"
echo "    ffmpeg : $FFMPEG_PREFIX"
echo "    target : $RESOURCES"
echo ""

# 0. Remove the previous bundle. A dylib that is no longer needed (the
#    libx264 and libx265 of the Homebrew build, for example) must not stay
#    behind and ship.
rm -f "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib

# 1. Copy fpcalc and mark it as seen so bundle_lib won't try to copy it again.
echo "  copy    fpcalc"
cp "$CHROMA_PREFIX/bin/fpcalc" "$RESOURCES/fpcalc"
chmod 755 "$RESOURCES/fpcalc"
mark_seen "fpcalc"

# 2. Bundle libchromaprint and all its transitive deps.
CHROMA_LIB="$(ls "$CHROMA_PREFIX"/lib/libchromaprint.[0-9].dylib 2>/dev/null | head -1)"
[[ -n "$CHROMA_LIB" ]] || fail "no libchromaprint in $CHROMA_PREFIX/lib"
bundle_lib "$CHROMA_LIB"

# 3. Bundle every dep of fpcalc itself (the FFmpeg quartet + anything else).
while IFS= read -r dep; do
    is_system_path "$dep"  && continue
    is_bundled_path "$dep" || continue
    bundle_lib "$dep"
done < <(otool -L "$CHROMA_PREFIX/bin/fpcalc" 2>/dev/null | awk 'NR>1{print $1}')

# 4. Rewrite fpcalc's own dep references now that every dep is in Resources/.
relink_exe "$RESOURCES/fpcalc"

# 5. Final @rpath sweep.
#
#    fpcalc can reference libchromaprint via @rpath rather than an absolute
#    path. The steps above only rewrite absolute paths, so @rpath references
#    are left intact. Now that every bundled dylib is in Resources/ we can
#    resolve them: for each binary, replace "@rpath/<name>" with
#    "@loader_path/<name>" whenever <name> is a file we placed in Resources/.
#    We also strip the stale LC_RPATH entries so dyld never tries the old path.

echo ""
echo "--- fixing @rpath references ---"
for f in "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib; do
    [[ -f "$f" ]] || continue
    while IFS= read -r dep; do
        [[ "$dep" == @rpath/* ]] || continue
        dep_name="${dep#@rpath/}"
        if [[ ! -f "$RESOURCES/$dep_name" && -f "$CHROMA_PREFIX/lib/$dep_name" ]]; then
            bundle_lib "$CHROMA_PREFIX/lib/$dep_name"
        fi
        [[ -f "$RESOURCES/$dep_name" ]] || continue
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$f"
        echo "  @rpath→@loader_path  $dep_name  in $(basename "$f")"
    done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}')

    # Strip embedded rpaths — they point into the build prefixes and are stale.
    while IFS= read -r rp; do
        install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
    done < <(otool -l "$f" 2>/dev/null \
        | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}')
done

# ── signing ───────────────────────────────────────────────────────────────────

echo ""
echo "--- signing (identity: $SIGNING_IDENTITY) ---"
for f in "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib; do
    [[ -f "$f" ]] || continue
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        # Ad-hoc: no timestamp or hardened runtime (local dev / Debug only).
        codesign --force --sign "$SIGNING_IDENTITY" "$f"
    else
        # Developer ID: hardened runtime + secure timestamp required by notarization.
        codesign --force --sign "$SIGNING_IDENTITY" \
            --options runtime \
            --timestamp \
            "$f"
    fi
    echo "  signed  $(basename "$f")"
done

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== bundled files ==="
ls -lh "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib
echo ""
echo "Verify with:  otool -L Resources/fpcalc"
echo "Done."
