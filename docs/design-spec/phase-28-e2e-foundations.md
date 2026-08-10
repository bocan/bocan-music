# Phase 28: E2E Foundations (Whole-App Testing)

> Prerequisites: Phases 0-27 complete. The `BocanUITests` XCUITest target
> exists (`UITests/SmokeTests.swift`, one launch test) and `A11y` identifiers
> already cover many controls. This phase opens the E2E programme (phases
> 28-35): a whole-app test tier whose dream state is every button clicked,
> every menu walked, every mode cycled, nightly, so no change breaks the app
> unseen for a month. Unit, snapshot, and source-convention tests stay the
> base of the pyramid; E2E is a smoke layer over real launch paths,
> persisted state, menus, and windows, the territory unit tests cannot reach
> (the phase 27 launch wedge is the canonical example).
>
> Read `docs/design-spec/_standards.md` first.

## Decisions binding on all E2E phases (agreed up front)

- **Two runner tiers.** A small smoke subset runs on GitHub-hosted macOS
  runners per push; the full crawl runs nightly on a self-hosted Mac runner
  with a real GPU (phase 35 owns the pipeline and its security model).
- **Hover text is audit-plus-spot-check.** Every interactive control must
  carry localized `.help()` text, enforced by audit (phase 29); physically
  hovering and reading rendered tooltips happens only for a small sample per
  surface (phase 31). Full hover-everything was rejected as unfixably flaky.
- **Hermetic network.** Nightly runs never touch the internet. Radio and
  podcasts get loopback fake servers (phase 34); Subsonic journeys stay at
  the unit tier for now.

## Constraints accepted (the honest list)

- **No audio audibility assertions.** Tests assert engine and UI state
  (playing indicator, advancing clock), not sound from speakers. A loopback
  audio-capture driver is a possible future, not in scope.
- **No pixel assertions in E2E.** Rendering correctness belongs to the
  existing offscreen snapshot tier. E2E captures screenshots as run
  artifacts for human eyes, never as pass/fail.
- **Sparkle's update flow stays untested** end to end (it needs a signed
  feed and an installed copy); the appcast contract is covered by unit
  tests and the drift/appcast checks.
- **OS-owned panels (open/save) are minimized**, not crawled: fixture mode
  avoids them; where unavoidable they are driven via Go-to-Folder typing.

## Goal

A fixture launch mode inside the app, a test harness with page-object
conventions, a `make test-e2e` target, and the first three journeys, one of
which is the phase 27 launch-wedge regression.

## Non-goals

- Identifier completeness (phase 29), menu crawling (30), surface crawling
  (31), windows/settings (32), visualizers (33), fake servers (34), and the
  nightly pipeline (35).

## Implementation plan

1. **Fixture launch mode (App + modules).** The app honors a
   `BOCAN_E2E_HOME` launch-environment variable: when set, every persistent
   path (Application Support, the GRDB database, caches, UserDefaults via a
   suite name) roots under that directory instead of the real ones. Also
   under the flag: Sparkle checks disabled, first-run prompts skipped,
   SwiftUI/NSAnimation animations minimized. Wire through the existing
   composition root; no module may read the variable directly except via a
   single `E2EEnvironment` helper in `App/`.
2. **Fixture library.** A `UITests/Fixtures/` seed: half a dozen tiny audio
   files (reuse the AudioEngine test fixtures), one playlist, pre-seeded
   database built by launching the scanner against the seed folder on first
   run of the harness (not checked-in binary DB, so schema migrations stay
   exercised).
3. **Harness conventions (UITests/Support/).** A `BocanRun` launcher
   (fresh temp home per test by default, opt-in shared home for journey
   chains), page objects per surface (`SidebarScreen`, `TransportScreen`,
   `RadioScreen`...) exposing typed accessors over `A11y` identifiers, and
   a `waitForPlayback()` helper asserting the strip's time advances.
4. **`make test-e2e`** running `xcodebuild test -only-testing:BocanUITests`
   with the standard destination; excluded from `make test` and CI's normal
   pipeline.
5. **First journeys** in `UITests/Journeys/`:
   - Cold launch to first window (replaces the current smoke test).
   - Play-a-track: select the seeded library, double-click a row, assert
     playing state and advancing time, pause, assert paused.
   - **Launch-wedge regression**: seed a persisted queue whose current item
     is `.internetRadio` plus a stale resume position, relaunch, assert a
     local track plays within 10 seconds (guards the phase 27 hang class).

## Test plan

The phase's deliverable is tests; the meta-test is `make test-e2e` running
all three journeys green, twice consecutively, on a developer Mac.

## Acceptance criteria

- [ ] `BOCAN_E2E_HOME` fully isolates app state (nothing written outside it
      during a run; assert by scanning the real Application Support mtime).
- [ ] Fixture seeding produces a deterministic library (same track count
      every run).
- [ ] All three journeys pass headed and via `make test-e2e`.
- [ ] Normal `make test` / CI timing is unchanged (E2E fully opt-in).

## Gotchas

- XCUITest launches the app fresh per `XCUIApplication.launch()`; harness
  must pass the environment on every launch, including mid-test relaunches.
- UserDefaults isolation needs a suite name override, not just a home
  directory, or the real defaults leak in.
- The single-instance guard (`SingleInstance.swift`) must not treat the
  test copy and a developer's running copy as duplicates: gate it off under
  the flag.

## Handoff

Phase 29 assumes: page-object pattern established, fixture mode stable, and
`make test-e2e` as the runner for every later phase's suites.
