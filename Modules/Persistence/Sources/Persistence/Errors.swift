import Foundation

/// Errors that the `Persistence` module can throw at public API boundaries.
public enum PersistenceError: Error, Sendable, CustomStringConvertible {
    /// A database migration failed.
    case migrationFailed(version: Int, underlying: Error)

    /// `PRAGMA integrity_check` returned a failure result.
    case integrityCheckFailed(details: String)

    /// A lookup by primary key found no row.
    case notFound(entity: String, id: Int64)

    /// An INSERT violated a UNIQUE constraint.
    case uniqueConstraintViolation(table: String, column: String)

    /// A write violated a FOREIGN KEY constraint.
    case foreignKeyViolation(details: String)

    /// A security-scoped bookmark could not be resolved to a file URL.
    case bookmarkResolutionFailed(reason: String)

    /// A backup copy operation failed.
    case backupFailed(underlying: Error)

    // MARK: - CustomStringConvertible

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case let .migrationFailed(version, underlying):
            "Migration \(version) failed: \(underlying)"

        case let .integrityCheckFailed(details):
            "Integrity check failed: \(details)"

        case let .notFound(entity, id):
            "\(entity) with id \(id) not found"

        case let .uniqueConstraintViolation(table, column):
            "Unique constraint violation in \(table).\(column)"

        case let .foreignKeyViolation(details):
            "Foreign key violation: \(details)"

        case let .bookmarkResolutionFailed(reason):
            "Bookmark resolution failed: \(reason)"

        case let .backupFailed(underlying):
            "Backup failed: \(underlying)"
        }
    }
}
