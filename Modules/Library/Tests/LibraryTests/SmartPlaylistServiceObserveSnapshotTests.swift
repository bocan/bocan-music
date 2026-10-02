import Foundation
import Testing
@testable import Library
@testable import Persistence

/// Counts the emissions of an observation stream from a collector task.
private actor Counter {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }

    func read() -> Int {
        self.value
    }
}

@Suite("SmartPlaylistService observation and snapshot mode")
struct SmartPlaylistServiceObserveSnapshotTests: SmartPlaylistServiceFixtures {
    // MARK: - Observation stream

    @Test func observeEmitsInitialResults() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let loved = try await insertTrack(in: db, fileURL: "file:///loved.mp3", loved: true)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let playlist = try await svc.create(name: "Loved", criteria: criteria)
        guard let pid = playlist.id else { Issue.record("no id")
            return
        }

        let stream = await svc.observe(pid)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let ids = first?.compactMap(\.id) ?? []
        #expect(ids.contains(loved))
    }

    @Test func observeCoalescesPlayCountBurst() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)

        let defaults = UserDefaults.standard
        let key = SmartPlaylistPreferences.observeDebounceMillisecondsKey
        let previous = defaults.object(forKey: key)
        defaults.set(250, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let trackID = try await insertTrack(in: db, fileURL: "file:///burst.mp3", playCount: 0)
        let criteria = SmartCriterion.rule(.init(field: .playCount, comparator: .greaterThanOrEqual, value: .int(0)))
        let playlist = try await svc.create(name: "PlayCount Burst", criteria: criteria)
        guard let playlistID = playlist.id else {
            Issue.record("missing playlist id")
            return
        }

        let stream = await svc.observe(playlistID)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // initial emission

        let counter = Counter()

        let collector = Task {
            do {
                while try await iterator.next() != nil {
                    await counter.increment()
                }
            } catch {
                // Cancellation is expected at test teardown.
            }
        }

        for _ in 0 ..< 100 {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE tracks SET play_count = play_count + 1 WHERE id = ?",
                    arguments: [trackID]
                )
            }
            try await Task.sleep(nanoseconds: 2_000_000) // ~200ms total burst
        }

        try await Task.sleep(nanoseconds: 700_000_000) // allow trailing debounce flush
        collector.cancel()

        let emissionCount = await counter.read()
        #expect(emissionCount >= 1)
        #expect(emissionCount <= 2)
    }

    // MARK: - Snapshot mode (liveUpdate = false)

    @Test func snapshotPersistsAndDoesNotReExecuteQuery() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let trackA = try await insertTrack(in: db, fileURL: "file:///a.mp3", loved: true)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let ls = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: false)
        let playlist = try await svc.create(name: "Loved Snapshot", criteria: criteria, limitSort: ls)
        guard let pid = playlist.id else {
            Issue.record("no id")
            return
        }

        // After create with liveUpdate=false, the snapshot must already
        // contain the matching track via auto-snapshot.
        var ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids == [trackA])

        // Mutate the library: add a new loved track that the live query
        // would match. The snapshot must NOT change until refresh.
        let trackB = try await insertTrack(in: db, fileURL: "file:///b.mp3", loved: true)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids == [trackA], "snapshot must be frozen until snapshot(id:) is called")

        // Explicit snapshot picks up trackB.
        let count = try await svc.snapshot(id: pid)
        #expect(count == 2)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))
    }

    @Test func snapshotStableUntilRefreshedWhenSourceRowsChange() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let trackRepo = TrackRepository(database: db)

        let loved = try await insertTrack(in: db, fileURL: "file:///stable_loved.mp3", loved: true)
        let unloved = try await insertTrack(in: db, fileURL: "file:///stable_unloved.mp3", loved: false)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let ls = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: false)
        let playlist = try await svc.create(name: "Stable Snapshot", criteria: criteria, limitSort: ls)
        guard let pid = playlist.id else {
            Issue.record("no id")
            return
        }

        var ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids == [loved])

        // Change a criterion source-table row (`tracks.loved`) so the live
        // query result would differ. Snapshot mode must stay frozen.
        var mutable = try await trackRepo.fetch(id: unloved)
        mutable.loved = true
        try await trackRepo.update(mutable)

        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids == [loved], "snapshot must not auto-update on source row changes")

        _ = try await svc.snapshot(playlistID: pid)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([loved, unloved]))
    }

    @Test func snapshotWritesLastSnapshotTimestamp() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        _ = try await self.insertTrack(in: db, fileURL: "file:///ts.mp3", loved: true)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let ls = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: false)
        let playlist = try await svc.create(name: "Timestamped", criteria: criteria, limitSort: ls)
        guard let pid = playlist.id else {
            Issue.record("no id")
            return
        }

        let first = try await svc.resolve(id: pid).playlist.smartLastSnapshotAt
        #expect(first != nil)

        _ = try await svc.snapshot(playlistID: pid)
        let second = try await svc.resolve(id: pid).playlist.smartLastSnapshotAt
        #expect(second != nil)
        #expect((second ?? 0) >= (first ?? 0))
    }

    @Test func updateSwitchingBetweenLiveAndSnapshot() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let trackA = try await insertTrack(in: db, fileURL: "file:///a.mp3", loved: true)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let live = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: true)
        let playlist = try await svc.create(name: "Loved", criteria: criteria, limitSort: live)
        guard let pid = playlist.id else {
            Issue.record("no id")
            return
        }

        // In live mode, adding a track should be reflected immediately.
        let trackB = try await insertTrack(in: db, fileURL: "file:///b.mp3", loved: true)
        var ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Switch to snapshot mode via update: auto-snapshots current matches.
        let snap = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: false)
        try await svc.update(id: pid, criteria: criteria, limitSort: snap)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Add a third loved track: should NOT appear until refresh.
        _ = try await self.insertTrack(in: db, fileURL: "file:///c.mp3", loved: true)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Switch back to live: stored snapshot rows are cleared and the
        // live query takes over.
        try await svc.update(id: pid, criteria: criteria, limitSort: live)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids.count == 3)
    }

    @Test func shuffleSeedRegeneratesPersistedSeed() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let playlist = try await svc.create(
            name: "Randomized",
            criteria: criteria,
            limitSort: LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        )
        guard let pid = playlist.id else {
            Issue.record("no id")
            return
        }

        let before = try await svc.resolve(id: pid).playlist.smartRandomSeed
        #expect(before != nil)

        let first = try await svc.shuffleSeed(id: pid)
        let afterFirst = try await svc.resolve(id: pid).playlist.smartRandomSeed
        #expect(afterFirst == first)

        let second = try await svc.shuffleSeed(id: pid)
        let afterSecond = try await svc.resolve(id: pid).playlist.smartRandomSeed
        #expect(afterSecond == second)
        #expect(first != second)
    }
}
