import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("TrackImporter")
struct TrackImporterTests {
    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTags(title: String = "Test Track") -> TrackTags {
        var tags = TrackTags()
        tags.title = title
        tags.artist = "Test Artist"
        tags.album = "Test Album"
        tags.duration = 180.0
        return tags
    }

    // MARK: - Tests

    @Test("import creates artist, album, and track rows")
    func importCreatesRows() async throws {
        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        let url = URL(fileURLWithPath: "/tmp/test.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 50000
        )

        #expect(id > 0)

        let trackRepo = TrackRepository(database: db)
        let track = try await trackRepo.fetchOne(fileURL: url.absoluteString)
        #expect(track?.title == "Test Track")
        #expect(track?.fileSize == 50000)

        let artistRepo = ArtistRepository(database: db)
        let artists = try await artistRepo.fetchAll()
        #expect(artists.count == 1)
        #expect(artists[0].name == "Test Artist")

        let albumRepo = AlbumRepository(database: db)
        let albums = try await albumRepo.fetchAll()
        #expect(albums.count == 1)
        #expect(albums[0].title == "Test Album")
    }

    @Test("importing same file twice is idempotent")
    func importIdemopotent() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)

        func runImport() async throws -> Int64 {
            let importer = TrackImporter(
                artistRepo: ArtistRepository(database: db),
                albumRepo: AlbumRepository(database: db),
                trackRepo: trackRepo,
                lyricsRepo: LyricsRepository(database: db),
                coverArtCache: CoverArtCache.make(database: db)
            )
            return try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/idempotent.mp3"),
                bookmark: nil,
                tags: self.makeTags(title: "Idempotent"),
                fileMtime: 1000,
                fileSize: 1234
            )
        }

        let id1 = try await runImport()
        let id2 = try await runImport()
        #expect(id1 == id2)
        #expect(try await trackRepo.count() == 1)
    }

    @Test("embedded lyrics are persisted")
    func lyricsArePersisted() async throws {
        let db = try await makeDB()
        var tags = self.makeTags()
        tags.lyrics = "Hello world\nAnother line"

        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        let url = URL(fileURLWithPath: "/tmp/lyrical.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: tags,
            fileMtime: 2000,
            fileSize: 9999
        )

        let lyricsRepo = LyricsRepository(database: db)
        let lyrics = try await lyricsRepo.fetch(trackID: id)
        #expect(lyrics?.lyricsText == "Hello world\nAnother line")
        #expect(lyrics?.isSynced == false)
    }

    @Test("user_edited = true skips tag overwrite")
    func userEditedSkipsOverwrite() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)

        let url = URL(fileURLWithPath: "/tmp/edited.mp3")

        // First import
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: trackRepo,
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        let id = try await importer.importTrack(
            url: url, bookmark: nil, tags: self.makeTags(title: "Original"),
            fileMtime: 1000, fileSize: 100
        )

        // Mark user_edited
        var track = try await trackRepo.fetch(id: id)
        track.userEdited = true
        track.title = "User's title"
        try await trackRepo.update(track)

        // Second import with different tags
        let importer2 = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: trackRepo,
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        _ = try await importer2.importTrack(
            url: url, bookmark: nil, tags: self.makeTags(title: "Disk Title"),
            fileMtime: 2000, fileSize: 200
        )

        // Title should NOT be overwritten
        let updated = try await trackRepo.fetch(id: id)
        #expect(updated.title == "User's title")
    }
}
