#!/usr/bin/env bash
# build-release.sh — Local Developer ID signed build + notarization.
# Requires: APPLE_TEAM_ID, APPLE_ID, APP_SPECIFIC_PASSWORD env vars.
set -euo pipefail

SCHEME="Bocan"
CONFIG="Release"
ARCHIVE_PATH="build/Bocan.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="Scripts/ExportOptions.plist"

echo "=== Archiving ==="
xcodebuild archive \
    -project Bocan.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    | xcbeautify

echo "=== Exporting ==="
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    | xcbeautify

APP="$EXPORT_PATH/Bocan.app"
echo "=== Notarizing $APP ==="
xcrun notarytool submit "$APP" \
    --apple-id "${APPLE_ID:?Set APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}" \
    --password "${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD}" \
    --wait

echo "=== Stapling ==="
xcrun stapler staple "$APP"

echo "=== Done. App at: $APP ==="
