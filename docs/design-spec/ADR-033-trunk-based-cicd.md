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
   Debug build. The pull request runs the full test and coverage suite. Pushes to `main` trigger no build at all: with branch protection
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
| `branch.yml` | push to any branch except `main` | gitleaks on `origin/main..HEAD` (Linux, parallel); lint + format-check + `make build` (macOS) | done, slice 1 (#427) |
| `pr.yml` | pull request to `main` | `changes` job diffs the PR; docs-only PRs skip the rest. Otherwise the full suite: `make test-coverage` + SPM package tests | done, slice 2 |
| `pr-metadata.yml` | pull request opened/edited/synchronize/labeled | Conventional Commit title check; `feat`/`fix`/`perf` must add a line under `## [Unreleased]` in `CHANGELOG.md` unless labelled `skip-changelog` | done, slice 2 |
| Snyk (GitHub app, no file) | pull request | dependency manifest scan | existing, keep |
| `release.yml` | manual only (`workflow_dispatch`, optional `tag` to rebuild) | `prepare` (Linux): `Scripts/release.sh` decides the version and rewrites `CHANGELOG.md` + `Info.plist`, lands them as a `chore(release): X.Y.Z` PR through the normal checks, tags the merge. `build` (macOS): tests, sign, notarize, DMG, build-provenance attestation of the DMG, GitHub release with prose-only notes, `appcast-entry.xml` asset, cask dispatch | done, slice 3 |
| `website.yml` | push to `main` touching `website/**` or `CHANGELOG.md`, after a Release run | `Scripts/build-appcast.sh` assembles the Sparkle feeds from `website/appcast/seed*.xml` plus every later release's asset; Eleventy build; Pages deploy | reworked, slice 3 |
| `dependency-drift.yml` | weekly cron | pin drift report as an issue | existing, keep |

Changes touching only `**.md`, `docs/**` or `website/**` skip the build workflows (`branch.yml` via `paths-ignore`; `pr.yml` via its `changes` job, because a required check that never starts would block the PR).

## Guardrails

| Mistake | What stops it |
|---|---|
| Committing on `main` | `CLAUDE.md` rule; branch protection on `main` (required checks: Build & Test, Conventional Commit title, Release note in CHANGELOG Unreleased) |
| Pushing a secret | gitleaks in the pre-commit hook (per clone, `make install-hooks`) and in `branch.yml` (authoritative) |
| Breaking the build and not noticing until the PR | `make build` on every branch push |
| Bad squash commit subject, so the wrong version bump | `pr-metadata.yml` title check, re-run on every title edit |
| Blank or prose-less release notes | `pr-metadata.yml` changelog check: a `feat`/`fix`/`perf` PR must add to `## [Unreleased]` or carry `skip-changelog`; `release.sh apply` and `release-notes.sh` both refuse an empty section |
| Release notes written as commit messages | the same check rejects backticks, `(#NNN)` and code vocabulary in the added lines |
| Releasing an unmerged or untested commit | releases cut from `main` only, which only holds PR-checked commits; the release commit itself goes through the same PR checks |
| Typing the wrong version, or releasing when nothing changed | `release.sh next` computes it from the squash subjects and exits 3 when nothing is releasable |
| Appcast pointing at the wrong OS floor, or shrinking | `build-appcast.sh` refuses an entry whose `minimumSystemVersion` disagrees with `project.yml`, and refuses fewer items than the seed |
| CI committing to `main` | nothing does any more: the release commit is a PR, the appcast is assembled at site build time |

## Secrets

| Secret | Used by |
|---|---|
| `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` | `release.yml`: signing and notarization |
| `SPARKLE_ED_PRIVATE_KEY` | `release.yml`: appcast entry signature |
| `HOMEBREW_TAP_TOKEN` | `release.yml`: `repository_dispatch` to `bocan/homebrew-bocan` |
| `ACOUSTID_API_KEY`, `BOCAN_LASTFM_API_KEY`, `BOCAN_LASTFM_SHARED_SECRET`, `PODCAST_INDEX_API_KEY`, `PODCAST_INDEX_API_SECRET` | `release.yml` (baked into the shipped build); `pr.yml` for the test build |
| `GITHUB_TOKEN` (default) | everything else |

`branch.yml` uses none of them.

## Migration

Each slice is one branch and one PR.

1. **Branch CI** (#427, merged 2026-08-30): `branch.yml`, gitleaks in Brewfile and hook,
   `CLAUDE.md` branching rule, this ADR rewritten. GitHub set to squash-only.
2. **PR CI** (#428, merged 2026-08-30, after #429 made the suite honest):
   `pr.yml` replaces `ci.yml`; `pr-metadata.yml` added; `codeql.yml` deleted;
   `## [Unreleased]` added to `CHANGELOG.md`; `skip-changelog` label created.
   Branch protection on `main` enabled the same day: PR required, the three
   checks required (strict), admins included, no force pushes, linear
   history. `Build & Test` counts as passed when skipped for docs-only PRs.
3. **Release** (this PR): `Scripts/release.sh` (+ tests under `Scripts/tests`,
   run by `pr.yml`'s `Script tests` job and `make test-scripts`),
   `Scripts/release-notes.sh` reduced to the prose, `Scripts/build-appcast.sh`,
   `release.yml` rewritten as above, the committed feeds frozen as
   `website/appcast/seed*.xml`, `pr-metadata.yml` rejects techno-speak in the
   note, `make release-preview`. Deleted: `release-please.yml`,
   `release-please-config.json`, `.release-please-manifest.json`,
   `Scripts/release-note.sh`, `make release-note`. After merging: add the
   `RELEASE_TOKEN` secret and close the bot's last open release PR.
4. **Docs** (this PR): `DEVELOPMENT.md` "Releasing", `CLAUDE.md` release-note
   rules, this ADR. `CONTRIBUTING.md` was updated in slice 2.

## Not doing

- No beta/nightly channel automation, release trains, delta updates, or
  release dashboards.
- No composite actions or reusable workflows until two workflows genuinely
  share more than a checkout.
- No CodeQL. Swift support is a GitHub preview, it cost 17 minutes per PR,
  and its build step had been silently failing (see the 2026-08-30 note
  below). Snyk covers dependency CVEs. Removed 2026-08-30.
- No platform migration; this is GitHub Actions.

## Note (2026-08-30): the Xcode test suite had not run in CI since 2 June

`4de9bec6` gave the Debug config `DEVELOPMENT_TEAM` + automatic signing and
`8166fd01` removed CI's `XCB_OVERRIDE` the same day; from the next run on,
`make test-coverage` failed on the certificate-less runner with exit 65 and
"Executed 0 tests". It reported green because `make test-coverage | xcbeautify`
ran without `pipefail`, so xcbeautify's exit 0 won. `release.yml`'s "run tests
before release" step has the same mask, and the Makefile `build` recipe pipes
into xcbeautify without `set -o pipefail` at all, so `make build` cannot fail
anywhere. Only the SPM package suites were real. Fixed in #429 (2026-08-30):
`pipefail` everywhere, CI builds ad-hoc signed with no team via
`XCB_OVERRIDE` as it did before June, Xcode pinned to 26.6, and an explicit
`Sendable` on the E2E menu manifest types whose recursive inference resolved
differently on the runner. The first honest run: 811 tests, 95% coverage.

## Release decisions (2026-08-30, slice 3)

7. **A release is started by hand, never by a merge.** The maintainer ships
   at most about once a week because updates tire users; `Unreleased`
   accumulates zero to ten PRs in between. `workflow_dispatch` with no input
   cuts the next version; with a tag input it rebuilds that tag.
8. **The version comes from the squash subjects since the last tag**, first
   parent only: `!`/`BREAKING CHANGE` major, `feat` minor, `fix`/`perf`
   patch, nothing else releasable. Nobody types a version.
9. **Two audiences, one file.** Each `CHANGELOG.md` version section is the
   maintainer's prose (from `Unreleased`) followed by a generated
   `### For developers` list of the squash subjects grouped Added / Fixed /
   Changed / Removed with PR links. The GitHub release body and the Sparkle
   prompt carry the prose only, plus a "Full changelog" compare link.
10. **The release commit lands through the same protected PR as any change**,
    auto-merged by the workflow once its checks pass (fully automated to
    start with; switching to a maintainer-merged release PR is a one-line
    change if the assembled notes need a last look). It needs a fine-scoped
    PAT (`RELEASE_TOKEN`) because a `GITHUB_TOKEN`-opened PR gets no checks.
11. **The appcast is derived, not committed.** Every release uploads its
    signed `appcast-entry.xml`; the website build appends the entries newer
    than the frozen seed (`website/appcast/seed.xml`, the history up to
    2.11.0, kept because older assets carry a wrong `26.0` OS floor) and
    refuses to publish if any entry's floor disagrees with `project.yml` or
    the feed would shrink. There is no `gh-pages` branch (Pages deploys an
    artifact), so "an appcast branch" was never needed.
12. **A hand-rolled `Scripts/release.sh` rather than release-please or
    git-cliff.** The bump is a `git log` and a `case`; the bullets are the
    subjects. Eighty readable lines with a fixture-repo test beat a bot branch
    or a template DSL for a solo maintainer.
