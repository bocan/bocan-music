import Foundation
import GRDB

/// One row of the transcode ledger (`sync_transcodes`, ADR-088): the artifact
/// derived from `sourceContentHash` for one track under one preset.
///
/// `preset` is an opaque string here; the preset vocabulary is owned by the
/// AudioEngine module and Persistence stays codec-agnostic. The row describes
/// the bytes the sync server will serve for the track; it remains authoritative
/// even after the artifact file itself has been released from disk.
public struct SyncTranscode: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sync_transcodes"

    /// The track this artifact belongs to.
    public var trackID: Int64
    /// The transcode preset raw value (e.g. "mp3_320").
    public var preset: String
    /// The track's `content_hash` the artifact was derived from; the row is
    /// valid only while this still matches the track.
    public var sourceContentHash: String
    /// SHA-256 of the artifact bytes, advertised as the manifest `sha256`.
    public var sha256: String
    /// Artifact size in bytes, advertised as the manifest `size`.
    public var size: Int64
    /// Artifact bitrate in kbps, when known.
    public var bitrate: Int?
    /// Unix seconds when the artifact was encoded.
    public var createdAt: Int64
    /// Unix seconds when a file response last delivered the artifact through
    /// EOF; `nil` until then. The release sweep keys off this.
    public var servedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case preset
        case sourceContentHash = "source_content_hash"
        case sha256
        case size
        case bitrate
        case createdAt = "created_at"
        case servedAt = "served_at"
    }

    public init(
        trackID: Int64,
        preset: String,
        sourceContentHash: String,
        sha256: String,
        size: Int64,
        createdAt: Int64,
        bitrate: Int? = nil,
        servedAt: Int64? = nil
    ) {
        self.trackID = trackID
        self.preset = preset
        self.sourceContentHash = sourceContentHash
        self.sha256 = sha256
        self.size = size
        self.bitrate = bitrate
        self.createdAt = createdAt
        self.servedAt = servedAt
    }
}
