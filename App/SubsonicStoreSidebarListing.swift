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

    func fetchSidebarServers() async throws -> [SubsonicSidebarServer] {
        try await self.store.fetchAll()
            .filter(\.showInSidebar)
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { SubsonicSidebarServer(id: $0.id, name: $0.name, sortIndex: $0.sortIndex) }
    }
}
