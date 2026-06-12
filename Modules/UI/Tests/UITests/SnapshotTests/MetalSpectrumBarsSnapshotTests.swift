import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalSpectrumBarsSnapshotTests

/// Snapshot suite for the Metal spectrum bars, rendered through
/// ``MetalOffscreenRenderer`` at a fixed mid-spectrum analysis. Skipped when
/// there is no Metal device, and disabled on CI like the other snapshot suites.
@Suite(
    "Metal Spectrum Bars Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalSpectrumBarsSnapshotTests {
    private static let size = CGSize(width: 400, height: 400)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    private static let midSpectrum: [Float] = (0 ..< FFTAnalyzer.bandCount).map {
        sin(Float($0) / Float(FFTAnalyzer.bandCount) * .pi) * 0.85
    }

    private static func analysis(_ bands: [Float]) -> Analysis {
        Analysis(bands: bands, rms: 0.6, peak: 0.9, centroid: 0.5)
    }

    // MARK: - Palette variants

    @Test("Metal spectrum bars across palettes", arguments: VisualizerPalette.allCases)
    func palettes(palette: VisualizerPalette) throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: palette, bands: Self.midSpectrum)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-spectrum-bars-\(palette.rawValue)"
        )
    }

    // MARK: - Accessibility + edge cases

    @Test("Metal spectrum bars reduce motion (no peaks, half opacity)")
    func reduceMotion() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, bands: Self.midSpectrum, reduceMotion: true)
        assertSnapshot(of: image, as: .image(precision: 0.95, perceptualPrecision: 0.98), named: "metal-spectrum-bars-reduce-motion")
    }

    @Test("Metal spectrum bars reduce transparency (full opacity)")
    func reduceTransparency() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, bands: Self.midSpectrum, reduceMotion: true, reduceTransparency: true)
        assertSnapshot(of: image, as: .image(precision: 0.95, perceptualPrecision: 0.98), named: "metal-spectrum-bars-reduce-transparency")
    }

    @Test("Metal spectrum bars full-height bar (cap radius and 4 pt headroom)")
    func tallBar() throws {
        guard MetalSupport.device != nil else { return }
        var bands = [Float](repeating: 0.1, count: FFTAnalyzer.bandCount)
        bands[16] = 1.0
        let image = try self.render(palette: .accent, bands: bands)
        assertSnapshot(of: image, as: .image(precision: 0.95, perceptualPrecision: 0.98), named: "metal-spectrum-bars-tall")
    }

    // MARK: - Helpers

    private func render(
        palette: VisualizerPalette,
        bands: [Float],
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) throws -> NSImage {
        let device = try #require(MetalSupport.device)
        let bars = try MetalSpectrumBars(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        )
        bars.pixelsPerPointOverride = 1
        return try #require(MetalOffscreenRenderer.render(
            bars, size: Self.size, analysis: Self.analysis(bands), samples: Self.silentSamples, time: 0
        ))
    }
}
