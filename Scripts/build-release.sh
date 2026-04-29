#!/usr/bin/env bash
# build-release.sh — Local Developer ID signed build + notarisation (arm64-only).
#
# Required env:
#   APPLE_TEAM_ID, APPLE_ID, APP_SPECIFIC_PASSWORD, DEVELOPER_ID_IDENTITY
#
# Usage:
#   Scripts/build-release.sh [--dry-run] [--skip-dmg]

set -euo pipefail

DRY_RUN=0
SKIP_DMG=0
while (( $# > 0 )); do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --skip-dmg) SKIP_DMG=1; shift ;;
        *) echo "unknown: $1" >&2; exit 2 ;;
    esac
done

SCHEME="Bocan"
CONFIG="Release"
ARCHIVE_PATH="build/Bocan.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="Scripts/ExportOptions.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run() {
    printf '+ %s\n' "$*"
    if (( DRY_RUN == 0 )); then "$@"; fi
}

echo "=== Archiving (arm64) ==="
run xcodebuild archive \
    -project Bocan.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS,arch=arm64' \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

echo "=== Exporting ==="
run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH"

APP="$EXPORT_PATH/Bocan.app"

echo "=== Deep-signing + notarising $APP ==="
SIGN_ARGS=()
if (( DRY_RUN )); then SIGN_ARGS+=(--dry-run); fi
run "$SCRIPT_DIR/sign-and-notarize.sh" "$APP" "${SIGN_ARGS[@]}"

if (( SKIP_DMG )); then
    echo "=== Skipping DMG (--skip-dmg) ==="
    exit 0
fi

echo "=== Building DMG ==="
DMG_ARGS=("$APP")
if (( DRY_RUN )); then DMG_ARGS+=(--dry-run); fi
run "$SCRIPT_DIR/make-dmg.sh" "${DMG_ARGS[@]}"

echo "=== Done. App at: $APP ==="
