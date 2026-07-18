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

    /// Inserts a track by `artistID` on `albumID`.
    private func insertTrack(
        _ repo: TrackRepository,
        title: String,
        artistID: Int64?,
        albumID: Int64?,
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
}
