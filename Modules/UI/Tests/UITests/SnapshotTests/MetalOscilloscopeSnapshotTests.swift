import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalOscilloscopeSnapshotTests

/// Snapshot suite for the Metal oscilloscope, rendered through
/// ``MetalOffscreenRenderer``. Each test feeds a fixed waveform so the output is
/// deterministic. Skipped when there is no Metal device, and disabled on CI like
/// the other snapshot suites (GPU rasterisation differs across runners).
///
/// Recorded references are eyeballed against the Canvas oscilloscope for parity;
/// the geometry is proven byte-for-byte in `MetalOscilloscopeTests`.
@Suite(
    "Metal Oscilloscope Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalOscilloscopeSnapshotTests {
    private static let size = CGSize(width: 400, height: 400)

    private static let sine: [Float] = (0 ..< 512).map { sin(Float($0) / 512 * 4 * .pi) * 0.85 }
    private static let cosine: [Float] = (0 ..< 512).map { cos(Float($0) / 512 * 4 * .pi) * 0.85 }

    private static var waveformSamples: AudioSamples {
        AudioSamples(timeStamp: .init(), sampleRate: 44100, mono: sine, left: sine, right: sine, rms: 0.6, peak: 0.85)
    }

    private static var lissajousSamples: AudioSamples {
        AudioSamples(timeStamp: .init(), sampleRate: 44100, mono: sine, left: sine, right: cosine, rms: 0.6, peak: 0.85)
    }

    private static let analysis = Analysis(
        bands: [Float](repeating: 0.4, count: FFTAnalyzer.bandCount), rms: 0.6, peak: 0.85, centroid: 0.6
    )

    // MARK: - Palette variants (waveform)

    @Test("Metal oscilloscope waveform across palettes", arguments: VisualizerPalette.allCases)
    func waveformPalettes(palette: VisualizerPalette) throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.renderWaveform(palette: palette, reduceMotion: false)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-oscilloscope-waveform-\(palette.rawValue)"
        )
    }

    // MARK: - Variant + accessibility

    @Test("Metal oscilloscope Lissajous")
    func lissajous() throws {
        guard let device = MetalSupport.device else { return }
        let oscilloscope = try MetalOscilloscope(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .spectrum, reduceMotion: false, reduceTransparency: false),
            variant: .lissajous
        )
        oscilloscope.pixelsPerPointOverride = 1
        let image = try #require(MetalOffscreenRenderer.render(
            oscilloscope, size: Self.size, analysis: Self.analysis, samples: Self.lissajousSamples, time: 0
        ))
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-oscilloscope-lissajous"
        )
    }

    @Test("Metal oscilloscope reduce motion")
    func reduceMotion() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.renderWaveform(palette: .spectrum, reduceMotion: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-oscilloscope-reduce-motion"
        )
    }

    // MARK: - Helpers

    private func renderWaveform(palette: VisualizerPalette, reduceMotion: Bool) throws -> NSImage {
        let device = try #require(MetalSupport.device)
        let oscilloscope = try MetalOscilloscope(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: reduceMotion, reduceTransparency: false)
        )
        // Scale 1 so the references are resolution-independent.
        oscilloscope.pixelsPerPointOverride = 1
        return try #require(MetalOffscreenRenderer.render(
            oscilloscope, size: Self.size, analysis: Self.analysis, samples: Self.waveformSamples, time: 0
        ))
    }
}
