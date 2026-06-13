import AudioEngine
import Foundation
import Metal
import Testing
@testable import UI

// MARK: - MetalNebulaTests

/// Guards the Nebula renderer's wiring and the testability contract: the renderer
/// builds through the standard factory, `renderScale` defaults to 0.6, and the
/// shader file carries no CPU/audio math (every audio-reactive number arrives as
/// a uniform from ``NebulaState``). The pixel output is covered by the snapshot
/// suite; the audio model by ``NebulaUniformsTests``.
@Suite("MetalNebula")
@MainActor
struct MetalNebulaTests {
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    // MARK: - Factory and mode wiring

    @Test("Nebula goes through the standard Metal factory")
    func factorySupportsNebula() {
        #expect(MetalVisualizerFactory.supports(.nebula))
    }

    @Test("Nebula requires Metal (no Canvas twin)")
    func nebulaRequiresMetal() {
        #expect(VisualizerMode.nebula.requiresMetal)
        for mode in VisualizerMode.allCases where mode != .nebula {
            #expect(!mode.requiresMetal, "\(mode) should not require Metal")
        }
    }

    // MARK: - Renderer defaults

    @Test("Renders at native resolution (renderScale 1.0)")
    func renderScaleDefault() {
        guard let device = MetalSupport.device else { return }
        guard let nebula = try? MetalNebula(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .thermal, reduceMotion: false, reduceTransparency: false)
        ) else { return }
        // Native resolution. Sub-1.0 drawable scaling re-entered the AppKit layout
        // pass and collapsed the live MTKView to a 1x1 drawable (a flat colour).
        #expect(nebula.renderScale == 1.0)
    }

    @Test("update advances the flow clock and renders at native resolution")
    func updateAdvancesState() {
        guard let device = MetalSupport.device else { return }
        guard let nebula = try? MetalNebula(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        ) else { return }
        nebula.update(
            analysis: Analysis(bands: [Float](repeating: 0, count: 32), rms: 0, peak: 0, bassEnergy: 1, frameIndex: 1),
            samples: Self.silentSamples,
            time: 0,
            drawableSize: CGSize(width: 400, height: 300)
        )
        nebula.update(
            analysis: Analysis(bands: [Float](repeating: 0, count: 32), rms: 0, peak: 0, bassEnergy: 1, frameIndex: 2),
            samples: Self.silentSamples,
            time: 1.0,
            drawableSize: CGSize(width: 400, height: 300)
        )
        #expect(nebula.uniforms.flowTime > 0)
        // Native resolution: the protocol default, after dropping the buggy
        // sub-1.0 drawable scale that collapsed the live view to a single pixel.
        #expect(nebula.renderScale == 1.0)
    }

    // MARK: - Source convention: no audio math in the shader

    @Test("Nebula.metal contains no audio-reactive CPU math (every value is a uniform)")
    func shaderHasNoAudioMath() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Resources/Shaders/Nebula.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        // The Analysis struct's energy field names must never appear in the shader:
        // they arrive packed as uniforms (centroidTint, onsetPulse, wispStrengths),
        // so finding a raw analysis field means the shader grew a CPU opinion and
        // broke the testability contract. (Legitimate uniform names like
        // `centroidTint` deliberately carry no raw `Analysis` field identifier.)
        for forbidden in ["bassEnergy", "midEnergy", "trebleEnergy", "Analysis"] {
            #expect(!source.contains(forbidden), "Nebula.metal must not reference \(forbidden)")
        }
    }
}
