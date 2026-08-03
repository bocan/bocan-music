import Foundation
import Testing
@testable import Persistence

/// The time-analytics queries (#373, phase 25-3). Expected buckets are
/// computed with `Calendar.current`, which shares the system time zone with
/// SQLite's `localtime` modifier, so these tests hold in any zone.
@Suite("LibraryStatsRepository listening time")
struct LibraryStatsListeningTimeTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database, artistName: String, title: String) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: artistName)
            try artist.insert(db)
            var track = Track(
                fileURL: "file:///tmp/\(artistName)-\(title).flac",
                fileFormat: "flac",
                duration: 200,
                title: title,
                addedAt: 0,
                updatedAt: 0
            )
            track.artistID = artist.id
            try track.insert(db)
            return try #require(track.id)
        }
    }

    private func localPlay(_ db: Database, trackID: Int64, at playedAt: Int64) async throws {
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (track_id, played_at, duration_played, source) VALUES (?, ?, ?, ?)",
                arguments: [trackID, playedAt, 180, "queue"]
            )
        }
    }

    private func importedPlay(_ db: Database, artist: String, title: String, at playedAt: Int64) async throws {
        try await db.write { db in
            var listen = ImportedListen(playedAt: playedAt, artist: artist, title: title)
            try listen.insert(db)
        }
    }

    /// Epoch seconds for a wall-clock moment in the current time zone.
    private func epoch(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) throws -> Int64 {
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        let date = try #require(Calendar.current.date(from: components))
        return Int64(date.timeIntervalSince1970)
    }

    /// The heatmap bucket SQLite's localtime maths will produce for `epoch`.
    private func bucket(_ epoch: Int64) -> (weekday: Int, hour: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let hour = Calendar.current.component(.hour, from: date)
        return (weekday, hour)
    }

    /// Calendar year and month for `epoch`, matching the SQL bucketing.
    private func yearMonth(_ epoch: Int64) -> (year: Int, month: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return (
            Calendar.current.component(.year, from: date),
            Calendar.current.component(.month, from: date)
        )
    }

    @Test("The heatmap unions local plays and imported listens")
    func heatmapUnionsSources() async throws {
        let db = try await makeDB()
        let track = try await self.seedTrack(db, artistName: "Heat", title: "Map")
        let first = try self.epoch(2024, 1, 10, 21)
        let second = first + 7 * 86400
        let other = try self.epoch(2024, 1, 12, 9)
        try await self.localPlay(db, trackID: track, at: first)
        try await self.importedPlay(db, artist: "Heat", title: "Map", at: second)
        try await self.importedPlay(db, artist: "Someone Else", title: "Morning Song", at: other)

        var expected: [String: Int] = [:]
        for stamp in [first, second, other] {
            let cell = self.bucket(stamp)
            expected["\(cell.weekday)-\(cell.hour)", default: 0] += 1
        }

        let report = try await LibraryStatsRepository(database: db).fetchListeningTime()
        #expect(report.totalPlays == 3)
        var actual: [String: Int] = [:]
        for cell in report.heatmap {
            actual["\(cell.weekday)-\(cell.hour)"] = cell.count
        }
        #expect(actual == expected)
    }

    @Test("Discovery counts each artist once, merged across sources and casing")
    func discoveryFirstSeen() async throws {
        let db = try await makeDB()
        let track = try await self.seedTrack(db, artistName: "Wade Bowen", title: "Turpentine")
        let debut = try self.epoch(2020, 3, 15)
        let replay = try self.epoch(2022, 6, 15)
        let newcomer = try self.epoch(2021, 9, 15)
        try await self.localPlay(db, trackID: track, at: debut)
        try await self.importedPlay(db, artist: "wade bowen", title: "Turpentine", at: replay)
        try await self.importedPlay(db, artist: "Kaylee Rose", title: "Shovel", at: newcomer)

        let report = try await LibraryStatsRepository(database: db).fetchListeningTime()
        let first = self.yearMonth(debut)
        let second = self.yearMonth(newcomer)
        #expect(report.discoveryByMonth.count == 2, "the later lowercase scrobble is not a new artist")
        #expect(report.discoveryByMonth.first?.year == first.year)
        #expect(report.discoveryByMonth.first?.month == first.month)
        #expect(report.discoveryByMonth.first?.newArtists == 1)
        #expect(report.discoveryByMonth.last?.year == second.year)
        #expect(report.discoveryByMonth.last?.month == second.month)
    }

    @Test("Seasonal artists need a recurring one-month skew, not a binge")
    func seasonalSkew() async throws {
        let db = try await makeDB()
        // Eight December plays across two years plus four in June: seasonal.
        for day in 1 ... 4 {
            try await self.importedPlay(db, artist: "Sleigher", title: "Bells", at: self.epoch(2020, 12, day + 10))
            try await self.importedPlay(db, artist: "Sleigher", title: "Bells", at: self.epoch(2021, 12, day + 10))
        }
        for day in 1 ... 4 {
            try await self.importedPlay(db, artist: "Sleigher", title: "Bells", at: self.epoch(2021, 6, day + 10))
        }
        // Twelve December plays in a single year: a binge, not a season.
        for day in 1 ... 12 {
            try await self.importedPlay(db, artist: "One Winter", title: "Once", at: self.epoch(2020, 12, day + 10))
        }
        // Recurring but too few plays overall.
        for year in [2020, 2021] {
            for day in 1 ... 3 {
                try await self.importedPlay(db, artist: "Quiet", title: "Rarely", at: self.epoch(year, 12, day + 10))
            }
        }

        let report = try await LibraryStatsRepository(database: db).fetchListeningTime()
        #expect(report.seasonalArtists.count == 1)
        let seasonal = try #require(report.seasonalArtists.first)
        #expect(seasonal.name == "Sleigher")
        #expect(seasonal.peakMonth == 12)
        #expect(seasonal.peakMonthPlays == 8)
        #expect(seasonal.totalPlays == 12)
        #expect(abs(seasonal.share - 8.0 / 12.0) < 0.0001)
    }

    @Test("An empty history yields an empty report")
    func emptyHistory() async throws {
        let db = try await makeDB()
        let report = try await LibraryStatsRepository(database: db).fetchListeningTime()
        #expect(report.totalPlays == 0)
        #expect(report.heatmap.isEmpty)
        #expect(report.discoveryByMonth.isEmpty)
        #expect(report.seasonalArtists.isEmpty)
    }
}
