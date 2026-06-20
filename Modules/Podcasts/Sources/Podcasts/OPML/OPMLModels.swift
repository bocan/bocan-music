import Foundation

// MARK: - OPMLEntry

/// A single feed entry parsed from an OPML `<outline>`. Feed content (the title)
/// is captured verbatim and never localized.
public struct OPMLEntry: Sendable, Hashable {
    public var feedURL: URL
    public var title: String
    public var htmlURL: URL?

    public init(feedURL: URL, title: String, htmlURL: URL? = nil) {
        self.feedURL = feedURL
        self.title = title
        self.htmlURL = htmlURL
    }
}

// MARK: - OPMLImportItem

/// One line item in an import summary: a feed and the reason it landed in its
/// bucket. `reason` is a human-readable, lower-module-owned string (a
/// `PodcastsError` description for failures).
public struct OPMLImportItem: Sendable, Hashable {
    public var title: String
    public var feedURL: URL
    public var reason: String

    public init(title: String, feedURL: URL, reason: String) {
        self.title = title
        self.feedURL = feedURL
        self.reason = reason
    }
}

// MARK: - OPMLImportSummary

/// The outcome of an OPML import, partitioned into outcome buckets. Intra-file
/// duplicates are dropped silently (kept first) and are not represented here.
public struct OPMLImportSummary: Sendable, Hashable {
    public var succeeded: [OPMLImportItem]
    public var alreadySubscribed: [OPMLImportItem]
    public var failed: [OPMLImportItem]

    public init(
        succeeded: [OPMLImportItem] = [],
        alreadySubscribed: [OPMLImportItem] = [],
        failed: [OPMLImportItem] = []
    ) {
        self.succeeded = succeeded
        self.alreadySubscribed = alreadySubscribed
        self.failed = failed
    }

    /// Feeds actually attempted (succeeded + failed); excludes skipped duplicates
    /// and already-subscribed feeds.
    public var totalAttempted: Int {
        self.succeeded.count + self.failed.count
    }
}
