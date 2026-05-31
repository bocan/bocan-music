import Foundation
import Subsonic
import UI

// MARK: - SubsonicStoreSidebarListing

/// App-layer adapter that bridges `SubsonicServerStore` (Subsonic module)
/// to the UI module's `SubsonicSidebarListing` protocol.
///
/// Filters out servers the user has hidden from the sidebar and projects
/// them down to the minimal `SubsonicSidebarServer` shape the UI consumes.
struct SubsonicStoreSidebarListing: SubsonicSidebarListing {
    let store: SubsonicServerStore
    let service: SubsonicService

    func fetchSidebarServers() async throws -> [SubsonicSidebarServer] {
        try await self.store.fetchAll()
            .filter(\.showInSidebar)
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { server in
                let caps = Self.decodeCapabilities(server.cachedCapabilitiesJSON)
                return SubsonicSidebarServer(
                    id: server.id,
                    name: server.name,
                    sortIndex: server.sortIndex,
                    supportsPodcasts: caps.supportsPodcasts,
                    supportsInternetRadio: caps.supportsInternetRadio,
                    supportsBookmarks: caps.supportsBookmarks,
                    includeInGlobalSearch: server.includeInGlobalSearch
                )
            }
    }

    func fetchHiddenSidebarServers() async throws -> [SubsonicSidebarServer] {
        try await self.store.fetchAll()
            .filter { !$0.showInSidebar }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { server in
                let caps = Self.decodeCapabilities(server.cachedCapabilitiesJSON)
                return SubsonicSidebarServer(
                    id: server.id,
                    name: server.name,
                    sortIndex: server.sortIndex,
                    supportsPodcasts: caps.supportsPodcasts,
                    supportsInternetRadio: caps.supportsInternetRadio,
                    supportsBookmarks: caps.supportsBookmarks,
                    includeInGlobalSearch: server.includeInGlobalSearch
                )
            }
    }

    func setSidebarVisible(id: UUID, visible: Bool) async throws {
        guard var server = try await self.store.fetch(id: id) else { return }
        guard server.showInSidebar != visible else { return }
        server.showInSidebar = visible
        try await self.store.update(server)
    }

    func removeServer(id: UUID) async throws {
        try await self.store.remove(id: id)
        await self.service.removeClient(for: id)
    }

    private static func decodeCapabilities(_ data: Data?) -> SubsonicCapabilities {
        guard let data else { return SubsonicCapabilities() }
        return (try? JSONDecoder().decode(SubsonicCapabilities.self, from: data))
            ?? SubsonicCapabilities()
    }
}
