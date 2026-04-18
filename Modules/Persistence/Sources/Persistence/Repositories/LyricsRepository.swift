import GRDB
import Observability

/// Read/write access to the `lyrics` table.
public struct LyricsRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts or replaces lyrics for `trackID`.
    public func save(_ lyrics: Lyrics) async throws {
        try await self.database.write { db in
            try lyrics.save(db)
        }
        self.log.debug("lyrics.save", ["track": lyrics.trackID])
    }

    /// Deletes lyrics for `trackID`.
    public func delete(trackID: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM lyrics WHERE track_id = ?",
                arguments: [trackID]
            )
        }
        self.log.debug("lyrics.delete", ["track": trackID])
    }

    // MARK: - Read

    /// Fetches the lyrics for `trackID`, or `nil` if none are stored.
    public func fetch(trackID: Int64) async throws -> Lyrics? {
        try await self.database.read { db in
            try Lyrics.fetchOne(db, key: trackID)
        }
    }
}
