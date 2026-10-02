import Foundation
import Metadata
import Observability
import Persistence

// MARK: - Per-file import, after the conflict check

extension ScanCoordinator {
    /// Imports the file through a `TrackImporter` and emits the outcome.
    func importAndReport(
        file: ScannedFile,
        tags: TrackTags,
        existingTrack: Track?,
        emit: @Sendable (ScanProgress) -> Void
    ) async -> ImportResult {
        let url = file.url
        let size = file.size
        let mtime = file.mtime
        // Create importer and import
        let importer = TrackImporter(
            artistRepo: artistRepo,
            albumRepo: albumRepo,
            trackRepo: trackRepo,
            lyricsRepo: lyricsRepo,
            coverArtCache: coverArtCache
        )

        let bookmark = self.bookmark(for: url, existingTrack: existingTrack)

        do {
            let id = try await importer.importTrack(
                url: url,
                bookmark: bookmark,
                tags: tags,
                fileMtime: mtime,
                fileSize: size
            )
            if existingTrack == nil {
                emit(.processed(url: url, outcome: .inserted(trackID: id)))
                return .inserted(id)
            } else {
                emit(.processed(url: url, outcome: .updated(trackID: id)))
                return .updated(id)
            }
        } catch {
            self.log.error("scan.import_failed", ["url": url.path, "error": "\(error)"])
            emit(.error(url: url, error: error))
            return .error
        }
    }

    /// Returns `true` when any user-visible tag field differs between the
    /// stored `Track` and the freshly-read `TrackTags`. Used in the conflict
    /// branch so we only raise `needsConflictReview` when something actually
    /// changed, not just the file's modification timestamp.
    static func tagsDiffer(dbTrack: Track, diskTags: TrackTags) -> Bool {
        func ne<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
            lhs != rhs
        }
        return ne(dbTrack.title, diskTags.title) ||
            ne(dbTrack.genre, diskTags.genre) ||
            ne(dbTrack.composer, diskTags.composer) ||
            ne(dbTrack.isrc, diskTags.isrc) ||
            ne(dbTrack.key, diskTags.key) ||
            ne(dbTrack.year, diskTags.year) ||
            ne(dbTrack.trackNumber, diskTags.trackNumber) ||
            ne(dbTrack.trackTotal, diskTags.trackTotal) ||
            ne(dbTrack.discNumber, diskTags.discNumber) ||
            ne(dbTrack.discTotal, diskTags.discTotal)
    }
}
