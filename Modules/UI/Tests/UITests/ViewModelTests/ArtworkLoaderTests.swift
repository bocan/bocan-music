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
/// Main-actor: `NSImage` construction on a worker thread races AppKit's
/// application-context `dispatch_once` under the parallel runner and can
/// deadlock against a main-actor suite creating a window (it wedged two full
/// `make tests` runs on 2026-09-01, in `-[NSApplication init]`). AppKit
/// object creation belongs on main.
@MainActor
@Suite("ArtworkLoader")
struct ArtworkLoaderTests {
    @Test("downsamples a large cover to a small cell size")
    func downsamplesSmallCell() async throws {
        let url = try TestImage.solidPNG(width: 1000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ArtworkLoader()
        // A 20 pt cell → 64 px floor; the 1000 px source must be downsampled.
        let img = try #require(await loader.image(at: url.path, maxDimensionPoints: 20))
        let longestEdge = max(img.size.width, img.size.height)
        #expect(longestEdge <= 64, "expected ≤ 64 px thumbnail, got \(longestEdge)")
    }

    @Test("caps even large/default requests well below full resolution")
    func capsLargeRequests() async throws {
        let url = try TestImage.solidPNG(width: 4096, height: 4096)
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
