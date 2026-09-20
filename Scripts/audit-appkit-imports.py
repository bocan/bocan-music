#!/usr/bin/env python3
"""AppKit import audit: UI is the only module that imports AppKit.

Scans Modules/*/Sources for `import AppKit` (and `import Cocoa`, which pulls
AppKit in). The `UI` module owns every AppKit surface, and the `App` target
hosts the NSWorkspace, NSApp and dock subscriptions the lower modules need, so
neither is scanned. A lower module that wants an AppKit notification exposes a
plain method and lets the app target call it: `SubsonicConnectionMonitor.wakeAll()`
is the model. The rule is docs/design-spec/_standards.md ("Dependency
directions").

A file that cannot avoid AppKit goes in
Scripts/audit-appkit-imports-allowlist.txt, one repo-relative path per line
with a trailing reason. That list is meant to stay at one or two entries.

Exit codes: 0 clean (or --warn mode), 1 violations in strict mode (the
default, matching `make lint`).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN_GLOB = "Modules/*/Sources"
EXEMPT_MODULES = {"UI"}
ALLOWLIST_FILE = ROOT / "Scripts" / "audit-appkit-imports-allowlist.txt"

# Matches `import AppKit`, attribute-prefixed forms (`@preconcurrency import
# AppKit`) and scoped forms (`import class AppKit.NSImage`).
IMPORT_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
    r"(AppKit|Cocoa)\b"
)


def load_allowlist(allowlist_file: pathlib.Path) -> set[str]:
    allowed = set()
    if allowlist_file.exists():
        for raw in allowlist_file.read_text().splitlines():
            entry = raw.split("#", 1)[0].strip()
            if entry:
                allowed.add(entry)
    return allowed


def source_files(root: pathlib.Path) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for base in sorted(root.glob(SCAN_GLOB)):
        if base.parent.name in EXEMPT_MODULES:
            continue
        files.extend(sorted(base.rglob("*.swift")))
    return [f for f in files if "Tests" not in f.parts]


def scan_file(path: pathlib.Path) -> list[tuple[int, str]]:
    sites = []
    for i, line in enumerate(path.read_text().splitlines()):
        match = IMPORT_RE.match(line)
        if match:
            sites.append((i + 1, match.group(1)))
    return sites


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--warn", action="store_true",
        help="report violations without failing (rollout mode)"
    )
    parser.add_argument(
        "--summary", action="store_true",
        help="print the violation count only, not the list"
    )
    parser.add_argument(
        "--root", help="scan this directory instead of the repo root (testing)"
    )
    parser.add_argument(
        "--allowlist", help="use this allowlist file (testing)"
    )
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve() if args.root else ROOT
    allowlist_file = pathlib.Path(args.allowlist) if args.allowlist else ALLOWLIST_FILE

    allowed = load_allowlist(allowlist_file)
    used: set[str] = set()
    failures: list[str] = []

    for path in source_files(root):
        relative = str(path.relative_to(root))
        for lineno, framework in scan_file(path):
            if relative in allowed:
                used.add(relative)
                continue
            failures.append(f"{relative}:{lineno}: import {framework}")

    for stale in sorted(allowed - used):
        print(f"note: stale allowlist entry (import removed or file moved): {stale}")

    if failures:
        if args.summary:
            print(
                f"{len(failures)} AppKit import(s) outside the UI module "
                "(python3 Scripts/audit-appkit-imports.py --warn lists them)"
            )
        else:
            print(f"{len(failures)} AppKit import(s) outside the UI module:")
            for failure in failures:
                print(f"  {failure}")
        return 0 if args.warn else 1

    print(f"AppKit import audit clean ({len(used)} allowlisted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
