import Foundation
import GRDB

/// A cached, re-fetchable Podcasting 2.0 chapters document, stored in
/// `podcast_episode_chapters`.
///
/// This is a cache, not user state: the raw `content` is the document as the
/// publisher served it, parsed to chapters at read time and passed through
/// unchanged by Phone Sync. Keyed by the stable `(podcast_id, guid)` identity;
/// `ON DELETE CASCADE` with the show.
///
/// Conforms to `PersistableRecord` (not `MutablePersistableRecord`): the primary
/// key is the composite `(podcast_id, guid)`, so there is no rowid to write back.
public struct PodcastChapters: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "podcast_episode_chapters"

    // MARK: - Properties

    public var podcastID: Int64
    public var guid: String
    /// The raw fetched JSON body, verbatim.
    public var content: String
    /// The episode `chapters_url` the body was fetched from.
    public var sourceURL: String

    // MARK: - Init

    public init(podcastID: Int64, guid: String, content: String, sourceURL: String) {
        self.podcastID = podcastID
        self.guid = guid
        self.content = content
        self.sourceURL = sourceURL
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case podcastID = "podcast_id"
        case guid
        case content
        case sourceURL = "source_url"
    }
}
