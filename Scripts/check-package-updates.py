#!/usr/bin/env python3
"""Reports Package.resolved pins that lag their upstream releases.

Reads the Xcode workspace's Package.resolved (the single source of truth for
what every build actually links, including transitive pins and the app-level
Sparkle dependency that Dependabot's Swift ecosystem cannot see) and compares
each pinned version against the newest semver tag upstream.

Uses the `gh` CLI for API access so the same invocation works locally and in
Actions. Prints a Markdown report to stdout.

Exit codes: 0 = everything current, 2 = at least one pin lags upstream,
1 = a pin could not be checked (treated as a real failure so silent gaps
cannot masquerade as "all current").
"""

import json
import re
import subprocess
import sys
from pathlib import Path

RESOLVED = Path(
    "Bocan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def parse_semver(tag):
    match = SEMVER.match(tag.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def gh_json(path):
    result = subprocess.run(
        ["gh", "api", path],
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


def latest_version(slug):
    """Newest semver upstream: releases first, tags as the fallback for
    repos that never publish releases."""
    release = gh_json(f"repos/{slug}/releases/latest")
    if release:
        version = parse_semver(release.get("tag_name", ""))
        if version:
            return version
    tags = gh_json(f"repos/{slug}/tags?per_page=100") or []
    versions = [v for t in tags if (v := parse_semver(t.get("name", "")))]
    return max(versions) if versions else None


def main():
    pins = json.loads(RESOLVED.read_text())["pins"]
    outdated = []
    failures = []

    for pin in pins:
        identity = pin["identity"]
        version_text = pin.get("state", {}).get("version")
        slug = repo_slug(pin.get("location", ""))
        pinned = parse_semver(version_text or "")
        if not (slug and pinned):
            failures.append(f"{identity}: unpinned or non-GitHub, cannot check")
            continue
        latest = latest_version(slug)
        if latest is None:
            failures.append(f"{identity}: no semver releases or tags found")
            continue
        if latest > pinned:
            gap = "MAJOR" if latest[0] > pinned[0] else "minor/patch"
            outdated.append((identity, version_text, ".".join(map(str, latest)), gap))

    if outdated:
        print("| Package | Pinned | Latest | Gap |")
        print("|---|---|---|---|")
        for identity, pinned_text, latest_text, gap in sorted(outdated):
            print(f"| {identity} | {pinned_text} | {latest_text} | {gap} |")
        print()
        print(
            "Major gaps need a manifest range change (SPM never crosses a "
            "major on its own); minor/patch gaps move with a package update "
            "plus the usual gates."
        )
    else:
        print("All Package.resolved pins match their upstream latest releases.")

    for failure in failures:
        print(f"\nWARNING: {failure}", file=sys.stderr)

    if failures:
        return 1
    return 2 if outdated else 0


if __name__ == "__main__":
    sys.exit(main())
