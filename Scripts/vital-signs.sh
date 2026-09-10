#!/usr/bin/env bash
# vital-signs.sh: print the repository's vital signs as a markdown table.
# Every row shows the metric, its value, a note, and the exact command that
# produced the value, so each number can be re-run and audited by hand.
#
# Usage: Scripts/vital-signs.sh [--slow] [--record] [--label NAME]
#   --slow        also time a clean Release build (several minutes) and, when
#                 a .periphery.yml exists, run a Periphery dead-code scan.
#   --record      append this run to docs/vital-signs.csv, one row per metric
#                 (date, commit, label, metric, value, unit, note), so runs
#                 can be compared. Scripts/vital-signs-trend.py reads it.
#   --label NAME  name this run in the history (for example pre-2.15.0).
#
# Source-based counts are scoped to Modules/*/Sources and App/, with tests
# counted separately. Coverage and test timing are read from the artefacts
# the last `make test-coverage` and `make coverage-all` left behind; nothing
# is rebuilt. A metric that cannot be measured prints "unmeasured" and why.
# Nothing is estimated.
#
# Metric names are the keys of the history, so they stay stable; anything
# that varies per run (artefact dates, reasons) goes in the note column.
# If a command changes in a way that changes the meaning of its number,
# rename the metric so the old series ends there.
#
# shellcheck disable=SC2016  # commands are quoted strings shown to the reader
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SLOW=0
RECORD=0
LABEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --slow) SLOW=1 ;;
        --record) RECORD=1 ;;
        --label)
            LABEL="${2:?--label needs a name}"
            shift
            ;;
        -h | --help)
            sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
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
CSV='docs/vital-signs.csv'
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

RUN_DATE="$(date '+%Y-%m-%dT%H:%M')"
RUN_COMMIT="$(git rev-parse --short HEAD)"
RECORDED=0

# --- table helpers -----------------------------------------------------------

escape_cell() {
    printf '%s' "$1" | sed 's/|/\\|/g'
}

csv_field() { # quote when the field holds a comma, a quote or a newline
    local f="$1"
    if [[ "$f" == *[,\"$'\n']* ]]; then
        f="${f//\"/\"\"}"
        printf '"%s"' "$f"
    else
        printf '%s' "$f"
    fi
}

record() { # metric, value, note. Splits "74.5 s" into value 74.5 unit s.
    local metric="$1" value="$2" note="$3" num="" unit=""
    local num_re='^([0-9]+(\.[0-9]+)?)[[:space:]]*(%|s|MB)?$'
    if [[ "$value" =~ $num_re ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        # unmeasured, error, no output: an empty value keeps the series honest
        note="${note:-$value}"
    fi
    if [[ ! -f "$CSV" ]]; then
        mkdir -p "$(dirname "$CSV")"
        echo "date,commit,label,metric,value,unit,note" >"$CSV"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_DATE" "$RUN_COMMIT" "$(csv_field "$LABEL")" "$(csv_field "$metric")" \
        "$num" "$unit" "$(csv_field "$note")" >>"$CSV"
    RECORDED=$((RECORDED + 1))
}

row() { # metric, value, command, [note]
    local metric="$1" value="$2" cmd="$3" note="${4:-}"
    printf '| %s | %s | %s | `%s` |\n' \
        "$(escape_cell "$metric")" "$(escape_cell "$value")" \
        "$(escape_cell "$note")" "$(escape_cell "$cmd")"
    if (( RECORD )); then
        record "$metric" "$value" "$note"
    fi
}

section() {
    printf '| **%s** | | | |\n' "$1"
}

# Run a command string, print its output as the value. rg exits 1 on no match,
# so pipefail is off inside the evaluation; a real error shows up on stderr and
# is reported instead of a silent zero.
measure() { # metric, command, [note]
    local metric="$1" cmd="$2" note="${3:-}" value
    value="$(set +o pipefail; eval "$cmd" 2>"$ERR_FILE")" || true
    if [[ -z "$value" && -s "$ERR_FILE" ]]; then
        value="error"
        note="$(head -n 1 "$ERR_FILE")"
    elif [[ -z "$value" ]]; then
        value="no output"
    fi
    row "$metric" "$value" "$cmd" "$note"
}

unmeasured() { # metric, reason, command that would produce it
    row "$1" "unmeasured" "$3" "$2"
}

mtime() {
    stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1"
}

# --- header ------------------------------------------------------------------

echo "# Bòcan vital signs"
echo
echo "Generated $RUN_DATE at commit $RUN_COMMIT on branch $(git branch --show-current)${LABEL:+, labelled $LABEL}."
echo "Source counts cover Modules/*/Sources and App/ unless a row says tests. Rows read from artefacts carry the artefact's date in the note. Unmeasured rows say why."
echo
echo "| Metric | Value | Note | Command |"
echo "|---|---|---|---|"

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
    measure "Tests · $module" \
        "rg -c '$TEST_RE' Modules/$module/Tests -g '*.swift' | $SUM" \
        "@Test attributes and XCTest funcs"
done
measure "Tests · all modules" "rg -c '$TEST_RE' Modules/*/Tests -g '*.swift' | $SUM"

if [[ -d "$XCRESULT" ]]; then
    XCR_NOTE="artefact $(mtime "$XCRESULT")"
    measure "Tests · Xcode bundle run" \
        "xcrun xcresulttool get test-results summary --path $XCRESULT | jq -r '.totalTestCount'" \
        "$XCR_NOTE"
    measure "Test suite wall time · Xcode bundle" \
        "xcrun xcresulttool get test-results summary --path $XCRESULT | jq -r '(((.finishTime - .startTime) * 10 | round) / 10 | tostring) + \" s\"'" \
        "$XCR_NOTE"
else
    unmeasured "Tests · Xcode bundle run" "no $XCRESULT; run make test-coverage first" "make test-coverage"
    unmeasured "Test suite wall time · Xcode bundle" "no $XCRESULT; run make test-coverage first" "make test-coverage"
fi
unmeasured "Test suite wall time · SPM modules" \
    "swift test leaves no timing artefact; time the run itself" "time make coverage-all"

# --- coverage ----------------------------------------------------------------

section "Coverage"
if [[ -d "$XCRESULT" ]]; then
    measure "Coverage · Xcode bundle gate (BocanTests.xctest)" \
        "xcrun xccov view --report --json $XCRESULT | jq -r '.targets[] | select(.name == \"BocanTests.xctest\") | (((.lineCoverage * 1000 | round) / 10) | tostring) + \"%\"'" \
        "$XCR_NOTE"
else
    unmeasured "Coverage · Xcode bundle gate (BocanTests.xctest)" "no $XCRESULT; run make test-coverage first" "make test-coverage"
fi
for dir in Modules/*/; do
    module="$(basename "$dir")"
    profdata="Modules/$module/.build/debug/codecov/default.profdata"
    binary="Modules/$module/.build/debug/${module}PackageTests.xctest/Contents/MacOS/${module}PackageTests"
    if [[ -f "$profdata" && -x "$binary" ]]; then
        # The same llvm-cov invocation Scripts/coverage-all.sh uses, on the
        # artefacts it left behind, so the number matches make coverage-all.
        measure "Coverage · $module" \
            "xcrun llvm-cov report $binary -instr-profile=$profdata -ignore-filename-regex='(\.build|/Tests/|/checkouts/|\.derivedSources)' Modules/$module/Sources/ | awk '/^TOTAL/ {print \$10}'" \
            "coverage-all artefact $(mtime "$profdata")"
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

# Periphery reports three kinds of finding. Only "unused" is dead code;
# assign-only properties and redundant public modifiers are reported on
# their own rows. One scan writes build/periphery-results.json and the rows
# read that file, so each number is a jq filter over the same scan. Findings
# in test targets are excluded from the source rows by location.
PERIPHERY_RESULTS='build/periphery-results.json'
PERIPHERY_SCAN_CMD="periphery scan --quiet --format json > $PERIPHERY_RESULTS && jq length $PERIPHERY_RESULTS"
PERIPHERY_SRC='select(.location | test("/Tests/|/UITests/") | not)'
if ! command -v periphery >/dev/null; then
    unmeasured "Dead code · Periphery scan" "periphery is not installed" "$PERIPHERY_SCAN_CMD"
elif [[ ! -f .periphery.yml ]]; then
    unmeasured "Dead code · Periphery scan" \
        "periphery $(periphery version 2>/dev/null || echo '?') is installed but not configured (no .periphery.yml)" \
        "$PERIPHERY_SCAN_CMD"
elif (( SLOW )); then
    mkdir -p build
    measure "Dead code · Periphery scan" "$PERIPHERY_SCAN_CMD" "all findings, tests included"
    measure "Dead code · unused declarations in sources" \
        "jq '[.[] | select(.hints[] == \"unused\") | $PERIPHERY_SRC] | length' $PERIPHERY_RESULTS"
    measure "Dead code · assign-only properties in sources" \
        "jq '[.[] | select(.hints[] == \"assignOnlyProperty\") | $PERIPHERY_SRC] | length' $PERIPHERY_RESULTS"
    measure "Dead code · redundant public modifiers in sources" \
        "jq '[.[] | select(.hints[] == \"redundantPublicAccessibility\") | $PERIPHERY_SRC] | length' $PERIPHERY_RESULTS"
else
    unmeasured "Dead code · Periphery scan" \
        "pass --slow (the first scan builds the project, several minutes; later scans reuse the index)" \
        "$PERIPHERY_SCAN_CMD"
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
row "try? in sources" "$try_total" "$TRY_TOTAL_CMD" "occurrences"
row "try? with an else { log } companion" "$try_with" "$TRY_WITH_CMD" "log call on the else line or the next"
row "try? without a companion" "$((try_total - try_with))" "(try? in sources) - (try? with companion)"

measure "nonisolated(unsafe) in sources" "rg -o 'nonisolated\(unsafe\)' $SRC -g '*.swift' | $COUNT"
measure "@unchecked Sendable in sources" "rg -o '@unchecked Sendable' $SRC -g '*.swift' | $COUNT"
measure "@MainActor outside the UI layer" \
    "rg -o '@MainActor' Modules/*/Sources -g '*.swift' -g '!Modules/UI/**' | $COUNT" \
    "Modules/* except UI; App is UI layer"

for word in TODO FIXME XCTSkip fatalError; do
    measure "$word in sources" "rg -ow '$word' $SRC -g '*.swift' | $COUNT" "whole word"
done
measure "XCTSkip in tests" "rg -ow 'XCTSkip' Modules/*/Tests -g '*.swift' | $COUNT" "whole word"

# Allowlist: one ripgrep glob per line, excluded from the "outside" counts.
ALLOW_GLOBS=""
ALLOW_COUNT=0
if [[ -f "$ALLOWLIST" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        ALLOW_GLOBS+=" -g '!$line'"
        ALLOW_COUNT=$((ALLOW_COUNT + 1))
    done <"$ALLOWLIST"
fi
ALLOW_NOTE="$ALLOWLIST, $ALLOW_COUNT entries"
measure "Task { in sources" "rg -oF 'Task {' $SRC -g '*.swift' | $COUNT"
measure "Task { outside the allowlist" "rg -oF 'Task {' $SRC -g '*.swift'$ALLOW_GLOBS | $COUNT" "$ALLOW_NOTE"
measure "Timer.scheduledTimer in sources" "rg -o 'Timer\.scheduledTimer' $SRC -g '*.swift' | $COUNT"
measure "Timer.scheduledTimer outside the allowlist" \
    "rg -o 'Timer\.scheduledTimer' $SRC -g '*.swift'$ALLOW_GLOBS | $COUNT" "$ALLOW_NOTE"

measure "sql: statements" "rg -c 'sql:' $SRC -g '*.swift' | $SUM" "lines"
measure "sql: lines with interpolation" "rg -n 'sql:' $SRC -g '*.swift' | rg -cF '\\('" "contain \\("

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
        row "Clean build time · Release" "$(( $(date +%s) - start )) s" "time $RELEASE_CMD" "unsigned, arm64"
    else
        row "Clean build time · Release" "error" "time $RELEASE_CMD" "build failed; see build/vital-signs-release-build.log"
    fi
else
    unmeasured "Clean build time · Release" "pass --slow (several minutes)" "time $RELEASE_CMD"
fi

TRACE_CMD="xctrace record --template 'Time Profiler' --all-processes --time-limit 30s --output build/launch.trace & sleep 2 && open -a Bocan; then read the signpost interval from the trace (xctrace export --xpath)"
unmeasured "Cold start to first window" \
    "the app.bootstrap signpost exists (App/BocanApp.swift) but info-level log lines are not persisted to the unified log and no launch trace is automated" \
    "$TRACE_CMD"
unmeasured "Library load time for the large fixture" \
    "no large fixture exists yet; the tracks.load and library.scan signposts exist" \
    "$TRACE_CMD"
unmeasured "Hitch ratio for the standard playback scenario" \
    "no standard playback scenario or performance gate exists yet" \
    "xctrace record --template 'Animation Hitches' --attach <pid> --time-limit 45s --output build/hitches.trace"
unmeasured "Idle memory after 10 minutes of playback" \
    "the 10-minute playback protocol is not automated; sample a running instance by hand" \
    "ps -o rss= -p \$(pgrep -x Bocan) | awk '{printf \"%.0f MB\\n\", \$1 / 1024}'"

if (( RECORD )); then
    echo "recorded $RECORDED rows to $CSV as run $RUN_DATE ($RUN_COMMIT${LABEL:+, $LABEL})" >&2
fi
