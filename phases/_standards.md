# Cross-Cutting Standards

Every phase assumes these. Re-read once, then obey without being asked.

## Language & Platform

- **Swift 6.0+** with `-strict-concurrency=complete`. No `@preconcurrency` escape hatches except at clearly-marked third-party boundaries, with a TODO and a justification.
- **macOS 26+ deployment target** (Tahoe). Nothing older.
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

Modules depend **only** on lower-level modules (no cycles). Current stack from bottom up:

```
Observability → Persistence → AudioEngine → Metadata → Library → Playback → UI → App
```

A module never imports `AppKit` unless it has no other choice (UI module is the only one expected to).

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

- Each module defines a single `*Error: Error, Sendable` enum (e.g. `AudioEngineError`).
- Errors carry context (URL, underlying error, human-readable reason) — not bare cases.
- No `try?` in production code paths unless an `else { log.warning }` branch also exists.
- `fatalError` is banned outside `#if DEBUG` or truly unreachable `default:` branches.

## Logging

- Use the `AppLogger` facade from `Observability`, never `print`, never raw `os_log`.
- Categories (create the module's category on first use): `app`, `audio`, `library`, `metadata`, `persistence`, `ui`, `network`, `playback`, `cast`, `scrobble`.
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
- Fixtures live in `Tests/Fixtures/` at repo root. Never generate fixtures at test time unless deterministic.
- Tests must not hit the network. Use a `URLProtocol` stub or a protocol-based HTTP client mock.

## Linting & formatting

- `swiftlint` and `swiftformat` configs at repo root.
- CI fails on any lint or format diff.
- Pre-commit hook installs with `make bootstrap` and runs both on changed files.

## Commits & PRs

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`, `build:`, `ci:`, `perf:`). A commit scope matches the module: `feat(audio): schedule gapless handoff`.
- One logical change per commit. PR titles mirror the leading commit.
- Every PR links to its phase file.

## Security & privacy

- **Sandbox on**, hardened runtime on, library validation on.
- Entitlements added per phase, never upfront "just in case".
- No analytics without explicit opt-in. MetricKit (which stays on-device) is fine.
- Secrets never in the repo. `.env` is gitignored; CI uses GitHub Actions secrets.
- Sensitive file access goes through `SecurityScope` helper (Phase 3) — never raw `URL.startAccessingSecurityScopedResource()` scattered around.

## Performance baselines

- App cold launch < 1.5s on an M-series Mac.
- Library view renders 10k tracks at 60fps scroll.
- Scrub / seek latency < 50ms.
- Idle CPU < 1% while paused.
- Idle CPU < 5% while playing a local file (no visualizer).

## Accessibility

- Every interactive element has an `accessibilityLabel`.
- Full keyboard navigation. No mouse-only actions.
- VoiceOver rotor reaches every meaningful view.
- Respects `reduceMotion`, `increaseContrast`, `differentiateWithoutColor`, `reduceTransparency`.
- Passes Accessibility Inspector audits on key screens.

## Localization

- Use **String Catalogs** (`.xcstrings`) from day one, even if only `en` ships.
- No string literals in views; all via catalogue.
- Dates, numbers, durations via `Formatter` / `Duration.formatted`.

## Context7

Add `use context7` to every prompt that touches evolving APIs. Explicit lookups are listed per phase.

## What "done" means

A phase is done when:

1. Every acceptance-criteria box in the phase file is ticked.
2. `make lint && make test-coverage` is green.
3. CI is green on the PR.
4. The phase's "Handoff" contract is honoured (the next phase's prerequisites hold).
5. Nothing marked `TODO(phase-NN)` remains.
