import Foundation

// MARK: - VisualizerMode

/// The set of available visualizer rendering modes.
public enum VisualizerMode: String, CaseIterable, Sendable {
    case spectrumBars
    case oscilloscope
    case halo
    case cascade

    /// Human-readable name shown in the settings picker.
    public var displayName: String {
        switch self {
        case .spectrumBars:
            L10n.string("Spectrum Bars")

        case .oscilloscope:
            L10n.string("Oscilloscope")

        case .halo:
            L10n.string("Halo")

        case .cascade:
            L10n.string("Cascade")
        }
    }

    /// SF Symbol name representing the mode in the UI.
    public var symbolName: String {
        switch self {
        case .spectrumBars:
            "chart.bar.fill"

        case .oscilloscope:
            "waveform"

        case .halo:
            "circle.circle"

        case .cascade:
            "water.waves"
        }
    }
}
