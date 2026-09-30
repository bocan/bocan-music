#!/usr/bin/env bash
# release-downloads.sh - Print GitHub Release DMG download counts, with the
# date each release was published.
#
# Counts are served by GitHub's public API from its own logs. Nothing on a
# user's machine is queried or contacted; this only reports how many DMGs left
# the shelf. No auth required for a public repo, but a GITHUB_TOKEN in the
# environment (if set) is used to lift the unauthenticated rate limit.
#
# Invoked by `make downloads`.
set -euo pipefail

REPO="${REPO:-bocan/bocan-music}"

auth=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

curl -fsSL "${auth[@]}" \
	-H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/${REPO}/releases?per_page=100" \
	| python3 -c '
import json, sys

repo = sys.argv[1]
data = json.load(sys.stdin)
if isinstance(data, dict):
    sys.exit("GitHub API error: " + str(data.get("message", data)))

rows, total = [], 0
for release in data:
    # published_at is an ISO 8601 UTC timestamp; a draft has none.
    date = (release.get("published_at") or "unpublished")[:10]
    for asset in release.get("assets", []):
        if asset["name"].endswith(".dmg"):
            count = asset["download_count"]
            total += count
            rows.append((release["tag_name"], date, count))

print("DMG downloads for " + repo + "\n")
for tag, date, count in rows:
    print(f"  {tag:<12} {date:<11} {count:>6}")
print("  " + "-" * 31)
label = "TOTAL"
print(f"  {label:<24} {total:>6}")
' "$REPO"
