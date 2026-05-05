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

    /// Returns a stream that emits values whenever `regions` are modified.
    ///
    /// Use this overload when the observed region is known up front and should
    /// not be inferred from the fetch closure.
    public func observe<T: Sendable>(
        regions: [any DatabaseRegionConvertible],
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        let observation = ValueObservation.tracking(regions: regions, fetch: value)
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

    /// Threshold below which `vacuum()` is a no-op.
    ///
    /// Reclaiming a few KB of free pages on every quit just churns disk and
    /// CloudKit-backed iCloud Drive backups; we only run it once the freelist
    /// has grown past 1 MB of unused space.
    private static let vacuumFreelistThresholdBytes: Int64 = 1 * 1024 * 1024

    /// Runs `PRAGMA incremental_vacuum` to reclaim free pages, but only when
    /// the freelist has grown past `vacuumFreelistThresholdBytes`.  Returns
    /// `true` if vacuuming actually ran.
    @discardableResult
    public func vacuum() async throws -> Bool {
        self.log.debug("vacuum.start")
        let didRun: Bool = try await self.writer.write { db in
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let freelist = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let freeBytes = pageSize * freelist
            guard freeBytes >= Self.vacuumFreelistThresholdBytes else { return false }
            try db.execute(sql: "PRAGMA incremental_vacuum")
            return true
        }
        self.log.debug("vacuum.end", ["ran": didRun])
        return didRun
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

    /// Returns the number of applied migrations.
    ///
    /// Reads from GRDB's bookkeeping table (`grdb_migrations`) rather than
    /// the SQLite `user_version` pragma — `user_version` is reserved for
    /// application use and should not be commandeered by infrastructure.
    public func schemaVersion() async throws -> Int {
        try await self.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
    }

    /// Backs up the live database into `destination` using SQLite's online
    /// backup API.  Writes are temporarily blocked while the snapshot copies,
    /// but the destination is a complete, self-contained file even when the
    /// source is in WAL mode.
    func backup(to destination: any DatabaseWriter) async throws {
        try await self.writer.backup(to: destination)
    }

    // MARK: - Private helpers

    private static func makeWriter(location: Location) throws -> any DatabaseWriter {
        var config = Configuration()
        // Give GRDB's internal writer/reader queues .userInitiated QoS so that
        // @MainActor and other high-priority callers don't trigger the OS
        // thread-performance priority-inversion warning (GRDB Pool.swift:97).
        // GRDB propagates `targetQueue` through its entire queue hierarchy.
        config.targetQueue = DispatchQueue(
            label: "io.cloudcauldron.bocan.db",
            qos: .userInitiated
        )
        config.prepareDatabase { db in
            try Self.applyConnectionPragmas(in: db)
            Self.registerREGEXP(in: db)
        }
        guard let url = location.url else {
            // In-memory queues used by tests must apply the same per-connection
            // pragmas as the on-disk pool — otherwise FK enforcement, the
            // 5s busy timeout, and recursive triggers all silently differ
            // between production and tests.
            return try DatabaseQueue(configuration: config)
        }
        return try DatabasePool(path: url.path, configuration: config)
    }

    /// Per-connection PRAGMAs applied via `Configuration.prepareDatabase`.
    ///
    /// `foreign_keys` is per-connection in SQLite, so this must run on every
    /// database handle (every reader and writer in a `DatabasePool`, plus
    /// the single connection in a `DatabaseQueue`).
    private static func applyConnectionPragmas(in db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: "PRAGMA busy_timeout = 5000")
        try db.execute(sql: "PRAGMA recursive_triggers = ON")
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
        // WAL mode for on-disk pools (no-op for in-memory queues).
        // wal_autocheckpoint: checkpoint after 400 pages (~1.6 MB) instead of the
        // SQLite default of 1,000. This prevents the WAL growing large enough that
        // ValueObservation delivers a stale (pre-WAL-replay) snapshot on the next
        // app launch, which surfaced as an empty library list despite rows being present.
        try await writer.write { db in
            _ = try? db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 400")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        var migrator = Migrator.make()
        try migrator.migrate(writer)
    }
}
