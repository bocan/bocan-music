#!/usr/bin/env bash
# build-fpcalc.sh — bundles fpcalc + all required FFmpeg/Chromaprint dylibs
# into Resources/ with paths rewritten to @loader_path so the app is
# self-contained and works in the sandbox without Homebrew present.
#
# What it does:
#   1. Copies fpcalc and libchromaprint from the chromaprint Homebrew prefix.
#   2. Recursively walks every dylib dependency that lives under HOMEBREW_PREFIX
#      (skipping /usr/lib, /System, @rpath etc.) and copies each one.
#   3. Rewrites every Homebrew-path reference inside each copied binary to
#      @loader_path/<name> so they resolve relative to Resources/ at runtime.
#   4. Ad-hoc or developer-signs every binary (ad-hoc works for Debug builds;
#      CI/release builds pass a real identity via $SIGNING_IDENTITY).
#
# Prerequisites: brew install chromaprint ffmpeg
# Run once after bootstrap; re-run when chromaprint or ffmpeg is upgraded.
#
# Usage:
#   bash Scripts/build-fpcalc.sh                  # ad-hoc sign
#   bash Scripts/build-fpcalc.sh "Developer ID"   # real sign for distribution
#   SIGNING_IDENTITY="Developer ID" bash Scripts/build-fpcalc.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES="$(cd "$SCRIPT_DIR/../Resources" && pwd)"
HOMEBREW="$(brew --prefix)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${1:-"-"}}"

# Temp file tracking which dylib basenames we've already bundled (replaces
# associative arrays, which require bash 4+ and macOS ships 3.2).
SEEN_FILE="$(mktemp)"
trap 'rm -f "$SEEN_FILE"' EXIT

# ── pre-flight ────────────────────────────────────────────────────────────────

CHROMA_PREFIX="$(brew --prefix chromaprint 2>/dev/null)" || {
    echo "ERROR: chromaprint is not installed."
    echo "       Run: brew install chromaprint"
    exit 1
}

[[ -x "$CHROMA_PREFIX/bin/fpcalc" ]] || {
    echo "ERROR: fpcalc not found at $CHROMA_PREFIX/bin/fpcalc"
    exit 1
}

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

is_homebrew_path() {
    local p="$1"
    [[ "$p" == /opt/homebrew/* ]] && return 0
    [[ "$p" == /usr/local/*    ]] && return 0
    return 1
}

already_seen() {
    grep -qxF "$1" "$SEEN_FILE" 2>/dev/null
}

mark_seen() {
    echo "$1" >> "$SEEN_FILE"
}

# bundle_lib <src-path>
#   Copies a Homebrew dylib into Resources/, rewrites its install name and all
#   its Homebrew dep references, then recurses into its own deps.
bundle_lib() {
    local src="$1"
    local name
    name="$(basename "$src")"

    already_seen "$name" && return 0
    mark_seen "$name"

    local dst="$RESOURCES/$name"
    echo "  bundle  $name"
    cp "$src" "$dst"
    chmod 755 "$dst"

    # Fix this dylib's own install name so other binaries can link it.
    local own_id
    own_id="$(otool -D "$dst" 2>/dev/null | tail -1)"
    if is_homebrew_path "$own_id"; then
        install_name_tool -id "@loader_path/$name" "$dst"
    fi

    # Rewrite all Homebrew-path deps to @loader_path/<name>.
    while IFS= read -r dep; do
        is_system_path "$dep"   && continue
        is_homebrew_path "$dep" || continue
        local dep_name
        dep_name="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$dst"
    done < <(otool -L "$dst" 2>/dev/null | awk 'NR>1{print $1}')

    # Recurse: bundle any Homebrew libs this lib itself depends on.
    while IFS= read -r dep; do
        is_system_path "$dep"   && continue
        is_homebrew_path "$dep" || continue
        bundle_lib "$dep"
    done < <(otool -L "$src" 2>/dev/null | awk 'NR>1{print $1}')
}

# relink_exe <dst-path>
#   Rewrites Homebrew dep references in an already-copied executable.
relink_exe() {
    local dst="$1"
    echo "  relink  $(basename "$dst")"
    while IFS= read -r dep; do
        is_system_path "$dep"   && continue
        is_homebrew_path "$dep" || continue
        local dep_name
        dep_name="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$dst"
    done < <(otool -L "$dst" 2>/dev/null | awk 'NR>1{print $1}')
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "=== build-fpcalc: bundling self-contained fpcalc into Resources/ ==="
echo "    source : $CHROMA_PREFIX"
echo "    target : $RESOURCES"
echo ""

# 1. Copy fpcalc and mark it as seen so bundle_lib won't try to copy it again.
echo "  copy    fpcalc"
cp "$CHROMA_PREFIX/bin/fpcalc" "$RESOURCES/fpcalc"
chmod 755 "$RESOURCES/fpcalc"
mark_seen "fpcalc"

# 2. Bundle libchromaprint and all its transitive Homebrew deps.
bundle_lib "$CHROMA_PREFIX/lib/libchromaprint.1.dylib"

# 3. Bundle every Homebrew dep of fpcalc itself (the FFmpeg quartet + anything else).
while IFS= read -r dep; do
    is_system_path "$dep"   && continue
    is_homebrew_path "$dep" || continue
    bundle_lib "$dep"
done < <(otool -L "$CHROMA_PREFIX/bin/fpcalc" 2>/dev/null | awk 'NR>1{print $1}')

# 4. Rewrite fpcalc's own dep references now that every dep is in Resources/.
relink_exe "$RESOURCES/fpcalc"

# ── signing ───────────────────────────────────────────────────────────────────

echo ""
echo "--- signing (identity: $SIGNING_IDENTITY) ---"
for f in "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib; do
    [[ -f "$f" ]] || continue
    codesign --force --sign "$SIGNING_IDENTITY" "$f"
    echo "  signed  $(basename "$f")"
done

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== bundled files ==="
ls -lh "$RESOURCES/fpcalc" "$RESOURCES"/*.dylib
echo ""
echo "Verify with:  otool -L Resources/fpcalc"
echo "Done."
