import AudioEngine
import Foundation
import Jellyfin
import Observability
import Playback

/// Adapts a stream cache, `JellyfinService` and `JellyfinServerStore` to
/// `Playback`'s `JellyfinStreamResolving` protocol (ADR-097 slice 5). It mirrors
/// `SubsonicStreamResolver`. Built once at launch by `JellyfinWiring` and
/// injected into `QueuePlayer`.
///
/// The cache is a second `SubsonicStreamCache` instance in its own folder
/// (`JellyfinStreams`). The class is named for Subsonic but carries nothing
/// Subsonic specific (ADR-097, D1); its key is the server UUID and an opaque id.
///
/// The stream URL carries the access token. It goes straight into the cache's
/// URL closure and is never logged.
final class JellyfinStreamResolver: JellyfinStreamResolving {
    private let cache: SubsonicStreamCache
    private let service: JellyfinService
    private let store: JellyfinServerStore
    private let log = AppLogger.make(.jellyfin)

    init(cache: SubsonicStreamCache, service: JellyfinService, store: JellyfinServerStore) {
        self.cache = cache
        self.service = service
        self.store = store
    }

    func localFileURL(serverID: UUID, itemID: String) async throws -> URL {
        let server = try await self.store.fetch(id: serverID)
        let format = server?.preferredFormat ?? .original
        // The cap applies only to a transcode (ADR-097, "Stream URL"), so the
        // key leaves it out for the original file: changing the cap must not
        // make an original file look like a different download.
        let bitrate: JellyfinBitrate = format == .original ? .original : (server?.maxBitrate ?? .original)
        let key = Self.cacheKey(serverID: serverID, itemID: itemID, format: format, bitrate: bitrate)
        let service = self.service
        return try await self.cache.url(for: key) {
            try await service.streamURL(serverID: serverID, itemID: itemID, format: format, bitrate: bitrate)
        }
    }

    func precache(serverID: UUID, itemID: String) async {
        let server: JellyfinServer?
        do {
            server = try await self.store.fetch(id: serverID)
        } catch {
            // Precache is skipped, which looks exactly like a server that has
            // the option switched off.
            self.log.warning("jellyfin.precache.serverReadFailed", [
                "serverID": serverID,
                "error": String(reflecting: error),
            ])
            return
        }
        guard let server, server.precacheNext else { return }
        do {
            _ = try await self.localFileURL(serverID: serverID, itemID: itemID)
            self.log.debug("jellyfin.precache.ok", ["serverID": serverID, "itemID": itemID])
        } catch {
            self.log.debug(
                "jellyfin.precache.failed",
                ["serverID": serverID, "itemID": itemID, "error": String(reflecting: error)]
            )
        }
    }

    /// The cache key for one song in one format. Follows the Subsonic resolver:
    /// the format's raw value and the cap in kbps (`nil` for no cap).
    static func cacheKey(
        serverID: UUID,
        itemID: String,
        format: JellyfinStreamFormat,
        bitrate: JellyfinBitrate
    ) -> SubsonicStreamKey {
        SubsonicStreamKey(serverID: serverID, songID: itemID, format: format.rawValue, bitrateKbps: bitrate.kbps)
    }
}
