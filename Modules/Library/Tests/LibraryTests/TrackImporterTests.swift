import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("TrackImporter")
struct TrackImporterTests: TrackImporterFixtures {
    // The fixture builders are in `TrackImporterTestSupport.swift`. The other
    // importer suites are `TrackImporterArtAndTagsTests` and
    // `TrackImporterRescanTests`.

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
            url: url,
            bookmark: nil,
            tags: self.makeTags(title: "Original"),
            fileMtime: 1000,
            fileSize: 100
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
            url: url,
            bookmark: nil,
            tags: self.makeTags(title: "Disk Title"),
            fileMtime: 2000,
            fileSize: 200
        )

        // Title should NOT be overwritten
        let updated = try await trackRepo.fetch(id: id)
        #expect(updated.title == "User's title")
    }

    @Test("track and album-artist MBIDs reach the track and artist rows (#399)")
    func artistMBIDsReachRows() async throws {
        let db = try await makeDB()
        let artistRepo = ArtistRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let importer = TrackImporter(
            artistRepo: artistRepo,
            albumRepo: AlbumRepository(database: db),
            trackRepo: trackRepo,
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var tags = self.makeTags(title: "Feat")
        tags.artist = "Guest"
        tags.musicbrainzArtistID = "mbid-guest"
        tags.albumArtist = "Headliner"
        tags.musicbrainzAlbumArtistID = "mbid-headliner"
        let id = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/feat.flac"), bookmark: nil, tags: tags, fileMtime: 1, fileSize: 1
        )
        #expect(try await trackRepo.fetch(id: id).musicbrainzArtistID == "mbid-guest")
        #expect(try await artistRepo.fetchOne(name: "Guest")?.musicbrainzArtistID == "mbid-guest")
        #expect(try await artistRepo.fetchOne(name: "Headliner")?.musicbrainzArtistID == "mbid-headliner")
    }

    @Test("release type from tags reaches the album row (#403)")
    func releaseTypeReachesAlbum() async throws {
        let db = try await makeDB()
        let albumRepo = AlbumRepository(database: db)
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: albumRepo,
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var tags = self.makeTags(title: "Lead")
        tags.releaseType = "ep"
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/ep.flac"), bookmark: nil, tags: tags, fileMtime: 1, fileSize: 1
        )
        #expect(try await albumRepo.fetchAll().first?.releaseType == "ep")

        // A track without the tag leaves it alone.
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/ep2.flac"), bookmark: nil, tags: self.makeTags(title: "B-side"), fileMtime: 1, fileSize: 1
        )
        #expect(try await albumRepo.fetchAll().first?.releaseType == "ep")
    }

    @Test("MusicBrainz release IDs roll up to the album row (#402)")
    func musicBrainzIDsRollUpToAlbum() async throws {
        let db = try await makeDB()
        let albumRepo = AlbumRepository(database: db)
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: albumRepo,
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var tags = self.makeTags(title: "One")
        tags.musicbrainzReleaseID = "rel-A"
        tags.musicbrainzReleaseGroupID = "rg-1"
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/mb-one.flac"), bookmark: nil, tags: tags, fileMtime: 1, fileSize: 1
        )
        var album = try #require(try await albumRepo.fetchAll().first)
        #expect(album.musicbrainzReleaseID == "rel-A")
        #expect(album.musicbrainzReleaseGroupID == "rg-1")

        // A second pressing of the same release group clears the release ID only.
        var other = self.makeTags(title: "Two")
        other.musicbrainzReleaseID = "rel-B"
        other.musicbrainzReleaseGroupID = "rg-1"
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/mb-two.flac"), bookmark: nil, tags: other, fileMtime: 1, fileSize: 1
        )
        album = try #require(try await albumRepo.fetchAll().first)
        #expect(album.musicbrainzReleaseID == nil)
        #expect(album.musicbrainzReleaseGroupID == "rg-1")
    }

    @Test("ARTISTSORT and ALBUMARTISTSORT reach the artist rows (#400)")
    func sortNamesReachArtistRows() async throws {
        let db = try await makeDB()
        let artistRepo = ArtistRepository(database: db)
        let importer = TrackImporter(
            artistRepo: artistRepo,
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        var tags = self.makeTags(title: "Something")
        tags.artist = "The Beatles"
        tags.sortArtist = "Beatles, The"
        tags.albumArtist = "Various Artists"
        tags.sortAlbumArtist = "Various"
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/sort.flac"), bookmark: nil, tags: tags, fileMtime: 1, fileSize: 1
        )
        #expect(try await artistRepo.fetchOne(name: "The Beatles")?.sortName == "Beatles, The")
        #expect(try await artistRepo.fetchOne(name: "Various Artists")?.sortName == "Various")

        // Untagged file: derived.
        var untagged = self.makeTags(title: "Baba")
        untagged.artist = "The Who"
        _ = try await importer.importTrack(
            url: URL(fileURLWithPath: "/tmp/who.flac"), bookmark: nil, tags: untagged, fileMtime: 1, fileSize: 1
        )
        #expect(try await artistRepo.fetchOne(name: "The Who")?.sortName == "Who, The")
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
}
