import Combine
import Foundation
import Jellyfin
import Observability

// MARK: - JellyfinSidebarServer

/// Lightweight, UI-only view of a Jellyfin server entry. The App layer adapts a
/// `JellyfinServer` into this shape when it fills the sidebar. It is the twin of
/// `SubsonicSidebarServer` without the Subsonic capability flags: a Jellyfin
/// server always shows the same nine rows.
public struct JellyfinSidebarServer: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let sortIndex: Int
    public let includeInGlobalSearch: Bool

    public init(id: UUID, name: String, sortIndex: Int, includeInGlobalSearch: Bool = true) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.includeInGlobalSearch = includeInGlobalSearch
    }
}

// MARK: - JellyfinSidebarListing

/// Source of the Jellyfin servers the sidebar shows. The App layer implements it
/// over `JellyfinServerStore`; `UI` consumes the protocol so a test needs no
/// database.
public protocol JellyfinSidebarListing: Sendable {
    /// The servers the user shows in the sidebar, in `sortIndex` order.
    func fetchSidebarServers() async throws -> [JellyfinSidebarServer]

    /// The servers the user hid from the sidebar, in `sortIndex` order. Powers
    /// the "Hidden Sources" submenu.
    func fetchHiddenSidebarServers() async throws -> [JellyfinSidebarServer]

    /// Flips a server's `showInSidebar` flag.
    func setSidebarVisible(id: UUID, visible: Bool) async throws

    /// Removes a server for good: the row, the Keychain token, the cached
    /// metadata and the in-memory client. The server is also asked to end the
    /// token, but a server that cannot be reached never blocks the removal.
    func removeServer(id: UUID) async throws
}

// MARK: - JellyfinConnectionObserving

/// Per-server connection status for the sidebar dot and the offline banner. It
/// speaks the UI's existing `SubsonicSidebarConnectionState`, which carries
/// nothing Subsonic specific (ADR-097, D1).
public protocol JellyfinConnectionObserving: Sendable {
    func currentStates() async -> [UUID: SubsonicSidebarConnectionState]
    func stateUpdates() -> AsyncStream<(UUID, SubsonicSidebarConnectionState)>
    /// Forces an immediate re-ping of one server ("Retry now").
    func retry(serverID: UUID) async
}

// MARK: - JellyfinSourceModel

/// Everything the main window knows about Jellyfin servers.
///
/// It is its own `ObservableObject` on purpose. `LibraryViewModel` holds one
/// reference to it and does **not** forward its changes, so the Sidebar and the
/// content pane hold it with `@ObservedObject` and read it directly (ADR-097,
/// "Observation"). Nothing here is mirrored into `UserDefaults`.
@MainActor
public final class JellyfinSourceModel: ObservableObject {
    /// Servers shown in the sidebar.
    @Published public private(set) var servers: [JellyfinSidebarServer] = []

    /// Servers the user hid from the sidebar.
    @Published public private(set) var hiddenServers: [JellyfinSidebarServer] = []

    /// Live connection state per server.
    @Published public private(set) var connectionStates: [UUID: SubsonicSidebarConnectionState] = [:]

    /// The server the user chose to remove, while the confirm dialog is up.
    @Published public var serverPendingRemoval: JellyfinSidebarServer?

    /// Set by the App layer. Builds the client pool before a persisted Jellyfin
    /// destination is restored, as `subsonicBootstrap` does.
    public var bootstrap: (@Sendable () async -> Void)?

    /// What the browse views ask for their data. `nil` without the Jellyfin
    /// module wired in (tests, snapshots): the views then show their empty state.
    public let dataSource: (any JellyfinBrowseDataSource)?

    /// Resolves cover-art URLs for the browse views. `nil` when not wired in.
    public let coverArtProvider: JellyfinCoverArtProvider?

    /// The metadata cache the browse view models hydrate from. The protocol is
    /// the Subsonic one, which carries nothing Subsonic specific.
    public let metadataCache: (any SubsonicMetadataCaching)?

    /// Cross-server search, shown by the Jellyfin Songs, Albums and Artists views
    /// while the search field has text. `nil` when there is no data source.
    public let search: JellyfinMultiSourceSearchViewModel?

    /// Optimistic favourites for every Jellyfin song table (ADR-097 slice 6).
    /// `nil` when no favourites queue is wired in: the star then only shows.
    public let annotations: JellyfinAnnotationCoordinator?

    private let listing: (any JellyfinSidebarListing)?
    private let connectionObserver: (any JellyfinConnectionObserving)?
    private var connectionTask: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    /// Every parameter is `nil` in tests and snapshots that run without the
    /// Jellyfin module wired in; every method is then a no-op.
    public init(
        listing: (any JellyfinSidebarListing)? = nil,
        connectionObserver: (any JellyfinConnectionObserving)? = nil,
        dataSource: (any JellyfinBrowseDataSource)? = nil,
        coverArtProvider: JellyfinCoverArtProvider? = nil,
        metadataCache: (any SubsonicMetadataCaching)? = nil,
        annotationDelivery: (any JellyfinAnnotationDelivering)? = nil
    ) {
        self.listing = listing
        self.connectionObserver = connectionObserver
        self.dataSource = dataSource
        self.coverArtProvider = coverArtProvider
        self.metadataCache = metadataCache
        let annotations = annotationDelivery.map { JellyfinAnnotationCoordinator(delivery: $0) }
        self.annotations = annotations
        self.search = dataSource.map { JellyfinMultiSourceSearchViewModel(dataSource: $0) }
        self.search?.attach(annotations)
        self.observeConnectionChanges()
    }

    deinit {
        self.connectionTask?.cancel()
    }

    /// `true` once any Jellyfin server exists, shown or hidden. The Sources
    /// section uses it to hide its "Add a Server" button.
    public var hasServers: Bool {
        !self.servers.isEmpty || !self.hiddenServers.isEmpty
    }

    // MARK: - Loading

    /// Reloads both lists so the "Hidden Sources" submenu stays in step.
    public func reloadServers() async {
        guard let listing = self.listing else { return }
        do {
            self.servers = try await listing.fetchSidebarServers()
        } catch {
            self.log.error("ui.jellyfin.reload.failed", ["error": String(reflecting: error)])
        }
        do {
            self.hiddenServers = try await listing.fetchHiddenSidebarServers()
        } catch {
            self.log.error("ui.jellyfin.reloadHidden.failed", ["error": String(reflecting: error)])
        }
    }

    /// Runs the App layer's `bootstrap` closure, if one was set.
    public func bootstrapServers() async {
        await self.bootstrap?()
    }

    // MARK: - Actions

    /// Hides or shows a server in the sidebar.
    public func setServerSidebarVisible(id: UUID, visible: Bool) async {
        guard let listing = self.listing else { return }
        do {
            try await listing.setSidebarVisible(id: id, visible: visible)
            await self.reloadServers()
        } catch {
            self.log.error(
                "ui.jellyfin.setSidebarVisible.failed",
                ["id": id.uuidString, "error": String(reflecting: error)]
            )
        }
    }

    /// Removes `server`, the one the confirmation dialog presented, then clears
    /// the pending state and reloads the lists.
    ///
    /// The dialog passes the server in. It must not be read back from
    /// `serverPendingRemoval`: the dialog's dismissal clears that before the
    /// button's task runs, so the removal silently did nothing (found by the
    /// slice 9 E2E journey).
    public func confirmRemoveServer(_ server: JellyfinSidebarServer) async {
        self.serverPendingRemoval = nil
        guard let listing = self.listing else { return }
        do {
            try await listing.removeServer(id: server.id)
            self.connectionStates[server.id] = nil
            await self.reloadServers()
        } catch {
            self.log.error(
                "ui.jellyfin.removeServer.failed",
                ["id": server.id.uuidString, "error": String(reflecting: error)]
            )
        }
    }

    /// "Retry now": asks the monitor to re-ping at once.
    public func retryConnection(serverID: UUID) async {
        await self.connectionObserver?.retry(serverID: serverID)
    }

    // MARK: - Connection state

    private func observeConnectionChanges() {
        guard let observer = self.connectionObserver else { return }
        let stream = observer.stateUpdates()
        self.connectionTask = Task { [weak self] in
            let snapshot = await observer.currentStates()
            self?.applySnapshot(snapshot)
            for await (serverID, state) in stream {
                guard let self else { return }
                // The monitor reports "online" after every 60 s ping. Writing
                // the same state would still publish and redraw the sidebar.
                if self.connectionStates[serverID] != state {
                    self.connectionStates[serverID] = state
                }
            }
        }
    }

    /// The snapshot is older than any update that has already arrived, so it
    /// only fills servers that have no state yet.
    private func applySnapshot(_ snapshot: [UUID: SubsonicSidebarConnectionState]) {
        for (id, state) in snapshot where self.connectionStates[id] == nil {
            self.connectionStates[id] = state
        }
    }
}
