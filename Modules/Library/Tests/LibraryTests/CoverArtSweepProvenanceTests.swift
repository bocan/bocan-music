import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

/// #570: the `CoverArt/` size sweep must not delete art that exists nowhere
/// else. A rescan re-extracts embedded and sidecar art from the audio files,
/// but it cannot rebuild:
/// - `musicbrainz`: Batch Cover Art downloads it and writes it only here.
/// - `user`: the metadata editor's no-file-write path (#472) stores the image
///   the user chose only here.
///
/// Each test ages one such file so it is the least recently used, links an
/// album to it, and then persists embedded art until a sweep must evict.
@Suite("CoverArtCache sweep and art a rescan cannot rebuild")
struct CoverArtSweepProvenanceTests {
    private static let artBytes = 100_000
    private static let longAgo = Date(timeIntervalSince1970: 1_600_000_000)

    private struct Bed {
        let dir: URL
        let db: Database
        let repo: CoverArtRepository
        let albums: AlbumRepository
        let cache: CoverArtCache
    }

    /// A cache whose budget holds two arts; a third forces a sweep.
    private static func makeBed() async throws -> Bed {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-art-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try await Database(location: .inMemory)
        let repo = CoverArtRepository(database: db)
        let cache = CoverArtCache(cacheRoot: dir, repo: repo, totalBytesLimit: 250_000, sweepThresholdBytes: 1)
        return Bed(dir: dir, db: db, repo: repo, albums: AlbumRepository(database: db), cache: cache)
    }

    private static func art(fill: UInt8) throws -> ExtractedCoverArt {
        let raw = RawCoverArt(data: Data(repeating: fill, count: Self.artBytes), mimeType: "image/jpeg", pictureType: 3)
        return try #require(CoverArtExtractor.extract(from: [raw]).first)
    }

    /// Writes art the way `BatchCoverArtViewModel` does: its own file in the
    /// cache layout, a `musicbrainz` row, and the album link.
    private static func writeLikeBatchCoverArt(_ bed: Bed, albumID: Int64) async throws -> (hash: String, path: String) {
        let art = try Self.art(fill: 0xB0)
        let dir = bed.dir.appendingPathComponent(String(art.sha256.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(art.sha256).jpg").path
        try art.data.write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try await bed.repo.save(CoverArt(hash: art.sha256, path: path, byteSize: art.data.count, source: "musicbrainz"))
        try await bed.albums.setCoverArt(albumID: albumID, hash: art.sha256, path: path)
        return (art.sha256, path)
    }

    /// Makes `path` the least recently used file, then persists two embedded
    /// arts, which pushes the cache to 300 KB against a 250 KB budget.
    /// Returns the path of the older embedded art, the one the sweep must
    /// evict instead.
    @discardableResult
    private static func ageAndOverfill(_ bed: Bed, path: String) async throws -> String {
        try FileManager.default.setAttributes([.modificationDate: self.longAgo], ofItemAtPath: path)
        let older = try #require(try await bed.cache.persist([Self.art(fill: 1)], source: "embedded"))
        try await Task.sleep(nanoseconds: 25_000_000) // strictly ordered mtimes
        _ = try await bed.cache.persist([Self.art(fill: 2)], source: "embedded")
        return older.path
    }

    @Test("Batch Cover Art survives a sweep, and its album keeps the cover")
    func musicBrainzArtSurvives() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let albumID = try await bed.albums.insert(Album(title: "Fetched Cover"))
        let fetched = try await Self.writeLikeBatchCoverArt(bed, albumID: albumID)

        let evictable = try await Self.ageAndOverfill(bed, path: fetched.path)

        #expect(FileManager.default.fileExists(atPath: fetched.path), "a rescan cannot rebuild this file")
        #expect(try await bed.repo.fetch(hash: fetched.hash) != nil)
        #expect(try await bed.albums.fetch(id: albumID).coverArtHash == fetched.hash)
        #expect(!FileManager.default.fileExists(atPath: evictable), "the sweep still evicts embedded art in its place")
    }

    @Test("the full-size original of art the user chose survives with it")
    func userOriginalSurvives() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let chosen = try #require(try await bed.cache.persist([Self.art(fill: 0xC1)], source: "user"))
        // `persist` keeps an original only for art over 4096 px; place one by
        // hand, named by the same hash, as it would be.
        let originals = bed.dir.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("\(chosen.hash).jpg").path
        try Data(repeating: 0xC1, count: 60000).write(to: URL(fileURLWithPath: original))
        try FileManager.default.setAttributes([.modificationDate: Self.longAgo], ofItemAtPath: original)

        try await Self.ageAndOverfill(bed, path: chosen.path)

        #expect(FileManager.default.fileExists(atPath: chosen.path))
        #expect(FileManager.default.fileExists(atPath: original), "the editor's \"Show original\" needs it")
    }

    @Test("art the user chose survives a sweep, and its album keeps the cover")
    func userArtSurvives() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let albumID = try await bed.albums.insert(Album(title: "Chosen Cover"))
        let chosen = try #require(try await bed.cache.persist([Self.art(fill: 0xC0)], source: "user"))
        try await bed.albums.setCoverArt(albumID: albumID, hash: chosen.hash, path: chosen.path)

        try await Self.ageAndOverfill(bed, path: chosen.path)

        #expect(FileManager.default.fileExists(atPath: chosen.path), "a rescan cannot rebuild this file")
        #expect(try await bed.repo.fetch(hash: chosen.hash) != nil)
        #expect(try await bed.albums.fetch(id: albumID).coverArtHash == chosen.hash)
    }
}
