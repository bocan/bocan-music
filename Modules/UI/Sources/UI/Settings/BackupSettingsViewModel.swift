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

    /// Timestamp of the most recent successful iCloud backup, or `nil` if never run.
    public var lastBackupDate: Date?

    /// `true` while a manual iCloud "Back Up Now" backup is in progress.
    public var isBackingUp = false

    /// `true` when iCloud Drive is accessible on this Mac.
    public var iCloudAvailable = false

    /// Non-nil when the most recent manual iCloud backup attempt failed.
    public var errorMessage: String?

    // MARK: - Local backup state

    /// Whether automatic launch-time local backups are enabled. Defaults to `true`.
    public var isLocalEnabled = true {
        didSet { self.persistLocalEnabled() }
    }

    /// Number of local backup files to retain (1–20).
    public var localKeepCount = 5 {
        didSet { self.persistLocalKeepCount() }
    }

    /// Timestamp of the most recent successful local backup, or `nil` if never run.
    public var lastLocalBackupDate: Date?

    /// `true` while a manual local "Back Up Now" is in progress.
    public var isLocalBackingUp = false

    /// Non-nil when the most recent manual local backup attempt failed.
    public var localErrorMessage: String?

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
            self.isLocalEnabled = try await (settings.get(Bool.self, for: "backup.local.enabled")) ?? true
            self.localKeepCount = try await (settings.get(Int.self, for: "backup.local.keepCount")) ?? 5
            if let ts = try await settings.get(Double.self, for: "backup.local.lastDate") {
                self.lastLocalBackupDate = Date(timeIntervalSince1970: ts)
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

    /// Triggers an immediate local backup regardless of the `isLocalEnabled` toggle.
    public func backupLocalNow() async {
        guard !self.isLocalBackingUp else { return }
        self.isLocalBackingUp = true
        self.localErrorMessage = nil
        do {
            _ = try await BackupService(database: self.database).backupToLocal(keepLast: self.localKeepCount)
            let settings = SettingsRepository(database: self.database)
            if let ts = try await settings.get(Double.self, for: "backup.local.lastDate") {
                self.lastLocalBackupDate = Date(timeIntervalSince1970: ts)
            }
        } catch {
            self.localErrorMessage = error.localizedDescription
            self.log.error("backup.local.manual_failed", ["error": String(reflecting: error)])
        }
        self.isLocalBackingUp = false
    }

    // MARK: - Computed helpers

    /// Human-readable description of the last iCloud backup time.
    public var lastBackupDescription: String {
        guard let date = self.lastBackupDate else { return L10n.string("Never") }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// Human-readable description of the last local backup time.
    public var lastLocalBackupDescription: String {
        guard let date = self.lastLocalBackupDate else { return L10n.string("Never") }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// URL of the local backup folder (for revealing in Finder).
    public var localBackupDirectory: URL {
        BackupService(database: self.database).localBackupDirectory()
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

    private func persistLocalEnabled() {
        let enabled = self.isLocalEnabled
        Task { [weak self] in
            guard let self else { return }
            do {
                try await SettingsRepository(database: self.database).set(enabled, for: "backup.local.enabled")
            } catch {
                self.log.error("backup.setLocalEnabled.failed", ["error": String(reflecting: error)])
            }
        }
    }

    private func persistLocalKeepCount() {
        let count = self.localKeepCount
        Task { [weak self] in
            guard let self else { return }
            do {
                try await SettingsRepository(database: self.database).set(count, for: "backup.local.keepCount")
            } catch {
                self.log.error("backup.setLocalKeepCount.failed", ["error": String(reflecting: error)])
            }
        }
    }
}
