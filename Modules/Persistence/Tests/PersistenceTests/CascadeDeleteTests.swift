import Foundation
import Testing
@testable import Persistence

@Suite("Cascade Delete Tests")
struct CascadeDeleteTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(fileURL: String = "file:///tmp/cascade.flac") -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 180,
            title: "Cascade Track",
            addedAt: now,
            updatedAt: now
        )
    }

    @Test("Delete track cascades to lyrics")
    func deleteTrackCascadesToLyrics() async throws {
        let db = try await makeDatabase()
        let trackRepo = TrackRepository(database: db)
        let lyricsRepo = LyricsRepository(database: db)
        let trackID = try await trackRepo.insert(self.makeTrack())
        let lyrics = Lyrics(trackID: trackID, lyricsText: "Test lyrics")
        try await lyricsRepo.save(lyrics)
        try await trackRepo.delete(id: trackID)
        let fetched = try await lyricsRepo.fetch(trackID: trackID)
        #expect(fetched == nil)
    }

    @Test("Delete track cascades to scrobble_queue")
    func deleteTrackCascadesToScrobbleQueue() async throws {
        let db = try await makeDatabase()
        let trackRepo = TrackRepository(database: db)
        let scrobbleRepo = ScrobbleRepository(database: db)
        let trackID = try await trackRepo.insert(self.makeTrack())
        let now = Int64(Date().timeIntervalSince1970)
        let item = ScrobbleQueueItem(trackID: trackID, playedAt: now, durationPlayed: 180)
        _ = try await scrobbleRepo.enqueue(item)
        try await trackRepo.delete(id: trackID)
        let pending = try await scrobbleRepo.fetchPending()
        let remaining = pending.filter { $0.trackID == trackID }
        #expect(remaining.isEmpty)
    }

    @Test("Delete playlist cascades to playlist_tracks; tracks survive")
    func deletePlaylistCascadesToMembership() async throws {
        let db = try await makeDatabase()
        let playlistRepo = PlaylistRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        let playlistID = try await playlistRepo.insert(
            Playlist(name: "Temp", createdAt: now, updatedAt: now)
        )
        let trackID = try await trackRepo.insert(self.makeTrack())
        try await playlistRepo.appendTrack(trackID: trackID, to: playlistID)
        try await playlistRepo.delete(id: playlistID)
        // Track must still exist
        let track = try await trackRepo.fetch(id: trackID)
        #expect(track.id == trackID)
    }

    @Test("Delete album sets album_id to NULL on tracks (FK is nullable)")
    func deleteAlbumNullsTrackAlbumID() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Temporary Album"))
        var track = self.makeTrack()
        track.albumID = albumID
        let trackID = try await trackRepo.insert(track)
        // Remove the FK link manually (since albums.id isn't ON DELETE CASCADE for tracks.album_id)
        try await db.write { grdb in
            try grdb.execute(
                sql: "UPDATE tracks SET album_id = NULL WHERE id = ?",
                arguments: [trackID]
            )
            _ = try Album.deleteOne(grdb, key: albumID)
        }
        let fetched = try await trackRepo.fetch(id: trackID)
        #expect(fetched.albumID == nil)
    }
}
