# ADR-089: Immersive Mode

> Depends on: ADR-015 (lyrics pane), ADR-016 and ADR-017 (visualizers and the Drift palette), ADR-022 and ADR-028 (Metal host, the renderScale rule), ADR-080 (identifier coverage), ADR-082 and ADR-083 (surface and window crawls), ADR-084 (E2E visualizer liveness).
> Binding docs: `_standards.md`; `localization.md`; the accessibility and testing sections of the root `CLAUDE.md`.
> Requested by the maintainer, 2026-09-04.

## Goal

Give the app a chrome-free now-playing window called **Immersive Mode**: a hidden-title-bar window, like the fullscreen visualizer, showing a compact cluster of three cards at the centre of an Oscilloscope visualizer running in the Drift palette:

| Column | Content |
|---|---|
| 1, leading | Artwork, song title, artist, album, and the player controls under everything else |
| 2, middle | The play queue (Up Next), live and reorderable |
| 3, trailing | Lyrics, synced when available, with the sync-offset control |

The window carries no toolbar, sidebar or transport strip. The player controls (scrubber with times, previous, play or pause, next, shuffle, repeat, stop after current, volume and mute; skip back and forward for a podcast) sit at the foot of column 1 and drive the same view model as the strip. Playback, queue edits, and lyrics behave exactly as they do in the normal window; Immersive Mode is a different arrangement of views the app already has, not a new player.

Two rules carry the design:

1. **Reuse, do not fork.** The columns are built from `QueueView`, `LyricsView` and `NowPlayingViewModel`. No second queue model, no second lyrics model, no copied transport.
2. **Nothing global changes.** Entering Immersive Mode does not rewrite the user's saved visualizer mode or palette, does not touch the lyrics or visualizer pane preferences, and leaves every other window alone.

## Non-goals

- **An in-window overlay.** The first cut laid Immersive Mode over the main window's content. It could never hide that window's own chrome: the toolbar stayed, and the split view's sidebar header sat visibly above the overlay. "Immersive" means no chrome, so Immersive Mode is its own hidden-title-bar `Window` scene, exactly like the fullscreen visualizer: restoration disabled, `.commandsRemoved()`, content through `GraphContent`, `Esc` closes it, and the traffic lights let it go to system full screen. The main window stays behind it.
- **A user-selectable visualizer for this surface.** Version one is fixed at Oscilloscope and Drift by requirement. The per-surface override built for it makes a later setting a small change (see Handoff).
- **Transport redesign.** The column 1 controls reuse `MiniPlayerTransport` (the podcast-aware row the mini player already has) plus a scrubber and a volume control modelled on the strip's. No new transport behaviour. The strip-only extras (love, sleep timer, playback speed, DSP, the pending-scrobble badge) are not duplicated; leaving Immersive Mode reaches them (see Handoff).
- **Responsive collapse.** Below a sensible minimum width the columns squeeze; they do not restack. The main window already has a minimum size.
- **Podcast chapters or show notes columns.** For podcasts the three columns show artwork and episode metadata, the queue, and the lyrics empty state. Chapters stay in the strip.
- **Mini player changes.** The mini player is unchanged. Toggling it while immersive orders the main window out as today; the immersive state persists behind it.

## Outcome shape

New files, all in the `UI` module unless stated:

| File | Purpose |
|---|---|
| `Modules/UI/Sources/UI/Immersive/ImmersiveView.swift` | The overlay: full-window `VisualizerHost` plus the three columns. |
| `Modules/UI/Sources/UI/Immersive/ImmersiveNowPlayingColumn.swift` | Column 1: artwork, text, and the transport at the foot. |
| `Modules/UI/Sources/UI/Immersive/ImmersiveTransport.swift` | The column 1 player controls: scrubber with times, the shared transport row, volume and mute. |
| `Modules/UI/Sources/UI/Immersive/ImmersivePanel.swift` | The card container modifier shared by the three columns. |
| `Modules/UI/Sources/UI/Immersive/ImmersiveWindowView.swift` | The window content: `ImmersiveView` edge to edge, Esc closes, mirrors the open flag. |
| `App/BocanApp.swift`, `App/AppSceneContent.swift` | The `immersive` hidden-title-bar scene and its `GraphContent` wrapper. |
| `Modules/UI/Sources/UI/Lyrics/LyricsOffsetControl.swift` | The offset popover extracted from `LyricsPane`, so both the pane and column 3 use one control. |
| `Modules/UI/Sources/UI/Visualizers/VisualizerLivenessReadout.swift` | The zero-size accessibility readouts extracted from `VisualizerControlOverlay`, so a surface can be E2E-observable without the control chrome. |
| `Modules/UI/Tests/UITests/SnapshotTests/SnapshotTests+Immersive.swift` | Light and dark snapshots. |
| `Modules/UI/Tests/UITests/ViewModelTests/VisualizerHostOverrideTests.swift` | Renderer-key tests for the per-surface override. |
| `UITests/Windows/ImmersiveModeTests.swift` | E2E: enter, exit by Esc, exit by menu, Esc precedence with full screen. |

Changed files:

| File | Change |
|---|---|
| `Modules/UI/Sources/UI/Visualizers/VisualizerHost.swift` | Optional `mode` and `palette` overrides on `init`; `rendererKey` uses the effective values. |
| `Modules/UI/Sources/UI/Visualizers/VisualizerControlOverlay.swift` | Uses `VisualizerLivenessReadout` instead of inline readouts. |
| `Modules/UI/Sources/UI/Lyrics/LyricsPane.swift` | Uses `LyricsOffsetControl`. |
| `Modules/UI/Sources/UI/MiniPlayer/MiniPlayerTransport.swift` | Optional per-control accessibility identifiers and a `.navigation` layout (previous, play, next, shuffle, repeat, stop; no info button). The mini player passes neither and is unchanged. |
| `Modules/UI/Sources/UI/AppRoot/RootView.swift` | Reads the mirror for the toolbar label, opens or dismisses the window from the toolbar, and reopens it after bootstrap when it was left open. |
| `Modules/UI/Sources/UI/AppRoot/MainToolbarItems.swift` (new) | The main toolbar group, extracted from `RootView` to make room; gains the Immersive Mode toggle. |
| `Modules/UI/Sources/UI/AppRoot/NowPlayingPanelButtons.swift` (new) | The strip's panel buttons, extracted from `NowPlayingStrip` to keep it under the type-body cap. No new button. |
| `Modules/UI/Sources/UI/Accessibility/A11yIdentifiers.swift` | `A11y.Immersive` enum. |
| `Modules/UI/Sources/UI/Resources/Localizable.xcstrings` | New keys; `make pseudolocale` after. |
| `App/BocanCommands.swift` | View menu item with an `@AppStorage` mirror. |
| `UITests/Menus/MenuManifest.swift` | The new View menu row. |
| `UITests/Surfaces/SurfaceCompletenessTests.swift` | Registry rows for the new identifiers. |
| `UITests/Visualizers/VisualizerLivenessTests.swift` | A fourth surface case. |
| `UITests/Support/E2ESession.swift` | Launch argument `-ui.immersive.visible NO`. |
| `CHANGELOG.md`, `README.md`, `website/` feature page, `docs/design-spec/README.md` | Release note, feature docs, ADR index row. |

## What carries over from previous specs

- **`VisualizerViewModel.start()` and `stop()` are reference counted** (ADR-022). Every surface that hosts a `VisualizerHost` pairs them in `onAppear` and `onDisappear`. Immersive Mode is a fourth such surface.
- **All Metal renderers keep `renderScale` at 1.0** (ADR-028, `MetalNebulaTests`). The immersive host introduces no scale.
- **`VisualizerHost` paints its own `Color.black`** under the renderer. Anything drawn over it that is not opaque reads as glass over black, not glass over the window.
- **Esc is a precedence ladder** (`NavigationInputMonitor`, ADR-083, `FullScreenTests`). Text focus first, then system full screen, then app-level layers. Immersive exit sits above drill-out and below full-screen exit.
- **Menu enablement reads `@AppStorage` mirrors, never plain VMs** (`BocanCommands.swift` header, the observation-staleness note). The immersive flag follows that pattern.
- **Every control ships an `A11y` id and a localized `.help()`** (ADR-080, `_standards.md`). Every id joins a crawl registry or `SurfaceCompletenessTests` fails.
- **No user-facing literals in `App/`.** Menu titles are the sanctioned exception.

## Definitions and contracts

### State

One preference, read and written in the `UI` module, mirrored in `App/`:

| Key | Type | Default | Read by | Written by |
|---|---|---|---|---|
| `ui.immersive.visible` | Bool | false | `BocanRootView` (toolbar label, reopen after bootstrap), `BocanCommands` (menu title) | `ImmersiveWindowView` on appear (true) and disappear (false) |

It mirrors whether the window is open; nothing else writes it. Opening and closing go through `openWindow(id:)` and `dismissWindow(id:)` with the scene id `immersive`. It is a `View`-level `@AppStorage`, the same as `lyrics.paneVisible`, and must not live on an `ObservableObject` held by the `App` struct (see the `WindowModeController` warning about `UserDefaults.didChangeNotification` loops).

The value persists across launches. An app that quits with the window open reopens it after bootstrap, from the same point in `BocanRootView.task` where the mini player restores; the scene's own restoration is disabled, so it can never open before bootstrap. E2E runs clear the key in `E2ESeeder`.

### Layout

```
+----------------------------------------------------------------------+
| [ VisualizerHost: Oscilloscope, Drift, full window, behind all ]      |
|                                                                       |
|  +----------------+  +------------------+  +----------------------+   |
|  |   artwork      |  |  Up Next         |  |  Lyrics     [offset] |   |
|  |   (square)     |  |  row             |  |  line                |   |
|  |                |  |  row (current)   |  |  line (current)      |   |
|  |  Title         |  |  row             |  |  line                |   |
|  |  Artist        |  |  ...             |  |  ...                 |   |
|  |  Album         |  |                  |  |                      |   |
|  |                |  |                  |  |                      |   |
|  |  ---o------ 1:23/4:56               |  |                      |   |
|  |  |< > >| shfl rpt stop   vol ---o    |  |                      |   |
|  +----------------+  +------------------+  +----------------------+   |
|                                                                 [x]   |
+----------------------------------------------------------------------+
```

- The window has a hidden title bar: no toolbar, no sidebar, no strip. It toggles itself into system full screen as soon as its content appears (`NSWindow.toggleFullScreen`, found by the scene id, the way the fullscreen visualizer finds its window to move it); SwiftUI has no scene modifier for that. Closing the window leaves full screen with it. The content ignores the safe area so the visualizer runs edge to edge.
- A compact cluster, centred, not three full-height columns. The queue card shows ten rows and scrolls past that; the cluster's height is derived from that (header plus ten `QueueRow` rows), and the other two cards match it. The now-playing card has a fixed width; the queue and lyrics cards share the rest up to a maximum cluster width, so a wide window keeps the visualizer around the cluster rather than stretching the cards. Gaps of `gutter` between and around the cards.
- Column 1: artwork fills the column width as a square (`ArtworkLoader.shared.image(at:maxDimensionPoints: 512)` is the cap; nothing larger helps), then title, artist, album in that order. Podcasts show episode title, show name, and no album line. Radio shows the live stream title and the station name. Missing artwork uses `GradientPlaceholder`. Under everything else, pinned to the foot of the column, `ImmersiveTransport`: a full-width scrubber with elapsed and total time, then `MiniPlayerTransport` in its `.navigation` layout (podcast-aware: skip back and forward for an episode), then mute and a volume slider. Every control has its own identifier and localized help.
- Column 2: `QueueView(vm:)` as is, with `.scrollContentBackground(.hidden)` so the panel colour shows. Drag reorder, context menu and double-click to play keep working because the view is the same one.
- Column 3: `LyricsView(vm:onSeek:searchText:)` with a header row holding the source badge and `LyricsOffsetControl`. The lyrics view model is driven from `BocanRootView` today (`trackDidChange`); the implementation must confirm that `positionDidChange` is also driven at root, not inside `LyricsPane`, and move it up if not. Otherwise lyrics do not scroll while the pane is hidden.
- A close button (`xmark.circle.fill`) at the bottom trailing corner of the overlay, plus the Esc key, plus the menu item and the strip button, all exit.

### Panels

`ImmersivePanel` is a `ViewModifier`:

- Background is a **tinted translucent fill**, `Color.black` at about half opacity, and deliberately not glass or a material. Both of those blur what is behind them, and behind these cards is an `MTKView` redrawing at the display rate; a clear-glass cut forced an offscreen blur pass over every card on every frame and the visualizer stuttered visibly. The tint lets the waveform read through at no cost and keeps the text legible. Reduce Transparency turns the card solid (`Color.bgPrimary`), the same escape the strip's material has. The opacity is one named constant.
- All three columns carry the card, the now-playing one included: with the clear surface its text was hard to read. Artwork, title and controls are centred within it, with a soft shadow under the cover.
- Card headers ("Up Next", "Lyrics") are quiet uppercase captions with no rule beneath them; the card edge is the frame.
- The whole overlay runs under `.environment(\.colorScheme, .dark)`, so the cards read as dark glass on the black field in both system appearances.
- Corner radius `Theme.cornerRadiusLarge`. Under Increase Contrast a 1pt `.separator` border is added, matching `AdaptiveMaterialBackground`.
- Text inside uses `Color.textPrimary` and friends, which resolve correctly under the forced dark scheme. The contrast audit (`ThemeAudit`, `ContrastAudit`) is run against the panel colours.

### Visualizer override

`VisualizerHost.init(vm:mode:palette:)` gains two optional parameters, default `nil`. The host computes `effectiveMode = mode ?? vm.mode` and `effectivePalette = palette ?? vm.palette`, uses them for renderer construction and in `rendererKey`, and otherwise behaves as today. The immersive overlay passes `.oscilloscope` and `.drift`. The pane, the mini player and the fullscreen window pass nothing and are unchanged.

The user's saved `visualizer.mode` and `visualizer.palette` are never written by this feature.

The overlay embeds `VisualizerLivenessReadout` (the `A11y.Visualizer.host`, `modeValue`, `paletteValue` and FPS readouts) so the E2E liveness matrix can observe it. It does not embed `VisualizerControlOverlay`; the mode and palette steppers would be lies on a fixed surface.

### Entry and exit

| Trigger | Where | Behaviour |
|---|---|---|
| View menu item | `BocanCommands`, after Toggle Miniplayer | Title "Enter Immersive Mode" / "Exit Immersive Mode" from the mirror; opens or dismisses the `immersive` scene. Shortcut `⇧⌘I` (`⌘I` is Get Info, `⌥⌘I` is Identify Track). Enabled always. |
| Toolbar button | `MainToolbarItems`, beside the mini player, lyrics and visualizer toggles | Same open or dismiss; the label follows the mirror. `A11y.Toolbar.immersiveToggle`, localized help. Not the strip: the strip has no slack at the window's minimum width, and a fifth panel button starved the scrubber. |
| Esc | `ImmersiveWindowView`, `onKeyPress(.escape)` | Closes the window, the fullscreen visualizer's pattern. Closing a window in system full screen leaves full screen with it. The main window's Esc ladder (`NavigationInputMonitor`) is untouched. |
| Close button | window corner | `A11y.Immersive.close`; the traffic lights close it too. |

Entering animates with `Theme.Animation.default` opacity unless Reduce Motion is on, using the existing `toggleAnimated` helper pattern.

### Accessibility identifiers

`A11y.Toolbar.immersiveToggle` for the toolbar button. `A11y.Immersive`: `root`, `nowPlayingColumn`, `artwork`, `title`, `artist`, `album`, `queueColumn`, `lyricsColumn`, `close`, and the transport: `transport`, `scrubber`, `previous`, `playPause`, `next`, `shuffle`, `repeatMode`, `stopAfter`, `skipBack`, `skipForward`, `mute`, `volume`. The lyrics offset control keeps `A11y.Lyrics.offsetButton` and `offsetSlider`; it is the same control. The root and every column use `.accessibilityElement(children: .contain)` so the children keep their identifiers.

### Localization keys

All in the `UI` catalog: the menu titles are bare literals in `App/` by the existing exception, but the strip button label and help, the close button label and help, the offset control label and help, and any empty-state copy in column 1 route through `L10n`. `make pseudolocale` after.

## Implementation plan

Five slices. Each is one commit on `feat/immersive`, gates green (`make format`, `make lint`, `make build`, `make test-coverage`, `make test-ui` where snapshots change).

1. **Visualizer per-surface override.** `VisualizerHost.init(vm:mode:palette:)`, effective values in `rendererKey`, `VisualizerHostOverrideTests`. Extract `VisualizerLivenessReadout` from `VisualizerControlOverlay` with no behaviour change; `VisualizerLivenessTests` still pass.
2. **Lyrics offset extraction.** Move the popover (`Slider` in `-5000...5000`, step 50, `A11y.Lyrics.offsetSlider`) into `LyricsOffsetControl`; `LyricsPane` uses it. Confirm `positionDidChange` is driven from `BocanRootView`; move it if it lives in the pane. `LyricsViewModelOffsetTests` unchanged and green.
3. **The overlay.** `ImmersivePanel`, `ImmersiveNowPlayingColumn`, `ImmersiveTransport`, `ImmersiveView` with the three columns and the visualizer behind; `MiniPlayerTransport` gains optional identifiers and the `.navigation` layout. `A11y.Immersive`, catalog keys, pseudolocale, light, dark and increased-contrast snapshots. The view owns its `start()`/`stop()` pairing. No wiring into the window yet; the snapshot host is the only consumer.
4. **Wiring.** The `immersive` hidden-title-bar scene in `BocanApp` with `ImmersiveWindowContent` through `GraphContent`; `ImmersiveWindowView` mirrors `ui.immersive.visible` and closes on Esc; the toolbar button and the View menu item (`⇧⌘I`) open or dismiss the window from the mirror; `BocanRootView` reopens it after bootstrap; `E2ESeeder` clears the key on every E2E launch (a launch argument would shadow it and freeze the menu label, the same trap the pane keys hit). Manual check in Xcode by the maintainer.
5. **E2E and docs.** `MenuManifest` row, `SurfaceCompletenessTests` registry rows, liveness fourth surface, `ImmersiveModeTests` (enter, Esc exit, menu exit, Esc under full screen still exits full screen first). CHANGELOG Unreleased note, README feature bullet, website feature page, ADR index row.

Slices 1 and 2 are independent of each other. Slice 3 needs both. Slice 4 needs 3. Slice 5 needs 4.

## Behavioural definitions

- **Given** Immersive Mode is off, **when** the user picks the View menu item, **then** a window with no toolbar, sidebar or strip opens in front of the main window, the visualizer runs Oscilloscope in Drift, and the three columns show the current track with its controls, the queue, and the lyrics.
- **Given** Immersive Mode is on, **when** the user presses play or pause, next, or drags the scrubber in column 1, **then** playback responds exactly as it does from the strip, because both drive the same view model.
- **Given** a podcast episode is playing, **when** Immersive Mode is on, **then** column 1's controls show skip back and skip forward instead of previous and next.
- **Given** the Immersive Mode window is frontmost, **when** the user presses Esc, **then** the window closes and the main window is untouched (no drill-out, no search clear).
- **Given** the main window is frontmost with Immersive Mode open behind it, **when** the user presses Esc, **then** the main window's own Esc ladder runs and the Immersive Mode window stays open.
- **Given** Immersive Mode is on, **when** the track changes, **then** column 1 updates, the queue's current-row marker moves, and the lyrics reload for the new track.
- **Given** Immersive Mode is on, **when** the user drags a queue row, **then** the queue reorders exactly as it does in the Up Next destination.
- **Given** the saved visualizer mode is Nebula and palette is Accent, **when** the user enters and exits Immersive Mode, **then** the saved mode and palette are still Nebula and Accent, and the visualizer pane, mini player and fullscreen window are unaffected.
- **Given** Immersive Mode is on, **when** the app quits and relaunches, **then** it opens in Immersive Mode.
- **Given** Reduce Motion is on, **when** Immersive Mode toggles, **then** there is no fade.
- **Given** a podcast episode is playing, **then** column 1 shows episode title and show name, column 3 shows the lyrics empty state, and nothing errors.

## Context7 lookups

- SwiftUI `toolbarVisibility(_:for:)` with `.windowToolbar` on macOS 15: confirm the modifier and its interaction with `NavigationSplitView`.
- SwiftUI `onKeyPress(.escape)` versus an AppKit local monitor: confirm which one the existing `NavigationInputMonitor` needs for the new hook to keep the documented precedence.
- SwiftUI `@Observable` in a `View` property versus `@ObservedObject`: `NowPlayingViewModel` is `@Observable`; `LyricsViewModel` and `VisualizerViewModel` are `ObservableObject`. Use the right wrapper for each or updates silently stop.

Always take the latest documented API; if a lookup shows any of the above deprecated on macOS 15, stop and ask.

## Dependencies

No new packages. No schema change. No new entitlements.

## Test plan

- **Unit (UI module):** `VisualizerHostOverrideTests` (override changes `rendererKey`, `nil` falls back to the VM, VM writes untouched); existing `VisualizerViewModelTests` refcount cases still pass with a fourth surface; `LyricsViewModelOffsetTests` unchanged.
- **Snapshots (`make test-ui`):** `ImmersiveView` light and dark, with a track, with a podcast, with an empty queue and no lyrics; Increase Contrast variant via the `bocanHighContrast` environment key.
- **E2E (`UITests/`):** `ImmersiveModeTests` as listed; `MenuCrawlTests`, `MenuEnablementTests`, `ShortcutParityTests` pick up the manifest row; `SurfaceCompletenessTests` covers the new identifiers; `VisualizerLivenessTests` proves the immersive host draws frames; `FullScreenTests` unchanged and green.
- **Audits:** `IdentifierAuditTests` and `Scripts/audit-help-text.py` (in `make lint`) pass without allowlist additions.
- **Coverage:** `make test-coverage` stays at or above the gate.

## Acceptance criteria

- The View menu, the strip button, Esc and the close button all enter or exit Immersive Mode, and the menu title flips.
- The visualizer behind the columns is Oscilloscope in Drift regardless of the saved visualizer preference, and the saved preference is unchanged afterwards.
- The three cards are translucent glass (material on macOS 15, solid under Reduce Transparency), sized to a ten-row queue and centred, so the visualizer fills the rest of the window and reads through the cards.
- The transport strip is covered while immersive, and column 1's controls drive playback, the scrubber, and volume.
- The queue and lyrics columns are the real `QueueView` and `LyricsView`, with reorder and synced scrolling working.
- Esc precedence matches the table above, and `FullScreenTests` stays green.
- All new controls have identifiers and localized help; `make pseudolocale` run; all gates green; CHANGELOG, README, website and ADR index updated.

## Gotchas

- **The Metal view must not touch `drawableSize` in `layout()`.** In the pane the `MTKView` never resizes, so the write in `VisualizerMTKView.layout()` was a no-op after the first frame. A window that animates open, or into full screen, resizes it every frame; the write re-entered AppKit layout (`NSDetectedLayoutRecursion`), zeroed the bounds, and every later frame drew a 1x1 drawable: a frozen, flat visualizer. The override is gone; the coordinator's per-frame draw applies the size outside the layout pass. This is the same trap ADR-028 hit with a sub-1.0 render scale, from the other side.
- **No glass or material over the Metal layer.** `VisualizerHost` draws the oscilloscope in an `MTKView` at the display rate. Glass and materials blur what is behind them, which means an offscreen blur of the live Metal content on every frame, per card; a clear-glass cut made the visualizer stutter on an M5 Max. A tinted translucent fill gives the see-through look for free. If glass is ever wanted, it needs a static backdrop (a blurred cover, say), not the live visualizer.
- **Forced dark scheme.** `.environment(\.colorScheme, .dark)` on the overlay changes every colour inside it, including `QueueView` rows and the lyrics text. Snapshot both system appearances to prove nothing inside goes invisible.
- **`QueueView` sets `.navigationTitle`.** Harmless outside a navigation container, but do not let it leak a title onto the main window; if it does, wrap or drop it.
- **Global mode and palette.** Do not "temporarily" write `visualizer.mode`. The pane, mini player and fullscreen window share that key and would flip too. The override parameter exists so nobody has to.
- **Refcount balance.** One `start()` in `onAppear`, one `stop()` in `onDisappear`, on the overlay itself. Hiding the trailing visualizer pane while immersive triggers its own `onDisappear`; that is expected and balanced.
- **Toolbar hiding.** Decided against: `toolbarVisibility(.hidden, for: .windowToolbar)` takes the title bar and traffic lights with it. The toolbar stays visible above the overlay.
- **Preference shadowing in E2E.** A `-ui.immersive.visible NO` launch argument would shadow the key for the whole run, so a menu toggle could never flip the label. `E2ESeeder` deletes the key instead, like the pane keys.
- **Esc belongs to the window.** `ImmersiveWindowView` handles Esc with `onKeyPress`, so the main window's `NavigationInputMonitor` ladder and `FullScreenTests` are untouched. Do not add an immersive arm to that ladder again.
- **Scene restoration is disabled** on the `immersive` scene, like every secondary scene: a restored secondary window can open before bootstrap and starve it (the mini player did exactly that). The root reopens it after bootstrap from the persisted mirror instead.
- **Identifier combining.** A label plus an identifier on a container merges the children. Use `.accessibilityElement(children: .contain)` on every column and on the root.
- **The `xcstrings` churn.** Xcode reorders the catalog on a run; `make pseudolocale` renormalizes before commit.

## Handoff

- **Strip-only controls in Immersive Mode.** Love, sleep timer, playback speed, DSP and the pending-scrobble badge live only in the strip today. If they are wanted in column 1, extract them from `NowPlayingStrip` (which sits at the file-length cap) into shared views first, the way `MiniPlayerTransport` was.
- **Per-surface visualizer setting.** `immersive.visualizerMode` and `immersive.visualizerPalette` preferences with a small picker in Settings > Visualizer. The override plumbing is already there; the work is the settings UI, the mirror, and the E2E rows.
- **Artwork blur field.** A blurred, dimmed copy of the artwork behind the columns as an alternative to the visualizer, for machines where Metal is unavailable or on battery with `simplifyOnBattery`.
- **Column width memory.** Draggable dividers with a saved ratio, following the `lyrics.paneWidth` pattern.
- **Podcast chapters column.** Replace the lyrics column with the chapter list when a podcast with chapters plays.
