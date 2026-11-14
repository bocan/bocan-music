#!/usr/bin/env python3
"""Jellyfin SDK import audit: only Modules/Jellyfin may use the Jellyfin SDK.

ADR-097 (D6) confines the official `jellyfin-sdk-swift` package to the
`Jellyfin` module. Its views and the App see only the module's own models
(`JellyfinSong` and so on), so the SDK can be swapped for a thin client
without touching anything above the `JellyfinClientProtocol` seam.

Scans every Swift file for `import JellyfinAPI`, and every `Package.swift`
for the SDK package or product name. Modules/Jellyfin is exempt. Build
output and checkouts are skipped.

Exit codes: 0 clean, 1 violations.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXEMPT_PREFIX = "Modules/Jellyfin/"
SKIP_PARTS = {".build", "build", "DerivedData", "node_modules", ".git", "checkouts"}

# Matches `import JellyfinAPI`, attribute-prefixed forms (`@preconcurrency
# import JellyfinAPI`) and scoped forms (`import struct JellyfinAPI.BaseItemDto`).
IMPORT_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?JellyfinAPI\b"
)
MANIFEST_RE = re.compile(r"jellyfin-sdk-swift|\"JellyfinAPI\"")


def scan(root: pathlib.Path) -> list[str]:
    problems = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in SKIP_PARTS for part in path.relative_to(root).parts):
            continue
        rel = path.relative_to(root).as_posix()
        if rel.startswith(EXEMPT_PREFIX):
            continue
        if path.suffix == ".swift":
            pattern = IMPORT_RE
        elif path.name == "Package.swift":
            pattern = MANIFEST_RE
        else:
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if pattern.search(line):
                problems.append(f"{rel}:{number}: {line.strip()}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--summary", action="store_true", help="print one line when clean")
    parser.add_argument("--root", type=pathlib.Path, default=ROOT, help="repository root (for tests)")
    args = parser.parse_args()

    problems = scan(args.root)
    if problems:
        print("Jellyfin SDK used outside Modules/Jellyfin (ADR-097, D6):")
        for problem in problems:
            print(f"  {problem}")
        print("Use the module's own models and JellyfinService instead.")
        return 1
    if args.summary:
        print("Jellyfin SDK import audit clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
