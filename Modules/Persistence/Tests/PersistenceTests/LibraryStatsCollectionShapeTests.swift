import Foundation
import Testing
@testable import Persistence

/// The Collection Shape report queries (#373), in their own suite like the
/// audio-quality tests so each file stays within the type-length budget.
@Suite("LibraryStatsRepository collection shape")
struct LibraryStatsCollectionShapeTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Duration, listening time, and year for one seeded track.
    private struct ShapeTrackSpec {
        var duration: Double = 60
        var played: Double = 0
        var year: Int?
    }

    private func makeArtist(_ db: Database, name: String) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: name)
            try artist.insert(db)
            return try #require(artist.id)
        }
    }

    @discardableResult
    private func seedAlbum(
        _ db: Database,
        title: String,
        artistID: Int64,
        tracks: [ShapeTrackSpec],
        year: Int? = nil
    ) async throws -> Int64 {
        try await db.write { db in
            var album = Album(title: title, albumArtistID: artistID)
            album.year = year
            try album.insert(db)
            let albumID = try #require(album.id)
            for (index, spec) in tracks.enumerated() {
                var track = Track(
                    fileURL: "file:///tmp/\(title)-\(index).flac",
                    fileFormat: "flac",
                    duration: spec.duration,
                    title: "\(title) \(index + 1)",
                    addedAt: 0,
                    updatedAt: 0
                )
                track.artistID = artistID
                track.albumArtistID = artistID
                track.albumID = albumID
                track.trackNumber = index + 1
                track.year = spec.year
                track.playDurationTotal = spec.played
                try track.insert(db)
            }
            return albumID
        }
    }

    @Test("Year histogram and decade shares split ownership from listening")
    func yearsAndDecades() async throws {
        let db = try await makeDB()
        let artist = try await makeArtist(db, name: "Shape")
        try await self.seedAlbum(db, title: "Nineties", artistID: artist, tracks: [
            .init(duration: 100, played: 50, year: 1994),
            .init(duration: 200, played: 0, year: 1994),
            .init(duration: 300, played: 600, year: 1995),
        ])
        try await self.seedAlbum(db, title: "Noughties", artistID: artist, tracks: [
            .init(duration: 400, played: 0, year: 2003),
            .init(duration: 500, played: 0, year: 190),
            .init(duration: 600, played: 0),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchCollectionShape()
        let expectedYears: [LibraryCollectionShapeReport.YearCount] = [
            .init(year: 1994, count: 2),
            .init(year: 1995, count: 1),
            .init(year: 2003, count: 1),
        ]
        #expect(report.years == expectedYears)
        #expect(report.undatedTrackCount == 2, "a junk year and a missing year are both undated")
        let expectedDecades: [LibraryCollectionShapeReport.DecadeShare] = [
            .init(decade: 1990, trackCount: 3, ownedSeconds: 600, playedSeconds: 650),
            .init(decade: 2000, trackCount: 1, ownedSeconds: 400, playedSeconds: 0),
        ]
        #expect(report.decades == expectedDecades)
    }

    @Test("Artist depth counts the one-track tail and the deep catalogues")
    func artistDepth() async throws {
        let db = try await makeDB()
        let single = try await makeArtist(db, name: "One Hit")
        let modest = try await makeArtist(db, name: "Modest")
        let deep = try await makeArtist(db, name: "Prolific")
        try await self.seedAlbum(db, title: "Single Serving", artistID: single, tracks: [.init()])
        try await self.seedAlbum(db, title: "Modest LP", artistID: modest, tracks: [
            .init(),
            .init(),
            .init(),
        ])
        for index in 1 ... 10 {
            try await self.seedAlbum(db, title: "Prolific \(index)", artistID: deep, tracks: [.init()])
        }

        let report = try await LibraryStatsRepository(database: db).fetchCollectionShape()
        #expect(report.artistCount == 3)
        #expect(report.singleTrackArtistCount == 1, "only One Hit has exactly one track")
        #expect(report.deepArtistCount == 1, "only Prolific reaches ten albums")
        #expect(report.deepestArtists.first?.name == "Prolific")
        #expect(report.deepestArtists.first?.albumCount == 10)
    }

    @Test("Extremes find the outlier tracks and the longest album")
    func extremes() async throws {
        let db = try await makeDB()
        let artist = try await makeArtist(db, name: "Extremist")
        let longID = try await self.seedAlbum(db, title: "Marathon", artistID: artist, tracks: [
            .init(duration: 3600),
            .init(duration: 200),
            .init(duration: 100),
        ])
        try await self.seedAlbum(db, title: "Sprint", artistID: artist, tracks: [
            .init(duration: 0),
            .init(duration: 150),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchCollectionShape()
        #expect(report.longestTrack?.duration == 3600)
        #expect(report.longestTrack?.albumID == longID)
        #expect(report.shortestTrack?.duration == 100, "zero-length rows must not win shortest")
        #expect(report.longestAlbum?.id == longID)
        #expect(report.longestAlbum?.totalSeconds == 3900)
        #expect(report.longestAlbum?.trackCount == 3)
        #expect(report.longestAlbum?.albumArtistName == "Extremist")
    }

    @Test("Average album length by decade skips singles and EP stubs")
    func albumLengthByDecade() async throws {
        let db = try await makeDB()
        let artist = try await makeArtist(db, name: "Longform")
        try await self.seedAlbum(
            db,
            title: "Seventies LP",
            artistID: artist,
            tracks: [
                .init(duration: 300),
                .init(duration: 300),
                .init(duration: 300),
                .init(duration: 300),
            ],
            year: 1975
        )
        try await self.seedAlbum(
            db,
            title: "Seventies Single",
            artistID: artist,
            tracks: [
                .init(duration: 2500),
                .init(duration: 2500),
            ],
            year: 1976
        )
        try await self.seedAlbum(
            db,
            title: "Nineties CD",
            artistID: artist,
            tracks: [
                .init(duration: 300),
                .init(duration: 300),
                .init(duration: 300),
                .init(duration: 300),
                .init(duration: 300),
            ],
            year: 1994
        )

        let report = try await LibraryStatsRepository(database: db).fetchCollectionShape()
        let expected: [LibraryCollectionShapeReport.DecadeAlbumLength] = [
            .init(decade: 1970, averageSeconds: 1200, albumCount: 1),
            .init(decade: 1990, averageSeconds: 1500, albumCount: 1),
        ]
        #expect(report.albumLengthByDecade == expected, "the two-track single must not join the mean")
    }

    @Test("An empty library yields an empty shape without crashing")
    func emptyLibrary() async throws {
        let db = try await makeDB()
        let report = try await LibraryStatsRepository(database: db).fetchCollectionShape()
        #expect(report.years.isEmpty)
        #expect(report.decades.isEmpty)
        #expect(report.artistCount == 0)
        #expect(report.longestTrack == nil)
        #expect(report.longestAlbum == nil)
        #expect(report.albumLengthByDecade.isEmpty)
    }
}
