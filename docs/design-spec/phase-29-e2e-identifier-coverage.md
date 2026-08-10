# Phase 29: E2E Identifier and Help-Text Coverage

> Prerequisites: Phase 28 (fixture mode, harness, `make test-e2e`).
> "Every button clicked" requires every button to be *findable*: a stable
> `accessibilityIdentifier` on each interactive control, and, per the agreed
> hover policy, localized `.help()` text on each as well. Today the `A11y`
> namespace covers many surfaces but not all; this phase makes coverage
> total and, crucially, *enforced*, so a new button cannot ship unfindable.
>
> Read `docs/design-spec/_standards.md` first.

## Goal

Every interactive control in every surface carries a stable identifier from
the `A11y` namespace and localized help text, with two automated audits that
fail when a control ships without them.

## Non-goals

- Clicking the controls (phases 30-32). This phase only makes them
  reachable and self-describing.

## Implementation plan

1. **Identifier sweep.** Extend `A11yIdentifiers.swift` with namespaces for
   every surface that lacks them (browse toolbars, queue rows, playlist
   rows, settings panes, mini players, sheets). Convention stays
   `surface.control`; row-level controls get `surface.row.control` with the
   row disambiguated by its accessibility label, not by index.
2. **The AX crawler audit (UITests/Audits/).** For each destination and
   window, a crawl test walks the accessibility tree and fails on any
   enabled `button`, `checkBox`, `popUpButton`, `slider`, `menuButton`, or
   `textField` whose identifier is empty and which is not on the explicit
   allowlist (system-provided controls: window chrome, scrollers, table
   sort headers AppKit owns). The allowlist lives in one file with a
   comment per entry.
3. **The help-text audit (Scripts/audit-help-text.py).** A source-level
   scan of `Modules/UI/Sources` and `App/` for interactive-control call
   sites (`Button(`, `Toggle(`, `Picker(`, `Slider(`, `Menu(`) lacking an
   attached `.help(` in the same expression chain, with a per-site
   allowlist for controls whose label is self-sufficient (per-case
   judgment, recorded in the allowlist file). Wire into `make lint` as a
   non-strict warning first; flip to failing once the sweep lands.
4. **Localization check rides free**: `.help()` strings go through the
   existing `L10n` machinery, so the `no_bare_user_facing_literal` rule and
   `L10nTests` already guarantee any help text added here is localized.

## Test plan

- Crawler audit green across: every sidebar destination, the transport
  strip, settings (each pane), Library Summary (each tab), Log Console,
  all three mini player modes, and every sheet reachable without network.
- Help audit green with an allowlist small enough to read in one sitting.
- Negative test: a scratch build with one unidentified button fails the
  crawler (verified once manually, documented in the audit file header).

## Acceptance criteria

- [ ] Zero unidentified interactive controls outside the allowlist.
- [ ] Zero help-less interactive controls outside the allowlist.
- [ ] Both audits run in `make test-e2e` (crawler) and `make lint`
      (help scan).
- [ ] `docs/design-spec/_standards.md` gains the rule: new interactive
      controls ship with `A11y` identifier + localized `.help()`.

## Gotchas

- SwiftUI sometimes collapses child identifiers when a parent uses
  `.accessibilityElement(children: .combine)`; rows doing this (the radio
  and Subsonic station rows) expose actions via rotors instead, and the
  crawler must treat combined elements with custom actions as compliant.
- Hover-revealed buttons do not exist in the tree until hover; the crawler
  hovers each row container before walking it.
- The AppKit-backed tables (`TrackTableCoordinator`) expose NSTableView
  accessibility, not SwiftUI's; their per-row controls are audited via
  their AppKit identifiers.

## Handoff

Phases 30-32 may assume any control they want to click is reachable as
`app.descendants(matching:).matching(identifier:)` with exactly one match
per screen context.
