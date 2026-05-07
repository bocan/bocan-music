import Foundation
import Observability
import Persistence

// MARK: - BackupSettingsViewModel

/// Drives the iCloud Backup section of Advanced Settings.
///
/// Loads and persists `backup.enabled` + `backup.lastDate` from the GRDB
/// `settings` table (not `UserDefaults`), because `BackupService` also reads
/// from the same table.  The `isEnabled` property is kept in sync eagerly so
/// the toggle feels instant; the async DB write happens concurrently.
@MainActor
@Observable
public final class BackupSettingsViewModel {
    // MARK: - Published state

    /// Whether automatic launch-time backups are enabled.
    public var isEnabled = false {
        didSet { self.persistEnabled() }
    }

    /// Timestamp of the most recent successful backup, or `nil` if never run.
    public var lastBackupDate: Date?

    /// `true` while a manual "Back Up Now" backup is in progress.
    public var isBackingUp = false

    /// `true` when iCloud Drive is accessible on this Mac.
    public var iCloudAvailable = false

    /// Non-nil when the most recent manual backup attempt failed.
    public var errorMessage: String?

    // MARK: - Private

    private let database: Database
    private let log = AppLogger.make(.app)

    // MARK: - Init

    /// Creates a view model backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Load

    /// Loads settings from the database.  Call from `.task {}` on the view.
    public func load() async {
        self.iCloudAvailable = BackupService(database: self.database).iCloudBackupDirectory() != nil
        let settings = SettingsRepository(database: self.database)
        do {
            self.isEnabled = try await (settings.get(Bool.self, for: "backup.enabled")) ?? false
            if let ts = try await settings.get(Double.self, for: "backup.lastDate") {
                self.lastBackupDate = Date(timeIntervalSince1970: ts)
            }
        } catch {
            self.log.error("backup.load.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Manual backup

    /// Triggers an immediate backup regardless of the `isEnabled` toggle.
    public func backupNow() async {
        guard !self.isBackingUp else { return }
        self.isBackingUp = true
        self.errorMessage = nil
        do {
            _ = try await BackupService(database: self.database).backupToiCloudIfAvailable()
            // Refresh the displayed date from the value that BackupService just wrote.
            let settings = SettingsRepository(database: self.database)
            if let ts = try await settings.get(Double.self, for: "backup.lastDate") {
                self.lastBackupDate = Date(timeIntervalSince1970: ts)
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.log.error("backup.manual_failed", ["error": String(reflecting: error)])
        }
        self.isBackingUp = false
    }

    // MARK: - Computed helpers

    /// Human-readable description of the last backup time.
    public var lastBackupDescription: String {
        guard let date = self.lastBackupDate else { return "Never" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Private

    private func persistEnabled() {
        let enabled = self.isEnabled
        Task { [weak self] in
            guard let self else { return }
            do {
                try await SettingsRepository(database: self.database).set(enabled, for: "backup.enabled")
            } catch {
                self.log.error("backup.setEnabled.failed", ["error": String(reflecting: error)])
            }
        }
    }
}
