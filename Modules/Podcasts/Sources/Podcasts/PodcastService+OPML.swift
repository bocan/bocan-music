import Foundation
import Observability
import Persistence

// MARK: - OPML import / export

/// Subscription import from and export to OPML.
public extension PodcastService {
    /// Imports an OPML subscription list: parse, dedupe (intra-file and against
    /// existing subscriptions via `FeedURL.canonicalKey`), then subscribe the
    /// remainder sequentially with progress.
    ///
    /// A malformed document throws up front, before any subscribe. Per-feed
    /// subscribe failures are collected into the summary and never abort the
    /// batch. A cancelled import returns the summary-so-far without throwing.
    /// `progress` is called `(completed, total)` after each subscribe attempt.
    func importOPML(
        data: Data,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> OPMLImportSummary {
        let entries = try OPMLReader.parse(data: data)

        // Drop intra-file duplicates by canonical key (keep first).
        var seen = Set<String>()
        let unique = entries.filter { seen.insert(FeedURL.canonicalKey($0.feedURL)).inserted }

        // Partition against existing subscriptions. A cancellation here (before any
        // subscribe) returns an empty summary rather than throwing.
        let existing: [Podcast]
        do {
            existing = try await self.subscribedPodcasts()
        } catch is CancellationError {
            return OPMLImportSummary()
        }
        let existingKeys = Set(existing.compactMap { URL(string: $0.feedURL).map(FeedURL.canonicalKey) })

        let partition = Self.partitionOPML(unique, existingKeys: existingKeys)
        var summary = partition.summary
        let toSubscribe = partition.toSubscribe

        let total = toSubscribe.count
        var completed = 0
        for entry in toSubscribe {
            if Task.isCancelled {
                self.log.info("podcast.opml.import.cancelled", ["completed": completed, "total": total])
                return summary
            }
            do {
                _ = try await self.subscribe(feedURL: entry.feedURL)
                summary.succeeded.append(OPMLImportItem(
                    title: entry.title,
                    feedURL: entry.feedURL,
                    reason: "Subscribed"
                ))
            } catch is CancellationError {
                self.log.info("podcast.opml.import.cancelled", ["completed": completed, "total": total])
                return summary
            } catch {
                let reason = (error as? PodcastsError)?.description ?? error.localizedDescription
                summary.failed.append(OPMLImportItem(title: entry.title, feedURL: entry.feedURL, reason: reason))
            }
            completed += 1
            progress?(completed, total)
        }

        self.log.info("podcast.opml.import", [
            "succeeded": summary.succeeded.count,
            "alreadySubscribed": summary.alreadySubscribed.count,
            "failed": summary.failed.count,
        ])
        return summary
    }

    /// Serializes the current subscriptions to OPML 2.0 UTF-8 `Data`. The UI
    /// owns the save panel and the atomic `data.write(to:)`.
    func exportOPML() async throws -> Data {
        let opml = try await OPMLWriter.write(self.subscribedPodcasts(), now: self.now())
        guard let data = opml.data(using: .utf8) else {
            throw PodcastsError.parseFailed(url: URL(fileURLWithPath: "opml-export"), reason: "UTF-8 encoding failed")
        }
        return data
    }
}

// MARK: - OPML helpers

extension PodcastService {
    /// Splits the de-duplicated import list against the existing subscriptions:
    /// a feed already subscribed goes into the summary, the rest are returned
    /// in file order for the subscribe loop.
    private static func partitionOPML(
        _ unique: [OPMLEntry],
        existingKeys: Set<String>
    ) -> (summary: OPMLImportSummary, toSubscribe: [OPMLEntry]) {
        var summary = OPMLImportSummary()
        var toSubscribe: [OPMLEntry] = []
        for entry in unique {
            if existingKeys.contains(FeedURL.canonicalKey(entry.feedURL)) {
                summary.alreadySubscribed.append(OPMLImportItem(
                    title: entry.title,
                    feedURL: entry.feedURL,
                    reason: "Already subscribed"
                ))
            } else {
                toSubscribe.append(entry)
            }
        }
        return (summary, toSubscribe)
    }
}
