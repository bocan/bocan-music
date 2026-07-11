import SwiftUI

// MARK: - SettingsPage

/// A Settings page that can be opened directly from a button or menu item
/// elsewhere in the app.
///
/// Raw values are stable so a selection can round-trip (persistence, tests).
public enum SettingsPage: String, CaseIterable, Sendable, Hashable {
    case general, library, sources, playback, equaliser, effects, replayGain
    case appearance, advanced, lyrics, visualizer, smartPlaylists, scrobble, diagnostics, podcasts
    case phoneSync
}

// MARK: - SettingsRouter

/// Shared navigation state for the `Settings` scene.
///
/// SwiftUI's `Settings` lives in its own scene that may not exist yet the first
/// time a deep-link is triggered, so a fire-and-forget `NotificationCenter` post
/// can be missed on first open (the long-standing awkwardness here). This object
/// instead *persists* the requested page until the Settings scene appears and
/// consumes it, making "open Settings at page X" reliable from anywhere.
///
/// Usage — pair with the `openSettings` environment action:
/// ```swift
/// // From a button:
/// @Environment(\.settingsRouter) private var settingsRouter
/// @Environment(\.openSettings) private var openSettings
/// settingsRouter?.open(.sources); openSettings()
///
/// // From a menu item (Commands), with the router passed in:
/// self.settingsRouter.open(.sources); self.openSettings()
/// ```
@MainActor
@Observable
public final class SettingsRouter {
    /// The page a caller wants shown. Set by `open(_:serverID:)`; the Settings
    /// scene reads it on appear and on change, then clears it.
    public var pendingPage: SettingsPage?

    /// Optional payload for the `.sources` page: a server to select on arrival.
    public var pendingServerID: UUID?

    public init() {}

    /// Request that Settings navigate to `page` (optionally selecting a server on
    /// the Sources page). Call `openSettings()` afterwards to bring the window
    /// forward; ordering doesn't matter because the request is persisted here.
    public func open(_ page: SettingsPage, serverID: UUID? = nil) {
        self.pendingPage = page
        self.pendingServerID = serverID
    }
}

/// Environment access to the shared ``SettingsRouter``.
public extension EnvironmentValues {
    /// The app-wide ``SettingsRouter``, or `nil` if none was injected. Optional so
    /// that views (and previews/tests) that read it never trap when it's absent;
    /// a `nil` router simply means a deep-link falls back to the default page.
    @Entry var settingsRouter: SettingsRouter?
}
