# ADR-079: E2E Foundations (Whole-App Testing)

> Prerequisites: ADR-001 to ADR-078 complete. The `BocanUITests` XCUITest target
> exists (`UITests/SmokeTests.swift`, one launch test) and `A11y` identifiers
> already cover many controls. This ADR opens the E2E programme (ADR-079 to
> ADR-086): a whole-app test tier whose dream state is every button clicked,
> every menu walked, every mode cycled, nightly, so no change breaks the app
> unseen for a month. Unit, snapshot, and source-convention tests stay the
> base of the pyramid; E2E is a smoke layer over real launch paths,
> persisted state, menus, and windows, the territory unit tests cannot reach
> (the ADR-078 launch wedge is the canonical example).
>
> Read `docs/design-spec/_standards.md` first.

## Decisions binding on all E2E ADRs (agreed up front)

- **Two runner tiers.** A small smoke subset runs on GitHub-hosted macOS
  runners per push; the full crawl runs nightly on a self-hosted Mac runner
  with a real GPU (ADR-086 owns the pipeline and its security model).
- **Hover text is audit-plus-spot-check.** Every interactive control must
  carry localized `.help()` text, enforced by audit (ADR-080); physically
  hovering and reading rendered tooltips happens only for a small sample per
  surface (ADR-082). Full hover-everything was rejected as unfixably flaky.
- **Hermetic network.** Nightly runs never touch the internet. Radio and
  podcasts get loopback fake servers (ADR-085); Subsonic journeys stay at
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
which is the ADR-078 launch-wedge regression.

## Non-goals

- Identifier completeness (ADR-080), menu crawling (30), surface crawling
  (31), windows/settings (32), visualizers (33), fake servers (34), and the
  nightly pipeline (35).

## Implementation plan

1. **Fixture launch mode (App + modules).** The app honors a
   `BOCAN_E2E_RUN=<id>` launch-environment variable: when set, the GRDB
   database roots under a per-run home the *app itself* creates at
   `<container>/tmp/bocan-e2e/<id>/`, and the single-instance guard is
   off. The contract is an identifier, not a path, because neither side
   can cross the sandbox wall: macOS app-container protection denies the
   runner writes (or unattended reads) inside the app's container, and
   the sandbox denies the app arbitrary outside paths. Sparkle needs no
   gating (Debug builds never start the updater). UserDefaults are *not*
   re-rooted in this ADR: injection uses read-only argument-domain
   overrides (`-key value` launch arguments), and module-level
   `UserDefaults.standard` writes remain a known, accepted leak until the
   ADR-083 suite/`defaultAppStorage` decision. No file reads the
   variables except the single `E2EEnvironment` helper in `App/`.
2. **Fixture library (`App/E2ESeeder.swift`).** On an E2E launch, before
   the database opens, the app sweeps stale sibling run homes (the runner
   cannot delete them either) and synthesizes its own fixture library:
   two 60-second quiet sine-tone WAVs (long enough that transport
   assertions never race track end), tagged through the real `TagWriter`.
   The seed folder is added as a library root through
   `LibraryViewModel.addURLs` (no `NSOpenPanel`), so scanning runs for
   real; `BOCAN_E2E_SEED_RADIO_URL` additionally seeds a one-item
   internet-radio queue for the wedge journey. A playlist fixture is
   deferred to the ADR that first needs one.
3. **Harness conventions (UITests/Support/).** An `E2ESession` (mints the
   run identifier, reused across relaunches within a journey), a
   `StallingListener` (loopback-only TCP, accepts then never responds;
   all-interfaces binding would trip the local-network consent prompt)
   standing in for a dead radio server, and `XCUIApplication` helpers
   (`waitUntilPlaying` keyed off the play/pause button's state-mirroring
   accessibility label, `waitForTrackRows` keyed off the deterministic
   fixture title). Full page-object surfaces arrive with the ADR-080
   identifier audit; the strip's time label has no identifier yet, so
   "advancing time" is asserted indirectly until then.
4. **`make test-e2e`** running `xcodebuild test -only-testing:BocanUITests`
   with the standard destination; excluded from `make test` and CI's normal
   pipeline.
5. **First journeys** in `UITests/Journeys/`:
   - Cold launch to first window (replaces the current smoke test).
   - Play-a-track: select the seeded library, double-click a row, assert
     playing state and advancing time, pause, assert paused.
   - **Launch-wedge regression**: seed a persisted queue whose current item
     is `.internetRadio` plus a stale resume position, relaunch, assert a
     local track plays within 10 seconds (guards the ADR-078 hang class).

## Test plan

This ADR's deliverable is tests; the meta-test is `make test-e2e` running
all three journeys green, twice consecutively, on a developer Mac.

## Acceptance criteria

- [ ] `BOCAN_E2E_RUN` isolates all file-backed app state. This is
      structural, not snapshot-asserted: the runner cannot read inside the
      app's container (any `open(2)` there parks on an unattended TCC
      consent; only `stat` succeeds), and every E2E path in the app keys
      off the same activation check, so a broken re-root also disables
      seeding and fails journey 1 at the track-rows wait. UserDefaults are
      exempt in this ADR (see plan item 1).
- [ ] Fixture seeding produces a deterministic library (same track count
      every run).
- [ ] All three journeys pass headed and via `make test-e2e`.
- [ ] Normal `make test` / CI timing is unchanged (E2E fully opt-in).

## Gotchas

- XCUITest launches the app fresh per `XCUIApplication.launch()`; harness
  must pass the environment on every launch, including mid-test relaunches.
- UserDefaults isolation needs a suite name override, not just a home
  directory, or the real defaults leak in. Deferred to ADR-083; until
  then E2E runs share the real defaults domain (read and write).
- The queue save is debounced by 2 s; a journey that terminates the app
  right after seeding must outlive the debounce or launch #2 restores an
  empty queue and passes vacuously. Journeys assert non-vacuity (the
  restored radio item must be visible) rather than trusting timing.
- The single-instance guard (`SingleInstance.swift`) must not treat the
  test copy and a developer's running copy as duplicates: gate it off under
  the flag.

## Handoff

ADR-080 assumes: page-object pattern established, fixture mode stable, and
`make test-e2e` as the runner for every later ADR's suites.
