import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - CoverMosaicGeneratorTests

/// Unit tests for the shared cover-mosaic engine (phase 23-1). Each test uses a
/// fresh generator instance so the singleton's cache never leaks across tests.
@Suite("CoverMosaicGenerator")
@MainActor
struct CoverMosaicGeneratorTests {
    /// Writes a solid-colour PNG to a unique temp file and returns its path.
    private func writePNG(_ color: NSColor) throws -> String {
        let size = NSSize(width: 100, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-\(UUID().uuidString).png")
        try png.write(to: url)
        return url.path
    }

    @Test("Composes 1 to 4 images into a square", arguments: 1 ... 4)
    func composesSquare(count: Int) async throws {
        let paths = try (0 ..< count).map { _ in try self.writePNG(.systemBlue) }
        let generator = CoverMosaicGenerator()
        let image = await generator.mosaic(paths: paths, version: 0)
        let unwrapped = try #require(image)
        #expect(unwrapped.size.width == unwrapped.size.height)
        #expect(unwrapped.size.width > 0)
    }

    @Test("Empty path list yields nil")
    func emptyYieldsNil() async {
        let generator = CoverMosaicGenerator()
        let image = await generator.mosaic(paths: [], version: 0)
        #expect(image == nil)
    }

    @Test("Cache returns the identical instance on a second call")
    func cacheIdentity() async throws {
        let path = try self.writePNG(.systemRed)
        let generator = CoverMosaicGenerator()
        let first = try #require(await generator.mosaic(paths: [path], version: 0))
        let second = try #require(await generator.mosaic(paths: [path], version: 0))
        #expect(first === second)
    }

    @Test("A different version key composes a fresh image")
    func versionInvalidates() async throws {
        let path = try self.writePNG(.systemGreen)
        let generator = CoverMosaicGenerator()
        let v0 = try #require(await generator.mosaic(paths: [path], version: 0))
        let v1 = try #require(await generator.mosaic(paths: [path], version: 1))
        #expect(v0 !== v1)
    }

    @Test("The cache clears once it exceeds the 512-entry cap")
    func capClears() async throws {
        let path = try self.writePNG(.systemOrange)
        let generator = CoverMosaicGenerator()
        // Seed version 0, then fill the cache to the 512-entry cap with distinct
        // version keys. The 512th distinct key past the seed triggers a clear.
        let seeded = try #require(await generator.mosaic(paths: [path], version: 0))
        for version in 1 ... 512 {
            _ = await generator.mosaic(paths: [path], version: Int64(version))
        }
        // Version 0 was evicted by the clear, so it recomputes to a new instance.
        let refetched = try #require(await generator.mosaic(paths: [path], version: 0))
        #expect(seeded !== refetched)
    }
}
