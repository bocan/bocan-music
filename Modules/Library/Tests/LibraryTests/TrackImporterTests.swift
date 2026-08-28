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

    @Test("tag totals roll up to the album row (#404)")
    func totalsRollUpToAlbum() async throws {
        let db = try await makeDB()
        let albumRepo = AlbumRepository(database: db)
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: albumRepo,
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var first = self.makeTags(title: "One")
        first.trackNumber = 1
        first.trackTotal = 12
        first.discNumber = 1
        first.discTotal = 2
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/one.flac"), bookmark: nil, tags: first, fileMtime: 1, fileSize: 1
        )
        var album = try #require(try await albumRepo.fetchAll().first)
        #expect(album.totalTracks == 12)
        #expect(album.totalDiscs == 2)

        // A later track without totals does not clear them.
        var second = self.makeTags(title: "Two")
        second.trackNumber = 2
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/two.flac"), bookmark: nil, tags: second, fileMtime: 1, fileSize: 1
        )
        album = try #require(try await albumRepo.fetchAll().first)
        #expect(album.totalTracks == 12)
        #expect(album.totalDiscs == 2)
    }

    @Test("user_edited = true still refreshes audio properties from the file (#405)")
    func userEditedRefreshesAudioProperties() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/edited-audio.flac")
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: trackRepo,
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )

        // First import: probed before the bit-depth fix, so no bit depth.
        var before = self.makeTags(title: "Original")
        before.sampleRate = 44100
        before.bitDepth = nil
        let id = try await importer.importTrack(
            url: url, bookmark: nil, tags: before, fileMtime: 1000, fileSize: 100
        )
        var track = try await trackRepo.fetch(id: id)
        track.userEdited = true
        track.title = "User's title"
        try await trackRepo.update(track)

        // Full rescan of the unchanged file now yields a bit depth.
        var after = self.makeTags(title: "Disk Title")
        after.sampleRate = 96000
        after.bitDepth = 24
        after.bitrate = 2304
        after.channels = 2
        after.duration = 181.5
        _ = try await importer.importTrack(
            url: url, bookmark: nil, tags: after, fileMtime: 1000, fileSize: 100
        )

        let updated = try await trackRepo.fetch(id: id)
        #expect(updated.title == "User's title")
        #expect(updated.bitDepth == 24)
        #expect(updated.sampleRate == 96000)
        #expect(updated.bitrate == 2304)
        #expect(updated.channelCount == 2)
        #expect(updated.duration == 181.5)
        #expect(updated.userEdited)
    }

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
            url: url, bookmark: nil, tags: tags,
            fileMtime: 1000, fileSize: 4567
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
            url: url, bookmark: nil, tags: self.makeTags(title: "Artless"),
            fileMtime: 1000, fileSize: 100
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
            url: dir.appendingPathComponent("embedded.mp3"), bookmark: nil, tags: tags,
            fileMtime: 1000, fileSize: 100
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
        tags.artist = "Run-DMC" // Flat field — used as fallback
        tags.extendedTags = [
            "ARTIST": ["Run-DMC", "Aerosmith"],
            "GENRE": ["Hip-Hop", "Rock"],
        ]

        let url = URL(fileURLWithPath: "/tmp/walk-this-way.mp3")
        let id = try await importer.importTrack(
            url: url, bookmark: nil, tags: tags,
            fileMtime: 1000, fileSize: 100
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
            url: url, bookmark: nil, tags: tags,
            fileMtime: 1000, fileSize: 100
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
            url: url, bookmark: nil, tags: self.makeTags(title: "No Ext"),
            fileMtime: 1000, fileSize: 100
        )

        let track = try await TrackRepository(database: db).fetch(id: id)
        #expect(track.extendedTags == nil)
    }

    // MARK: - Compilation grouping (#362)

    /// Builds tags for a compilation track: same album, a distinct artist,
    /// no album-artist, compilation flag set.
    private func compilationTags(artist: String, compilation: Bool = true) -> TrackTags {
        var tags = TrackTags()
        tags.title = "Track by \(artist)"
        tags.artist = artist
        tags.album = "Now That's What I Call Music"
        tags.isCompilation = compilation
        tags.duration = 180.0
        return tags
    }

    private func makeImporter(_ db: Database) -> TrackImporter {
        TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
    }

    @Test("compilation with no album-artist groups under one Various Artists album (#362)")
    func compilationGroupsUnderVariousArtists() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/comp\(i).mp3"),
                bookmark: nil, tags: self.compilationTags(artist: artist),
                fileMtime: 1000, fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 1)
        #expect(albums.first?.albumArtistID == nil) // nil => "Various Artists"
    }

    @Test("non-compilation with no album-artist still splits by track artist")
    func nonCompilationSplitsByArtist() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/split\(i).mp3"),
                bookmark: nil,
                tags: self.compilationTags(artist: artist, compilation: false),
                fileMtime: 1000, fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 3)
    }

    @Test("explicit album-artist wins over the compilation flag")
    func explicitAlbumArtistWinsOverCompilation() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B"].enumerated() {
            var tags = self.compilationTags(artist: artist)
            tags.albumArtist = "The Curator"
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/curated\(i).mp3"),
                bookmark: nil, tags: tags, fileMtime: 1000, fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 1)
        let curator = try await ArtistRepository(database: db).fetchAll()
            .first { $0.name == "The Curator" }
        #expect(albums.first?.albumArtistID == curator?.id)
        #expect(albums.first?.albumArtistID != nil)
    }

    // MARK: - Provenance carry-over (ADR-075 slice 2)

    @Test("re-importing an unchanged file keeps its provenance verdict")
    func provenanceSurvivesUnchangedReimport() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-keep.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        try await trackRepo.setProvenance(
            trackID: id,
            suspected: true,
            confidence: 0.9,
            shelfHz: 16000,
            analysedAt: 2000
        )

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.provenanceSuspected == true)
        #expect(track.provenanceConfidence == 0.9)
        #expect(track.provenanceShelfHz == 16000)
        #expect(track.provenanceAnalysedAt == 2000)
    }

    @Test("re-importing a changed file nulls its provenance verdict")
    func provenanceClearedOnChangedFile() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-drop.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        try await trackRepo.setProvenance(
            trackID: id,
            suspected: true,
            confidence: 0.9,
            shelfHz: 16000,
            analysedAt: 2000
        )

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 3000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.provenanceSuspected == nil)
        #expect(track.provenanceConfidence == nil)
        #expect(track.provenanceShelfHz == nil)
        #expect(track.provenanceAnalysedAt == nil)
    }

    @Test("a changed file nulls the verdict even when user-edited tags are preserved")
    func provenanceClearedOnUserEditedChangedFile() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-edited.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        var edited = try await trackRepo.fetch(id: id)
        edited.userEdited = true
        edited.provenanceSuspected = false
        edited.provenanceConfidence = 0
        edited.provenanceAnalysedAt = 2000
        try await trackRepo.update(edited)

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 3000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.userEdited, "the user-edited skip branch must have handled this import")
        #expect(track.provenanceSuspected == nil)
        #expect(track.provenanceAnalysedAt == nil)
    }
}
