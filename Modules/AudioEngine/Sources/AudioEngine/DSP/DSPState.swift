import Foundation

/// The complete DSP configuration snapshot.
///
/// Stored in `UserDefaults` and propagated to `DSPChain` on every change.
/// All DSP parameters live here so the UI has a single observable source of truth.
public struct DSPState: Sendable, Codable, Hashable {
    /// Whether the 10-band EQ is active. When `false`, `DSPChain` bypasses the EQ node.
    public var eqEnabled = true
    /// ID of the currently loaded `EQPreset`, or `nil` for a custom (unsaved) configuration.
    public var eqPresetID: EQPreset.ID? = BuiltInPresets.flat.id
    /// Bass-boost shelf gain in dB (0 = off, max 12 dB).
    public var bassBoostDB: Double = 0
    /// Bauer headphone crossfeed amount (0 = off, 1 = full).
    public var crossfeedAmount: Double = 0
    /// Mid/side stereo width multiplier (0.5 = half-width mono-ish … 1.0 = original … 2.0 = wide).
    public var stereoWidth = 1.0
    /// Which ReplayGain value to apply at playback time.
    public var replayGainMode: ReplayGainMode = .track
    /// Pre-amplifier gain added on top of the resolved ReplayGain value (±12 dB).
    public var preAmpDB: Double = 0
    /// Crossfade duration in seconds (0 = disabled / gapless-only).
    public var crossfadeSeconds: Double = 0
    /// When `true` and `crossfadeSeconds > 0`, tracks from the same album use the
    /// Phase 5 sample-accurate gapless path; crossfade only activates at album boundaries.
    public var crossfadeAlbumGapless = true

    public init() {}

    // MARK: - UserDefaults persistence

    private static let defaultsKey = "io.cloudcauldron.bocan.dspState"

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return state
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
