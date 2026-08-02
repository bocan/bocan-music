import Foundation
import Testing
@testable import Persistence

@Suite("LibraryStatsRepository")
struct LibraryStatsRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Seeds: two artists fronting one album each (3 + 1 enabled tracks), one
    /// guest with a single track on the first album, a compilation with no
    /// album artist, and one disabled track that must count nowhere.
    private func seed(_ db: Database) async throws {
        try await db.write { db in
            func artist(_ name: String) throws -> Int64 {
                var artist = Artist(name: name)
                try artist.insert(db)
                return try #require(artist.id)
            }
            func album(_ title: String, albumArtistID: Int64?) throws -> Int64 {
                var album = Album(title: title, albumArtistID: albumArtistID)
                try album.insert(db)
                return try #require(album.id)
            }
            func track(
                _ title: String,
                artistID: Int64?,
                albumID: Int64?,
                duration: Double,
                disabled: Bool = false
            ) throws {
                var t = Track(
                    fileURL: "file:///tmp/\(title).mp3",
                    fileSize: 1,
                    fileMtime: 0,
                    fileFormat: "mp3",
                    duration: duration,
                    title: title,
                    addedAt: 0,
                    updatedAt: 0
                )
                t.artistID = artistID
                t.albumID = albumID
                t.disabled = disabled
                try t.insert(db)
            }

            let alpha = try artist("Alpha")
            let beta = try artist("Beta")
            let guest = try artist("Guest")

            let alphaLP = try album("Alpha LP", albumArtistID: alpha)
            let betaLP = try album("Beta LP", albumArtistID: beta)
            let comp = try album("Compilation", albumArtistID: nil)

            try track("a1", artistID: alpha, albumID: alphaLP, duration: 100)
            try track("a2", artistID: alpha, albumID: alphaLP, duration: 200)
            try track("a3", artistID: alpha, albumID: alphaLP, duration: 300)
            try track("b1", artistID: beta, albumID: betaLP, duration: 400)
            try track("g1 (feat.)", artistID: guest, albumID: alphaLP, duration: 50)
            try track("c1", artistID: alpha, albumID: comp, duration: 25)
            try track("ghost", artistID: beta, albumID: betaLP, duration: 999, disabled: true)
        }
    }

    @Test("fetchSummary counts enabled tracks, albums, and artists")
    func countsEnabledEntities() async throws {
        let db = try await makeDB()
        try await self.seed(db)

        let stats = try await LibraryStatsRepository(database: db).fetchSummary()
        #expect(stats.songCount == 6) // the disabled track never counts
        #expect(stats.albumCount == 3) // both LPs and the compilation
        #expect(stats.artistCount == 3) // Alpha, Beta, and the guest credit
    }

    @Test("fetchSummary counts album artists via album-artist credits only")
    func countsAlbumArtists() async throws {
        let db = try await makeDB()
        try await self.seed(db)

        let stats = try await LibraryStatsRepository(database: db).fetchSummary()
        // Alpha and Beta front albums; the guest and the album-artist-less
        // compilation contribute nothing.
        #expect(stats.albumArtistCount == 2)
    }

    @Test("fetchSummary sums enabled durations only")
    func sumsEnabledDurations() async throws {
        let db = try await makeDB()
        try await self.seed(db)

        let stats = try await LibraryStatsRepository(database: db).fetchSummary()
        #expect(stats.totalDuration == 1075) // 100+200+300+400+50+25, not 999
    }

    @Test("fetchSummary returns zeroes for an empty library")
    func emptyLibrary() async throws {
        let db = try await makeDB()
        let stats = try await LibraryStatsRepository(database: db).fetchSummary()
        let empty = LibrarySummaryStats(
            songCount: 0,
            albumCount: 0,
            artistCount: 0,
            albumArtistCount: 0,
            totalDuration: 0
        )
        #expect(stats == empty)
    }
}
