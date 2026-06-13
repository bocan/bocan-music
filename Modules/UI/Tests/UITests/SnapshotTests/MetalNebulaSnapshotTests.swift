import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalNebulaSnapshotTests

/// Snapshot suite for the Nebula gas shader, rendered through
/// ``MetalOffscreenRenderer``. Every uniform is fixed: a fresh ``NebulaState`` is
/// driven through a fixed scripted scene with a fixed `dt` to a known `flowTime`
/// and envelope, then packed once and installed via
/// ``MetalNebula/setUniformsForTesting(_:)``. The renderer's live `update` is
/// never called, so the GPU output depends on nothing but the pinned inputs and
/// the palette across all six palettes.
///
/// Skipped when there is no Metal device, and disabled on CI like the other
/// snapshot suites (GPU rasterisation differs across runners).
@Suite(
    "Metal Nebula Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalNebulaSnapshotTests {
    private static let size = CGSize(width: 480, height: 360)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    /// A fixed mid-track spectrum: a gentle rising ramp across the 32 bands so all
    /// four band groups carry energy and every wisp is visible.
    private static let bands: [Float] = {
        var values = [Float](repeating: 0, count: 32)
        for index in values.indices {
            values[index] = 0.25 + 0.6 * Float(index) / 31
        }
        return values
    }()

    private static func analysis(frameIndex: UInt64, onset: Bool = false) -> Analysis {
        Analysis(
            bands: self.bands,
            rms: 0.5,
            peak: 0.9,
            centroid: 0.65,
            onset: onset,
            bassEnergy: 0.6,
            midEnergy: 0.45,
            trebleEnergy: 0.3,
            frameIndex: frameIndex
        )
    }

    /// Builds fixed uniforms: integrate a fresh state through 40 scripted frames at
    /// a fixed 60 Hz dt (one onset near the end), then pack the final frame. Pure
    /// and deterministic, so the snapshot is stable.
    private static func fixedUniforms() -> NebulaUniforms {
        var state = NebulaState()
        let dt = 1.0 / 60.0
        for frame in 1 ... 40 {
            let onset = frame == 36
            _ = state.update(
                analysis: self.analysis(frameIndex: UInt64(frame), onset: onset),
                time: Double(frame) * dt,
                drawableSize: self.size
            )
        }
        return state.pack(analysis: self.analysis(frameIndex: 41), drawableSize: self.size)
    }

    // MARK: - Palette matrix

    @Test("Nebula across palettes", arguments: VisualizerPalette.allCases)
    func palettes(palette: VisualizerPalette) throws {
        guard let device = MetalSupport.device else { return }
        let nebula = try MetalNebula(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: false, reduceTransparency: false)
        )
        nebula.setUniformsForTesting(Self.fixedUniforms())

        // Encode directly with the pinned uniforms: do not call the live update.
        let image = try #require(Self.renderPinned(nebula, device: device))
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-nebula-\(palette.rawValue)"
        )
    }

    // MARK: - Helpers

    /// Renders one frame without calling `renderer.update`, so the uniforms pinned
    /// via ``MetalNebula/setUniformsForTesting(_:)`` survive into the encode.
    private static func renderPinned(_ nebula: MetalNebula, device: MTLDevice) -> NSImage? {
        guard let queue = device.makeCommandQueue() else { return nil }
        let width = Int(self.size.width)
        let height = Int(self.size.height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        nebula.encode(into: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return Self.image(from: texture, width: width, height: height)
    }

    private static func image(from texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
