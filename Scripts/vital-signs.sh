#!/usr/bin/env bash
# vital-signs.sh: print the repository's vital signs as a markdown table.
# Every row shows the metric, its value, and the exact command that produced
# the value, so each number can be re-run and audited by hand.
#
# Usage: Scripts/vital-signs.sh [--slow]
#   --slow   also time a clean Release build (several minutes) and, when a
#            .periphery.yml exists, run a Periphery dead-code scan.
#
# Source-based counts are scoped to Modules/*/Sources and App/, with tests
# counted separately. Coverage and test timing are read from the artefacts
# the last `make test-coverage` and `make coverage-all` left behind; nothing
# is rebuilt. A metric that cannot be measured prints "unmeasured" and why.
# Nothing is estimated.
#
# shellcheck disable=SC2016  # commands are quoted strings shown to the reader
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SLOW=0
for arg in "$@"; do
    case "$arg" in
        --slow) SLOW=1 ;;
        -h | --help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

for tool in rg jq xcrun git; do
    command -v "$tool" >/dev/null || {
        echo "missing tool: $tool" >&2
        exit 2
    }
done

# Scope strings reused in the printed commands. SRC is expanded by the shell
# when the command runs; the reader can paste the command as printed.
SRC='Modules/*/Sources App'
SUM="awk -F: '{s+=\$NF} END{print s+0}'"
COUNT="wc -l | tr -d ' '"
XCRESULT='build/TestResults.xcresult'
ALLOWLIST='Scripts/vital-signs.allowlist'
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

# --- table helpers -----------------------------------------------------------

escape_cell() {
    printf '%s' "$1" | sed 's/|/\\|/g'
}

row() { # metric, value, command
    printf '| %s | %s | `%s` |\n' \
        "$(escape_cell "$1")" "$(escape_cell "$2")" "$(escape_cell "$3")"
}

section() {
    printf '| **%s** | | |\n' "$1"
}

# Run a command string, print its output as the value. rg exits 1 on no match,
# so pipefail is off inside the evaluation; a real error shows up on stderr and
# is reported instead of a silent zero.
measure() { # metric, command
    local metric="$1" cmd="$2" value
    value="$(set +o pipefail; eval "$cmd" 2>"$ERR_FILE")" || true
    if [[ -z "$value" && -s "$ERR_FILE" ]]; then
        value="error: $(head -n 1 "$ERR_FILE")"
    elif [[ -z "$value" ]]; then
        value="no output"
    fi
    row "$metric" "$value" "$cmd"
}

unmeasured() { # metric, reason, command that would produce it
    row "$1" "unmeasured: $2" "$3"
}

mtime() {
    stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1"
}

# --- header ------------------------------------------------------------------

echo "# Bòcan vital signs"
echo
echo "Generated $(date '+%Y-%m-%d %H:%M %Z') at commit $(git rev-parse --short HEAD) on branch $(git branch --show-current)."
echo "Source counts cover Modules/*/Sources and App/ unless a row says tests. Rows read from artefacts carry the artefact's date. Unmeasured rows say why."
echo
echo "| Metric | Value | Command |"
echo "|---|---|---|"

# --- size --------------------------------------------------------------------

section "Size"
for dir in Modules/*/; do
    module="$(basename "$dir")"
    measure "Swift lines · $module (sources)" \
        "rg --files Modules/$module/Sources -g '*.swift' | xargs cat | $COUNT"
done
measure "Swift lines · App (sources)" "rg --files App -g '*.swift' | xargs cat | $COUNT"
measure "Swift lines · all sources" "rg --files $SRC -g '*.swift' | xargs cat | $COUNT"
measure "Swift lines · all tests" "rg --files Modules/*/Tests -g '*.swift' | xargs cat | $COUNT"

# --- tests -------------------------------------------------------------------

section "Tests"
TEST_RE='^\s*(@Test\b|func test[A-Z])'
for dir in Modules/*/; do
    module="$(basename "$dir")"
    measure "Tests · $module (@Test and XCTest funcs)" \
        "rg -c '$TEST_RE' Modules/$module/Tests -g '*.swift' | $SUM"
done
measure "Tests · all modules" "rg -c '$TEST_RE' Modules/*/Tests -g '*.swift' | $SUM"

if [[ -d "$XCRESULT" ]]; then
    XCR_DATE="$(mtime "$XCRESULT")"
    measure "Tests · Xcode bundle run ($XCR_DATE)" \
        "xcrun xcresulttool get test-results summary --path $XCRESULT | jq -r '.totalTestCount'"
    measure "Test suite wall time · Xcode bundle ($XCR_DATE)" \
        "xcrun xcresulttool get test-results summary --path $XCRESULT | jq -r '(((.finishTime - .startTime) * 10 | round) / 10 | tostring) + \" s\"'"
else
    unmeasured "Tests · Xcode bundle run" "no $XCRESULT; run make test-coverage first" "make test-coverage"
    unmeasured "Test suite wall time · Xcode bundle" "no $XCRESULT; run make test-coverage first" "make test-coverage"
fi
unmeasured "Test suite wall time · SPM modules" \
    "swift test leaves no timing artefact; time the run itself" "time make coverage-all"

# --- coverage ----------------------------------------------------------------

section "Coverage"
if [[ -d "$XCRESULT" ]]; then
    measure "Coverage · Xcode bundle gate, BocanTests.xctest ($XCR_DATE)" \
        "xcrun xccov view --report --json $XCRESULT | jq -r '.targets[] | select(.name == \"BocanTests.xctest\") | (((.lineCoverage * 1000 | round) / 10) | tostring) + \"%\"'"
else
    unmeasured "Coverage · Xcode bundle gate" "no $XCRESULT; run make test-coverage first" "make test-coverage"
fi
for dir in Modules/*/; do
    module="$(basename "$dir")"
    profdata="Modules/$module/.build/debug/codecov/default.profdata"
    binary="Modules/$module/.build/debug/${module}PackageTests.xctest/Contents/MacOS/${module}PackageTests"
    if [[ -f "$profdata" && -x "$binary" ]]; then
        # The same llvm-cov invocation Scripts/coverage-all.sh uses, on the
        # artefacts it left behind, so the number matches make coverage-all.
        measure "Coverage · $module (coverage-all artefact $(mtime "$profdata"))" \
            "xcrun llvm-cov report $binary -instr-profile=$profdata -ignore-filename-regex='(\.build|/Tests/|/checkouts/|\.derivedSources)' Modules/$module/Sources/ | awk '/^TOTAL/ {print \$10}'"
    else
        have_prof="no"; [[ -f "$profdata" ]] && have_prof="yes"
        have_bin="no"; [[ -x "$binary" ]] && have_bin="yes"
        unmeasured "Coverage · $module" \
            "no coverage-all artefacts (profdata: $have_prof, test binary: $have_bin); run make coverage-all" \
            "make coverage-all"
    fi
done

# --- code quality ------------------------------------------------------------

section "Code quality"
unmeasured "Duplication percentage" \
    "no duplication scanner is installed or wired; the maintainability audit (docs/design-spec/maintainability-audit/findings-ledger.md) was a manual ledger" \
    "none"

PERIPHERY_CMD="periphery scan --quiet --format json | jq length"
if ! command -v periphery >/dev/null; then
    unmeasured "Dead code · Periphery results" "periphery is not installed" "$PERIPHERY_CMD"
elif [[ ! -f .periphery.yml ]]; then
    unmeasured "Dead code · Periphery results" \
        "periphery $(periphery version 2>/dev/null || echo '?') is installed but not configured (no .periphery.yml); run periphery scan --setup once" \
        "periphery scan --setup"
elif (( SLOW )); then
    measure "Dead code · Periphery results" "$PERIPHERY_CMD"
else
    unmeasured "Dead code · Periphery results" "pass --slow (Periphery builds the project, several minutes)" "$PERIPHERY_CMD"
fi

# try? split. The house rule (CLAUDE.md) wants an `else { log.warning }`
# companion. "With companion" is read strictly as a try? whose `else {` has an
# AppLogger call on the same line or the next one; everything else counts as
# without. Both commands are printed so the heuristic can be inspected.
TRY_TOTAL_CMD="rg -o 'try\?' $SRC -g '*.swift' | $COUNT"
TRY_WITH_CMD="rg -U -o 'try\?[^\n]*\belse\s*\{[^\n]*(\n[^\n]*)?\blog\.(warning|error|info|debug|notice|fault)\(' $SRC -g '*.swift' | rg -c 'try\?'"
try_total="$(set +o pipefail; eval "$TRY_TOTAL_CMD" 2>/dev/null || true)"
try_with="$(set +o pipefail; eval "$TRY_WITH_CMD" 2>/dev/null || true)"
try_with="${try_with:-0}"
row "try? in sources (occurrences)" "$try_total" "$TRY_TOTAL_CMD"
row "try? with an else { log } companion (log call on the else line or the next)" "$try_with" "$TRY_WITH_CMD"
row "try? without a companion" "$((try_total - try_with))" "(try? occurrences) - (try? with companion)"

measure "nonisolated(unsafe) in sources" "rg -o 'nonisolated\(unsafe\)' $SRC -g '*.swift' | $COUNT"
measure "@unchecked Sendable in sources" "rg -o '@unchecked Sendable' $SRC -g '*.swift' | $COUNT"
measure "@MainActor outside the UI layer (Modules/* except UI; App is UI layer)" \
    "rg -o '@MainActor' Modules/*/Sources -g '*.swift' -g '!Modules/UI/**' | $COUNT"

for word in TODO FIXME XCTSkip fatalError; do
    measure "$word in sources (whole word)" "rg -ow '$word' $SRC -g '*.swift' | $COUNT"
done
measure "XCTSkip in tests (whole word)" "rg -ow 'XCTSkip' Modules/*/Tests -g '*.swift' | $COUNT"

# Allowlist: one ripgrep glob per line, excluded from the "outside" counts.
ALLOW_GLOBS=""
if [[ -f "$ALLOWLIST" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        ALLOW_GLOBS+=" -g '!$line'"
    done <"$ALLOWLIST"
fi
measure "Task { in sources (all)" "rg -oF 'Task {' $SRC -g '*.swift' | $COUNT"
measure "Task { outside the allowlist ($ALLOWLIST)" "rg -oF 'Task {' $SRC -g '*.swift'$ALLOW_GLOBS | $COUNT"
measure "Timer.scheduledTimer in sources (all)" "rg -o 'Timer\.scheduledTimer' $SRC -g '*.swift' | $COUNT"
measure "Timer.scheduledTimer outside the allowlist ($ALLOWLIST)" \
    "rg -o 'Timer\.scheduledTimer' $SRC -g '*.swift'$ALLOW_GLOBS | $COUNT"

measure "sql: statements (lines)" "rg -c 'sql:' $SRC -g '*.swift' | $SUM"
measure "sql: lines containing \\( interpolation" "rg -n 'sql:' $SRC -g '*.swift' | rg -cF '\\('"

measure "ADRs" "ls docs/design-spec/ADR-*.md | $COUNT"
measure "ADRs with a status field" \
    "rg -il '^(\*\*)?status(\*\*)?\s*:' docs/design-spec/ADR-*.md | $COUNT"

# --- build and runtime -------------------------------------------------------

section "Build and runtime"
RELEASE_CMD="xcodebuild -project Bocan.xcodeproj -scheme Bocan -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/vital-signs-derived ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= clean build"
if (( SLOW )); then
    mkdir -p build
    start="$(date +%s)"
    if eval "$RELEASE_CMD" >build/vital-signs-release-build.log 2>&1; then
        row "Clean build time · Release (unsigned, arm64)" "$(( $(date +%s) - start )) s" "time $RELEASE_CMD"
    else
        row "Clean build time · Release (unsigned, arm64)" "build failed; see build/vital-signs-release-build.log" "time $RELEASE_CMD"
    fi
else
    unmeasured "Clean build time · Release (unsigned, arm64)" "pass --slow (several minutes)" "time $RELEASE_CMD"
fi

TRACE_CMD="xctrace record --template 'Time Profiler' --all-processes --time-limit 30s --output build/launch.trace & sleep 2 && open -a Bocan; then read the signpost interval from the trace (xctrace export --xpath)"
unmeasured "Cold start to first window (app.bootstrap signpost)" \
    "the signpost exists (App/BocanApp.swift) but info-level log lines are not persisted to the unified log and no launch trace is automated" \
    "$TRACE_CMD"
unmeasured "Library load time for the large fixture (tracks.load, library.scan signposts)" \
    "no large fixture exists yet; the signposts exist" \
    "$TRACE_CMD"
unmeasured "Hitch ratio for the standard playback scenario" \
    "no standard playback scenario or performance gate exists yet" \
    "xctrace record --template 'Animation Hitches' --attach <pid> --time-limit 45s --output build/hitches.trace"
unmeasured "Idle memory after 10 minutes of playback" \
    "the 10-minute playback protocol is not automated; sample a running instance by hand" \
    "ps -o rss= -p \$(pgrep -x Bocan) | awk '{printf \"%.0f MB\\n\", \$1 / 1024}'"
