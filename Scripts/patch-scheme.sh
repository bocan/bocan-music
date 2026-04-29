#!/usr/bin/env bash
# Phase 1 audit #13: enable Thread Sanitizer on the Bocan scheme's TestAction.
# XcodeGen's ProjectSpec has no flag for this; we patch the generated XML.
#
# Idempotent: safe to run on every regeneration.

set -euo pipefail

SCHEME="Bocan.xcodeproj/xcshareddata/xcshareddata/xcschemes/Bocan.xcscheme"
# XcodeGen actually writes to xcshareddata/xcschemes (single).  Try both.
for candidate in \
    "Bocan.xcodeproj/xcshareddata/xcschemes/Bocan.xcscheme" \
    "Bocan.xcodeproj/xcuserdata/${USER}.xcuserdatad/xcschemes/Bocan.xcscheme"
do
    [[ -f "$candidate" ]] || continue
    SCHEME="$candidate"
    break
done

if [[ ! -f "$SCHEME" ]]; then
    echo "patch-scheme: scheme not found, skipping"
    exit 0
fi

# Add enableThreadSanitizer="YES" to the <TestAction ...> opening tag if not
# already present.  Uses Python to avoid sed pitfalls with multiline XML.
python3 - "$SCHEME" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
def patch(tag, attr):
    global text
    pattern = re.compile(rf"<{tag}(\s+[^>]*?)>", re.DOTALL)
    def repl(m):
        head = m.group(1)
        if attr in head:
            return m.group(0)
        return f"<{tag}{head}\n      {attr}=\"YES\">"
    text = pattern.sub(repl, text, count=1)
patch("TestAction", "enableThreadSanitizer")
path.write_text(text)
print(f"patch-scheme: enabled TSan in {path}")
PY
