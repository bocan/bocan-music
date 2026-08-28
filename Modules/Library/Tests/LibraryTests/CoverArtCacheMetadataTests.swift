import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Persistence
import Testing
import UniformTypeIdentifiers
@testable import Library

@Suite("CoverArtCache metadata")
struct CoverArtCacheMetadataTests {
    private func makeCache(db: Database) throws -> CoverArtCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-art-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CoverArtCache(cacheRoot: root, repo: CoverArtRepository(database: db))
    }

    /// A real `side` x `side` PNG so the cache can read its pixel size.
    private func png(side: Int, seed: UInt8) throws -> ExtractedCoverArt {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: CGFloat(seed) / 255, green: 0.2, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        let raw = RawCoverArt(data: out as Data, mimeType: "image/png", pictureType: 3)
        return try #require(CoverArtExtractor.extract(from: [raw]).first)
    }

    @Test("persist records dimensions, byte size, and provenance (#417)")
    func persistRecordsMetadata() async throws {
        let db = try await Database(location: .inMemory)
        let cache = try makeCache(db: db)
        let art = try png(side: 64, seed: 10)
        let persisted = try #require(try await cache.persist([art], source: "sidecar"))
        let row = try #require(try await CoverArtRepository(database: db).fetch(hash: persisted.hash))
        #expect(row.width == 64)
        #expect(row.height == 64)
        #expect(row.byteSize == art.data.count)
        #expect(row.source == "sidecar")
        #expect(row.format == "png")
    }

    @Test("save fills NULL metadata on an existing hash without overwriting values")
    func saveFillsNulls() async throws {
        let db = try await Database(location: .inMemory)
        let repo = CoverArtRepository(database: db)
        // A row from before dimensions and provenance were recorded.
        try await repo.save(CoverArt(hash: "old", path: "/art/old.jpg"))
        try await repo.save(CoverArt(hash: "old", path: "/art/ignored.jpg", width: 600, height: 600, byteSize: 1234, source: "embedded"))
        var row = try #require(try await repo.fetch(hash: "old"))
        #expect(row.path == "/art/old.jpg")
        #expect(row.width == 600)
        #expect(row.byteSize == 1234)
        #expect(row.source == "embedded")

        // A later persist with a different provenance does not override it.
        try await repo.save(CoverArt(hash: "old", path: "/art/old.jpg", source: "user"))
        row = try #require(try await repo.fetch(hash: "old"))
        #expect(row.source == "embedded")
    }
}
