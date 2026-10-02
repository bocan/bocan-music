import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Observability
import Persistence
import UniformTypeIdentifiers

// MARK: - CoverArtFiles

/// Where a cover's full-size image lives on disk.
///
/// Working art is capped at 4096 px on its longest side. A larger cover keeps
/// its full-size bytes in `originals/`, beside the two-character working
/// folders, under the same file name (ADR-010 "Show original", #583).
public enum CoverArtFiles {
    /// The full-size image for the working art at `workingPath`: the kept
    /// original when there is one, otherwise the working file itself (which
    /// is then the full image, or the best copy left after an original was
    /// evicted), or `nil` when neither exists on disk.
    public static func fullSizeURL(forWorkingPath workingPath: String) -> URL? {
        let working = URL(fileURLWithPath: workingPath)
        let original = self.originalURL(forWorking: working)
        let fm = FileManager.default
        if fm.fileExists(atPath: original.path) {
            return original
        }
        return fm.fileExists(atPath: working.path) ? working : nil
    }

    /// `<cacheRoot>/originals/<hash>.<ext>` for working art at
    /// `<cacheRoot>/<hash[0..<2]>/<hash>.<ext>`. The single place that knows
    /// the layout, shared by the writer (`CoverArtCache.persist`) and readers.
    static func originalURL(forWorking working: URL) -> URL {
        working.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(working.lastPathComponent)
    }
}

// MARK: - CoverArtCache

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

    /// ADR-004 audit H5: cap cache art at 4096 px on the longest side.
    /// Originals are preserved separately for the metadata editor's
    /// "Show original" affordance (ADR-010).
    private let maxLongestSide = 4096

    /// Soft cap on the total on-disk cover-art cache (working art + originals).
    /// When `persist` pushes the cache past this, a least-recently-used sweep
    /// deletes the oldest art by file modification time until back under
    /// budget (#268). Working-art rows are also removed from the DB.
    ///
    /// The sweep never evicts art that is still needed, so it can end above
    /// this cap:
    /// - working art an album or a track shows (#576). `albums`/`tracks`
    ///   reference `cover_art` with `ON DELETE SET NULL`, so evicting it
    ///   left them without a cover, and a quick scan skips unchanged files,
    ///   so only a full rescan brought it back.
    /// - art a rescan cannot rebuild at all (`unrebuildableSources`, #570),
    ///   working copy and original alike.
    ///
    /// - working art written or refreshed within `newArtGracePeriod`. The
    ///   caller links art only after `persist` returns, and a scan imports up
    ///   to four files at once, so art another import has just persisted is
    ///   not linked yet. Without this, a folder where everything older is in
    ///   use evicted each new cover as soon as it was written.
    ///
    /// So what the sweep evicts is art nothing shows any more, and the
    /// full-size originals of rebuildable art. Those originals are what an
    /// album page's "Show Original Cover" opens (`CoverArtFiles`, #583);
    /// once one is evicted it opens the working copy instead, and the
    /// full-size bytes are still in the audio file or the sidecar.
    private let totalBytesLimit: Int

    /// How long after it is written (or refreshed by a dedup hit) working art
    /// is kept whatever the sweep finds: far longer than any gap between
    /// `persist` and the caller's link.
    private let newArtGracePeriod: TimeInterval

    /// `cover_art.source` values whose bytes exist only in this cache, never
    /// in or next to an audio file: `musicbrainz` (Batch Cover Art writes it
    /// here and nowhere else) and `user` (the editor's no-file-write path,
    /// #472, keeps the chosen image only here). The sweep never evicts them.
    static let unrebuildableSources: Set = ["musicbrainz", "user"]

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
        sweepThresholdBytes: Int = 128 * 1024 * 1024, // 128 MiB
        newArtGracePeriod: TimeInterval = 300
    ) {
        self.cacheRoot = cacheRoot
        self.repo = repo
        self.totalBytesLimit = totalBytesLimit
        self.sweepThresholdBytes = sweepThresholdBytes
        self.newArtGracePeriod = newArtGracePeriod
    }

    static func make(database: Database) -> CoverArtCache {
        // Same fallback as `LibraryLocation`: the user-domain lookup has no
        // documented way to come back empty, and the fallback is the same folder.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let cacheRoot = appSupport
            .appendingPathComponent("Bocan", isDirectory: true)
            .appendingPathComponent("CoverArt", isDirectory: true)
        return CoverArtCache(cacheRoot: cacheRoot, repo: CoverArtRepository(database: database))
    }

    // MARK: - API

    /// Persists `arts` to disk (if absent) and to the DB.
    ///
    /// `source` records provenance in `cover_art.source` (`embedded`, `sidecar`,
    /// `user`; the MusicBrainz batch tool writes `musicbrainz` itself), so the
    /// hygiene pane and the batch tool can tell a 200 px embedded thumbnail from
    /// art the user chose (#417). An existing row keeps its own value and only
    /// has NULL metadata filled in (see `CoverArtRepository.save`).
    ///
    /// Returns the hash and file-system path of the first art item, or `nil` when `arts` is empty.
    func persist(_ arts: [ExtractedCoverArt], source: String) async throws -> (hash: String, path: String)? {
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

            try self.writeIfAbsent(art, resized: resized, to: fileURL, in: dir, hash: hash)

            let record = CoverArt(
                hash: hash,
                path: fileURL.path,
                width: resized.pixelSize.map { Int($0.width) },
                height: resized.pixelSize.map { Int($0.height) },
                format: art.fileExtension == "jpg" ? "jpeg" : art.fileExtension,
                byteSize: resized.data.count,
                source: source
            )
            try await self.repo.save(record)
            if first == nil {
                first = (hash: hash, path: fileURL.path)
            }
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

    /// Writes the working copy of `art` to `fileURL` when no file is there,
    /// with the original beside it when the working copy was downsampled. A
    /// file already there only has its modification date refreshed.
    private func writeIfAbsent(
        _ art: ExtractedCoverArt,
        resized: DownsampleResult,
        to fileURL: URL,
        in dir: URL,
        hash: String
    ) throws {
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
                let originalURL = CoverArtFiles.originalURL(forWorking: fileURL)
                let originalsDir = originalURL.deletingLastPathComponent()
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
    }

    // MARK: - Eviction

    /// One file in the cache, as the sweep sees it.
    private struct SweepEntry {
        let url: URL
        let size: Int
        let mtime: Date
        let isOriginal: Bool

        /// Working art and its original are both named `<hash>.<ext>`.
        var hash: String {
            self.url.deletingPathExtension().lastPathComponent
        }
    }

    /// Enforces `totalBytesLimit` by deleting least-recently-used art (oldest
    /// file modification time first) until the on-disk cache is back under
    /// budget. Working-art files also have their `cover_art` DB row removed so
    /// the stored path never dangles; `originals/` files have no DB row and are
    /// simply unlinked. Art from `unrebuildableSources` (working copy and
    /// original alike), working art an album or track shows, and working art
    /// newer than `newArtGracePeriod` are skipped but still count towards the
    /// total.
    private func sweep() async {
        let fm = FileManager.default
        var (entries, total) = self.cacheEntries()
        guard total > self.totalBytesLimit else { return }

        // If either set cannot be read, evict nothing: over budget is better
        // than deleting a cover that is in use or the only copy of one.
        guard let protected = await self.protectedHashes() else { return }
        let unrebuildable = protected.unrebuildable
        let inUse = protected.inUse

        entries.sort { $0.mtime < $1.mtime } // least-recently-used first
        let linkCutoff = Date().addingTimeInterval(-self.newArtGracePeriod)
        var evicted = 0
        var freed = 0
        var protectedCount = 0
        var protectedBytes = 0
        for entry in entries {
            if total <= self.totalBytesLimit {
                break
            }
            // An original is kept only for unrebuildable art. The original of
            // an embedded or sidecar cover can go: its full-size bytes are
            // still in the file, and "Show Original Cover" then opens the
            // working copy. Working art is kept while in use, or while new
            // enough that its link may be pending.
            let keepWorking = !entry.isOriginal && (inUse.contains(entry.hash) || entry.mtime > linkCutoff)
            if unrebuildable.contains(entry.hash) || keepWorking {
                protectedCount += 1
                protectedBytes += entry.size
                continue
            }
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
                await self.deleteRow(hash: entry.hash)
            }
        }
        self.log.info("cover_art.sweep", [
            "evicted": evicted,
            "freedBytes": freed,
            "remainingBytes": total,
            "limitBytes": self.totalBytesLimit,
        ])
        if total > self.totalBytesLimit {
            // Every evictable file is gone; what is left is art in use or art
            // a rescan cannot rebuild.
            self.log.info("cover_art.sweep.protected", ["count": protectedCount, "bytes": protectedBytes])
        }
    }

    /// The hashes the sweep must not evict, or `nil` (with a log line) when
    /// either set cannot be read.
    private func protectedHashes() async -> (unrebuildable: Set<String>, inUse: Set<String>)? {
        let unrebuildable: Set<String>
        let inUse: Set<String>
        do {
            unrebuildable = try await self.repo.hashes(withSourceIn: Self.unrebuildableSources)
            inUse = try await self.repo.hashesInUse()
        } catch {
            self.log.warning("cover_art.sweep.skipped", ["error": String(reflecting: error)])
            return nil
        }
        return (unrebuildable, inUse)
    }

    /// Removes the `cover_art` row of an evicted working file.
    private func deleteRow(hash: String) async {
        do {
            try await self.repo.delete(hash: hash)
        } catch {
            // The file is gone but its row is not, so the next lookup
            // resolves to a path that no longer exists (#492).
            self.log.warning("cover_art.sweep.rowDeleteFailed", [
                "hash": hash,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Every regular file under the cache root, with the total of their sizes.
    private func cacheEntries() -> (entries: [SweepEntry], total: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: self.cacheRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }

        // Known by the folder's name, not by comparing full paths: the
        // enumerator can return a path with its symlinks resolved (`/var` is
        // `/private/var`), which then never matches `cacheRoot`, and an
        // original taken for working art would have its hash's row deleted
        // (#576). Working art sits in two-character hex folders, so the name
        // cannot collide.
        var entries: [SweepEntry] = []
        var total = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            entries.append(SweepEntry(
                url: url,
                size: size,
                mtime: values.contentModificationDate ?? .distantPast,
                isOriginal: url.deletingLastPathComponent().lastPathComponent == "originals"
            ))
            total += size
        }
        return (entries, total)
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

        guard let outData = self.encode(thumb, fileExtension: fileExtension) else {
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

    /// Encodes `thumb` as PNG (for a `png` extension) or JPEG, or returns
    /// `nil` when the image destination cannot be made or finalized.
    private func encode(_ thumb: CGImage, fileExtension: String) -> NSMutableData? {
        let utType: CFString = (fileExtension == "png")
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData as CFMutableData, utType, 1, nil) else {
            return nil
        }
        let destProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, thumb, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return outData
    }
}
