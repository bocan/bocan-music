import Foundation
import Testing
@testable import Persistence

@Suite("CoverArtRepository")
struct CoverArtRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @Test("save inserts new row and returns its path")
    func saveNew() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        let art = CoverArt(hash: "h1", path: "/img/h1.jpg", width: 100, height: 100, format: "jpg")
        let path = try await repo.save(art)
        #expect(path == "/img/h1.jpg")
        let fetched = try await repo.fetch(hash: "h1")
        #expect(fetched?.path == "/img/h1.jpg")
        #expect(fetched?.width == 100)
    }

    @Test("save is a no-op when hash already exists and returns stored path")
    func saveExisting() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        _ = try await repo.save(CoverArt(hash: "h1", path: "/img/h1.jpg"))
        let path = try await repo.save(CoverArt(hash: "h1", path: "/img/other.jpg"))
        #expect(path == "/img/h1.jpg")
    }

    @Test("hashes(withSourceIn:) returns only the rows with a listed source")
    func hashesBySource() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        _ = try await repo.save(CoverArt(hash: "embedded", path: "/e", source: "embedded"))
        _ = try await repo.save(CoverArt(hash: "fetched", path: "/f", source: "musicbrainz"))
        _ = try await repo.save(CoverArt(hash: "chosen", path: "/c", source: "user"))
        _ = try await repo.save(CoverArt(hash: "unknown", path: "/u"))

        #expect(try await repo.hashes(withSourceIn: ["musicbrainz", "user"]) == ["fetched", "chosen"])
        #expect(try await repo.hashes(withSourceIn: []).isEmpty)
    }

    @Test("hashesInUse() returns the art an album or a track shows, once each, and nothing else")
    func hashesInUse() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        for hash in ["albumArt", "trackArt", "both", "orphan"] {
            _ = try await repo.save(CoverArt(hash: hash, path: "/\(hash)"))
        }
        let albums = AlbumRepository(database: db)
        let albumID = try await albums.insert(Album(title: "A"))
        try await albums.setCoverArt(albumID: albumID, hash: "albumArt", path: "/albumArt")
        let otherAlbum = try await albums.insert(Album(title: "B"))
        try await albums.setCoverArt(albumID: otherAlbum, hash: "both", path: "/both")
        let now = Int64(Date().timeIntervalSince1970)
        let tracks = TrackRepository(database: db)
        for hash in ["trackArt", "both"] {
            var track = Track(fileURL: "/tmp/\(hash).flac", fileFormat: "flac", duration: 1, addedAt: now, updatedAt: now)
            track.coverArtHash = hash
            _ = try await tracks.insert(track)
        }
        _ = try await albums.insert(Album(title: "No Cover"))

        #expect(try await repo.hashesInUse() == ["albumArt", "trackArt", "both"])
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        _ = try await repo.save(CoverArt(hash: "h1", path: "/p"))
        try await repo.delete(hash: "h1")
        #expect(try await repo.fetch(hash: "h1") == nil)
    }

    @Test("fetch returns nil for unknown hash")
    func fetchMissing() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        #expect(try await repo.fetch(hash: "ghost") == nil)
    }
}
