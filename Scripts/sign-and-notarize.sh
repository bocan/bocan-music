#!/usr/bin/env bash
# sign-and-notarize.sh — Sign, notarise, and staple a built .app.
#
# Inside-out signing for nested frameworks, hardened runtime, timestamp.
# Submits to Apple notarytool and waits for the result, then staples.
#
# Required env:
#   DEVELOPER_ID_IDENTITY      e.g. "Developer ID Application: My Name (ABCDE12345)"
#   APPLE_ID                   Apple ID email used to log into developer.apple.com
#   APPLE_TEAM_ID              10-char team identifier
#   APP_SPECIFIC_PASSWORD      App-specific password for notarytool
#
# Usage:
#   Scripts/sign-and-notarize.sh <path-to-.app> [--entitlements <path>] [--dry-run]

set -euo pipefail

APP_PATH=""
ENTITLEMENTS="Resources/Bocan.entitlements"
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --entitlements) ENTITLEMENTS="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  APP_PATH="$1"; shift ;;
    esac
done

if [[ -z "$APP_PATH" ]]; then
    echo "usage: sign-and-notarize.sh <path-to-.app> [--entitlements <path>] [--dry-run]" >&2
    exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH is not a directory" >&2
    exit 1
fi

run() {
    if (( DRY_RUN )); then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*"
        "$@"
    fi
}

require() {
    if (( DRY_RUN )); then return 0; fi
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            echo "error: $var is required (set in env)" >&2
            exit 1
        fi
    done
}

require DEVELOPER_ID_IDENTITY APPLE_ID APPLE_TEAM_ID APP_SPECIFIC_PASSWORD

IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application}"

echo "=== Deep-signing nested frameworks ==="
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' framework; do
        run codesign --force --sign "$IDENTITY" \
            --options=runtime --timestamp "$framework"
    done < <(find "$APP_PATH/Contents/Frameworks" -type d \
        \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0)
fi

if [[ -d "$APP_PATH/Contents/Resources" ]]; then
    while IFS= read -r -d '' lib; do
        run codesign --force --sign "$IDENTITY" \
            --options=runtime --timestamp "$lib"
    done < <(find "$APP_PATH/Contents/Resources" -type f -name "*.dylib" -print0)
fi

echo "=== Signing app bundle ==="
SIGN_ARGS=(
    --force
    --sign "$IDENTITY"
    --options=runtime
    --timestamp
)
if [[ -f "$ENTITLEMENTS" ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
run codesign "${SIGN_ARGS[@]}" "$APP_PATH"

echo "=== Verifying signature ==="
run codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if (( DRY_RUN )); then
    echo "=== Dry run — skipping notarisation ==="
    exit 0
fi

echo "=== Notarising ==="
ZIP="${APP_PATH%.app}-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

echo "=== Stapling ==="
xcrun stapler staple "$APP_PATH"

echo "=== spctl assessment ==="
spctl --assess --type execute --verbose=4 "$APP_PATH" || {
    echo "warning: spctl rejected the app — check the output above" >&2
    exit 1
}

echo "=== Done: $APP_PATH ==="
