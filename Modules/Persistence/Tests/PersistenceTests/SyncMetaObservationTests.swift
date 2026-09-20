import Foundation
import Testing
@testable import Persistence

// MARK: - SyncMetaObservationTests

/// #550: both Phone Sync observations tracked whole tables, so the end-of-play
/// write (`play_count`, `last_played_at`, `play_duration_total`) bumped the
/// manifest generation and started a whole-library transcode pass, and the
/// transcode pass re-armed itself through its own ledger writes.
///
/// Each test pairs the write that must be ignored with a write that must be
/// seen, so a region that observes nothing cannot pass.
@Suite("Sync meta observation regions")
struct SyncMetaObservationTests {
    /// Counts emissions of an observation stream, skipping the initial one.
    private actor EmissionCounter {
        private(set) var count = 0
        private var task: Task<Void, Never>?

        func start(_ stream: AsyncThrowingStream<Void, Error>) {
            self.task = Task { [weak self] in
                var isInitial = true
                do {
                    for try await _ in stream {
                        if isInitial {
                            isInitial = false
                            continue
                        }
                        await self?.increment()
                    }
                } catch {
                    // A cancelled or failed observation just stops counting;
                    // every assertion here is about the count.
                }
            }
        }

        private func increment() {
            self.count += 1
        }

        func stop() {
            self.task?.cancel()
            self.task = nil
        }

        /// Waits for the count to reach `target`, or gives up.
        func wait(forAtLeast target: Int, timeout: Duration = .seconds(2)) async -> Int {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, self.count < target {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return self.count
        }
    }

    private func seedTrack(_ database: Database) async throws -> Int64 {
        try await TrackRepository(database: database).insert(Track(
            fileURL: "file:///sync-region.flac",
            fileFormat: "flac",
            duration: 100,
            addedAt: 0,
            updatedAt: 0
        ))
    }

    /// The end-of-play write, exactly as `PlayHistoryRecorder` issues it.
    private func recordPlay(_ database: Database, trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE tracks
                SET play_count = play_count + 1,
                    last_played_at = 1,
                    play_duration_total = play_duration_total + 90
                WHERE id = ?
                """,
                arguments: [trackID]
            )
        }
    }

    // MARK: - The manifest generation region

    @Test("the narrowed region ignores an end-of-play write but sees a rating change")
    func narrowRegionIgnoresPlayCount() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let trackID = try await seedTrack(database)

        let counter = EmissionCounter()
        await counter.start(syncMeta.observeLibraryChanges(narrowTracksToManifestColumns: true))
        defer { Task { await counter.stop() } }
        try await Task.sleep(for: .milliseconds(200)) // let the initial emission land

        try await self.recordPlay(database, trackID: trackID)
        #expect(await counter.wait(forAtLeast: 1, timeout: .milliseconds(600)) == 0, "a play must not bump")

        // Positive control: a column the manifest carries must still emit.
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET rating = 4 WHERE id = ?", arguments: [trackID])
        }
        #expect(await counter.wait(forAtLeast: 1) >= 1, "a rating change must bump")
    }

    @Test("the wide region sees an end-of-play write, because a smart playlist can key on it")
    func wideRegionSeesPlayCount() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let trackID = try await seedTrack(database)

        let counter = EmissionCounter()
        await counter.start(syncMeta.observeLibraryChanges(narrowTracksToManifestColumns: false))
        defer { Task { await counter.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        try await self.recordPlay(database, trackID: trackID)
        #expect(await counter.wait(forAtLeast: 1) >= 1)
    }

    @Test("the narrowed region still sees a content hash arriving")
    func narrowRegionSeesContentHash() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let trackID = try await seedTrack(database)

        let counter = EmissionCounter()
        await counter.start(syncMeta.observeLibraryChanges(narrowTracksToManifestColumns: true))
        defer { Task { await counter.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        // A hash appearing is what makes a track eligible for the manifest.
        try await TrackRepository(database: database).setContentHash(trackID: trackID, hash: "abc")
        #expect(await counter.wait(forAtLeast: 1) >= 1)
    }

    // MARK: - The transcode-input region

    @Test("the transcode region ignores its own ledger writes but sees a target change")
    func transcodeRegionIgnoresLedger() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let trackID = try await seedTrack(database)

        let counter = EmissionCounter()
        await counter.start(syncMeta.observeTranscodeInputs())
        defer { Task { await counter.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        // A pass writes its ledger; that must not schedule another pass.
        try await SyncTranscodeRepository(database: database).upsert(SyncTranscode(
            trackID: trackID,
            preset: "opus96",
            sourceContentHash: "abc",
            sha256: "def",
            size: 1,
            createdAt: 0
        ))
        #expect(
            await counter.wait(forAtLeast: 1, timeout: .milliseconds(600)) == 0,
            "a ledger write must not re-arm the pass"
        )

        // Positive control: a column the predicate reads must still emit.
        try await TrackRepository(database: database).setContentHash(trackID: trackID, hash: "ghi")
        #expect(await counter.wait(forAtLeast: 1) >= 1)
    }

    @Test("the transcode region ignores an end-of-play write")
    func transcodeRegionIgnoresPlayCount() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let trackID = try await seedTrack(database)

        let counter = EmissionCounter()
        await counter.start(syncMeta.observeTranscodeInputs())
        defer { Task { await counter.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        try await self.recordPlay(database, trackID: trackID)
        #expect(await counter.wait(forAtLeast: 1, timeout: .milliseconds(600)) == 0)

        try await TrackRepository(database: database).setContentHash(trackID: trackID, hash: "jkl")
        #expect(await counter.wait(forAtLeast: 1) >= 1)
    }
}
