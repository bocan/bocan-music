import Foundation
@testable import Library
@testable import Persistence

/// Fixture builders shared by the `SmartPlaylistService` suites. A suite
/// conforms to get them as `makeDatabase()`, `self.makeService(db:)` and
/// `insertTrack(in:fileURL:...)`.
protocol SmartPlaylistServiceFixtures {}

extension SmartPlaylistServiceFixtures {
    func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    func makeService(db: Persistence.Database) -> SmartPlaylistService {
        SmartPlaylistService(database: db)
    }

    /// Inserts a bare track and returns its row ID.
    func insertTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track",
        rating: Int = 0,
        playCount: Int = 0,
        loved: Bool = false,
        genre: String? = nil
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        track.rating = rating
        track.playCount = playCount
        track.loved = loved
        track.genre = genre
        let repo = TrackRepository(database: db)
        return try await repo.insert(track)
    }
}
