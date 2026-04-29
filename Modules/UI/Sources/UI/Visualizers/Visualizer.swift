import AudioEngine
import SwiftUI

// MARK: - Analysis

/// Pre-computed analysis snapshot passed to every ``Visualizer`` on each frame.
public struct Analysis: Sendable {
    /// 32 perceptual frequency bands, each normalised 0…1.
    public let bands: [Float]
    /// RMS level of the mono signal (0…1).
    public let rms: Float
    /// Peak absolute value of the mono signal (0…1).
    public let peak: Float

    /// Silent frame used before the first real sample arrives.
    public static let silent = Self(
        bands: [Float](repeating: 0, count: FFTAnalyzer.bandCount),
        rms: 0,
        peak: 0
    )
}

// MARK: - Visualizer

/// A single visualizer rendering strategy.
///
/// All methods are called on the main actor, so implementations may freely
/// read `@MainActor`-isolated state.
@MainActor
public protocol Visualizer: AnyObject {
    /// Draw the current frame into `context`.
    ///
    /// - Parameters:
    ///   - context: A SwiftUI `GraphicsContext` ready for drawing.
    ///   - size:    The pixel dimensions of the canvas.
    ///   - samples: The latest raw audio buffer from the tap.
    ///   - analysis: Pre-computed FFT bands and levels.
    func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis
    )
}
