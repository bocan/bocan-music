#!/usr/bin/env python3
"""Phase 29 help-text audit: every interactive control ships with .help().

Scans Modules/UI/Sources and App/ for interactive-control call sites
(Button, Toggle, Picker, Slider, Menu) whose modifier chain lacks an
attached .help(...), so hover text coverage is enforced at the source
level (the agreed audit-plus-spot-check hover policy).

Skipped contexts, by rule rather than allowlist:
  - menu-item contexts (Menu { }, CommandMenu, CommandGroup, .contextMenu,
    confirmationDialog, .swipeActions, Picker option closures): macOS does
    not render tooltips inside open menus, so .help() there is dead code;
  - test sources, #Preview bodies, and *_Previews types.

Everything else lacking .help() must appear in the allowlist file
(Scripts/audit-help-text-allowlist.txt) with a reason, keyed by
"<relative-path>|<normalized first line of the call site>". Line numbers
are deliberately not part of the key so ordinary edits don't churn it.

Exit codes: 0 clean (or --warn mode), 1 violations in strict mode (the
default, matching `make lint`).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN_DIRS = ["Modules/UI/Sources", "App"]
ALLOWLIST_FILE = ROOT / "Scripts" / "audit-help-text-allowlist.txt"

CONSTRUCT_RE = re.compile(r"(?<![\w.])(Button|Toggle|Picker|Slider|Menu)\s*[({]")
# Entering any of these opens a "menu item" context where .help() is inert:
# macOS renders no tooltips inside open menus, alerts, or dialogs. Menu
# content is often built in dedicated builder functions/properties, so
# declarations whose name mentions "menu" open the same context.
MENU_CONTEXT_RE = re.compile(
    r"(?<![\w.])(Menu|CommandMenu|CommandGroup)\s*[({]"
    r"|\.contextMenu\s*[({]"
    r"|confirmationDialog\s*\("
    r"|\.alert\s*\("
    r"|\.swipeActions\s*[({]"
    r"|dockMenu"
    r"|(?:func|var)\s+\w*[Mm]enu\w*"
)
PREVIEW_RE = re.compile(r"#Preview|_Previews\b")


def depth_delta(line: str) -> int:
    """Net brace depth change, ignoring braces inside string literals."""
    delta, in_string, escape = 0, False, False
    for char in line:
        if escape:
            escape = False
            continue
        if char == "\\":
            escape = True
        elif char == '"':
            in_string = not in_string
        elif not in_string:
            if char in "{(":
                delta += 1
            elif char in "})":
                delta -= 1
    return delta


def statement_chain(lines: list[str], start: int) -> str:
    """The call at `lines[start]` plus its whole modifier chain."""
    chain = [lines[start]]
    depth = depth_delta(lines[start])
    i = start + 1
    while i < len(lines):
        stripped = lines[i].strip()
        if depth <= 0 and not stripped.startswith("."):
            break
        chain.append(lines[i])
        depth += depth_delta(lines[i])
        i += 1
    return "\n".join(chain)


def site_key(path: pathlib.Path, line: str) -> str:
    return f"{path.relative_to(ROOT)}|{' '.join(line.split())}"


def load_allowlist() -> set[str]:
    allowed = set()
    if ALLOWLIST_FILE.exists():
        for raw in ALLOWLIST_FILE.read_text().splitlines():
            entry = raw.split("#", 1)[0].strip()
            if entry:
                allowed.add(entry)
    return allowed


def scan_file(path: pathlib.Path) -> list[tuple[int, str, str]]:
    lines = path.read_text().splitlines()
    violations = []
    menu_depth_stack: list[int] = []  # depths at which a menu context opened
    preview_depth: int | None = None
    depth = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if preview_depth is None and PREVIEW_RE.search(stripped):
            preview_depth = depth
        if preview_depth is None and not menu_depth_stack:
            match = CONSTRUCT_RE.search(stripped)
            if match and not stripped.startswith("//"):
                chain = statement_chain(lines, i)
                if ".help(" not in chain:
                    violations.append((i + 1, match.group(1), stripped))
        if MENU_CONTEXT_RE.search(stripped) and not stripped.startswith("//"):
            menu_depth_stack.append(depth)
        depth += depth_delta(line)
        menu_depth_stack = [d for d in menu_depth_stack if depth > d]
        if preview_depth is not None and depth <= preview_depth:
            preview_depth = None
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--warn", action="store_true",
        help="report violations without failing (rollout mode)"
    )
    args = parser.parse_args()

    allowed = load_allowlist()
    used: set[str] = set()
    failures = []
    for scan_dir in SCAN_DIRS:
        for path in sorted((ROOT / scan_dir).rglob("*.swift")):
            if "Tests" in path.parts:
                continue
            for lineno, construct, line in scan_file(path):
                key = site_key(path, line)
                if key in allowed:
                    used.add(key)
                    continue
                failures.append(
                    f"{path.relative_to(ROOT)}:{lineno}: {construct} without .help(): {line[:100]}"
                )

    for stale in sorted(allowed - used):
        print(f"note: stale allowlist entry (control gained help or moved): {stale}")

    if failures:
        print(f"{len(failures)} interactive control(s) without help text:")
        for failure in failures:
            print(f"  {failure}")
        return 0 if args.warn else 1
    print("help-text audit clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
