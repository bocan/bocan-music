# Phase 30: E2E Menu Bar Crawl

> Prerequisites: Phases 28-29. The menu bar is wired in `App/BocanCommands`
> and has already produced exactly the bug class this programme exists for:
> the help book shipped three wrong shortcuts for months, and ⌘A silently
> stole select-all from text fields. Menus are cheap to crawl exhaustively
> because XCUITest reads them as a plain tree (`app.menuBars`), no
> identifiers needed.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Every menu, submenu, and item: asserted to exist with its expected title,
shortcut, and enablement per app state, and every item actually invoked at
least once in fixture mode with a postcondition check.

## Non-goals

- Context menus inside views (phase 31 owns those with their surfaces).
- The system-supplied items Apple owns (Services, Emoji, window tiling).

## Implementation plan

1. **The menu manifest (UITests/Menus/MenuManifest.swift).** A declarative
   table: menu path, expected title, expected shortcut string, enablement
   contexts, invocation postcondition, and a `skip` reason where invocation
   is impossible (e.g. Check for Updates under the E2E flag). The manifest
   is the reviewable single source of truth; the crawl is just its
   interpreter.
2. **Shortcut parity test (UITests/Menus/ShortcutParityTests.swift).**
   The manifest's shortcut strings are asserted directly against parsed
   source (no generated fixture needed): `KeyBindings.swift`, the
   `.keyboardShortcut(...)` declarations in `BocanCommands*.swift`, the
   help book's shortcut table row by row, and every shortcut token in the
   help book's prose, so the manifest, the bindings, the menus, and the
   shipped docs (phase 27 fix) can never drift apart silently again.
3. **Structural crawl.** Walk `app.menuBars` recursively; fail on any menu
   item present but absent from the manifest, or vice versa. This is what
   catches "a menu item quietly vanished" a month before a human notices.
4. **Enablement matrix (UITests/Menus/MenuEnablementTests.swift).** For a
   small set of app states (fresh launch; track selected; track playing;
   search field focused; seeded radio queue current) open each menu and
   assert per-manifest enablement. The ⌘A regression becomes a permanent
   matrix row: with the search field focused, Select All must leave the
   field's text selected, not the track list.
5. **Invocation pass.** In fixture mode, invoke every non-skipped item and
   assert its postcondition (window appears, mode toggles, destination
   changes). Destructive items (Clear Queue, Remove) run against throwaway
   fixture state and assert the destruction happened, then reset.

5. **Invocation pass (UITests/Menus/MenuInvocationTests.swift).** One
   scripted sequence invokes every non-skipped manifest leaf with a real
   postcondition (window opens and closes, pane title flips, queue insert
   shows in Up Next, rating changes smart-playlist membership, transport
   toggle flips the strip's AX label, navigation switches destination,
   Clear Queue empties the queue). State builds forward: queue items are
   inserted before playback, destructive items run against throwaway
   fixture state. `MenuInvoker` owns menu clicking and the shared
   postcondition helpers. Eight items carry written skip reasons; a
   completeness assertion proves every non-system leaf was invoked or
   skipped.

## Test plan

- Structural crawl green against the full manifest.
- Enablement matrix green for all five states.
- Invocation pass green; every skip carries a written reason.

## Acceptance criteria

- [x] Manifest covers 100% of app-owned menu items (structural crawl
      proves it bidirectionally; Window menu contents are system-managed
      and excluded by design).
- [x] Shortcut parity: manifest == KeyBindings == menu source == help
      book (table rows and prose tokens).
- [x] ⌘A-in-search-field is a permanent enablement-matrix assertion.
- [x] A deliberately renamed menu item fails the crawl (verified once,
      noted in the manifest header).
- [x] Every app-owned menu item invoked in fixture mode with a
      postcondition (invocation pass); each skip has a written reason and
      the completeness assertion proves coverage.

## Gotchas

- Menu enablement updates lazily; open the menu before asserting, and
  allow one 100ms settle. Never assert enablement without the menu open.
- `BocanCommands` reads some state from `@AppStorage` keys to avoid menu
  invalidation storms; the matrix must set state through the app (clicks),
  not by writing defaults, or it tests a lie.
- Items that open modal panels (About, file pickers) need the panel
  dismissed before the crawl continues; the interpreter owns dismissal.
- E2E launches share the container's real `UserDefaults` (isolation is a
  phase 32 decision), so preference-gated items ("Fetch Lyrics from
  LRClib") and Show/Hide labels vary by machine. The crawl pins the
  feature flag on via `MenuManifest.pinnedDefaults` (argument domain) and
  the manifest lists both labels of dynamic titles.
- The first crawl caught the bug class it exists for: `%.2g` labelled the
  1.25× quick rate "1.2×" (and 1.75× "1.8×" in Podcast settings) across
  four surfaces; fixed by `PlaybackRateLabel` with a regression test.
- **A `Commands` body only re-evaluates on @AppStorage or @Observable
  reads.** The view models arrive as plain `let`s (deliberately, to keep
  the menu bar off the high-frequency render path), so `.disabled` gates
  reading `@Published`/plain state freeze at whatever the body was built
  with. The matrix caught three: the File-menu rescan items
  (`isScanning`, now an `library.scanActive` defaults mirror), the
  "View as" pair (`library.collectionListingActive` mirror), and the
  whole Track menu (now reading the @Observable `tracks.selection`
  directly). Gate new menu items on @Observable or @AppStorage state
  only.
- A menu `Picker`'s options ignore `.disabled` entirely (they stay
  clickable and write the selection while only the header greys out);
  the "View as" pair is therefore checkmarked `Toggle`s, not a Picker.
- The scan-summary banner auto-dismisses after 3 seconds, so it is
  useless as a "scan settled" signal for tests; the matrix relies on its
  own retry loop instead.
- A stopped queue whose current item is a stream emits no current-track
  change (streams are never engine-preloaded), so the now-playing display
  sat on "Not playing" after a radio restore, and menu gates keyed off it
  were wrong. `NowPlayingViewModel` now seeds its display from the queue
  after activation and re-syncs on queue changes at rest.

## Handoff

Phase 31 reuses the manifest interpreter pattern for per-surface control
crawls, and the enablement matrix states become shared harness fixtures.
