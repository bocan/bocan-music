#!/usr/bin/env bash
# Tests for Scripts/check-package-updates.py, hermetic: `gh` is a fake that
# answers from files, so no test reaches the network.
# Run: Scripts/tests/check-package-updates-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-package-updates.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# ── the fake gh ───────────────────────────────────────────────────────────────
# `gh api <path>` prints $API/<path with every other character as _>, or
# fails like a 404 when there is no such file.
API="$WORK/api"
FAKE_GH="$WORK/gh"
cat > "$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || exit 2
file="$FAKE_GH_API/$(printf '%s' "$2" | tr -c 'A-Za-z0-9.-' '_')"
[[ -f "$file" ]] || { echo '{"message":"Not Found"}'; exit 1; }
cat "$file"
EOF
chmod +x "$FAKE_GH"

# answer <api path> <json>
answer() {
    printf '%s\n' "$2" > "$API/$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_')"
}
release() { answer "repos/$1/releases/latest" "{\"tag_name\": \"$2\"}"; }
# tags <slug> <page> <tag>...
tags() {
    local slug="$1" page="$2" json="" tag
    shift 2
    for tag in "$@"; do json+="${json:+,}{\"name\": \"$tag\"}"; done
    answer "repos/$slug/tags?per_page=100&page=$page" "[$json]"
}

# ── the fixture repository ───────────────────────────────────────────────────
# reset: a repository where every pin is current, and an upstream that agrees.
reset() {
    rm -rf "$WORK/repo" "$API"
    mkdir -p "$API" "$WORK/repo/Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    cat > "$WORK/repo/Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'EOF'
{"pins": [
  {"identity": "grdb.swift", "location": "https://github.com/groue/GRDB.swift.git",
   "state": {"revision": "abc", "version": "7.11.1"}},
  {"identity": "sparkle", "location": "https://github.com/sparkle-project/Sparkle",
   "state": {"revision": "def", "version": "2.10.0"}}
]}
EOF
    printf '# The FFmpeg source release.\nFFMPEG_VERSION=9.0.2\nFFMPEG_URL=https://example.invalid/f.tar.xz\nFFMPEG_SHA256=00\n' \
        > "$WORK/repo/.ffmpeg-source"
    printf '# The Chromaprint source release.\nCHROMAPRINT_VERSION=1.6.1\nCHROMAPRINT_URL=https://example.invalid/c.tar.gz\nCHROMAPRINT_SHA256=00\n' \
        > "$WORK/repo/.chromaprint-source"
    echo "0.65.1" > "$WORK/repo/.swiftlint-version"
    echo "0.63.1" > "$WORK/repo/.swiftformat-version"

    release groue/GRDB.swift v7.11.1
    release sparkle-project/Sparkle 2.10.0
    # FFmpeg publishes no GitHub releases, only tags, with an `n` in front.
    tags FFmpeg/FFmpeg 1 v0.6.1 n9.1-dev n9.0.2 n9.0.1 n9.0 n8.1
    release acoustid/chromaprint v1.6.1
    release realm/SwiftLint 0.65.1
    release nicklockwood/SwiftFormat 0.63.1
}

# run_case name expected_exit expected_fragment
run_case() {
    local name="$1" expected_exit="$2" fragment="$3"
    local out exit_code=0
    out="$(cd "$WORK/repo" && GH_CMD="$FAKE_GH" FAKE_GH_API="$API" python3 "$SCRIPT" 2>&1)" || exit_code=$?
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        fail "$name (exit $exit_code, expected $expected_exit)"
        echo "    output: $out" >&2
        return
    fi
    if [[ -n "$fragment" && "$out" != *"$fragment"* ]]; then
        fail "$name (output missing '$fragment')"
        echo "    output: $out" >&2
        return
    fi
    pass "$name"
}

reset
run_case "every pin current" 0 "All 6 pins match"

reset
release groue/GRDB.swift v7.12.0
run_case "a Swift package behind is reported" 2 '| grdb.swift | `Package.resolved` | 7.11.1 | 7.12.0 | minor/patch |'

reset
tags FFmpeg/FFmpeg 1 v0.6.1 n9.1-dev n9.0.3 n9.0.2 n9.0
run_case "FFmpeg behind is reported" 2 '| FFmpeg | `.ffmpeg-source` | 9.0.2 | 9.0.3 | minor/patch |'

reset
tags FFmpeg/FFmpeg 1 n10.0 n9.0.2
run_case "a two-part FFmpeg tag is a major gap" 2 '| 9.0.2 | 10.0.0 | MAJOR |'

reset
tags FFmpeg/FFmpeg 1 n9.1-dev n9.0.2
run_case "a development tag is not a release" 0 "All 6 pins match"

# The newest tag is on the second page: the first holds 100 older ones.
reset
old_tags=()
for i in $(seq 1 100); do old_tags+=("n1.0.$i"); done
tags FFmpeg/FFmpeg 1 "${old_tags[@]}"
tags FFmpeg/FFmpeg 2 n9.0.4 n9.0.2
run_case "a newer tag on the second page is found" 2 '| 9.0.2 | 9.0.4 |'

reset
release acoustid/chromaprint v1.7.0
run_case "Chromaprint behind is reported" 2 '| Chromaprint | `.chromaprint-source` | 1.6.1 | 1.7.0 | minor/patch |'

reset
release realm/SwiftLint 0.66.0
run_case "SwiftLint behind is reported" 2 '| SwiftLint | `.swiftlint-version` | 0.65.1 | 0.66.0 | minor/patch |'

reset
release nicklockwood/SwiftFormat 1.0.0
run_case "SwiftFormat behind by a major is reported" 2 '| SwiftFormat | `.swiftformat-version` | 0.63.1 | 1.0.0 | MAJOR |'

reset
rm "$WORK/repo/.swiftlint-version"
run_case "a missing pin file is a failure, not 'all current'" 1 "SwiftLint (.swiftlint-version): unpinned"

reset
printf 'FFMPEG_URL=https://example.invalid/f.tar.xz\n' > "$WORK/repo/.ffmpeg-source"
run_case "a pin file without its version is a failure" 1 "FFmpeg (.ffmpeg-source): unpinned"

reset
rm "$API"/repos_realm_SwiftLint_releases_latest
run_case "an upstream that cannot be read is a failure" 1 "SwiftLint (.swiftlint-version): no release versions found"

# A failure wins over a lagging pin: exit 1, and the lagging pin is still shown.
reset
release groue/GRDB.swift v7.12.0
rm "$WORK/repo/.swiftformat-version"
run_case "a failure beside a lagging pin exits 1" 1 "| grdb.swift |"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures check-package-updates test(s) failed" >&2
    exit 1
fi
echo "all check-package-updates tests passed"
