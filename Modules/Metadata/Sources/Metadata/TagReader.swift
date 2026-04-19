import Foundation
import Observability
import TagLibBridge

/// Reads tag metadata from local audio files via the TagLib Obj-C++ bridge.
///
/// All operations are synchronous wrt TagLib (TagLib is not async-safe), but
/// the public entry point is `async throws` so callers can hop off the main actor.
public struct TagReader: Sendable {
    private let log = AppLogger.make(.metadata)

    public init() {}

    // MARK: - Supported formats

    /// File extensions supported by TagLib (lowercase, no leading dot).
    public static let supportedExtensions: Set = [
        "mp3", "flac", "ogg", "opus", "m4a", "m4b", "mp4",
        "aac", "alac", "wav", "aiff", "aif", "wv", "ape",
        "mpc", "wma", "dsf", "dff", "tta", "mka",
    ]

    /// Returns `true` if `url`'s path extension is in `supportedExtensions`.
    public static func isSupported(_ url: URL) -> Bool {
        self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Reading

    /// Reads all available metadata from `url`.
    ///
    /// Runs on the calling thread; wrap in a `Task` or `withCheckedThrowingContinuation`
    /// when calling from the main actor.
    public func read(from url: URL) throws -> TrackTags {
        let path = url.path(percentEncoded: false)
        let raw: BOCTags
        do {
            raw = try BOCTagLibBridge.readTags(fromPath: path)
        } catch {
            throw MetadataError.unreadableFile(url, error.localizedDescription)
        }

        self.log.debug("taglib.read", ["path": url.lastPathComponent])

        // Cover art
        let rawArts: [RawCoverArt] = raw.coverArt.map {
            RawCoverArt(data: $0.data, mimeType: $0.mimeType, pictureType: Int($0.pictureType))
        }
        let extracted = CoverArtExtractor.extract(from: rawArts)

        let rg = ReplayGain(
            trackGainRaw: raw.replaygainTrackGain,
            trackPeakRaw: raw.replaygainTrackPeak,
            albumGainRaw: raw.replaygainAlbumGain,
            albumPeakRaw: raw.replaygainAlbumPeak,
            r128TrackGainRaw: raw.r128TrackGain,
            r128AlbumGainRaw: raw.r128AlbumGain
        )

        // Break the large init into groups to help the type-checker.
        var tags = TrackTags(
            title: raw.title.map { String($0) },
            artist: raw.artist.map { String($0) },
            albumArtist: raw.albumArtist.map { String($0) },
            album: raw.album.map { String($0) },
            genre: raw.genre.map { String($0) },
            composer: raw.composer.map { String($0) },
            comment: raw.comment.map { String($0) },
            year: raw.year > 0 ? Int(raw.year) : nil,
            trackNumber: raw.trackNumber > 0 ? Int(raw.trackNumber) : nil,
            trackTotal: raw.trackTotal > 0 ? Int(raw.trackTotal) : nil,
            discNumber: raw.discNumber > 0 ? Int(raw.discNumber) : nil,
            discTotal: raw.discTotal > 0 ? Int(raw.discTotal) : nil
        )
        tags.sortTitle = raw.sortTitle.map { String($0) }
        tags.sortArtist = raw.sortArtist.map { String($0) }
        tags.sortAlbumArtist = raw.sortAlbumArtist.map { String($0) }
        tags.sortAlbum = raw.sortAlbum.map { String($0) }
        tags.lyrics = raw.lyrics.map { String($0) }
        tags.bpm = raw.bpm > 0 ? raw.bpm : nil
        tags.key = raw.key.map { String($0) }
        tags.isrc = raw.isrc.map { String($0) }
        tags.musicbrainzTrackID = raw.musicbrainzTrackID.map { String($0) }
        tags.musicbrainzRecordingID = raw.musicbrainzRecordingID.map { String($0) }
        tags.musicbrainzAlbumArtistID = raw.musicbrainzAlbumArtistID.map { String($0) }
        tags.musicbrainzReleaseID = raw.musicbrainzReleaseID.map { String($0) }
        tags.musicbrainzReleaseGroupID = raw.musicbrainzReleaseGroupID.map { String($0) }
        tags.replayGain = rg
        tags.coverArt = extracted
        tags.duration = raw.duration
        tags.sampleRate = raw.sampleRate > 0 ? Int(raw.sampleRate) : nil
        tags.bitrate = raw.bitrate > 0 ? Int(raw.bitrate) : nil
        tags.channels = raw.channels > 0 ? Int(raw.channels) : nil
        tags.bitDepth = raw.bitDepth > 0 ? Int(raw.bitDepth) : nil
        return tags
    }
}
