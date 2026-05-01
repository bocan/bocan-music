import AppKit

// MARK: - PlaylistMosaicGenerator

/// Off-main-thread actor that composites up to four album-cover images
/// into a 2×2 mosaic suitable for the playlist header hero.
///
/// Results are cached by the union of source paths and the playlist's
/// `updated_at` epoch; stale entries are evicted automatically when
/// membership changes.
actor PlaylistMosaicGenerator {
    static let shared = PlaylistMosaicGenerator()

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let paths: [String]
        let updatedAt: Int64
    }

    private var cache: [CacheKey: NSImage] = [:]

    // MARK: - Public

    /// Returns a square `NSImage` composed from up to four entries in `paths`,
    /// or `nil` if no images can be loaded from disk.
    ///
    /// - Parameters:
    ///   - paths:      Ordered cover-art file paths (duplicates are de-duped; up to 4 used).
    ///   - updatedAt:  The playlist's `updated_at` epoch value; acts as a cache-version key.
    ///   - sideLength: Pixel side length of the result (default 144 px ≈ 72 pt @2×).
    func mosaic(paths: [String], updatedAt: Int64, sideLength: Int = 144) -> NSImage? {
        let uniquePaths = paths.filter { !$0.isEmpty }.uniqued().prefix(4)
        let pathList = Array(uniquePaths)
        guard !pathList.isEmpty else { return nil }

        let key = CacheKey(paths: pathList, updatedAt: updatedAt)
        if let cached = cache[key] { return cached }

        let cgImages: [CGImage] = pathList.compactMap { path in
            guard let img = NSImage(contentsOfFile: path) else { return nil }
            var rect = NSRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard !cgImages.isEmpty else { return nil }

        guard let result = Self.compose(images: cgImages, sideLength: sideLength) else { return nil }
        self.cache[key] = result
        return result
    }

    // MARK: - Composition

    private static func compose(images: [CGImage], sideLength: Int) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: sideLength,
            height: sideLength,
            bitsPerComponent: 8,
            bytesPerRow: sideLength * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Dark fill so any un-covered pixels look intentional.
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: sideLength, height: sideLength))

        let rects = Self.tileRects(count: images.count, sideLength: sideLength)
        for (cgImage, rect) in zip(images, rects) {
            let drawn = Self.aspectFillCrop(cgImage, to: rect) ?? cgImage
            ctx.draw(drawn, in: rect)
        }

        guard let composited = ctx.makeImage() else { return nil }
        let ptSide = CGFloat(sideLength) / 2
        return NSImage(cgImage: composited, size: NSSize(width: ptSide, height: ptSide))
    }

    /// Returns tile rects in the same coordinate system as `CGContext` (origin bottom-left).
    private static func tileRects(count: Int, sideLength: Int) -> [CGRect] {
        let s = CGFloat(sideLength)
        let half = s / 2
        guard count > 1 else {
            return [CGRect(x: 0, y: 0, width: s, height: s)]
        }
        return [
            CGRect(x: 0, y: half, width: half, height: half),
            CGRect(x: half, y: half, width: half, height: half),
            CGRect(x: 0, y: 0, width: half, height: half),
            CGRect(x: half, y: 0, width: half, height: half),
        ]
    }

    /// Crops `image` so it fills `rect` with aspect-fill (centre crop).
    private static func aspectFillCrop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let targetAR = rect.width / rect.height
        let srcAR = srcW / srcH
        let cropRect: CGRect
        if srcAR > targetAR {
            let cropW = srcH * targetAR
            cropRect = CGRect(x: (srcW - cropW) / 2, y: 0, width: cropW, height: srcH)
        } else {
            let cropH = srcW / targetAR
            cropRect = CGRect(x: 0, y: (srcH - cropH) / 2, width: srcW, height: cropH)
        }
        return image.cropping(to: cropRect)
    }
}

// MARK: - Sequence+uniqued

private extension Sequence where Element: Hashable {
    /// Returns elements in original order with duplicates removed.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
