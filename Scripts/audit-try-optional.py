#!/usr/bin/env python3
"""#459 try? audit: every swallowed error is an allowlisted idiom.

Scans Modules/*/Sources and App for `try?`. The operator discards the error,
so any site outside the idioms below is a failure the app cannot report and
nobody can find in the log afterwards. The audit behind this rule, with all
325 sites of the 6e759707 tree classified, is
docs/audits/try-optional-audit.md.

Allowed by rule rather than by allowlist, these are the families the audit
found to carry no information the app can act on:

  - a Task.sleep whose only possible error is cancellation;
  - a file-handle close, typically in a defer;
  - remove-if-present of a cache or temp file, and directory pre-creation
    before a write that reports its own failure;
  - a file-attribute or directory-listing read with a fallback value;
  - a Codable encode/decode whose fallback is the documented contract;
  - a best-effort file read with a fallback.

Everything else must appear in Scripts/audit-try-optional-allowlist.txt with
a reason, keyed "<relative-path>|<normalized line>". Line numbers are
deliberately not part of the key, so ordinary edits do not churn the file.

Run `--keys` to print paste-ready allowlist lines for whatever is failing.

Exit codes: 0 clean (or --warn mode), 1 violations in strict mode (the
default, matching `make lint`).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN_GLOBS = ["Modules/*/Sources", "App"]
ALLOWLIST_FILE = ROOT / "Scripts" / "audit-try-optional-allowlist.txt"

TRY_OPTIONAL_RE = re.compile(r"(?<![\w.])try\?")

# Each entry is (idiom name, pattern). The name is only used in --verbose
# output; matching any one of them clears the site.
IDIOM_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "cancellation-only sleep",
        re.compile(r"try\?\s*await\s+Task\.sleep\b"),
    ),
    (
        "file-handle close",
        re.compile(r"try\?\s*[\w.]*\bclose\(\)"),
    ),
    (
        "remove-if-present / directory pre-creation",
        re.compile(r"try\?\s*[\w.]*\.(removeItem|createDirectory)\("),
    ),
    (
        "file-attribute or directory read with a fallback",
        re.compile(
            r"try\?\s*[\w.$]*\.?resourceValues\("
            r"|try\?\s*[\w.]*\.(attributesOfItem|setAttributes|contentsOfDirectory)\("
        ),
    ),
    (
        "documented-contract Codable",
        re.compile(
            r"try\?\s*JSONDecoder\(\)\.decode\("
            r"|try\?\s*JSONEncoder\(\)\.encode\("
            r"|try\?\s*\w+\.decode\([\w\[\].]+\.self,\s*forKey"
        ),
    ),
    (
        "best-effort file read with a fallback",
        re.compile(
            r"try\?\s*Data\(contentsOf"
            r"|try\?\s*[\w.]*\.read\(upToCount"
            r"|try\?\s*FileHandle\(forReadingFrom"
        ),
    ),
]


def site_key(path: pathlib.Path, line: str, root: pathlib.Path) -> str:
    return f"{path.relative_to(root)}|{' '.join(line.split())}"


def load_allowlist(allowlist_file: pathlib.Path) -> set[str]:
    allowed = set()
    if allowlist_file.exists():
        for raw in allowlist_file.read_text().splitlines():
            entry = raw.split("#", 1)[0].strip()
            if entry:
                allowed.add(entry)
    return allowed


def matched_idiom(line: str) -> str | None:
    for name, pattern in IDIOM_PATTERNS:
        if pattern.search(line):
            return name
    return None


def scan_file(path: pathlib.Path) -> list[tuple[int, str]]:
    sites = []
    for i, line in enumerate(path.read_text().splitlines()):
        stripped = line.strip()
        if stripped.startswith("//") or not TRY_OPTIONAL_RE.search(stripped):
            continue
        sites.append((i + 1, stripped))
    return sites


def source_files(root: pathlib.Path) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for glob in SCAN_GLOBS:
        for base in sorted(root.glob(glob)):
            files.extend(sorted(base.rglob("*.swift")))
    return [f for f in files if "Tests" not in f.parts]


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
        "--keys", action="store_true",
        help="print paste-ready allowlist lines for the current violations"
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="print every site and the idiom that cleared it"
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
    keys: list[str] = []
    idiom_count = 0

    for path in source_files(root):
        for lineno, line in scan_file(path):
            idiom = matched_idiom(line)
            if idiom is not None:
                idiom_count += 1
                if args.verbose:
                    print(f"  ok {path.relative_to(root)}:{lineno}: {idiom}")
                continue
            key = site_key(path, line, root)
            if key in allowed:
                used.add(key)
                if args.verbose:
                    print(f"  ok {path.relative_to(root)}:{lineno}: allowlisted")
                continue
            failures.append(f"{path.relative_to(root)}:{lineno}: {line[:110]}")
            keys.append(key)

    for stale in sorted(allowed - used):
        print(f"note: stale allowlist entry (site fixed or moved): {stale}")

    if args.keys:
        for key in keys:
            print(f"{key}  # REASON")

    if failures:
        if args.summary:
            print(
                f"{len(failures)} swallowed error(s) outside the try? allowlist "
                "(python3 Scripts/audit-try-optional.py --warn lists them)"
            )
        elif not args.keys:
            print(f"{len(failures)} swallowed error(s) outside the try? allowlist:")
            for failure in failures:
                print(f"  {failure}")
        return 0 if args.warn else 1

    print(f"try? audit clean ({idiom_count} idiom sites, {len(used)} allowlisted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
