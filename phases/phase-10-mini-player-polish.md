# Phase 10 — Mini Player, Window Modes, Polish

> Prerequisites: Phases 0–9 complete.
>
> Read `phases/_standards.md` first.

## Goal

A second, slick, resizable mini-player window; clean toggle between full and mini modes; refined light/dark themes audited across every view; Dock tile with now-playing thumbnail; optional menu-bar extra and on-track-change notifications; proper preferences/settings window. Sleep timer. Playback speed control.

## Non-goals

- Fullscreen visualizer — Phase 12.
- Widgets on the macOS lock screen / Notification Centre widget — stretch; only if trivial via WidgetKit.
- Customisable Touch Bar — not worth the effort (deprecated on current hardware).

## Outcome shape

```
Modules/Playback/Sources/Playback/    # Extended from Phase 5
└── SleepTimer.swift                  # Countdown actor; fires stop command to QueuePlayer on expiry

Modules/UI/Sources/UI/Transport/
├── SleepTimerMenu.swift              # Playback > Sleep Timer submenu + NowPlayingStrip countdown badge
└── SpeedPickerView.swift             # Transport speed control (0.5×–2.0×)

Modules/UI/Sources/UI/MiniPlayer/
├── MiniPlayerWindow.swift           # Scene
├── MiniPlayerView.swift             # Root layout
├── MiniPlayerCompact.swift          # < 320 pt wide mode
├── MiniPlayerSquare.swift           # square artwork-first mode
└── MiniPlayerViewModel.swift

Modules/UI/Sources/UI/WindowModes/
├── WindowModeController.swift       # Switches scenes + remembers state
└── AlwaysOnTop.swift

Modules/UI/Sources/UI/Settings/
├── SettingsScene.swift              # Top-level Settings scene
├── GeneralSettingsView.swift
├── LibrarySettingsView.swift
├── PlaybackSettingsView.swift
├── DSPSettingsView.swift            # Wraps Phase 9 views
├── AppearanceSettingsView.swift
├── AdvancedSettingsView.swift
└── AboutView.swift

Modules/UI/Sources/UI/MenuBarExtra/
└── MenuBarExtraScene.swift

Modules/UI/Sources/UI/DockTile/
└── DockTileController.swift

Modules/UI/Sources/UI/Theme/
├── ThemeAudit.swift                 # Debug helper to dump all semantic colours
└── AccentPalette.swift
```

## Implementation plan

1. **Multiple scenes** in `BocanApp`:
   ```swift
   @main struct BocanApp: App {
       var body: some Scene {
           WindowGroup("Bòcan", id: "main") { RootView() }
               .defaultSize(width: 1280, height: 800)
           Window("Mini Player", id: "mini") { MiniPlayerView() }
               .windowResizability(.contentSize)
               .defaultSize(width: 420, height: 72)
               .defaultPosition(.bottomTrailing)
               .windowToolbarStyle(.unifiedCompact)
           Settings { SettingsScene() }
           #if canImport(SwiftUI) && !DEBUG
           MenuBarExtra("Bòcan", systemImage: "music.note") { MenuBarExtraScene() }
               .menuBarExtraStyle(.window)
           #endif
       }
   }
   ```

2. **`WindowModeController`**:
   - Open/close via `@Environment(\.openWindow)` and `dismissWindow`.
   - `⌘⌥M` toggles Mini; when toggling, close the other (unless user holds ⌥, which keeps both).
   - State (which window is last shown, last size/position of each) persisted in `ui.state.v1`.
   - `restoresLastMode` setting: on launch, restore the last window the user had open.

3. **Mini player layout** adapts to size:
   - **Square** (≥ 220 × 220): big artwork dominates; title + artist marquee-scroll under it; tiny transport below; scrubber as a thin line at the bottom.
   - **Compact horizontal** (300–600 × 64–96): thumbnail left, title/artist centre, transport + scrubber right.
   - **Minimal strip** (≥ 200 × 28): just title + play/pause.
   - All transitions animated with a `.spring`.

4. **Always-on-top toggle** — floating-window level for Mini. Toggleable via a pin button in Mini's titlebar. Persisted.

5. **Menu-bar extra**:
   - Icon changes to reflect state: `music.note` paused, `music.note` with subtle dot when playing.
   - Popover shows artwork + title/artist + transport + "Show Bòcan" button.
   - Off by default; setting to enable. Uses `MenuBarExtra(isInserted:)` bound to the setting.

6. **Dock tile**:
   - `DockTileController` updates `NSApp.dockTile` on track change with:
     - A composed image: small app-logo corner + current album art.
     - A progress bar at the bottom (via a custom `NSView` set as `dockTile.contentView`).
   - Throttle updates (every 2s during playback is enough).
   - Off / on setting.

7. **Track change notifications**:
   - Using `UserNotifications` framework. Banner with artwork, title, artist. Tapping brings the window forward.
   - Off by default; setting to enable. Request authorisation only when the user enables it.
   - Do not show when the app is frontmost.

8. **Settings window** — standard `Settings` scene with sidebar tabs. Each panel wires to existing settings keys. Add missing ones:
   - General: startup behaviour, window restoration, notifications, menu bar extra.
   - Library: root folders (with "Add…" and "Remove"), quick vs full scan defaults, watch for changes toggle.
   - Playback: gapless preroll seconds, shuffle mode preferences, repeat default, cross-album gapless tolerance, default speed (reset to 1× button), sleep timer default duration, fade-out toggle.
   - DSP: wraps Phase 9 panels.
   - Appearance: theme mode (System / Light / Dark / Match macOS), accent colour picker, row density, reduce motion override.
   - Advanced: logging level, "Reveal DB in Finder", "Export Diagnostics" (writes a sysdiagnose-like bundle), "Reset Preferences", "Rebuild FTS Index".

9. **Accent colour**:
   - `AccentPalette` defines 8 curated accents (+ System). When changed, the app's tint updates live.
   - Stored in `settings` and applied via `.tint(...)` at `RootView`/`MiniPlayerView` level.

10. **Theme audit**:
    - Every view reviewed in both modes against WCAG AA contrast minima.
    - Snapshot tests cover: sidebar collapsed & expanded, tracks view, album grid, album detail, playlist detail, smart playlist, metadata editor, EQ view, DSP view, mini player at three sizes, settings panels.
    - `ThemeAudit` debug menu item opens a window with swatches of every semantic colour in both modes for eyeballing.

11. **Empty states, error states, loading states** — every major view has intentional illustrations/messages. Collect into `EmptyState` / `ErrorState` / `LoadingState` reusable views. No "spinner forever" anywhere.

12. **Motion & transparency**:
    - `reduceMotion` disables marquee scroll and spring transitions.
    - `reduceTransparency` swaps vibrancy for solid fills.
    - `increaseContrast` strengthens separators.

13. **Marquee** — when title/artist text overflows, auto-scroll with a 3s delay, 60 pt/s, pause on hover. Respects `reduceMotion`.

14. **Performance pass**:
    - Launch ≤ 1.5s on M1.
    - Memory ≤ 300 MB on a 10k-track library.
    - 60fps on album grid scroll.
    - Idle CPU ≤ 1% paused, ≤ 5% playing.

15. **Error recovery**:
    - If the main window closes via `⌘W`, the app does not terminate — it hides. `⌘,` (settings) or Dock click reopens.
    - `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
    - `⌘Q` quits with confirm if a background scan or RG analysis is in progress.

16. **`SleepTimer`** actor in `Modules/Playback`:
    - Countdown in minutes; preset durations: Off, 15, 30, 45, 60, 90, 120, Custom (text-field entry).
    - Optional “Fade out in last 30 s” setting: ramps `QueuePlayer` volume from 1.0 → 0 over the final 30 s, then calls `stop()`.
    - Timer state persisted in `settings` (`playback.sleepTimer.expiresAt`, `playback.sleepTimer.fadeOut`). On relaunch, if `expiresAt` is in the future the timer resumes from the remaining duration.
    - UI: `Playback > Sleep Timer` submenu in the menu bar. NowPlayingStrip shows a moon icon + remaining time (e.g. “☽ 28 m”) when active.
    - Cancellation: selecting “Off” or tapping the active preset again cancels the timer.

17. **Playback speed control**:
    - `QueuePlayer.setRate(_ rate: Float) async` — sets `AVAudioPlayerNode.rate` with `AVAudioTimePitchAlgorithm.spectral` for pitch-correction (no chipmunk effect at high speeds).
    - Range: 0.5×–2.0×, default 1.0×, step 0.05×.
    - UI: `SpeedPickerView` in the NowPlayingStrip — a popover triggered by a “1.0×” label, showing a slider + quick-pick buttons (0.75, 1.0, 1.25, 1.5, 2.0). Hidden when at 1.0× to reduce visual noise; revealed on hover or via Settings.
    - Persisted to `settings` as `playback.rate` (default `1.0`). A “Reset to 1×” button in `PlaybackSettingsView`.

## Context7 lookups

- `use context7 SwiftUI multiple windows Scene macOS`
- `use context7 SwiftUI MenuBarExtra window style`
- `use context7 NSDockTile contentView progress bar SwiftUI`
- `use context7 UserNotifications macOS authorization`
- `use context7 NSApp applicationShouldTerminateAfterLastWindowClosed SwiftUI`
- `use context7 SwiftUI Settings scene tabs sidebar`
- `use context7 AVAudioPlayerNode rate timePitchAlgorithm spectral pitch correction`
- `use context7 NSWorkspace didWakeNotification macOS sleep timer`

## Dependencies

None new.

## Test plan

- Snapshot every settings pane in light/dark.
- Snapshot mini player at small/medium/square sizes, light/dark, playing & paused, with and without cover art.
- Window state persistence: open mini, resize, move, quit, relaunch → restored.
- Always-on-top toggle changes window level.
- Menu bar extra appears/disappears when toggled in Settings.
- Dock tile image updates on track change; respects the setting.
- Notification posts when a track starts and the app is not frontmost; doesn't post when frontmost.
- Theme audit dump snapshot (swatches view) to catch accidental colour changes in review.
- Launch performance: sign-posted in Instruments; test asserts `App Launch` signpost < 1500ms.
- Accessibility: full keyboard nav traverses mini player and main; VoiceOver reads transport actions correctly.
- Reduced-motion: marquee doesn't scroll.
- `⌘W` hides, doesn't terminate; `⌘Q` confirms during scan.

## Acceptance criteria

- [ ] Mini player looks good at any reasonable size and both themes.
- [ ] Switching modes is instant and remembers positions.
- [ ] Dock tile artwork + progress visible and not distracting.
- [ ] Sleep timer stops playback at the configured time; the fade-out is audible when enabled.
- [ ] Playback speed changes are immediate; pitch is preserved across the full 0.5×–2.0× range.
- [ ] Menu bar extra usable without opening the main window.
- [ ] Settings window has every runtime-toggleable preference.
- [ ] Every view passes contrast checks and snapshot tests in both themes.
- [ ] Launch perf baseline met.
- [ ] 80%+ coverage on new non-view code.
- [ ] `make lint && make test-coverage` green.

## Gotchas

- **`MenuBarExtra` rebuilds** frequently; keep its body cheap. Extract heavy work to a shared view model.
- **Dock tile custom view** must be `NSView`; the progress bar must redraw when window server tells it to. Use `needsDisplay = true` on tick, don't time-drive from a `Timer` running at 60Hz.
- **Notifications** require authorisation; re-asking after denial is disallowed. Show a one-time explainer before the system prompt.
- **Always-on-top** at NSFloatingWindow level can steal focus in edge cases; test with screensaver + full-screen apps.
- **`Settings` scene** on macOS 14 has quirky sidebar persistence; reset-to-defaults flows must not lose the selected pane.
- **`applicationShouldTerminateAfterLastWindowClosed`** in SwiftUI: set via an `AppDelegate` adaptor if not available via scene modifiers.
- **Opening a window** that's already open just brings it forward — make sure your toggle logic accounts for this (closing vs. dismissing).
- **`@SceneStorage`** for per-window small state, `@AppStorage` for app-wide booleans. Don't abuse `@AppStorage` for complex types.
- **Marquee**: measuring text for overflow requires the rendered width; use `TimelineView` + `.drawingGroup()` trick or a `GeometryReader` with a measured overlay.
- **Window restoration and sandbox**: SwiftUI's default frame autosave works under sandbox; verify on clean account.
- **Dark mode + custom colours**: don't hardcode. Every colour is a semantic asset in the catalogue.- **Sleep timer + system sleep**: macOS may sleep the machine before the timer fires. Listen for `NSWorkspace.didWakeNotification`; if `expiresAt` is now in the past, stop playback immediately.
- **Pitch algorithm at rate changes**: switching `timePitchAlgorithm` while audio is playing causes a dropout. Set it once at engine init; don’t change it dynamically.
- **Speed + gapless timing**: `AVAudioPlayerNode` handles rate-adjusted scheduling internally against the output device’s fixed sample rate. Don’t try to adjust pre-scheduled `AVAudioTime` values manually.
## Handoff

Phase 11 (Lyrics) expects:

- A reusable overlay/sheet surface exists so a lyrics pane can appear without disrupting transport.
- `MiniPlayerView` has a lyrics toggle stub (disabled until Phase 11 ships).
- Accessibility settings from this phase apply to the lyrics view (reduce motion disables auto-scroll).
