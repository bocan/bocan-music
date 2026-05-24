import Foundation
import Observability
import Persistence

// MARK: - ScrobbleSink

/// Snapshot of a Subsonic-sourced play. Carries everything a remote provider
/// needs since Subsonic songs are never written to the local `tracks` table
/// and so cannot be looked up by `trackID` later in the pipeline.
public struct SubsonicPlayContext: Sendable, Equatable {
    public let serverID: UUID
    public let songID: String
    public let title: String
    public let artist: String
    public let albumArtist: String?
    public let album: String?
    public let duration: TimeInterval

    public init(
        serverID: UUID,
        songID: String,
        title: String,
        artist: String,
        albumArtist: String? = nil,
        album: String? = nil,
        duration: TimeInterval
    ) {
        self.serverID = serverID
        self.songID = songID
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.duration = duration
    }
}

/// Downstream consumer of recorded plays. The `Scrobble` module supplies the
/// production implementation; tests can pass a no-op or capture for assertions.
///
/// Decoupled via this protocol so `Playback` doesn't depend on `Scrobble`.
public protocol ScrobbleSink: Sendable {
    func recordPlay(trackID: Int64, playedAt: Date, durationPlayed: TimeInterval) async
    /// Best-effort "now playing" hint sent when a track starts. Defaults to no-op
    /// so existing test sinks don't need updating.
    func nowPlaying(trackID: Int64) async
    /// Subsonic-sourced play. Default implementation is a no-op so existing
    /// sinks don't need updating.
    func recordSubsonicPlay(
        context: SubsonicPlayContext,
        playedAt: Date,
        durationPlayed: TimeInterval
    ) async
    /// Subsonic-sourced now-playing hint. Default implementation is a no-op.
    func nowPlayingSubsonic(context: SubsonicPlayContext) async
}

public extension ScrobbleSink {
    func nowPlaying(trackID _: Int64) async {}
    func recordSubsonicPlay(
        context _: SubsonicPlayContext,
        playedAt _: Date,
        durationPlayed _: TimeInterval
    ) async {}
    func nowPlayingSubsonic(context _: SubsonicPlayContext) async {}
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
    private var currentSubsonicContext: SubsonicPlayContext?

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
        self.currentSubsonicContext = nil
        self.log.debug("history.start", ["trackID": trackID, "duration": duration])
        // Fire-and-forget: the Now Playing hint to scrobbling services is best-effort
        // and must never block the playback hot path (engine.play() follows immediately).
        if let sink = scrobbleSink {
            Task { await sink.nowPlaying(trackID: trackID) }
        }
    }

    /// Call when a Subsonic-sourced track starts playing. The full context is
    /// retained because Subsonic songs have no row in the local `tracks` table
    /// for downstream lookup.
    public func trackDidStart(subsonic context: SubsonicPlayContext) async {
        self.currentTrackID = nil
        self.trackDuration = context.duration
        self.playStartedAt = Date()
        self.hasScrobbled = false
        self.currentSubsonicContext = context
        self.log.debug("history.start.subsonic", [
            "server": context.serverID.uuidString,
            "song": context.songID,
            "duration": context.duration,
        ])
        if let sink = scrobbleSink {
            let ctx = context
            Task { await sink.nowPlayingSubsonic(context: ctx) }
        }
    }

    /// Call periodically (or at track end) with the elapsed time so far.
    public func update(elapsed: TimeInterval) async {
        guard !self.hasScrobbled else { return }
        let shouldScrobble = self.meetsThreshold(elapsed: elapsed, duration: self.trackDuration)
        guard shouldScrobble else { return }
        if let ctx = currentSubsonicContext {
            await self.scrobbleSubsonic(context: ctx, durationPlayed: elapsed)
        } else if let id = currentTrackID {
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        }
    }

    /// Call when the user skips before the threshold. Records a skip event.
    public func trackSkipped(elapsed: TimeInterval) async {
        defer {
            currentTrackID = nil
            currentSubsonicContext = nil
            trackDuration = 0
            playStartedAt = nil
            hasScrobbled = false
        }

        let metThreshold = self.meetsThreshold(elapsed: elapsed, duration: self.trackDuration)
        if let ctx = currentSubsonicContext {
            if metThreshold {
                await self.scrobbleSubsonic(context: ctx, durationPlayed: elapsed)
            }
            // Subsonic plays have no local tracks row to bump skip_count against.
            return
        }
        guard let id = currentTrackID else { return }
        if metThreshold {
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        } else {
            await self.recordSkip(trackID: id, elapsed: elapsed)
        }
    }

    /// Call when the track ends naturally (completes playing).
    public func trackDidEnd(elapsed: TimeInterval) async {
        defer {
            currentTrackID = nil
            currentSubsonicContext = nil
            trackDuration = 0
            playStartedAt = nil
            hasScrobbled = false
        }
        if self.hasScrobbled { return }
        if let ctx = currentSubsonicContext {
            await self.scrobbleSubsonic(context: ctx, durationPlayed: elapsed)
        } else if let id = currentTrackID {
            await self.scrobble(trackID: id, durationPlayed: elapsed, source: "queue")
        }
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

    /// Scrobble path for Subsonic-sourced plays. Skips the local
    /// `play_history` insert and `tracks` UPDATE entirely (the song has no
    /// row in either) and just hands the play to the scrobble pipeline.
    private func scrobbleSubsonic(context: SubsonicPlayContext, durationPlayed: TimeInterval) async {
        guard !self.hasScrobbled else { return }
        self.hasScrobbled = true
        let playedAt = Date()
        self.log.debug("history.scrobbled.subsonic", [
            "server": context.serverID.uuidString,
            "song": context.songID,
            "duration": durationPlayed,
        ])
        if let sink = scrobbleSink {
            await sink.recordSubsonicPlay(context: context, playedAt: playedAt, durationPlayed: durationPlayed)
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
