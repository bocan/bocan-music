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

    // MARK: - Typed fetch helpers

    /// Reads the record of type `Record` with primary key `id`, throwing
    /// `PersistenceError.notFound(entity:id:)` when no row matches.
    ///
    /// Folds the "fetch by primary key or throw not-found" body that otherwise
    /// recurs verbatim across the typed repositories' `fetch(id:)` methods.
    func fetchOne<Record: FetchableRecord & TableRecord & Sendable>(
        _: Record.Type,
        id: Int64,
        entity: String
    ) async throws -> Record {
        try await self.read { db in
            guard let record = try Record.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: entity, id: id)
            }
            return record
        }
    }

    // MARK: - Observation

    /// Returns a stream that emits the current value immediately and again on every change.
    ///
    /// The stream completes only if an error occurs or the consuming `Task` is cancelled.
    /// Uses `.mainActor` scheduling so GRDB uses `ValueMainObserver` instead of
    /// `ValueConcurrentObserver`. The latter takes a WAL snapshot via
    /// `WALSnapshotTransaction.commitAndRelease → reentrantSync → dispatch_sync`, which
    /// deadlocks due to a bug in GRDB 7.9.0+ (nested reentrant detection fails).
    ///
    /// The fix: set `requiresWriteAccess = true` so `DatabasePool._add` routes to
    /// `_addWriteOnly → ValueWriteOnlyObserver` instead of `_addConcurrent → ValueConcurrentObserver`.
    /// `ValueWriteOnlyObserver` fetches on the writer connection directly — no WAL snapshot,
    /// no deadlock. Reads and writes are serialized on the writer queue, which is acceptable
    /// because observations are infrequent and the app uses actor-isolated access anyway.
    public func observe<T: Sendable>(
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        var observation = ValueObservation.tracking(value)
        observation.requiresWriteAccess = true // use ValueWriteOnlyObserver, avoid WAL snapshot deadlock
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: .main),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Returns a stream that emits values whenever `regions` are modified.
    ///
    /// Use this overload when the observed region is known up front and should
    /// not be inferred from the fetch closure.
    /// Uses `requiresWriteAccess = true` — see `observe(value:)` for the full rationale.
    public func observe<T: Sendable>(
        regions: [any DatabaseRegionConvertible],
        value: @escaping @Sendable (GRDB.Database) throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        var observation = ValueObservation.tracking(regions: regions, fetch: value)
        observation.requiresWriteAccess = true // use ValueWriteOnlyObserver, avoid WAL snapshot deadlock
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: .main),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: - Internal observation bridge

    /// Starts a GRDB observation and returns a cancellable.
    /// Used by `AsyncObservation` to bridge from outside the actor.
    ///
    /// Uses `requiresWriteAccess = true` to route through `ValueWriteOnlyObserver`,
    /// avoiding the `ValueConcurrentObserver` WAL snapshot deadlock — see `observe(value:)`.
    func startObservation<T: Sendable>(
        observation: ValueObservation<ValueReducers.Fetch<T>>,
        continuation: AsyncThrowingStream<T, Error>.Continuation
    ) -> AnyDatabaseCancellable {
        var obs = observation
        obs.requiresWriteAccess = true // use ValueWriteOnlyObserver, avoid WAL snapshot deadlock
        return obs.start(
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
        try self.writer.backup(to: destination)
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
        let log = AppLogger.make(.persistence)
        try await writer.write { db in
            do {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            } catch {
                // WAL is unavailable on read-only or network-mounted volumes.
                // Log a warning so degraded mode is visible; the app continues in DELETE journaling.
                log.warning("db.wal.unavailable", ["error": String(reflecting: error)])
            }
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 400")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        var migrator = Migrator.make()
        try migrator.migrate(writer)
    }
}
