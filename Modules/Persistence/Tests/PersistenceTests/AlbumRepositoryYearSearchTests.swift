import Foundation
import Testing
@testable import Persistence

/// Year and date matching in `AlbumRepository.search` (#378): a four-digit
/// query matches `albums.year` and track `year_text` prefixes; a date-shaped
/// query narrows via `year_text` alone.
@Suite("Album Repository Year Search Tests")
struct AlbumRepositoryYearSearchTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(
        title: String,
        albumID: Int64,
        yearText: String,
        disabled: Bool = false
    ) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 200,
            title: title,
            albumID: albumID,
            yearText: yearText,
            addedAt: now,
            updatedAt: now
        )
        track.disabled = disabled
        return track
    }

    @Test("search matches albums by exact release year")
    func searchMatchesByYear() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Older Album", year: 1984))
        _ = try await repo.insert(Album(title: "Newer Album", year: 1985))
        let hits = try await repo.search(query: "1984")
        #expect(hits.map(\.title) == ["Older Album"])
    }

    @Test("search does not year-match digit runs shorter than four")
    func searchYearRequiresFourDigits() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Quiet Album", year: 1984))
        #expect(try await repo.search(query: "198").isEmpty)
        #expect(try await repo.search(query: "19").isEmpty)
    }

    @Test("date-shaped query narrows by tracks' raw date tag, not the whole year")
    func searchDateQueryMatchesYearText() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let juneID = try await albumRepo.insert(Album(title: "June Album", year: 2004))
        let novemberID = try await albumRepo.insert(Album(title: "November Album", year: 2004))
        _ = try await trackRepo.insert(
            self.makeTrack(title: "Summer Song", albumID: juneID, yearText: "2004-06-15")
        )
        _ = try await trackRepo.insert(
            self.makeTrack(title: "Autumn Song", albumID: novemberID, yearText: "2004-11-01")
        )

        let monthHits = try await albumRepo.search(query: "2004-06")
        #expect(monthHits.map(\.title) == ["June Album"])

        // A bare year still matches both, via the integer column.
        let yearHits = try await albumRepo.search(query: "2004")
        #expect(Set(yearHits.map(\.title)) == ["June Album", "November Album"])
    }

    @Test("year search falls back to tracks' date tag when the album year is unset")
    func searchYearTextCoversMissingYearInt() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Undated Album"))
        _ = try await trackRepo.insert(
            self.makeTrack(title: "Spring Song", albumID: albumID, yearText: "1974-05")
        )
        #expect(try await albumRepo.search(query: "1974").map(\.title) == ["Undated Album"])
    }

    @Test("year search ignores disabled tracks' date tags")
    func searchYearTextIgnoresDisabledTracks() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Disabled Undated"))
        _ = try await trackRepo.insert(
            self.makeTrack(title: "Hidden Song", albumID: albumID, yearText: "1974-05", disabled: true)
        )
        #expect(try await albumRepo.search(query: "1974").isEmpty)
    }

    @Test("search dedupes an album matched by both title and year")
    func searchDedupesTitleAndYear() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let albumID = try await repo.insert(Album(title: "1984", year: 1984))
        let hits = try await repo.search(query: "1984")
        #expect(hits.count { $0.id == albumID } == 1)
    }
}
