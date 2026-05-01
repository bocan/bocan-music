import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - SmartPlaylistDetailViewModelTests

@Suite("SmartPlaylistDetailViewModel")
@MainActor
struct SmartPlaylistDetailViewModelTests {
    // MARK: - Helpers

    private struct Seed {
        let vm: SmartPlaylistDetailViewModel
        let service: SmartPlaylistService
        let database: Database
        let playlistID: Int64
        let trackIDs: [Int64]
    }

    private func seed(liveUpdate: Bool = true) async throws -> Seed {
        let db = try await Database(location: .inMemory)
        let service = SmartPlaylistService(database: db)
        let repo = TrackRepository(database: db)

        // Insert tracks with loved == true so the criteria below matches all of them.
        var trackIDs: [Int64] = []
        for i in 0 ..< 3 {
            let now = Int64(Date().timeIntervalSince1970)
            var track = Track(
                fileURL: "file:///tmp/sp\(i).mp3",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "mp3",
                duration: 180,
                title: "SP\(i)",
                addedAt: now,
                updatedAt: now
            )
            track.loved = true
            let id = try await repo.insert(track)
            trackIDs.append(id)
        }

        let criteria = SmartCriterion.rule(
            .init(field: .loved, comparator: .isTrue, value: .null)
        )
        let limitSort = LimitSort(sortBy: .addedAt, ascending: true, liveUpdate: liveUpdate)
        let playlist = try await service.create(
            name: "Loved",
            criteria: criteria,
            limitSort: limitSort
        )
        guard let pid = playlist.id else {
            throw PlaylistError.emptyName
        }

        let vm = SmartPlaylistDetailViewModel(service: service)
        return Seed(vm: vm, service: service, database: db, playlistID: pid, trackIDs: trackIDs)
    }

    // MARK: - Tests

    @Test("load populates title and tracks for a live smart playlist")
    func loadLive() async throws {
        let seed = try await self.seed(liveUpdate: true)
        await seed.vm.load(playlistID: seed.playlistID)

        // Allow the observation stream to emit the initial value.
        for _ in 0 ..< 50 {
            if !seed.vm.tracks.isEmpty { break }
            await Task.yield()
        }

        #expect(seed.vm.title == "Loved")
        #expect(seed.vm.tracks.count == seed.trackIDs.count)
        #expect(seed.vm.isLive)
        #expect(seed.vm.lastError == nil)
    }

    @Test("load populates tracks for a snapshot smart playlist")
    func loadSnapshot() async throws {
        let seed = try await self.seed(liveUpdate: false)
        await seed.vm.load(playlistID: seed.playlistID)

        #expect(seed.vm.title == "Loved")
        #expect(seed.vm.tracks.count == seed.trackIDs.count)
        #expect(!seed.vm.isLive)
        #expect(seed.vm.lastError == nil)
    }

    @Test("tracks are delivered in original (unshuffled) order so caller owns shuffle")
    func tracksInOriginalOrder() async throws {
        // The shuffle fix moves the shuffle responsibility from the view's
        // .shuffled() call into setShuffle(true) on the queue player.
        // This test verifies that SmartPlaylistDetailViewModel never reorders
        // tracks itself — it hands the original ordered slice to the caller.
        let seed = try await self.seed(liveUpdate: false)
        await seed.vm.load(playlistID: seed.playlistID)

        let loadedIDs = seed.vm.tracks.compactMap(\.id)
        // The service returns them sorted by addedAt ascending; the seed inserts
        // SP0 < SP1 < SP2 so their IDs must appear in that same order.
        #expect(loadedIDs == seed.trackIDs)
    }

    @Test("load with invalid ID sets lastError")
    func loadInvalidID() async throws {
        let db = try await Database(location: .inMemory)
        let service = SmartPlaylistService(database: db)
        let vm = SmartPlaylistDetailViewModel(service: service)

        await vm.load(playlistID: 999)

        #expect(vm.lastError != nil)
        #expect(vm.tracks.isEmpty)
    }
}
