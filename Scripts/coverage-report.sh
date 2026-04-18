#!/usr/bin/env bash
# coverage-report.sh — Parse an .xcresult bundle and fail if line coverage
# for any module is below the threshold.
#
# Usage: Scripts/coverage-report.sh <path-to.xcresult> <threshold-percent>
# Example: Scripts/coverage-report.sh build/TestResults.xcresult 80
set -euo pipefail

RESULT_BUNDLE="${1:?Usage: $0 <path.xcresult> <threshold>}"
THRESHOLD="${2:?Usage: $0 <path.xcresult> <threshold>}"

echo "=== Coverage report ==="
echo "Bundle : $RESULT_BUNDLE"
echo "Minimum: ${THRESHOLD}%"
echo ""

# Extract JSON coverage report
JSON=$(xcrun xccov view --report --json "$RESULT_BUNDLE" 2>/dev/null) || {
    echo "ERROR: Could not parse xcresult. Raw structure below for diagnostics:"
    xcrun xccov view --report "$RESULT_BUNDLE" 2>&1 || true
    exit 1
}

# Parse line coverage for each target (requires jq or python)
if command -v jq &>/dev/null; then
    FAILED=0
    while IFS= read -r line; do
        TARGET=$(echo "$line" | jq -r '.name')
        RAW_COV=$(echo "$line" | jq -r '.lineCoverage')
        # Convert 0-1 float to integer percent
        PERCENT=$(echo "$RAW_COV" | awk '{printf "%d", $1 * 100}')
        echo "  $TARGET: ${PERCENT}%"
        if [[ "$PERCENT" -lt "$THRESHOLD" ]]; then
            echo "  ✗ BELOW THRESHOLD (${THRESHOLD}%)"
            FAILED=1
        else
            echo "  ✓"
        fi
    done < <(echo "$JSON" | jq -c '.targets[] | select(.name | test("Observability|Bocan"; "i"))')

    if [[ "$FAILED" -ne 0 ]]; then
        echo ""
        echo "Coverage below ${THRESHOLD}%. Failing build."
        exit 1
    fi
else
    # Fallback: python3
    python3 - <<PYEOF "$JSON" "$THRESHOLD"
import sys, json

raw = sys.argv[1]
threshold = int(sys.argv[2])
data = json.loads(raw)

failed = False
for target in data.get("targets", []):
    name = target["name"]
    cov = int(target["lineCoverage"] * 100)
    mark = "✓" if cov >= threshold else "✗ BELOW THRESHOLD"
    print(f"  {name}: {cov}%  {mark}")
    if cov < threshold:
        failed = True

if failed:
    print(f"\nCoverage below {threshold}%. Failing build.")
    sys.exit(1)
PYEOF
fi

echo ""
echo "Coverage check passed."
