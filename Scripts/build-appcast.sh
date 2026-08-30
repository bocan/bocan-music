#!/usr/bin/env bash
# build-appcast.sh: assemble the Sparkle feeds for the website from
#   1. the frozen seed feeds in website/appcast/ (history up to the cut-over;
#      never written by CI again), and
#   2. the signed appcast-entry.xml asset every release since then carries.
#
# Writes website/static/appcast.xml and website/static/appcast-beta.xml
# (gitignored) for Eleventy's passthrough copy. main stays source-only: no
# workflow commits an appcast any more (ADR-033, slice 3).
#
# Usage: Scripts/build-appcast.sh [--offline]
#   --offline   Copy the seeds only (no GitHub calls). Used for local site
#               builds without gh; the deployed site always runs online.
#
# Safety: an entry whose minimumSystemVersion disagrees with project.yml's
# MACOSX_DEPLOYMENT_TARGET fails the build (old assets carried a wrong 26.0
# floor that hid updates from macOS 15 users), and the output must never
# have fewer items than the seed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_DIR="$ROOT/website/appcast"
OUT_DIR="$ROOT/website/static"
REPO="${RELEASE_REPO:-bocan/bocan-music}"
OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

die() { echo "build-appcast.sh: $*" >&2; exit 1; }

[[ -f "$SEED_DIR/seed.xml" && -f "$SEED_DIR/seed-beta.xml" ]] || die "seed feeds missing in $SEED_DIR"

MIN_OS="$(awk -F'"' '/MACOSX_DEPLOYMENT_TARGET/ { print $2; exit }' "$ROOT/project.yml")"
[[ -n "$MIN_OS" ]] || die "could not read MACOSX_DEPLOYMENT_TARGET from project.yml"

mkdir -p "$OUT_DIR"
cp "$SEED_DIR/seed.xml" "$OUT_DIR/appcast.xml"
cp "$SEED_DIR/seed-beta.xml" "$OUT_DIR/appcast-beta.xml"

if (( OFFLINE )); then
    echo "offline: wrote seed feeds only"
    exit 0
fi
command -v gh >/dev/null || die "gh is required (or pass --offline)"

# Newest version already in the seed; only releases after it are appended.
seed_newest="$(grep -oE 'shortVersionString>[^<]+' "$SEED_DIR/seed.xml" "$SEED_DIR/seed-beta.xml" \
    | sed 's/.*>//' | sort -V | tail -1)"
[[ -n "$seed_newest" ]] || die "seed has no entries"

append_entry() { # feed-file entry-file
    python3 - "$1" "$2" <<'PY'
import sys, pathlib
feed, entry = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
item = entry.read_text().strip()
indented = "\n".join(("    " + ln) if ln.strip() else "" for ln in item.splitlines())
text = feed.read_text()
assert "  </channel>" in text, "feed has no </channel>"
feed.write_text(text.replace("  </channel>", indented + "\n\n  </channel>", 1))
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
added=0

# Oldest first so the feed stays chronological like the seed.
gh release list --repo "$REPO" --limit 500 --json tagName,isDraft --jq '.[] | select(.isDraft | not) | .tagName' \
    | grep -E '^v[0-9]' | sort -V | while read -r tag; do
    version="${tag#v}"
    # Skip anything not newer than the seed's newest entry.
    [[ "$(printf '%s\n%s\n' "$seed_newest" "$version" | sort -V | tail -1)" == "$version" ]] || continue
    [[ "$version" != "$seed_newest" ]] || continue

    if ! gh release download "$tag" --repo "$REPO" -p appcast-entry.xml -O "$tmp/$tag.xml" 2>/dev/null; then
        echo "warning: $tag has no appcast-entry.xml asset (failed release?); skipped" >&2
        continue
    fi
    entry_min="$(grep -oE 'minimumSystemVersion>[^<]+' "$tmp/$tag.xml" | sed 's/.*>//')"
    [[ "$entry_min" == "$MIN_OS" ]] \
        || die "$tag entry says minimumSystemVersion $entry_min but project.yml says $MIN_OS; refusing to publish"

    if [[ "$version" == *-beta* || "$version" == *-rc* ]]; then
        append_entry "$OUT_DIR/appcast-beta.xml" "$tmp/$tag.xml"
    else
        append_entry "$OUT_DIR/appcast.xml" "$tmp/$tag.xml"
    fi
    echo "appended $tag"
    echo "$tag" >> "$tmp/added"
done

added=$( [[ -f "$tmp/added" ]] && wc -l < "$tmp/added" || echo 0 )
seed_items=$(grep -c '<item>' "$SEED_DIR/seed.xml")
out_items=$(grep -c '<item>' "$OUT_DIR/appcast.xml")
(( out_items >= seed_items )) || die "output has $out_items items, seed has $seed_items; refusing to publish a shrunken feed"
echo "appcast.xml: $out_items items ($added appended beyond seed $seed_newest)"
