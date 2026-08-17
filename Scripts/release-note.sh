#!/usr/bin/env bash
# release-note.sh — Adds a human note to the pending release PR's CHANGELOG.
#
# Usage: release-note.sh   (or `make release-note`)
#
# The release-please bot force-recreates `release-please--branches--main`
# every cycle, so a surviving local copy of that branch is always a stale
# fossil, and a plain `git switch` + `git pull` merges two unrelated
# generations of it (the v2.8.0 incident: conflicts in every file the bot
# owns). This script encodes the only safe flow, with guardrails:
#
#   1. Refuses to run unless you are on main with a clean tree.
#   2. Fetches, and refuses if the bot branch does not exist on GitHub
#      (no pending release PR to annotate).
#   3. Force-resets the local branch onto the remote one (`switch -C`),
#      so a stale local copy is impossible.
#   4. Opens $EDITOR on CHANGELOG.md; write your note inside the newest
#      version's section, above the generated list.
#   5. Commits only if CHANGELOG.md (and nothing else) changed.
#   6. Pushes to GitHub ONLY — origin's pushurls fan out to Tangled and
#      Codeberg, which reject this GitHub-only branch.
#   7. Returns you to main; if anything is uncommitted or unpushed it
#      stays put and tells you, so nothing is ever lost silently.
#
# The note lands in CHANGELOG.md via the PR merge; the release workflow
# then applies that section to the GitHub release body and the Sparkle
# update prompt.

set -euo pipefail

BRANCH="release-please--branches--main"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

die() { echo "✗ $*" >&2; exit 1; }

# --- Guardrail: start from a clean main -------------------------------------
[[ "$(git branch --show-current)" == "main" ]] \
    || die "run this from main (currently on '$(git branch --show-current)')"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || die "working tree has uncommitted changes; commit or stash first"

# --- Guardrail: the bot branch must exist on GitHub -------------------------
GITHUB_URL="$(git remote get-url origin)"
[[ "$GITHUB_URL" == *github.com* ]] \
    || die "origin's fetch URL is not GitHub ($GITHUB_URL); refusing to guess where to push"
git fetch origin --prune
git rev-parse --verify -q "origin/$BRANCH" >/dev/null \
    || die "origin/$BRANCH does not exist: no pending release PR. Push to main and let the release-please action run first."

# --- Never-stale checkout ----------------------------------------------------
git switch -C "$BRANCH" "origin/$BRANCH"

# From here on, always try to leave the user back on main — unless doing so
# would lose work, in which case stay and explain.
cleanup() {
    [[ "$(git branch --show-current)" == "$BRANCH" ]] || return 0
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "! Uncommitted changes left on $BRANCH — staying on it so nothing is lost."
        return 0
    fi
    local ahead
    ahead="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"
    if [[ "$ahead" != "0" ]]; then
        echo "! $ahead unpushed commit(s) on $BRANCH — staying on it. Push with:"
        echo "    git push \"$GITHUB_URL\" $BRANCH"
        return 0
    fi
    git switch -q main
    echo "✓ Back on main."
}
trap cleanup EXIT

# --- Edit --------------------------------------------------------------------
"${EDITOR:-vi}" CHANGELOG.md

if git diff --quiet -- CHANGELOG.md; then
    echo "No changes made to CHANGELOG.md; nothing to do."
    exit 0
fi

# --- Guardrail: only CHANGELOG.md may change ---------------------------------
CHANGED="$(git status --porcelain --untracked-files=no | awk '{print $2}')"
[[ "$CHANGED" == "CHANGELOG.md" ]] \
    || die "unexpected changes beyond CHANGELOG.md: $CHANGED"

git add CHANGELOG.md
git commit -m "chore: release notes"

# --- Push to GitHub only -----------------------------------------------------
git push "$GITHUB_URL" "$BRANCH"

echo "✓ Note pushed to the release PR."
if command -v gh >/dev/null 2>&1; then
    gh pr list --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true
fi
echo "Merge the PR when ready; the release workflow carries these notes into the GitHub release and the Sparkle prompt."
