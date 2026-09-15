import AudioEngine
import Foundation
import Persistence

// MARK: - NowPlayingSourceFacts

/// What the play bar can say about the sound it is playing: the codec, how
/// much data it spends, how often it was sampled, how finely, and how many
/// channels it carries (ADR-092).
///
/// Two sources feed it. A local track brings its scanned columns; the open
/// decoder brings what it measured. `merging(_:)` puts the two together with
/// one rule, so a badge never shows a column the decoder has since
/// contradicted.
public struct NowPlayingSourceFacts: Sendable, Equatable {
    /// FFmpeg's short codec name ("flac", "eac3", "opus"), never a container
    /// name. Only a decoder can say it (#529), so a track alone leaves it nil.
    public var codec: String?
    /// The codec's profile where it has one ("Dolby Digital Plus + Dolby
    /// Atmos", "HE-AAC"). Hover-text material, not a badge of its own.
    public var codecProfile: String?
    /// Average bitrate in kbps: the track's scanned figure, or the rate a
    /// stream claims for itself.
    public var bitrateKbps: Int?
    /// Sample rate in Hz, as stored (a DSD file reports its DSD rate).
    public var sampleRateHz: Int?
    /// Bits per sample. Only ever the track's column: `AVAudioFile` reports 0
    /// for every compressed codec, so no decoder can supply it.
    public var bitDepth: Int?
    /// Channels in the source, before the engine's fold to stereo.
    public var channelCount: Int?

    public init(
        codec: String? = nil,
        codecProfile: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.codec = codec
        self.codecProfile = codecProfile
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }

    /// The columns the scanner wrote for a local track.
    ///
    /// `fileFormat` is deliberately not read: it is the file extension, and
    /// an `.m4a` carries AAC, ALAC and E-AC-3 alike, so a codec taken from it
    /// would be a guess that reads as a fact (#529). The decoder fills it in
    /// once the file is open.
    public init(track: Track) {
        self.init(
            bitrateKbps: track.bitrate,
            sampleRateHz: track.sampleRate,
            bitDepth: track.bitDepth,
            channelCount: track.channelCount
        )
    }

    /// What the open decoder measured: the codec on either route, and, for an
    /// FFmpeg-backed source, the rest of the stream's facts. Bit depth is
    /// absent by construction.
    ///
    /// A zero rate or channel count is FFmpeg saying it does not know, not a
    /// file with no channels, so both become nil.
    public init(details: StreamDetails?, codec: String?) {
        self.init(
            codec: codec ?? details?.codec,
            codecProfile: details?.codecProfile,
            bitrateKbps: details?.claimedBitrateKbps,
            sampleRateHz: details.map(\.sampleRateHz).flatMap { $0 > 0 ? $0 : nil },
            channelCount: details.map(\.channelCount).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// `live` wins wherever it has something to say; everything else stays.
    /// The decoder is looking at the bytes, the columns are a scan-time
    /// memory of them.
    public func merging(_ live: Self) -> Self {
        Self(
            codec: live.codec ?? self.codec,
            codecProfile: live.codecProfile ?? self.codecProfile,
            bitrateKbps: live.bitrateKbps ?? self.bitrateKbps,
            sampleRateHz: live.sampleRateHz ?? self.sampleRateHz,
            bitDepth: live.bitDepth ?? self.bitDepth,
            channelCount: live.channelCount ?? self.channelCount
        )
    }

    /// True when there is nothing to draw. The profile alone is not a badge,
    /// so it does not count as content.
    public var isEmpty: Bool {
        self.codec == nil
            && self.bitrateKbps == nil
            && self.sampleRateHz == nil
            && self.bitDepth == nil
            && self.channelCount == nil
    }
}
