import Foundation
import Scrobble
import Subsonic

/// Bridges `Scrobble.SubsonicScrobbleDelivering` to the `Subsonic` module so the
/// `Scrobble` package can stay independent of `Subsonic`.
struct SubsonicScrobbleDelivery: SubsonicScrobbleDelivering {
    let service: SubsonicService
    let store: SubsonicServerStore

    func scrobbleEnabledServerIDs() async -> Set<UUID> {
        do {
            let servers = try await store.fetchAll()
            return Set(servers.filter(\.scrobble).map(\.id))
        } catch {
            return []
        }
    }

    func scrobble(serverID: UUID, songID: String, submission: Bool) async throws {
        try await self.service.scrobble(serverID: serverID, songID: songID, submission: submission)
    }
}
