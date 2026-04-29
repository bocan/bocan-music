import AudioEngine
import SwiftUI

// MARK: - OscilloscopeVariant

/// The two display variants of the oscilloscope.
public enum OscilloscopeVariant: String, CaseIterable, Sendable {
    /// Classic time-domain waveform.
    case waveform
    /// XY (Lissajous) mode — L channel on horizontal axis, R channel on vertical.
    case lissajous
}

// MARK: - Oscilloscope

/// Canvas-based oscilloscope with waveform and Lissajous (XY) variants.
///
/// `reduceMotion`: pauses on the last rendered frame (no new path updates).
@MainActor
public final class Oscilloscope: Visualizer {
    // MARK: - State

    private var lastSamples: AudioSamples?
    private let variant: OscilloscopeVariant
    private let palette: VisualizerPalette
    private let reduceMotion: Bool

    // MARK: - Init

    public init(
        variant: OscilloscopeVariant = .waveform,
        palette: VisualizerPalette = .accent,
        reduceMotion: Bool = false
    ) {
        self.variant = variant
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
        let drawSamples: AudioSamples
        if self.reduceMotion {
            // Freeze on the last frame — only update once to capture silence.
            if let last = lastSamples {
                drawSamples = last
            } else {
                self.lastSamples = samples
                drawSamples = samples
            }
        } else {
            self.lastSamples = samples
            drawSamples = samples
        }

        switch self.variant {
        case .waveform:
            self.renderWaveform(into: &context, size: size, samples: drawSamples, analysis: analysis)

        case .lissajous:
            self.renderLissajous(into: &context, size: size, samples: drawSamples, analysis: analysis)
        }
    }

    // MARK: - Waveform

    private func renderWaveform(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis
    ) {
        let mono = samples.mono
        guard mono.count >= 2 else { return }

        // Downsample to at most 512 points for performance.
        let targetPoints = min(512, mono.count)
        let step = max(1, mono.count / targetPoints)

        var path = Path()
        let midY = size.height / 2

        for i in stride(from: 0, to: mono.count, by: step) {
            let x = size.width * CGFloat(i) / CGFloat(mono.count)
            let y = midY - CGFloat(mono[i]) * midY * 0.9
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        let strokeColor = self.lineColor(analysis: analysis)
        context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)

        // Faint centre line.
        var centreLine = Path()
        centreLine.move(to: CGPoint(x: 0, y: midY))
        centreLine.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(centreLine, with: .color(strokeColor.opacity(0.15)), lineWidth: 0.5)
    }

    // MARK: - Lissajous

    private func renderLissajous(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis
    ) {
        let left = samples.left
        let right = samples.right
        guard left.count >= 2, right.count >= 2 else { return }

        let count = min(left.count, right.count)
        let targetPoints = min(512, count)
        let step = max(1, count / targetPoints)

        let cx = size.width / 2
        let cy = size.height / 2
        let scale = min(cx, cy) * 0.9

        var path = Path()
        var first = true
        for i in stride(from: 0, to: count, by: step) {
            let x = cx + CGFloat(left[i]) * scale
            let y = cy - CGFloat(right[i]) * scale
            let pt = CGPoint(x: x, y: y)
            if first {
                path.move(to: pt)
                first = false
            } else {
                path.addLine(to: pt)
            }
        }

        let strokeColor = self.lineColor(analysis: analysis)
        context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
    }

    // MARK: - Private

    private func lineColor(analysis: Analysis) -> Color {
        switch self.palette {
        case .spectrum:
            Color(hue: Double(analysis.rms) * 0.5, saturation: 0.9, brightness: 0.9)

        case .mono:
            .white

        case .ember:
            Color(hue: 0.03, saturation: 0.9, brightness: 0.9)

        case .accent:
            .accentColor
        }
    }
}
