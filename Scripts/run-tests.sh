#!/usr/bin/env bash
# run-tests.sh — Run every test stage sequentially.
#
# Prints one "Stage N : <name>  ✓/✗" line per stage.
# On failure, prints only the error lines from that stage's output.
#
# Usage: bash Scripts/run-tests.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

TMPLOG=$(mktemp /tmp/bocan-tests-XXXXXX.log)
trap 'rm -f "$TMPLOG"' EXIT

PASS=0
FAIL=0
STAGE=0

# Colour codes (disabled when not a TTY)
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

run_stage() {
    local label="$1"; shift
    STAGE=$((STAGE + 1))
    printf "${BOLD}Stage %-2d${RESET} : %-24s" "$STAGE" "$label"
    if "$@" >"$TMPLOG" 2>&1; then
        printf "${GREEN}✓${RESET}\n"
        PASS=$((PASS + 1))
    else
        printf "${RED}✗  FAILED${RESET}\n"
        FAIL=$((FAIL + 1))
        grep -E "error:|❌|✗|FAILED|warning:.*[Vv]iolation|coverage.*below|ERROR:" "$TMPLOG" \
            | grep -v "^$" | head -50 | sed 's/^/    /' || true
        printf "\n"
    fi
}

run_stage "format"         make -s format
run_stage "lint"           make -s lint
run_stage "build"          make -s build
run_stage "test"           make -s test
run_stage "test-coverage"  make -s test-coverage
run_stage "audio-engine"   make -s test-audio-engine
run_stage "persistence"    make -s test-persistence
run_stage "metadata"       make -s test-metadata
run_stage "library"        make -s test-library
run_stage "acoustics"      make -s test-acoustics
run_stage "ui"             make -s test-ui
run_stage "playback"       make -s test-playback
run_stage "scrobble"       make -s test-scrobble
run_stage "subsonic"       make -s test-subsonic
run_stage "podcasts"       make -s test-podcasts
run_stage "sync-server"    make -s test-sync-server
run_stage "observability"  make -s test-observability

printf "\n${BOLD}%d passed, %d failed${RESET}\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
