import Foundation

/// A Podcasting 2.0 `podcast:remoteItem` inside a channel-level `<podcast:podroll>`:
/// a show the publisher recommends.
///
/// Feed content (never user-owned), stored as JSON in the `podroll_json` column of
/// `podcasts`. Only `feedURL` is required; `feedGUID` and `title` are optional and
/// frequently absent (most feeds, including Podcast Index's own, ship only the URL),
/// in which case the UI resolves the show's title and artwork from the feed itself.
public struct PodcastPodrollItem: Codable, Equatable, Hashable, Sendable {
    /// The recommended show's feed URL (validated http/https).
    public var feedURL: String
    /// The recommended show's `podcast:guid`, when the feed supplies it.
    public var feedGUID: String?
    /// A display title, when the `remoteItem` carries one; usually `nil`.
    public var title: String?

    public init(feedURL: String, feedGUID: String? = nil, title: String? = nil) {
        self.feedURL = feedURL
        self.feedGUID = feedGUID
        self.title = title
    }

    // MARK: - JSON column helpers

    /// Decodes the `podroll_json` blob; tolerant (returns `[]` on nil/garbage).
    public static func decodeList(_ data: Data?) -> [Self] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    /// Encodes a podroll list for storage; `nil` for an empty list so the column
    /// stays NULL rather than holding an empty array.
    public static func encodeList(_ list: [Self]) -> Data? {
        list.isEmpty ? nil : try? JSONEncoder().encode(list)
    }
}
