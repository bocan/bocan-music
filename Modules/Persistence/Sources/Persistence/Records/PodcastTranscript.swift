import Foundation
import GRDB

/// The on-the-wire format of a cached transcript body, stored as the `format`
/// discriminator on `PodcastTranscript`.
public enum TranscriptFormat: String, Codable, Sendable, CaseIterable {
    case vtt
    case srt
    case json
    case html
    case plain

    /// Best-effort format inference from a transcript URL extension and/or the
    /// HTTP `Content-Type`. The MIME type wins when present; otherwise the path
    /// extension; defaulting to `.plain` so an unknown body still renders.
    public static func infer(fromURL url: URL, mime: String?) -> Self {
        if let mime = mime?.lowercased() {
            if mime.contains("vtt") { return .vtt }
            if mime.contains("srt") || mime.contains("subrip") { return .srt }
            if mime.contains("json") { return .json }
            if mime.contains("html") { return .html }
            if mime.contains("text/plain") { return .plain }
        }
        switch url.pathExtension.lowercased() {
        case "vtt":
            return .vtt

        case "srt":
            return .srt

        case "json":
            return .json

        case "html", "htm":
            return .html

        default:
            return .plain
        }
    }
}

/// A cached, re-fetchable episode transcript body, stored in
/// `podcast_episode_transcript`.
///
/// This is a cache, not user state: the raw `content` is the lossless source of
/// truth (a later parser fix re-parses old caches with no migration), parsed to
/// cues lazily at view time. Keyed by the stable `(podcast_id, guid)` identity;
/// `ON DELETE CASCADE` with the show. Cleaned 30 days after the episode is played
/// (see `TranscriptRepository.deletePlayedOlderThan`).
///
/// Conforms to `PersistableRecord` (not `MutablePersistableRecord`): the primary
/// key is the composite `(podcast_id, guid)`, so there is no rowid to write back.
public struct PodcastTranscript: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "podcast_episode_transcript"

    // MARK: - Properties

    public var podcastID: Int64
    public var guid: String
    /// The raw fetched body, verbatim. Parsed to cues at view time.
    public var content: String
    public var format: TranscriptFormat
    public var language: String?
    public var sourceURL: String
    public var fetchedAt: Double

    // MARK: - Init

    public init(
        podcastID: Int64,
        guid: String,
        content: String,
        format: TranscriptFormat,
        language: String?,
        sourceURL: String,
        fetchedAt: Double
    ) {
        self.podcastID = podcastID
        self.guid = guid
        self.content = content
        self.format = format
        self.language = language
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case podcastID = "podcast_id"
        case guid
        case content
        case format
        case language
        case sourceURL = "source_url"
        case fetchedAt = "fetched_at"
    }
}
