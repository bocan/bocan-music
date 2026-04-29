import Foundation
import GRDB
import Observability

/// Copies the live SQLite database to an iCloud Drive location for backup.
///
/// Uses the SQLite backup API (via GRDB) so the copy is always consistent,
/// even if a write is in progress.  The backup is gated behind the
/// `"backup.enabled"` setting key and is off by default.
///
/// **WAL note:** the backup API produces a single self-contained file, unlike
/// a naive file copy that would require all three WAL files (`-wal`, `-shm`, `.sqlite`).
public struct BackupService: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a backup service for `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Public

    /// Backs up the database to `destinationURL`.
    ///
    /// Creates parent directories as needed.
    /// Throws `PersistenceError.backupFailed` if the copy fails.
    public func backup(to destinationURL: URL) async throws {
        self.log.debug("backup.start", ["destination": destinationURL.path])
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            // Use SQLite's online backup API via GRDB's writer-to-writer
            // overload.  The previous implementation tried to extract the
            // raw `GRDB.Database` from a queue's `read` closure — that
            // closure releases the connection back to the pool on return,
            // so by the time `sourceDB.backup(to:)` ran the destination
            // handle had become invalid (Phase 2 audit #6).
            let destQueue = try DatabaseQueue(path: destinationURL.path)
            try await self.database.backup(to: destQueue)
            self.log.debug("backup.end", ["destination": destinationURL.path])
        } catch let error as PersistenceError {
            throw error
        } catch {
            self.log.error("backup.failed", ["error": String(reflecting: error)])
            throw PersistenceError.backupFailed(underlying: error)
        }
    }

    /// Returns the iCloud Drive backup directory URL if available, otherwise `nil`.
    ///
    /// Logs a `.notice` if iCloud Drive is not configured rather than throwing.
    public func iCloudBackupDirectory() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: nil
        ) else {
            self.log.notice("backup.icloud_unavailable")
            return nil
        }
        return container
            .appendingPathComponent("Documents/Bocan", isDirectory: true)
    }

    /// Backs up to iCloud Drive if available.
    ///
    /// The file is named `library-<ISO8601 timestamp>.sqlite`.
    /// Returns `true` if the backup was performed, `false` if iCloud is unavailable.
    @discardableResult
    public func backupToiCloudIfAvailable() async throws -> Bool {
        guard let dir = iCloudBackupDirectory() else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("library-\(timestamp).sqlite")
        try await self.backup(to: dest)
        return true
    }
}
