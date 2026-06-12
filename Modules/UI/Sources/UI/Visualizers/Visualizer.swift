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
    /// Spectral centroid on a log-frequency scale, 0…1 (0.5 in silence).
    public let centroid: Float
    /// Positive spectral flux, normalised 0…1.
    public let flux: Float
    /// True when this frame contains a detected onset (transient).
    public let onset: Bool
    /// Mean energy of the low/mid/high band groups, each 0…1.
    public let bassEnergy: Float
    public let midEnergy: Float
    public let trebleEnergy: Float
    /// Monotonically increasing counter incremented by `VisualizerViewModel`
    /// on every new analysis frame. Used by renderers (Cascade, Starfield) to
    /// detect new-frame arrivals without comparing all 32 band values.
    public let frameIndex: UInt64

    /// New fields default to their silent values so existing call sites that
    /// construct an `Analysis` from bands/rms/peak alone keep compiling.
    public init(
        bands: [Float],
        rms: Float,
        peak: Float,
        centroid: Float = 0.5,
        flux: Float = 0,
        onset: Bool = false,
        bassEnergy: Float = 0,
        midEnergy: Float = 0,
        trebleEnergy: Float = 0,
        frameIndex: UInt64 = 0
    ) {
        self.bands = bands
        self.rms = rms
        self.peak = peak
        self.centroid = centroid
        self.flux = flux
        self.onset = onset
        self.bassEnergy = bassEnergy
        self.midEnergy = midEnergy
        self.trebleEnergy = trebleEnergy
        self.frameIndex = frameIndex
    }

    /// Silent frame used before the first real sample arrives. Centroid is the
    /// neutral midpoint (0.5) so dynamic palettes do not slam to one extreme on
    /// pause; everything else is zero/false. frameIndex 0 signals "not yet started".
    public static let silent = Self(
        bands: [Float](repeating: 0, count: FFTAnalyzer.bandCount),
        rms: 0,
        peak: 0,
        centroid: 0.5,
        frameIndex: 0
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
    ///   - time:    The frame timestamp in seconds (TimelineView date). Animated
    ///              modes and dynamic palettes derive motion from this so they
    ///              stay deterministic under fixed times in snapshot tests.
    func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis,
        time: TimeInterval
    )
}
