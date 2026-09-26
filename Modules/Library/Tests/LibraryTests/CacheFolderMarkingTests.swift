import Foundation
import Observability
import Testing
@testable import Library

/// The Library-owned cache folders are marked for backup tools (#569): a
/// `CACHEDIR.TAG` and the Time Machine exclusion. Every test uses a temporary
/// root, never the real folders.
@Suite("Library cache folder marking")
struct CacheFolderMarkingTests {
    private static func tempRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func isMarked(_ folder: URL) throws -> Bool {
        let tag = folder.appendingPathComponent(CacheDirectoryMarker.tagFileName)
        let fresh = URL(fileURLWithPath: folder.path, isDirectory: true)
        let excluded = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        return FileManager.default.fileExists(atPath: tag.path) && excluded
    }

    @Test("Deep Dive: a folder left by an older version is marked when the cache is built")
    func deepDiveMarksExistingFolderAtInit() throws {
        let root = Self.tempRoot("deepdive-mark")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = DeepDiveCache(root: root)

        #expect(try Self.isMarked(root))
    }

    @Test("Deep Dive: the first write creates the folder and marks it")
    func deepDiveMarksNewFolderOnStore() async throws {
        let root = Self.tempRoot("deepdive-mark")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DeepDiveCache(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path), "building the cache must not create the folder")

        await cache.store(["value"], key: "artist:1")

        #expect(try Self.isMarked(root))
    }

    @Test("Cover search: CoverArtCache is marked, and the thumbnails go in Fetch below it")
    func coverSearchMarksCoverArtCache() throws {
        let root = Self.tempRoot("coverartcache-mark")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = CoverArtSearchService(thumbnailCacheRoot: root)

        #expect(try Self.isMarked(root))
        let fetch = root.appendingPathComponent("Fetch", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: fetch.path))
        #expect(!FileManager.default.fileExists(
            atPath: fetch.appendingPathComponent(CacheDirectoryMarker.tagFileName).path
        ), "one tag, at CoverArtCache/")
    }
}
