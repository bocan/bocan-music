import Foundation
import Persistence

// MARK: - AudioSourceFormat

/// Describes the native audio format of a file, used for gapless compatibility checks.
///
/// Two items are gapless-compatible when `isGaplessCompatible(with:)` returns `true`
/// — i.e. they share sample rate and channel count, so the same player node and
/// output format can render both without a converter restart.
public struct AudioSourceFormat: Sendable, Hashable, Codable {
    public let sampleRate: Double
    public let bitDepth: Int
    public let channelCount: Int
    public let isInterleaved: Bool
    public let codec: String

    /// `true` when it is safe to stitch this format with `other` on the same
    /// `AVAudioPlayerNode` without engaging `FormatBridge`.
    ///
    /// Requirements:
    /// - Same sample rate (AVAudioPlayerNode resamples only at the graph level)
    /// - Same channel count
    /// Bit depth does not matter because the engine uses Float32 internally.
    public func isGaplessCompatible(with other: AudioSourceFormat) -> Bool {
        self.sampleRate == other.sampleRate && self.channelCount == other.channelCount
    }

    public init(
        sampleRate: Double,
        bitDepth: Int,
        channelCount: Int,
        isInterleaved: Bool,
        codec: String
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.codec = codec
    }
}

// MARK: - RepeatMode

/// Controls what happens when the last item in the queue finishes.
public enum RepeatMode: String, Sendable, Codable, CaseIterable {
    /// Stop when the queue is exhausted.
    case off
    /// Loop back to the start of the queue.
    case all
    /// Replay the current item indefinitely.
    case one
}

// MARK: - ShuffleState

/// Records whether shuffle is active and, if so, what seed was used.
/// The seed makes the shuffle order reproducible (important for "unshuffle" restore).
public enum ShuffleState: Sendable, Codable, Equatable {
    case off
    case on(seed: UInt64)
}

// MARK: - QueueChange

/// Incremental mutations emitted by `PlaybackQueue` via `AsyncStream<QueueChange>`.
public enum QueueChange: Sendable {
    case reset(items: [QueueItem], currentIndex: Int?)
    case appended(items: [QueueItem])
    case insertedNext(items: [QueueItem])
    case removed(ids: [QueueItem.ID])
    case moved(fromIndex: Int, toIndex: Int)
    case cleared
    case currentChanged(newIndex: Int?, previousIndex: Int?)
    case repeatChanged(RepeatMode)
    case shuffleChanged(ShuffleState)
    case stopAfterCurrentChanged(Bool)
}

// MARK: - QueueItem

/// A single entry in the playback queue.
///
/// `id` is queue-local (a new `UUID` each time the item is enqueued, even for
/// the same track). `trackID` is the database row identifier.
///
/// `bookmark` is the security-scoped bookmark allowing sandboxed file access
/// after the original open-panel scope expires. It may be `nil` for items created
/// in tests or when no bookmark was stored (fallback: parse `fileURL` directly).
public struct QueueItem: Sendable, Identifiable, Hashable, Codable {
    // MARK: - Core fields (per spec)

    public let id: UUID
    public let trackID: Int64
    public let bookmark: BookmarkBlob?
    public let fileURL: String
    public let duration: TimeInterval
    public let sourceFormat: AudioSourceFormat

    /// Where the playable bytes live: a local security-scoped bookmark or a
    /// remote Subsonic server. Added in queue schema v2; defaults to
    /// `.localBookmark(bookmark?.data ?? Data())` for callers that don't
    /// pass it explicitly so existing call sites keep working.
    public let playableSource: PlayableSource

    // MARK: - Display metadata (snapshot at enqueue time)

    public let title: String?
    public let artistName: String?
    public let albumName: String?
    public let genre: String?

    // MARK: - Smart-shuffle hints (snapshot of track state at enqueue time)

    public let rating: Int
    public let loved: Bool
    public let playCount: Int
    public let excludedFromShuffle: Bool
    public let lastPlayedAt: Int64?
    public let albumID: Int64?
    public let artistID: Int64?

    // MARK: - CUE / segment offsets

    /// Start position within the source audio file (milliseconds).
    /// Non-nil only for virtual tracks derived from a CUE sheet.
    public let startOffsetMs: Int64?
    /// End position within the source audio file (milliseconds).
    /// Non-nil only for virtual tracks derived from a CUE sheet that are not the last track.
    public let endOffsetMs: Int64?
    /// The underlying physical audio file URL string for CUE virtual tracks.
    /// `nil` for ordinary tracks (where `fileURL` is already the playable file).
    public let sourceFileURL: String?

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        trackID: Int64,
        bookmark: BookmarkBlob?,
        fileURL: String,
        duration: TimeInterval,
        sourceFormat: AudioSourceFormat,
        title: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        genre: String? = nil,
        rating: Int = 0,
        loved: Bool = false,
        playCount: Int = 0,
        excludedFromShuffle: Bool = false,
        lastPlayedAt: Int64? = nil,
        albumID: Int64? = nil,
        artistID: Int64? = nil,
        startOffsetMs: Int64? = nil,
        endOffsetMs: Int64? = nil,
        sourceFileURL: String? = nil,
        playableSource: PlayableSource? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.bookmark = bookmark
        self.fileURL = fileURL
        self.duration = duration
        self.sourceFormat = sourceFormat
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.genre = genre
        self.rating = rating
        self.loved = loved
        self.playCount = playCount
        self.excludedFromShuffle = excludedFromShuffle
        self.lastPlayedAt = lastPlayedAt
        self.albumID = albumID
        self.artistID = artistID
        self.startOffsetMs = startOffsetMs
        self.endOffsetMs = endOffsetMs
        self.sourceFileURL = sourceFileURL
        self.playableSource = playableSource ?? .localBookmark(bookmark?.data ?? Data())
    }

    // MARK: - Helpers

    /// Returns the playable URL, preferring the security-scoped bookmark.
    /// The caller is responsible for calling `stopAccessingSecurityScopedResource()`.
    public func resolvedURL() throws -> URL {
        if let bookmark {
            return try bookmark.resolve()
        }
        guard let url = URL(string: fileURL) else {
            throw PlaybackError.bookmarkResolutionFailed(
                trackID: self.trackID,
                underlying: URLError(.badURL)
            )
        }
        return url
    }

    /// `true` when this item is a virtual CUE-derived track that requires
    /// segment-offset handling during playback.
    public var isCUETrack: Bool {
        self.startOffsetMs != nil
    }

    // MARK: - Hashable / Equatable (identity only)

    public static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

// MARK: - QueueItem + Track factory

public extension QueueItem {
    /// Build a `QueueItem` from a `Track` row.
    static func make(from track: Track, artistName: String? = nil) -> QueueItem {
        let fmt = AudioSourceFormat(
            sampleRate: Double(track.sampleRate ?? 44100),
            bitDepth: track.bitDepth ?? 16,
            channelCount: track.channelCount ?? 2,
            isInterleaved: false,
            codec: track.fileFormat
        )
        let blob: BookmarkBlob? = track.fileBookmark.map { BookmarkBlob(data: $0) }
        return QueueItem(
            trackID: track.id ?? -1,
            bookmark: blob,
            fileURL: track.fileURL,
            duration: track.duration,
            sourceFormat: fmt,
            title: track.title,
            artistName: artistName,
            genre: track.genre,
            rating: track.rating,
            loved: track.loved,
            playCount: track.playCount,
            excludedFromShuffle: track.excludedFromShuffle,
            lastPlayedAt: track.lastPlayedAt,
            albumID: track.albumID,
            artistID: track.artistID,
            startOffsetMs: track.startOffsetMs,
            endOffsetMs: track.endOffsetMs,
            sourceFileURL: track.sourceFileURL
        )
    }
}
