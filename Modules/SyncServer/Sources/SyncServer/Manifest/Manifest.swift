import Foundation

/// The Phone Sync manifest (sync-protocol.md section 7). Encoded to JSON for
/// `GET /v1/manifest`; the field names are fixed by the protocol. Optional
/// properties are omitted when nil (Swift's synthesized `encodeIfPresent`),
/// matching the wire format. `Codable` + `Equatable` so the golden-fixture parity
/// test can decode and compare.
struct Manifest: Codable, Equatable {
    var protocolVersion: Int
    var serverId: String
    var serverName: String
    var generation: Int
    var generatedAt: String
    var tracks: [ManifestTrack]
    var playlists: [ManifestPlaylist]
    var podcasts: [ManifestPodcast]
    var episodes: [ManifestEpisode]
}

struct ManifestTrack: Codable, Equatable {
    var id: Int64
    var relPath: String
    var size: Int64
    var sha256: String
    var format: String
    var durationMs: Int
    var title: String?
    var artist: String?
    var artistId: Int64?
    var albumArtist: String?
    var albumArtistId: Int64?
    var album: String?
    var albumId: Int64?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: Int?
    var genre: String?
    var composer: String?
    var bpm: Double?
    var rating: Int
    var loved: Bool
    var sampleRate: Int?
    var bitDepth: Int?
    var bitrate: Int?
    var channelCount: Int?
    var isLossless: Bool?
    var replayGain: ManifestReplayGain?
    var artworkHash: String?
    var lyricsHash: String?
    var clip: ManifestClip?
}

struct ManifestReplayGain: Codable, Equatable {
    var trackGain: Double
    var trackPeak: Double?
    var albumGain: Double?
    var albumPeak: Double?
}

struct ManifestClip: Codable, Equatable {
    var sourceTrackId: Int64
    var startMs: Int64
    var endMs: Int64
}

struct ManifestPlaylist: Codable, Equatable {
    var id: Int64
    var name: String
    var kind: String // manual | smart | folder
    var parentId: Int64?
    var sortOrder: Int?
    var accentColor: String?
    var artworkHash: String?
    var trackIds: [Int64]
}

struct ManifestPodcast: Codable, Equatable {
    var id: Int64
    var title: String
    var author: String?
    var descriptionHtml: String?
    var artworkHash: String?
    var playbackSpeed: Double?
}

struct ManifestEpisode: Codable, Equatable {
    var id: String
    var podcastId: Int64
    var guid: String
    var title: String
    var publishedAt: String?
    var durationMs: Int?
    var descriptionHtml: String?
    var relPath: String
    var size: Int64
    var sha256: String
    var hasChapters: Bool
    var playPositionMs: Int
    var playState: String
}
