#!/usr/bin/env bash
# Tests for Scripts/audit-help-text.py, hermetic via --root and --allowlist.
# Run: Scripts/tests/audit-help-text-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/audit-help-text.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# run_case name expected_exit expected_fragment [extra args...]
run_case() {
    local name="$1" expected_exit="$2" fragment="$3"
    shift 3
    local out exit_code=0
    out="$(python3 "$SCRIPT" --root "$TREE" "$@" 2>&1)" || exit_code=$?
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

# Fixture tree mirroring the two directories the script scans, plus a test
# source that must be skipped.
TREE="$WORK/tree"
UI="$TREE/Modules/UI/Sources/UI"
mkdir -p "$UI" "$TREE/App" "$TREE/Modules/UI/Tests/UITests"
EMPTY="$WORK/empty-allowlist.txt"
: > "$EMPTY"

cat > "$UI/Covered.swift" <<'SWIFT'
struct Covered: View {
    var body: some View {
        Button(L10n.string("Play")) { self.play() }
            .buttonStyle(.plain)
            .help(L10n.string("Starts playing this album."))
        Toggle(L10n.string("Shuffle"), isOn: self.$shuffle)
            .help(L10n.string("Plays the queue in a random order."))
    }
}
SWIFT

echo "audit-help-text.py:"

run_case "a tree where every control has help passes" 0 "help-text audit clean" --allowlist "$EMPTY"

# The thing the audit exists to catch: a control with no hover text.
cat > "$TREE/App/Offender.swift" <<'SWIFT'
struct Offender: View {
    var body: some View {
        Button(L10n.string("Erase")) { self.erase() }
    }
}
SWIFT

run_case "a control without help fails strict" 1 "1 interactive control(s) without help text" --allowlist "$EMPTY"
run_case "--warn reports without failing" 0 "1 interactive control(s) without help text" --warn --allowlist "$EMPTY"
run_case "--summary names the follow-up command" 1 "--warn lists them" --summary --allowlist "$EMPTY"

# The allowlist clears it, keyed on path plus normalized line, no line number.
ALLOW="$WORK/allowlist.txt"
cat > "$ALLOW" <<'TXT'
# a comment line is ignored
App/Offender.swift|Button(L10n.string("Erase")) { self.erase() }  # deliberate, for the test
TXT
run_case "an allowlisted site passes" 0 "help-text audit clean" --allowlist "$ALLOW"

# Re-indenting the line must not churn the allowlist (whitespace normalized).
cat > "$TREE/App/Offender.swift" <<'SWIFT'
struct Offender: View {
    var body: some View {
        if true {
                Button(L10n.string("Erase"))  {  self.erase() }
        }
    }
}
SWIFT
run_case "re-indenting does not break the key" 0 "help-text audit clean" --allowlist "$ALLOW"

# Fixing the site makes the entry stale, which is reported but is not a failure.
cat > "$TREE/App/Offender.swift" <<'SWIFT'
struct Offender: View {
    var body: some View {
        Button(L10n.string("Erase")) { self.erase() }
            .help(L10n.string("Erases the thing."))
    }
}
SWIFT
run_case "a stale entry is reported, not failed" 0 "stale allowlist entry" --allowlist "$ALLOW"
rm "$TREE/App/Offender.swift"

# Exempt by rule, not by allowlist: macOS renders no tooltip inside a menu.
cat > "$UI/InsideMenu.swift" <<'SWIFT'
struct InsideMenu: View {
    var body: some View {
        Text(verbatim: "row")
            .contextMenu {
                Button(L10n.string("Get Info")) { self.info() }
            }
    }
}
SWIFT
run_case "a button inside a context menu is exempt" 0 "help-text audit clean" --allowlist "$EMPTY"

# #504: a whole type can be menu content. A struct whose name ENDS in Menu is
# exempt for its whole body; one that merely starts with it is not, which is
# what keeps MenuBarExtraScene's popover controls in the count.
cat > "$UI/ArtistContextMenu.swift" <<'SWIFT'
struct ArtistContextMenu: View {
    var body: some View {
        Button(L10n.string("Get Info")) { self.info() }
    }
}
SWIFT
run_case "a struct named ...Menu is menu content" 0 "help-text audit clean" --allowlist "$EMPTY"

cat > "$UI/MenuBarExtraScene.swift" <<'SWIFT'
struct MenuBarExtraScene: View {
    var body: some View {
        Button(L10n.string("Show Bòcan")) { self.show() }
    }
}
SWIFT
run_case "a struct merely starting with Menu is still audited" 1 "MenuBarExtraScene.swift" --allowlist "$EMPTY"
rm "$UI/MenuBarExtraScene.swift"

# Preview bodies and test sources are out of scope.
cat > "$UI/Previewed.swift" <<'SWIFT'
#Preview {
    Button(L10n.string("Preview only")) {}
}
SWIFT
cat > "$TREE/Modules/UI/Tests/UITests/FakeTests.swift" <<'SWIFT'
struct FakeTests {
    var body: some View {
        Button(L10n.string("In a test")) {}
    }
}
SWIFT
run_case "preview bodies and test sources are skipped" 0 "help-text audit clean" --allowlist "$EMPTY"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all audit-help-text tests passed"
