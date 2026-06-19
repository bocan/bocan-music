import Foundation
import Observability

/// Concurrent fan-out to Podcast Index + iTunes, merge, dedupe, and sort.
///
/// When `podcastIndex` is nil (no credentials), the service runs iTunes-only
/// and every result is sourced `.itunes`. This is a clean expected path.
public actor PodcastSearchService {
    private let podcastIndex: PodcastIndexClient?
    private let itunes: ITunesSearchClient
    private let log: AppLogger

    public init(
        podcastIndex: PodcastIndexClient?,
        itunes: ITunesSearchClient,
        log: AppLogger = .make(.network)
    ) {
        self.podcastIndex = podcastIndex
        self.itunes = itunes
        self.log = log
    }

    /// Run both sources concurrently, merge, deduplicate, and return the combined
    /// list ordered by relevance.
    ///
    /// Never throws when at least one source succeeds. Throws
    /// ``PodcastsError/searchUnavailable(source:reason:)`` only when ALL sources fail.
    /// Returns `[]` immediately for a blank or whitespace-only query.
    public func search(term: String) async throws -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try Task.checkCancellation()

        self.log.debug("search.start", ["term": trimmed])
        let start = Date()

        // Capture refs before spawning child tasks (Sendable actors, safe to capture).
        let pi = self.podcastIndex
        let it = self.itunes

        // Fan out both sources with an 8s per-source soft timeout.
        async let piOutcome: Result<[PodcastSearchResult], Error> = Self.withTimeout(8) {
            guard let pi else { return [] }
            return try await pi.search(term: trimmed)
        }
        async let itOutcome: Result<[PodcastSearchResult], Error> = Self.withTimeout(8) {
            try await it.search(term: trimmed)
        }

        let (piResult, itResult) = await (piOutcome, itOutcome)

        // Capture feeds; log warnings for individual source failures.
        let piFeeds: [PodcastSearchResult]
        switch piResult {
        case let .success(feeds): piFeeds = feeds
        case let .failure(err):
            piFeeds = []
            self.log.warning("search.pi.failed", ["term": trimmed, "error": String(reflecting: err)])
        }

        let itFeeds: [PodcastSearchResult]
        switch itResult {
        case let .success(feeds): itFeeds = feeds
        case let .failure(err):
            itFeeds = []
            self.log.warning("search.itunes.failed", ["term": trimmed, "error": String(reflecting: err)])
        }

        // Throw only when every configured source failed.
        if case .failure = piResult, case .failure = itResult {
            throw PodcastsError.searchUnavailable(source: "all", reason: "all sources failed or timed out")
        }

        let results = Self.merge(piFeeds: piFeeds, itFeeds: itFeeds)
        self.log.debug("search.end", ["ms": -start.timeIntervalSinceNow * 1000, "results": results.count])
        return results
    }

    /// Enrich channel metadata for the detail view.
    ///
    /// Prefers Podcast Index's `byfeedurl` endpoint; falls back to iTunes lookup;
    /// falls back to returning the existing result unchanged. Never throws.
    public func detail(for result: PodcastSearchResult) async -> PodcastSearchResult {
        if let pi = podcastIndex {
            do {
                if let enriched = try await pi.podcast(byFeedURL: result.feedURL) {
                    var blended = Self.blend(preferred: enriched, secondary: result)
                    blended.itunesCollectionID = blended.itunesCollectionID ?? result.itunesCollectionID
                    return blended
                }
            } catch {
                self.log.warning("detail.pi.failed", [
                    "url": result.feedURL.absoluteString,
                    "error": String(reflecting: error),
                ])
            }
        } else if let collectionID = result.itunesCollectionID {
            do {
                if let enriched = try await itunes.lookup(collectionID: collectionID) {
                    return Self.blend(preferred: result, secondary: enriched)
                }
            } catch {
                self.log.warning("detail.itunes.failed", [
                    "collectionID": collectionID,
                    "error": String(reflecting: error),
                ])
            }
        }
        return result
    }

    // MARK: - Merge + dedupe

    static func merge(
        piFeeds: [PodcastSearchResult],
        itFeeds: [PodcastSearchResult]
    ) -> [PodcastSearchResult] {
        // Step 1: primary dedupe by canonical feed URL.
        var byKey: [String: PodcastSearchResult] = [:]
        var piOrder: [String: Int] = [:]
        var itOrder: [String: Int] = [:]

        for (i, r) in piFeeds.enumerated() {
            byKey[r.canonicalFeedKey] = r
            piOrder[r.canonicalFeedKey] = i
        }
        for (i, r) in itFeeds.enumerated() {
            itOrder[r.canonicalFeedKey] = i
            if let existing = byKey[r.canonicalFeedKey] {
                byKey[r.canonicalFeedKey] = self.blend(preferred: existing, secondary: r)
            } else {
                byKey[r.canonicalFeedKey] = r
            }
        }

        // Step 2: secondary dedupe by normalized title + author.
        // Sorts PI results first so the PI member wins title+author collisions.
        let presorted = byKey.values.sorted {
            (piOrder[$0.canonicalFeedKey] ?? Int.max) < (piOrder[$1.canonicalFeedKey] ?? Int.max)
        }

        var merged: [PodcastSearchResult] = []
        var seenTitleAuthor: [String: Int] = [:]

        for r in presorted {
            let ta = self.normalise(r.title) + "\u{1}" + self.normalise(r.author ?? "")
            if let existingIdx = seenTitleAuthor[ta] {
                merged[existingIdx] = self.blend(preferred: merged[existingIdx], secondary: r)
                // Carry over iTunes order so sorting stays correct.
                if let newItOrd = itOrder[r.canonicalFeedKey] {
                    let winnerKey = merged[existingIdx].canonicalFeedKey
                    if itOrder[winnerKey] == nil { itOrder[winnerKey] = newItOrd }
                }
            } else {
                seenTitleAuthor[ta] = merged.count
                merged.append(r)
            }
        }

        // Step 3: sort -- both-source first (PI order), PI-only second, iTunes-only last.
        return merged.sorted { lhs, rhs in
            let lg = self.sortGroup(lhs)
            let rg = self.sortGroup(rhs)
            guard lg == rg else { return lg < rg }
            if lg == 2 {
                return (itOrder[lhs.canonicalFeedKey] ?? Int.max)
                    < (itOrder[rhs.canonicalFeedKey] ?? Int.max)
            }
            return (piOrder[lhs.canonicalFeedKey] ?? Int.max)
                < (piOrder[rhs.canonicalFeedKey] ?? Int.max)
        }
    }

    /// Merge `secondary` into `preferred`, keeping `preferred`'s non-nil fields.
    static func blend(
        preferred: PodcastSearchResult,
        secondary: PodcastSearchResult
    ) -> PodcastSearchResult {
        var r = preferred
        r.sources.formUnion(secondary.sources)
        if r.author == nil { r.author = secondary.author }
        if r.artworkURL == nil { r.artworkURL = secondary.artworkURL }
        if r.description == nil { r.description = secondary.description }
        if r.episodeCount == nil { r.episodeCount = secondary.episodeCount }
        if r.lastPublishedAt == nil { r.lastPublishedAt = secondary.lastPublishedAt }
        if r.categories.isEmpty { r.categories = secondary.categories }
        if r.podcastIndexID == nil { r.podcastIndexID = secondary.podcastIndexID }
        if r.itunesCollectionID == nil { r.itunesCollectionID = secondary.itunesCollectionID }
        // Prefer https feed URL.
        if secondary.feedURL.scheme?.lowercased() == "https",
           r.feedURL.scheme?.lowercased() != "https" {
            r.feedURL = secondary.feedURL
        }
        return r
    }

    private static func sortGroup(_ r: PodcastSearchResult) -> Int {
        if r.sources.count > 1 { return 0 }
        if r.sources.contains(.podcastIndex) { return 1 }
        return 2
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    // MARK: - Timeout helper

    /// Run `work` with a per-source timeout. Never throws; wraps the outcome in
    /// `Result` so the caller can differentiate failure from empty results.
    private nonisolated static func withTimeout<T: Sendable>(
        _ seconds: Double,
        work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do {
            let value = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw PodcastsError.searchUnavailable(
                        source: "timeout",
                        reason: "source did not respond within \(Int(seconds))s"
                    )
                }
                guard let result = try await group.next() else {
                    throw PodcastsError.searchUnavailable(source: "timeout", reason: "no result")
                }
                group.cancelAll()
                return result
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}
