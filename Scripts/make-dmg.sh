#!/usr/bin/env bash
# make-dmg.sh — Build a signed, notarised, stapled DMG from a built .app.
#
# Usage:
#   Scripts/make-dmg.sh <path-to-.app> [--version <semver>] [--output <dmg>] [--dry-run]
#
# Steps:
#   1. create-dmg with the project's window + icon layout.
#   2. codesign the DMG.
#   3. notarytool submit + wait.
#   4. stapler staple.
#   5. shasum -a 256 → <dmg>.sha256.

set -euo pipefail

APP_PATH=""
VERSION="${MARKETING_VERSION:-0.0.0}"
VERSION="${VERSION#v}"
OUTPUT=""
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --version) VERSION="${2#v}"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  APP_PATH="$1"; shift ;;
    esac
done

if [[ -z "$APP_PATH" ]]; then
    echo "usage: make-dmg.sh <path-to-.app> [--version X.Y.Z] [--output file.dmg] [--dry-run]" >&2
    exit 2
fi

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="build/Bocan-${VERSION}.dmg"
fi

mkdir -p "$(dirname "$OUTPUT")"
STAGING="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING/"

run() {
    printf '+ %s\n' "$*"
    if (( DRY_RUN == 0 )); then "$@"; fi
}

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not found. brew install create-dmg." >&2
    exit 1
fi

echo "=== Building DMG ==="
DMG_ATTEMPT=0
until run create-dmg \
    --volname "Bòcan ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "Bocan.app" 175 190 \
    --hide-extension "Bocan.app" \
    --app-drop-link 425 190 \
    "$OUTPUT" \
    "$STAGING/" ; do
    DMG_ATTEMPT=$((DMG_ATTEMPT + 1))
    if (( DMG_ATTEMPT >= 3 )); then
        echo "error: create-dmg failed after $DMG_ATTEMPT attempts" >&2
        exit 1
    fi
    echo "create-dmg failed; retrying in 5s ($DMG_ATTEMPT)..."
    sleep 5
done

if (( DRY_RUN )); then
    echo "=== Dry run — DMG built but not signed/notarised ==="
    exit 0
fi

if [[ -z "${DEVELOPER_ID_IDENTITY:-}" ]]; then
    echo "warning: DEVELOPER_ID_IDENTITY not set — skipping sign/notarise" >&2
else
    echo "=== Signing DMG ==="
    codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$OUTPUT"

    echo "=== Notarising DMG ==="
    : "${APPLE_ID:?set APPLE_ID}"
    : "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
    : "${APP_SPECIFIC_PASSWORD:?set APP_SPECIFIC_PASSWORD}"
    xcrun notarytool submit "$OUTPUT" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --wait

    echo "=== Stapling DMG ==="
    xcrun stapler staple "$OUTPUT"
fi

echo "=== Computing SHA-256 ==="
( cd "$(dirname "$OUTPUT")" && shasum -a 256 "$(basename "$OUTPUT")" | tee "$(basename "$OUTPUT").sha256" )

echo "=== Done: $OUTPUT ==="
