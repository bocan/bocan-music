#!/usr/bin/env python3
"""Regenerate the en-XA pseudolocale in the UI module String Catalog (#314).

For every key in Modules/UI/Sources/UI/Resources/Localizable.xcstrings this
script derives an accented, ~30%-expanded variant of the English copy and
stores it as the "en-XA" localization. Running the built app with
-AppleLanguages '(en-XA)' then proves at a glance that copy resolves through
the catalog (accented text) and that layouts survive text expansion (padding).

Rules:
- The English source is the explicit "en" value when present, otherwise the
  key itself (Xcode's auto-extracted stub entries carry no "en" value).
- Format specifiers (%@, %lld, %1$@, %%, ...) pass through untouched.
- Values without any ASCII letter (separators like "·") are left unchanged.
- Plural variations are pseudolocalized per variation.
- The catalog is rewritten in Xcode's canonical form (sorted keys, " : "
  separators, two-space indent), so re-running the script is a no-op.

Usage: python3 Scripts/gen-pseudolocale.py  (or `make pseudolocale`)
"""

import json
import math
import re
import sys
from itertools import cycle
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / (
    "Modules/UI/Sources/UI/Resources/Localizable.xcstrings"
)

ACCENTS = str.maketrans(
    "abcdefghijklmnoprstuwyzABCDEFGHIJKLMNOPRSTUWYZ",
    "áƀçđéƒĝĥíĵķĺḿñóƥŕšţúŵýžÁƁÇĐÉƑĜĤÍĴĶĹḾÑÓƤŔŠŢÚŴÝŽ",
)

# %% first, then positional/precision forms; length specifiers before short ones.
SPECIFIER = re.compile(r"%%|%(?:\d+\$)?(?:\.\d+)?(?:lld|llu|ld|lu|@|d|u|f|s|x|X)")

PAD_WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]


def accent(text):
    """Accent every letter outside format specifiers."""
    out = []
    last = 0
    for m in SPECIFIER.finditer(text):
        out.append(text[last:m.start()].translate(ACCENTS))
        out.append(m.group())
        last = m.end()
    out.append(text[last:].translate(ACCENTS))
    return "".join(out)


def pseudo(value):
    if not re.search(r"[A-Za-z]", value):
        return value
    result = accent(value)
    target = math.ceil(len(value) * 0.3)
    added = 0
    words = cycle(PAD_WORDS)
    while added < target:
        word = next(words)
        result += " " + word
        added += len(word) + 1
    return result


def unit(value):
    return {"state": "translated", "value": value}


def localize(key, entry):
    """Attach an en-XA localization derived from the en value (or the key)."""
    locs = entry.setdefault("localizations", {})
    en = locs.get("en", {})
    if "variations" in en:
        plural = en["variations"]["plural"]
        xa_plural = {
            category: {"stringUnit": unit(pseudo(v["stringUnit"]["value"]))}
            for category, v in plural.items()
        }
        locs["en-XA"] = {"variations": {"plural": xa_plural}}
    else:
        source = en.get("stringUnit", {}).get("value", key)
        locs["en-XA"] = {"stringUnit": unit(pseudo(source))}
    if not locs:
        del entry["localizations"]


def main():
    data = json.loads(CATALOG.read_text())
    strings = data["strings"]
    count = 0
    for key, entry in strings.items():
        entry.get("localizations", {}).pop("en-XA", None)
        if not key:
            if entry.get("localizations") == {}:
                del entry["localizations"]
            continue
        localize(key, entry)
        count += 1
    text = json.dumps(data, indent=2, separators=(",", " : "), ensure_ascii=False, sort_keys=True)
    # Xcode writes empty entries as multi-line objects.
    text = re.sub(r'(?m)^(    "(?:[^"\\]|\\.)*" : )\{\}(,?)$', r"\1{\n\n    }\2", text)
    CATALOG.write_text(text + "\n")
    print(f"en-XA generated for {count} of {len(strings)} keys -> {CATALOG}")


if __name__ == "__main__":
    sys.exit(main())
