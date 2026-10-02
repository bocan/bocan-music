import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Persistence
import Testing
import UniformTypeIdentifiers
@testable import Library

/// #583: the full-size originals the cache keeps for covers over 4096 px are
/// now read, by the album page's "Show Original Cover". `CoverArtFiles` is
/// where a reader finds them.
@Suite("CoverArtFiles")
struct CoverArtFilesTests {
    private struct Bed {
        let root: URL
        let cache: CoverArtCache
    }

    private func makeBed() async throws -> Bed {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-art-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try await Database(location: .inMemory)
        return Bed(root: root, cache: CoverArtCache(cacheRoot: root, repo: CoverArtRepository(database: db)))
    }

    /// A real `width` x `height` PNG, so the cache reads its pixel size.
    private func png(width: Int, height: Int) throws -> ExtractedCoverArt {
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        let raw = RawCoverArt(data: out as Data, mimeType: "image/png", pictureType: 3)
        return try #require(CoverArtExtractor.extract(from: [raw]).first)
    }

    private func pixelWidth(at url: URL) throws -> Int {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try #require((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
    }

    @Test("A cover over 4096 px resolves to its kept original at full size")
    func largeCoverResolvesToOriginal() async throws {
        let bed = try await self.makeBed()
        let persisted = try #require(try await bed.cache.persist([self.png(width: 4200, height: 10)], source: "user"))
        #expect(try self.pixelWidth(at: URL(fileURLWithPath: persisted.path)) == 4096)

        let full = try #require(CoverArtFiles.fullSizeURL(forWorkingPath: persisted.path))
        #expect(full.deletingLastPathComponent().lastPathComponent == "originals")
        #expect(full.lastPathComponent == URL(fileURLWithPath: persisted.path).lastPathComponent)
        #expect(try self.pixelWidth(at: full) == 4200)
    }

    @Test("A cover within 4096 px resolves to the working file, which is the full image")
    func smallCoverResolvesToWorkingFile() async throws {
        let bed = try await self.makeBed()
        let persisted = try #require(try await bed.cache.persist([self.png(width: 64, height: 64)], source: "embedded"))
        let full = try #require(CoverArtFiles.fullSizeURL(forWorkingPath: persisted.path))
        #expect(full.path == persisted.path)
        #expect(!FileManager.default.fileExists(atPath: bed.root.appendingPathComponent("originals").path))
    }

    @Test("An evicted original falls back to the working copy")
    func evictedOriginalFallsBack() async throws {
        let bed = try await self.makeBed()
        let persisted = try #require(try await bed.cache.persist([self.png(width: 4200, height: 10)], source: "embedded"))
        let original = try #require(CoverArtFiles.fullSizeURL(forWorkingPath: persisted.path))
        try FileManager.default.removeItem(at: original)
        #expect(CoverArtFiles.fullSizeURL(forWorkingPath: persisted.path)?.path == persisted.path)
    }

    @Test("A path with no file on disk resolves to nothing")
    func missingFileResolvesToNil() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-cache-\(UUID().uuidString)/ab/abcdef.jpg").path
        #expect(CoverArtFiles.fullSizeURL(forWorkingPath: path) == nil)
    }
}
