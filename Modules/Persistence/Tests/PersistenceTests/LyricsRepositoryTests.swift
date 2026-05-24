import Foundation
import Testing
@testable import Persistence

@Suite("LyricsRepository")
struct LyricsRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        return try await TrackRepository(database: db).insert(
            Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 180,
                title: "T",
                addedAt: now,
                updatedAt: now
            )
        )
    }

    @Test("save then fetch round-trip")
    func saveAndFetch() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = LyricsRepository(database: db)
        try await repo.save(Lyrics(trackID: trackID, lyricsText: "[00:01.00]Hi", isSynced: true, source: "lrclib", offsetMS: 100))
        let fetched = try await repo.fetch(trackID: trackID)
        #expect(fetched?.lyricsText == "[00:01.00]Hi")
        #expect(fetched?.isSynced == true)
        #expect(fetched?.source == "lrclib")
        #expect(fetched?.offsetMS == 100)
    }

    @Test("save replaces existing row")
    func saveReplaces() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = LyricsRepository(database: db)
        try await repo.save(Lyrics(trackID: trackID, lyricsText: "v1"))
        try await repo.save(Lyrics(trackID: trackID, lyricsText: "v2"))
        #expect(try await repo.fetch(trackID: trackID)?.lyricsText == "v2")
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = LyricsRepository(database: db)
        try await repo.save(Lyrics(trackID: trackID, lyricsText: "x"))
        try await repo.delete(trackID: trackID)
        #expect(try await repo.fetch(trackID: trackID) == nil)
    }

    @Test("fetch returns nil for unknown trackID")
    func fetchMissing() async throws {
        let db = try await makeDB()
        let repo = LyricsRepository(database: db)
        #expect(try await repo.fetch(trackID: 9999) == nil)
    }
}
