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
2. **Shortcut parity test.** The manifest's shortcut strings are asserted
   against `KeyBindings.swift` via a generated fixture, so the manifest,
   the menus, and the help book's shortcut table (phase 27 fix) can never
   drift apart silently again: one source-convention test compares all
   three.
3. **Structural crawl.** Walk `app.menuBars` recursively; fail on any menu
   item present but absent from the manifest, or vice versa. This is what
   catches "a menu item quietly vanished" a month before a human notices.
4. **Enablement matrix.** For a small set of app states (nothing playing;
   track playing; radio playing; track selected; text field focused) open
   each menu and assert per-manifest enablement. The ⌘A regression becomes
   a permanent matrix row: with the search field focused, Select All must
   leave the field's text selected, not the track list.
5. **Invocation pass.** In fixture mode, invoke every non-skipped item and
   assert its postcondition (window appears, mode toggles, destination
   changes). Destructive items (Clear Queue, Remove) run against throwaway
   fixture state and assert the destruction happened, then reset.

## Test plan

- Structural crawl green against the full manifest.
- Enablement matrix green for all five states.
- Invocation pass green; every skip carries a written reason.

## Acceptance criteria

- [ ] Manifest covers 100% of app-owned menu items (structural crawl
      proves it bidirectionally).
- [ ] Shortcut parity: manifest == KeyBindings == help book table.
- [ ] ⌘A-in-search-field is a permanent enablement-matrix assertion.
- [ ] A deliberately renamed menu item fails the crawl (verified once,
      noted in the manifest header).

## Gotchas

- Menu enablement updates lazily; open the menu before asserting, and
  allow one 100ms settle. Never assert enablement without the menu open.
- `BocanCommands` reads some state from `@AppStorage` keys to avoid menu
  invalidation storms; the matrix must set state through the app (clicks),
  not by writing defaults, or it tests a lie.
- Items that open modal panels (About, file pickers) need the panel
  dismissed before the crawl continues; the interpreter owns dismissal.

## Handoff

Phase 31 reuses the manifest interpreter pattern for per-surface control
crawls, and the enablement matrix states become shared harness fixtures.
