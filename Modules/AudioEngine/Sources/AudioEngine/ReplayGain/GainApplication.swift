import Foundation

// MARK: - TrackGainInfo

/// The raw ReplayGain values stored for a track (from DB or tags).
public struct TrackGainInfo: Sendable {
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

// MARK: - GainApplication

/// Resolves which ReplayGain gain value to apply at playback time.
///
/// **Mode resolution:**
/// - `.off`: returns 0 dB.
/// - `.track`: uses `trackGainDB`.
/// - `.album`: uses `albumGainDB`; falls back to `trackGainDB` if absent.
/// - `.auto`: uses album gain when `isInAlbumContext`, otherwise track gain.
///
/// **Pre-amp**: `preAmpDB` is added on top of the resolved gain.
///
/// **Clipping guard**: when `(resolved + preAmpDB)` would push the peak above
/// −0.5 dBFS, the pre-amp contribution is reduced until the peak is safe.
/// A log warning is emitted when the guard triggers.
public struct GainApplication: Sendable {
    // MARK: - Constants

    /// Maximum output peak before the clipping guard triggers (in dBFS).
    public static let maxOutputPeakDBFS: Double = -0.5

    // MARK: - API

    /// Compute the gain in dB to write to `GainStage`.
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
        let baseGain: Double
        switch mode {
        case .off:
            return 0

        case .track:
            baseGain = info.trackGainDB ?? 0

        case .album:
            baseGain = info.albumGainDB ?? info.trackGainDB ?? 0

        case .auto:
            if isInAlbumContext {
                baseGain = info.albumGainDB ?? info.trackGainDB ?? 0
            } else {
                baseGain = info.trackGainDB ?? 0
            }
        }

        let tentative = baseGain + preAmpDB

        // Clipping guard: only applies when we have measured peak data.
        // Without peak data, assume the gain is safe (no guard).
        let peakLinear: Double?
        switch mode {
        case .off:
            return 0

        case .track:
            peakLinear = info.trackPeakLinear

        case .album:
            peakLinear = info.albumPeakLinear ?? info.trackPeakLinear

        case .auto:
            peakLinear = isInAlbumContext
                ? (info.albumPeakLinear ?? info.trackPeakLinear)
                : info.trackPeakLinear
        }

        guard let peakLinear, peakLinear > 0 else { return tentative }
        let peakAfterGainDB = 20.0 * log10(peakLinear) + tentative
        if peakAfterGainDB > Self.maxOutputPeakDBFS {
            let reduction = peakAfterGainDB - Self.maxOutputPeakDBFS
            return tentative - reduction
        }
        return tentative
    }

    /// Convert the peak linear value from a `ReplayGainResult` to dBFS.
    public static func peakDBFS(fromLinear linear: Double) -> Double {
        guard linear > 0 else { return -120 }
        return 20.0 * log10(linear)
    }
}
