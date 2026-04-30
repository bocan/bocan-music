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
}
