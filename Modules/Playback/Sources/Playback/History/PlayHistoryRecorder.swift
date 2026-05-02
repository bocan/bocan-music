import Foundation
import Observability
import Persistence

// MARK: - ScrobbleSink

/// Downstream consumer of recorded plays. The `Scrobble` module supplies the
/// production implementation; tests can pass a no-op or capture for assertions.
///
/// Decoupled via this protocol so `Playback` doesn't depend on `Scrobble`.
public protocol ScrobbleSink: Sendable {
    func recordPlay(trackID: Int64, playedAt: Date, durationPlayed: TimeInterval) async
    /// Best-effort "now playing" hint sent when a track starts. Defaults to no-op
    /// so existing test sinks don't need updating.
    func nowPlaying(trackID: Int64) async
}

public extension ScrobbleSink {
    func nowPlaying(trackID _: Int64) async {}
}

// MARK: - PlayHistoryRecorder

/// Observes engine state and records play-history events.
///
/// **Scrobble threshold**: a play is recorded when ≥ 50% of the track has been
/// played, OR ≥ 4 minutes have elapsed — whichever comes first (same rule as Last.fm).
/// `play_count` and `last_played_at` on the `tracks` row are also incremented.
///
/// **Skip detection**: if the track ends / is replaced before the threshold is
/// reached, `skip_count` is incremented instead.
public actor PlayHistoryRecorder {
    // MARK: - Threshold

    private static let minimumFraction = 0.50
    private static let minimumAbsoluteSeconds: TimeInterval = 240.0 // 4 minutes

    // MARK: - Dependencies

    private let db: Database
    private let trackRepo: TrackRepository
    private let scrobbleSink: (any ScrobbleSink)?
    private let log = AppLogger.make(.playback)

    // MARK: - Tracking state

    private var currentTrackID: Int64?
    private var trackDuration: TimeInterval = 0
    private var playStartedAt: Date?
    private var hasScrobbled = false

    // MARK: - Init

    public init(database: Database, scrobbleSink: (any ScrobbleSink)? = nil) {
        self.db = database
        self.trackRepo = TrackRepository(database: database)
        self.scrobbleSink = scrobbleSink
    }

    // MARK: - Public API

    /// Call when a new track starts playing.
    public func trackDidStart(trackID: Int64, duration: TimeInterval) async {
        self.currentTrackID = trackID
        self.trackDuration = duration
        self.playStartedAt = Date()
        self.hasScrobbled = false
        self.log.debug("history.start", ["trackID": trackID, "duration": duration])
        // Fire-and-forget: the Now Playing hint to scrobbling services is best-effort
        // and must never block the playback hot path (engine.play() follows immediately).
        if let sink = scrobbleSink {
            Task { await sink.nowPlaying(trackID: trackID) }
        }
    }

    /// Call periodically (or at track end) with the elapsed time so far.
    public func update(elapsed: TimeInterval) async {
        guard let id = currentTrackID, !hasScrobbled else { return }
        let shouldScrobble = self.meetsThreshold(elapsed: elapsed, duration: self.trackDuration)
        if shouldScrobble {
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        }
    }

    /// Call when the user skips before the threshold. Records a skip event.
    public func trackSkipped(elapsed: TimeInterval) async {
        guard let id = currentTrackID else { return }
        defer {
            currentTrackID = nil
            trackDuration = 0
            playStartedAt = nil
            hasScrobbled = false
        }

        if self.meetsThreshold(elapsed: elapsed, duration: self.trackDuration) {
            // Technically met threshold before skip — still scrobble.
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        } else {
            await self.recordSkip(trackID: id, elapsed: elapsed)
        }
    }

    /// Call when the track ends naturally (completes playing).
    public func trackDidEnd(elapsed: TimeInterval) async {
        guard let id = currentTrackID else { return }
        if !self.hasScrobbled {
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        }
        self.currentTrackID = nil
        self.trackDuration = 0
        self.playStartedAt = nil
        self.hasScrobbled = false
    }

    /// Call when a gapless handoff has occurred — the outgoing track played
    /// to its full natural length and was seamlessly replaced. Equivalent to
    /// `trackDidEnd(elapsed:)` with `elapsed = trackDuration`, but doesn't
    /// require the caller to know the previous track's duration.
    public func trackDidEndNaturally() async {
        await self.trackDidEnd(elapsed: self.trackDuration)
    }

    // MARK: - Private

    private func meetsThreshold(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        if duration > 0 {
            let fraction = elapsed / duration
            if fraction >= Self.minimumFraction { return true }
        }
        return elapsed >= Self.minimumAbsoluteSeconds
    }

    private func scrobble(trackID: Int64, durationPlayed: TimeInterval, source: String) async {
        guard !self.hasScrobbled else { return }
        self.hasScrobbled = true

        let playedAtDate = Date()
        let playedAt = Int64(playedAtDate.timeIntervalSince1970)

        do {
            try await self.db.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO play_history (track_id, played_at, duration_played, source)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [trackID, playedAt, durationPlayed, source]
                )
            }
            // Update play_count and last_played_at on the track row.
            try await self.db.write { db in
                try db.execute(
                    sql: """
                    UPDATE tracks
                    SET play_count = play_count + 1,
                        last_played_at = ?,
                        play_duration_total = play_duration_total + ?
                    WHERE id = ?
                    """,
                    arguments: [playedAt, durationPlayed, trackID]
                )
            }
            self.log.debug("history.scrobbled", ["trackID": trackID, "duration": durationPlayed])
        } catch {
            self.log.error("history.scrobble.failed", ["error": String(reflecting: error)])
            return
        }
        // Notify the scrobble pipeline so it can fan-out to remote services.
        if let sink = scrobbleSink {
            await sink.recordPlay(trackID: trackID, playedAt: playedAtDate, durationPlayed: durationPlayed)
        }
    }

    private func recordSkip(trackID: Int64, elapsed: TimeInterval) async {
        do {
            try await self.db.write { db in
                try db.execute(
                    sql: """
                    UPDATE tracks
                    SET skip_count = skip_count + 1,
                        skip_after_seconds = CASE
                            WHEN skip_after_seconds IS NULL THEN ?
                            ELSE (skip_after_seconds + ?) / 2.0
                        END
                    WHERE id = ?
                    """,
                    arguments: [elapsed, elapsed, trackID]
                )
            }
            self.log.debug("history.skip", ["trackID": trackID, "elapsed": elapsed])
        } catch {
            self.log.error("history.skip.failed", ["error": String(reflecting: error)])
        }
    }
}
