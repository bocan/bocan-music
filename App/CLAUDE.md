# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `App/` directory only. For build/lint/test commands, the module DAG, concurrency rules, and commit conventions, see the root `CLAUDE.md`. This file covers what is specific to the Xcode shell app.

## What `App/` is

The composition root and the only layer allowed to import both `UI` and the lower modules at once. It owns three things:

1. **The object graph** (dependency injection): every module's objects are constructed and wired here.
2. **The scenes and menus**: the SwiftUI `App`, its windows, and the menu bar.
3. **Adapters**: concrete implementations of protocols the lower modules declare, so those modules never import each other directly.

There is no business logic here. If you are adding a feature, the logic belongs in a module under `Modules/`; `App/` only wires it in.

## The graph and async launch

- `AppGraph` (in `BocanApp.swift`) is a flat struct holding every constructed object (view models, services, stores, controllers). Adding a cross-module object usually means: build it in the bootstrap function, add a `let` to `AppGraph`, pass it to the scene/command that needs it.
- `AppModel` owns the **async** bootstrap. The database open is slow and used to block launch, so `bootstrap()` builds the graph off the launch path and publishes it into `AppModel.graph`. `@Observable` gives property-level granularity, so `body` re-evaluates once when `graph` flips.
- The main window renders `AppRootGate` (in `LaunchLoadingView.swift`): a loading shell until `graph` is non-nil, then the UI module's `BocanRootView`. Secondary windows render their content through `GraphContent`, which shows `Color.clear` until the graph exists (these windows only open post-launch, so the placeholder is effectively never seen).
- `RootView.swift` is intentionally empty: the real root view is `BocanRootView` in the `UI` module.

## Scenes: the type-checker constraint

`BocanApp.body` is a long flat list of scenes. To keep it within the SwiftUI **scene type-checker's** limits, each window's content is a concrete named `View` (`SettingsWindowContent`, `DSPWindowContent`, etc. in `AppSceneContent.swift`) rather than an inline `GraphContent { ... }` closure. Follow that pattern when adding a window. Gating whole scenes on `model.graph` (rather than gating their content) also overran the type-checker, which is why every window is declared unconditionally and gated inside.

The mini-player and other secondary windows call `.commandsRemoved()` so SwiftUI does not auto-inject duplicate Window-menu items for them.

## Menus: `BocanCommands.swift`

- All menu bar commands live here, fed by `AppCommands` (in `AppSceneContent.swift`) once the graph is ready.
- View models are passed as plain `let`, **not** `@ObservedObject`/`@Bindable`. `LibraryViewModel` publishes on every playback tick and the visualizer at 60 fps; rebuilding the menu bar at those rates starves the audio buffer and causes audible pops. For labels that must reflect live state (Show vs Hide, Mute vs Unmute), read the backing `@AppStorage` keys directly instead.
- The **View menu** is the system one: `SidebarCommands()` plus `CommandGroup(after: .sidebar)`, not a custom `CommandMenu("View")` (a custom one risks a duplicate next to the system View menu). Window/Edit standard groups (Cut/Copy/Paste in `.pasteboard`, Undo/Redo in `.undoRedo`, Zoom in the Window menu) are left intact; only `.textEditing` is replaced so Cmd-F focuses the library search.
- This file sits at the SwiftLint **500-line `file_length` limit**. Adding items usually means trimming a comment elsewhere; do not add a `swiftlint:disable`.
- To open a specific Settings page from a menu item (or any button), use the injected `SettingsRouter`: `settingsRouter.open(.page); openSettings()`. The router persists the request so it survives a first-ever Settings open. See `Modules/UI/Sources/UI/Settings/SettingsRouter.swift`.

## Adapters: how the module DAG stays acyclic

The `UI` and `Scrobble` modules must not import `Subsonic`, so they declare protocols and `App/` provides the concrete bridges:

- `SubsonicStoreSidebarListing` -> `UI.SubsonicSidebarListing` (sidebar server list, visibility, delete)
- `SubsonicMonitorConnectionObserver` -> `UI.SubsonicConnectionObserving`
- `SubsonicCapabilityObserver` -> `UI.SubsonicCapabilityChangeObserving`
- `SubsonicRepositoryMetadataCache` -> `SubsonicMetadataCaching`; `SubsonicStreamResolver` -> `SubsonicStreamResolving` (the metadata-cache and stream-resolution seams)
- `SubsonicScrobbleDelivery` -> `Scrobble.SubsonicScrobbleDelivering`

When you need module A to call into module B that it cannot import, add a protocol in A and an adapter here, then inject it through the graph. That is the established seam, not a new cross-module dependency.

## Lifecycle and single instance

- `SingleInstance.swift` enforces one running copy via `DistributedNotificationCenter`. Its activation notification name is a stable external contract: never change `SingleInstance.activationNotification` without updating every installed copy (there is a test pinning it).
- `Lifecycle.swift`, `LaunchSanity.swift`, `LaunchAtLoginController.swift`, and `AppDelegate+DockMenu.swift` handle termination-time state save, launch sanity checks, login-item registration, and the dock-tile menu. `Updates/UpdateController.swift` wraps Sparkle.

## Tests

App-target tests live in **`Tests/AppTests/`** at the repo root (not in `App/`), and run host-less in the Xcode `BocanTests` bundle. Two consequences:

- Most App code (scenes, commands) cannot be exercised without a running app, so the tests are **source-convention checks**: they read an `App/*.swift` file via `#filePath` and assert structural facts (e.g. the View menu exists, a menu item deep-links via the router). When you change menu/scene structure, update or add one of these.
- Only `App/SingleInstance.swift` is compiled directly into the test bundle (declared in `project.yml`) so tests can reference its constants. Everything else is read as text.
- Adding a new file under `Tests/AppTests/` requires `make generate` before `make test` will see it (the directory is globbed into the Xcode project at generation time).
