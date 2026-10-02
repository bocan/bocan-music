#!/usr/bin/env bash
# Tests for Scripts/smoke-launch.sh, hermetic: the "app" is a shell script.
# Run: Scripts/tests/smoke-launch-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/smoke-launch.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# make_app name app-body fpcalc-body
#   Builds a fake bundle whose executable and fpcalc are the given scripts.
make_app() {
    local app="$WORK/$1/Bocan.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$app/Contents/MacOS/Bocan"
    chmod +x "$app/Contents/MacOS/Bocan"
    if [[ -n "$3" ]]; then
        printf '#!/usr/bin/env bash\n%s\n' "$3" > "$app/Contents/Resources/fpcalc"
        chmod +x "$app/Contents/Resources/fpcalc"
    fi
    echo "$app"
}

# run_case name expected_exit expected_fragment args...
run_case() {
    local name="$1" expected_exit="$2" fragment="$3"
    shift 3
    local out exit_code=0
    out="$(SMOKE_WAIT_SECONDS=2 SMOKE_SETTLE_SECONDS=0 CRASH_REPORT_DIR="$CRASHES" bash "$SCRIPT" "$@" 2>&1)" || exit_code=$?
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

CRASHES="$WORK/crashes"
mkdir -p "$CRASHES"
AUDIO="$WORK/track.mp3"
echo "not really audio" > "$AUDIO"

GOOD_FPCALC='if [[ "${1:-}" == "-version" ]]; then echo "fpcalc version 1.6.1"; else echo "DURATION=3"; echo "FINGERPRINT=AQAAA0mU"; fi'

run_case "no argument is a usage error" 2 "usage:"
run_case "a missing bundle is a usage error" 2 "no app bundle" "$WORK/nothing/Bocan.app"

app="$(make_app healthy 'sleep 30' "$GOOD_FPCALC")"
run_case "an app that stays up passes" 0 "smoke test passed" "$app" "$AUDIO"

app="$(make_app dies 'echo "dyld: Symbol not found: _newer_function" >&2; exit 6' "$GOOD_FPCALC")"
run_case "an app that stops fails" 1 "the app stopped" "$app" "$AUDIO"
run_case "an app that stops shows what it printed" 1 "Symbol not found" "$app" "$AUDIO"

app="$(make_app no-fpcalc 'sleep 30' '')"
run_case "a bundle with no fpcalc fails" 1 "no fpcalc" "$app"

app="$(make_app bad-fpcalc 'sleep 30' 'echo "dyld: Library not loaded" >&2; exit 6')"
run_case "an fpcalc that does not start fails" 1 "fpcalc does not start" "$app"

app="$(make_app no-fingerprint 'sleep 30' 'if [[ "${1:-}" == "-version" ]]; then echo "fpcalc version 1.6.1"; else echo "ERROR: could not open"; exit 2; fi')"
run_case "an fpcalc that makes no fingerprint fails" 1 "made no fingerprint" "$app" "$AUDIO"

app="$(make_app healthy-2 'sleep 30' "$GOOD_FPCALC")"
run_case "a missing audio file fails" 1 "no audio file" "$app" "$WORK/missing.mp3"

# A crash report written while the app runs fails the run, although the
# process itself stayed alive.
app="$(make_app crash-report "touch '$CRASHES/Bocan-2026-10-02-120000.ips'; sleep 30" "$GOOD_FPCALC")"
run_case "a crash report fails the run" 1 "a crash report was written" "$app" "$AUDIO"
rm -f "$CRASHES"/Bocan*

# An old report, from before the app started, is not this run's problem.
touch "$CRASHES/Bocan-2026-09-01-120000.ips"
sleep 1
app="$(make_app old-report 'sleep 30' "$GOOD_FPCALC")"
run_case "an older crash report is ignored" 0 "no crash report" "$app" "$AUDIO"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures smoke-launch test(s) failed" >&2
    exit 1
fi
echo "all smoke-launch tests passed"
