import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("TrackImporter cover art and extended tags")
struct TrackImporterArtAndTagsTests: TrackImporterFixtures {
    @Test("embedded cover art is linked to the album")
    func coverArtLinkedToAlbum() async throws {
        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        var tags = self.makeTags(title: "With Art")
        tags.coverArt = CoverArtExtractor.extract(from: [
            RawCoverArt(data: Data([0x01, 0x02, 0x03]), mimeType: "image/jpeg", pictureType: 3),
        ])

        let url = URL(fileURLWithPath: "/tmp/with-art.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: tags,
            fileMtime: 1000,
            fileSize: 4567
        )

        let trackRepo = TrackRepository(database: db)
        let track = try await trackRepo.fetch(id: id)
        #expect(track.coverArtHash != nil)

        let albumRepo = AlbumRepository(database: db)
        let albums = try await albumRepo.fetchAll()
        #expect(albums.count == 1)
        #expect(albums[0].coverArtHash == track.coverArtHash)
        #expect(albums[0].coverArtPath != nil)
    }

    @Test("sidecar cover art fills in when the file embeds none (#388)")
    func sidecarArtFillsGap() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("importer-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecarBytes = Data([0xAA, 0xBB, 0xCC])
        try sidecarBytes.write(to: dir.appendingPathComponent("cover.jpg"))

        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        let url = dir.appendingPathComponent("artless.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(title: "Artless"),
            fileMtime: 1000,
            fileSize: 100
        )

        let expectedHash = ExtractedCoverArt(
            data: sidecarBytes, mimeType: "image/jpeg", pictureType: 3
        ).sha256
        let track = try await TrackRepository(database: db).fetch(id: id)
        #expect(track.coverArtHash == expectedHash)
        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.first?.coverArtHash == expectedHash)
        #expect(albums.first?.coverArtPath != nil)
    }

    @Test("embedded art beats a sidecar in the same folder (#388)")
    func embeddedBeatsSidecar() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("importer-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecarBytes = Data([0xAA, 0xBB, 0xCC])
        try sidecarBytes.write(to: dir.appendingPathComponent("cover.jpg"))
        let sidecarHash = ExtractedCoverArt(
            data: sidecarBytes, mimeType: "image/jpeg", pictureType: 3
        ).sha256

        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var tags = self.makeTags(title: "Embedded")
        tags.coverArt = CoverArtExtractor.extract(from: [
            RawCoverArt(data: Data([0x01, 0x02, 0x03]), mimeType: "image/jpeg", pictureType: 3),
        ])
        _ = try await importer.importTrack(
            url: dir.appendingPathComponent("embedded.mp3"),
            bookmark: nil,
            tags: tags,
            fileMtime: 1000,
            fileSize: 100
        )

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.first?.coverArtHash != nil)
        #expect(albums.first?.coverArtHash != sidecarHash, "embedded art must win over the sidecar")
    }

    @Test("multi-valued ARTIST tag uses first value as the artists FK target")
    func multiValueArtistUsesFirstValue() async throws {
        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        var tags = self.makeTags(title: "Walk This Way")
        tags.artist = "Run-DMC" // Flat field, used as fallback
        tags.extendedTags = [
            "ARTIST": ["Run-DMC", "Aerosmith"],
            "GENRE": ["Hip-Hop", "Rock"],
        ]

        let url = URL(fileURLWithPath: "/tmp/walk-this-way.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: tags,
            fileMtime: 1000,
            fileSize: 100
        )

        let track = try await TrackRepository(database: db).fetch(id: id)
        let artists = try await ArtistRepository(database: db).fetchAll()
        #expect(artists.count == 1)
        #expect(artists[0].name == "Run-DMC")
        #expect(track.artistID == artists[0].id)
    }

    @Test("extended_tags column is populated with deterministic JSON")
    func extendedTagsPersisted() async throws {
        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        var tags = self.makeTags(title: "JSON Roundtrip")
        tags.extendedTags = [
            "ARTIST": ["Run-DMC", "Aerosmith"],
            "GENRE": ["Hip-Hop"],
        ]

        let url = URL(fileURLWithPath: "/tmp/json.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: tags,
            fileMtime: 1000,
            fileSize: 100
        )

        let track = try await TrackRepository(database: db).fetch(id: id)
        let json = try #require(track.extendedTags)
        // Sorted-keys output is deterministic.
        #expect(json == #"{"ARTIST":["Run-DMC","Aerosmith"],"GENRE":["Hip-Hop"]}"#)
    }

    @Test("empty extendedTags leaves the column NULL")
    func emptyExtendedTagsIsNull() async throws {
        let db = try await makeDB()
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        let url = URL(fileURLWithPath: "/tmp/no-ext.mp3")
        let id = try await importer.importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(title: "No Ext"),
            fileMtime: 1000,
            fileSize: 100
        )

        let track = try await TrackRepository(database: db).fetch(id: id)
        #expect(track.extendedTags == nil)
    }
}
