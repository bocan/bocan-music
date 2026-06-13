import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalStarfieldSnapshotTests

/// Snapshot suite for the Metal starfield, rendered through
/// ``MetalOffscreenRenderer``. Each test seeds the composed field
/// deterministically and advances the same scripted mid-track sequence as the
/// Canvas `StarfieldSnapshotTests` fixture (same seed, same 89-frame warm-up,
/// frame 90 rendered), so the Metal output is comparable to the Canvas
/// reference. A streak variant fires an onset on the render frame; reduce-motion
/// and reduce-transparency variants exercise the accessibility paths.
///
/// Skipped when there is no Metal device, and disabled on CI like the other
/// snapshot suites.
@Suite(
    "Metal Starfield Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalStarfieldSnapshotTests {
    private static let size = CGSize(width: 480, height: 480)
    private static let seed: UInt64 = 0xBADC_0FFE_E0DD_F00D
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    /// The same mid-track spectrum the Canvas fixture scripts.
    private static let bands: [Float] = {
        var values = [Float](repeating: 0, count: Starfield.bandCount)
        for index in values.indices {
            let fraction = Float(index) / Float(values.count)
            values[index] = (sin(fraction * .pi * 2) * 0.5 + 0.5) * 0.8
        }
        return values
    }()

    private static func analysis(frameIndex: UInt64, onset: Bool = false) -> Analysis {
        Analysis(
            bands: self.bands,
            rms: 0.5,
            peak: 0.9,
            centroid: 0.6,
            onset: onset,
            bassEnergy: 0.5,
            trebleEnergy: 0.3,
            frameIndex: frameIndex
        )
    }

    // MARK: - Palette variants

    @Test("Metal starfield across palettes", arguments: VisualizerPalette.allCases)
    func palettes(palette: VisualizerPalette) throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: palette)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-starfield-\(palette.rawValue)"
        )
    }

    // MARK: - Behaviour variants

    @Test("Metal starfield warp streaks")
    func streaks() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, streak: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-starfield-streaks"
        )
    }

    @Test("Metal starfield reduce motion")
    func reduceMotion() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, reduceMotion: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-starfield-reduce-motion"
        )
    }

    @Test("Metal starfield reduce transparency")
    func reduceTransparency() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.render(palette: .spectrum, reduceTransparency: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-starfield-reduce-transparency"
        )
    }

    // MARK: - Helpers

    private func render(
        palette: VisualizerPalette,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        streak: Bool = false
    ) throws -> NSImage {
        let device = try #require(MetalSupport.device)
        let viz = try MetalStarfield(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency),
            seed: Self.seed
        )
        viz.pixelsPerPointOverride = 1

        // Warm up the composed core through the scripted scene (frames 1...89),
        // mirroring the Canvas fixture. The offscreen renderer's update() owns the
        // final frame (90), so the streak onset fires there with a real dt.
        for frame in 1 ... 89 {
            viz.core.advance(analysis: Self.analysis(frameIndex: UInt64(frame)), time: Double(frame) / 60.0)
        }
        return try #require(MetalOffscreenRenderer.render(
            viz,
            size: Self.size,
            analysis: Self.analysis(frameIndex: 90, onset: streak),
            samples: Self.silentSamples,
            time: 90.0 / 60.0
        ))
    }
}
