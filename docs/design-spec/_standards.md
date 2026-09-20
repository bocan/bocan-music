# Cross-Cutting Standards

Every ADR assumes these. Re-read once, then obey without being asked.

## Language & Platform

- **Swift 6.0+** with `-strict-concurrency=complete`. No `@preconcurrency` escape hatches except at clearly-marked third-party boundaries, with a TODO and a justification.
- **macOS 15+ deployment target** (Sequoia). Nothing older.
- **Xcode 16+**.
- **SwiftUI** primary; reach for `NSViewRepresentable`/`NSHostingController` only when SwiftUI genuinely cannot deliver. Document every drop-down to AppKit with a one-line comment explaining why.
- **SPM only**. No CocoaPods, no Carthage, no manually-vendored xcframeworks unless they are the only option (e.g. FFmpeg binary artifacts).

## Module layout

Every feature is a Swift Package under `Modules/<Name>/`. A module has:

```
Modules/<Name>/
├── Package.swift
├── Sources/<Name>/
│   └── *.swift
└── Tests/<Name>Tests/
    └── *.swift
```

Modules depend **only** on lower-level modules (no cycles). The dependency graph is no longer a single chain; feature modules fan out from the foundation layers.

Current internal-module dependencies:

| Module        | Depends on                                                                                |
|---------------|-------------------------------------------------------------------------------------------|
| Observability | (none)                                                                                    |
| AudioEngine   | Observability                                                                             |
| Metadata      | Observability                                                                             |
| Acoustics     | Observability                                                                             |
| Persistence   | Observability                                                                             |
| Subsonic      | Observability, Persistence                                                                |
| SyncServer    | Observability, Persistence, AudioEngine, Library, Metadata, Podcasts (AudioEngine edge: ADR-088 transcoding) |
| Library       | Observability, Persistence, Metadata, Acoustics                                           |
| Playback      | Observability, Persistence, AudioEngine                                                   |
| Scrobble      | Observability, Persistence, Playback                                                      |
| UI            | Observability, Persistence, AudioEngine, Library, Playback, Scrobble, Subsonic, Acoustics |
| App           | UI (transitively pulls in everything else)                                                |

Read this top-to-bottom before adding a `.package(path: ...)` line. Anything that looks like it wants an upward edge (e.g. `Playback` importing `UI`) is a sign the abstraction lives in the wrong layer; lift the shared type into one of the lower modules instead.

UI is the only module that imports `AppKit`. A lower module that wants an AppKit event (system wake, app activation) exposes a plain method and the `App` target subscribes and calls it; `SubsonicConnectionMonitor.wakeAll()` is the model. The one exception is `NowPlayingCentre` in `Playback`, because the request handler of `MPMediaItemArtwork` must return an `NSImage` on macOS. Enforced by `Scripts/audit-appkit-imports.py` from `make lint`: any other file needs an entry with a reason in `Scripts/audit-appkit-imports-allowlist.txt`.

## Naming

- App display name: **Bòcan Music**
- Binary / bundle / package / repo / module prefix: `bocan` (lowercase, ASCII)
- Bundle ID: `io.cloudcauldron.bocan`
- Type prefix: none. Swift modules namespace types.
- Log subsystem: `io.cloudcauldron.bocan`

## Concurrency

- Public APIs that do async work are `async throws` and annotated `Sendable` where relevant.
- Long-lived state is owned by `actor`s, not classes with locks.
- `@MainActor` everything touching SwiftUI view state.
- No `DispatchQueue.global().async` in new code. Use `Task` or `TaskGroup`.
- Cancellation is respected: every loop over an `AsyncSequence` or long operation checks `Task.checkCancellation()`.

## Error handling

- Each module defines one public `*Error: Error, Sendable` enum per domain area (e.g. `AudioEngineError`; `Library` has one each for scanning, playlists, editing, playlist I/O, smart playlists and deep dive). A small module has one. An internal error enum is allowed when it is wrapped into a public one before it crosses the module boundary.
- Errors carry context (URL, underlying error, human-readable reason), not bare cases. No ad hoc `struct Foo: Error {}`: a failure becomes a case of the area's enum.
- `try?` only for the allowlisted idioms (a cancellation-checked `Task.sleep`, `defer { try? handle.close() }`, remove-if-present, directory pre-creation, a file-attribute read with a fallback, a decode whose fallback is the documented contract). Every other error is either recovered and logged (`do { try ... } catch { log.warning("op.failed", [...]) }`) or propagated with `try`. A user action that fails reaches the user; a value written to the database or sent on the wire is never derived from a swallowed error. For a one-line recovery, `Observability.logged(_:_:context:_:)` is the sanctioned helper. Enforced by `Scripts/audit-try-optional.py` from `make lint`: a site outside the idiom patterns needs an entry with a reason in `Scripts/audit-try-optional-allowlist.txt`. See `docs/audits/try-optional-audit.md`.
- `fatalError` is banned outside `#if DEBUG` or truly unreachable `default:` branches. The one named exception is the body of an `@available(*, unavailable) required init(coder:)`, which the compiler already makes uncallable. A failure that can happen at run time (an allocation, a missing directory) throws, returns `nil` or falls back, and logs.

## Logging

- Use the `AppLogger` facade from `Observability`, never `print`, never raw `os_log`.
- Categories (create the module's category on first use): `app`, `audio`, `library`, `metadata`, `persistence`, `ui`, `network`, `playback`, `podcasts`, `scrobble`, `subsonic`, `sync`.
- Every async op: `log.debug("op.start", [...])` / `log.debug("op.end", ["ms": duration])`.
- Every caught error: `log.error("op.failed", ["reason": ..., "error": String(reflecting: err)])`.
- **Redact** anything matching keys in `Observability.sensitiveKeys` (`apiKey`, `token`, `sessionKey`, `password`, `authorization`). Add to that list as you add integrations.

## Testing

- **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`) for unit + integration tests. `XCTest` only where a framework forces it (e.g. XCUITest).
- **80% line coverage minimum** per module, enforced in CI.
- Every public function has at least one `@Test`.
- Every bug fix begins with a failing regression test.
- UI: **swift-snapshot-testing** for every view, in light and dark mode, at representative sizes.
- Property-based tests (swift-testing's `arguments:` or hand-rolled) for anything with interesting algebra (queue ops, criteria compiler, LRC parser, etc.).
- Fixtures live alongside the module that uses them, under `Modules/<Module>/Tests/<Module>Tests/Fixtures/` (e.g. `Modules/Metadata/Tests/MetadataTests/Fixtures/`). Keep a fixture in the SPM package whose tests consume it so `swift test` and the per-module `make test-<module>` gate pick it up as a bundle resource. Never generate fixtures at test time unless deterministic.
- Tests must not hit the network. Use a `URLProtocol` stub or a protocol-based HTTP client mock.

## Linting & formatting

- `swiftlint` and `swiftformat` configs at repo root.
- CI fails on any lint or format diff.
- Pre-commit hook installs with `make bootstrap` and runs both on changed files.

## Commits & PRs

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`, `build:`, `ci:`, `perf:`). A commit scope matches the module: `feat(audio): schedule gapless handoff`.
- One logical change per commit. PR titles mirror the leading commit.
- Every PR links to its ADR.

## Security & privacy

- **Sandbox on for the Debug build**, hardened runtime on for both builds, library validation on. The shipped release build is unsandboxed: `Scripts/embed-deps.sh` re-signs it without entitlements, and sandboxing it now would move every user into an empty container (see `docs/GOTCHAS.md`, "The debug build and the installed release app use different libraries"). File access goes through the `SecurityScope` helper in both builds.
- Entitlements added per ADR, never upfront "just in case".
- No analytics without explicit opt-in. MetricKit (which stays on-device) is fine.
- Secrets never in the repo. `.env` is gitignored; CI uses GitHub Actions secrets.
- Sensitive file access goes through `SecurityScope` helper (ADR-004) — never raw `URL.startAccessingSecurityScopedResource()` scattered around.

## Performance baselines

- App cold launch < 1.5s on an M-series Mac.
- Library view renders 10k tracks at 60fps scroll.
- Scrub / seek latency < 50ms.
- Idle CPU < 1% while paused.
- Idle CPU < 5% while playing a local file (no visualizer).

## Accessibility

- Every interactive element has an `accessibilityLabel`.
- Every new interactive control ships with a stable `A11y` accessibility
  identifier, enforced by the E2E crawler audit in `make test-e2e`.
- Every new interactive control ships with localized `.help()` text, or an
  allowlist entry saying why not. The policy is below.
- Full keyboard navigation. No mouse-only actions.
- VoiceOver rotor reaches every meaningful view.
- Respects `reduceMotion`, `increaseContrast`, `differentiateWithoutColor`, `reduceTransparency`.
- Passes Accessibility Inspector audits on key screens.

### Hover text

A control the user can click, switch or choose from carries `.help()`, and the
text is a hover affordance, not a second copy of the label. It says what the
control does, or what changes if it is switched, or what the user gets back.
"Reshuffle the sample" on a Refresh button earns its place; "Refresh" on a
Refresh button does not, and is worse than nothing, because it teaches the user
that hovering tells them nothing.

Which controls: `Button`, `Toggle`, `Picker`, `Slider` and `Menu`, in
`Modules/UI/Sources` and `App/`. `Scripts/audit-help-text.py` finds them.

**Exempt by rule, not by allowlist.** macOS renders no tooltip inside an open
menu, alert or dialog, so `.help()` there is dead code. The audit already skips
`Menu` and `CommandMenu` bodies, `CommandGroup`, `.contextMenu`,
`confirmationDialog`, `.alert`, `.swipeActions`, `Picker` option closures, the
dock menu, and anything in a `#Preview` body or a test source. None of this
needs re-arguing at a call site.

**The allowlist is the other right answer.** A control whose label is already
the whole story does not get redundant hover text; it gets a line in
`Scripts/audit-help-text-allowlist.txt` with a reason, keyed
`<relative-path>|<normalized first line of the call site>`. Line numbers are
deliberately not in the key, so ordinary edits do not churn it. The list is
meant to stay short enough to read in one sitting: if it grows past a screen,
the policy is being avoided rather than applied.

**The text is user-facing copy.** In the `UI` module that means
`L10n.string("…")` with a key in
`Modules/UI/Sources/UI/Resources/Localizable.xcstrings`, and `make pseudolocale`
re-run afterwards, or the en-XA coverage test fails. A bare literal compiles,
renders in English and silently never localizes.

Enforced by `Scripts/audit-help-text.py` from `make lint`, in strict mode since
#509: a control that ships without hover text and without an allowlist entry
fails the build, locally and in CI. The audit has its own hermetic tests in
`Scripts/tests/audit-help-text-test.sh`, which `make test-scripts` and the CI
`scripts` job both run. The backlog this replaced, counted per area, is
`docs/audits/help-text-audit.md` (#501).

## Localization

- Use **String Catalogs** (`.xcstrings`) from day one, even if only `en` ships.
- No string literals in views; all via catalogue.
- Dates, numbers, durations via `Formatter` / `Duration.formatted`.

## Context7

Add `use context7` to every prompt that touches evolving APIs. Explicit lookups are listed per ADR.

## What "done" means

An ADR is done when:

1. Every acceptance-criteria box in the ADR is ticked.
2. `make format && make lint && make build && make test-{whatever module you changed}` is green.
3. CI is green on the PR.
4. The ADR's "Handoff" contract is honoured (the next ADR's prerequisites hold).
5. Nothing marked `TODO(ADR-NNN)` remains.
