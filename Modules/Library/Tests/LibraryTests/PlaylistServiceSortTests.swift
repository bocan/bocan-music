import Foundation
import Testing
@testable import Library
@testable import Persistence

@Suite("PlaylistService sort contents")
struct PlaylistServiceSortTests: PlaylistServiceFixtures {
    // MARK: - Sort contents

    @Test("sortContents by title reorders tracks alphabetically")
    func sortByTitle() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "P")
        guard let pid = playlist.id else { return }
        let charlie = try await self.makeTrack(in: db, fileURL: "file:///tmp/st_c.mp3", title: "Charlie")
        let alpha = try await self.makeTrack(in: db, fileURL: "file:///tmp/st_a.mp3", title: "Alpha")
        let bravo = try await self.makeTrack(in: db, fileURL: "file:///tmp/st_b.mp3", title: "Bravo")
        // Add in C, A, B order; after sort expect A, B, C.
        try await service.addTracks([charlie, alpha, bravo], to: pid)
        try await service.sortContents(pid, by: .title)
        let titles = try await service.tracks(in: pid).map { $0.title ?? "" }
        #expect(titles == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("sortContents by title is case-insensitive")
    func sortByTitleCaseInsensitive() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "P")
        guard let pid = playlist.id else { return }
        let lower = try await self.makeTrack(in: db, fileURL: "file:///tmp/ci_a.mp3", title: "alpha")
        let mixed = try await self.makeTrack(in: db, fileURL: "file:///tmp/ci_b.mp3", title: "Bravo")
        let caps = try await self.makeTrack(in: db, fileURL: "file:///tmp/ci_c.mp3", title: "AARDVARK")
        try await service.addTracks([lower, mixed, caps], to: pid)
        try await service.sortContents(pid, by: .title)
        let titles = try await service.tracks(in: pid).map { $0.title ?? "" }
        // LOWER("AARDVARK") < LOWER("alpha") < LOWER("Bravo")
        #expect(titles == ["AARDVARK", "alpha", "Bravo"])
    }

    @Test("sortContents by dateAdded orders oldest first")
    func sortByDateAdded() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "P")
        guard let pid = playlist.id else { return }
        let repo = TrackRepository(database: db)
        let old = Track(
            fileURL: "file:///tmp/da_old.mp3",
            fileFormat: "mp3",
            duration: 1,
            title: "Old",
            addedAt: 1000,
            updatedAt: 1000
        )
        let mid = Track(
            fileURL: "file:///tmp/da_mid.mp3",
            fileFormat: "mp3",
            duration: 1,
            title: "Mid",
            addedAt: 2000,
            updatedAt: 2000
        )
        let newTrack = Track(
            fileURL: "file:///tmp/da_new.mp3",
            fileFormat: "mp3",
            duration: 1,
            title: "New",
            addedAt: 3000,
            updatedAt: 3000
        )
        let idOld = try await repo.insert(old)
        let idMid = try await repo.insert(mid)
        let idNew = try await repo.insert(newTrack)
        // Add newest first; sort should flip to oldest first.
        try await service.addTracks([idNew, idMid, idOld], to: pid)
        try await service.sortContents(pid, by: .dateAdded)
        let titles = try await service.tracks(in: pid).map { $0.title ?? "" }
        #expect(titles == ["Old", "Mid", "New"])
    }

    @Test("sortContents by artist sorts by artist name then title")
    func sortByArtist() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "P")
        guard let pid = playlist.id else { return }
        let artistRepo = ArtistRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        let zoeID = try await artistRepo.insert(Artist(name: "Zoe"))
        let andyID = try await artistRepo.insert(Artist(name: "Andy"))
        let t1 = Track(
            fileURL: "file:///tmp/ar_z.mp3",
            fileFormat: "mp3",
            duration: 1,
            title: "ZoeSong",
            artistID: zoeID,
            addedAt: now,
            updatedAt: now
        )
        let t2 = Track(
            fileURL: "file:///tmp/ar_a.mp3",
            fileFormat: "mp3",
            duration: 1,
            title: "AndySong",
            artistID: andyID,
            addedAt: now,
            updatedAt: now
        )
        let id1 = try await trackRepo.insert(t1)
        let id2 = try await trackRepo.insert(t2)
        // Add Zoe first, Andy second; after artist sort Andy should be first.
        try await service.addTracks([id1, id2], to: pid)
        try await service.sortContents(pid, by: .artist)
        let titles = try await service.tracks(in: pid).map { $0.title ?? "" }
        #expect(titles == ["AndySong", "ZoeSong"])
    }

    @Test("sortContents rejects smart playlists")
    func sortRejectsSmart() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let pRepo = PlaylistRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        let smart = Playlist(name: "Smart", isSmart: true, createdAt: now, updatedAt: now, kind: .smart)
        let id = try await pRepo.insert(smart)
        await #expect(throws: PlaylistError.self) {
            try await service.sortContents(id, by: .title)
        }
    }

    @Test("sortContents on empty playlist is a no-op")
    func sortEmpty() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Empty")
        guard let pid = playlist.id else { return }
        try await service.sortContents(pid, by: .title)
        let tracks = try await service.tracks(in: pid)
        #expect(tracks.isEmpty)
    }

    @Test("sortContents positions are on the 1024 grid after sorting")
    func sortProducesCleanPositions() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "P")
        guard let pid = playlist.id else { return }
        let ids = try await self.tracks(5, in: db)
        try await service.addTracks(ids, to: pid)
        try await service.sortContents(pid, by: .title)
        let repo = PlaylistRepository(database: db)
        let membership = try await repo.fetchMembership(playlistID: pid)
        #expect(membership.allSatisfy { $0.position % 1024 == 0 })
        #expect(membership.count == 5)
    }
}
