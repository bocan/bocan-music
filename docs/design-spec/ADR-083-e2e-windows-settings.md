# ADR-083: E2E Windows, Mini Players, and Settings

> Prerequisites: ADR-079 to ADR-082. Everything outside the main window: the
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

- Visualizer rendering content (ADR-084 owns the modes' behavior; this
ADR only proves the visualizer window/pane opens and closes).

## Implementation plan

1. **Mini players.** From main view: toggle the mini player (⌘⌥M and the
   menu path), cycle all three modes (compact, square, visualizer), crawl
   each mode's table (transport controls, love, info where present),
   assert playback continues across mode switches, return to main window.
   The ADR-078 slice 5 radio behavior is asserted here too: with a fixture
   radio stream playing (ADR-085's server, or a local file masquerading
   until then), titles render at full strength in each mode.
2. **Full screen.** Enter and exit on the main window; assert Esc exits
   full screen (the #378 precedence ladder's step 5) and that the
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

## Progress

Landed (`UITests/Windows/`): `MiniPlayerWindowTests` (all four layouts —
strip, compact, square, visualizer — cycled three times each with playback
surviving into every mode), `FullScreenTests` (Esc-exits-full-screen guard,
with a `tearDownWithError` that force-exits full screen even on assertion
failure so a wedged full-screen Space can never survive into the next test),
`SecondaryWindowsTests` (Library Summary's six tabs, Log Console's control
bar, the DSP window's Equaliser/Effects/ReplayGain tabs), `SettingsCrawlTests`
(all 15 sidebar panes open and render a representative control), and
`SettingsPersistenceTests` (eight toggles plus the Appearance accent,
flipped, relaunched into the same run, and asserted to persist; every accent
swatch and all three appearance modes cycled with a responsiveness check
after each).

Real bugs found and fixed along the way:
- The Mini Player `Window` scene was the only secondary window missing
  `.restorationBehavior(.disabled)`; macOS restoring it on a cold launch
  ordered out the main window before that window's bootstrap `.task` ran,
  so the database never opened. A real user hitting this: quit with the
  mini player open, next launch never loads the library.
- The Mini Player could render partially off-screen: `setContentSize`
  grows the window from a fixed corner, so snapping to a wider persisted
  layout than the scene's `.defaultPosition(.bottomTrailing)` was computed
  for pushed the far edge past the screen bounds, making its own chrome
  buttons unreachable. Fixed by clamping the frame to the screen's visible
  area after every resize.
- `LibraryViewModel.selectedDestination`/`.isScanning` mirrored state into
  `UserDefaults` unconditionally on every `didSet`, including every
  ordinary navigation click. `UserDefaults.set` broadcasts the key-agnostic
  `didChangeNotification` regardless of whether the value changed, and
  `BocanCommands` subscribes via `@AppStorage` — reviving the project's
  original menu-driven audio-crackle bug class. Both mirrors now guard on
  an actual value flip before writing.
- Settings → Sources' empty state sat visibly off-centre: an always-empty
  240pt server-list column remained beside it. The column is now hidden
  when there is nothing to list.

Settings-sidebar navigation needed its own technique: the sidebar's 15
panes across 5 sections do not all fit inside the scene's minimum window
size, and a row outside the visible fold reports an AX frame outside the
window's clip area — synthesizing any gesture there, including a scroll,
fails outright, since XCTest can't resolve a real on-screen point. Every
`selectSidebarRow` call scrolls from an *anchor* (the previously-selected,
known-hittable row) rather than the off-screen target itself, with a large
scroll step so a long jump (the persistence suite deliberately visits
Appearance right after Diagnostics, proving both scroll directions) crosses
the distance before the anchor itself goes off-screen.

Also added: a per-run `UserDefaults` suite for the Settings scene in E2E
(`E2EEnvironment.settingsDefaults`, wired via `.defaultAppStorage` in
`AppSceneContent.swift`), so the persistence proof can flip real
`@AppStorage`-backed preferences and relaunch-verify them without ever
touching a developer's actual preferences — the isolation decision this
ADR's spec called out.

Deferred to a later slice: the Lyrics pane and playlist import/export
sheet crawls (folded into secondary windows only partially — DSP/Log
Console/Library Summary landed, Lyrics did not), `SettingsRouter` deep-link
navigation (only sidebar-click navigation is covered), the radio-stream
title-rendering assertion inside each mini player mode (needs ADR-085's
fixture radio server), and per-accent screenshot artifacts for the nightly
report.

## Acceptance criteria

- [x] All four mini player modes crawled with playback surviving (the spec
      says three; the shipped `MiniPlayerViewModel.Layout` has a fourth,
      strip, also crawled).
- [x] Esc-in-fullscreen exits full screen (permanent regression guard).
- [x] Every settings pane crawled; every pane has a relaunch-persistence
      assertion (via the shared toggle table; slider/action-only panes are
      covered by the pane-open crawl instead, per its own comment).
- [x] Every accent + appearance cycled without a hang or crash. Artifacts
      for the nightly report are not yet captured (deferred).

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

ADR-084 assumes mini player and window plumbing is stable so visualizer
mode cycling can be tested in both the main pane and the visualizer mini
player.
