#!/usr/bin/env bash
# Tests for Scripts/release.sh against a throwaway git repository.
# Run: Scripts/tests/release-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
assert_eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else
        fail "$1"; echo "    expected: $2" >&2; echo "    actual:   $3" >&2; fi
}

# A fresh repo with a tagged release and a CHANGELOG/Info.plist like ours.
make_repo() {
    local dir="$WORK/$1"
    mkdir -p "$dir/Resources"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name t
    # Independent of the developer's global signing setup.
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config tag.gpgsign false
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Changelog

Intro line.

## [Unreleased]

## [1.2.0](https://github.com/o/r/compare/v1.1.0...v1.2.0) (2026-08-01)

Old prose.

### For developers

**Added**
- x: old ([#9](https://github.com/o/r/pull/9))
EOF
    cat > "$dir/Resources/Info.plist" <<'EOF'
<plist>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
</plist>
EOF
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore(main): release 1.2.0"
    git -C "$dir" tag v1.2.0
    echo "$dir"
}

commit() { # dir subject [body]
    echo "$RANDOM" >> "$1/file.txt"
    git -C "$1" add -A
    if [[ -n "${3:-}" ]]; then git -C "$1" commit -q -m "$2" -m "$3"; else git -C "$1" commit -q -m "$2"; fi
}

write_prose() { # dir text
    python3 - "$1/CHANGELOG.md" "$2" <<'PY'
import sys
p, text = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace("## [Unreleased]\n", "## [Unreleased]\n\n" + text + "\n", 1)
open(p, "w").write(s)
PY
}

echo "release.sh tests"

# --- minor bump, full section -------------------------------------------------
repo="$(make_repo minor)"
commit "$repo" "fix(subsonic): retry login after a transient 503 (#432)"
commit "$repo" "feat(podcasts): resume interrupted episode downloads (#431)"
commit "$repo" "refactor(persistence): split TrackRepository queries (#433)"
commit "$repo" "chore(deps): bump things (#435)"
commit "$repo" "fix(ui): keep the mini player above full-screen video (#434)"
write_prose "$repo" $'Podcast downloads now pick up where they stopped.\n\nThe mini player stays on top.'

assert_eq "next: feat present gives minor" "1.3.0" "$(cd "$repo" && "$SCRIPT" next)"

expected_section='## [1.3.0](https://github.com/o/r/compare/v1.2.0...v1.3.0) (2026-09-04)

Podcast downloads now pick up where they stopped.

The mini player stays on top.

### For developers

**Added**
- podcasts: resume interrupted episode downloads ([#431](https://github.com/o/r/pull/431))

**Fixed**
- subsonic: retry login after a transient 503 ([#432](https://github.com/o/r/pull/432))
- ui: keep the mini player above full-screen video ([#434](https://github.com/o/r/pull/434))

**Changed**
- persistence: split TrackRepository queries ([#433](https://github.com/o/r/pull/433))'
actual_section="$(cd "$repo" && RELEASE_DATE=2026-09-04 RELEASE_REPO=o/r "$SCRIPT" preview)"
assert_eq "preview: prose first, grouped bullets, chore hidden" "$expected_section" "$actual_section"

out="$(cd "$repo" && RELEASE_DATE=2026-09-04 RELEASE_REPO=o/r "$SCRIPT" apply)"
assert_eq "apply prints the version" "1.3.0" "$out"

expected_changelog="# Changelog

Intro line.

## [Unreleased]

$expected_section

## [1.2.0](https://github.com/o/r/compare/v1.1.0...v1.2.0) (2026-08-01)

Old prose.

### For developers

**Added**
- x: old ([#9](https://github.com/o/r/pull/9))"
assert_eq "apply: CHANGELOG rewritten with a fresh empty Unreleased on top" "$expected_changelog" "$(cat "$repo/CHANGELOG.md")"
assert_eq "apply: Info.plist stamped" "    <string>1.3.0</string>" "$(sed -n 3p "$repo/Resources/Info.plist")"
assert_eq "apply: CFBundleVersion untouched" '    <string>$(CURRENT_PROJECT_VERSION)</string>' "$(sed -n 5p "$repo/Resources/Info.plist")"

# --- patch bump ---------------------------------------------------------------
repo="$(make_repo patch)"
commit "$repo" "fix(ui): one thing (#1)"
commit "$repo" "perf(library): faster (#2)"
assert_eq "next: fix and perf only give patch" "1.2.1" "$(cd "$repo" && "$SCRIPT" next)"

# --- major bump via ! and via body ---------------------------------------------
repo="$(make_repo bang)"
commit "$repo" "feat(sync)!: new pairing protocol (#3)"
assert_eq "next: type! gives major" "2.0.0" "$(cd "$repo" && "$SCRIPT" next)"
repo="$(make_repo body)"
commit "$repo" "fix(sync): change the wire format (#4)" "BREAKING CHANGE: phones must re-pair"
assert_eq "next: BREAKING CHANGE footer gives major" "2.0.0" "$(cd "$repo" && "$SCRIPT" next)"
write_prose "$repo" "Phones need to be paired again."
assert_eq "preview: breaking bullet is marked" "- BREAKING: sync: change the wire format ([#4](https://github.com/o/r/pull/4))" \
    "$(cd "$repo" && RELEASE_REPO=o/r "$SCRIPT" preview | grep '^- ')"

# --- nothing to release ---------------------------------------------------------
repo="$(make_repo none)"
commit "$repo" "chore(deps): bump (#5)"
commit "$repo" "docs: words (#6)"
commit "$repo" "ci: tweak (#7)"
set +e; (cd "$repo" && "$SCRIPT" next) >/dev/null 2>&1; code=$?; set -e
assert_eq "next: chore/docs/ci only exits 3" "3" "$code"

# --- empty Unreleased refuses -----------------------------------------------------
repo="$(make_repo noprose)"
commit "$repo" "fix(ui): thing (#8)"
set +e; (cd "$repo" && "$SCRIPT" apply) >/dev/null 2>&1; code=$?; set -e
assert_eq "apply: empty Unreleased exits 4" "4" "$code"
assert_eq "apply: nothing written on refusal" "1.2.0" "$(grep -o '<string>1\.[0-9.]*</string>' "$repo/Resources/Info.plist" | head -1 | sed 's/<[^>]*>//g')"

echo
if (( failures )); then echo "$failures failure(s)" >&2; exit 1; fi
echo "all release.sh tests passed"
