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

    /// File extensions the reader accepts (lowercase, no leading dot): what
    /// TagLib parses, plus the raw Dolby extensions it has no type for, which
    /// `read(from:)` serves through AVFoundation instead.
    public static let supportedExtensions: Set = [
        "mp3", "mp2", "mp1", "flac", "ogg", "opus", "m4a", "m4b", "mp4",
        "aac", "alac", "wav", "aiff", "aif", "wv", "ape",
        "mpc", "wma", "dsf", "dff", "tta", "mka",
        "ac3", "eac3", "ec3", "dts", "au", "snd", "w64", "mkv", "webm",
    ]

    /// Raw Dolby files with no container. TagLib has no AC-3 or E-AC-3 type,
    /// so when it throws for one of these the properties come from
    /// AVFoundation (ADR-091 slice 3). TrueHD (`thd`, `mlp`) stays out:
    /// AVAudioFile refuses it too, so the fallback could not read it.
    static let avFoundationFallbackExtensions: Set = ["ac3", "eac3", "ec3"]

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
            let tagLibError = MetadataError.unreadableFile(url, error.localizedDescription)
            guard Self.avFoundationFallbackExtensions.contains(url.pathExtension.lowercased()) else {
                throw tagLibError
            }
            return try self.readWithAVFoundation(from: url, tagLibError: tagLibError)
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
        tags.isCompilation = raw.isCompilation
        tags.sortTitle = raw.sortTitle.map { String($0) }
        tags.dateText = raw.dateText.map { String($0) }
        tags.sortArtist = raw.sortArtist.map { String($0) }
        tags.sortAlbumArtist = raw.sortAlbumArtist.map { String($0) }
        tags.sortAlbum = raw.sortAlbum.map { String($0) }
        tags.lyrics = raw.lyrics.map { String($0) }
        tags.bpm = raw.bpm > 0 ? raw.bpm : nil
        tags.key = raw.key.map { String($0) }
        tags.isrc = raw.isrc.map { String($0) }
        tags.musicbrainzTrackID = raw.musicbrainzTrackID.map { String($0) }
        tags.musicbrainzRecordingID = raw.musicbrainzRecordingID.map { String($0) }
        tags.musicbrainzArtistID = raw.musicbrainzArtistID.map { String($0) }
        tags.musicbrainzAlbumArtistID = raw.musicbrainzAlbumArtistID.map { String($0) }
        tags.musicbrainzReleaseID = raw.musicbrainzReleaseID.map { String($0) }
        tags.musicbrainzReleaseGroupID = raw.musicbrainzReleaseGroupID.map { String($0) }
        tags.replayGain = rg
        tags.coverArt = extracted
        // Lift the TagLib PropertyMap (NSDictionary<NSString,NSArray<NSString>>)
        // into a Swift [String: [String]]. Bridging is shallow but copies the
        // strings, so the result is fully Sendable.
        var ext: [String: [String]] = [:]
        ext.reserveCapacity(raw.extendedTags.count)
        for (key, values) in raw.extendedTags {
            ext[String(key)] = values.map { String($0) }
        }
        tags.extendedTags = ext

        // Release type needs the full multi-valued list, so it is derived
        // after extendedTags: prefer a known MusicBrainz type anywhere in the
        // list over a junk first value (see TrackTags.primaryReleaseType).
        let releaseTypeValues = tags.extendedTags["RELEASETYPE"] ?? tags.extendedTags["MUSICBRAINZ_ALBUMTYPE"]
            ?? raw.releaseType.map { [String($0)] } ?? []
        tags.releaseType = TrackTags.primaryReleaseType(from: releaseTypeValues)
        tags.duration = raw.duration
        tags.sampleRate = raw.sampleRate > 0 ? Int(raw.sampleRate) : nil
        tags.bitrate = raw.bitrate > 0 ? Int(raw.bitrate) : nil
        tags.channels = raw.channels > 0 ? Int(raw.channels) : nil
        tags.bitDepth = raw.bitDepth > 0 ? Int(raw.bitDepth) : nil
        return tags
    }

    /// The one escape hatch from TagLib: a raw Dolby file's properties from
    /// AVFoundation, named after the file. If AVFoundation refuses it too,
    /// the caller gets TagLib's error unchanged; it is why the file was
    /// rejected, and the reason the scan log already reports.
    private func readWithAVFoundation(from url: URL, tagLibError: MetadataError) throws -> TrackTags {
        let properties: AVFoundationProperties
        do {
            properties = try AVFoundationProperties(url: url)
        } catch {
            self.log.warning("taglib.read.avfoundationFallback.failed", [
                "path": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
            throw tagLibError
        }
        self.log.debug("taglib.read.avfoundationFallback", [
            "path": url.lastPathComponent,
            "channels": properties.channels,
            "sampleRate": properties.sampleRate,
        ])
        return properties.tags(for: url)
    }
}
