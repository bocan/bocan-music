import Foundation
import Metadata
import Observability
import Persistence

/// Manages the cover art cache directory and persists cover-art rows.
///
/// Cache layout: `<cacheRoot>/<sha256[0..<2]>/<sha256>.<ext>`
actor CoverArtCache {
    // MARK: - Properties

    private let cacheRoot: URL
    private let repo: CoverArtRepository
    private let log = AppLogger.make(.library)

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
    /// Returns the hash of the first front-cover art, or `nil`.
    func persist(_ arts: [ExtractedCoverArt]) async throws -> String? {
        guard !arts.isEmpty else { return nil }
        var firstHash: String?
        for art in arts {
            let hash = art.sha256
            let prefix = String(hash.prefix(2))
            let dir = self.cacheRoot.appendingPathComponent(prefix, isDirectory: true)
            let fileURL = dir.appendingPathComponent("\(hash).\(art.fileExtension)")

            // Write to disk only if absent
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try art.data.write(to: fileURL, options: .atomic)
                self.log.debug("cover_art.write", ["hash": hash])
            }

            let record = CoverArt(
                hash: hash,
                path: fileURL.path,
                width: nil,
                height: nil,
                format: art.fileExtension == "jpg" ? "jpeg" : art.fileExtension
            )
            try await self.repo.save(record)
            if firstHash == nil { firstHash = hash }
        }
        return firstHash
    }
}
