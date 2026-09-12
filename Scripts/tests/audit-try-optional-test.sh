#!/usr/bin/env bash
# Tests for Scripts/audit-try-optional.py, hermetic via --root and --allowlist.
# Run: Scripts/tests/audit-try-optional-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/audit-try-optional.py"
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

# Fixture tree: one module source dir, one App dir, one test dir that must be
# skipped, mirroring the real layout the script scans.
TREE="$WORK/tree"
mkdir -p "$TREE/Modules/Fake/Sources/Fake" "$TREE/App" "$TREE/Modules/Fake/Tests/FakeTests"
EMPTY="$WORK/empty-allowlist.txt"
: > "$EMPTY"

cat > "$TREE/Modules/Fake/Sources/Fake/Idioms.swift" <<'SWIFT'
func idioms() async {
    try? await Task.sleep(for: .seconds(1))
    defer { try? handle.close() }
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    let decoded = try? JSONDecoder().decode(Thing.self, from: data)
    let encoded = try? JSONEncoder().encode(thing)
    let blob = try? Data(contentsOf: url)
    // try? this comment must be ignored
}
SWIFT

echo "audit-try-optional.py:"

run_case "a tree of pure idioms passes" 0 "try? audit clean" --allowlist "$EMPTY"

# A swallowed repository read is the thing the audit exists to catch.
cat > "$TREE/App/Offender.swift" <<'SWIFT'
func offend() async {
    let row = try? await repo.fetch(id: 1)
}
SWIFT

run_case "a swallowed read fails strict" 1 "1 swallowed error(s)" --allowlist "$EMPTY"
run_case "--warn reports without failing" 0 "1 swallowed error(s)" --warn --allowlist "$EMPTY"
run_case "--summary names the follow-up command" 1 "--warn lists them" --summary --allowlist "$EMPTY"
run_case "--keys emits a paste-ready line" 0 "App/Offender.swift|let row = try? await repo.fetch(id: 1)" \
    --keys --warn --allowlist "$EMPTY"

# The allowlist clears it, keyed on path plus normalized line, no line number.
ALLOW="$WORK/allowlist.txt"
cat > "$ALLOW" <<'TXT'
# a comment line is ignored
App/Offender.swift|let row = try? await repo.fetch(id: 1)  # deliberate, for the test
TXT
run_case "an allowlisted site passes" 0 "1 allowlisted" --allowlist "$ALLOW"

# Re-indenting the line must not churn the allowlist (whitespace normalized).
cat > "$TREE/App/Offender.swift" <<'SWIFT'
func offend() async {
    if true {
            let row  =  try? await repo.fetch(id: 1)
    }
}
SWIFT
run_case "re-indenting does not break the key" 0 "1 allowlisted" --allowlist "$ALLOW"

# Fixing the site makes the entry stale, which is reported but is not a failure.
cat > "$TREE/App/Offender.swift" <<'SWIFT'
func offend() async {
    do { _ = try await repo.fetch(id: 1) } catch { log.warning("x", [:]) }
}
SWIFT
run_case "a stale entry is reported, not failed" 0 "stale allowlist entry" --allowlist "$ALLOW"

# Test sources are out of scope, as the issue says.
cat > "$TREE/Modules/Fake/Tests/FakeTests/FakeTests.swift" <<'SWIFT'
func t() async { let row = try? await repo.fetch(id: 1) }
SWIFT
run_case "test sources are skipped" 0 "try? audit clean" --allowlist "$EMPTY"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all audit-try-optional tests passed"
