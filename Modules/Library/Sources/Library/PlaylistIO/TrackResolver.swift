import Foundation
import Observability
import Persistence

/// Resolves playlist entries to library tracks via path → fuzzy metadata.
///
/// Strategy (in order):
///   1. Normalised `file://` URL match against `tracks.file_url`.
///   2. Absolute filesystem-path match (canonical mapping).
///   3. Filename match across the library (when path didn't resolve).
///   4. Fuzzy match by `artist + title` constrained by `±tolerance` seconds.
///   5. Unresolved.
public actor TrackResolver {
    private let trackRepo: TrackRepository
    private let log = AppLogger.make(.library)

    public init(trackRepo: TrackRepository) {
        self.trackRepo = trackRepo
    }

    public func resolve(_ payload: PlaylistPayload, tolerance: TimeInterval = 2.0) async -> Resolution {
        var matches: [Resolution.Match] = []
        var misses: [Resolution.Miss] = []
        for (idx, entry) in payload.entries.enumerated() {
            if let id = await self.resolveEntry(entry, tolerance: tolerance) {
                matches.append(Resolution.Match(entryIndex: idx, trackID: id))
            } else {
                misses.append(Resolution.Miss(entryIndex: idx, hint: entry.hint))
            }
        }
        self.log.debug(
            "playlist.resolve",
            ["entries": payload.entries.count, "matches": matches.count, "misses": misses.count]
        )
        return Resolution(matches: matches, misses: misses)
    }

    // MARK: - Single-entry resolution

    public func resolveEntry(_ entry: PlaylistPayload.Entry, tolerance: TimeInterval = 2.0) async -> Int64? {
        // Step 1: full file:// URL.
        if let url = entry.absoluteURL {
            let normalised = url.absoluteString.precomposedStringWithCanonicalMapping
            if let t = try? await self.trackRepo.fetchOne(fileURL: normalised), let id = t.id {
                return id
            }
            // Step 2: try without percent-encoding (decoded path).
            let altURL = URL(fileURLWithPath: url.path)
            let altNorm = altURL.absoluteString.precomposedStringWithCanonicalMapping
            if altNorm != normalised,
               let t = try? await self.trackRepo.fetchOne(fileURL: altNorm),
               let id = t.id {
                return id
            }
        }

        // Step 4: fuzzy by metadata.
        if let title = entry.titleHint, !title.isEmpty {
            if let candidate = try? await self.trackRepo.findByMetadata(
                artist: entry.artistHint,
                title: title,
                duration: entry.durationHint,
                tolerance: tolerance
            ), let id = candidate.id {
                return id
            }
        }

        return nil
    }
}
