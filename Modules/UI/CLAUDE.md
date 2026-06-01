# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `UI` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`. The menu bar and window/scene wiring live in `App/`, not here (see `App/CLAUDE.md`).

## What this module owns

Every SwiftUI view and view model. It is the only module that imports AppKit, and it sits just below `App` in the DAG.

- `LibraryViewModel` (in `ViewModels/`) is the spine: navigation, selection, sidebar/server state, scanning, toasts, and most user actions hang off it. `NowPlayingViewModel` drives the transport strip. View models are `@MainActor` `@Observable`/`ObservableObject`.
- `AppRoot/` is the main window (`BocanRootView`, `Sidebar`). `Browse/` is the library content (tracks/albums/artists tables, the Subsonic browse views, queue). `Settings/` is the System-Settings-style scene. `Console/` holds `LogConsoleView`, `LogConsoleRow`, and `LogConsoleViewModel` -- the in-app log window that backfills from `LogStore` and tails live entries. `MiniPlayer/`, `Lyrics/`, `Visualizers/`, `DSP/`, `Routing/`, `Transport/` are the other surfaces. `Theme/` holds colours, typography, and reusable a11y modifiers.
- To stay decoupled from `Subsonic`, this module declares protocols (sidebar listing, connection/capability observing, etc.) that the App layer implements. Do not `import Subsonic`/`import Scrobble`-internals here.

## Testing this module (read before writing tests)

- `make test-ui` runs the SPM test target: snapshot tests plus the view-model/source-convention tests. **Snapshot tests and anything needing a real view tree only run here**, because the Xcode `BocanTests` bundle is host-less.
- The Xcode `BocanTests` bundle *also* globs `Modules/UI/Tests/UITests/ViewModelTests`. **Adding a new file there requires `make generate`** before `make test`/`make test-coverage` will pick it up.
- Much of the UI cannot be unit-tested host-less (menus, view internals, drawing). The established pattern is a **source-convention test**: read the source file via `#filePath` and assert a structural fact (a modifier is applied, an item exists, copy is present). When you change such a view, update or add one of these.
- Keep resolved English strings byte-identical when localizing, so default-size snapshots do not drift.

## Things easy to get wrong

- **SwiftLint enforces a 500-line `file_length`.** Several big view files (`NowPlayingStrip`, `BocanCommands` over in App, `TrackTableCoordinator`) sit right at it. Adding to them usually means trimming a comment elsewhere; do not add a `swiftlint:disable`. Watch out for `switch_case_on_newline`, `prefer_self_in_static_references`, and `trailing_closure` too.
- **Localization is mid-migration (issue #314).** SwiftPM only copies `Resources/Localizable.xcstrings`; **only the Xcode build compiles it** into `.strings`/`.stringsdict`. A bare `Text("…")` in this SPM module resolves against `Bundle.main`, not the module catalog, so user-facing copy must go through the `L10n` helper (`Text(localized:)` / `L10n.string(_:)`, which pass `bundle: .module`). Tests validate the catalog *content* (deterministic) rather than runtime resolution. Note: an Xcode build (`make test`) rewrites the catalog via auto-extraction; that churn is unrelated to most changes and can be reverted.
- **High-frequency view models must not invalidate the menu bar.** That is why `App/BocanCommands` takes them as plain `let`. Within this module, prefer property-level observation and avoid widening what a hot view observes.
- A spurious compiler warning, `'nonisolated(unsafe)' has no effect on property 'X', consider using 'nonisolated'`, fires on the `Task<…>?` handles in some view models. Its fix-it does not compile (`nonisolated` is rejected on mutable stored properties, and removing the annotation breaks the nonisolated `deinit`). Leave `nonisolated(unsafe)` as is.

## Testing

Run `make test-ui` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/UI`, or `make test-coverage` for the Xcode-bundle view-model tests), run `make test-ui` last so the full module suite (including snapshots) is the final gate before the commit.
