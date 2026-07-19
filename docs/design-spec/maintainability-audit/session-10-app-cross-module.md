# Session 10: App + cross-module sweep + close-out

> Read [README.md](README.md) first. This session audits `App/`, then resolves
> every cross-module candidate deferred by Sessions 1 to 9, then writes the
> close-out. Do not start it until Sessions 1 to 9 are logged.

## Scope

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `App/` | 27 | ~3.5k | Composition root, scenes, commands, adapters. |
| Cross-module | -- | -- | Every ledger row marked `deferred`. |

Prereq: all prior sessions. Gate: `make build`, `make test-coverage`, and any
module gate a cross-module change touches; `make lint` module-wide.

## Part A -- App

- **Scene content.** `AppSceneContent.swift` window-content structs
  (`SettingsWindowContent`, `DSPWindowContent`, ...) follow one shape (per
  `App/CLAUDE.md`). Check for boilerplate a helper could carry -- but the
  type-checker constraint that each window be a concrete named `View` is
  deliberate; do not fold them into closures.
- **Commands.** After Phase 23 split `BocanCommands` into `+Tools`,
  `+CollectionViewMenu`, look for further cohesive groups repeating
  button/keyboard-shortcut/help shapes; extract only if it removes real
  duplication, honoring the bare-literal + no-new-catalog rule for `App/`.
- **Adapters.** The `Subsonic*` -> `UI.*` bridges follow one adapter shape;
  check for repeated forwarding boilerplate.

## Part B -- Cross-module sweep (the main event)

Resolve every `deferred` row. Expected clusters, from the seeding greps:

- **HTTP/JSON client.** Acoustics (S2), Scrobble (S4), and Subsonic (S5) each
  build requests + decode + map errors. Decide the one shared home that respects
  the DAG (a small client at/below the lowest consumer, or a shared protocol +
  per-module conformance). Apply the rubric: if the three genuinely differ in
  auth/shape, share only the skeleton. Record the decision even if the answer is
  "keep separate".
- **Formatters.** ~13 files scatter duration / byte-size / date formatting
  (`DateComponentsFormatter`, `ByteCountFormatter`, `%02d:%02d`). A shared
  formatting helper at a low module is a strong, safe consolidation. Watch for
  UI vs lower-module split (UI copy is localized; lower modules are not).
- **Offline/retry queues.** The Scrobble offline queue (S4) and the Podcasts
  download queue (S5) -- if near-identical, a shared queue is a candidate; if
  they differ in item type/retry policy, keep separate and record why.
- **Test scaffolding.** HTTP `URLProtocol` stubs (~7 test files) and image/
  fixture helpers -- consolidate shared test support (extending the `TestImage`
  precedent) without crossing module test-target boundaries incorrectly.
- **Logging shape.** The `log.debug("op.start") / "op.end"` timing pattern
  (~17 sites) -- consider a tiny `AppLogger` timing helper, or leave as
  idiomatic; measure.

## Part C -- Close-out (required deliverable)

Write `close-out.md` in this directory:

- Total net lines removed; counts of consolidated / tolerated / rejected /
  deferred-then-resolved.
- The final **shared-surface catalogue**: every helper the audit created or
  confirmed, and where it lives, so the next feature reuses instead of copies.
- The top 3 "rejected" decisions with their reasoning, as guidance for future
  contributors (and future AI sessions) on when *not* to consolidate.
- Any candidate intentionally left for later, with a reason.

## Exit criteria

- `App/` triaged; every `deferred` ledger row resolved (consolidated or
  kept-with-reason).
- `close-out.md` written; ledger running totals finalized.
- Full gate sweep green: `make lint`, `make build`, `make test-coverage`,
  `make test-ui`, and each module `make test-*` a change touched.
