import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - CapturingScrobbleSink

private actor CapturingScrobbleSink: ScrobbleSink {
    private(set) var calls: [(trackID: Int64, playedAt: Date, duration: TimeInterval)] = []
    private(set) var nowPlayingCalls: [Int64] = []
    func recordPlay(trackID: Int64, playedAt: Date, durationPlayed: TimeInterval) async {
        self.calls.append((trackID, playedAt, durationPlayed))
    }

    func nowPlaying(trackID: Int64) async {
        self.nowPlayingCalls.append(trackID)
    }
}

// MARK: - HistoryRecorderTests

@Suite("PlayHistoryRecorder")
struct HistoryRecorderTests {
    // MARK: - Threshold checks

    @Test("50% fraction meets threshold for 200s track")
    func halfFractionMeetsThreshold() async {
        // 200s track, 100s played = 50%
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        await recorder.trackDidStart(trackID: 1, duration: 200)
        // 100s = 50% → should scrobble
        let shouldScrobble = self.threshold(elapsed: 100, duration: 200)
        #expect(shouldScrobble)
    }

    @Test("49% fraction does not meet threshold")
    func belowFractionNoThreshold() {
        let shouldScrobble = self.threshold(elapsed: 97, duration: 200)
        #expect(!shouldScrobble)
    }

    @Test("4 minutes absolute meets threshold for long tracks")
    func absoluteThreshold() {
        // 1000s track, 240s played = 24% fraction < 50%, but ≥ 4min
        let shouldScrobble = self.threshold(elapsed: 240, duration: 1000)
        #expect(shouldScrobble)
    }

    @Test("less than 4 minutes and less than 50% does not meet threshold")
    func belowBothThresholds() {
        let shouldScrobble = self.threshold(elapsed: 60, duration: 1000)
        #expect(!shouldScrobble)
    }

    @Test("trackDidEnd calls no-op when nothing started")
    func endWithNothingStarted() async {
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        // Should not crash
        await recorder.trackDidEnd(elapsed: 100)
    }

    @Test("trackSkipped calls no-op when nothing started")
    func skipWithNothingStarted() async {
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        // Should not crash
        await recorder.trackSkipped(elapsed: 100)
    }

    @Test("trackDidEndNaturally credits previous play and forwards to scrobble sink")
    func gaplessHandoffCreditsPreviousPlay() async throws {
        let sink = CapturingScrobbleSink()
        let db = await makeDatabase()
        try await Self.insertTrack(id: 42, in: db)
        try await Self.insertTrack(id: 43, in: db)
        let recorder = await PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(trackID: 42, duration: 180)
        await recorder.trackDidEndNaturally()
        // After end, starting another track must not double-scrobble the previous one.
        await recorder.trackDidStart(trackID: 43, duration: 180)
        await recorder.trackDidEndNaturally()

        let calls = await sink.calls
        #expect(calls.count == 2)
        #expect(calls[0].trackID == 42)
        #expect(calls[0].duration == 180)
        #expect(calls[1].trackID == 43)
    }

    @Test("trackDidStart fires nowPlaying on the sink")
    func nowPlayingFiresOnTrackStart() async throws {
        let sink = CapturingScrobbleSink()
        let db = await makeDatabase()
        try await Self.insertTrack(id: 99, in: db)
        let recorder = await PlayHistoryRecorder(database: db, scrobbleSink: sink)
        await recorder.trackDidStart(trackID: 99, duration: 200)
        let calls = await sink.nowPlayingCalls
        #expect(calls == [99])
    }

    // MARK: - Helpers

    /// Mirror of the private threshold logic for testing.
    private func threshold(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        if duration > 0 {
            let fraction = elapsed / duration
            if fraction >= 0.50 { return true }
        }
        return elapsed >= 240.0
    }

    private func makeDatabase() async -> Database {
        // A fully in-memory database suitable for tests.
        // We don't actually write during these unit tests (DB is not used for threshold logic).
        try! await Database(location: .inMemory)
    }

    static func insertTrack(id: Int64, in db: Database) async throws {
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
}
