import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

// MARK: - Helpers

private func makeDB() async throws -> Database {
    try await Database(location: .inMemory)
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cover-art-cache-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a distinct `ExtractedCoverArt` of `bytes` bytes. Distinct `fill`
/// values produce distinct SHA-256 hashes (and distinct cache files). The
/// payload is not a real image, so the cache stores it verbatim — which makes
/// the on-disk size exactly controllable.
private func art(fill: UInt8, bytes: Int) -> ExtractedCoverArt {
    let raw = RawCoverArt(data: Data(repeating: fill, count: bytes), mimeType: "image/jpeg", pictureType: 3)
    // swiftlint:disable:next force_unwrapping
    return CoverArtExtractor.extract(from: [raw]).first!
}

// MARK: - Tests

@Suite("CoverArtCache eviction")
struct CoverArtCacheEvictionTests {
    @Test("disk cache is swept back under its byte budget, LRU first (#268)")
    func sweepEnforcesByteBudget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        let artBytes = 100_000
        // Budget holds two 100 KB arts; the third pushes us to 300 KB and must
        // trigger an LRU sweep back down to <= 200 KB. sweepThresholdBytes = 1
        // makes the budget check run after every persist.
        let cache = CoverArtCache(
            cacheRoot: dir,
            repo: repo,
            totalBytesLimit: 250_000,
            sweepThresholdBytes: 1
        )

        // Persist three distinct arts oldest-first, with gaps so their file
        // modification times (the LRU key) are strictly ordered.
        let first = try #require(try await cache.persist([art(fill: 1, bytes: artBytes)]))
        try await Task.sleep(nanoseconds: 25_000_000)
        let second = try #require(try await cache.persist([art(fill: 2, bytes: artBytes)]))
        try await Task.sleep(nanoseconds: 25_000_000)
        let third = try #require(try await cache.persist([art(fill: 3, bytes: artBytes)]))

        let fm = FileManager.default
        // Oldest art evicted from disk and DB; the FK is ON DELETE SET NULL so
        // this is safe and self-heals on the next scan.
        #expect(!fm.fileExists(atPath: first.path), "least-recently-used art should be evicted")
        let firstRow = try await repo.fetch(hash: first.hash)
        #expect(firstRow == nil, "evicted working-art DB row should be removed")

        // The two most-recent arts survive.
        #expect(fm.fileExists(atPath: second.path))
        #expect(fm.fileExists(atPath: third.path))

        // And the cache as a whole is back under budget.
        let total = directorySize(dir)
        #expect(total <= 250_000, "on-disk cache should be back under the byte budget, was \(total)")
    }

    @Test("cache below the budget evicts nothing")
    func belowBudgetKeepsEverything() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        let cache = CoverArtCache(
            cacheRoot: dir,
            repo: repo,
            totalBytesLimit: 10_000_000,
            sweepThresholdBytes: 1
        )

        var paths: [String] = []
        for fill: UInt8 in 1 ... 4 {
            let result = try #require(try await cache.persist([art(fill: fill, bytes: 50000)]))
            paths.append(result.path)
        }

        let fm = FileManager.default
        for path in paths {
            #expect(fm.fileExists(atPath: path), "nothing should be evicted while under budget")
        }
    }
}

/// Sum of every regular file under `dir`, recursively.
private func directorySize(_ dir: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    ) else { return 0 }
    var total = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { continue }
        total += values.fileSize ?? 0
    }
    return total
}
