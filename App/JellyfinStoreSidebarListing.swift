import Foundation
import Jellyfin
import UI

// MARK: - JellyfinStoreSidebarListing

/// App-layer adapter from the Jellyfin module's store to the UI module's
/// `JellyfinSidebarListing`. It mirrors `SubsonicStoreSidebarListing`.
///
/// Removal goes through `JellyfinService.removeServer`, which asks the server to
/// end the access token first (best effort), and then stops the monitor loop.
struct JellyfinStoreSidebarListing: JellyfinSidebarListing {
    let store: JellyfinServerStore
    let service: JellyfinService
    let monitor: JellyfinConnectionMonitor

    func fetchSidebarServers() async throws -> [JellyfinSidebarServer] {
        try await self.store.fetchAll()
            .filter(\.showInSidebar)
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(Self.sidebarServer)
    }

    func fetchHiddenSidebarServers() async throws -> [JellyfinSidebarServer] {
        try await self.store.fetchAll()
            .filter { !$0.showInSidebar }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(Self.sidebarServer)
    }

    func setSidebarVisible(id: UUID, visible: Bool) async throws {
        guard var server = try await self.store.fetch(id: id) else { return }
        guard server.showInSidebar != visible else { return }
        server.showInSidebar = visible
        try await self.store.update(server)
    }

    func removeServer(id: UUID) async throws {
        try await self.service.removeServer(id: id)
        await self.monitor.stopMonitoring(serverID: id)
    }

    private static func sidebarServer(_ server: JellyfinServer) -> JellyfinSidebarServer {
        JellyfinSidebarServer(
            id: server.id,
            name: server.name,
            sortIndex: server.sortIndex,
            includeInGlobalSearch: server.includeInGlobalSearch
        )
    }
}
