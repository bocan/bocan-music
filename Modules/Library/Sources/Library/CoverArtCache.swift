import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Observability
import Persistence
import UniformTypeIdentifiers

/// Manages the cover art cache directory and persists cover-art rows.
///
/// Cache layout:
/// - Working art: `<cacheRoot>/<sha256[0..<2]>/<sha256>.<ext>`
/// - Originals (when downsampled): `<cacheRoot>/originals/<sha256>.<ext>`
actor CoverArtCache {
    // MARK: - Properties

    private let cacheRoot: URL
    private let repo: CoverArtRepository
    private let log = AppLogger.make(.library)

    /// Phase 3 audit H5: cap cache art at 4096 px on the longest side.
    /// Originals are preserved separately for the metadata editor's
    /// "Show original" affordance (Phase 8).
    private let maxLongestSide = 4096

    // MARK: - Init

    init(cacheRoot: URL, repo: CoverArtRepository) {
        self.cacheRoot = cacheRoot
        self.repo = repo
    }

    static func make(database: Database) -> CoverArtCache {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bocan", isDirectory: true)
            .appendingPathComponent("CoverArt", isDirectory: true)
        return CoverArtCache(cacheRoot: appSupport, repo: CoverArtRepository(database: database))
    }

    // MARK: - API

    /// Persists `arts` to disk (if absent) and to the DB.
    ///
    /// Returns the hash and file-system path of the first art item, or `nil` when `arts` is empty.
    func persist(_ arts: [ExtractedCoverArt]) async throws -> (hash: String, path: String)? {
        guard !arts.isEmpty else { return nil }
        var first: (hash: String, path: String)?
        for art in arts {
            let hash = art.sha256
            let prefix = String(hash.prefix(2))
            let dir = self.cacheRoot.appendingPathComponent(prefix, isDirectory: true)
            let fileURL = dir.appendingPathComponent("\(hash).\(art.fileExtension)")

            // Resize-if-needed: very large art is kept verbatim under
            // `originals/` and a downsampled copy is written to the working path.
            let resized = self.downsampleIfNeeded(data: art.data, fileExtension: art.fileExtension)

            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try resized.data.write(to: fileURL, options: .atomic)
                self.log.debug("cover_art.write", [
                    "hash": hash,
                    "downsampled": resized.didDownsample,
                    "width": resized.pixelSize?.width ?? 0,
                    "height": resized.pixelSize?.height ?? 0,
                ])

                if resized.didDownsample {
                    let originalsDir = self.cacheRoot.appendingPathComponent("originals", isDirectory: true)
                    let originalURL = originalsDir.appendingPathComponent("\(hash).\(art.fileExtension)")
                    if !fm.fileExists(atPath: originalURL.path) {
                        try fm.createDirectory(at: originalsDir, withIntermediateDirectories: true)
                        try art.data.write(to: originalURL, options: .atomic)
                        self.log.debug("cover_art.original_preserved", ["hash": hash])
                    }
                }
            }

            let record = CoverArt(
                hash: hash,
                path: fileURL.path,
                width: resized.pixelSize.map { Int($0.width) },
                height: resized.pixelSize.map { Int($0.height) },
                format: art.fileExtension == "jpg" ? "jpeg" : art.fileExtension
            )
            try await self.repo.save(record)
            if first == nil { first = (hash: hash, path: fileURL.path) }
        }
        return first
    }

    // MARK: - Private

    private struct DownsampleResult {
        let data: Data
        let didDownsample: Bool
        let pixelSize: CGSize?
    }

    /// Returns a downsampled copy when the longest side exceeds `maxLongestSide`,
    /// otherwise returns the original data unchanged.  The pixel size is
    /// reported so the DB row can store it.
    private func downsampleIfNeeded(data: Data, fileExtension: String) -> DownsampleResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return DownsampleResult(data: data, didDownsample: false, pixelSize: nil)
        }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, opts as CFDictionary) as? [CFString: Any],
              let widthNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return DownsampleResult(data: data, didDownsample: false, pixelSize: nil)
        }
        let width = widthNum.intValue
        let height = heightNum.intValue
        let longest = max(width, height)
        guard longest > self.maxLongestSide else {
            return DownsampleResult(
                data: data,
                didDownsample: false,
                pixelSize: CGSize(width: width, height: height)
            )
        }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: self.maxLongestSide,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return DownsampleResult(
                data: data,
                didDownsample: false,
                pixelSize: CGSize(width: width, height: height)
            )
        }

        let utType: CFString = (fileExtension == "png")
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData as CFMutableData, utType, 1, nil) else {
            return DownsampleResult(
                data: data,
                didDownsample: false,
                pixelSize: CGSize(width: width, height: height)
            )
        }
        let destProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, thumb, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return DownsampleResult(
                data: data,
                didDownsample: false,
                pixelSize: CGSize(width: width, height: height)
            )
        }
        return DownsampleResult(
            data: outData as Data,
            didDownsample: true,
            pixelSize: CGSize(width: thumb.width, height: thumb.height)
        )
    }
}
