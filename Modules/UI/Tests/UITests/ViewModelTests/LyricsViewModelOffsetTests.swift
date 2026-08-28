import Foundation
import Library
import Metadata
import Persistence
import Testing
@testable import UI

@Suite("LyricsViewModel sync offset")
@MainActor
struct LyricsViewModelOffsetTests {
    private func seed(db: Database, offsetMS: Int) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let trackID = try await TrackRepository(database: db).upsert(Track(
            fileURL: "/tmp/offset.flac",
            fileSize: 0,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 60,
            addedAt: now,
            updatedAt: now
        ))
        try await LyricsRepository(database: db).save(Lyrics(
            trackID: trackID,
            lyricsText: "[00:10.00]One\n[00:20.00]Two",
            isSynced: true,
            source: "user",
            offsetMS: offsetMS
        ))
        return trackID
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("the stored offset loads on track change and commitOffset persists a new value (#415)")
    func offsetLoadsAndPersists() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await seed(db: db, offsetMS: 300)
        let service = LyricsService(database: db, fetcher: nil)
        let vm = LyricsViewModel(service: service)

        vm.trackDidChange(trackID: trackID)
        await self.waitUntil { vm.userOffsetMS == 300 }
        #expect(vm.userOffsetMS == 300, "slider reflects the saved adjustment")

        vm.userOffsetMS = 500
        vm.commitOffset()
        var stored = 0
        for _ in 0 ..< 100 where stored != 500 {
            try? await Task.sleep(for: .milliseconds(20))
            stored = try await service.userOffsetMS(for: trackID)
        }
        #expect(stored == 500)

        // A new track starts from its own stored value, not the previous slider position.
        vm.trackDidChange(trackID: nil)
        #expect(vm.userOffsetMS == 0)
    }

    @Test("position maths applies only the unsaved delta on top of the folded document")
    func positionUsesDeltaOnly() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await seed(db: db, offsetMS: 1000)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))
        vm.trackDidChange(trackID: trackID)
        await self.waitUntil { vm.userOffsetMS == 1000 && vm.document != nil }

        // Document offset already includes the 1000 ms; at 10.5 s playback the
        // adjusted position is 9.5 s, before line one.
        vm.positionDidChange(10.5)
        #expect(vm.currentLineIndex == nil)
        vm.positionDidChange(11.5)
        #expect(vm.currentLineIndex == 0)

        // Moving the slider without saving shifts by the delta only.
        vm.userOffsetMS = 0
        vm.positionDidChange(10.5)
        #expect(vm.currentLineIndex == 0)
    }
}
