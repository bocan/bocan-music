import Acoustics
import Foundation
import Observability
import Persistence

// MARK: - FingerprintService

/// Orchestrates the full acoustic-identification pipeline:
///   1. Fingerprint the file via `Fingerprinter` (fpcalc).
///   2. Submit to AcoustID → ranked result list.
///   3. Enrich candidates above 0.5 confidence via MusicBrainz recording lookup.
///   4. Persist the fingerprint + AcoustID ID to the DB (always).
///   5. Return sorted `IdentificationCandidate` array to the caller.
///
/// The two `RateLimiter` instances are created here and injected into their
/// respective clients so that all call sites share a single rate budget.
public actor FingerprintService {
    // MARK: - Dependencies

    private let fingerprinter: Fingerprinter
    private let acoustidClient: AcoustIDClient
    private let mbClient: Acoustics.MusicBrainzClient
    private let store: FingerprintStore
    private let log = AppLogger.make(.network)

    // MARK: - Init

    /// - Parameters:
    ///   - database: Used to persist fingerprint results.
    ///   - fpcalcURL: Path to the bundled `fpcalc` binary.
    ///   - acoustIDAPIKey: Read from `Bundle.main.infoDictionary["AcoustIDAPIKey"]`.
    ///   - userAgent: Must follow MusicBrainz policy: `AppName/Version ( contact )`.
    public init(
        database: Database,
        fpcalcURL: URL,
        acoustIDAPIKey: String,
        userAgent: String = "Bòcan/1.0 ( https://github.com/bocan/bocan-music )"
    ) {
        // Single shared rate-limiter instances — one per service.
        let acoustIDLimiter = Acoustics.RateLimiter(maxRequests: 3, per: 1.0)
        let mbLimiter = Acoustics.RateLimiter(maxRequests: 1, per: 1.0)

        self.fingerprinter = Fingerprinter(fpcalcURL: fpcalcURL)
        self.acoustidClient = AcoustIDClient(apiKey: acoustIDAPIKey, rateLimiter: acoustIDLimiter)
        self.mbClient = Acoustics.MusicBrainzClient(userAgent: userAgent, rateLimiter: mbLimiter)
        self.store = FingerprintStore(database: database)
    }

    // MARK: - Public API

    /// Identifies `track` and returns candidates sorted by confidence (highest first).
    ///
    /// The fingerprint and AcoustID ID are always written to the DB, even if the
    /// returned array is empty or the caller does not apply any candidate.
    public func identify(track: Track) async throws -> [IdentificationCandidate] {
        guard let trackID = track.id else {
            throw LibraryError.missingID
        }

        self.log.debug("fingerprint.identify.start", ["trackID": trackID])

        // Resolve file URL — prefer security-scoped bookmark if available.
        let (fileURL, scopedURL) = try resolveFileURL(for: track)
        defer {
            // Always pair start with stop. Holding the scope for the lifetime of
            // identify() guarantees fpcalc, AcoustID, and MusicBrainz work all see
            // the file, and prevents handle-table exhaustion across many calls.
            scopedURL?.stopAccessingSecurityScopedResource()
        }

        // 1. Compute fingerprint.
        let (fingerprint, duration) = try await self.fingerprinter.fingerprint(url: fileURL)

        try Task.checkCancellation()

        // 2. AcoustID lookup.
        let acoustidResults = try await self.acoustidClient.lookup(
            fingerprint: fingerprint,
            duration: duration
        )

        // 3. Persist fingerprint + AcoustID ID regardless of what the user picks.
        let topAcoustID = acoustidResults.first?.id
        try await self.store.save(trackID: trackID, fingerprint: fingerprint, acoustidID: topAcoustID)

        try Task.checkCancellation()

        // 4. Enrich candidates above the 0.5 confidence threshold with MusicBrainz data.
        var candidates: [IdentificationCandidate] = []
        for result in acoustidResults {
            try Task.checkCancellation()
            let candidate = try await self.buildCandidate(from: result)
            candidates.append(contentsOf: candidate)
        }

        self.log.debug("fingerprint.identify.done", [
            "trackID": trackID,
            "candidates": candidates.count,
        ])
        return candidates.sorted { $0.score > $1.score }
    }

    // MARK: - Private

    private func resolveFileURL(for track: Track) throws -> (url: URL, scoped: URL?) {
        if let bookmark = track.fileBookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Start the security scope. The caller must `stopAccessingSecurityScopedResource()`
            // on the returned `scoped` URL once it is finished — `identify()` does this via
            // `defer` so the scope lifetime is bounded to the call.
            guard url.startAccessingSecurityScopedResource() else {
                throw LibraryError.bookmarkStale(url)
            }
            return (url, url)
        }
        guard let url = URL(string: track.fileURL) else {
            throw LibraryError.invalidFileURL(track.fileURL)
        }
        return (url, nil)
    }

    /// Builds zero or more `IdentificationCandidate` from a single AcoustID result.
    ///
    /// Results below 0.5 confidence are included in the list with a visual warning
    /// in the UI — never silently discarded — but are never auto-applied.
    private func buildCandidate(from result: AcoustIDResult) async throws -> [IdentificationCandidate] {
        guard let recordings = result.recordings, !recordings.isEmpty else {
            // AcoustID result with no attached recordings — surface the score only.
            return []
        }

        var candidates: [IdentificationCandidate] = []

        for recording in recordings {
            try Task.checkCancellation()
            let release = recording.releases?.first
            let artist = recording.artists?.map(\.name).joined(separator: ", ") ?? ""

            // Try to enrich with full MusicBrainz data for confident matches.
            if result.score >= 0.5 {
                if let mbRecording = try? await self.mbClient.fetchRecording(mbid: recording.id) {
                    let bestRelease = mbRecording.releases?.first
                    let candidate = IdentificationCandidate(
                        id: result.id,
                        score: result.score,
                        mbRecordingID: recording.id,
                        title: mbRecording.title,
                        artist: mbRecording.artistName,
                        album: bestRelease?.title,
                        albumArtist: bestRelease?.albumArtistName,
                        trackNumber: bestRelease?.media?.first?.tracks?.first?.trackNumber,
                        discNumber: bestRelease?.media?.first?.position,
                        year: bestRelease?.year,
                        genre: mbRecording.topGenre,
                        label: bestRelease?.labelInfo?.first?.label?.name
                    )
                    candidates.append(candidate)
                    continue
                }
            }

            // Fallback: build from AcoustID data alone.
            candidates.append(IdentificationCandidate(
                id: result.id,
                score: result.score,
                mbRecordingID: recording.id,
                title: recording.title ?? "",
                artist: artist,
                album: release?.title,
                year: release?.date?.year
            ))
        }

        return candidates
    }
}
