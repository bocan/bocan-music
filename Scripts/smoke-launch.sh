#!/usr/bin/env bash
# Starts a built Bocan.app on this machine and fails if it does not stay up.
#
# The app says it runs on macOS 15 and later, but the libraries inside it can
# be built for a newer macOS than that (#627). A library that needs a system
# function this macOS does not have stops the app when it starts. So the test
# is to start the app on the oldest macOS it claims, and see that it stays
# alive. The `smoketest` workflow runs this on macOS 15 and macOS 26.
#
# Usage:
#   Scripts/smoke-launch.sh path/to/Bocan.app [audio-file-for-fpcalc]
#
# Exit 0 only when every check holds. Otherwise one line per failure on stderr
# and exit 1. Exit 2 for a usage error.
#
# The checks:
#   1. The app's process is still alive after SMOKE_WAIT_SECONDS.
#   2. No crash report for Bocan was written while it ran.
#   3. The bundled fpcalc starts, and (when an audio file is given) prints a
#      fingerprint for it. fpcalc is a separate program with its own copies
#      of the libraries, so check 1 does not cover it.
#
# It also prints, for information, the macOS version each bundled library was
# built for. That list never fails the run: a library built for a newer macOS
# is the question, and checks 1 to 3 are the answer.
#
# This proves the app starts. It does not prove that every code path works.
#
# Overridable through the environment, for the hermetic test in Scripts/tests/
# (which also runs on Linux):
#   SMOKE_WAIT_SECONDS  how long the app must stay alive   (default: 20)
#   SMOKE_SETTLE_SECONDS  wait for a crash report to land  (default: 5)
#   CRASH_REPORT_DIR    where crash reports are written
#                       (default: ~/Library/Logs/DiagnosticReports)

set -euo pipefail

APP="${1:-}"
FIXTURE="${2:-}"
WAIT="${SMOKE_WAIT_SECONDS:-20}"
SETTLE="${SMOKE_SETTLE_SECONDS:-5}"
CRASH_REPORT_DIR="${CRASH_REPORT_DIR:-$HOME/Library/Logs/DiagnosticReports}"

if [[ -z "$APP" ]]; then
    echo "usage: $(basename "$0") path/to/Bocan.app [audio-file-for-fpcalc]" >&2
    exit 2
fi
if [[ ! -d "$APP" ]]; then
    echo "✗ no app bundle at $APP" >&2
    exit 2
fi
BINARY="$APP/Contents/MacOS/Bocan"
FPCALC="$APP/Contents/Resources/fpcalc"
if [[ ! -x "$BINARY" ]]; then
    echo "✗ no executable at $BINARY" >&2
    exit 2
fi

failures=0
fail() {
    echo "✗ $1" >&2
    failures=$((failures + 1))
}

WORK="$(mktemp -d)"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── for information: what this machine is, and what the libraries expect ─────

if command -v sw_vers > /dev/null; then
    echo "=== this machine: macOS $(sw_vers -productVersion) ($(uname -m)) ==="
fi
if command -v otool > /dev/null; then
    echo "=== built for (minimum macOS) ==="
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        # `|| true`: a file that is not a Mach-O has no build version, and is
        # left out of the list.
        minos="$(otool -l "$file" 2>/dev/null \
            | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}' || true)"
        [[ -n "$minos" ]] || continue
        printf '    %-6s %s\n' "$minos" "${file#"$APP"/}"
    done < <(
        echo "$BINARY"
        find "$APP/Contents/Frameworks" "$APP/Contents/Resources" \
            -type f \( -name '*.dylib' -o -name fpcalc \) 2>/dev/null | sort
    )
fi

# ── checks 1 and 2: the app starts and stays up ──────────────────────────────

MARK="$WORK/started"
touch "$MARK"
LOG="$WORK/app.log"

echo "=== start $(basename "$APP"), and wait ${WAIT} s ==="
# The arguments keep a clean machine from blocking on restored windows or on
# the Local Network permission dialog (docs/GOTCHAS.md, the E2E launch entry).
"$BINARY" \
    -ApplePersistenceIgnoreState YES \
    -sync.enabled NO \
    -ui.windowMode.miniPlayerOpen NO \
    > "$LOG" 2>&1 &
APP_PID=$!

alive=1
elapsed=0
while [[ "$elapsed" -lt "$WAIT" ]]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        alive=0
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [[ "$alive" -eq 0 ]]; then
    exit_code=0
    wait "$APP_PID" || exit_code=$?
    APP_PID=""
    fail "the app stopped after ${elapsed} s (exit code ${exit_code})"
    echo "--- what the app printed (last 40 lines) ---" >&2
    tail -40 "$LOG" >&2 || true
else
    echo "✓ the app is alive after ${WAIT} s"
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
fi

# A crash report is written a moment after the process dies.
sleep "$SETTLE"
if [[ -d "$CRASH_REPORT_DIR" ]]; then
    reports="$(find "$CRASH_REPORT_DIR" -type f -name 'Bocan*' -newer "$MARK" 2>/dev/null | sort || true)"
    if [[ -n "$reports" ]]; then
        while IFS= read -r report; do
            fail "a crash report was written: $report"
            echo "--- $(basename "$report") (first 60 lines) ---" >&2
            head -60 "$report" >&2 || true
        done <<< "$reports"
    else
        echo "✓ no crash report"
    fi
fi

# ── check 3: the bundled fpcalc ───────────────────────────────────────────────

if [[ ! -x "$FPCALC" ]]; then
    fail "no fpcalc at ${FPCALC#"$APP"/}"
else
    fpcalc_out=""
    if fpcalc_out="$("$FPCALC" -version 2>&1)"; then
        echo "✓ $fpcalc_out"
    else
        fail "fpcalc does not start: $fpcalc_out"
    fi
    if [[ -n "$FIXTURE" ]]; then
        if [[ ! -f "$FIXTURE" ]]; then
            fail "no audio file at $FIXTURE"
        elif fpcalc_out="$("$FPCALC" "$FIXTURE" 2>&1)" && grep -q '^FINGERPRINT=.' <<< "$fpcalc_out"; then
            echo "✓ fpcalc made a fingerprint for $(basename "$FIXTURE")"
        else
            fail "fpcalc made no fingerprint for $(basename "$FIXTURE"): $fpcalc_out"
        fi
    fi
fi

# ── result ───────────────────────────────────────────────────────────────────

if [[ "$failures" -gt 0 ]]; then
    echo "✗ smoke test failed: ${failures} problem(s)" >&2
    exit 1
fi
echo "✓ smoke test passed"
