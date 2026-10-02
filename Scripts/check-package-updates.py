#!/usr/bin/env python3
"""Reports pinned dependencies that lag their upstream releases.

Two kinds of pin are checked:

1. Every pin in the Xcode workspace's Package.resolved (the single source of
   truth for what every build actually links, including transitive pins and
   the app-level Sparkle dependency that Dependabot's Swift ecosystem cannot
   see).
2. The pins that live in a file of their own (FILE_PINS below): the FFmpeg and
   Chromaprint source releases the project builds (ADR-096), and the SwiftLint
   and SwiftFormat releases that CI installs and `make doctor` enforces.
   Nothing else watches these: they do not move until someone edits the file.

Not checked, because they are not pinned: the Homebrew libraries (TagLib,
LAME, Opus, OpenSSL), which every build takes at Homebrew's current version.
GitHub Actions versions are Dependabot's (.github/dependabot.yml).

Each pinned version is compared against the newest release tag upstream.

Uses the `gh` CLI for API access so the same invocation works locally and in
Actions. Prints a Markdown report to stdout. Run it from the repository root.

Exit codes: 0 = everything current, 2 = at least one pin lags upstream,
1 = a pin could not be checked (treated as a real failure so silent gaps
cannot masquerade as "all current").

GH_CMD overrides the `gh` executable, for the hermetic test in
Scripts/tests/check-package-updates-test.sh.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

RESOLVED = Path(
    "Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

# (name, pin file, key, GitHub repository). A key names the `KEY=value` line
# that holds the version; None means the file holds only the version.
FILE_PINS = [
    ("FFmpeg", ".ffmpeg-source", "FFMPEG_VERSION", "FFmpeg/FFmpeg"),
    ("Chromaprint", ".chromaprint-source", "CHROMAPRINT_VERSION", "acoustid/chromaprint"),
    ("SwiftLint", ".swiftlint-version", None, "realm/SwiftLint"),
    ("SwiftFormat", ".swiftformat-version", None, "nicklockwood/SwiftFormat"),
]

# A release version: 1.2.3 or 1.2, with the `v` most projects put before it or
# the `n` FFmpeg does (n9.0.2, n9.0). Pre-release and development tags
# (1.5.1rc1, n9.1-dev) do not match, on purpose.
VERSION = re.compile(r"^[vn]?(\d+)\.(\d+)(?:\.(\d+))?$")

TAGS_PER_PAGE = 100
# FFmpeg has several hundred tags and no GitHub releases; the newest are not
# all on the first page.
MAX_TAG_PAGES = 20


def parse_version(tag):
    match = VERSION.match(tag.strip())
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def gh_json(path):
    result = subprocess.run(
        [os.environ.get("GH_CMD", "gh"), "api", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def repo_slug(location):
    match = re.search(r"github\.com/([^/]+/[^/]+?)(?:\.git)?$", location)
    return match.group(1) if match else None


def newest_tag(slug):
    """Newest release version among all the tags of a repository."""
    versions = []
    for page in range(1, MAX_TAG_PAGES + 1):
        tags = gh_json(f"repos/{slug}/tags?per_page={TAGS_PER_PAGE}&page={page}")
        if not tags:
            break
        versions += [v for t in tags if (v := parse_version(t.get("name", "")))]
        if len(tags) < TAGS_PER_PAGE:
            break
    return max(versions) if versions else None


def latest_version(slug):
    """Newest version upstream: releases first, tags as the fallback for
    repos that never publish releases."""
    release = gh_json(f"repos/{slug}/releases/latest")
    if release:
        version = parse_version(release.get("tag_name", ""))
        if version:
            return version
    return newest_tag(slug)


def read_file_pin(path, key):
    """The version a pin file holds, or None when it cannot be read."""
    try:
        text = Path(path).read_text()
    except OSError:
        return None
    if key is None:
        return text.strip() or None
    match = re.search(rf"^{re.escape(key)}=(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def pinned_versions():
    """Yields (name, where, version text, repository) for every pin. The
    version text or the repository is None when it could not be read."""
    for pin in json.loads(RESOLVED.read_text())["pins"]:
        yield (
            pin["identity"],
            "Package.resolved",
            pin.get("state", {}).get("version"),
            repo_slug(pin.get("location", "")),
        )
    for name, path, key, slug in FILE_PINS:
        yield name, path, read_file_pin(path, key), slug


def main():
    outdated = []
    failures = []
    checked = 0

    for name, where, version_text, slug in pinned_versions():
        pinned = parse_version(version_text or "")
        if not (slug and pinned):
            failures.append(f"{name} ({where}): unpinned or non-GitHub, cannot check")
            continue
        latest = latest_version(slug)
        if latest is None:
            failures.append(f"{name} ({where}): no release versions found upstream")
            continue
        checked += 1
        if latest > pinned:
            gap = "MAJOR" if latest[0] > pinned[0] else "minor/patch"
            outdated.append((name, where, version_text, ".".join(map(str, latest)), gap))

    if outdated:
        print("| Dependency | Pinned in | Pinned | Latest | Gap |")
        print("|---|---|---|---|---|")
        for name, where, pinned_text, latest_text, gap in sorted(outdated):
            print(f"| {name} | `{where}` | {pinned_text} | {latest_text} | {gap} |")
        print()
        print(
            "Swift packages: major gaps need a manifest range change (SPM "
            "never crosses a major on its own); minor/patch gaps move with a "
            "package update plus the usual gates."
        )
        print()
        print(
            "Pins in a file of their own: change the file as its header says "
            "(`.ffmpeg-source` and `.chromaprint-source` hold a version, a URL "
            "and a checksum; rebuild with `make ffmpeg-lgpl` and `make "
            "bundle-fpcalc`, then run the full suites)."
        )
    else:
        print(f"All {checked} pins match their upstream latest releases.")

    for failure in failures:
        print(f"\nWARNING: {failure}", file=sys.stderr)

    if failures:
        return 1
    return 2 if outdated else 0


if __name__ == "__main__":
    sys.exit(main())
