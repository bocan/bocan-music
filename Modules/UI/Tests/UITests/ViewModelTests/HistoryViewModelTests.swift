import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - HistoryViewModelTests

/// The History destination's view model (ADR-094): rows from the repository,
/// a version that moves with them, a query debounced into the term the
/// observation runs on, a source filter and a paged window, and listens
/// resolved back to songs for actions.
@Suite("HistoryViewModel")
@MainActor
struct HistoryViewModelTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private var now: Int64 {
        1_700_000_000
    }

    /// Awaits the pending debounce, if any, instead of sleeping past it: a
    /// fixed sleep raced the 250 ms timer under a loaded parallel run.
    private func settle(_ vm: HistoryViewModel) async throws {
        guard let task = vm.debounceTask else { return }
        try await task.value
    }

    private func makeViewModel(_ db: Database) -> HistoryViewModel {
        HistoryViewModel(
            repository: PlayHistoryRepository(database: db),
            trackRepository: TrackRepository(database: db)
        )
    }

    /// A song plus `plays` local plays and `imported` matched listens of it,
    /// one second apart. Returns the track id.
    private func insertSong(into db: Database, title: String, plays: Int, imported: Int = 0) async throws -> Int64 {
        let artistID = try await ArtistRepository(database: db).insert(Artist(name: "Wade Bowen"))
        let track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: self.now,
            fileFormat: "flac",
            duration: 245,
            title: title,
            artistID: artistID,
            addedAt: self.now,
            updatedAt: self.now
        )
        let trackID = try await TrackRepository(database: db).insert(track)
        let now = self.now
        try await db.write { db in
            for offset in 0 ..< plays {
                try db.execute(
                    sql: """
                    INSERT INTO play_history (track_id, played_at, duration_played, source)
                    VALUES (?, ?, 130, 'queue')
                    """,
                    arguments: [trackID, now + Int64(offset)]
                )
            }
            for offset in 0 ..< imported {
                try db.execute(
                    sql: """
                    INSERT INTO imported_listens (source, played_at, artist, title, track_id)
                    VALUES ('lastfm', ?, 'Wade Bowen', ?, ?)
                    """,
                    arguments: [now + 1000 + Int64(offset), title, trackID]
                )
            }
        }
        return trackID
    }

    // MARK: - Loading

    @Test("load fills the rows, newest first, and moves the rows version")
    func loadFillsRows() async throws {
        let db = try await self.makeDatabase()
        _ = try await self.insertSong(into: db, title: "Say Anything", plays: 3)
        let vm = self.makeViewModel(db)
        let before = vm.rowsVersion

        await vm.load()

        #expect(vm.rows.count == 3)
        #expect(vm.rows.map(\.playedAt) == [self.now + 2, self.now + 1, self.now])
        #expect(vm.rowsVersion == before + 1)
        #expect(!vm.isLoading)
        #expect(vm.hasLoaded)
    }

    @Test("An empty library loads to no rows, and reports it has loaded")
    func emptyLoad() async throws {
        let db = try await self.makeDatabase()
        let vm = self.makeViewModel(db)

        await vm.load()

        #expect(vm.rows.isEmpty)
        #expect(vm.hasLoaded, "an empty list must read as no plays, not as not loaded")
    }

    @Test("load applies the debounced query, not the live one")
    func loadUsesTheDebouncedQuery() async throws {
        let db = try await self.makeDatabase()
        _ = try await self.insertSong(into: db, title: "Say Anything", plays: 1)
        let vm = self.makeViewModel(db)

        vm.query = "zzzz"
        await vm.load()
        #expect(vm.rows.count == 1, "the live query has not been debounced yet, so no filter applies")

        try await self.settle(vm)
        await vm.load()
        #expect(vm.rows.isEmpty, "after the debounce the filter applies")
    }

    // MARK: - Source filter and paging (slice 3)

    @Test("The source filter narrows the rows and starts the window over")
    func sourceFilterNarrows() async throws {
        let db = try await self.makeDatabase()
        _ = try await self.insertSong(into: db, title: "Say Anything", plays: 2, imported: 3)
        let vm = self.makeViewModel(db)
        await vm.load()
        #expect(vm.rows.count == 5)
        vm.loadMore()

        vm.sourceFilter = .imported
        await vm.load()

        #expect(vm.rows.map(\.source) == [.imported, .imported, .imported])
        #expect(vm.pages == 1, "a filter change drops back to the first page")
        #expect(vm.observationKey.source == .imported)
    }

    @Test("loadMore widens the window one page at a time, and only while the window is full")
    func loadMoreWidensTheWindow() async throws {
        let db = try await self.makeDatabase()
        _ = try await self.insertSong(into: db, title: "Say Anything", plays: 2)
        let vm = self.makeViewModel(db)
        await vm.load()

        #expect(vm.limit == HistoryViewModel.pageSize)
        #expect(!vm.hasMore, "two rows do not fill a page")
        vm.loadMore()
        #expect(vm.pages == 1, "nothing to widen for")

        // The debounced query moving on also starts the window over.
        vm.query = "a"
        try await self.settle(vm)
        #expect(vm.pages == 1)
        #expect(vm.observationKey == HistoryViewModel.ObservationKey(query: "a", source: .all, pages: 1))
    }

    // MARK: - Debounce (contract 10)

    @Test("Two keystrokes inside 250 ms debounce to one term")
    func keystrokesDebounce() async throws {
        let db = try await self.makeDatabase()
        let vm = self.makeViewModel(db)

        vm.query = "s"
        let firstSettle = try #require(vm.debounceTask)
        vm.query = "sa"
        #expect(vm.debouncedQuery.isEmpty, "nothing has settled yet")
        #expect(firstSettle.isCancelled, "the second keystroke cancelled the first settle")

        try await self.settle(vm)

        #expect(vm.debouncedQuery == "sa", "one settle, to the last keystroke")
    }

    @Test("clearQuery drops both the live and the debounced term at once")
    func clearQueryIsImmediate() async throws {
        let db = try await self.makeDatabase()
        let vm = self.makeViewModel(db)
        vm.query = "sa"
        try await self.settle(vm)
        #expect(vm.debouncedQuery == "sa")
        vm.query = "sab"
        let pending = try #require(vm.debounceTask)

        vm.clearQuery()

        #expect(vm.query.isEmpty)
        #expect(vm.debouncedQuery.isEmpty, "no debounce wait on the way out")
        #expect(pending.isCancelled, "and no pending settle can bring it back")
    }

    // MARK: - Rows to songs

    @Test("track(forKey:) resolves a listen to its song, from either source, and nil for an unknown key")
    func trackForKey() async throws {
        let db = try await self.makeDatabase()
        let trackID = try await self.insertSong(into: db, title: "Say Anything", plays: 1, imported: 1)
        let vm = self.makeViewModel(db)
        await vm.load()
        let imported = try #require(vm.rows.first { $0.source == .imported })
        let local = try #require(vm.rows.first { $0.source == .local })

        let fromImported = await vm.track(forKey: imported.id)
        let fromLocal = await vm.track(forKey: local.id)
        let missing = await vm.track(forKey: PlayHistoryRow.Key(source: .local, rowID: local.rowID + 1000))

        #expect(fromImported?.id == trackID)
        #expect(fromLocal?.id == trackID)
        #expect(fromLocal?.title == "Say Anything")
        #expect(missing == nil)
    }
}
