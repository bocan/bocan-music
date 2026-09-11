import Foundation

/// The single error type for the Podcasts module.
public enum PodcastsError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case invalidFeedURL(String)
    case network(underlying: Error)
    case httpStatus(code: Int, url: URL)
    case feedTooLarge(bytes: Int)
    case parseFailed(url: URL, reason: String)
    case notAFeed(url: URL)
    case noEnclosure(episodeTitle: String)
    case searchUnavailable(source: String, reason: String)
    case notFound(feedURL: URL)
    case keychain(OSStatus, String)
    /// The feed is served over plain http only and App Transport Security
    /// refused it (its https twin failed first). Nothing to retry.
    case insecureFeedUnsupported(feedURL: URL)

    public var description: String {
        switch self {
        case let .invalidFeedURL(s):
            "Invalid feed URL: \(s)"
        case let .network(err):
            "Network error: \(err.localizedDescription)"
        case let .httpStatus(code, url):
            "HTTP \(code) from \(url)"
        case let .feedTooLarge(bytes):
            "Feed too large: \(bytes) bytes"
        case let .parseFailed(url, reason):
            "Parse failed for \(url): \(reason)"
        case let .notAFeed(url):
            "Not a recognisable feed: \(url)"
        case let .noEnclosure(title):
            "Episode has no audio enclosure: \(title)"
        case let .searchUnavailable(source, reason):
            "Search unavailable (\(source)): \(reason)"
        case let .notFound(url):
            "Podcast not found: \(url)"
        case let .keychain(status, op):
            "Keychain error \(status) during \(op)"
        case let .insecureFeedUnsupported(url):
            "This feed is only served over unencrypted http, which is not fetched: \(url)"
        }
    }

    /// Surfaced through `error.localizedDescription`. Without this conformance,
    /// the runtime renders bare cases as "Podcasts.PodcastsError error 1." and
    /// hides the underlying cause (e.g. an App Transport Security failure).
    public var errorDescription: String? {
        self.description
    }
}
