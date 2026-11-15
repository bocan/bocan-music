import Foundation
import Observability
import Persistence
import UI

// MARK: - JellyfinRepositoryMetadataCache

/// App-layer adapter that bridges `JellyfinServerRepository`'s metadata-cache SQL
/// to the UI module's `SubsonicMetadataCaching` protocol. That protocol is only
/// "a payload by server, kind and id", so the Jellyfin browse view models use it
/// as it is (ADR-097, D1). Errors are logged and swallowed, so a miss looks the
/// same as "no cache yet" to the view models. It mirrors `SubsonicRepositoryMetadataCache`.
struct JellyfinRepositoryMetadataCache: SubsonicMetadataCaching {
    let repository: JellyfinServerRepository

    private static let log = AppLogger.make(.app)

    func loadCache(serverID: UUID, entityKind: String, entityID: String) async -> Data? {
        do {
            return try await self.repository.fetchCache(serverID: serverID, entityKind: entityKind, entityID: entityID)
        } catch {
            Self.log.debug(
                "jellyfin.cache.load.failed",
                ["serverID": serverID.uuidString, "kind": entityKind, "id": entityID]
            )
            return nil
        }
    }

    func saveCache(serverID: UUID, entityKind: String, entityID: String, payload: Data) async {
        do {
            try await self.repository.upsertCache(
                serverID: serverID,
                entityKind: entityKind,
                entityID: entityID,
                payloadJSON: payload
            )
        } catch {
            Self.log.debug(
                "jellyfin.cache.save.failed",
                ["serverID": serverID.uuidString, "kind": entityKind, "id": entityID]
            )
        }
    }
}
