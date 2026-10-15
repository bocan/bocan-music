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
#   Scripts/smoke-launch.sh path/to/Bocan.app [audio-file-for-fpcalc [fixture-dir]]
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
#   6. With a fixture directory, on a runner: the app adds the files to its
#      library and plays each through the queue player with its window up,
#      and the play bar gets the track's facts. A crash while a track starts
#      is caught here. Checks 4 and 5 never reach the UI.
#   5. Every bundled .dylib loads on its own with all symbols bound, so a
#      missing system symbol is named in the failure (runs before check 4).
#   4. With a fixture directory: the app decodes one file of each format to
#      its end (MP3, FLAC, Ogg Vorbis, Opus, Opus in MP4, AAC, ALAC, WAV,
#      WavPack) and one file over local HTTP, and every one yields audible
#      samples. A library that loads but fails on its first real call stops
#      here, where checks 1 to 3 cannot see it (#627). The app does the
#      decoding itself (App/SmokeCheck.swift), so it is the bundled libraries
#      that run. No output device is needed.
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
FIXTURE_DIR="${3:-}"
DECODE_TIMEOUT="${SMOKE_DECODE_TIMEOUT_SECONDS:-120}"
# One file per format. Names are the fixtures in AudioEngineTests/Fixtures.
DECODE_FILES=(
    sample.mp3
    sine-1s-44100-24-stereo.flac
    sine-1s-48000-stereo.ogg
    sine-1s-48000-stereo.opus
    opus-in-mp4.m4a
    sample-aac.m4a
    sample-alac.m4a
    sine-1s-44100-16-stereo.wav
    sine-1s-44100-stereo.wv
)
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

# ── check 5: every bundled library loads, with all symbols bound ────────────

# `ctypes.CDLL` calls dlopen with RTLD_NOW, so a library that needs a system
# symbol this macOS lacks fails here and the dyld error names the symbol. A
# lazily bound symbol would otherwise stay unresolved until its first call,
# which is a crash in the middle of playback and not at launch (#627).
# Python's own signature matters: a hardened Python refuses an ad hoc signed
# library with a team ID message, which is not a missing symbol. An Apple
# Python under SIP also drops DYLD_* variables, so the siblings would not be
# found; the runners use Homebrew's Python.
echo "=== load each bundled library ==="
if ! command -v python3 > /dev/null; then
    fail "python3 is not available for the library load check"
else
    while IFS= read -r dylib; do
        [[ -n "$dylib" ]] || continue
        # The libraries name their siblings as @rpath/<name>, which the app
        # resolves through its own rpath. Python has none, so the bundle's
        # directories go in as the fallback path: dyld then finds each
        # sibling by its leaf name, and what is left to fail is a symbol.
        if load_out="$(DYLD_FALLBACK_LIBRARY_PATH="$APP/Contents/Frameworks:$APP/Contents/Resources" \
            python3 -I -c 'import ctypes, sys; ctypes.CDLL(sys.argv[1])' "$dylib" 2>&1)"; then
            echo "✓ loads: ${dylib#"$APP"/}"
        else
            fail "does not load: ${dylib#"$APP"/}: ${load_out##*$'\n'}"
        fi
    done < <(find "$APP/Contents/Frameworks" "$APP/Contents/Resources" -type f -name '*.dylib' 2>/dev/null | sort)
fi

# ── check 4: decode one file of each format ──────────────────────────────────

if [[ -n "$FIXTURE_DIR" ]] && ! grep -aq BOCAN_SMOKE_DECODE_LIST "$BINARY"; then
    # A release from before the check existed has no hook to call.
    echo "- decode check skipped: this build predates it"
elif [[ -n "$FIXTURE_DIR" ]]; then
    echo "=== decode each format with the bundled libraries (no playback) ==="
    LIST="$WORK/decode-list.txt"
    REPORT="$WORK/decode-report.tsv"
    : > "$LIST"
    for name in "${DECODE_FILES[@]}"; do
        if [[ -f "$FIXTURE_DIR/$name" ]]; then
            echo "$FIXTURE_DIR/$name" >> "$LIST"
        else
            fail "no fixture at $FIXTURE_DIR/$name"
        fi
    done

    # One file over HTTP, so the FFmpeg stream route and its protocol layer
    # run too. TLS is not covered: no certificate the bundle trusts is
    # available to a runner.
    HTTP_PID=""
    if command -v python3 > /dev/null; then
        HTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
        python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$FIXTURE_DIR" > /dev/null 2>&1 &
        HTTP_PID=$!
        sleep 1
        echo "http://127.0.0.1:${HTTP_PORT}/sample.mp3" >> "$LIST"
    else
        fail "python3 is not available for the HTTP stream check"
    fi

    BOCAN_SMOKE_DECODE_LIST="$LIST" BOCAN_SMOKE_REPORT="$REPORT" \
        "$BINARY" -ApplePersistenceIgnoreState YES -sync.enabled NO \
        -ui.windowMode.miniPlayerOpen NO > "$WORK/decode.log" 2>&1 &
    APP_PID=$!
    waited=0
    while kill -0 "$APP_PID" 2>/dev/null && [[ "$waited" -lt "$DECODE_TIMEOUT" ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        fail "the decode check did not finish in ${DECODE_TIMEOUT} s"
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    decode_exit=0
    wait "$APP_PID" 2>/dev/null || decode_exit=$?
    APP_PID=""
    if [[ -n "$HTTP_PID" ]]; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi

    if [[ ! -f "$REPORT" ]]; then
        fail "the decode check wrote no report (app exit code ${decode_exit})"
        echo "--- what the app printed (last 40 lines) ---" >&2
        tail -40 "$WORK/decode.log" >&2 || true
    else
        while IFS=$'\t' read -r verdict decoder codec frames peak source reason; do
            case "$verdict" in
                PASS) printf '✓ %-14s %-8s %7s frames  peak %s  %s\n' \
                    "$decoder" "$codec" "$frames" "$peak" "$(basename "$source")" ;;
                FAIL) fail "decode failed: $(basename "$source") ($decoder, $codec): $reason" ;;
            esac
        done < "$REPORT"
        if ! grep -q '^RESULT'$'\t''ok$' "$REPORT"; then
            fail "the decode check did not report ok (app exit code ${decode_exit})"
        fi
    fi

    # A crash during decoding leaves a report too.
    sleep "$SETTLE"
    if [[ -d "$CRASH_REPORT_DIR" ]]; then
        reports="$(find "$CRASH_REPORT_DIR" -type f -name 'Bocan*' -newer "$MARK" 2>/dev/null | sort || true)"
        while IFS= read -r report; do
            [[ -n "$report" ]] || continue
            fail "a crash report was written while decoding: $report"
            echo "--- $(basename "$report") (first 60 lines) ---" >&2
            head -60 "$report" >&2 || true
        done <<< "$reports"
    fi
fi

# ── check 6: play each format through the app, with the window up ────────────

# The decode check above proves the libraries and nothing past them. This one
# is what a listener does: the app adds the folder to its library, plays each
# file through the queue player and the engine, and waits for the play bar to
# have the track's facts. A view that traps when a track starts (#627) ends
# the app here and writes no report. The app does it in-process
# (App/SmokePlayback.swift); the script adds the folder, the wait and the
# verdict.
#
# It adds a library folder to the app's own library, so it runs only on a
# runner (CI is set) or when SMOKE_ALLOW_LOCAL=1 says the library is
# disposable. PLAY_TIMEOUT covers the scan, the nine tracks and their pauses.
PLAY_TIMEOUT="${SMOKE_PLAY_TIMEOUT_SECONDS:-300}"
if [[ -z "$FIXTURE_DIR" ]]; then
    :
elif ! grep -aq BOCAN_SMOKE_PLAY_DIR "$BINARY"; then
    echo "- playback check skipped: this build predates it"
elif [[ -z "${CI:-}" && "${SMOKE_ALLOW_LOCAL:-}" != "1" ]]; then
    echo "- playback check skipped: it changes the app's library (set SMOKE_ALLOW_LOCAL=1 to run it here)"
else
    echo "=== play each format through the app ==="
    PLAY_DIR="$WORK/play"
    PLAY_REPORT="$WORK/play-report.tsv"
    mkdir -p "$PLAY_DIR"
    for name in "${DECODE_FILES[@]}"; do
        [[ -f "$FIXTURE_DIR/$name" ]] && cp "$FIXTURE_DIR/$name" "$PLAY_DIR/"
    done
    play_mark="$WORK/play-started"
    touch "$play_mark"

    BOCAN_SMOKE_PLAY_DIR="$PLAY_DIR" BOCAN_SMOKE_PLAY_REPORT="$PLAY_REPORT" \
        "$BINARY" -ApplePersistenceIgnoreState YES -sync.enabled NO \
        -ui.windowMode.miniPlayerOpen NO > "$WORK/play.log" 2>&1 &
    APP_PID=$!
    waited=0
    while kill -0 "$APP_PID" 2>/dev/null && [[ "$waited" -lt "$PLAY_TIMEOUT" ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        fail "the playback check did not finish in ${PLAY_TIMEOUT} s"
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    play_exit=0
    wait "$APP_PID" 2>/dev/null || play_exit=$?
    APP_PID=""

    if [[ ! -f "$PLAY_REPORT" ]]; then
        fail "the playback check wrote no report: the app stopped (exit code ${play_exit})"
        echo "--- what the app printed (last 40 lines) ---" >&2
        tail -40 "$WORK/play.log" >&2 || true
    else
        while IFS=$'\t' read -r verdict codec position name reason; do
            case "$verdict" in
                PASS) printf '✓ played %-8s to %5s s  %s\n' "$codec" "$position" "$name" ;;
                FAIL) fail "did not play: $name: $reason" ;;
            esac
        done < "$PLAY_REPORT"
        if ! grep -q '^RESULT'$'\t''ok$' "$PLAY_REPORT"; then
            fail "the playback check did not report ok (app exit code ${play_exit})"
        fi
    fi

    sleep "$SETTLE"
    if [[ -d "$CRASH_REPORT_DIR" ]]; then
        reports="$(find "$CRASH_REPORT_DIR" -type f -name 'Bocan*' -newer "$play_mark" 2>/dev/null | sort || true)"
        while IFS= read -r report; do
            [[ -n "$report" ]] || continue
            fail "a crash report was written during playback: $report"
            echo "--- $(basename "$report") (first 60 lines) ---" >&2
            head -60 "$report" >&2 || true
        done <<< "$reports"
    fi
fi

# ── result ───────────────────────────────────────────────────────────────────

if [[ "$failures" -gt 0 ]]; then
    echo "✗ smoke test failed: ${failures} problem(s)" >&2
    exit 1
fi
echo "✓ smoke test passed"
