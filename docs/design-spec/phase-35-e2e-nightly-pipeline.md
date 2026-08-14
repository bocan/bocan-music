# Phase 35: E2E Local Pre-Release Checks (CI Deferred)

> Prerequisites: Phases 28-34 (any subset already landed benefits
> immediately; this phase can start once 28 exists and grow).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A fast, curated local subset of the E2E suite for a quick pre-release
sanity check, sitting alongside the full `make test-e2e` board from phase
34.

## Status: CI scope dropped

The original plan for this phase was a two-tier GitHub Actions pipeline: a
per-push smoke workflow on GitHub-hosted runners, and a nightly full crawl
on a self-hosted Mac with a real GPU, complete with a security model for
the self-hosted runner and self-filing failure issues. As of 2026-08-15
the decision is to run no automated tests on GitHub for this repo yet, and
no self-hosted runner exists. That drops the CI-dependent items entirely:

- Two GitHub Actions workflows (`e2e-smoke.yml`, `e2e-nightly.yml`).
- Self-hosted runner provisioning and its five mandatory security
  mitigations (label scoping, `pull_request` exclusion, outside-collaborator
  approval, dedicated unprivileged login, schedule/dispatch-only triggers).
- Self-filing "Nightly E2E failures" issue automation.
- The flake ledger (`UITests/QUARANTINE.md`) as originally specified: it
  existed to keep a nightly report honest about what it silently excludes,
  which has no referent without a nightly run.

Revisit all of the above if/when a self-hosted runner and a decision to
run GitHub Actions on this repo both exist. Nothing here precludes that
later; the tagging/subset split below is the same shape it would need.

## What shipped instead

`make test-e2e` (phase 34) already runs the full `BocanUITests` board
locally. The one piece of the original plan with standalone value for
local pre-release checks — a fast curated subset distinct from the full
1-3 hour board — is `make test-e2e-smoke`.

Rather than Xcode `.xctestplan` files (the original mechanism, chosen for
CI tag-based scheduling that no longer applies), the smoke subset is a
plain `-only-testing:` filter list in the `Makefile`, matching the same
mechanism `test` and `test-coverage` already use to exclude `BocanUITests`.
This avoids coupling to the generated `Bocan.xcodeproj` target UUIDs that
a checked-in `.xctestplan` would require, and needs no `make generate`
round-trip to keep in sync.

The smoke subset: `FoundationJourneys` (phase 28 journeys), the menu
structural crawl (`MenuCrawlTests/testMenuBarMatchesManifest`), one
surface (`ToolbarSurfaceTests/testToolbarSurface`), and one radio journey
(`RadioStreamJourneyTests/testAddByURLPlaysAndShowsScriptedTitle`). It
deliberately excludes the reconnect pair (the phase 34 flake watch, slow
by design) and hover tooltip checks (quarantinable, not a smoke concern).

## Acceptance criteria

- [x] `make test-e2e-smoke` runs a curated subset locally, distinct from
      the full `make test-e2e` board.
- [x] Smoke subset timing verified under 10 minutes on real hardware: 6
      tests, ~2.5 minutes wall clock on 2026-08-15.
- Dropped, CI-dependent (see above): GitHub Actions workflows, self-hosted
  runner + security model, self-filing failure issues, nightly-report-tied
  flake ledger.

## Handoff

If GitHub Actions automation is wanted later, the smoke/full split here
carries forward directly: `e2e-smoke.yml` runs `make test-e2e-smoke` on
`macos-latest`, and a future self-hosted nightly runs `make test-e2e`.
The security model and self-filing issue automation from the original
plan are still the right design when that day comes; they were dropped
for being inapplicable now, not for being wrong.
