import Foundation
@testable import Library
@testable import Persistence

/// Fixture builders shared by the `PlaylistService` suites. A suite conforms
/// to get them as `self.makeDatabase()`, `self.makeTrack(in:fileURL:)` and
/// `self.tracks(_:in:)`.
protocol PlaylistServiceFixtures {}

extension PlaylistServiceFixtures {
    func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    func makeTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track"
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        let repo = TrackRepository(database: db)
        return try await repo.insert(track)
    }

    func tracks(_ count: Int, in db: Persistence.Database) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0 ..< count {
            let id = try await self.makeTrack(in: db, fileURL: "file:///tmp/t\(i).mp3", title: "T\(i)")
            ids.append(id)
        }
        return ids
    }
}
