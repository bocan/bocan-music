# Phase 0 — Foundations

> Prerequisites: none. This is the chassis.
>
> Read `phases/_standards.md` first. Every later phase assumes this one is finished.

## Goal

A repo that compiles and launches an empty "Hello, Bòcan" window, with CI, logging, linting, testing, coverage, and release scaffolding all working. **No product features.** If you are tempted to add a feature here, stop.

## Non-goals

- Any audio.
- Any UI beyond a placeholder window.
- Any persistence.
- Any dependency you don't need for Phase 0 itself.

## Outcome shape

```
bocan-music/
├── App/
│   ├── BocanApp.swift           # @main
│   └── RootView.swift            # "Hello, Bòcan" placeholder
├── Modules/
│   └── Observability/            # Swift Package
│       ├── Package.swift
│       ├── Sources/Observability/
│       │   ├── AppLogger.swift
│       │   ├── LogCategory.swift
│       │   ├── Telemetry.swift
│       │   └── Redaction.swift
│       └── Tests/ObservabilityTests/
│           └── AppLoggerTests.swift
├── Tests/                        # Cross-module integration tests (empty for now, keep folder)
├── UITests/
│   └── SmokeTests.swift          # Launches app, asserts "Hello" label exists
├── Resources/
│   ├── Assets.xcassets           # App icon placeholder (1024 gradient is fine)
│   ├── Info.plist
│   └── Bocan.entitlements
├── Scripts/
│   ├── coverage-report.sh        # Parses xcresult, fails if < 80%
│   └── build-release.sh          # Local signed build
├── .github/
│   ├── workflows/
│   │   ├── ci.yml
│   │   └── release.yml
│   ├── CODEOWNERS
│   ├── dependabot.yml
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── pull_request_template.md
├── phases/                       # This folder of specs (already exists)
├── .gitignore                    # Swift/Xcode/macOS
├── .gitattributes                # LF, text=auto
├── .editorconfig
├── .swiftlint.yml
├── .swiftformat
├── Brewfile
├── Makefile
├── Package.swift                 # Workspace-level if you use an SPM-first layout; optional
├── Bocan.xcodeproj/              # or .xcworkspace
├── CHANGELOG.md                  # Seeded, empty sections
├── CONTRIBUTING.md
├── DEVELOPMENT.md                # Local dev setup
├── LICENSE                       # Pick one, MIT/Apache-2.0 suggested
├── README.md
├── SECURITY.md
└── spec.md                       # Already there
```

## Implementation plan

1. **Xcode project**
   - macOS App, SwiftUI lifecycle, Swift Testing bundle, UITest bundle.
   - Bundle ID `io.cloudcauldron.bocan`, display name `Bòcan`, executable `bocan`.
   - Set `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 14.0`.
   - Enable Hardened Runtime. Enable App Sandbox.
   - `Bocan.entitlements` — initial contents:
     - `com.apple.security.app-sandbox = true`
     - `com.apple.security.files.user-selected.read-write = true`
     - `com.apple.security.files.bookmarks.app-scope = true`
   - `Info.plist`: `LSApplicationCategoryType = public.app-category.music`, `NSHumanReadableCopyright`, `CFBundleDisplayName = Bòcan`.
   - Do **not** add `NSMusicFolderUsageDescription` yet — add in Phase 3 when the scanner lands.

2. **.gitignore** (Swift/Xcode): ignore `.build/`, `DerivedData/`, `xcuserdata/`, `*.xcuserstate`, `Package.resolved` *inside* nested modules only (keep root one), `.DS_Store`, `build/`, `coverage.xml`, `.env`.

3. **.editorconfig** — 4-space indent for Swift, 2-space for YAML/JSON/Markdown tables, LF line endings, UTF-8.

4. **SwiftLint config (`.swiftlint.yml`)**
   - Enable at least: `force_cast`, `force_try`, `force_unwrapping`, `implicit_return`, `redundant_optional_initialization`, `unused_import`, `unused_declaration`, `explicit_init`, `first_where`, `last_where`, `contains_over_filter_is_empty`, `empty_count`.
   - `line_length: 140` (warn), 180 error.
   - `type_name` / `identifier_name`: allow 2-char types, set reasonable bounds.
   - `excluded:` `.build`, `DerivedData`, `Tests/Fixtures`.

5. **SwiftFormat config (`.swiftformat`)**
   - `--swiftversion 6.0`, `--self insert`, `--stripunusedargs closure-only`, `--wraparguments before-first`, `--wrapparameters before-first`, `--indent 4`.

6. **Brewfile**
   ```ruby
   brew "swiftlint"
   brew "swiftformat"
   brew "xcbeautify"
   brew "ffmpeg"        # needed in Phase 1, install now
   brew "create-dmg"    # needed in Phase 16, install now
   brew "gh"            # nice for the Actions workflow
   ```

7. **Makefile** — use exactly the targets in `spec.md` section Phase 0 step 3. Additionally:
   - `make install-hooks` installs a pre-commit hook (copy `Scripts/pre-commit` → `.git/hooks/`).
   - `make doctor` prints tool versions; CI calls this too.
   - `make open` opens the Xcode project.
   - Every target with a `## description` comment appears in `make help`.

8. **Pre-commit hook (`Scripts/pre-commit`)** — runs `swiftformat --lint` and `swiftlint` on staged `.swift` files. Bypassable only with `--no-verify`; log a warning commit-message-template telling reviewers to reject that.

9. **Observability module**
   - `LogCategory` enum: `.app`, `.audio`, `.library`, `.metadata`, `.persistence`, `.ui`, `.network`, `.playback`, `.cast`, `.scrobble`. One case per expected category even though most aren't used yet — centralises the list.
   - `AppLogger` actor (or a `Sendable` struct wrapping `os.Logger`; actor if you want to serialise):
     ```swift
     public struct AppLogger: Sendable {
         public init(subsystem: String = "io.cloudcauldron.bocan", category: LogCategory)
         public func trace(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:])
         public func debug(_ message: ..., _ fields: ...)
         public func info(...)
         public func notice(...)
         public func warning(...)
         public func error(...)
         public func fault(...)
     }
     ```
     `fields` is rendered as a stable key-sorted `k=v` suffix. Values matching `Redaction.sensitiveKeys` (`apiKey`, `token`, `sessionKey`, `password`, `authorization`, `cookie`, `set-cookie`) are replaced with `<redacted>`.
   - `AppLogger.make(_:)` convenience: `AppLogger.make(.audio)`.
   - `Telemetry` namespace:
     - `counter(_ name: String, by: Int = 1, tags: [String: String] = [:])`
     - `timer(_ name: String, tags: ...) -> (end: @Sendable () -> Void)`
     - Implementations wrap OSSignposter for Instruments integration; expose noop variant used in tests.
   - `MetricKitListener` — subscribes to `MXMetricManager.shared`, forwards payloads to `AppLogger(.app)` at `.notice`. Gate behind `#if os(macOS)` (MetricKit is macOS 12+ only).

10. **App target**
    - `BocanApp` with a single `WindowGroup` containing `RootView { Text("Hello, Bòcan") }`.
    - Log `app.launched` at `.info` via `AppLogger.make(.app)`.
    - Set an app-accent placeholder colour in `Assets.xcassets`.

11. **CI — `.github/workflows/ci.yml`**
    - Triggers: `pull_request`, `push: main`.
    - Runner: `macos-15` (pin by label; do not use `macos-latest`).
    - Steps:
      1. `actions/checkout@v4`
      2. Cache SPM: `~/Library/Developer/Xcode/DerivedData/**/SourcePackages` and `~/.swiftpm`.
      3. Install Brewfile (`brew bundle`).
      4. `make doctor`.
      5. `make lint`.
      6. `make test-coverage` piped through `xcbeautify`.
      7. Upload `build/TestResults.xcresult` as artefact.
      8. Fail if coverage < 80% (logic in `Scripts/coverage-report.sh` using `xcrun xccov view --report --json`).

12. **Release — `.github/workflows/release.yml`**
    - Trigger: push tag `v*.*.*`.
    - Steps:
      1. Checkout with `fetch-depth: 0` (needed for changelog).
      2. Import signing cert from secret (`DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`) into a temporary keychain.
      3. `xcodebuild archive` for Release.
      4. Export `.app` with Developer ID.
      5. `xcrun notarytool submit --wait` using `APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD` secrets.
      6. `xcrun stapler staple`.
      7. `create-dmg` with a nice background (placeholder PNG for now).
      8. Generate changelog section from Conventional Commits since previous tag.
      9. `softprops/action-gh-release@v2` attaches DMG + changelog to the GitHub Release.
    - The workflow must run on a **clean fresh VM** — do not assume host state.

13. **Dependabot (`.github/dependabot.yml`)** — weekly updates for `github-actions` and `swift` (root and each `Modules/*`).

14. **CODEOWNERS, PR template, issue templates** — minimal but present.

15. **README.md** — naming section copied verbatim from `spec.md`, badges for CI + coverage, one-line install + run instructions. No feature list yet.

16. **LICENSE** — add one; Apache-2.0 or MIT are both fine. If unsure, Apache-2.0.

17. **SECURITY.md** — how to report security issues privately.

18. **CHANGELOG.md** — "Keep a Changelog" template seeded with `## [Unreleased]` section and `### Added / Changed / Fixed / Removed` subsections.

19. **DEVELOPMENT.md** — prereqs (Xcode version, Homebrew), clone → bootstrap → build → test, pointer to `phases/`.

## Definitions the assistant must produce verbatim

### `LogCategory.swift`

```swift
public enum LogCategory: String, Sendable, CaseIterable {
    case app, audio, library, metadata, persistence, ui, network, playback, cast, scrobble
}
```

### `Redaction.swift`

```swift
public enum Redaction {
    public static let sensitiveKeys: Set<String> = [
        "apiKey", "token", "sessionKey", "password", "authorization",
        "cookie", "set-cookie", "secret", "refreshToken", "accessToken",
    ]

    public static func sanitize(_ fields: [String: Any]) -> [String: String] {
        fields.reduce(into: [:]) { out, kv in
            out[kv.key] = sensitiveKeys.contains(kv.key.lowercased())
                ? "<redacted>"
                : String(describing: kv.value)
        }
    }
}
```

## Context7 lookups

- `use context7 Swift 6 strict concurrency`
- `use context7 os.Logger OSLog structured`
- `use context7 Swift Testing macros`
- `use context7 swift-snapshot-testing`
- `use context7 MetricKit MXMetricManager macOS`
- `use context7 GitHub Actions notarytool macOS`

## Dependencies

None yet (Observability uses only `Foundation`, `os`, `MetricKit`). Do not add `swift-log`; the facade is thin enough in-house.

## Test plan

- `AppLogger` emits each level to OSLog; read back via `OSLogStore` and assert subsystem/category/message.
- `AppLogger` sorts fields deterministically in the rendered suffix.
- `Redaction.sanitize` replaces sensitive keys (case-insensitive) and leaves others untouched.
- `Telemetry.counter` increments a signposter-backed counter (smoke test — OSSignposter has no direct assertion API; at minimum, don't crash).
- `Makefile` targets resolve: a CI job runs `grep -E` over the Makefile asserting every `.PHONY` target listed exists.
- Coverage script fails when given a synthetic xcresult below threshold (unit-test the parser against two fixture JSONs).
- UITest `SmokeTests.testHelloWorld` launches app, finds static text "Hello, Bòcan", passes.

## Acceptance criteria

- [ ] `make bootstrap && make test` passes on a clean clone on Apple Silicon and Intel runners.
- [ ] `make lint` is clean.
- [ ] `make test-coverage` reports ≥ 80% on `Observability`.
- [ ] CI workflow green on a no-op PR.
- [ ] Release workflow dry-runs locally via `act` or on a `workflow_dispatch` branch (tag not required yet, but the file must parse).
- [ ] App launches, window titled **Bòcan**, body reads "Hello, Bòcan".
- [ ] Log lines visible in Console.app filtered by subsystem `io.cloudcauldron.bocan`.
- [ ] All files in the "Outcome shape" tree exist.

## Gotchas

- **App Sandbox + Xcode previews**: previews sometimes fail under sandbox. If that bites, move preview content behind `#if DEBUG` and document.
- **macos-15 runner image**: can drift; pin Xcode version explicitly with `sudo xcode-select -s /Applications/Xcode_16.x.app`.
- **Notarization secrets**: document required secret names in `DEVELOPMENT.md` so future-you doesn't forget.
- **Coverage JSON schema** changes between Xcode versions. Write the parser defensively and log the raw structure if it can't be parsed.
- **`macos-latest` label** aliases shift yearly — use a concrete label.
- **Swift 6 and third-party packages**: most aren't strict-concurrency-clean yet. You don't depend on any here; in later phases expect to add per-target `.unsafeFlags(["-strict-concurrency=minimal"])` for offending packages with a TODO.
- **Bundle display name** with `ò`: ensure the Info.plist is UTF-8 (Xcode defaults to binary; force XML format if you hand-edit).
- **`@main` attribute** requires an `App` type whose name is unique across the target. Naming the type `BocanApp` avoids collisions with SwiftUI's `App` protocol at call sites.
- **Hardened Runtime + FFmpeg** will bite in Phase 1 (disable library validation for FFmpeg dylib, or statically link). Don't do anything about it now — just be aware.

## Handoff

Phase 1 expects:

- `AppLogger.make(.audio)` returns a working logger.
- A `Modules/AudioEngine/` package can be added and depended on by the App target.
- `make test` runs Swift Testing suites from any module.
- Entitlements file exists and is referenced by the target.
