import Foundation

// MARK: - VisualizerMode

/// The set of available visualizer rendering modes.
public enum VisualizerMode: String, CaseIterable, Sendable {
    case spectrumBars
    case oscilloscope
    case fluidMetal

    /// Human-readable name shown in the settings picker.
    public var displayName: String {
        switch self {
        case .spectrumBars:
            "Spectrum Bars"

        case .oscilloscope:
            "Oscilloscope"

        case .fluidMetal:
            "Fluid"
        }
    }

    /// SF Symbol name representing the mode in the UI.
    public var symbolName: String {
        switch self {
        case .spectrumBars:
            "chart.bar.fill"

        case .oscilloscope:
            "waveform"

        case .fluidMetal:
            "sparkles"
        }
    }

    /// Whether this mode uses Metal (and can be disabled by `reduceMotion`).
    public var isMetalBased: Bool {
        self == .fluidMetal
    }
}
