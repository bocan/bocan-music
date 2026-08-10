# Phase 31: E2E Surface Crawl (Every Button in the Main Window)

> Prerequisites: Phases 28-30. This is the heart of the dream: every
> control on every main-window surface gets clicked with a defined
> postcondition, and a sampled hover pass proves tooltips actually render.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

For each sidebar destination and each main-window surface, a crawl suite
that clicks every identified control and asserts a specific postcondition,
plus a per-surface hover spot-check (3-5 controls) that verifies a real
tooltip window appears containing the control's help text.

## Non-goals

- Menus (phase 30), secondary windows and settings (phase 32),
  visualizer content (phase 33), network-dependent journeys (phase 34).

## Implementation plan

1. **Surface inventory.** One suite per destination: Songs, Albums,
   Artists, Genres, Composers, Podcasts, Radio, Up Next, Recents, a local
   playlist, a smart playlist, and search results. Plus the transport
   strip and toolbar as their own suites. Each suite is a table of
   (identifier, action, postcondition), interpreter-driven like the menu
   manifest, so the reviewable artifact is the table.
2. **Postcondition discipline.** Every click asserts something concrete:
   a sheet appears (and is dismissed), a toggle's value flips, the
   destination changes, a row's state changes. "Did not crash" alone is
   never a postcondition, except where the control's whole contract is
   visual (then the assertion is that the app remains responsive and the
   control remains present).
3. **Hover-revealed controls.** Rows that reveal buttons on hover (radio
   stations, Subsonic stations, queue rows) get an explicit
   hover-then-click step in their tables; the harness's `hoverRow()`
   helper from phase 29's crawler is reused.
4. **The tooltip spot-check.** Per surface, 3-5 representative controls:
   `element.hover()`, wait up to 3s for a tooltip, and assert the
   help text appears in the app's window list as static text. Marked
   `.tags(.tooltip)` so the whole category can be quarantined in one line
   if macOS tooltip timing turns hostile on some OS release; the
   guarantee of help-text *existence* stays with phase 29's audits.
5. **Navigation invariants woven in**: after each drill-down suite, one
   Esc drill-out and one mouse-back assertion (the phase 27/378 semantics)
   so the navigation contract is re-proven on every surface.
6. **Interaction coverage beyond clicks** where the surface contract
   includes it: double-click to play (rows, album covers), type-to-search
   from each browse view, drag a track to Up Next (XCUIElement
   press-and-drag), column sort clicks on the track tables.

## Test plan

- Every table row green per surface, headed and via `make test-e2e`.
- Tooltip spot-checks green on a developer Mac (allowed flaky-quarantine
  on the GitHub tier from day one).
- Deliberate breakage drill: hide one button behind a condition and watch
  the surface's table fail (verified once, documented).

## Acceptance criteria

- [ ] Every `A11y` identifier registered in phase 29 for these surfaces
      appears in exactly one crawl table (a completeness test enforces
      this bidirectionally, so new controls must join a table to ship).
- [ ] All postconditions are state assertions, not absence-of-crash.
- [ ] Tooltip spot-check present for every surface, quarantinable by tag.
- [ ] Esc/mouse-back invariants asserted from every drill-down.

## Gotchas

- Tooltips: macOS shows them in an app-owned borderless window after a
  system-controlled delay; the 3s wait is empirical, and the text match
  must be `contains`, not equality (macOS may truncate).
- Coordinate-based drags on SwiftUI lists need
  `coordinate(withNormalizedOffset:)` anchoring; element-to-element drag
  is more stable when both ends have identifiers.
- The crawl's completeness test is the long-term payoff: it converts
  "we forgot to test the new button" from a review hope into a red build.

## Handoff

Phase 32 extends the same table pattern beyond the main window; phase 35
budgets runtime knowing this phase is the largest suite (est. 30-60 min).
