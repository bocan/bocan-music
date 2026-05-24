#!/usr/bin/env bash
# coverage-all.sh — Run `swift test --enable-code-coverage` against every
# SPM module under Modules/ and fail if any module's line coverage falls
# below the threshold.
#
# Usage: Scripts/coverage-all.sh <threshold-percent> [module ...]
# Example: Scripts/coverage-all.sh 70
#          Scripts/coverage-all.sh 70 UI Playback
#
# Per-module thresholds can be overridden via env vars of the form
# COVERAGE_MIN_<MODULE>, e.g. COVERAGE_MIN_UI=20 for SwiftUI-heavy targets.
set -euo pipefail

THRESHOLD_DEFAULT="${1:?Usage: $0 <threshold> [module ...]}"
shift || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$REPO_ROOT/Modules"

if [[ "$#" -gt 0 ]]; then
    MODULES=("$@")
else
    MODULES=()
    for d in "$MODULES_DIR"/*/; do
        name="$(basename "$d")"
        # Skip modules without tests
        if [[ -d "$d/Tests" ]] && ls "$d/Tests"/*/ >/dev/null 2>&1; then
            MODULES+=("$name")
        fi
    done
fi

echo "=== coverage-all ==="
echo "Default minimum : ${THRESHOLD_DEFAULT}%"
echo "Modules         : ${MODULES[*]}"
echo ""

FAILED=()
SUMMARY=()

for module in "${MODULES[@]}"; do
    mod_dir="$MODULES_DIR/$module"
    if [[ ! -f "$mod_dir/Package.swift" ]]; then
        echo "  skip $module (no Package.swift)"
        continue
    fi

    upper="$(echo "$module" | tr '[:lower:]' '[:upper:]')"
    threshold_var="COVERAGE_MIN_${upper}"
    threshold="${!threshold_var:-$THRESHOLD_DEFAULT}"

    echo "------------------------------------------------------------"
    echo "[$module] running tests (min ${threshold}%)"
    echo "------------------------------------------------------------"

    (cd "$mod_dir" && swift test --enable-code-coverage --quiet)

    profdata="$mod_dir/.build/debug/codecov/default.profdata"
    xctest="$mod_dir/.build/debug/${module}PackageTests.xctest"
    if [[ ! -d "$xctest" ]]; then
        # Fall back to glob
        xctest="$(find "$mod_dir/.build/debug" -maxdepth 1 -type d -name '*PackageTests.xctest' | head -1)"
    fi
    binary="$xctest/Contents/MacOS/$(basename "$xctest" .xctest)"

    if [[ ! -f "$profdata" || ! -x "$binary" ]]; then
        echo "  ERROR: missing coverage artefacts for $module"
        echo "    profdata: $profdata"
        echo "    binary  : $binary"
        FAILED+=("$module (missing artefacts)")
        continue
    fi

    total_line="$(xcrun llvm-cov report \
        "$binary" \
        -instr-profile="$profdata" \
        -ignore-filename-regex='(\.build|/Tests/|/checkouts/|\.derivedSources)' \
        2>/dev/null \
        | awk '/^TOTAL/ {print $7}' \
        | tr -d '%')"

    if [[ -z "$total_line" ]]; then
        echo "  ERROR: could not parse llvm-cov output for $module"
        FAILED+=("$module (parse error)")
        continue
    fi

    # llvm-cov prints percentages with one decimal; compare as integer floor.
    percent_int="$(printf '%.0f' "$total_line")"
    if [[ "$percent_int" -lt "$threshold" ]]; then
        mark="✗ BELOW ${threshold}%"
        FAILED+=("$module: ${total_line}% < ${threshold}%")
    else
        mark="✓"
    fi
    line="  $module : ${total_line}%  $mark"
    echo "$line"
    SUMMARY+=("$line")
done

echo ""
echo "=== Summary ==="
for s in "${SUMMARY[@]}"; do echo "$s"; done

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    echo ""
    echo "Coverage gate failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi

echo ""
echo "All modules at or above their threshold."
