import Foundation

// MARK: - TrackGainInfo

/// The raw ReplayGain values stored for a track (from DB or tags).
public struct TrackGainInfo: Sendable, Hashable {
    public var trackGainDB: Double?
    public var trackPeakLinear: Double?
    public var albumGainDB: Double?
    public var albumPeakLinear: Double?

    public init(
        trackGainDB: Double? = nil,
        trackPeakLinear: Double? = nil,
        albumGainDB: Double? = nil,
        albumPeakLinear: Double? = nil
    ) {
        self.trackGainDB = trackGainDB
        self.trackPeakLinear = trackPeakLinear
        self.albumGainDB = albumGainDB
        self.albumPeakLinear = albumPeakLinear
    }
}

// MARK: - TrackReplayGain

/// What the engine needs to apply ReplayGain to one track it plays: the
/// stored values, and whether the track plays inside an album span (which
/// `.auto` mode reads). The mode and pre-amp are not here: they come from
/// `DSPState`, so a settings change reapplies to the tracks already loaded
/// without the caller loading them again (#573).
public struct TrackReplayGain: Sendable, Hashable {
    public var values: TrackGainInfo
    public var isInAlbumContext: Bool

    public init(values: TrackGainInfo, isInAlbumContext: Bool = false) {
        self.values = values
        self.isInAlbumContext = isInAlbumContext
    }
}

// MARK: - GainApplication

/// Resolves which ReplayGain gain value to apply at playback time.
///
/// **Mode resolution:**
/// - `.off`: returns 0 dB.
/// - `.track`: uses `trackGainDB`.
/// - `.album`: uses `albumGainDB`; falls back to `trackGainDB` if absent.
/// - `.auto`: uses album gain when `isInAlbumContext`, otherwise track gain.
///
/// **No values:** a track with nothing measured for the chosen mode plays
/// as it is, at 0 dB. The pre-amp is an offset on a ReplayGain value, and
/// there is none to offset.
///
/// **Pre-amp**: `preAmpDB` is added on top of the resolved gain.
///
/// **Clipping guard**: when `(resolved + preAmpDB)` would push the peak above
/// −0.5 dBFS, the pre-amp contribution is reduced until the peak is safe.
public struct GainApplication: Sendable {
    // MARK: - Constants

    /// Maximum output peak before the clipping guard triggers (in dBFS).
    public static let maxOutputPeakDBFS: Double = -0.5

    /// The largest gain, either way, that `linear(fromDB:)` passes through.
    /// Far outside any real ReplayGain value: it only stops a corrupt tag
    /// from blasting or muting a track.
    public static let gainLimitDB: Double = 40

    // MARK: - API

    /// Compute the gain in dB the buffer pump applies to the track's audio.
    ///
    /// - Parameters:
    ///   - info:            ReplayGain values for the track.
    ///   - mode:            Which gain mode to apply.
    ///   - preAmpDB:        Pre-amplifier offset (±12 dB, from DSPState).
    ///   - isInAlbumContext: Whether the track is being played as part of a queued album span.
    /// - Returns: Final gain in dB to apply, after clipping guard.
    public static func resolve(
        info: TrackGainInfo,
        mode: ReplayGainMode,
        preAmpDB: Double = 0,
        isInAlbumContext: Bool = false
    ) -> Double {
        let preferAlbum: Bool
        switch mode {
        case .off:
            return 0

        case .track:
            preferAlbum = false

        case .album:
            preferAlbum = true

        case .auto:
            preferAlbum = isInAlbumContext
        }

        // The peak goes with the gain it was measured with.
        let albumPair = preferAlbum
            ? info.albumGainDB.map { (gain: $0, peak: info.albumPeakLinear ?? info.trackPeakLinear) }
            : nil
        guard let chosen = albumPair ?? info.trackGainDB.map({ (gain: $0, peak: info.trackPeakLinear) }) else {
            return 0
        }

        let tentative = chosen.gain + preAmpDB

        // Clipping guard: only applies when we have measured peak data.
        // Without peak data, assume the gain is safe (no guard).
        guard let peakLinear = chosen.peak, peakLinear > 0 else { return tentative }
        let peakAfterGainDB = 20.0 * log10(peakLinear) + tentative
        if peakAfterGainDB > Self.maxOutputPeakDBFS {
            let reduction = peakAfterGainDB - Self.maxOutputPeakDBFS
            return tentative - reduction
        }
        return tentative
    }

    /// The linear gain the buffer pump multiplies `track`'s samples by: 1
    /// for a track with no ReplayGain facts (a stream, a podcast, a file
    /// opened outside the library) or when the mode is `.off`.
    public static func linearGain(
        for track: TrackReplayGain?,
        mode: ReplayGainMode,
        preAmpDB: Double
    ) -> Float {
        guard let track else { return 1 }
        let db = self.resolve(
            info: track.values,
            mode: mode,
            preAmpDB: preAmpDB,
            isInAlbumContext: track.isInAlbumContext
        )
        return self.linear(fromDB: db)
    }

    /// `db` as a linear amplitude factor, clamped to ±`gainLimitDB`.
    public static func linear(fromDB db: Double) -> Float {
        let clamped = max(-self.gainLimitDB, min(self.gainLimitDB, db))
        return Float(pow(10.0, clamped / 20.0))
    }

    /// Convert the peak linear value from a `ReplayGainResult` to dBFS.
    public static func peakDBFS(fromLinear linear: Double) -> Double {
        guard linear > 0 else { return -120 }
        return 20.0 * log10(linear)
    }
}
