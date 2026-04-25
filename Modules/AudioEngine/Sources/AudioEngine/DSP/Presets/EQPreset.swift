import Foundation

/// A named 10-band equaliser preset with an optional overall output gain.
///
/// Built-in presets use stable `"bocan.*"` IDs. User-created presets use UUID strings.
public struct EQPreset: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Gain values in dB for each of the 10 ISO centre-frequency bands
    /// (31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz). Must have exactly 10 entries.
    public let bandGainsDB: [Double]
    /// Overall output gain adjustment in dB (±12 dB range).
    public let outputGainDB: Double
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        bandGainsDB: [Double],
        isBuiltIn: Bool,
        outputGainDB: Double = 0
    ) {
        precondition(bandGainsDB.count == 10, "EQPreset requires exactly 10 band gains")
        self.id = id
        self.name = name
        self.bandGainsDB = bandGainsDB
        self.outputGainDB = outputGainDB
        self.isBuiltIn = isBuiltIn
    }
}
