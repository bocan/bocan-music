import Acoustics
import Foundation
import Observability
import Persistence

/// Fills `artists.disambiguation` (and a missing `sort_name`) from the
/// MusicBrainz artist entity, one lookup per artist, ever (issue #401).
///
/// Runs as a single background pass over artists with an MBID and no
/// `musicbrainz_fetched_at`, through the app-wide 1 request/second limiter
/// and paced a little slower than it (`pacing`), so identify and cover-art
/// search keep headroom and network jitter cannot land two requests inside
/// one second on MusicBrainz's clock. A 503 or network error backs off
/// (doubling from `backoff`, up to `maxBackoffs` in a row) and retries the
/// same artist; only a run of failures pauses the pass, leaving the rest
/// unstamped for the next launch. A definite MusicBrainz "no" (a stale or
/// bad MBID) stamps the row so it is not retried forever.
public actor ArtistEnrichmentService {
    private let artists: ArtistRepository
    private let client: MusicBrainzClient
    private let batchSize: Int
    private let pacing: Duration
    private let backoff: Duration
    private let maxBackoffs: Int
    private let now: @Sendable () -> Date
    private let log = AppLogger.make(.library)
    private var runningPass: Task<Void, Never>?

    public init(
        artists: ArtistRepository,
        client: MusicBrainzClient = MusicBrainzClient(),
        batchSize: Int = 50,
        pacing: Duration = .milliseconds(1500),
        backoff: Duration = .seconds(15),
        maxBackoffs: Int = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.artists = artists
        self.client = client
        self.batchSize = batchSize
        self.pacing = pacing
        self.backoff = backoff
        self.maxBackoffs = maxBackoffs
        self.now = now
    }

    /// Starts one pass after `delay` (so launch work settles first). A pass
    /// already underway is left alone. The task captures `self` strongly on
    /// purpose: a fire-and-forget background pass must keep its actor alive
    /// until it ends; `stop()` cancels it.
    public func start(after delay: Duration = .seconds(45)) {
        guard self.runningPass == nil else { return }
        self.runningPass = Task(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.enrichOnce()
            await self.passFinished()
        }
    }

    public func stop() {
        self.runningPass?.cancel()
        self.runningPass = nil
    }

    private func passFinished() {
        self.runningPass = nil
    }

    /// Looks up every artist still needing enrichment. Returns the number
    /// of rows stamped. Internal so tests drive it directly.
    @discardableResult
    func enrichOnce() async -> Int {
        var stamped = 0
        do {
            let pending = try await self.artists.countNeedingEnrichment()
            guard pending > 0 else { return 0 }
            self.log.info("artist.enrich.pass.start", ["pending": pending])
            var cursor: Int64 = 0
            var consecutiveBackoffs = 0
            while true {
                try Task.checkCancellation()
                let batch = try await self.artists.fetchNeedingEnrichment(limit: self.batchSize)
                    .filter { ($0.id ?? 0) > cursor }
                guard !batch.isEmpty else { break }
                batchLoop: for artist in batch {
                    try Task.checkCancellation()
                    guard let id = artist.id, let mbid = artist.musicbrainzArtistID else { continue }
                    switch await self.enrich(id: id, mbid: mbid) {
                    case .stamped:
                        stamped += 1
                        consecutiveBackoffs = 0
                        cursor = max(cursor, id)
                    case .skipped:
                        cursor = max(cursor, id)
                    case .abort:
                        // Retry this artist after a growing pause; give up on
                        // the pass after a run of failures. Leaving the loop
                        // re-reads the batch from just before this artist.
                        consecutiveBackoffs += 1
                        guard consecutiveBackoffs <= self.maxBackoffs else { throw PassAborted() }
                        let wait = self.backoff * (1 << (consecutiveBackoffs - 1))
                        self.log.info("artist.enrich.backoff", ["attempt": consecutiveBackoffs, "seconds": wait.seconds])
                        try await Task.sleep(for: wait)
                        cursor = id - 1
                        break batchLoop
                    }
                    try await Task.sleep(for: self.pacing)
                }
            }
        } catch is CancellationError {
            self.log.debug("artist.enrich.pass.cancelled", ["stamped": stamped])
            return stamped
        } catch is PassAborted {
            self.log.info("artist.enrich.pass.paused", ["stamped": stamped, "reason": "rate limit or network"])
            return stamped
        } catch {
            self.log.error("artist.enrich.pass.failed", ["error": String(reflecting: error)])
        }
        self.log.info("artist.enrich.pass.end", ["stamped": stamped])
        return stamped
    }

    /// Enriches one artist on demand (Deep Dive, #413). Returns the refreshed row.
    public func enrich(artistID: Int64) async throws -> Artist {
        let artist = try await self.artists.fetch(id: artistID)
        if let mbid = artist.musicbrainzArtistID {
            _ = await self.enrich(id: artistID, mbid: mbid)
        }
        return try await self.artists.fetch(id: artistID)
    }

    private enum Outcome { case stamped, skipped, abort }
    private struct PassAborted: Error {}

    private func enrich(id: Int64, mbid: String) async -> Outcome {
        do {
            let detail = try await self.client.fetchArtist(mbid: mbid)
            try await self.artists.setEnrichment(
                id: id,
                disambiguation: detail.disambiguation,
                sortName: detail.sortName,
                fetchedAt: Int64(self.now().timeIntervalSince1970)
            )
            return .stamped
        } catch AcousticsError.rateLimitExceeded, AcousticsError.networkError {
            return .abort
        } catch is CancellationError {
            return .abort
        } catch AcousticsError.invalidResponse {
            // A definite answer (typically 404 for a stale MBID): stamp so the
            // row is not retried every launch, keep whatever it already had.
            self.log.warning("artist.enrich.unresolved", ["id": id, "mbid": mbid])
            try? await self.artists.setEnrichment(
                id: id,
                disambiguation: nil,
                sortName: nil,
                fetchedAt: Int64(self.now().timeIntervalSince1970)
            )
            return .skipped
        } catch {
            self.log.warning("artist.enrich.failed", ["id": id, "error": String(reflecting: error)])
            return .skipped
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(self.components.seconds) + Double(self.components.attoseconds) / 1e18
    }
}
