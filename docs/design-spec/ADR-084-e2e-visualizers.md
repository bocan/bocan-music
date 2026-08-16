# ADR-084: E2E Visualizer and Appearance Cycling (GPU Tier)

> Prerequisites: ADR-079 to ADR-083; the self-hosted GPU runner from ADR-086's
> setup (this ADR's suites are the reason that runner exists; they run
> degraded on GitHub-hosted software rendering). "Cycling through the
> visualizers, cycling through each colour mode" from the dream lives
> here, with honest limits: E2E asserts behavior and liveness, never
> pixels; the offscreen Metal snapshot tier owns rendering correctness.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

During real playback, every visualizer mode is cycled in every palette, in
the main pane, the visualizer mini player, and full screen, with liveness
(frames actually rendering) asserted and screenshots captured as nightly
artifacts.

## Non-goals

- Pixel or perceptual assertions of rendered output (snapshot tier).
- Performance benchmarking (a frame-rate floor is asserted, not a target).

## Implementation plan

1. **Liveness signal.** Under the E2E flag, the existing
   `FrameRateMonitor` exposes its rolling FPS through the visualizer
   view's accessibility value. The suite's core assertion becomes: after
   selecting a mode and waiting 2 seconds, FPS > 10 and still > 10 five
   seconds later. This converts "did the Metal pipeline actually draw"
   from a screenshot guess into a readable number, and it is exactly the
   assertion that catches the renderScale/1x1-drawable class of bug.
2. **The cycle matrix.** For each visualizer mode (Canvas and Metal
   variants alike) x each palette: select via the visualizer settings
   surface, assert liveness, capture one screenshot artifact, move on.
   Then repeat a reduced matrix (each mode once, default palette) inside
   the visualizer mini player and in full screen.
3. **Transition torture, briefly.** One test cycles all modes as fast as
   the UI allows, twice, then asserts liveness and that playback never
   stopped: mode-switch teardown races are historically where visualizer
   crashes live.
4. **Appearance interaction.** With a Metal mode live, switch light/dark
   and two accents (ADR-083 owns the full accent cycle); assert liveness
   after each switch.
5. **Tier behavior.** On the GPU runner the full matrix runs. On
   GitHub-hosted runners only a single mode's liveness smoke runs, tagged
   `.tags(.gpu)` for the rest, since software rendering makes FPS floors
   meaningless there.

## Test plan

- Full matrix green on the GPU runner three nights running before the
  ADR is called done (flake rate is the real acceptance metric here).
- Artifact review: one screenshot per mode/palette lands in the nightly
  report, named `visualizer-<mode>-<palette>.png`.

## Acceptance criteria

- [x] Every mode x palette combination cycled with the FPS floor met
      (`testMainPaneModeAndPaletteMatrix`, `UITests/Visualizers/VisualizerLivenessTests.swift`).
- [x] Mini player and full screen reduced matrices green
      (`testMiniPlayerModeMatrix`, `testFullScreenModeMatrix`).
- [x] Rapid-cycling torture test green with playback surviving
      (`testRapidModeCyclingSurvivesPlayback`).
- [x] Appearance interaction test green with a Metal mode live
      (`testAppearanceSwitchWhileMetalModeLive`).
- [ ] GitHub tier runs only the tagged smoke subset. Not implemented: this
      harness is plain XCTest with no GPU/GitHub tier split or `.tags(.gpu)`
      mechanism yet. All five tests currently run together, untagged, on
      whatever machine invokes `make test` (or a direct `xcodebuild test`
      filter) — no nightly-only or CI-gated scheduling exists. Screenshot
      artifact capture (`visualizer-<mode>-<palette>.png` per the test plan)
      is also not implemented; the suite asserts liveness only.

## Gotchas

- The FPS accessibility value must be E2E-flag-gated; shipping it always-on
  would leak an internal metric into every user's accessibility tree.
- All modes run at renderScale 1.0 by project decision (the Metal
  renderScale trap); if that ever changes, the liveness floor is the test
  that pages someone.
- Full-screen visualizer owns its own window and its own Esc handling;
  the suite must not inherit #378's drill-out monitor assumptions
  there (different window, monitor correctly ignores it).

## Handoff

ADR-085 can play its fixture radio stream under any visualizer knowing
mode cycling is safe; ADR-086 schedules this suite GPU-tier-only.
