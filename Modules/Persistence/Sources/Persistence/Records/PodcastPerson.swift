import Foundation

/// A Podcasting 2.0 `podcast:person` credit: a host, co-host, guest, producer, or any
/// other role from the Podcast Taxonomy Project.
///
/// Feed content (never user-owned), stored as JSON in the `persons_json` column of
/// `podcasts` (show-level "regular" people) and `podcast_episodes` (episode-level).
/// Per the spec, an episode's people *wholly replace* the show's people for that
/// episode, so resolve the effective list with `PodcastPerson.effective(episode:show:)`.
public struct PodcastPerson: Codable, Equatable, Hashable, Sendable {
    /// Full name or alias (the element text; required, the spec caps it at 128 chars).
    public var name: String
    /// Taxonomy role, e.g. "host", "guest", "producer". Stored as given (the spec is
    /// case-insensitive). `nil` means the spec default of "host".
    public var role: String?
    /// Taxonomy group, e.g. "cast", "writing", "visuals". `nil` means the default "cast".
    public var group: String?
    /// Avatar image URL (validated http/https), or `nil`.
    public var imageURL: String?
    /// Link to a profile/homepage (validated http/https), or `nil`.
    public var href: String?

    public init(
        name: String,
        role: String? = nil,
        group: String? = nil,
        imageURL: String? = nil,
        href: String? = nil
    ) {
        self.name = name
        self.role = role
        self.group = group
        self.imageURL = imageURL
        self.href = href
    }

    // MARK: - JSON column helpers

    /// Decodes the `persons_json` blob; tolerant (returns `[]` on nil/garbage).
    public static func decodeList(_ data: Data?) -> [Self] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    /// Encodes a person list for storage; `nil` for an empty list so the column
    /// stays NULL rather than holding an empty array.
    public static func encodeList(_ list: [Self]) -> Data? {
        list.isEmpty ? nil : try? JSONEncoder().encode(list)
    }

    /// The effective credits for an episode: the episode's own people when it has
    /// any (they replace the show's per the spec), otherwise the show's people.
    public static func effective(episode: [Self], show: [Self]) -> [Self] {
        episode.isEmpty ? show : episode
    }
}
