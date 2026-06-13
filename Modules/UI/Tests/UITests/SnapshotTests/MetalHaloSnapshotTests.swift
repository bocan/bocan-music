import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalHaloSnapshotTests

/// Snapshot suite for the Metal halo, rendered through ``MetalOffscreenRenderer``.
///
/// Mirrors the Canvas ``HaloSnapshotTests`` fixture exactly so the two renderers
/// are comparable by eye: the same sine-shaped bands, rms 0.6, a 60-frame EMA
/// warm-up via ``Halo/updateSmoothing(analysis:)`` (so the smoothed bands are
/// settled), and a single render at the fixed time 1000. The warm-up uses
/// `updateSmoothing` rather than a full `update` so the rotation phase stays 0,
/// matching the Canvas reference (whose single render has dt 0).
///
/// Skipped when there is no Metal device, and disabled on CI like the other
/// snapshot suites (GPU rasterisation differs across runners).
@Suite(
    "Metal Halo Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalHaloSnapshotTests {
    private static let size = CGSize(width: 400, height: 400)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    private static let analysis: Analysis = {
        var bands = [Float](repeating: 0, count: FFTAnalyzer.bandCount)
        for index in 0 ..< bands.count {
            let fraction = Float(index) / Float(bands.count)
            bands[index] = sin(fraction * .pi) * 0.85
        }
        return Analysis(bands: bands, rms: 0.6, peak: 0.9, centroid: 0.6, bassEnergy: 0.5, trebleEnergy: 0.3)
    }()

    // MARK: - Palette variants (all six)

    @Test("Metal halo across palettes", arguments: VisualizerPalette.allCases)
    func palettes(palette: VisualizerPalette) throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: palette)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-halo-\(palette.rawValue)"
        )
    }

    // MARK: - Accessibility variants

    @Test("Metal halo reduce motion")
    func reduceMotion() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, reduceMotion: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-halo-reduce-motion"
        )
    }

    @Test("Metal halo reduce transparency")
    func reduceTransparency() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, reduceTransparency: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-halo-reduce-transparency"
        )
    }

    // MARK: - Helpers

    private func render(
        palette: VisualizerPalette,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) throws -> NSImage {
        let device = try #require(MetalSupport.device)
        let halo = try MetalHalo(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(
                palette: palette, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
            )
        )
        halo.pixelsPerPointOverride = 1
        // Warm the EMA to its settled values, exactly like the Canvas fixture.
        for _ in 0 ..< 60 {
            halo.core.updateSmoothing(analysis: Self.analysis)
        }
        return try #require(MetalOffscreenRenderer.render(
            halo, size: Self.size, analysis: Self.analysis, samples: Self.silentSamples, time: 1000
        ))
    }
}
