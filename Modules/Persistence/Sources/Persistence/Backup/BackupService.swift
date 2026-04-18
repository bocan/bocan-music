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
            try await self.database.write { sourceDB in
                let destQueue = try DatabaseQueue(path: destinationURL.path)
                try sourceDB.backup(to: destQueue.internalDatabase)
            }
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

// MARK: - GRDB internal database access

private extension DatabaseQueue {
    /// Exposes the raw GRDB.Database for use with the backup API.
    var internalDatabase: GRDB.Database {
        get throws {
            try self.read { $0 }
        }
    }
}
