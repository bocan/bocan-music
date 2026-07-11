# Phase 22-8: Settings Pane + Pairing Sheet

> Depends on: `phase22-0-overview.md`, `phase22-4-pairing-ceremony.md` (the
> `PairingUIBridge` seam + coordinator), `phase22-5-manifest.md`
> (`SyncProfile` + repository, for the profile editor + size estimate),
> `phase22-7-lifecycle-bonjour.md` (`SyncServer` start/stop + enable toggle).
> Touches **UI** and **App**.
>
> Binding docs: `_standards.md`, `docs/design-spec/localization.md`, the `UI`
> module CLAUDE.md, `sync-protocol.md` section 4 (the human-confirmation step is
> part of the security design).

## Goal

A "Phone Sync" Settings pane and its pairing sheet, fully localized and
snapshot-tested. The pane exposes: an enable toggle, a sync-profile editor with a
size estimate, a paired-devices list with Revoke, and a "Pair a phone" button
that presents the pairing sheet (large six-digit code, spinner states, and the
mandatory final "Pair with '<device>'?" confirmation). This is the only
user-facing surface of Phase 22; it implements the `PairingUIBridge` the ceremony
drives.

## Where it plugs in (real registration path)

Settings in this app is an enum-driven scene, not `TabView` items. Register the
new pane in three files (mirroring the existing panes):

1. `Modules/UI/Sources/UI/Settings/SettingsRouter.swift`: add a
   `case phoneSync` to `SettingsPage`.
2. `Modules/UI/Sources/UI/Settings/SettingsScene.swift`:
   - add `phoneSync` to the appropriate section in `SettingsSection.sidebar(...)`,
   - add a `detail(for:)` switch arm returning `PhoneSyncSettingsView(...)`,
   - add `title` and `systemImage` arms (a localized title key + an SF Symbol,
     e.g. `iphone.and.arrow.forward` or `arrow.trianglehead.2.clockwise` — pick
     one that reads as "sync to phone").
3. `App/AppSceneContent.swift` (`SettingsWindowContent`) +
   `App/BocanApp.swift` (`buildGraph` / `AppGraph`): build a
   `PhoneSyncViewModel` in `buildGraph`, store it on `AppGraph`, and thread it
   through `SettingsWindowContent` into `SettingsScene(...)` (the same way
   `subsonicViewModel` / `scrobbleViewModel` are injected).

## View model

`@MainActor final class PhoneSyncViewModel: ObservableObject` (or `@Observable`)
in `Modules/UI`, holding a seam to the server (declared in `UI`, implemented in
`App` over `SyncServer` + repositories, so `UI` does not import `SyncServer`
directly if the DAG prefers a protocol seam; per the overview `UI` may depend on
`SyncServer`, so a direct dependency is also acceptable, choose one and be
consistent). It exposes:

- `enabled: Bool` (writes the persisted toggle; on -> `syncServer.start()`, off
  -> `syncServer.stop()`).
- `profile: SyncProfile` + editing affordances; `sizeEstimate: String` (a
  human-formatted byte total summed from in-profile track/episode sizes, via a
  `sizeEstimate()` call on the seam; recomputed when the profile changes).
- `pairedDevices: [TrustedDevice]` (from `TrustedDevices.list()`), with
  `revoke(fingerprint:)`.
- Pairing sheet state: `startPairing()` calls `syncServer.armPairing()`; the
  `PairingUIBridge` callbacks drive `codeToShow`, `awaitingConfirmation(device,
  fpTail)`, and `pairingResult`.

The view model **is** (or owns) the `PairingUIBridge` implementation:

```swift
func showCode(_ code: String) async            // publish to the sheet
func requestConfirmation(deviceName:, fingerprintTail:) async -> Bool  // await the user's Trust click
func pairingEnded(result:) async               // dismiss / show result
```

## The pane (`PhoneSyncSettingsView`)

Sections, all chrome localized:

1. **Enable**: a `Toggle` ("Phone Sync"), with a one-line explanation ("Serve your
   library to a paired phone over your local network. One way, read only."). When
   on, show the discovered service name / status.
2. **Sync profile**: a picker between **Everything** and **Choose playlists**;
   when "Choose playlists", a multi-select list of playlists (manual + smart +
   folders); an **Include podcasts** toggle; a live **size estimate** ("About
   12.4 GB, 1,203 tracks"). Editing writes through `SyncProfileRepository.set`
   (which bumps `generation`, per 22-5).
3. **Paired devices**: a `List` of `TrustedDevice` rows (device name, paired
   date), each with a **Revoke** action (button / swipe / context menu) that calls
   `revoke`; revocation blocks the device at the TLS layer on its next connection
   (22-2/22-3). Empty state: "No paired phones yet."
4. **Pair a phone**: a button that arms pairing and presents the sheet.

## The pairing sheet (`PhoneSyncPairingSheet`)

A modal sheet with these states (driven by the view model / `PairingUIBridge`):

1. **Waiting**: "Open Bòcan on your phone and tap this Mac." + a spinner. (Pairing
   mode is armed; 120 s window.)
2. **Show code**: a large, grouped six-digit code (`123 456`), "Enter this code on
   your phone." Monospaced, high-contrast, accessible (read the digits
   individually to VoiceOver).
3. **Confirm** (the mandatory human step, `sync-protocol.md` section 4 step 5):
   "Pair with '<deviceName>'? Only accept if the phone shows Paired." showing the
   phone fingerprint's last 8 hex chars, with **Trust** and **Cancel**. Trust
   resolves `requestConfirmation` to `true`. This step is required by the security
   design; do not add a "skip confirmation" option.
4. **Result**: "Paired" (success) or a clear failure ("This code did not match" /
   "Timed out" / "Cancelled"), then dismiss.

Device names are **phone-supplied content**, rendered verbatim (not localized);
everything around them is localized chrome.

## Localization (house rule, non-negotiable)

- Every label, button, column header, status line, error, and accessibility
  label routes through `L10n` in the `UI` catalog: `Text(localized: "…")` /
  `L10n.string("…")` (both pass `bundle: .module`). Keys live in
  `Modules/UI/Sources/UI/Resources/Localizable.xcstrings`.
- No bare user-facing literals: the `no_bare_user_facing_literal` SwiftLint rule
  and `L10nTests` are CI gates. A bare `Text("…")` compiles but resolves against
  `Bundle.main` and silently never localizes.
- After adding keys, run `make pseudolocale` (the en-XA coverage test fails
  otherwise).
- Do **not** add user-facing copy to `App/` (no String Catalog there); keep it in
  `UI`.

## Accessibility

Per the standards: every interactive element has an `accessibilityLabel`; full
keyboard navigation; the six-digit code is reachable and read digit-by-digit; the
Revoke action has a clear label combining device name + action; respects
`reduceMotion` (spinner) and `increaseContrast` (the code).

## Snapshot tests (house rule)

Snapshot every view in light and dark mode at representative sizes, in the `UI`
package (these render a real view tree, so they run via `make test-ui`, not the
host-appless `BocanTests`):

- the pane in three states: disabled, enabled+Everything, enabled+Choose
  playlists with a couple selected and a size estimate.
- the paired-devices list: populated and empty.
- the pairing sheet in each of its four states (waiting, show-code, confirm,
  result-success, result-failure).

Drive them with a fake view model (fixture `TrustedDevice`s, a fixed code, a
canned size estimate) so snapshots are deterministic. No real server, no network.

## Tests beyond snapshots

- View-model logic: toggling enabled calls start/stop; editing the profile writes
  through and updates the size estimate; revoke removes a row; the
  `PairingUIBridge` callbacks move the sheet through its states; declining
  confirmation returns `false` and ends pairing.
- `L10nTests` passes (no bare literals); `make pseudolocale` green.

## Context7 lookups

- use context7: SwiftUI sheet presentation state machine; macOS Settings scene
  form sections; swift-snapshot-testing assertSnapshot light dark

## Acceptance criteria

- [x] A "Phone Sync" pane appears in Settings (registered via `SettingsPage` +
      `SettingsScene`), with enable toggle, profile editor + size estimate, paired
      devices + Revoke, and "Pair a phone".
- [x] The pairing sheet shows the six-digit code and requires the final human
      "Pair with '<device>'?" confirmation; declining does not trust the device.
- [x] Enabling starts the server; disabling stops it; Revoke removes a device and
      blocks it on its next connection.
- [x] Editing the sync profile persists and bumps `generation`; the size estimate
      reflects the selection.
- [x] All new strings localized; `make pseudolocale` green; `no_bare_user_facing_
      literal` and `L10nTests` pass; snapshot tests added for every state in light
      and dark.
- [x] `make format && make lint && make build && make test-ui` green; coverage
      floors met.

## Handoff

Phase 22-9 records the manual real-device end-to-end run driven from this UI
(pair a phone, pick a profile, sync), and finalizes docs. After 22-8 the feature
is user-complete on the Mac side.
