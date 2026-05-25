import Foundation
import Observability
import Persistence
import UI

// MARK: - SubsonicRepositoryMetadataCache

/// App-layer adapter that bridges `SubsonicServerRepository`'s metadata-cache
/// SQL to the UI module's `SubsonicMetadataCaching` protocol. Errors are
/// logged and swallowed so cache misses look identical to "no cache yet" to
/// the per-server browse view-models.
struct SubsonicRepositoryMetadataCache: SubsonicMetadataCaching {
    let repository: SubsonicServerRepository

    private static let log = AppLogger.make(.app)

    func loadCache(serverID: UUID, entityKind: String, entityID: String) async -> Data? {
        do {
            return try await self.repository.fetchCache(
                serverID: serverID,
                entityKind: entityKind,
                entityID: entityID
            )
        } catch {
            Self.log.debug(
                "subsonic.cache.load.failed",
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
                "subsonic.cache.save.failed",
                ["serverID": serverID.uuidString, "kind": entityKind, "id": entityID]
            )
        }
    }
}
