import Foundation
import Testing
@testable import Persistence

// MARK: - AlbumRepositoryCollectionCardsTests

/// Tests for the collection-card cover query (Artists grid, phase 23-1).
///
/// Covers are keyed on the *track* artist so they match the album set counted
/// by `ArtistRepository.fetchAlbumCounts` (compilation appearances included).
@Suite("Album Repository Collection Cards")
struct AlbumRepositoryCollectionCardsTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private var now: Int64 {
        1_700_000_000
    }

    /// Inserts an album and returns its id.
    private func insertAlbum(
        _ repo: AlbumRepository,
        title: String,
        albumArtistID: Int64?,
        year: Int?,
        coverArtPath: String?
    ) async throws -> Int64 {
        try await repo.insert(
            Album(title: title, albumArtistID: albumArtistID, year: year, coverArtPath: coverArtPath)
        )
    }

    /// Inserts a track by `artistID` on `albumID`, optionally tagged with a
    /// genre/composer.
    private func insertTrack(
        _ repo: TrackRepository,
        title: String,
        artistID: Int64? = nil,
        albumID: Int64? = nil,
        genre: String? = nil,
        composer: String? = nil,
        disabled: Bool = false
    ) async throws {
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: self.now,
            fileFormat: "flac",
            duration: 180,
            title: title,
            artistID: artistID,
            albumID: albumID,
            genre: genre,
            composer: composer,
            addedAt: self.now,
            updatedAt: self.now
        )
        track.disabled = disabled
        _ = try await repo.insert(track)
    }

    @Test("Groups cover paths by the track artist")
    func groupsByArtist() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artistRepo = ArtistRepository(database: db)
        let artistA = try await artistRepo.insert(Artist(name: "Alpha"))
        let artistB = try await artistRepo.insert(Artist(name: "Beta"))
        let a1 = try await self.insertAlbum(repo, title: "A1", albumArtistID: artistA, year: 2000, coverArtPath: "/covers/a1.jpg")
        let a2 = try await self.insertAlbum(repo, title: "A2", albumArtistID: artistA, year: 2001, coverArtPath: "/covers/a2.jpg")
        let b1 = try await self.insertAlbum(repo, title: "B1", albumArtistID: artistB, year: 1999, coverArtPath: "/covers/b1.jpg")
        try await self.insertTrack(trackRepo, title: "t1", artistID: artistA, albumID: a1)
        try await self.insertTrack(trackRepo, title: "t2", artistID: artistA, albumID: a2)
        try await self.insertTrack(trackRepo, title: "t3", artistID: artistB, albumID: b1)

        let map = try await repo.fetchCoverArtPathsByArtist()
        #expect(map[artistA]?.count == 2)
        #expect(map[artistB] == ["/covers/b1.jpg"])
    }

    @Test("Includes compilation appearances (album artist differs from track artist)")
    func includesCompilations() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artistRepo = ArtistRepository(database: db)
        let artist = try await artistRepo.insert(Artist(name: "Guest"))
        let various = try await artistRepo.insert(Artist(name: "Various Artists"))
        // The artist's only album is a compilation credited to "Various Artists".
        let comp = try await self.insertAlbum(repo, title: "Comp", albumArtistID: various, year: 2010, coverArtPath: "/covers/comp.jpg")
        try await self.insertTrack(trackRepo, title: "guest track", artistID: artist, albumID: comp)

        let map = try await repo.fetchCoverArtPathsByArtist()
        // The old album-artist grouping would miss this entirely.
        #expect(map[artist] == ["/covers/comp.jpg"])
    }

    @Test("Excludes albums with no cover art")
    func excludesArtless() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artist = try await ArtistRepository(database: db).insert(Artist(name: "Alpha"))
        let withArt = try await self.insertAlbum(repo, title: "WithArt", albumArtistID: artist, year: 2000, coverArtPath: "/covers/x.jpg")
        let noArt = try await self.insertAlbum(repo, title: "NoArt", albumArtistID: artist, year: 2001, coverArtPath: nil)
        try await self.insertTrack(trackRepo, title: "t1", artistID: artist, albumID: withArt)
        try await self.insertTrack(trackRepo, title: "t2", artistID: artist, albumID: noArt)

        let map = try await repo.fetchCoverArtPathsByArtist()
        #expect(map[artist] == ["/covers/x.jpg"])
    }

    @Test("Excludes disabled tracks")
    func excludesDisabled() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artist = try await ArtistRepository(database: db).insert(Artist(name: "Alpha"))
        let album = try await self.insertAlbum(repo, title: "Only", albumArtistID: artist, year: 2000, coverArtPath: "/covers/only.jpg")
        try await self.insertTrack(trackRepo, title: "disabled", artistID: artist, albumID: album, disabled: true)

        let map = try await repo.fetchCoverArtPathsByArtist()
        #expect(map[artist] == nil)
    }

    @Test("Collapses many tracks on one album to a single cover")
    func onePerAlbum() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artist = try await ArtistRepository(database: db).insert(Artist(name: "Alpha"))
        let album = try await self.insertAlbum(repo, title: "Only", albumArtistID: artist, year: 2000, coverArtPath: "/covers/only.jpg")
        // Ten tracks on the same album must not produce ten cover entries.
        for i in 0 ..< 10 {
            try await self.insertTrack(trackRepo, title: "t\(i)", artistID: artist, albumID: album)
        }

        let map = try await repo.fetchCoverArtPathsByArtist()
        #expect(map[artist] == ["/covers/only.jpg"])
    }

    @Test("Orders covers by year DESC then title")
    func deterministicOrder() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artist = try await ArtistRepository(database: db).insert(Artist(name: "Alpha"))
        let older = try await self.insertAlbum(repo, title: "Older", albumArtistID: artist, year: 1990, coverArtPath: "/covers/old.jpg")
        let newerB = try await self.insertAlbum(repo, title: "Newer B", albumArtistID: artist, year: 2020, coverArtPath: "/covers/newB.jpg")
        let newerA = try await self.insertAlbum(repo, title: "Newer A", albumArtistID: artist, year: 2020, coverArtPath: "/covers/newA.jpg")
        try await self.insertTrack(trackRepo, title: "t1", artistID: artist, albumID: older)
        try await self.insertTrack(trackRepo, title: "t2", artistID: artist, albumID: newerB)
        try await self.insertTrack(trackRepo, title: "t3", artistID: artist, albumID: newerA)

        let map = try await repo.fetchCoverArtPathsByArtist()
        #expect(map[artist] == ["/covers/newA.jpg", "/covers/newB.jpg", "/covers/old.jpg"])
    }

    @Test("Respects the maxPerArtist cap")
    func respectsCap() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let artist = try await ArtistRepository(database: db).insert(Artist(name: "Alpha"))
        for i in 0 ..< 6 {
            let album = try await self.insertAlbum(
                repo, title: "Album \(i)", albumArtistID: artist, year: 2000 + i, coverArtPath: "/covers/\(i).jpg"
            )
            try await self.insertTrack(trackRepo, title: "t\(i)", artistID: artist, albumID: album)
        }

        let capped = try await repo.fetchCoverArtPathsByArtist(maxPerArtist: 4)
        #expect(capped[artist]?.count == 4)
        // Newest four (years 2005..2002), year DESC.
        #expect(capped[artist] == ["/covers/5.jpg", "/covers/4.jpg", "/covers/3.jpg", "/covers/2.jpg"])

        let capTwo = try await repo.fetchCoverArtPathsByArtist(maxPerArtist: 2)
        #expect(capTwo[artist]?.count == 2)
    }

    // MARK: - Genre / composer cards

    /// Seeds an assortment of genre edge rows and returns the database.
    ///
    /// - "Rock": two albums (one with art), plus a track with no album.
    /// - "Jazz": one album with art.
    /// - "": an empty-string genre on one track (the list includes it).
    /// - NULL genre on one track (the list excludes it).
    /// - a disabled track carrying an otherwise-unique genre "Deleted".
    /// - a compilation album (nil album artist) whose track is tagged "Rock".
    private func seedGenres(_ repo: AlbumRepository, _ trackRepo: TrackRepository) async throws {
        let rockA = try await self.insertAlbum(repo, title: "RockA", albumArtistID: nil, year: 2001, coverArtPath: "/covers/rockA.jpg")
        let rockB = try await self.insertAlbum(repo, title: "RockB", albumArtistID: nil, year: 2002, coverArtPath: nil)
        let jazz = try await self.insertAlbum(repo, title: "JazzA", albumArtistID: nil, year: 1999, coverArtPath: "/covers/jazz.jpg")
        let comp = try await self.insertAlbum(repo, title: "Comp", albumArtistID: nil, year: 2010, coverArtPath: "/covers/comp.jpg")
        try await self.insertTrack(trackRepo, title: "r1", albumID: rockA, genre: "Rock")
        try await self.insertTrack(trackRepo, title: "r2", albumID: rockB, genre: "Rock")
        try await self.insertTrack(trackRepo, title: "r3", albumID: nil, genre: "Rock") // no album
        try await self.insertTrack(trackRepo, title: "r4", albumID: comp, genre: "Rock") // compilation
        try await self.insertTrack(trackRepo, title: "j1", albumID: jazz, genre: "Jazz")
        try await self.insertTrack(trackRepo, title: "e1", albumID: rockA, genre: "") // empty string
        try await self.insertTrack(trackRepo, title: "n1", albumID: rockA, genre: nil) // null
        try await self.insertTrack(trackRepo, title: "d1", albumID: jazz, genre: "Deleted", disabled: true)
    }

    @Test("Genre cards match the list set exactly (empty string in, null and disabled out)")
    func genreSetEquality() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        try await self.seedGenres(repo, trackRepo)

        let cards = try await repo.fetchGenreCards()
        let listGenres = try await trackRepo.allGenres()
        #expect(Set(cards.map(\.name)) == Set(listGenres))
        // Concretely: Rock, Jazz and the empty string; not "Deleted" (disabled) or null.
        #expect(Set(cards.map(\.name)) == ["Rock", "Jazz", ""])
    }

    @Test("Genre counts: distinct albums, songs include album-less tracks, exclude disabled")
    func genreCounts() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        try await self.seedGenres(repo, trackRepo)

        let cards = try await repo.fetchGenreCards()
        let rock = try #require(cards.first { $0.name == "Rock" })
        // Three distinct albums (RockA, RockB, Comp); r3 has no album so adds no
        // album but does count as a song. Four Rock songs total.
        #expect(rock.albumCount == 3)
        #expect(rock.songCount == 4)
        // Covers only from albums that have art: RockA and Comp (RockB has none).
        #expect(rock.coverArtPaths.contains("/covers/rockA.jpg"))
        #expect(rock.coverArtPaths.contains("/covers/comp.jpg"))
        #expect(!rock.coverArtPaths.contains { $0.isEmpty })
        #expect(rock.coverArtPaths.count == 2)
    }

    @Test("Composer cards match the list set exactly")
    func composerSetEquality() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let album = try await self.insertAlbum(repo, title: "A", albumArtistID: nil, year: 2000, coverArtPath: "/covers/a.jpg")
        try await self.insertTrack(trackRepo, title: "t1", albumID: album, composer: "Bach")
        try await self.insertTrack(trackRepo, title: "t2", albumID: album, composer: "Mozart")
        try await self.insertTrack(trackRepo, title: "t3", albumID: album, composer: "") // empty string
        try await self.insertTrack(trackRepo, title: "t4", albumID: album, composer: nil) // null
        try await self.insertTrack(trackRepo, title: "t5", albumID: album, composer: "Ghost", disabled: true)

        let cards = try await repo.fetchComposerCards()
        let listComposers = try await trackRepo.allComposers()
        #expect(Set(cards.map(\.name)) == Set(listComposers))
        #expect(Set(cards.map(\.name)) == ["Bach", "Mozart", ""])
    }

    // MARK: - Destination album filters (fetchAll(genre:) / fetchAll(composer:))

    @Test("fetchAll(genre:) returns distinct albums in title order, excluding disabled")
    func fetchAlbumsByGenre() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let zed = try await self.insertAlbum(repo, title: "Zed", albumArtistID: nil, year: 2001, coverArtPath: nil)
        let ace = try await self.insertAlbum(repo, title: "Ace", albumArtistID: nil, year: 2002, coverArtPath: nil)
        let other = try await self.insertAlbum(repo, title: "Other", albumArtistID: nil, year: 2003, coverArtPath: nil)
        // Two Rock tracks on "Ace" must not duplicate the album.
        try await self.insertTrack(trackRepo, title: "r1", albumID: ace, genre: "Rock")
        try await self.insertTrack(trackRepo, title: "r2", albumID: ace, genre: "Rock")
        try await self.insertTrack(trackRepo, title: "r3", albumID: zed, genre: "Rock")
        // A disabled Rock track on "Other" must not include it.
        try await self.insertTrack(trackRepo, title: "r4", albumID: other, genre: "Rock", disabled: true)
        // A Rock track with no album contributes nothing.
        try await self.insertTrack(trackRepo, title: "r5", albumID: nil, genre: "Rock")
        // A Jazz track must not leak into the Rock result.
        try await self.insertTrack(trackRepo, title: "j1", albumID: other, genre: "Jazz")

        let albums = try await repo.fetchAll(genre: "Rock")
        #expect(albums.map(\.title) == ["Ace", "Zed"])
    }

    @Test("fetchAll(composer:) returns distinct albums in title order, excluding disabled")
    func fetchAlbumsByComposer() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let beta = try await self.insertAlbum(repo, title: "Beta", albumArtistID: nil, year: 2001, coverArtPath: nil)
        let alpha = try await self.insertAlbum(repo, title: "Alpha", albumArtistID: nil, year: 2002, coverArtPath: nil)
        let gone = try await self.insertAlbum(repo, title: "Gone", albumArtistID: nil, year: 2003, coverArtPath: nil)
        try await self.insertTrack(trackRepo, title: "b1", albumID: beta, composer: "Bach")
        try await self.insertTrack(trackRepo, title: "a1", albumID: alpha, composer: "Bach")
        try await self.insertTrack(trackRepo, title: "g1", albumID: gone, composer: "Bach", disabled: true)

        let albums = try await repo.fetchAll(composer: "Bach")
        #expect(albums.map(\.title) == ["Alpha", "Beta"])
    }

    @Test("Genre cover paths are deduped and capped")
    func genreCoversDedupedAndCapped() async throws {
        let db = try await self.makeDatabase()
        let repo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        // Six distinct albums with art, all tagged "Pop".
        for i in 0 ..< 6 {
            let album = try await self.insertAlbum(
                repo,
                title: "P\(i)",
                albumArtistID: nil,
                year: 2000 + i,
                coverArtPath: "/covers/p\(i).jpg"
            )
            try await self.insertTrack(trackRepo, title: "t\(i)", albumID: album, genre: "Pop")
        }
        let cards = try await repo.fetchGenreCards(maxCovers: 4)
        let pop = try #require(cards.first { $0.name == "Pop" })
        #expect(pop.coverArtPaths.count == 4)
        // Newest four first (years 2005..2002), deterministic.
        #expect(pop.coverArtPaths == ["/covers/p5.jpg", "/covers/p4.jpg", "/covers/p3.jpg", "/covers/p2.jpg"])
    }
}
