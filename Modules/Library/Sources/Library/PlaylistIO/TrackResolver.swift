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
            if let id = await self.trackID(fileURL: normalised, step: "url") {
                return id
            }
            // Step 2: try without percent-encoding (decoded path).
            let altURL = URL(fileURLWithPath: url.path)
            let altNorm = altURL.absoluteString.precomposedStringWithCanonicalMapping
            if altNorm != normalised, let id = await self.trackID(fileURL: altNorm, step: "decodedPath") {
                return id
            }
        }

        // Step 3: filename match — catches re-tagged files whose path changed.
        if let url = entry.absoluteURL {
            let filename = url.lastPathComponent
            if !filename.isEmpty {
                do {
                    if let id = try await self.trackRepo.findByFilename(filename)?.id {
                        return id
                    }
                } catch {
                    self.log.warning("playlist.import.lookupFailed", [
                        "step": "filename",
                        "error": String(reflecting: error),
                    ])
                }
            }
        }

        // Step 4: fuzzy by metadata.
        if let title = entry.titleHint, !title.isEmpty {
            do {
                let candidate = try await self.trackRepo.findByMetadata(
                    artist: entry.artistHint,
                    title: title,
                    duration: entry.durationHint,
                    tolerance: tolerance
                )
                if let id = candidate?.id {
                    return id
                }
            } catch {
                self.log.warning("playlist.import.lookupFailed", [
                    "step": "metadata",
                    "error": String(reflecting: error),
                ])
            }
        }

        return nil
    }

    /// A lookup by file URL whose failure is logged rather than read as "not
    /// in the library": an import report that calls a track missing when the
    /// database errored sends the user looking for the wrong thing (#492).
    private func trackID(fileURL: String, step: String) async -> Int64? {
        do {
            return try await self.trackRepo.fetchOne(fileURL: fileURL)?.id
        } catch {
            self.log.warning("playlist.import.lookupFailed", [
                "step": step,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }
}
