import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - PlaylistDetailViewModelTests

@Suite("PlaylistDetailViewModel")
@MainActor
struct PlaylistDetailViewModelTests {
    private struct Seed {
        let vm: PlaylistDetailViewModel
        let service: PlaylistService
        let database: Database
        let playlistID: Int64
        let trackIDs: [Int64]
    }

    private func seed() async throws -> Seed {
        let db = try await Database(location: .inMemory)
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Test")
        guard let pid = playlist.id else { throw PlaylistError.emptyName }
        var trackIDs: [Int64] = []
        let repo = TrackRepository(database: db)
        for i in 0 ..< 4 {
            let now = Int64(Date().timeIntervalSince1970)
            let track = Track(
                fileURL: "file:///tmp/d\(i).mp3",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "mp3",
                duration: 120,
                title: "D\(i)",
                addedAt: now,
                updatedAt: now
            )
            let id = try await repo.insert(track)
            trackIDs.append(id)
        }
        try await service.addTracks(trackIDs, to: pid)
        let vm = PlaylistDetailViewModel(service: service, database: db)
        return Seed(vm: vm, service: service, database: db, playlistID: pid, trackIDs: trackIDs)
    }

    @Test("load populates playlist and tracks")
    func load() async throws {
        let seed = try await self.seed()
        await seed.vm.load(playlistID: seed.playlistID)
        #expect(seed.vm.title == "Test")
        #expect(seed.vm.tracks.map { $0.id ?? -1 } == seed.trackIDs)
        #expect(seed.vm.trackCount == 4)
        #expect(seed.vm.totalDuration == 480)
    }

    @Test("move reorders optimistically and persists")
    func move() async throws {
        let seed = try await self.seed()
        await seed.vm.load(playlistID: seed.playlistID)
        await seed.vm.move(from: IndexSet([0]), to: 4)
        #expect(seed.vm.tracks.first?.id == seed.trackIDs[1])
        let persisted = try await seed.service.tracks(in: seed.playlistID).map { $0.id ?? -1 }
        #expect(persisted == seed.vm.tracks.map { $0.id ?? -1 })
    }

    @Test("remove optimistically removes entries")
    func remove() async throws {
        let seed = try await self.seed()
        await seed.vm.load(playlistID: seed.playlistID)
        await seed.vm.remove(at: IndexSet([1, 3]))
        #expect(seed.vm.tracks.map { $0.id ?? -1 } == [seed.trackIDs[0], seed.trackIDs[2]])
    }

    @Test("removeSelected clears selection after removal")
    func removeSelected() async throws {
        let seed = try await self.seed()
        await seed.vm.load(playlistID: seed.playlistID)
        seed.vm.selection = Set([seed.trackIDs[0], seed.trackIDs[2]])
        await seed.vm.removeSelected()
        #expect(seed.vm.selection.isEmpty)
        #expect(seed.vm.tracks.map { $0.id ?? -1 } == [seed.trackIDs[1], seed.trackIDs[3]])
    }
}
