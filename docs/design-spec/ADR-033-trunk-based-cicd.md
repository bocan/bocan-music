# ADR-033: Trunk-based development and a small, guarded CI/CD

> Status: **in progress**, written slice by slice as the pipeline is rebuilt.
> Each slice's pull request updates the Status and Migration sections below.
> Read `docs/design-spec/_standards.md` first.

## Context

An earlier version of this ADR (a five-workflow, composite-action, fully
automated continuous-delivery design) was shelved as more complex than the
problem. It has been discarded; this document starts again from the actual
pain, which is that the maintainer keeps making mistakes with the release
process:

- Releasing needs a ritual in the right order: push to `main`, wait for the
  release-please bot to open its PR, run `make release-note` to add prose to
  the bot's branch, merge the PR, then run the Release workflow. Steps get
  forgotten, and the ritual is understood by nobody, the maintainer included.
- Release notes come out blank, or as a bare commit list with the human
  summary missing, because the prose is written at the last moment on a bot
  branch that is force-recreated every cycle.
- All work is committed straight to `main`. There is no review point, no
  place to stop, and no branch protection.
- The full test suite runs three times per released commit: on push to
  `main`, in CodeQL's build, and again inside the Release workflow. Every push
  to `main` costs a full macOS run even for a one-line fix.
- The Release workflow commits the appcast back to `main`, so local `main`
  routinely diverges from the remote and `git pull` has bitten more than once.

## Decision

1. **Trunk-based development.** `main` is the trunk and is never committed to
   directly. Every change, however small, is made on a short-lived branch named
   `<type>/<slug>` (`fix/349-album-grid-scroll-restore`,
   `feat/phone-sync-manifest`), lives hours to a couple of days, and lands by
   pull request. The full standard is in `CLAUDE.md` ("Branching").
2. **Light CI on branch push, full CI on the pull request, nothing on
   `main`.** A branch push runs only a secret scan, lint, format-check and a
   Debug build. The pull request runs the full test and coverage suite plus
   CodeQL. Pushes to `main` trigger no build at all: with branch protection
   requiring the PR checks, every commit on `main` has already passed them.
3. **Squash-only merges with a Conventional Commit PR title.** The pull
   request is the unit of change; its title becomes the one commit on `main`
   and its description becomes the commit body. Per-slice commits stay on the
   branch and in the PR for reference. Repository settings: squash merging
   only, squash title = PR title, squash message = PR description,
   delete branch on merge (done 2026-08-30).
4. **Release notes are written on the branch, in the same PR as the change.**
   `CHANGELOG.md` keeps an `## [Unreleased]` section at the top. Human prose
   for a user-visible change goes there, in the PR that makes the change, and a
   PR check refuses a `feat`, `fix` or `perf` PR that does not touch it. At
   release time the section is renamed to the version and the generated list
   of squash-commit subjects is appended beneath the prose. The GitHub release
   body and the Sparkle update prompt are that section, verbatim.
5. **No CI commits to `main`.** Generated artifacts (DMG, checksums, appcast)
   live as release assets or on a dedicated branch, never as commits on trunk.
6. **No repository secrets in branch CI.** A compile only needs the
   `Secrets.xcconfig.template` placeholders; real keys are exposed to the PR
   and release workflows only.

## Workflows

| File | Trigger | Does | Status |
|---|---|---|---|
| `branch.yml` | push to any branch except `main` | gitleaks on `origin/main..HEAD` (Linux, parallel); lint + format-check + `make build` (macOS) | **built**, slice 1 |
| `pr.yml` | pull request to `main` | full suite: `make test-coverage` + SPM package tests; Conventional Commit title check; `Unreleased` changelog check | planned, slice 2 |
| `codeql.yml` | pull request + weekly cron | CodeQL Swift analysis (drop the push-to-main trigger) | planned, slice 2 |
| `release.yml` | to be decided in slice 3 | build, sign, notarize, DMG, GitHub release, appcast, cask dispatch | existing, to be reworked |
| `website.yml` | push to `main` touching `website/**`, after a release | Eleventy build + Pages deploy | existing, keep |
| `dependency-drift.yml` | weekly cron | pin drift report as an issue | existing, keep |
| `ci.yml` | push to `main` + PR | today's full suite | to be replaced by `pr.yml` |
| `release-please.yml` | push to `main` | bot release PR, tag, release | to be deleted in slice 3 |

Changes touching only `**.md`, `docs/**` or `website/**` skip the build workflows.

## Guardrails

| Mistake | What stops it |
|---|---|
| Committing on `main` | `CLAUDE.md` rule now; branch protection once `pr.yml` exists |
| Pushing a secret | gitleaks in the pre-commit hook (per clone, `make install-hooks`) and in `branch.yml` (authoritative) |
| Breaking the build and not noticing until the PR | `make build` on every branch push |
| Bad squash commit subject, so the wrong version bump | required PR title format check (slice 2) |
| Blank or prose-less release notes | `Unreleased` section check on the PR (slice 2) |
| Releasing an unmerged or untested commit | releases cut from `main` only, which only holds PR-checked commits |

## Secrets

| Secret | Used by |
|---|---|
| `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` | `release.yml`: signing and notarization |
| `SPARKLE_ED_PRIVATE_KEY` | `release.yml`: appcast entry signature |
| `HOMEBREW_TAP_TOKEN` | `release.yml`: `repository_dispatch` to `bocan/homebrew-bocan` |
| `ACOUSTID_API_KEY`, `BOCAN_LASTFM_API_KEY`, `BOCAN_LASTFM_SHARED_SECRET`, `PODCAST_INDEX_API_KEY`, `PODCAST_INDEX_API_SECRET` | `release.yml` (baked into the shipped build); `pr.yml` and `codeql.yml` for the test build |
| `GITHUB_TOKEN` (default) | everything else |

`branch.yml` uses none of them.

## Migration

Each slice is one branch and one PR.

1. **Branch CI** (this PR): `branch.yml`, gitleaks in Brewfile and hook,
   `CLAUDE.md` branching rule, this ADR rewritten. GitHub set to squash-only.
2. **PR CI**: `pr.yml` replaces `ci.yml`; CodeQL loses its push trigger; PR
   title and `Unreleased` checks; `## [Unreleased]` added to `CHANGELOG.md`.
   Then enable branch protection on `main`: require a PR, require the `pr.yml`
   and CodeQL checks, no direct pushes, no force pushes.
3. **Release**: decide and build the release trigger and version bump; rework
   `release.yml` to consume the `Unreleased` section and stop committing the
   appcast to `main`. Delete `release-please.yml`, `release-please-config.json`,
   `.release-please-manifest.json`, `Scripts/release-note.sh` and the
   `release-note` Makefile target. Close the bot's open release PR.
4. **Docs**: `CONTRIBUTING.md`, `DEVELOPMENT.md` and the website release notes
   page updated to the new flow.

Until slice 3, the release-please bot keeps refreshing its PR after every
merge to `main`. Ignore it; it only edits its own branch, never `main`.

## Not doing

- No beta/nightly channel automation, release trains, delta updates, or
  release dashboards.
- No composite actions or reusable workflows until two workflows genuinely
  share more than a checkout.
- No platform migration; this is GitHub Actions.

## Open questions (slice 3)

- What triggers a release: a manually run workflow that bumps and tags from
  `main`, or automatic tagging on merge when `Unreleased` is non-empty?
- Where the appcast lives once it is no longer committed to `main`: a release
  asset served through the website build, or an `appcast` branch.
