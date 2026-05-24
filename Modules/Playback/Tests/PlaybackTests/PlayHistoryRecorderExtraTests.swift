import Foundation
import GRDB
import Persistence
import Testing
@testable import Playback

private actor SimpleSink: ScrobbleSink {
    private(set) var plays: [(Int64, TimeInterval)] = []
    private(set) var subsonicPlays: [SubsonicPlayContext] = []
    func recordPlay(trackID: Int64, playedAt _: Date, durationPlayed: TimeInterval) async {
        self.plays.append((trackID, durationPlayed))
    }

    func recordSubsonicPlay(
        context: SubsonicPlayContext,
        playedAt _: Date,
        durationPlayed _: TimeInterval
    ) async {
        self.subsonicPlays.append(context)
    }
}

private func makeDB() async throws -> Persistence.Database {
    try await Database(location: .inMemory)
}

private func insertTrack(id: Int64, db: Persistence.Database) async throws {
    try await db.write { db in
        try db.execute(
            sql: """
            INSERT INTO tracks (id, file_url, file_size, file_mtime, file_format, duration, added_at, updated_at)
            VALUES (?, ?, 0, 0, 'flac', 180, 0, 0)
            """,
            arguments: [id, "file:///tmp/track-\(id).flac"]
        )
    }
}

@Suite("PlayHistoryRecorder additional paths")
struct PlayHistoryRecorderExtraTests {
    @Test("update(elapsed:) scrobbles a local track when the threshold is met")
    func updateScrobblesLocal() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        try await insertTrack(id: 1, db: db)
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(trackID: 1, duration: 100)
        await recorder.update(elapsed: 60) // 60% > 50%
        let plays = await sink.plays
        #expect(plays.count == 1)
        #expect(plays[0].0 == 1)
        // Idempotent: a second update() doesn't double-scrobble.
        await recorder.update(elapsed: 80)
        let again = await sink.plays
        #expect(again.count == 1)
    }

    @Test("update(elapsed:) below threshold scrobbles nothing")
    func updateBelowThreshold() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        try await insertTrack(id: 2, db: db)
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(trackID: 2, duration: 200)
        await recorder.update(elapsed: 30) // 15%
        let plays = await sink.plays
        #expect(plays.isEmpty)
    }

    @Test("update(elapsed:) scrobbles a Subsonic play when the threshold is met")
    func updateScrobblesSubsonic() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        let ctx = SubsonicPlayContext(
            serverID: UUID(),
            songID: "song-1",
            title: "T",
            artist: "A",
            duration: 100
        )
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(subsonic: ctx)
        await recorder.update(elapsed: 60)
        let subs = await sink.subsonicPlays
        #expect(subs.count == 1)
    }

    @Test("trackSkipped above threshold scrobbles the play (local)")
    func skipAboveThresholdScrobbles() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        try await insertTrack(id: 3, db: db)
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(trackID: 3, duration: 100)
        await recorder.trackSkipped(elapsed: 80)
        let plays = await sink.plays
        #expect(plays.count == 1)
    }

    @Test("trackSkipped below threshold increments skip_count (local)")
    func skipBelowThresholdRecordsSkip() async throws {
        let db = try await makeDB()
        try await insertTrack(id: 4, db: db)
        let recorder = PlayHistoryRecorder(database: db)
        await recorder.trackDidStart(trackID: 4, duration: 200)
        await recorder.trackSkipped(elapsed: 10) // way below threshold
        let skipCount: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT skip_count FROM tracks WHERE id = 4") ?? -1
        }
        #expect(skipCount == 1)
    }

    @Test("trackSkipped above threshold scrobbles a Subsonic play")
    func skipSubsonicAboveThreshold() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        let ctx = SubsonicPlayContext(
            serverID: UUID(), songID: "x", title: "T", artist: "A", duration: 100
        )
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(subsonic: ctx)
        await recorder.trackSkipped(elapsed: 80)
        let subs = await sink.subsonicPlays
        #expect(subs.count == 1)
    }

    @Test("trackSkipped below threshold on Subsonic play is a no-op")
    func skipSubsonicBelowThreshold() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        let ctx = SubsonicPlayContext(
            serverID: UUID(), songID: "y", title: "T", artist: "A", duration: 100
        )
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(subsonic: ctx)
        await recorder.trackSkipped(elapsed: 5)
        let subs = await sink.subsonicPlays
        #expect(subs.isEmpty)
    }

    @Test("trackDidEnd on a Subsonic context forwards to the sink")
    func endSubsonicForwards() async throws {
        let sink = SimpleSink()
        let db = try await makeDB()
        let ctx = SubsonicPlayContext(
            serverID: UUID(), songID: "z", title: "T", artist: "A", duration: 100
        )
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(subsonic: ctx)
        await recorder.trackDidEnd(elapsed: 100)
        let subs = await sink.subsonicPlays
        #expect(subs.count == 1)
    }
}
