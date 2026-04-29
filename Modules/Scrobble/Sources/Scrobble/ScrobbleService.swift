import Foundation
import Observability
import Persistence
import Playback

// MARK: - ScrobbleService

/// Public façade over the scrobble pipeline.
///
/// Owns the providers, the queue repository, and the per-provider workers.
/// The rest of the app talks to this actor via three small entry points:
///   - `recordPlay(_:)` from `PlayHistoryRecorder` once a play passes the
///     scrobble threshold,
///   - `nowPlaying(_:)` from `QueuePlayer` when a track starts (best-effort),
///   - `love(_:loved:)` from the UI when the user toggles the loved flag.
public actor ScrobbleService: ScrobbleSink {
    public static let providerIDs: [String] = ["lastfm", "listenbrainz"]

    private let providers: [String: any ScrobbleProvider]
    private let workers: [String: ScrobbleQueueWorker]
    private let repository: ScrobbleQueueRepository
    private let log = AppLogger.make(.scrobble)

    public init(
        providers: [any ScrobbleProvider],
        repository: ScrobbleQueueRepository,
        reachability: any Reachability,
        policy: RetryPolicy = .default
    ) {
        var providerMap: [String: any ScrobbleProvider] = [:]
        var workerMap: [String: ScrobbleQueueWorker] = [:]
        for p in providers {
            providerMap[p.id] = p
            workerMap[p.id] = ScrobbleQueueWorker(
                provider: p,
                repository: repository,
                policy: policy,
                reachability: reachability
            )
        }
        self.providers = providerMap
        self.workers = workerMap
        self.repository = repository
    }

    public func start() async {
        for worker in self.workers.values {
            await worker.start()
        }
        self.log.info("scrobble.service.start", ["providers": self.providers.keys.sorted().joined(separator: ",")])
    }

    public func stop() async {
        for worker in self.workers.values {
            await worker.stop()
        }
    }

    // MARK: Public API

    /// Called by `PlayHistoryRecorder` after a play passes the eligibility threshold.
    /// Inserts into `scrobble_queue` and signals all workers to drain.
    public func recordPlay(
        trackID: Int64,
        playedAt: Date,
        durationPlayed: TimeInterval
    ) async {
        let activeProviders = await self.activeProviderIDs()
        guard !activeProviders.isEmpty else {
            self.log.debug("scrobble.service.skip", ["reason": "no providers connected"])
            return
        }
        guard ScrobbleRules.isWithinBackdateWindow(playedAt) else {
            self.log.warning("scrobble.service.backdated", ["played_at": playedAt.timeIntervalSince1970])
            return
        }
        do {
            let queueID = try await self.repository.enqueue(
                trackID: trackID,
                playedAt: playedAt,
                durationPlayed: durationPlayed,
                providerIDs: activeProviders
            )
            self.log.info("scrobble.service.enqueued", ["queue_id": queueID ?? -1, "providers": activeProviders.joined(separator: ",")])
            for pid in activeProviders {
                await self.workers[pid]?.kick()
            }
        } catch {
            self.log.error("scrobble.service.enqueue.fail", ["err": String(reflecting: error)])
        }
    }

    /// Best-effort "now playing" notification.
    public func nowPlaying(
        trackID: Int64,
        artist: String,
        albumArtist: String?,
        album: String?,
        title: String,
        duration: TimeInterval,
        mbid: String?
    ) async {
        let event = PlayEvent(
            queueID: -1, trackID: trackID,
            artist: artist, albumArtist: albumArtist, album: album,
            title: title, duration: duration, mbid: mbid,
            playedAt: Date()
        )
        for (pid, provider) in self.providers {
            let authed = await provider.isAuthenticated()
            guard authed else { continue }
            do {
                try await provider.nowPlaying(event)
            } catch {
                self.log.warning("scrobble.service.nowplaying.fail", ["provider": pid, "err": String(reflecting: error)])
            }
        }
    }

    /// Toggle the loved flag at every connected provider.
    public func love(track: TrackIdentity, loved: Bool) async {
        for (pid, provider) in self.providers {
            let authed = await provider.isAuthenticated()
            guard authed else { continue }
            do {
                try await provider.love(track: track, loved: loved)
            } catch {
                self.log.warning("scrobble.service.love.fail", ["provider": pid, "err": String(reflecting: error)])
            }
        }
    }

    /// Provider lookup so the UI can drive auth flows directly.
    public func provider(id: String) -> (any ScrobbleProvider)? {
        self.providers[id]
    }

    /// Repo so the UI can fetch stats / observe.
    public nonisolated var queueRepository: ScrobbleQueueRepository {
        self.repository
    }

    /// Force one drain pass on every worker. Used by app-launch and "retry now" UI.
    public func kickAll() async {
        for worker in self.workers.values {
            await worker.kick()
        }
    }

    private func activeProviderIDs() async -> [String] {
        var out: [String] = []
        for (pid, p) in self.providers {
            if await p.isAuthenticated() { out.append(pid) }
        }
        return out.sorted()
    }
}
