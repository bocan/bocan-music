import Foundation

// MARK: - BuiltInPresets

/// All factory-supplied EQ presets, ordered as they appear in the preset menu.
public enum BuiltInPresets {
    // ISO 1/3-octave centre frequencies (Hz): 31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k

    /// Unity gain at all frequencies.
    public static let flat = EQPreset(
        id: "bocan.flat",
        name: "Flat",
        bandGainsDB: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    /// Boosted highs and sub-bass for electric guitar and drums.
    public static let rock = EQPreset(
        id: "bocan.rock",
        name: "Rock",
        bandGainsDB: [4, 3, -2, -3, -1, 2, 4, 5, 5, 4],
        isBuiltIn: true
    )

    /// Warm low-mids and open highs suited to jazz recordings.
    public static let jazz = EQPreset(
        id: "bocan.jazz",
        name: "Jazz",
        bandGainsDB: [2, 2, 1, 0, -1, -1, 0, 1, 2, 3],
        isBuiltIn: true
    )

    /// Gentle roll-off in the upper treble to reduce harshness in orchestral recordings.
    public static let classical = EQPreset(
        id: "bocan.classical",
        name: "Classical",
        bandGainsDB: [0, 0, 0, 0, 0, 0, -2, -2, -2, -3],
        isBuiltIn: true
    )

    /// Sub-bass punch and crisp highs for electronic and dance music.
    public static let electronic = EQPreset(
        id: "bocan.electronic",
        name: "Electronic",
        bandGainsDB: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5],
        isBuiltIn: true
    )

    /// Presence lift in the 500 Hz – 2 kHz range for clearer vocals.
    public static let vocalBoost = EQPreset(
        id: "bocan.vocal_boost",
        name: "Vocal Boost",
        bandGainsDB: [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1],
        isBuiltIn: true
    )

    /// Extended sub-bass and bass shelf.
    public static let bassBoost = EQPreset(
        id: "bocan.bass_boost",
        name: "Bass Boost",
        bandGainsDB: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    /// Lifted presence above 4 kHz for added air and detail.
    public static let trebleBoost = EQPreset(
        id: "bocan.treble_boost",
        name: "Treble Boost",
        bandGainsDB: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
        isBuiltIn: true
    )

    /// Bass and treble boost with a mild mid-scoop for playback at lower volumes.
    public static let loudness = EQPreset(
        id: "bocan.loudness",
        name: "Loudness",
        bandGainsDB: [6, 4, 1, 0, -2, -1, 0, 1, 4, 6],
        isBuiltIn: true
    )

    /// Mid-range emphasis around 1–4 kHz for podcasts and audiobooks.
    public static let spokenWord = EQPreset(
        id: "bocan.spoken_word",
        name: "Spoken Word",
        bandGainsDB: [-4, -3, 0, 2, 4, 3, 2, 1, -1, -2],
        isBuiltIn: true
    )

    /// All built-in presets in display order (Flat first, then alphabetical).
    public static let all: [EQPreset] = [
        flat, rock, jazz, classical, electronic,
        vocalBoost, bassBoost, trebleBoost, loudness, spokenWord,
    ]
}
