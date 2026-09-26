import Foundation
import Testing
@testable import Observability

@Suite("CacheDirectoryMarker")
struct CacheDirectoryMarkerTests {
    /// A fresh folder under the temporary directory, never a real cache.
    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheDirectoryMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func tagText(in folder: URL) throws -> String {
        let data = try Data(contentsOf: folder.appendingPathComponent(CacheDirectoryMarker.tagFileName))
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the flag from a new URL, so no cached resource value answers.
    private static func isExcluded(_ folder: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: folder.path, isDirectory: true)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    @Test("the tag begins with the exact signature line and a newline")
    func writesTheSignature() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        CacheDirectoryMarker.mark(folder, excludeFromBackup: false)

        let text = try Self.tagText(in: folder)
        #expect(text.hasPrefix("Signature: 8a477f597d28d172789f06886806bc55\n"))
    }

    @Test("a second call leaves an existing tag alone")
    func doesNotRewriteTheTag() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        CacheDirectoryMarker.mark(folder, excludeFromBackup: false)
        let tag = folder.appendingPathComponent(CacheDirectoryMarker.tagFileName)
        let sentinel = CacheDirectoryMarker.signatureLine + "\n# sentinel\n"
        try Data(sentinel.utf8).write(to: tag)

        CacheDirectoryMarker.mark(folder, excludeFromBackup: false)

        #expect(try Self.tagText(in: folder) == sentinel)
    }

    @Test("the backup exclusion is set when asked for")
    func excludesFromBackup() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        CacheDirectoryMarker.mark(folder, excludeFromBackup: true)

        #expect(try Self.isExcluded(folder))
    }

    @Test("the backup exclusion is left alone when not asked for")
    func leavesBackupFlagAlone() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        CacheDirectoryMarker.mark(folder, excludeFromBackup: false)

        #expect(try Self.isExcluded(folder) == false)
    }

    @Test("a folder that does not exist is not created")
    func missingFolderIsNotCreated() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheDirectoryMarkerTests-missing-\(UUID().uuidString)", isDirectory: true)

        CacheDirectoryMarker.mark(folder, excludeFromBackup: true)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
