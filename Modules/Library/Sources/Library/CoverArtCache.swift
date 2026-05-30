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

    /// Soft cap on the total on-disk cover-art cache (working art + originals).
    /// When `persist` pushes the cache past this, a least-recently-used sweep
    /// deletes the oldest art by file modification time until back under
    /// budget. Working-art rows are also removed from the DB; because
    /// `albums`/`tracks` reference `cover_art` with `ON DELETE SET NULL`, the
    /// only consequence of evicting still-referenced art is that it is
    /// re-extracted on the next scan. See #268.
    private let totalBytesLimit: Int

    /// Re-check disk usage only after this many *new* bytes have been written.
    /// Without this throttle a full directory enumeration would run on every
    /// persisted file (O(n²) over a large scan); instead it runs roughly once
    /// per `sweepThresholdBytes` of growth, bounding overshoot to ~one slab.
    private let sweepThresholdBytes: Int

    /// New bytes written since the last sweep check.
    private var bytesSinceSweep = 0

    // MARK: - Init

    init(
        cacheRoot: URL,
        repo: CoverArtRepository,
        totalBytesLimit: Int = 1 << 30, // 1 GiB
        sweepThresholdBytes: Int = 128 * 1024 * 1024 // 128 MiB
    ) {
        self.cacheRoot = cacheRoot
        self.repo = repo
        self.totalBytesLimit = totalBytesLimit
        self.sweepThresholdBytes = sweepThresholdBytes
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
                self.bytesSinceSweep += resized.data.count
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
                        self.bytesSinceSweep += art.data.count
                        self.log.debug("cover_art.original_preserved", ["hash": hash])
                    }
                }
            } else {
                // Dedup hit: this art is still in use, so refresh its LRU
                // timestamp to keep frequently-seen art warm against eviction.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
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

        // Periodically enforce the disk budget. Throttled by accumulated new
        // bytes so the directory enumeration runs ~once per slab of growth
        // rather than on every persisted file.
        if self.bytesSinceSweep >= self.sweepThresholdBytes {
            self.bytesSinceSweep = 0
            await self.sweep()
        }
        return first
    }

    // MARK: - Eviction

    /// Enforces `totalBytesLimit` by deleting least-recently-used art (oldest
    /// file modification time first) until the on-disk cache is back under
    /// budget. Working-art files also have their `cover_art` DB row removed so
    /// the stored path never dangles; `originals/` files have no DB row and are
    /// simply unlinked.
    private func sweep() async {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: self.cacheRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let size: Int
            let mtime: Date
            let isOriginal: Bool
        }

        let originalsPath = self.cacheRoot
            .appendingPathComponent("originals", isDirectory: true)
            .path
        var entries: [Entry] = []
        var total = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            entries.append(Entry(
                url: url,
                size: size,
                mtime: values.contentModificationDate ?? .distantPast,
                isOriginal: url.deletingLastPathComponent().path == originalsPath
            ))
            total += size
        }

        guard total > self.totalBytesLimit else { return }

        entries.sort { $0.mtime < $1.mtime } // least-recently-used first
        var evicted = 0
        var freed = 0
        for entry in entries {
            if total <= self.totalBytesLimit { break }
            do {
                try fm.removeItem(at: entry.url)
            } catch {
                self.log.warning("cover_art.sweep.delete_failed", [
                    "path": entry.url.path,
                    "error": String(reflecting: error),
                ])
                continue
            }
            total -= entry.size
            freed += entry.size
            evicted += 1
            if !entry.isOriginal {
                // hash == filename stem (`<hash>.<ext>`).
                let hash = entry.url.deletingPathExtension().lastPathComponent
                try? await self.repo.delete(hash: hash)
            }
        }
        self.log.info("cover_art.sweep", [
            "evicted": evicted,
            "freedBytes": freed,
            "remainingBytes": total,
            "limitBytes": self.totalBytesLimit,
        ])
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
