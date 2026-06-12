import AudioEngine
import SwiftUI

// MARK: - VisualizerPalette

/// The curated colour palettes for the visualizer.
///
/// Stored by `rawValue` in `@AppStorage`, so appending cases is backward
/// compatible. ``drift`` and ``thermal`` are dynamic palettes for motion-heavy
/// modes where the static palettes feel flat.
public enum VisualizerPalette: String, CaseIterable, Sendable {
    case accent // tinted from the app accent colour
    case spectrum // classic rainbow
    case mono // single-colour (accessibility-friendly)
    case ember // warm red/orange
    case drift // slowly evolving hue, steered by the music
    case thermal // magnitude-to-heat colour ramp

    public var displayName: String {
        switch self {
        case .accent:
            L10n.string("Accent")

        case .spectrum:
            L10n.string("Spectrum")

        case .mono:
            L10n.string("Mono")

        case .ember:
            L10n.string("Ember")

        case .drift:
            L10n.string("Drift")

        case .thermal:
            L10n.string("Thermal")
        }
    }
}

// MARK: - SpectrumBars

/// Draws 32 log-spaced spectrum bars with rounded caps and per-band colouring.
///
/// Features:
/// - Peak-hold markers that fall with simulated gravity after the peak decays.
/// - Gradient tint selected by ``VisualizerPalette``.
/// - Respects `reduceMotion` by pausing peak-fall animation and using a calm
///   low-saturation style.
/// - Respects `reduceTransparency` by rendering bars at full opacity.
@MainActor
public final class SpectrumBars: Visualizer {
    // MARK: - State

    private var peakHold: [Float]
    private var peakVelocity: [Float] // "gravity" fall speed per band
    private let gravity: Float = 0.004 // fall acceleration per frame
    private let holdFrames = 30 // frames to hold peak before falling
    private var peakHoldCounter: [Int]

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool

    // MARK: - Init

    public init(
        palette: VisualizerPalette = .accent,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) {
        let n = FFTAnalyzer.bandCount
        self.peakHold = [Float](repeating: 0, count: n)
        self.peakVelocity = [Float](repeating: 0, count: n)
        self.peakHoldCounter = [Int](repeating: 0, count: n)
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let bandCount = analysis.bands.count
        guard bandCount > 0 else { return }

        let barSpacing: CGFloat = 2
        let barWidth = (size.width - barSpacing * CGFloat(bandCount + 1)) / CGFloat(bandCount)
        let maxBarHeight = size.height - 4 // minimal padding for peak markers

        for i in 0 ..< bandCount {
            let x = barSpacing + CGFloat(i) * (barWidth + barSpacing)
            let magnitude = CGFloat(analysis.bands[i])
            let barHeight = magnitude * maxBarHeight
            let y = size.height - barHeight

            // Bar fill colour, resolved through the shared palette mapping.
            let position = Double(i) / Double(max(bandCount - 1, 1))
            let barColor = PaletteResolver.color(
                palette: self.palette,
                position: position,
                magnitude: analysis.bands[i],
                analysis: analysis,
                time: time
            )
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let barPath = RoundedRectangle(cornerRadius: min(3, barWidth / 2))
                .path(in: barRect)

            // Gradient from bar colour (top) to slightly darker (bottom)
            context.fill(barPath, with: .color(barColor.opacity(
                self.reduceTransparency ? 1.0 : (self.reduceMotion ? 0.5 : 1.0)
            )))

            // Peak-hold marker
            if !self.reduceMotion {
                self.updatePeak(band: i, magnitude: Float(magnitude))
                let peakY = size.height - CGFloat(self.peakHold[i]) * maxBarHeight - 3
                let peakRect = CGRect(x: x, y: peakY, width: barWidth, height: 2)
                context.fill(Path(peakRect), with: .color(barColor.opacity(0.9)))
            }
        }
    }

    // MARK: - Private

    private func updatePeak(band i: Int, magnitude: Float) {
        if magnitude >= self.peakHold[i] {
            self.peakHold[i] = magnitude
            self.peakVelocity[i] = 0
            self.peakHoldCounter[i] = self.holdFrames
        } else if self.peakHoldCounter[i] > 0 {
            self.peakHoldCounter[i] -= 1
        } else {
            self.peakVelocity[i] += self.gravity
            self.peakHold[i] = max(0, self.peakHold[i] - self.peakVelocity[i])
        }
    }
}
