# Phase 32: E2E Windows, Mini Players, and Settings

> Prerequisites: Phases 28-31. Everything outside the main window: the
> three mini player modes, full screen, the secondary windows, and a full
> settings crawl with persistence proof. This is where "going to main view
> mode, then the mini-players" from the original dream lives.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Every window the app can present is opened, exercised via its crawl table,
and closed; every settings control is toggled and proven to persist across
a relaunch.

## Non-goals

- Visualizer rendering content (phase 33 owns the modes' behavior; this
  phase only proves the visualizer window/pane opens and closes).

## Implementation plan

1. **Mini players.** From main view: toggle the mini player (⌘⌥M and the
   menu path), cycle all three modes (compact, square, visualizer), crawl
   each mode's table (transport controls, love, info where present),
   assert playback continues across mode switches, return to main window.
   The phase 27-5 radio behavior is asserted here too: with a fixture
   radio stream playing (phase 34's server, or a local file masquerading
   until then), titles render at full strength in each mode.
2. **Full screen.** Enter and exit on the main window; assert Esc exits
   full screen (the phase 378 precedence ladder's step 5) and that the
   navigation monitors do not swallow it.
3. **Secondary windows.** Library Summary (⌘⇧Y): open, walk all six tabs,
   click one representative reveal action, close. Log Console (⌘⇧L):
   open, filter, search, pause, copy, close. DSP window, Lyrics pane,
   playlist import/export sheets: open, crawl, dismiss.
4. **Settings crawl.** Every pane via the sidebar and via `SettingsRouter`
   deep links. Every non-destructive control: toggle or cycle it, assert
   the in-app effect where observable. **Persistence proof**: a chosen
   sample (one control per pane) is flipped, the app relaunched into the
   same fixture home, and the flipped value asserted; this catches the
   `@AppStorage` RawRepresentable propagation trap class permanently.
5. **Appearance controls.** Cycle every accent colour and light/dark/auto
   appearance from Settings; assert the selection persists and the main
   window remains responsive after each cycle. Screenshot artifacts are
   captured per accent for the nightly report (human review, no pixel
   assertions; the snapshot tier owns rendering).

## Test plan

- Full crawl green headed; mode-cycling under playback repeated 3 times
  in one run to smoke out ordering races.
- Persistence sample: relaunch assertions green for every pane.
- One deliberate persistence break (revert a `@AppStorage` fix locally)
  fails the sample (verified once, documented).

## Acceptance criteria

- [ ] All three mini player modes crawled with playback surviving.
- [ ] Esc-in-fullscreen exits full screen (permanent regression guard).
- [ ] Every settings pane crawled; every pane has a relaunch-persistence
      assertion.
- [ ] Every accent + appearance cycled without a hang or crash, with
      artifacts attached to the nightly report.

## Gotchas

- Mini player windows are `.commandsRemoved()` scenes; find them by
  window identifier, not by menu-derived titles.
- Settings is a separate scene; `openSettings()` timing needs a settle
  wait before pane navigation, and the router's persisted-request
  behavior means a stale deep link can fire on first open (assert and
  clear).
- Appearance switching invalidates Metal layers; the responsiveness
  assertion after each cycle is what would have caught a renderScale-type
  regression at the window level.

## Handoff

Phase 33 assumes mini player and window plumbing is stable so visualizer
mode cycling can be tested in both the main pane and the visualizer mini
player.
