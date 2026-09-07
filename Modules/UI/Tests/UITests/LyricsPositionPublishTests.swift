import Combine
import Foundation
import Library
import Metadata
import Persistence
import Testing
@testable import UI

// MARK: - LyricsPositionPublishTests

/// #450: `LyricsViewModel.positionDidChange` runs on every 0.5 s playback tick.
/// A `@Published` assignment emits `objectWillChange` even when the value is
/// unchanged, and every `@ObservedObject` / `@EnvironmentObject` consumer of the
/// model (the root view, the tracks view) re-renders on each emission, which
/// ends in the songs table re-diffing every row twice a second. The model must
/// publish from a tick only when the highlighted line actually moves.
@Suite("LyricsViewModel publishes from a position tick only on a line change")
@MainActor
struct LyricsPositionPublishTests {
    private func seedSynced(db: Database) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let trackID = try await TrackRepository(database: db).upsert(Track(
            fileURL: "/tmp/publish.flac",
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
            offsetMS: 0
        ))
        return trackID
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("no document: repeated ticks never publish")
    func noDocumentTicksAreSilent() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))
        var emissions = 0
        let sink = vm.objectWillChange.sink { emissions += 1 }
        defer { sink.cancel() }

        for tick in 0 ..< 10 {
            vm.positionDidChange(TimeInterval(tick) * 0.5)
        }

        #expect(emissions == 0, "an unsynced tick republished an unchanged nil index")
        #expect(vm.currentLineIndex == nil)
    }

    @Test("synced document: ticks publish once per line change and not otherwise")
    func syncedTicksPublishOnlyOnLineChange() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await self.seedSynced(db: db)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))
        vm.trackDidChange(trackID: trackID)
        await self.waitUntil { vm.document != nil }
        try #require(vm.document != nil)

        var emissions = 0
        let sink = vm.objectWillChange.sink { emissions += 1 }
        defer { sink.cancel() }

        // Before line one: index stays nil, nothing to publish.
        for tick in 0 ..< 4 {
            vm.positionDidChange(TimeInterval(tick) * 0.5)
        }
        #expect(emissions == 0)

        // Crossing into line one publishes once; holding there publishes nothing.
        vm.positionDidChange(10.2)
        #expect(vm.currentLineIndex == 0)
        #expect(emissions == 1)
        vm.positionDidChange(10.7)
        vm.positionDidChange(11.2)
        #expect(emissions == 1)

        // Line two: one more.
        vm.positionDidChange(20.3)
        #expect(vm.currentLineIndex == 1)
        #expect(emissions == 2)
    }
}
