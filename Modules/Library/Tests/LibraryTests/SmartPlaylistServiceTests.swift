import Foundation
import Testing
@testable import Library
@testable import Persistence

@Suite("SmartPlaylistService")
struct SmartPlaylistServiceTests {
    // MARK: - Helpers

    private func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    private func makeService(db: Persistence.Database) -> SmartPlaylistService {
        SmartPlaylistService(database: db)
    }

    /// Inserts a bare track and returns its row ID.
    private func insertTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track",
        rating: Int = 0,
        playCount: Int = 0,
        loved: Bool = false,
        genre: String? = nil
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        track.rating = rating
        track.playCount = playCount
        track.loved = loved
        track.genre = genre
        let repo = TrackRepository(database: db)
        return try await repo.insert(track) ?? -1
    }

    // MARK: - CRUD: create

    @Test func createPersists() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let playlist = try await svc.create(name: "Loved", criteria: criteria)
        #expect(playlist.id != nil)
        #expect(playlist.name == "Loved")
        #expect(playlist.kind == .smart)
        #expect(playlist.smartRandomSeed != nil)
    }

    @Test func createAppearsInListAll() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "LikedTracks", criteria: criteria)
        let all = try await svc.listAll()
        #expect(all.contains { $0.id == p.id })
    }

    @Test func createWithPresetKey() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "Loved", criteria: criteria, presetKey: "loved")
        #expect(p.smartPresetKey == "loved")
    }

    // MARK: - CRUD: update

    @Test func updateChangesCriteria() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let original = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "Test", criteria: original)
        guard let id = p.id else { Issue.record("no id")
            return
        }

        let updated = SmartCriterion.rule(.init(field: .rating, comparator: .greaterThan, value: .int(80)))
        try await svc.update(id: id, criteria: updated, limitSort: LimitSort())
        let resolved = try await svc.resolve(id: id)
        #expect(resolved.criteria == updated)
    }

    @Test func updateNonExistentThrows() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        await #expect(throws: SmartPlaylistError.self) {
            try await svc.update(id: 9999, criteria: criteria, limitSort: LimitSort())
        }
    }

    // MARK: - CRUD: delete

    @Test func deleteRemovesPlaylist() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "ToDelete", criteria: criteria)
        guard let id = p.id else { Issue.record("no id")
            return
        }
        try await svc.delete(id: id)
        let all = try await svc.listAll()
        #expect(!all.contains { $0.id == id })
    }

    // MARK: - tracks(for:): filtering

    @Test func tracksForRatingFilter() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let id1 = try await insertTrack(in: db, fileURL: "file:///t1.mp3", rating: 90)
        let id2 = try await insertTrack(in: db, fileURL: "file:///t2.mp3", rating: 50)
        let id3 = try await insertTrack(in: db, fileURL: "file:///t3.mp3", rating: 100)
        _ = id2 // not expected in results

        let criteria = SmartCriterion.rule(.init(field: .rating, comparator: .greaterThanOrEqual, value: .int(80)))
        let p = try await svc.create(name: "HighRating", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(id1))
        #expect(ids.contains(id3))
        #expect(!ids.contains(id2))
    }

    @Test func tracksForLovedFilter() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let loved = try await insertTrack(in: db, fileURL: "file:///loved.mp3", loved: true)
        let unloved = try await insertTrack(in: db, fileURL: "file:///unloved.mp3", loved: false)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "Loved", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(loved))
        #expect(!ids.contains(unloved))
    }

    @Test func tracksForPlayCountFilter() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let played = try await insertTrack(in: db, fileURL: "file:///played.mp3", playCount: 10)
        let unplayed = try await insertTrack(in: db, fileURL: "file:///unplayed.mp3", playCount: 0)

        let criteria = SmartCriterion.rule(.init(field: .playCount, comparator: .greaterThan, value: .int(0)))
        let p = try await svc.create(name: "Played", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(played))
        #expect(!ids.contains(unplayed))
    }

    @Test func tracksForTitleContainsFilter() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let jazz = try await insertTrack(in: db, fileURL: "file:///jazz.mp3", title: "Jazz Night")
        let rock = try await insertTrack(in: db, fileURL: "file:///rock.mp3", title: "Rock Anthem")

        let criteria = SmartCriterion.rule(.init(field: .title, comparator: .contains, value: .text("Jazz")))
        let p = try await svc.create(name: "Jazz", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(jazz))
        #expect(!ids.contains(rock))
    }

    @Test func tracksForNestedGroupCriteria() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        // Matches: rating >= 80 AND loved = true
        let match = try await insertTrack(in: db, fileURL: "file:///match.mp3", rating: 90, loved: true)
        let highNotLoved = try await insertTrack(in: db, fileURL: "file:///hnl.mp3", rating: 90, loved: false)
        let lovedLowRating = try await insertTrack(in: db, fileURL: "file:///llr.mp3", rating: 50, loved: true)

        let criteria = SmartCriterion.group(.and, [
            .rule(.init(field: .rating, comparator: .greaterThanOrEqual, value: .int(80))),
            .rule(.init(field: .loved, comparator: .isTrue, value: .null)),
        ])
        let p = try await svc.create(name: "Best Loved", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(match))
        #expect(!ids.contains(highNotLoved))
        #expect(!ids.contains(lovedLowRating))
    }

    // MARK: - SQL injection resistance via service

    @Test func tracksForSqlInjectionYieldsNoResults() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        // Insert a track — the injection attempt should NOT match everything
        _ = try await self.insertTrack(in: db, fileURL: "file:///t.mp3", title: "Normal Track")

        let criteria = SmartCriterion.rule(.init(
            field: .title,
            comparator: .contains,
            value: .text("' OR 1=1 --")
        ))
        let p = try await svc.create(name: "Injection", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        // Should match 0 tracks, not dump the whole library
        #expect(tracks.isEmpty)
    }

    // MARK: - Limit & sort honoured

    @Test func limitHonoured() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        for i in 0 ..< 10 {
            _ = try await self.insertTrack(in: db, fileURL: "file:///t\(i).mp3", rating: 100)
        }
        let criteria = SmartCriterion.rule(.init(field: .rating, comparator: .equalTo, value: .int(100)))
        let ls = LimitSort(sortBy: .addedAt, ascending: false, limit: 3, liveUpdate: true)
        let p = try await svc.create(name: "Top3", criteria: criteria, limitSort: ls)
        guard let pid = p.id else { Issue.record("no id")
            return
        }

        let tracks = try await svc.tracks(for: pid)
        #expect(tracks.count == 3)
    }

    // MARK: - Resolve

    @Test func resolveReturnsSmartPlaylist() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let ls = LimitSort(sortBy: .rating, ascending: false, limit: 10, liveUpdate: true)
        let p = try await svc.create(name: "Resolved", criteria: criteria, limitSort: ls)
        guard let id = p.id else { Issue.record("no id")
            return
        }

        let sp = try await svc.resolve(id: id)
        #expect(sp.playlist.name == "Resolved")
        #expect(sp.criteria == criteria)
        #expect(sp.limitSort.sortBy == .rating)
        #expect(sp.limitSort.limit == 10)
    }

    @Test func resolveNotFoundThrows() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        await #expect(throws: SmartPlaylistError.self) {
            try await svc.resolve(id: 9999)
        }
    }

    // MARK: - Reject smart-playlist references

    @Test func createRejectsMemberOfSmartPlaylist() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        // Smart playlist A
        let a = try await svc.create(
            name: "A",
            criteria: .rule(.init(field: .loved, comparator: .isTrue, value: .null))
        )
        guard let aid = a.id else {
            Issue.record("missing id")
            return
        }
        // Smart playlist B references A via memberOf — must throw.
        let recursive = SmartCriterion.rule(.init(
            field: .inPlaylist,
            comparator: .memberOf,
            value: .playlistRef(aid)
        ))
        await #expect(throws: SmartPlaylistError.self) {
            _ = try await svc.create(name: "B", criteria: recursive)
        }
    }

    // MARK: - Built-in presets

    @Test func builtInPresetsSeeded() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        try await BuiltInSmartPresets.seed(using: svc)
        let all = try await svc.listAll()
        #expect(all.count >= 5, "Expected at least 5 presets, got \(all.count)")
        let keys = all.compactMap(\.smartPresetKey)
        #expect(keys.contains("builtin.loved"))
        #expect(keys.contains("builtin.never_played"))
    }

    @Test func builtInPresetsNotDuplicated() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        // Seed twice — should not duplicate
        try await BuiltInSmartPresets.seed(using: svc)
        try await BuiltInSmartPresets.seed(using: svc)
        let all = try await svc.listAll()
        let keys = all.compactMap(\.smartPresetKey)
        // Each key should appear exactly once
        let keySet = Set(keys)
        #expect(keys.count == keySet.count, "Duplicate preset keys found")
    }

    @Test func unratedPresetMatchesNullAndZero() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let zeroID = try await insertTrack(in: db, fileURL: "file:///zero.mp3", rating: 0)
        let ratedID = try await insertTrack(in: db, fileURL: "file:///rated.mp3", rating: 80)

        try await BuiltInSmartPresets.seed(using: svc)
        let all = try await svc.listAll()
        guard let unrated = all.first(where: { $0.smartPresetKey == "builtin.unrated" }),
              let pid = unrated.id else {
            Issue.record("Unrated preset not seeded")
            return
        }

        // Behavioural: rating = 0 matches, rating = 80 does not.
        let tracks = try await svc.tracks(for: pid)
        let ids = tracks.compactMap(\.id)
        #expect(ids.contains(zeroID), "rating = 0 should be Unrated")
        #expect(!ids.contains(ratedID), "rating = 80 must not be Unrated")

        // Defensive: verify the compiled SQL also includes the IS NULL branch
        // so future schema changes that allow NULL ratings remain covered by
        // this preset.
        let resolved = try await svc.resolve(id: pid)
        let compiled = try SQLBuilder.compile(criteria: resolved.criteria, limitSort: resolved.limitSort)
        #expect(compiled.selectSQL.contains("IS NULL"))
        #expect(compiled.selectSQL.contains("tracks.rating = ?"))
    }

    // MARK: - Observation stream

    @Test func observeEmitsInitialResults() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)
        let loved = try await insertTrack(in: db, fileURL: "file:///loved.mp3", loved: true)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(name: "Loved", criteria: criteria)
        guard let pid = p.id else { Issue.record("no id")
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

        actor Counter {
            private(set) var value = 0
            func increment() {
                self.value += 1
            }

            func read() -> Int {
                self.value
            }
        }
        let counter = Counter()

        let collector = Task {
            do {
                while let _ = try await iterator.next() {
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
        let p = try await svc.create(name: "Loved Snapshot", criteria: criteria, limitSort: ls)
        guard let pid = p.id else {
            Issue.record("no id")
            return
        }

        // After create with liveUpdate=false, the snapshot must already
        // contain the matching track via auto-snapshot.
        var ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids == [trackA])

        // Mutate the library — add a new loved track that the live query
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
        let p = try await svc.create(name: "Stable Snapshot", criteria: criteria, limitSort: ls)
        guard let pid = p.id else {
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
        let p = try await svc.create(name: "Timestamped", criteria: criteria, limitSort: ls)
        guard let pid = p.id else {
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
        let p = try await svc.create(name: "Loved", criteria: criteria, limitSort: live)
        guard let pid = p.id else {
            Issue.record("no id")
            return
        }

        // In live mode, adding a track should be reflected immediately.
        let trackB = try await insertTrack(in: db, fileURL: "file:///b.mp3", loved: true)
        var ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Switch to snapshot mode via update — auto-snapshots current matches.
        let snap = LimitSort(sortBy: .addedAt, ascending: true, limit: nil, liveUpdate: false)
        try await svc.update(id: pid, criteria: criteria, limitSort: snap)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Add a third loved track — should NOT appear until refresh.
        _ = try await self.insertTrack(in: db, fileURL: "file:///c.mp3", loved: true)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(Set(ids) == Set([trackA, trackB]))

        // Switch back to live — stored snapshot rows are cleared and the
        // live query takes over.
        try await svc.update(id: pid, criteria: criteria, limitSort: live)
        ids = try await svc.tracks(for: pid).compactMap(\.id)
        #expect(ids.count == 3)
    }

    @Test func shuffleSeedRegeneratesPersistedSeed() async throws {
        let db = try await makeDatabase()
        let svc = self.makeService(db: db)

        let criteria = SmartCriterion.rule(.init(field: .loved, comparator: .isTrue, value: .null))
        let p = try await svc.create(
            name: "Randomized",
            criteria: criteria,
            limitSort: LimitSort(sortBy: .random, ascending: true, limit: nil, liveUpdate: true)
        )
        guard let pid = p.id else {
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
