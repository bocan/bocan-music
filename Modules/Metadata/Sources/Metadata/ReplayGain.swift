import Foundation

// MARK: - ReplayGain values

/// ReplayGain or EBU R128 loudness metadata.
public struct ReplayGain: Sendable, Equatable {
    /// Track gain in dB (positive = amplify, negative = attenuate).
    public let trackGain: Double?

    /// Track peak sample level (0.0 – 1.0+).
    public let trackPeak: Double?

    /// Album gain in dB.
    public let albumGain: Double?

    /// Album peak sample level.
    public let albumPeak: Double?

    /// EBU R128 track loudness correction in dB (decoded from Q7.8).
    public let r128TrackGain: Double?

    /// EBU R128 album loudness correction in dB.
    public let r128AlbumGain: Double?

    public init(
        trackGain: Double? = nil,
        trackPeak: Double? = nil,
        albumGain: Double? = nil,
        albumPeak: Double? = nil,
        r128TrackGain: Double? = nil,
        r128AlbumGain: Double? = nil
    ) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
        self.r128TrackGain = r128TrackGain
        self.r128AlbumGain = r128AlbumGain
    }

    // MARK: - NaN-to-nil conversion from bridge

    /// Lifts raw `Double` values from the Obj-C bridge, treating `NaN` as absent.
    init(
        trackGainRaw: Double,
        trackPeakRaw: Double,
        albumGainRaw: Double,
        albumPeakRaw: Double,
        r128TrackGainRaw: Double,
        r128AlbumGainRaw: Double
    ) {
        self.trackGain = trackGainRaw.isNaN ? nil : trackGainRaw
        self.trackPeak = trackPeakRaw.isNaN ? nil : trackPeakRaw
        self.albumGain = albumGainRaw.isNaN ? nil : albumGainRaw
        self.albumPeak = albumPeakRaw.isNaN ? nil : albumPeakRaw
        self.r128TrackGain = r128TrackGainRaw.isNaN ? nil : r128TrackGainRaw
        self.r128AlbumGain = r128AlbumGainRaw.isNaN ? nil : r128AlbumGainRaw
    }

    /// `true` when no loudness values are present.
    public var isEmpty: Bool {
        self.trackGain == nil && self.trackPeak == nil &&
            self.albumGain == nil && self.albumPeak == nil &&
            self.r128TrackGain == nil && self.r128AlbumGain == nil
    }
}
