# Phase 24 Maintainability Audit -- Close-out

A ten-session, bottom-up sweep of the whole codebase for duplication worth
sharing. The deliverable was never "fewer lines at any cost" -- it was a
smaller, less-repetitive codebase *where compression genuinely helps*, plus a
recorded decision for every candidate considered (including the ones left
alone). The full row-by-row record is in [findings-ledger.md](findings-ledger.md).

## Totals

- **Net lines removed:** ~187 (behavior-preserving; every commit kept the gates green).
- **Clusters triaged:** 72.
  - **Consolidated:** 5
  - **Tolerated:** 55 (below the rule of three / idiomatic / already single-source)
  - **Rejected:** 12 (consolidation considered and judged worse -- the recorded "don't")
  - **Deferred-then-resolved:** 8 cross-module candidates, all resolved in Session 10 (0 left open).
- **New shared helpers introduced:** 4 (plus one Subsonic-internal pair).

The headline is the ratio: 5 consolidations against 67 leave-alones. That is the
audit working as intended -- finding duplication is easy; the skill is deciding
what *not* to touch.

## What got consolidated

| Helper | Module | What it folded | Session / commit |
|--------|--------|----------------|------------------|
| `Database.fetchOne(_:id:entity:)` | Persistence | 7 repositories' fetch-by-id-or-throw bodies | S1 `083de5a` |
| `ListenBrainzCompatibleTransport` | Scrobble | ListenBrainz + Rocksky `submit-listens` payload + POST engine | S4 `889d78d` |
| `SubsonicService.withClient` / `withCapabilityGatedClient` | Subsonic | 20 endpoint methods' `requireClient` + `SwiftSonicError`->`SubsonicError` wrapper | S5 `cd7b4fb` |
| `View.loadErrorAlert(_:message:)` | UI/Common | 12 Subsonic browse views' load-error alert | S7 `c82de1a` |
| `MTLDevice.makeAlphaBlendedPipeline(...)` | UI/Visualizers/Metal | 4 renderers' identical alpha-blend pipeline setup | S9 `06fc680` |

## Shared-surface catalogue

The reusable surface the audit created or confirmed. The next feature reuses
these instead of re-copying. (Full annotations in the ledger's "Shared surface"
table.)

**Created by the audit**
- `Database.fetchOne(_:id:entity:)` -- Persistence (fetch by primary key or throw `.notFound`).
- `ListenBrainzCompatibleTransport` -- Scrobble (ListenBrainz-protocol payload + POST/error-map).
- `View.loadErrorAlert(_:message:)` -- UI/Common (one-button error alert bound to a VM's `errorMessage`).
- `MTLDevice.makeAlphaBlendedPipeline(...)` -- UI/Visualizers/Metal (standard straight-alpha render pipeline).
- `SubsonicService.withClient` / `withCapabilityGatedClient` -- Subsonic-internal request wrapper.

**Confirmed single-source (pre-existing; do not re-implement)**
- Persistence: `SQL.escapeFTSTerm` / `escapeLIKETerm`.
- Library: `CoverArtCache` (cover-art on-disk hash/path scheme); `M3UReader`/`M3UWriter` playlist path/decode helpers.
- Scrobble: `LastFmCompatibleTransport`.
- AudioEngine: `Internal/FormatConverter` (format conversion single-source).
- UI/Common: `EmptyState` / `LoadingState` / `ErrorState`; `Formatters` (duration/byte/date display).
- UI/Components: `CollectionCard` / `CollectionCardGrid` (carries #349 scroll-restore) / `CoverMosaicGenerator`.
- UI/Browse: `SortMenu` / `SortMenuOption`; `SubsonicSongRow`.
- UI/MetadataEditor: `TagFieldRow`. UI/Playlists: `PlaylistHeader`.
- UI/Visualizers/Metal: `MetalVisualizer` protocol, `MetalRendererConfig`, `MetalShaderLibrary`, `PaletteRampLUT`, `FrameRing`, `PolylineRibbon`, `MetalVisualizerFactory.instantiate`; test harness `MetalOffscreenRenderer` + `TestImage`.

## Top 3 "rejected" decisions -- guidance on when NOT to consolidate

These are the most instructive leave-alones. Future contributors (and future AI
sessions): do not re-litigate these without new information.

1. **A repo-wide `clamped(to:)` helper (S10-4).** ~39 `max(lo, min(hi, x))` sites
   looked like a textbook shared micro-helper. Rejected because it is break-even
   on lines **and actively unsafe**: many sites clamp to a *dynamic* upper bound
   (`max(0, min(count - 1, x))`), and `x.clamped(to: 0...(count - 1))` traps on an
   empty range when `count == 0`. A blanket conversion would introduce crashes for
   zero line reduction. Lesson: a "cleaner" idiom that changes failure semantics is
   not cleaner. If you add `clamped(to:)` later, audit each call site's bounds.

2. **A shared HTTP client module (S10-5).** The `HTTPClient` protocol is
   byte-identical in three modules -- but that duplication is *deliberate and
   documented*: it keeps each networked module self-contained with its own
   `MockHTTPClient` test seam. Hoisting a 3-line protocol to a new module would
   couple four modules and pollute the DAG floor with a networking concept, to save
   ~7 lines. The genuinely different parts (auth: none / HMAC / `api_sig` / `Token`;
   three error enums; per-family transports) are already factored where they belong.
   Lesson: sharing a trivial skeleton is not worth new cross-module coupling; a
   documented, intentional mirror is a design choice, not debt.

3. **The AppRoot banner component (S6-3).** Two launch banners shared ~30 lines of
   `.safeAreaInset` chrome. A shared `InsetBanner` was written, built, and tested
   green -- then **measured at net +18 lines** for a 5-param + `ViewBuilder` +
   `AnyShapeStyle` interface at only 2 copies, and reverted. Lesson: build-and-
   measure beats eyeballing; a reusable-component narrative does not override a
   failed line-delta gate at two copies.

Runners-up worth reading: the S6 view-model `withLoading` protocol (needed
settable `isLoading` across two observation models -> API change), and the S7
Subsonic refresh-toolbar (varied action/`disabled`/`help` -> config bag).

## Intentionally left for later

- **Minor UI tidy:** a few inline `%d:%02d` duration strings in `UI/Browse` could
  route through `UI/Common/Formatters` (S10-8). Not done here: it is a within-UI
  cleanup, not the cross-module win originally imagined, and each site is a one-liner.
- **Dead code:** `CollectionModeToggle` has zero references and `ErrorState` is
  unused (Browse uses `.alert` + `ContentUnavailableView`) -- see S7-6. Removing
  dead code is a separate concern from the dedup audit; flagged for a future tidy.
- **`DSPChain`'s private `clamped`** may be promoted opportunistically if a change
  touches that area, but not as a repo-wide sweep (see rejection #1).

## Method notes for the next audit

- **Bottom-up paid off.** By the time the UI sessions ran, the shared-surface table
  already listed lower-module helpers to dedup against, and the cross-module
  candidates were fully mapped before Session 10 had to decide them.
- **Measure before extracting.** Two of the most confident-looking consolidations
  (S6 banner, and the S10 clamp/HTTP items) failed on measurement. The `git diff
  --numstat` net and the interface-size check caught them.
- **"Kept-with-reason" is a deliverable, not a cop-out.** 67 of 72 clusters were
  left alone; each has a one-line rationale so the decision is never re-made blind.
