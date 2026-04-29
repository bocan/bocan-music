#!/usr/bin/env bash
# sparkle-update.sh — Generate a signed Sparkle <item> entry for one release.
#
# Sparkle 2 ships a `sign_update` tool with the SPM artefact bundle. We locate
# it dynamically; in CI we expect SPARKLE_BIN_DIR to point at the directory
# containing `sign_update`.
#
# Usage:
#   Scripts/sparkle-update.sh \
#       --dmg build/Bocan-0.2.0.dmg \
#       --version 0.2.0 \
#       --build  1745939999 \
#       --output build/appcast-entry.xml \
#       [--channel stable|beta] [--dry-run]
#
# Required env:
#   SPARKLE_ED_PRIVATE_KEY  EdDSA private key (single-line base64). Optional in
#                           --dry-run; skipped if unset.

set -euo pipefail

DMG=""
VERSION=""
BUILD=""
OUTPUT=""
CHANNEL="stable"
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --dmg)     DMG="$2"; shift 2 ;;
        --version) VERSION="${2#v}"; shift 2 ;;
        --build)   BUILD="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  echo "unexpected: $1" >&2; exit 2 ;;
    esac
done

for var in DMG VERSION BUILD OUTPUT; do
    if [[ -z "${!var}" ]]; then
        echo "error: --${var,,} is required" >&2
        exit 2
    fi
done

if [[ ! -f "$DMG" ]] && (( DRY_RUN == 0 )); then
    echo "error: $DMG not found" >&2
    exit 1
fi

# Find sign_update.
find_sign_update() {
    if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "$SPARKLE_BIN_DIR/sign_update" ]]; then
        echo "$SPARKLE_BIN_DIR/sign_update"; return 0
    fi
    while IFS= read -r -d '' candidate; do
        if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
    done < <(find ~/Library/Developer/Xcode/DerivedData -type f -name sign_update -print0 2>/dev/null)
    return 1
}

SIGNATURE=""
LENGTH=0
if (( DRY_RUN == 0 )); then
    if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        echo "warning: SPARKLE_ED_PRIVATE_KEY not set — emitting unsigned entry" >&2
    else
        if SIGN_TOOL="$(find_sign_update)"; then
            : > /tmp/sparkle.key
            chmod 600 /tmp/sparkle.key
            printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" > /tmp/sparkle.key
            SIGNATURE="$("$SIGN_TOOL" --ed-key-file /tmp/sparkle.key "$DMG" 2>/dev/null || true)"
            shred -u /tmp/sparkle.key 2>/dev/null || rm -f /tmp/sparkle.key
        else
            echo "warning: sign_update not located — emitting unsigned entry" >&2
        fi
    fi
    LENGTH=$(stat -f%z "$DMG")
fi

PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
URL="https://github.com/bocan/bocan-music/releases/download/v${VERSION}/$(basename "$DMG")"
NOTES_URL="https://github.com/bocan/bocan-music/releases/tag/v${VERSION}"

mkdir -p "$(dirname "$OUTPUT")"
{
    cat <<XML
<item>
  <title>Bòcan ${VERSION}</title>
  <pubDate>${PUBDATE}</pubDate>
  <sparkle:channel>${CHANNEL}</sparkle:channel>
  <sparkle:version>${BUILD}</sparkle:version>
  <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
  <enclosure
    url="${URL}"
    sparkle:edSignature="${SIGNATURE}"
    length="${LENGTH}"
    type="application/octet-stream" />
</item>
XML
} > "$OUTPUT"

echo "wrote $OUTPUT"
