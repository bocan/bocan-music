import AppKit
import Observability
import SwiftUI

// MARK: - Image loader actor

/// Thread-safe async image loader with `NSCache` backing.
///
/// Images are keyed by the SHA-256 hash string stored in `cover_art.hash` /
/// `tracks.cover_art_hash`.  The cache has a 200-image cost limit; macOS will
/// evict under memory pressure.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    private let log = AppLogger.make(.ui)

    /// Returns a decoded `NSImage` for `path`, loading from disk if not cached.
    func image(at path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else {
            self.log.debug("artwork.miss", ["path": path])
            return nil
        }
        self.cache.setObject(img, forKey: key)
        return img
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
        ZStack {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(self.isLoaded ? 1 : 0)
                    .animation(self.reduceMotion ? .none : Theme.animationNormal, value: self.isLoaded)
            } else {
                GradientPlaceholder(seed: self.seed)
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: self.size > 60 ? Theme.cornerRadiusMedium : Theme.cornerRadiusSmall)
        )
        .task(id: self.artPath) {
            self.isLoaded = false
            self.loadedImage = nil
            guard let path = artPath else { return }
            let img = await ArtworkLoader.shared.image(at: path)
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
