import Foundation
import GRDB
import Observability

/// Thread-safe, actor-isolated gateway to the SQLite database.
///
/// Wraps a `DatabasePool` (on-disk) or `DatabaseQueue` (in-memory) and runs
/// all migrations on first open.  Pass a `DatabaseLocation` to control where
/// the file lives; use `.inMemory` in tests.
///
/// ```swift
/// let db = try await Database(location: .application)
/// let tracks = try await db.read { db in try Track.fetchAll(db) }
/// ```
public actor Database {
    // MARK: - Types

    /// Where the SQLite file lives.
    public typealias Location = DatabaseLocation

    // MARK: - Properties

    private let writer: any DatabaseWriter
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Opens (or creates) the database at `location` and applies all pending migrations.
    public init(location: Location = .application) async throws {
        let writer = try Self.makeWriter(location: location)
        self.writer = writer
        try await Self.configure(writer: writer)
    }

    // MARK: - Public read / write

    /// Runs `work` on a read-only database connection and returns the result.
    public func read<T: Sendable>(_ work: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await self.writer.read(work)
    }

    /// Runs `work` on a write database connection, commits, and returns the result.
    public func write<T: Sendable>(_ work: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await self.writer.write(work)
    }

    // MARK: - Observation

    /// Returns a stream that emits the current value immediately and again on every change.
    ///
    /// The stream completes only if an error occurs or the consuming `Task` is cancelled.
    /// Task cancellation propagates into GRDB's async sequence.
    public func observe<T: Sendable>(
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        let observation = ValueObservation.tracking(value)
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: writer) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internal observation bridge

    /// Starts a GRDB observation and returns a cancellable.
    /// Used by `AsyncObservation` to bridge from outside the actor.
    ///
    /// Passes an explicit `.async(onQueue: .main)` scheduler so we use
    /// the non-MainActor-isolated overload of `start(in:scheduling:…)`.
    /// The default scheduler is `.mainActor` which requires the caller
    /// be on `@MainActor`; we call this from the `Database` actor.
    func startObservation<T: Sendable>(
        observation: ValueObservation<ValueReducers.Fetch<T>>,
        continuation: AsyncThrowingStream<T, Error>.Continuation
    ) -> AnyDatabaseCancellable {
        observation.start(
            in: self.writer,
            scheduling: .async(onQueue: .main),
            onError: { continuation.finish(throwing: $0) },
            onChange: { continuation.yield($0) }
        )
    }

    // MARK: - Maintenance

    /// Runs `PRAGMA incremental_vacuum` to reclaim free pages.
    public func vacuum() async throws {
        self.log.debug("vacuum.start")
        try await self.writer.write { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
        self.log.debug("vacuum.end")
    }

    /// Runs `PRAGMA integrity_check` and throws if the result is not `ok`.
    public func integrityCheck() async throws {
        self.log.debug("integrity_check.start")
        let result: String = try await self.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA integrity_check")
            return rows.first?["integrity_check"] ?? "error"
        }
        guard result == "ok" else {
            throw PersistenceError.integrityCheckFailed(details: result)
        }
        self.log.debug("integrity_check.end", ["result": result])
    }

    /// Returns the number of the highest applied migration.
    public func schemaVersion() async throws -> Int {
        try await self.writer.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            return version ?? 0
        }
    }

    // MARK: - Private helpers

    private static func makeWriter(location: Location) throws -> any DatabaseWriter {
        guard let url = location.url else {
            let queue = try DatabaseQueue()
            try Self.registerCustomFunctions(in: queue)
            return queue
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA recursive_triggers = ON")
            Self.registerREGEXP(in: db)
        }
        return try DatabasePool(path: url.path, configuration: config)
    }

    /// Registers the `REGEXP` function for in-memory `DatabaseQueue` instances (tests).
    private static func registerCustomFunctions(in queue: DatabaseQueue) throws {
        try queue.write { db in Self.registerREGEXP(in: db) }
    }

    /// Registers the `REGEXP(pattern, value)` SQLite function.
    ///
    /// Uses `NSRegularExpression` with unanchored, case-insensitive matching.
    /// The compiled expression is cached per connection.
    private static func registerREGEXP(in db: GRDB.Database) {
        let function = DatabaseFunction("REGEXP", argumentCount: 2, pure: true) { dbValues in
            guard
                let pattern = String.fromDatabaseValue(dbValues[0]),
                let value = String.fromDatabaseValue(dbValues[1]) else { return false }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, range: range) != nil
        }
        db.add(function: function)
    }

    private static func configure(writer: any DatabaseWriter) async throws {
        // WAL mode for on-disk pools (no-op for in-memory queues)
        try await writer.write { db in
            _ = try? db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        var migrator = Migrator.make()
        try migrator.migrate(writer)
        // Stamp user_version with the migration count so schemaVersion() is readable.
        let count = migrator.migrations.count
        try await writer.write { db in
            try db.execute(sql: "PRAGMA user_version = \(count)")
        }
    }
}
