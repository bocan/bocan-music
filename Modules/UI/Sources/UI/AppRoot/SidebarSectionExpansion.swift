import Foundation

// MARK: - SidebarSectionExpansion

/// Persisted expand/collapse state for every top-level sidebar section, plus
/// per-server disclosure state for the Phase 19 Sources section. Lives in
/// `UIStateV2` so it survives a relaunch.
///
/// All booleans default to `true`: a fresh install opens with every section
/// visible. Adding a new section in a future phase only requires bumping the
/// default here — old persisted payloads decode missing keys as `true`.
public struct SidebarSectionExpansion: Codable, Sendable, Hashable {
    public var localLibrary: Bool
    public var sources: Bool
    public var recents: Bool
    public var queue: Bool
    public var expandedServers: Set<UUID>

    public init(
        localLibrary: Bool = true,
        sources: Bool = true,
        recents: Bool = true,
        queue: Bool = true,
        expandedServers: Set<UUID> = []
    ) {
        self.localLibrary = localLibrary
        self.sources = sources
        self.recents = recents
        self.queue = queue
        self.expandedServers = expandedServers
    }

    private enum CodingKeys: String, CodingKey {
        case localLibrary
        case sources
        case recents
        case queue
        case expandedServers
    }

    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.localLibrary = try c.decodeIfPresent(Bool.self, forKey: .localLibrary) ?? true
        self.sources = try c.decodeIfPresent(Bool.self, forKey: .sources) ?? true
        self.recents = try c.decodeIfPresent(Bool.self, forKey: .recents) ?? true
        self.queue = try c.decodeIfPresent(Bool.self, forKey: .queue) ?? true
        self.expandedServers = try c.decodeIfPresent(Set<UUID>.self, forKey: .expandedServers) ?? []
    }
}

// MARK: - SubsonicSidebarServer

/// Lightweight, UI-only view of a Subsonic server entry. The `Subsonic`
/// module isn't a dependency of `UI`, so the app layer adapts a
/// `SubsonicServer` into this DTO when populating the sidebar.
public struct SubsonicSidebarServer: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let sortIndex: Int
    public let supportsPodcasts: Bool
    public let supportsInternetRadio: Bool
    public let supportsBookmarks: Bool
    public let includeInGlobalSearch: Bool

    public init(
        id: UUID,
        name: String,
        sortIndex: Int,
        supportsPodcasts: Bool = false,
        supportsInternetRadio: Bool = false,
        supportsBookmarks: Bool = false,
        includeInGlobalSearch: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.supportsPodcasts = supportsPodcasts
        self.supportsInternetRadio = supportsInternetRadio
        self.supportsBookmarks = supportsBookmarks
        self.includeInGlobalSearch = includeInGlobalSearch
    }
}

// MARK: - SubsonicSidebarListing

/// Source of sidebar-visible Subsonic servers. Implemented by the app layer
/// against `SubsonicServerStore`; UI consumes the protocol so the module
/// stays decoupled from the `Subsonic` package.
public protocol SubsonicSidebarListing: Sendable {
    /// Returns the list of servers the user has chosen to show in the
    /// sidebar, sorted by `sortIndex`. Servers with `showInSidebar == false`
    /// are filtered out before this method returns.
    func fetchSidebarServers() async throws -> [SubsonicSidebarServer]
}

// MARK: - SubsonicCapabilityChangeObserving

/// Phase 19 step 16: surfaces capability-change events from the Subsonic
/// module to the UI layer, so the sidebar can grow new rows (Podcasts,
/// Internet Radio, Bookmarks…) without a relaunch when a server upgrade
/// adds support for them.
public protocol SubsonicCapabilityChangeObserving: Sendable {
    /// Stream of server IDs whose advertised capabilities changed since the
    /// previously persisted snapshot. Consumers should refetch the sidebar
    /// listing on each emission.
    func capabilityChanges() -> AsyncStream<UUID>
}
