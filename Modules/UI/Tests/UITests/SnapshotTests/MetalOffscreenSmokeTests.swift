import AudioEngine
import Metal
import Testing
@testable import UI

// MARK: - NoopMetalVisualizer

/// A do-nothing renderer: its initializer succeeds, it keeps no state, and it
/// encodes no draw calls, so a rendered frame is just the render pass's black
/// clear. Used to smoke-test the offscreen render path and the factory wrapper.
@MainActor
final class NoopMetalVisualizer: MetalVisualizer {
    init(device: MTLDevice, pixelFormat: MTLPixelFormat, config: MetalRendererConfig) throws {}
    func update(analysis: Analysis, samples: AudioSamples, time: TimeInterval, drawableSize: CGSize) {}
    func encode(into encoder: MTLRenderCommandEncoder) {}
}

// MARK: - MetalOffscreenSmokeTests

/// Confirms the offscreen render path produces an image end to end on a real
/// device. Skipped when no Metal device is available.
@Suite("MetalOffscreenRenderer")
@MainActor
struct MetalOffscreenSmokeTests {
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    @Test("A do-nothing renderer produces a non-nil cleared image at the requested size")
    func smokeRender() throws {
        guard let device = MetalSupport.device else { return }
        let renderer = try NoopMetalVisualizer(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .accent, reduceMotion: false, reduceTransparency: false)
        )
        let image = MetalOffscreenRenderer.render(
            renderer,
            size: CGSize(width: 64, height: 64),
            analysis: .silent,
            samples: Self.silentSamples,
            time: 0
        )
        let unwrapped = try #require(image)
        #expect(unwrapped.size.width == 64)
        #expect(unwrapped.size.height == 64)
    }
}
