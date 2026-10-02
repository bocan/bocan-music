import Foundation
import Persistence
@testable import Library

/// Fixture builders shared by the `MetadataEditService` suites. A suite
/// conforms to get them as `makeDatabase()`, `insertTrack(in:fileURL:)` and
/// `tempMP3()`.
protocol MetadataEditServiceFixtures {}

extension MetadataEditServiceFixtures {
    func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    /// Inserts a bare track and returns its row ID.
    func insertTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track"
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: fileURL,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        return try await TrackRepository(database: db).insert(track)
    }

    /// Fixture MP3 (from sample-library) copied to a temp file; caller owns cleanup.
    func tempMP3() throws -> URL {
        guard let libraryURL = Bundle.module.url(
            forResource: "sample-library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.notFound("sample-library")
        }
        // Find the first non-corrupt MP3
        let enumerator = FileManager.default.enumerator(at: libraryURL, includingPropertiesForKeys: nil)
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.pathExtension == "mp3",
                  !candidate.lastPathComponent.lowercased().contains("corrupt") else { continue }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mp3")
            try FileManager.default.copyItem(at: candidate, to: tmp)
            return tmp
        }
        throw FixtureError.notFound("mp3 in sample-library")
    }
}

enum FixtureError: Error {
    case notFound(String)
}
