#!/usr/bin/env bash
# Tests for Scripts/audit-appkit-imports.py, hermetic via --root and --allowlist.
# Run: Scripts/tests/audit-appkit-imports-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/audit-appkit-imports.py"
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

# Fixture tree: a lower module, the UI module and the App target, mirroring
# the real layout. Only the lower module is in scope.
TREE="$WORK/tree"
mkdir -p "$TREE/Modules/Fake/Sources/Fake" "$TREE/Modules/UI/Sources/UI" "$TREE/App" \
    "$TREE/Modules/Fake/Tests/FakeTests"
EMPTY="$WORK/empty-allowlist.txt"
: > "$EMPTY"

cat > "$TREE/Modules/Fake/Sources/Fake/Clean.swift" <<'SWIFT'
import Foundation
// import AppKit in a comment must be ignored
let note = "import AppKit in a string must be ignored"
SWIFT
cat > "$TREE/Modules/UI/Sources/UI/View.swift" <<'SWIFT'
import AppKit
SWIFT
cat > "$TREE/App/Delegate.swift" <<'SWIFT'
import AppKit
SWIFT

echo "audit-appkit-imports.py:"

run_case "UI and App may import AppKit" 0 "AppKit import audit clean" --allowlist "$EMPTY"

cat > "$TREE/Modules/Fake/Sources/Fake/Offender.swift" <<'SWIFT'
import AppKit
import Foundation
SWIFT

run_case "a lower-module import fails strict" 1 "1 AppKit import(s)" --allowlist "$EMPTY"
run_case "the failure names the file and line" 1 "Modules/Fake/Sources/Fake/Offender.swift:1: import AppKit" \
    --allowlist "$EMPTY"
run_case "--warn reports without failing" 0 "1 AppKit import(s)" --warn --allowlist "$EMPTY"
run_case "--summary names the follow-up command" 1 "--warn lists them" --summary --allowlist "$EMPTY"

# Cocoa pulls AppKit in, and attributes or a scoped import must not hide it.
cat > "$TREE/Modules/Fake/Sources/Fake/Offender.swift" <<'SWIFT'
import Cocoa
SWIFT
run_case "import Cocoa is caught" 1 "import Cocoa" --allowlist "$EMPTY"

cat > "$TREE/Modules/Fake/Sources/Fake/Offender.swift" <<'SWIFT'
@preconcurrency import AppKit
SWIFT
run_case "an attribute-prefixed import is caught" 1 "1 AppKit import(s)" --allowlist "$EMPTY"

cat > "$TREE/Modules/Fake/Sources/Fake/Offender.swift" <<'SWIFT'
import class AppKit.NSImage
SWIFT
run_case "a scoped import is caught" 1 "1 AppKit import(s)" --allowlist "$EMPTY"

# The allowlist clears a file, keyed on its repo-relative path.
ALLOW="$WORK/allowlist.txt"
cat > "$ALLOW" <<'TXT'
# a comment line is ignored
Modules/Fake/Sources/Fake/Offender.swift  # deliberate, for the test
TXT
run_case "an allowlisted file passes" 0 "1 allowlisted" --allowlist "$ALLOW"

# Removing the import makes the entry stale, which is reported but is not a failure.
cat > "$TREE/Modules/Fake/Sources/Fake/Offender.swift" <<'SWIFT'
import Foundation
SWIFT
run_case "a stale entry is reported, not failed" 0 "stale allowlist entry" --allowlist "$ALLOW"

# Test sources are out of scope.
cat > "$TREE/Modules/Fake/Tests/FakeTests/FakeTests.swift" <<'SWIFT'
import AppKit
SWIFT
run_case "test sources are skipped" 0 "AppKit import audit clean" --allowlist "$EMPTY"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all audit-appkit-imports tests passed"
