import Foundation
import Testing
@testable import Persistence

@Suite("ArtistRepository")
struct ArtistRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @discardableResult
    private func seedTrack(
        _ db: Database,
        title: String,
        artistID: Int64?,
        albumID: Int64?,
        disabled: Bool = false
    ) async throws -> Int64 {
        try await db.write { db in
            var t = Track(
                fileURL: "file:///tmp/\(title).mp3",
                fileSize: 1,
                fileMtime: 0,
                fileFormat: "mp3",
                duration: 1,
                title: title,
                addedAt: 0,
                updatedAt: 0
            )
            t.artistID = artistID
            t.albumID = albumID
            t.disabled = disabled
            try t.insert(db)
            return try #require(t.id)
        }
    }

    private func seedArtist(_ db: Database, name: String) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: name)
            try artist.insert(db)
            return try #require(artist.id)
        }
    }

    private func seedAlbum(_ db: Database, title: String, albumArtistID: Int64?) async throws -> Int64 {
        try await db.write { db in
            var album = Album(title: title, albumArtistID: albumArtistID)
            try album.insert(db)
            return try #require(album.id)
        }
    }

    // MARK: - Sort names (#400)

    @Test("derivedSortName moves a leading English article", arguments: [
        ("The Beatles", "Beatles, The"),
        ("A Tribe Called Quest", "Tribe Called Quest, A"),
        ("An Emotional Fish", "Emotional Fish, An"),
        ("the the", "the, the"),
    ])
    func derivedSortName(name: String, expected: String) {
        #expect(Artist.derivedSortName(from: name) == expected)
    }

    @Test("derivedSortName leaves names without an article alone", arguments: [
        "Beatles", "Los Lobos", "La Roux", "Theatre of Hate", "The", "A", "",
    ])
    func derivedSortNameNil(name: String) {
        #expect(Artist.derivedSortName(from: name) == nil)
    }

    @Test("findOrCreate stores the tag sort name, derives one without it, and lets a tag replace the derivation")
    func findOrCreateSortName() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)

        // No tag: derived.
        var beatles = try await repo.findOrCreate(name: "The Beatles")
        #expect(beatles.sortName == "Beatles, The")

        // A later file with a tag overrides the derivation.
        beatles = try await repo.findOrCreate(name: "The Beatles", sortName: "Beatles")
        #expect(beatles.sortName == "Beatles")
        #expect(try await repo.fetch(id: #require(beatles.id)).sortName == "Beatles")

        // A file without a tag does not clobber a stored one.
        beatles = try await repo.findOrCreate(name: "The Beatles")
        #expect(beatles.sortName == "Beatles")

        // Tag on first sight wins over the derivation.
        let quest = try await repo.findOrCreate(name: "A Tribe Called Quest", sortName: "Tribe Called Quest")
        #expect(quest.sortName == "Tribe Called Quest")

        // No article, no tag: stays NULL.
        let cream = try await repo.findOrCreate(name: "Cream")
        #expect(cream.sortName == nil)
    }

    @Test("findOrCreate fills a NULL MusicBrainz ID once and never overwrites it (#399)")
    func findOrCreateMusicBrainzID() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)
        var beatles = try await repo.findOrCreate(name: "The Beatles")
        #expect(beatles.musicbrainzArtistID == nil)
        beatles = try await repo.findOrCreate(name: "The Beatles", musicbrainzID: "mbid-1")
        #expect(beatles.musicbrainzArtistID == "mbid-1")
        beatles = try await repo.findOrCreate(name: "The Beatles", musicbrainzID: "mbid-2")
        #expect(beatles.musicbrainzArtistID == "mbid-1")
        beatles = try await repo.findOrCreate(name: "The Beatles", musicbrainzID: "")
        #expect(beatles.musicbrainzArtistID == "mbid-1")
        #expect(try await repo.fetch(id: #require(beatles.id)).musicbrainzArtistID == "mbid-1")
        let fresh = try await repo.findOrCreate(name: "Cream", musicbrainzID: "mbid-cream")
        #expect(fresh.musicbrainzArtistID == "mbid-cream")
        #expect(fresh.musicbrainzIDSource == "tag")
        #expect(beatles.musicbrainzIDSource == "tag")
    }

    @Test("enrichment queue lists MBID artists once, and setEnrichment fills without clobbering (#401)")
    func enrichmentQueue() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)
        let tagged = try await repo.findOrCreate(name: "The Kestrels", sortName: "Kestrels, The", musicbrainzID: "mb-1")
        let bare = try await repo.findOrCreate(name: "Solo One", musicbrainzID: "mb-2")
        _ = try await repo.findOrCreate(name: "No MBID")

        #expect(try await repo.countNeedingEnrichment() == 2)
        #expect(try await repo.fetchNeedingEnrichment(limit: 10).map(\.name) == ["The Kestrels", "Solo One"])
        #expect(try await repo.fetchNeedingEnrichment(limit: 1).map(\.name) == ["The Kestrels"])

        #expect(try await repo
            .setEnrichment(mbid: "mb-1", disambiguation: "UK folk band", sortName: "Kestrels, The (MB)", fetchedAt: 100) == 1)
        _ = try await repo.findOrCreate(name: "Solo One feat. Guest", musicbrainzID: "mb-2")
        #expect(
            try await repo.setEnrichment(mbid: "mb-2", disambiguation: "", sortName: "One, Solo", fetchedAt: 100) == 2,
            "every row sharing the MBID is stamped"
        )
        #expect(try await repo.fetchOne(name: "Solo One feat. Guest")?.musicbrainzFetchedAt == 100)
        let first = try await repo.fetch(id: #require(tagged.id))
        #expect(first.disambiguation == "UK folk band")
        #expect(first.sortName == "Kestrels, The", "an existing sort name is kept")
        #expect(first.musicbrainzFetchedAt == 100)
        let second = try await repo.fetch(id: #require(bare.id))
        #expect(second.disambiguation == nil, "empty disambiguation stored as NULL")
        #expect(second.sortName == "One, Solo", "MusicBrainz fills a missing sort name")
        #expect(try await repo.countNeedingEnrichment() == 0)
    }

    @Test("fetchAll orders by sort name with display-name fallback")
    func fetchAllOrdersBySortName() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)
        for name in ["The Who", "Cream", "The Beatles", "abba", "Zappa"] {
            _ = try await repo.findOrCreate(name: name)
        }
        let names = try await repo.fetchAll().map(\.name)
        #expect(names == ["abba", "The Beatles", "Cream", "The Who", "Zappa"])
    }

    @Test("fetchAlbumArtistIDs includes artists credited as an album artist")
    func includesAlbumArtists() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let album = try await seedAlbum(db, title: "LP", albumArtistID: headliner)
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids == [headliner])
    }

    @Test("fetchAlbumArtistIDs excludes artists with only per-track credits")
    func excludesGuestArtists() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let guest = try await seedArtist(db, name: "Guest")
        let album = try await seedAlbum(db, title: "LP", albumArtistID: headliner)
        // The guest sings a track on the headliner's album but fronts no album.
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album)
        try await self.seedTrack(db, title: "t2 (feat. Guest)", artistID: guest, albumID: album)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.contains(headliner))
        #expect(!ids.contains(guest))
    }

    @Test("fetchAlbumArtistIDs ignores compilations with no album artist")
    func ignoresCompilations() async throws {
        let db = try await makeDB()
        let contributor = try await seedArtist(db, name: "Contributor")
        // A "Various Artists" compilation: album_artist_id is NULL by design.
        let compilation = try await seedAlbum(db, title: "Now That's Music", albumArtistID: nil)
        try await self.seedTrack(db, title: "t1", artistID: contributor, albumID: compilation)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.isEmpty)
    }

    @Test("fetchAlbumArtistIDs excludes albums whose tracks are all disabled")
    func excludesFullyDisabledAlbums() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let album = try await seedAlbum(db, title: "Vanished LP", albumArtistID: headliner)
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album, disabled: true)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.isEmpty)
    }

    @Test("a confirmed search id is stored with its source and yields to the next tagged id (#413)")
    func confirmedSearchIDYieldsToTag() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)
        var band = try await repo.findOrCreate(name: "The Kestrels")
        #expect(band.musicbrainzArtistID == nil)
        #expect(band.musicbrainzIDSource == nil)
        let id = try #require(band.id)

        #expect(try await repo.setMusicBrainzID(id: id, mbid: "guess-1", source: .search) == 1)
        band = try await repo.fetch(id: id)
        #expect(band.musicbrainzArtistID == "guess-1")
        #expect(band.musicbrainzIDSource == "search")

        // An untagged rescan leaves the confirmation alone.
        band = try await repo.findOrCreate(name: "The Kestrels")
        #expect(band.musicbrainzArtistID == "guess-1")
        #expect(band.musicbrainzIDSource == "search")

        // A tagged id (a Picard pass) replaces the guess.
        band = try await repo.findOrCreate(name: "The Kestrels", musicbrainzID: "tagged-1")
        #expect(band.musicbrainzArtistID == "tagged-1")
        #expect(band.musicbrainzIDSource == "tag")
        band = try await repo.fetch(id: id)
        #expect(band.musicbrainzArtistID == "tagged-1")
        #expect(band.musicbrainzIDSource == "tag")

        // Once tagged, a different tagged id no longer wins (first-seen rule).
        band = try await repo.findOrCreate(name: "The Kestrels", musicbrainzID: "tagged-2")
        #expect(band.musicbrainzArtistID == "tagged-1")
        #expect(try await repo.setMusicBrainzID(id: 9999, mbid: "x", source: .search) == 0)
    }

    @Test("observeEnrichmentProgress counts artists with an id and follows each stamp")
    func observeEnrichmentProgress() async throws {
        let db = try await makeDB()
        let repo = ArtistRepository(database: db)
        _ = try await repo.findOrCreate(name: "Tagged", musicbrainzID: "mbid-1")
        _ = try await repo.findOrCreate(name: "Also Tagged", musicbrainzID: "mbid-2")
        _ = try await repo.findOrCreate(name: "Bare")

        let stream = await repo.observeEnrichmentProgress()
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == ArtistEnrichmentProgress(fetched: 0, total: 2))
        #expect(initial?.remaining == 2)
        #expect(initial?.isComplete == false)

        try await repo.setEnrichment(mbid: "mbid-1", disambiguation: "band", sortName: nil, fetchedAt: 100)
        #expect(try await iterator.next() == ArtistEnrichmentProgress(fetched: 1, total: 2))
        try await repo.setEnrichment(mbid: "mbid-2", disambiguation: nil, sortName: nil, fetchedAt: 101)
        let done = try await iterator.next()
        #expect(done == ArtistEnrichmentProgress(fetched: 2, total: 2))
        #expect(done?.isComplete == true)
    }
}
