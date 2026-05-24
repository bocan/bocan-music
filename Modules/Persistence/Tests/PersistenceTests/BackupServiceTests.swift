import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("BackupService", .serialized)
struct BackupServiceTests {
    @Test("backup writes a readable SQLite file to the destination URL")
    func backupCopiesFile() async throws {
        let db = try await Database(location: .inMemory)
        let service = BackupService(database: db)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bocan-backup-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dest = tmpDir.appendingPathComponent("snapshot.sqlite")

        try await service.backup(to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        // Verify it's a real, openable SQLite database.
        let opened = try DatabaseQueue(path: dest.path)
        let count = try await opened.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
        }
        #expect(count > 0)
    }

    @Test("localBackupDirectory points inside Application Support")
    func localDirectoryPath() async throws {
        let db = try await Database(location: .inMemory)
        let service = BackupService(database: db)
        let dir = service.localBackupDirectory()
        #expect(dir.path.contains("Bocan/Backups"))
    }

    @Test("backupToLocal writes a timestamped file and updates the settings row")
    func backupToLocalCreatesFile() async throws {
        let db = try await Database(location: .inMemory)
        let service = BackupService(database: db)

        let ok = try await service.backupToLocal(keepLast: 5)
        #expect(ok)

        let recorded = try await SettingsRepository(database: db)
            .get(TimeInterval.self, for: "backup.local.lastDate")
        #expect(recorded != nil)
    }

    @Test("backup fails cleanly when destination directory is unwritable")
    func backupFails() async throws {
        let db = try await Database(location: .inMemory)
        let service = BackupService(database: db)
        // A path under /System on macOS is non-writable for normal users.
        let dest = URL(fileURLWithPath: "/System/forbidden-\(UUID().uuidString)/snapshot.sqlite")
        await #expect(throws: (any Error).self) {
            try await service.backup(to: dest)
        }
    }
}
