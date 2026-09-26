import Foundation
import Observability
import Persistence
import Testing
@testable import Podcasts

/// The podcast artwork folder is marked for backup tools (#569): a
/// `CACHEDIR.TAG` and the Time Machine exclusion. Downloads are not.
@Suite("PodcastArtworkCache folder marking")
struct PodcastArtworkCacheMarkingTests {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-mark-\(UUID().uuidString)", isDirectory: true)
    }

    private static func isMarked(_ folder: URL) throws -> Bool {
        let tag = folder.appendingPathComponent(CacheDirectoryMarker.tagFileName)
        let fresh = URL(fileURLWithPath: folder.path, isDirectory: true)
        let excluded = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        return FileManager.default.fileExists(atPath: tag.path) && excluded
    }

    @Test("a folder left by an older version is marked when the cache is built")
    func marksExistingFolderAtInit() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = PodcastArtworkCache(http: MockHTTPClient(), root: root)

        #expect(try Self.isMarked(root))
    }

    @Test("the first artwork write creates the folder and marks it")
    func marksNewFolderOnWrite() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = MockHTTPClient()
        http.handler = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data([0xFF, 0xD8, 0xFF, 0xE0]), response)
        }
        let cache = PodcastArtworkCache(http: http, root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path), "building the cache must not create the folder")
        let db = try await Database(location: .inMemory)

        let path = try await cache.cachePodcastArt(
            podcastID: 1,
            url: #require(URL(string: "https://example.com/show.jpg")),
            repo: PodcastRepository(database: db)
        )

        #expect(path != nil)
        #expect(try Self.isMarked(root))
    }
}
