# Phase 21-12-c: Support this show (funding link with confirmation)

> Depends on: `phase21-12-a-namespace-supplement.md` (the supplementary `podcast:`
> parser that populates `Podcast.fundingURL` from `podcast:funding` and adds the
> new `Podcast.fundingText` label column). Also builds on
> `phase21-12-podcast-features.md` (the contract) and `phase21-9-ui-episodes.md`
> (the `PodcastShowView` header + `moreMenu` this slice extends).
>
> Read `_standards.md` and `phase21-0-overview.md` first, then the contract.
> Touches **UI** only. No new migration, no new entitlement, no seam change.

## Goal

Add a "Support this show" affordance to the subscribed-show surface that opens the
show's `podcast:funding` URL in the user's default browser, but only after a
confirmation dialog that names the destination host. The URL is untrusted feed
content, so the affordance appears only when a funding URL is present and the open
is gated on an `http`/`https` scheme check.

## Non-goals

- No `podcast:value` / payments / in-app tipping (deferred research, per the
  contract Non-goals).
- No per-episode funding (the `podcast:funding` tag is channel-level here).
- No new App-side seam: opening an external URL is already done in `UI` via
  `NSWorkspace.shared.open` (see `PodcastShowView.swift` "Go to Website" and
  `EpisodeList.swift`), so this slice follows that precedent rather than adding a
  method to `PodcastActions`.
- No change to `Persistence`, `Podcasts`, or the seam protocols in
  `PodcastSeams.swift`.

## Outcome shape (file tree)

```
Modules/UI/Sources/UI/Browse/Podcasts/
  PodcastShowView.swift          (edited: header button + moreMenu item + confirm dialog)
  FundingLink.swift              (new: host extraction + http/https guard, pure helpers)
Modules/UI/Sources/UI/Resources/
  Localizable.xcstrings          (edited: new L10n keys; run `make pseudolocale`)
Modules/UI/Tests/UITests/ViewModelTests/
  FundingLinkTests.swift         (new: guard + host-extraction unit tests)
  PodcastFundingConventionTests.swift  (new: #filePath source-convention test)
```

## Implementation

### Surface (where it appears)

`PodcastShowView` already holds `vm.currentShow: Podcast?` and renders a
`.primaryAction` toolbar with `moreMenu`. One computed value gates both entry
points:

```swift
// Nil unless the show has a usable (http/https) funding link.
private var fundingLink: FundingLink? {
    FundingLink(rawURL: vm.currentShow?.fundingURL, label: vm.currentShow?.fundingText)
}
```

1. **Show header button.** When `fundingLink != nil`, a bordered button
   (SF Symbol `heart.circle`). Its label is the feed-supplied `fundingText` when
   present (`Text(verbatim:)`, it is feed content), else the localized fallback
   `Text(localized: "Support This Show")`. It sets
   `@State private var pendingFunding: FundingLink?` to trigger the dialog and
   carries `.accessibilityLabel(L10n.string("Support this show in your browser"))`.
   It does not open anything directly.
2. **`moreMenu` item.** A parallel `Button` in the existing `Menu` (next to
   "Go to Website"), guarded by the same `if let link = fundingLink`, also setting
   `pendingFunding = link`: a discoverable second entry point, one shared dialog.

### Confirmation

One `.confirmationDialog` (matching the existing unsubscribe dialog idiom in the
same file) bound to `item: $pendingFunding` (SwiftUI presents on non-nil):

```swift
.confirmationDialog(
    L10n.string("Open this funding link?"),
    isPresented: Binding(get: { pendingFunding != nil },
                         set: { if !$0 { pendingFunding = nil } }),
    titleVisibility: .visible,
    presenting: pendingFunding
) { link in
    Button(L10n.string("Open in Browser")) { link.open() }
    Button(L10n.string("Cancel"), role: .cancel) { pendingFunding = nil }
} message: { link in
    // Host is parsed and safe to show; format string interpolates it.
    Text(L10n.string("This opens \(link.host) in your default browser."))
}
```

The message shows the parsed destination **host** (not the full URL: a long or
crafted path should not be the thing the user reads). Cancel is the escape action.

### Open + safety (the FundingLink helper)

`FundingLink` is a small `Sendable` value type that does all parsing and the open,
so the view stays declarative and the logic is unit-testable without a view tree.
Its failable initializer is the trust boundary:

```swift
struct FundingLink: Equatable, Sendable {
    let url: URL          // already validated http/https
    let host: String      // parsed, lowercased, for display
    let label: String?    // feed-supplied fundingText, verbatim; nil if absent

    /// Fails for nil/empty input, unparseable URLs, or any non-http/https scheme.
    init?(rawURL: String?, label: String?) {
        guard let rawURL, let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        self.url = url
        self.host = host
        self.label = (label?.isEmpty == false) ? label : nil
    }

    // UI already opens external links this way; no new entitlement needed.
    @MainActor func open() { NSWorkspace.shared.open(url) }
}
```

Decision (open in UI vs an App seam): **open in UI** via `NSWorkspace.shared.open`.
Justification: the `UI` module already imports AppKit and already opens external
links exactly this way in `PodcastShowView.swift` and `EpisodeList.swift`, the
contract explicitly says funding uses `NSWorkspace.open` with no new entitlement
(`phase21-12-podcast-features.md`, "Sandbox"), and routing this through a new
`PodcastActions` method would add a seam for zero benefit and break the "no
gold-plating / mirror existing wiring" rule. No upward import is involved.

## Context7 lookups

None needed. `NSWorkspace.shared.open(_:)`, SwiftUI `.confirmationDialog`, and
`URL.host()` are stable system APIs already used in this codebase; the existing
call sites in `PodcastShowView.swift` and `EpisodeList.swift` are the pattern to
copy. (If `confirmationDialog(presenting:)` overload details are in doubt, the
`presenting:`/`message:` shape mirrored above is the one already shipping in
`PodcastShowView`'s unsubscribe dialog.)

## Test plan

No network in any test (this slice does no networking).

- **`FundingLinkTests` (pure unit, no view tree):**
  - `init?` returns nil for nil, empty string, and whitespace input.
  - Rejects non-http schemes: `javascript:alert(1)`, `file:///etc/passwd`,
    `ftp://host/x`, `mailto:a@b.com` all yield nil (the trust boundary).
  - Accepts `http://` and `https://`; `host` is the lowercased host
    (`HTTPS://Example.COM/give` -> host `example.com`).
  - Rejects a scheme-relative / hostless URL (`https:///path`) -> nil.
  - `label` is carried verbatim when present and normalized to nil when empty.
- **`PodcastFundingConventionTests` (source-convention, reads via `#filePath`):**
  read `PodcastShowView.swift` as a string and assert it contains the gating
  (`fundingLink`), the confirm strings (`"Open this funding link?"`,
  `"Open in Browser"`, `"Cancel"`), the accessibility key
  (`"Support this show in your browser"`), and the verbatim-label path
  (`Text(verbatim:`), proving the affordance and dialog exist and are gated. This
  follows the established host-less UI test idiom (e.g.
  `PodcastsSidebarConventionTests`, `LogConsoleViewConventionTests`).
- **L10n:** `L10nTests` covers the new keys; run `make pseudolocale` so the en-XA
  coverage test passes.

## Acceptance criteria

- [ ] A subscribed show with a `podcast:funding` URL shows a "Support this show"
      button in the header and a matching item in the `moreMenu`.
- [ ] A show with no funding URL shows neither (the affordance is fully gated on
      `fundingLink != nil`).
- [ ] The button label is the feed's `fundingText` (verbatim) when present, else
      the localized `Support This Show`.
- [ ] Tapping the affordance shows a confirmation dialog naming the destination
      host, with Cancel and Open in Browser; only Open in Browser opens the URL.
- [ ] Only `http`/`https` URLs are ever opened; any other scheme produces no
      affordance (the `FundingLink` initializer fails).
- [ ] The button has an `accessibilityLabel`; all chrome is localized;
      `make pseudolocale` has been run.
- [ ] `make test-ui` green; no lint (incl. `file_length` on `PodcastShowView`) or
      format warnings.

## Gotchas

- **The URL is untrusted feed content.** Never open it without the scheme guard;
  the guard lives in `FundingLink.init?`, not scattered at call sites. A bare
  `URL(string:)` + `NSWorkspace.open` would happily fire `file:` or
  `javascript:` schemes.
- **Only `http`/`https`.** This is a hard requirement from the contract; the unit
  tests pin the rejected schemes so a future refactor cannot loosen it silently.
- **Show the host, not the full URL.** A long or deceptive path should not be the
  primary thing the user reads in the dialog; `URL.host()` is the parsed,
  trustworthy bit.
- **No new entitlement.** `NSWorkspace.shared.open` works under the existing
  sandbox; do not add an entitlement "just in case" (it would fail review and the
  sibling "Go to Website" feature already proves it is unnecessary).
- **`fundingText` is feed content**, rendered with `Text(verbatim:)` (or
  `Text(_:)` on an interpolated host) and never localized; only the fallback and
  the dialog chrome route through `L10n`.
- **`PodcastShowView.swift` is near the 500-line `file_length` cap.** Keep the
  helper in its own `FundingLink.swift`; if the view file tightens, trim a comment
  rather than adding a `swiftlint:disable`.
- **Sub-phase a is the prerequisite.** `Podcast.fundingText` does not exist until
  `phase21-12-a` lands; if this slice is built first, `fundingLink` can read
  `fundingURL` alone and treat the label as always-nil, but prefer ordering after
  a so the verbatim-label path is real.

## Handoff

With this slice, parsed funding URLs (from sub-phase a) become a user-facing,
confirmation-gated "Support this show" action. It shares the external-open path
with the existing "Go to Website" affordances and introduces no new seam, so the
remaining `phase21-12-{d..i}` sub-phases are unaffected. If a future
`podcast:value` slice ever lands, it would extend (not replace) this surface.
