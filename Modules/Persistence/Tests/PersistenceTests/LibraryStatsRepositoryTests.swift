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

    // MARK: - Hygiene

    private func seedHygieneAlbum(
        _ db: Database,
        title: String,
        artistName: String,
        trackNumbers: [Int],
        year: Int? = nil,
        coverArtHash: String? = nil,
        musicbrainzReleaseID: String? = nil,
        trackYear: Int? = nil
    ) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: artistName)
            try artist.insert(db)
            if let coverArtHash {
                // cover_art_hash is a foreign key; the referenced row must
                // exist. Callers use a distinct hash per album.
                var art = CoverArt(hash: coverArtHash, path: "/art/\(coverArtHash).jpg")
                try art.insert(db)
            }
            var album = Album(title: title, albumArtistID: artist.id)
            album.year = year
            album.coverArtHash = coverArtHash
            album.musicbrainzReleaseID = musicbrainzReleaseID
            try album.insert(db)
            let albumID = try #require(album.id)
            for n in trackNumbers {
                var t = Track(
                    fileURL: "file:///tmp/\(title)-\(artistName)-\(n).mp3",
                    fileSize: 1,
                    fileMtime: 0,
                    fileFormat: "mp3",
                    duration: 60,
                    title: "\(title) \(n)",
                    addedAt: 0,
                    updatedAt: 0
                )
                t.artistID = artist.id
                t.albumID = albumID
                t.trackNumber = n
                t.year = trackYear
                try t.insert(db)
            }
            return albumID
        }
    }

    @Test("fetchHygiene reports track number gaps, worst offenders first")
    func hygieneTrackGaps() async throws {
        let db = try await makeDB()
        try await self.seedHygieneAlbum(
            db,
            title: "Gappy",
            artistName: "GapArtist",
            trackNumbers: [1, 2, 3, 5, 6],
            year: 2000,
            coverArtHash: "h",
            musicbrainzReleaseID: "mb"
        )
        try await self.seedHygieneAlbum(
            db,
            title: "Complete",
            artistName: "TidyArtist",
            trackNumbers: [1, 2, 3],
            year: 2001,
            coverArtHash: "h2",
            musicbrainzReleaseID: "mb2"
        )

        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.trackGapAlbumCount == 1)
        #expect(report.trackGapAlbums.first?.albumTitle == "Gappy")
        #expect(report.trackGapAlbums.first?.missingTrackNumbers == [4])
        #expect(report.trackGapAlbums.first?.albumArtistName == "GapArtist")
    }

    @Test("fetchHygiene flags implausible years and album disagreements")
    func hygieneSuspiciousYears() async throws {
        let db = try await makeDB()
        // Track year 1085: implausible outright.
        try await self.seedHygieneAlbum(
            db,
            title: "Medieval",
            artistName: "Monk",
            trackNumbers: [1, 2],
            coverArtHash: "h",
            musicbrainzReleaseID: "mb",
            trackYear: 1085
        )
        // Track year 1999 against album year 2001: a disagreement.
        try await self.seedHygieneAlbum(
            db,
            title: "Reissue",
            artistName: "Band",
            trackNumbers: [1, 2],
            year: 2001,
            coverArtHash: "h2",
            musicbrainzReleaseID: "mb2",
            trackYear: 1999
        )

        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.suspiciousYearCount == 4) // two tracks per seeded album
        let implausible = report.suspiciousYearTracks.first { $0.year == 1085 }
        #expect(implausible != nil)
        #expect(implausible?.albumYear == nil) // no album year to disagree with
        let disagreement = report.suspiciousYearTracks.first { $0.year == 1999 }
        #expect(disagreement?.albumYear == 2001)
        #expect(disagreement?.albumID != nil) // offender rows navigate to the album
    }

    @Test("fetchHygiene flags exploded albums but not shared titles")
    func hygieneSplitAlbums() async throws {
        let db = try await makeDB()
        // The explosion: one shard variant beside the real album.
        let substantialID = try await self.seedHygieneAlbum(
            db,
            title: "Use Your Illusion",
            artistName: "Guns N' Roses",
            trackNumbers: [1, 2, 3, 4],
            year: 1991,
            coverArtHash: "h",
            musicbrainzReleaseID: "mb"
        )
        _ = try await self.seedHygieneAlbum(
            db,
            title: "Use Your Illusion",
            artistName: "Guns N Roses",
            trackNumbers: [5],
            year: 1991,
            coverArtHash: "h-shard",
            musicbrainzReleaseID: "mb"
        )
        // Legitimate shared title: both variants substantial.
        _ = try await self.seedHygieneAlbum(
            db,
            title: "Greatest Hits",
            artistName: "Queen",
            trackNumbers: [1, 2, 3],
            year: 1981,
            coverArtHash: "h2",
            musicbrainzReleaseID: "mb2"
        )
        _ = try await self.seedHygieneAlbum(
            db,
            title: "Greatest Hits",
            artistName: "ABBA",
            trackNumbers: [1, 2, 3],
            year: 1992,
            coverArtHash: "h3",
            musicbrainzReleaseID: "mb3"
        )

        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.splitAlbumCount == 1)
        #expect(report.splitAlbums.first?.title == "Use Your Illusion")
        #expect(report.splitAlbums.first?.variantCount == 2)
        #expect(report.splitAlbums.first?.shardCount == 1)
        // Navigation lands on the substantial copy, not the shard.
        #expect(report.splitAlbums.first?.primaryAlbumID == substantialID)
    }

    @Test("fetchHygiene counts low-resolution art and ignores unknown dimensions (#417)")
    func hygieneLowResolutionArt() async throws {
        let db = try await makeDB()
        try await self.seedHygieneAlbum(db, title: "Thumb", artistName: "A", trackNumbers: [1], coverArtHash: "small")
        try await self.seedHygieneAlbum(db, title: "Proper", artistName: "B", trackNumbers: [1], coverArtHash: "big")
        try await self.seedHygieneAlbum(db, title: "Unknown", artistName: "C", trackNumbers: [1], coverArtHash: "unk")
        try await db.write { db in
            try db.execute(sql: "UPDATE cover_art SET width = 300, height = 300 WHERE hash = 'small'")
            try db.execute(sql: "UPDATE cover_art SET width = 1400, height = 1400 WHERE hash = 'big'")
        }
        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.albumCount == 3)
        #expect(report.albumsLowResolutionArt == 1)
    }

    @Test("fetchHygiene counts completeness gaps and missing files")
    func hygieneCompletenessAndMissingFiles() async throws {
        let db = try await makeDB()
        // Missing artwork, year, and MBID all at once.
        let bareID = try await self.seedHygieneAlbum(
            db,
            title: "Bare",
            artistName: "Untagged",
            trackNumbers: [1, 2]
        )
        // Fully tagged.
        try await self.seedHygieneAlbum(
            db,
            title: "Tagged",
            artistName: "Tidy",
            trackNumbers: [1, 2],
            year: 2020,
            coverArtHash: "h",
            musicbrainzReleaseID: "mb"
        )
        // One vanished file on the bare album.
        try await db.write { db in
            var ghost = Track(
                fileURL: "file:///tmp/ghost.mp3",
                fileSize: 1,
                fileMtime: 0,
                fileFormat: "mp3",
                duration: 60,
                title: "Ghost",
                addedAt: 0,
                updatedAt: 0
            )
            ghost.albumID = bareID
            ghost.disabled = true
            try ghost.insert(db)
        }

        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.albumCount == 2)
        #expect(report.albumsMissingArtwork == 1)
        #expect(report.albumsMissingYear == 1)
        #expect(report.albumsMissingMusicBrainzID == 1)
        #expect(report.missingFileCount == 1)
        #expect(report.missingFiles.first?.trackTitle == "Ghost")
        #expect(report.missingFiles.first?.albumID == bareID)
        #expect(report.isClean == false)
    }

    @Test("fetchHygiene reports a clean bill for a tidy library")
    func hygieneClean() async throws {
        let db = try await makeDB()
        try await self.seedHygieneAlbum(
            db,
            title: "Tidy LP",
            artistName: "Tidy",
            trackNumbers: [1, 2, 3],
            year: 2020,
            coverArtHash: "h",
            musicbrainzReleaseID: "mb"
        )
        let report = try await LibraryStatsRepository(database: db).fetchHygiene()
        #expect(report.isClean)
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
