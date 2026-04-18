import Foundation
import Testing
@testable import Persistence

@Suite("Playlist Repository Tests")
struct PlaylistRepositoryTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(
        fileURL: String,
        title: String = "Track"
    ) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 200,
            title: title,
            addedAt: now,
            updatedAt: now
        )
    }

    private func makePlaylist(name: String = "Favourites") -> Playlist {
        let now = Int64(Date().timeIntervalSince1970)
        return Playlist(name: name, createdAt: now, updatedAt: now)
    }

    @Test("Insert and fetch playlist round-trip")
    func insertAndFetch() async throws {
        let db = try await makeDatabase()
        let repo = PlaylistRepository(database: db)
        let id = try await repo.insert(self.makePlaylist())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.id == id)
        #expect(fetched.name == "Favourites")
    }

    @Test("Delete playlist cascades to playlist_tracks")
    func deleteCascadesToTracks() async throws {
        let db = try await makeDatabase()
        let pRepo = PlaylistRepository(database: db)
        let tRepo = TrackRepository(database: db)
        let playlistID = try await pRepo.insert(self.makePlaylist())
        let trackID = try await tRepo.insert(self.makeTrack(fileURL: "file:///tmp/cascade.mp3"))
        try await pRepo.appendTrack(trackID: trackID, to: playlistID)
        let membersBefore = try await pRepo.fetchTrackIDs(playlistID: playlistID)
        #expect(membersBefore.count == 1)
        try await pRepo.delete(id: playlistID)
        // After deleting the playlist, track should still exist
        let track = try await tRepo.fetch(id: trackID)
        #expect(track.id == trackID)
    }

    @Test("appendTrack grows playlist in order")
    func appendTrackGrowsPlaylist() async throws {
        let db = try await makeDatabase()
        let pRepo = PlaylistRepository(database: db)
        let tRepo = TrackRepository(database: db)
        let playlistID = try await pRepo.insert(self.makePlaylist())
        let id1 = try await tRepo.insert(self.makeTrack(fileURL: "file:///tmp/a.mp3", title: "A"))
        let id2 = try await tRepo.insert(self.makeTrack(fileURL: "file:///tmp/b.mp3", title: "B"))
        try await pRepo.appendTrack(trackID: id1, to: playlistID)
        try await pRepo.appendTrack(trackID: id2, to: playlistID)
        let ids = try await pRepo.fetchTrackIDs(playlistID: playlistID)
        #expect(ids == [id1, id2])
    }

    @Test("removeTrack removes all occurrences")
    func removeTrackRemovesAll() async throws {
        let db = try await makeDatabase()
        let pRepo = PlaylistRepository(database: db)
        let tRepo = TrackRepository(database: db)
        let playlistID = try await pRepo.insert(self.makePlaylist())
        let trackID = try await tRepo.insert(self.makeTrack(fileURL: "file:///tmp/rm.mp3"))
        try await pRepo.appendTrack(trackID: trackID, to: playlistID)
        try await pRepo.removeTrack(trackID: trackID, from: playlistID)
        let ids = try await pRepo.fetchTrackIDs(playlistID: playlistID)
        #expect(ids.isEmpty)
    }

    @Test("fetchAll returns playlists sorted by sort_order then name")
    func fetchAllSorted() async throws {
        let db = try await makeDatabase()
        let repo = PlaylistRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        var beta = Playlist(name: "Beta", createdAt: now, updatedAt: now)
        beta.sortOrder = 2
        var alpha = Playlist(name: "Alpha", createdAt: now, updatedAt: now)
        alpha.sortOrder = 1
        _ = try await repo.insert(beta)
        _ = try await repo.insert(alpha)
        let all = try await repo.fetchAll()
        #expect(all.first?.name == "Alpha")
    }
}
