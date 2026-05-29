import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UI

// MARK: - ArtworkLoaderTests

/// Regression for issue #275: the artwork cache decoded covers at full
/// resolution (up to 4096px) regardless of display size and had no
/// `totalCostLimit`, so 200 large covers could exceed 1 GB. `ArtworkLoader` now
/// downsamples via `CGImageSource` to a capped, display-sized thumbnail.
@Suite("ArtworkLoader")
struct ArtworkLoaderTests {
    /// Writes a solid-colour PNG of the given pixel dimensions to a temp file.
    private func writePNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test("downsamples a large cover to a small cell size")
    func downsamplesSmallCell() async throws {
        let url = try self.writePNG(width: 1000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ArtworkLoader()
        // A 20 pt cell → 64 px floor; the 1000 px source must be downsampled.
        let img = try #require(await loader.image(at: url.path, maxDimensionPoints: 20))
        let longestEdge = max(img.size.width, img.size.height)
        #expect(longestEdge <= 64, "expected ≤ 64 px thumbnail, got \(longestEdge)")
    }

    @Test("caps even large/default requests well below full resolution")
    func capsLargeRequests() async throws {
        let url = try self.writePNG(width: 4096, height: 4096)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ArtworkLoader()
        // Default (hero) request must still be capped at 1024 px, not 4096.
        let img = try #require(await loader.image(at: url.path))
        let longestEdge = max(img.size.width, img.size.height)
        #expect(longestEdge <= 1024, "expected ≤ 1024 px cap, got \(longestEdge)")
    }

    @Test("returns nil for a missing file")
    func missingFile() async {
        let loader = ArtworkLoader()
        let img = await loader.image(at: "/nonexistent/\(UUID().uuidString).png")
        #expect(img == nil)
    }
}
