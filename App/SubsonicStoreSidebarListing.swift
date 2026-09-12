import Foundation
import Observability
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
        do {
            return try JSONDecoder().decode(SubsonicCapabilities.self, from: data)
        } catch {
            // Defaulting to no capabilities hides the Podcasts, Internet Radio
            // and Bookmarks rows, so a corrupt cache is indistinguishable from
            // a server that simply does not support them (#493).
            AppLogger.make(.subsonic).warning("subsonic.capabilitiesCache.decodeFailed", [
                "bytes": data.count,
                "error": String(reflecting: error),
            ])
            return SubsonicCapabilities()
        }
    }
}
