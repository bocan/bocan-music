import AudioEngine
import Foundation
import Observability
import Playback
import Subsonic

/// Adapts `SubsonicStreamCache` + `SubsonicService` + `SubsonicServerStore`
/// to `Playback`'s `SubsonicStreamResolving` protocol. Built once at app
/// launch and injected into `QueuePlayer`.
public final class SubsonicStreamResolver: SubsonicStreamResolving {
    private let cache: SubsonicStreamCache
    private let service: SubsonicService
    private let store: SubsonicServerStore
    private let log = AppLogger.make(.subsonic)

    public init(cache: SubsonicStreamCache, service: SubsonicService, store: SubsonicServerStore) {
        self.cache = cache
        self.service = service
        self.store = store
    }

    public func localFileURL(serverID: UUID, songID: String) async throws -> URL {
        let server = try await store.fetch(id: serverID)
        let bitrate: Int? = {
            guard let server else { return nil }
            if case let .kbps(kbps) = server.maxBitrate {
                return kbps
            }
            return nil
        }()
        let formatString = server?.preferredFormat.rawValue ?? "original"
        let key = SubsonicStreamKey(
            serverID: serverID,
            songID: songID,
            format: formatString,
            bitrateKbps: bitrate
        )

        let svc = self.service
        let formatParam: String? = server?.preferredFormat == .original ? nil : formatString
        return try await self.cache.url(for: key) {
            try await svc.streamURL(
                serverID: serverID,
                songID: songID,
                maxBitRate: bitrate,
                format: formatParam
            )
        }
    }

    public func precache(serverID: UUID, songID: String) async {
        let server: SubsonicServer?
        do {
            server = try await self.store.fetch(id: serverID)
        } catch {
            // Precache is skipped, which looks exactly like a server that has
            // the option switched off (#493).
            self.log.warning("subsonic.precache.serverReadFailed", [
                "serverID": serverID,
                "error": String(reflecting: error),
            ])
            return
        }
        guard let server, server.precacheNext else { return }
        do {
            _ = try await self.localFileURL(serverID: serverID, songID: songID)
            self.log.debug("subsonic.precache.ok", ["serverID": serverID, "songID": songID])
        } catch {
            self.log.debug(
                "subsonic.precache.failed",
                ["serverID": serverID, "songID": songID, "error": String(reflecting: error)]
            )
        }
    }
}
