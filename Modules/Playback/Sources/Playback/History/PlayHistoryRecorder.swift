import Foundation
import Observability
import Persistence

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
    private let log = AppLogger.make(.playback)

    // MARK: - Tracking state

    private var currentTrackID: Int64?
    private var trackDuration: TimeInterval = 0
    private var playStartedAt: Date?
    private var hasScrobbled = false

    // MARK: - Init

    public init(database: Database) {
        self.db = database
        self.trackRepo = TrackRepository(database: database)
    }

    // MARK: - Public API

    /// Call when a new track starts playing.
    public func trackDidStart(trackID: Int64, duration: TimeInterval) {
        self.currentTrackID = trackID
        self.trackDuration = duration
        self.playStartedAt = Date()
        self.hasScrobbled = false
        self.log.debug("history.start", ["trackID": trackID, "duration": duration])
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

        let playedAt = Int64(Date().timeIntervalSince1970)

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
