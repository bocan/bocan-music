import AudioEngine
import SwiftUI

// MARK: - VisualizerPalette

/// The four curated colour palettes for the visualizer.
public enum VisualizerPalette: String, CaseIterable, Sendable {
    case accent // tinted from the app accent colour
    case spectrum // classic rainbow
    case mono // single-colour (accessibility-friendly)
    case ember // warm red/orange

    public var displayName: String {
        switch self {
        case .accent:
            "Accent"

        case .spectrum:
            "Spectrum"

        case .mono:
            "Mono"

        case .ember:
            "Ember"
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

    // MARK: - Init

    public init(palette: VisualizerPalette = .accent, reduceMotion: Bool = false) {
        let n = FFTAnalyzer.bandCount
        self.peakHold = [Float](repeating: 0, count: n)
        self.peakVelocity = [Float](repeating: 0, count: n)
        self.peakHoldCounter = [Int](repeating: 0, count: n)
        self.palette = palette
        self.reduceMotion = reduceMotion
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis
    ) {
        let bandCount = analysis.bands.count
        guard bandCount > 0 else { return }

        let barSpacing: CGFloat = 2
        let barWidth = (size.width - barSpacing * CGFloat(bandCount + 1)) / CGFloat(bandCount)
        let maxBarHeight = size.height - 12 // leave room for peak markers

        for i in 0 ..< bandCount {
            let x = barSpacing + CGFloat(i) * (barWidth + barSpacing)
            let magnitude = CGFloat(analysis.bands[i])
            let barHeight = magnitude * maxBarHeight
            let y = size.height - barHeight

            // Bar fill gradient
            let barColor = self.bandColor(index: i, count: bandCount, magnitude: analysis.bands[i])
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let barPath = RoundedRectangle(cornerRadius: min(3, barWidth / 2))
                .path(in: barRect)

            // Gradient from bar colour (top) to slightly darker (bottom)
            context.fill(barPath, with: .color(barColor.opacity(self.reduceMotion ? 0.5 : 1.0)))

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

    private func bandColor(index: Int, count: Int, magnitude: Float) -> Color {
        let t = Double(index) / Double(max(count - 1, 1))
        switch self.palette {
        case .spectrum:
            return Color(hue: t * 0.75, saturation: 0.9, brightness: 0.9)

        case .mono:
            return Color(hue: 0, saturation: 0, brightness: 0.85)

        case .ember:
            return Color(hue: t * 0.08, saturation: 0.95, brightness: 0.95)

        case .accent:
            // Shift hue slightly per band for visual interest.
            return Color.accentColor.opacity(0.7 + Double(magnitude) * 0.3)
        }
    }
}
