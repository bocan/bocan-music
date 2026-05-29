import AppKit
import ImageIO
import Observability
import SwiftUI

// MARK: - Image loader actor

/// Thread-safe async image loader with `NSCache` backing.
///
/// Images are keyed by `<path>@<pixelSize>`: the same cover can coexist as a
/// tiny table thumbnail and a large hero image without one evicting the other.
///
/// Covers are **downsampled at decode time** via `CGImageSource` rather than
/// decoded at full resolution: a 4096px cover bound for a 36px cell wastes both
/// CPU and ~64 MB of RAM. The cache is bounded by both a count limit and a
/// `totalCostLimit` (approximate decoded bytes), and macOS evicts under memory
/// pressure on top of that.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    /// Approximate backing scale used to convert point sizes to pixels. Most
    /// Macs are Retina (2x); on a 1x display this merely over-resolves slightly,
    /// which stays bounded by the per-image cap below.
    private static let renderScale: CGFloat = 2.0
    /// Hard cap on a thumbnail's longest edge (pixels). 1024px is sharp for the
    /// largest hero art while keeping a single decoded cover to ~4 MB.
    private static let maxThumbnailPixels = 1024
    /// Floor so tiny cells still get a usable (and cacheable) thumbnail.
    private static let minThumbnailPixels = 64

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        // ~256 MB ceiling so a gridful of covers can't balloon unbounded.
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    private let log = AppLogger.make(.ui)

    /// Returns a decoded `NSImage` for `path`, downsampled so its longest edge is
    /// at most `maxDimensionPoints` (converted to pixels and capped). Loads from
    /// disk if not cached.
    ///
    /// - Parameter maxDimensionPoints: The largest on-screen edge the image will
    ///   be drawn at, in points. Defaults to a generous hero size for callers
    ///   that display art large.
    func image(at path: String, maxDimensionPoints: CGFloat = 512) -> NSImage? {
        let maxPixels = Self.pixelTarget(forPoints: maxDimensionPoints)
        let key = "\(path)@\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let cg = Self.downsampledCGImage(at: path, maxPixels: maxPixels) else {
            self.log.debug("artwork.miss", ["path": path])
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // Cost ≈ decoded bytes (8-bit RGBA) so totalCostLimit reflects real memory.
        self.cache.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
        return img
    }

    private static func pixelTarget(forPoints points: CGFloat) -> Int {
        let scaled = Int((points * self.renderScale).rounded(.up))
        return min(max(scaled, self.minThumbnailPixels), self.maxThumbnailPixels)
    }

    private static func downsampledCGImage(at path: String, maxPixels: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(
            url, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Artwork view

/// An async cover-art view that loads from the on-disk cache.
///
/// Shows a deterministic gradient placeholder when no art is available,
/// so grids always look intentional even for un-tagged tracks.
///
/// Usage:
/// ```swift
/// Artwork(artPath: track.coverArtHash.flatMap { repo.path(hash: $0) }, albumHash: track.albumID)
///     .frame(width: 160, height: 160)
/// ```
public struct Artwork: View {
    private let artPath: String?
    private let seed: Int
    private let size: CGFloat

    /// - Parameters:
    ///   - artPath: Absolute file-system path to the image (from `cover_art.path`).
    ///   - seed:    Deterministic seed for the placeholder gradient (use album/artist ID).
    ///   - size:    Side length used to derive corner radius.
    public init(artPath: String?, seed: Int, size: CGFloat = Theme.albumArtworkSize) {
        self.artPath = artPath
        self.seed = seed
        self.size = size
    }

    @State private var loadedImage: NSImage?
    @State private var isLoaded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        // Layout is driven by a fixed-aspect base shape; the image and the
        // placeholder sit in overlays so the container's size is not affected
        // by the image's native aspect ratio (some embedded covers are far
        // from square).  `.clipped()` keeps the fill-scaled image from
        // leaking into adjacent views.
        Color.bgTertiary
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GradientPlaceholder(seed: self.seed)
                    .opacity(self.loadedImage == nil ? 1 : 0)
            }
            .overlay {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(self.isLoaded ? 1 : 0)
                        .animation(self.reduceMotion ? .none : Theme.animationNormal, value: self.isLoaded)
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: self.size > 60 ? Theme.cornerRadiusMedium : Theme.cornerRadiusSmall)
            )
            .task(id: self.artPath) {
                self.isLoaded = false
                self.loadedImage = nil
                guard let path = artPath else { return }
                let img = await ArtworkLoader.shared.image(at: path, maxDimensionPoints: self.size)
                guard !Task.isCancelled else { return }
                self.loadedImage = img
                self.isLoaded = img != nil
            }
    }
}

// MARK: - Gradient placeholder

struct GradientPlaceholder: View {
    let seed: Int

    private var gradient: LinearGradient {
        let hue1 = Double(abs(seed) % 360) / 360.0
        let hue2 = Double((abs(seed) + 120) % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.4, brightness: 0.6),
                Color(hue: hue2, saturation: 0.5, brightness: 0.5),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        self.gradient
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityHidden(true)
            }
    }
}
