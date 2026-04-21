import Foundation
import Testing
@testable import Library
@testable import Persistence

@Suite("PlaylistService")
struct PlaylistServiceTests {
    // MARK: - Helpers

    private func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    private func makeTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track"
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(track)
        return id ?? -1
    }

    private func tracks(_ count: Int, in db: Persistence.Database) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0 ..< count {
            let id = try await self.makeTrack(in: db, fileURL: "file:///tmp/t\(i).mp3", title: "T\(i)")
            ids.append(id)
        }
        return ids
    }

    // MARK: - CRUD

    @Test("create persists a manual playlist")
    func createManual() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "Favourites")
        #expect(p.id != nil)
        #expect(p.kind == .manual)
        let list = try await service.list()
        #expect(list.contains { $0.id == p.id })
    }

    @Test("create rejects empty name")
    func createRejectsEmpty() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        await #expect(throws: PlaylistError.self) {
            try await service.create(name: "   ")
        }
    }

    @Test("createFolder persists a folder")
    func createFolder() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let folder = try await service.createFolder(name: "Roadtrip")
        #expect(folder.kind == .folder)
    }

    @Test("create under a non-folder parent is rejected")
    func createUnderPlaylistFails() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let parent = try await service.create(name: "Parent")
        guard let parentID = parent.id else { return }
        await #expect(throws: PlaylistError.self) {
            try await service.create(name: "Child", parentID: parentID)
        }
    }

    @Test("rename updates the name")
    func rename() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "Old")
        guard let id = p.id else { return }
        try await service.rename(id, to: "New")
        let repo = PlaylistRepository(database: db)
        let updated = try await repo.fetch(id: id)
        #expect(updated.name == "New")
    }

    @Test("delete folder reparents children by default")
    func deleteFolderReparents() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let folder = try await service.createFolder(name: "Folder")
        guard let folderID = folder.id else { return }
        let child = try await service.create(name: "Child", parentID: folderID)
        guard let childID = child.id else { return }
        try await service.delete(folderID)
        let repo = PlaylistRepository(database: db)
        let reloaded = try await repo.fetch(id: childID)
        #expect(reloaded.parentID == nil)
    }

    @Test("deleteRecursively removes the folder and its descendants")
    func deleteFolderRecursive() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let folder = try await service.createFolder(name: "F")
        guard let folderID = folder.id else { return }
        let child = try await service.create(name: "C", parentID: folderID)
        guard let childID = child.id else { return }
        try await service.deleteRecursively(folderID)
        let repo = PlaylistRepository(database: db)
        await #expect(throws: PersistenceError.self) {
            _ = try await repo.fetch(id: childID)
        }
    }

    @Test("deleting a playlist leaves its tracks intact")
    func deletePlaylistKeepsTracks() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let trackIDs = try await self.tracks(3, in: db)
        try await service.addTracks(trackIDs, to: pid)
        try await service.delete(pid)
        let tRepo = TrackRepository(database: db)
        for t in trackIDs {
            let track = try await tRepo.fetch(id: t)
            #expect(track.id == t)
        }
    }

    // MARK: - Move / cycles

    @Test("move to self throws cycleDetected")
    func moveSelfCycle() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let f = try await service.createFolder(name: "F")
        guard let id = f.id else { return }
        await #expect(throws: PlaylistError.self) {
            try await service.move(id, toParent: id)
        }
    }

    @Test("move under descendant throws cycleDetected")
    func moveDescendantCycle() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let parent = try await service.createFolder(name: "Parent")
        guard let parentID = parent.id else { return }
        let child = try await service.createFolder(name: "Child", parentID: parentID)
        guard let childID = child.id else { return }
        await #expect(throws: PlaylistError.self) {
            try await service.move(parentID, toParent: childID)
        }
    }

    // MARK: - Membership

    @Test("addTracks then list returns count/duration")
    func addAndCount() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let trackIDs = try await self.tracks(4, in: db)
        try await service.addTracks(trackIDs, to: pid)
        let nodes = try await service.list()
        let node = nodes.first { $0.id == pid }
        #expect(node?.trackCount == 4)
        #expect(node?.totalDuration ?? 0 > 0)
    }

    @Test("addTracks at end yields increasing positions")
    func addTracksIncreasing() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let ids = try await self.tracks(3, in: db)
        try await service.addTracks(ids, to: pid)
        let repo = PlaylistRepository(database: db)
        let membership = try await repo.fetchMembership(playlistID: pid)
        let positions = membership.map(\.position)
        for i in 1 ..< positions.count {
            #expect(positions[i] > positions[i - 1])
        }
    }

    @Test("addTracks at middle places between neighbours")
    func addTracksMiddle() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let firstA = try await self.makeTrack(in: db, fileURL: "file:///tmp/midA.mp3")
        let firstB = try await self.makeTrack(in: db, fileURL: "file:///tmp/midB.mp3")
        try await service.addTracks([firstA, firstB], to: pid)
        let insertedA = try await self.makeTrack(in: db, fileURL: "file:///tmp/midC.mp3")
        let insertedB = try await self.makeTrack(in: db, fileURL: "file:///tmp/midD.mp3")
        try await service.addTracks([insertedA, insertedB], to: pid, at: 1)
        let tracks = try await service.tracks(in: pid)
        #expect(tracks.count == 4)
        #expect(tracks.map { $0.id ?? -1 } == [firstA, insertedA, insertedB, firstB])
    }

    @Test("repack kicks in when positions collide")
    func repackOnCollision() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        // Manually seed tight positions to force a repack path.
        let trackIDs = try await self.tracks(3, in: db)
        let repo = PlaylistRepository(database: db)
        try await repo.replaceMembership(
            playlistID: pid,
            ordered: [
                (trackID: trackIDs[0], position: 1),
                (trackID: trackIDs[1], position: 2),
                (trackID: trackIDs[2], position: 3),
            ]
        )
        // Insert another one in the middle — tight gap triggers repack.
        let extra = try await self.makeTrack(in: db, fileURL: "file:///tmp/extra.mp3")
        try await service.addTracks([extra], to: pid, at: 1)
        let membership = try await repo.fetchMembership(playlistID: pid)
        let positions = membership.map(\.position)
        // After repack, positions should be on the 1024 grid.
        #expect(positions.allSatisfy { $0 % 1024 == 0 })
        #expect(positions.count == 4)
    }

    @Test("removeTracks deletes specified positions only")
    func removeTracks() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let ids = try await self.tracks(4, in: db)
        try await service.addTracks(ids, to: pid)
        try await service.removeTracks(at: IndexSet([1, 3]), from: pid)
        let remaining = try await service.tracks(in: pid).map { $0.id ?? -1 }
        #expect(remaining == [ids[0], ids[2]])
    }

    @Test("moveTracks mirrors SwiftUI move semantics")
    func moveTracksMirrorsSwiftUI() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }
        let ids = try await self.tracks(5, in: db)
        try await service.addTracks(ids, to: pid)
        // Move element at offset 1 to offset 4 -> expected order [0, 2, 3, 1, 4]
        try await service.moveTracks(in: pid, from: IndexSet([1]), to: 4)
        let reorderedIDs = try await service.tracks(in: pid).map { $0.id ?? -1 }
        #expect(reorderedIDs == [ids[0], ids[2], ids[3], ids[1], ids[4]])
    }

    @Test("duplicate creates a copy with same tracks")
    func duplicate() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "Original")
        guard let pid = p.id else { return }
        let ids = try await self.tracks(3, in: db)
        try await service.addTracks(ids, to: pid)
        let copy = try await service.duplicate(pid)
        guard let copyID = copy.id else { return }
        #expect(copy.name == "Original copy")
        let originalIDs = try await service.tracks(in: pid).map { $0.id ?? -1 }
        let copyIDs = try await service.tracks(in: copyID).map { $0.id ?? -1 }
        #expect(originalIDs == copyIDs)
    }

    @Test("duplicate rejects folders")
    func duplicateFolderRejected() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let f = try await service.createFolder(name: "F")
        guard let id = f.id else { return }
        await #expect(throws: PlaylistError.self) {
            _ = try await service.duplicate(id)
        }
    }

    @Test("setAccentColor validates hex")
    func accentColor() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let id = p.id else { return }
        try await service.setAccentColor(id, hex: "#FF9500")
        try await service.setAccentColor(id, hex: nil)
        await #expect(throws: PlaylistError.self) {
            try await service.setAccentColor(id, hex: "purple")
        }
    }

    // MARK: - Oracle (property-style) test

    @Test("Arbitrary add/remove/move sequence matches in-memory oracle")
    func oracleParity() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let p = try await service.create(name: "P")
        guard let pid = p.id else { return }

        var oracle: [Int64] = []
        var pool: [Int64] = []
        for i in 0 ..< 20 {
            try await pool.append(self.makeTrack(in: db, fileURL: "file:///tmp/oracle\(i).mp3"))
        }

        // Apply a deterministic sequence of ops.
        let ops: [(String, [Int])] = [
            ("addEnd", [0, 1, 2, 3, 4]),
            ("addAt", [5, 2]), // insert id=5 at index 2
            ("addAt", [6, 0]),
            ("removeAt", [3]),
            ("moveFromTo", [1, 4]),
            ("addEnd", [7, 8]),
            ("moveFromTo", [0, 5]),
            ("removeAt", [2]),
        ]
        for op in ops {
            switch op.0 {
            case "addEnd":
                let ids = op.1.map { pool[$0] }
                try await service.addTracks(ids, to: pid)
                oracle.append(contentsOf: ids)

            case "addAt":
                let id = pool[op.1[0]]
                let idx = op.1[1]
                try await service.addTracks([id], to: pid, at: idx)
                oracle.insert(id, at: min(idx, oracle.count))

            case "removeAt":
                let idx = op.1[0]
                try await service.removeTracks(at: IndexSet([idx]), from: pid)
                oracle.remove(at: idx)

            case "moveFromTo":
                let from = op.1[0]
                let to = op.1[1]
                try await service.moveTracks(in: pid, from: IndexSet([from]), to: to)
                let moved = PositionArranger.applyMove(oracle, fromOffsets: IndexSet([from]), toOffset: to)
                oracle = moved

            default:
                break
            }
        }

        let actualIDs = try await service.tracks(in: pid).map { $0.id ?? -1 }
        #expect(actualIDs == oracle)
    }
}
