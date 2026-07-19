import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// MARK: - TestImage

/// Shared test helper: writes a solid-colour PNG of the given pixel size to a
/// unique temp file. One definition for the artwork, mosaic, and collection-card
/// tests, which each used to carry their own copy.
enum TestImage {
    static func solidPNG(
        width: Int = 100,
        height: Int = 100,
        color: CGColor = CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }
}
