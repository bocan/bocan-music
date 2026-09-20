import Foundation
import Library
import Observation
import Persistence
import Testing
@testable import UI

// MARK: - LyricsMenuStateTests

/// #546: the Track menu's Fetch Lyrics and Clear Lyrics items gated on
/// `LyricsViewModel`'s `@Published` values, which a `Commands` body cannot
/// observe, so they froze until the track changed. The menu now reads the
/// `@Observable` `menuState`. These tests pin the mirror and, because the whole
/// point is observability, that a flip is visible to `withObservationTracking`.
@Suite("Lyrics menu state (#546)")
@MainActor
struct LyricsMenuStateTests {
    private func seedTrack(db: Database, withLyrics: Bool) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let trackID = try await TrackRepository(database: db).upsert(Track(
            fileURL: "/tmp/menu-state.flac",
            fileSize: 0,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 60,
            addedAt: now,
            updatedAt: now
        ))
        if withLyrics {
            try await LyricsRepository(database: db).save(Lyrics(
                trackID: trackID,
                lyricsText: "[00:10.00]One\n[00:20.00]Two",
                isSynced: true,
                source: "user",
                offsetMS: 0
            ))
        }
        return trackID
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Records whether an `@Observable` read was invalidated, which is exactly
    /// what a `Commands` body relies on.
    private final class ChangeFlag: @unchecked Sendable {
        var fired = false
    }

    @Test("hasDocument follows the document: set on load, cleared by Clear Lyrics and by a track change")
    func hasDocumentMirrorsDocument() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await seedTrack(db: db, withLyrics: true)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))
        #expect(!vm.menuState.hasDocument, "nothing is loaded before the first track")

        vm.trackDidChange(trackID: trackID)
        await self.waitUntil { vm.menuState.hasDocument }
        #expect(vm.menuState.hasDocument)
        #expect(vm.document != nil)

        // The menu's own Clear Lyrics action: the item must then disable
        // itself without waiting for the next track.
        vm.clearLyrics(for: trackID)
        await self.waitUntil { !vm.menuState.hasDocument }
        #expect(!vm.menuState.hasDocument)
        #expect(vm.document == nil)

        vm.trackDidChange(trackID: nil)
        #expect(!vm.menuState.hasDocument)
    }

    @Test("a document landing invalidates an @Observable read, as a Commands body needs")
    func documentLandingIsObservable() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await seedTrack(db: db, withLyrics: true)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))

        let flag = ChangeFlag()
        withObservationTracking {
            _ = vm.menuState.hasDocument
        } onChange: {
            flag.fired = true
        }

        vm.trackDidChange(trackID: trackID)
        await self.waitUntil { flag.fired }
        #expect(flag.fired, "the menu would stay frozen if this read were not tracked")
    }

    @Test("isFetching is raised for the length of a fetch and lowered after it")
    func isFetchingMirrorsFetch() async throws {
        let db = try await Database(location: .inMemory)
        let trackID = try await seedTrack(db: db, withLyrics: false)
        let vm = LyricsViewModel(service: LyricsService(database: db, fetcher: nil))

        let flag = ChangeFlag()
        withObservationTracking {
            _ = vm.menuState.isFetching
        } onChange: {
            flag.fired = true
        }

        // No LRClib client is configured, so the fetch ends at once; the flag
        // must still go up synchronously (so a second click is refused) and
        // come back down.
        vm.forceFetch(for: trackID)
        #expect(vm.menuState.isFetching)
        #expect(flag.fired)

        await self.waitUntil { !vm.menuState.isFetching }
        #expect(!vm.menuState.isFetching)
        #expect(!vm.isFetching)
    }

    @Test("an unchanged value is not written again, so the menu bar is not rebuilt for nothing")
    func unchangedValueDoesNotInvalidate() {
        let state = LyricsMenuState()
        state.update(hasDocument: true)

        let flag = ChangeFlag()
        withObservationTracking {
            _ = state.hasDocument
        } onChange: {
            flag.fired = true
        }

        state.update(hasDocument: true)
        #expect(!flag.fired, "one document replacing another must not invalidate the menu")

        state.update(hasDocument: false)
        #expect(flag.fired)
    }
}
