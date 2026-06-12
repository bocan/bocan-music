import SwiftUI

// MARK: - PaletteResolver

/// The single source of truth that maps a ``VisualizerPalette`` (plus an
/// element's position/magnitude and the current analysis/time) to a `Color`.
///
/// Every visualizer resolves colour through this helper, so the one global
/// palette setting controls all modes and there is no duplicated palette
/// `switch` scattered across individual renderers.
public enum PaletteResolver {
    /// Colour for a single element of a visualizer.
    ///
    /// - Parameters:
    ///   - palette: The active palette.
    ///   - position: 0…1 placement of the element (band fraction, angle fraction).
    ///   - magnitude: 0…1 intensity of the element.
    ///   - analysis: Current-frame analysis (steers dynamic palettes).
    ///   - time: Frame timestamp in seconds (drives time-evolving palettes).
    public static func color(
        palette: VisualizerPalette,
        position: Double,
        magnitude: Float,
        analysis: Analysis,
        time: TimeInterval
    ) -> Color {
        switch palette {
        case .spectrum:
            Color(hue: position * 0.75, saturation: 0.9, brightness: 0.9)

        case .mono:
            // Single, accessibility-friendly white (the oscilloscope line "stays white").
            .white

        case .ember:
            Color(hue: position * 0.08, saturation: 0.95, brightness: 0.95)

        case .accent:
            Color.accentColor.opacity(0.7 + Double(magnitude) * 0.3)

        case .drift:
            self.driftColor(position: position, magnitude: magnitude, analysis: analysis, time: time)

        case .thermal:
            self.thermalColor(magnitude: magnitude)
        }
    }

    /// Evenly spaced gradient stops (count 8) for ramp-style consumers
    /// (Cascade pixel LUT, Nebula density LUT). Sweeps position and magnitude
    /// together from 0 to 1 so every palette yields a low→high gradient.
    public static func rampStops(
        palette: VisualizerPalette,
        analysis: Analysis,
        time: TimeInterval
    ) -> [Color] {
        (0 ..< 8).map { i in
            let f = Double(i) / 7
            return Self.color(palette: palette, position: f, magnitude: Float(f), analysis: analysis, time: time)
        }
    }

    // MARK: - Drift

    /// Slowly evolving hue steered by the music. A full hue cycle takes 90 s; the
    /// centroid term makes bright, trebly passages visibly shift the colour.
    /// Deterministic given `(time, analysis)`, so it is snapshot-testable.
    private static func driftColor(
        position: Double,
        magnitude: Float,
        analysis: Analysis,
        time: TimeInterval
    ) -> Color {
        let raw = time / 90 + 0.25 * Double(analysis.centroid) + 0.15 * position
        let hue = raw - floor(raw) // fract(raw)
        return Color(hue: hue, saturation: 0.85, brightness: 0.55 + 0.45 * Double(magnitude))
    }

    // MARK: - Thermal

    /// One sRGB stop on the heat ramp.
    private struct ThermalStop {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Heat ramp (sRGB) sampled at magnitude 0, 0.25, 0.5, 0.75, 1.0:
    /// near-black navy → indigo → magenta → orange → white-hot. Perceived
    /// brightness rises monotonically across the ramp.
    private static let thermalStops: [ThermalStop] = [
        ThermalStop(red: 0.02, green: 0.02, blue: 0.10),
        ThermalStop(red: 0.25, green: 0.05, blue: 0.55),
        ThermalStop(red: 0.85, green: 0.12, blue: 0.55),
        ThermalStop(red: 1.00, green: 0.55, blue: 0.10),
        ThermalStop(red: 1.00, green: 0.98, blue: 0.92),
    ]

    /// Position-independent heat colour, linearly interpolated between
    /// ``thermalStops`` in sRGB and indexed by `magnitude`.
    private static func thermalColor(magnitude: Float) -> Color {
        let level = min(1, max(0, Double(magnitude)))
        let scaled = level * Double(Self.thermalStops.count - 1)
        let index = min(Self.thermalStops.count - 2, Int(scaled))
        let fraction = scaled - Double(index)
        let from = Self.thermalStops[index]
        let to = Self.thermalStops[index + 1]
        return Color(
            .sRGB,
            red: from.red + (to.red - from.red) * fraction,
            green: from.green + (to.green - from.green) * fraction,
            blue: from.blue + (to.blue - from.blue) * fraction,
            opacity: 1
        )
    }
}
