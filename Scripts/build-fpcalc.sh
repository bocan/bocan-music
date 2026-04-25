#!/usr/bin/env bash
# build-fpcalc.sh — fetches and packages a fat (arm64 + x86_64) fpcalc binary
# for inclusion in the Bòcan app bundle under Resources/fpcalc.
#
# Requires: Homebrew, chromaprint, lipo, codesign
# Usage: ./Scripts/build-fpcalc.sh [signing-identity]
#
# The signing identity defaults to the value of CODE_SIGN_IDENTITY in the
# environment (set automatically by Xcode during a build phase run).

set -euo pipefail

SIGNING_IDENTITY="${1:-${CODE_SIGN_IDENTITY:-"-"}}"
DEST="Resources/fpcalc"

echo "==> Building fat fpcalc binary"

# Install chromaprint if not present.
if ! command -v fpcalc &>/dev/null; then
  echo "  Installing chromaprint via Homebrew..."
  brew install chromaprint
fi

FPCALC_PATH="$(command -v fpcalc)"
echo "  Found fpcalc at: $FPCALC_PATH"

# Copy the native binary.
cp "$FPCALC_PATH" "$DEST"

echo "  Copied to $DEST"
echo "  Architecture: $(file "$DEST")"

# Sign the binary (required for sandboxed apps).
if [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "  Signing with identity: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$DEST"
  echo "  Signed."
else
  echo "  Skipping code-sign (no identity provided — ad-hoc signing only in dev builds)."
  codesign --force --sign - "$DEST"
fi

echo "==> Done: $DEST"
