import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - PlaylistDetailViewModelTests

@Suite("PlaylistDetailViewModel")
@MainActor
struct PlaylistDetailViewModelTests {
    private func seed() async throws -> (PlaylistDetailViewModel, PlaylistService, Database, Int64, [Int64]) {
        let db = try await Database(location: .inMemory)
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Test")
        guard let pid = playlist.id else { throw PlaylistError.emptyName }
        // Create a handful of tracks.
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
        return (vm, service, db, pid, trackIDs)
    }

    @Test("load populates playlist and tracks")
    func load() async throws {
        let (vm, _, _, pid, trackIDs) = try await self.seed()
        await vm.load(playlistID: pid)
        #expect(vm.title == "Test")
        #expect(vm.tracks.map { $0.id ?? -1 } == trackIDs)
        #expect(vm.trackCount == 4)
        #expect(vm.totalDuration == 480)
    }

    @Test("move reorders optimistically and persists")
    func move() async throws {
        let (vm, service, _, pid, trackIDs) = try await self.seed()
        await vm.load(playlistID: pid)
        await vm.move(from: IndexSet([0]), to: 4)
        #expect(vm.tracks.first?.id == trackIDs[1])
        // And the DB now agrees.
        let persisted = try await service.tracks(in: pid).map { $0.id ?? -1 }
        #expect(persisted == vm.tracks.map { $0.id ?? -1 })
    }

    @Test("remove optimistically removes entries")
    func remove() async throws {
        let (vm, _, _, pid, trackIDs) = try await self.seed()
        await vm.load(playlistID: pid)
        await vm.remove(at: IndexSet([1, 3]))
        #expect(vm.tracks.map { $0.id ?? -1 } == [trackIDs[0], trackIDs[2]])
    }

    @Test("removeSelected clears selection after removal")
    func removeSelected() async throws {
        let (vm, _, _, pid, trackIDs) = try await self.seed()
        await vm.load(playlistID: pid)
        vm.selection = Set([trackIDs[0], trackIDs[2]])
        await vm.removeSelected()
        #expect(vm.selection.isEmpty)
        #expect(vm.tracks.map { $0.id ?? -1 } == [trackIDs[1], trackIDs[3]])
    }
}
