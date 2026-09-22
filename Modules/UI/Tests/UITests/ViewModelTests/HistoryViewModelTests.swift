import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - HistoryViewModelTests

/// The History destination's view model (ADR-094): rows from the repository,
/// a version that moves with them, a query debounced into the term the
/// observation runs on, and plays resolved back to songs for actions.
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

    /// A song plus `plays` plays of it, one second apart. Returns the track id.
    private func insertSong(into db: Database, title: String, plays: Int) async throws -> Int64 {
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

    @Test("track(forPlayID:) resolves a play to its song, and nil for an unknown play")
    func trackForPlay() async throws {
        let db = try await self.makeDatabase()
        let trackID = try await self.insertSong(into: db, title: "Say Anything", plays: 1)
        let vm = self.makeViewModel(db)
        await vm.load()
        let playID = try #require(vm.rows.first?.playID)

        let track = await vm.track(forPlayID: playID)
        let missing = await vm.track(forPlayID: playID + 1000)

        #expect(track?.id == trackID)
        #expect(track?.title == "Say Anything")
        #expect(missing == nil)
    }
}
