import AppKit
import AudioEngine
import Foundation
import Metal
import SnapshotTesting
import Testing
@testable import UI

// MARK: - MetalCascadeSnapshotTests

/// Snapshot suite for the Metal cascade, rendered through ``MetalOffscreenRenderer``.
///
/// Each test feeds a scripted 64-frame frequency sweep with two onsets (mirroring
/// the Canvas `CascadeSnapshotTests` script) into the history texture, then
/// renders the final frame. The orientation test additionally checks the actual
/// pixels: bass at the bottom, treble at the top, newest column at the right.
///
/// Skipped when there is no Metal device, and disabled on CI like the other
/// snapshot suites.
@Suite(
    "Metal Cascade Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; GPU rendering differs on CI runners."
    )
)
@MainActor
struct MetalCascadeSnapshotTests {
    private static let size = CGSize(width: 600, height: 300)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    // MARK: - Palette variants

    @Test("Metal cascade across palettes", arguments: VisualizerPalette.allCases)
    func palettes(palette: VisualizerPalette) throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.renderSweep(palette: palette, reduceMotion: false)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-cascade-\(palette.rawValue)"
        )
    }

    @Test("Metal cascade reduce motion")
    func reduceMotion() throws {
        guard MetalSupport.device != nil else { return }
        let image = try self.renderSweep(palette: .spectrum, reduceMotion: true)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "metal-cascade-reduce-motion"
        )
    }

    // MARK: - Orientation (bass bottom, treble top, newest right)

    @Test("Bass lands at the bottom and treble at the top, newest column at the right")
    func orientation() throws {
        guard let device = MetalSupport.device else { return }

        // A bright bass band (0) should be brightest at the bottom; a bright
        // treble band (31) at the top. Render each and compare top vs bottom of
        // the newest (rightmost) column.
        let bassImage = try Self.renderRaw(device: device, brightBand: 0)
        let trebleImage = try Self.renderRaw(device: device, brightBand: 31)

        let column = bassImage.width - 4 // newest column, inset past the wrap seam
        let bassTop = Self.luminance(bassImage, x: column, y: 4)
        let bassBottom = Self.luminance(bassImage, x: column, y: bassImage.height - 4)
        let trebleTop = Self.luminance(trebleImage, x: column, y: 4)
        let trebleBottom = Self.luminance(trebleImage, x: column, y: trebleImage.height - 4)

        #expect(bassBottom > bassTop + 40, "bass should be brighter at the bottom")
        #expect(trebleTop > trebleBottom + 40, "treble should be brighter at the top")
    }

    // MARK: - Helpers

    private func renderSweep(palette: VisualizerPalette, reduceMotion: Bool) throws -> NSImage {
        let device = try #require(MetalSupport.device)
        let cascade = try MetalCascade(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: reduceMotion, reduceTransparency: false)
        )
        cascade.pixelsPerPointOverride = 1
        // Feed frames 1...63 into the history; the final frame is rendered below.
        for frame in 1 ..< 64 {
            cascade.update(
                analysis: Self.scriptedAnalysis(frame: frame),
                samples: Self.silentSamples,
                time: Double(frame) * MetalCascade.columnPeriod,
                drawableSize: Self.size
            )
        }
        return try #require(MetalOffscreenRenderer.render(
            cascade,
            size: Self.size,
            analysis: Self.scriptedAnalysis(frame: 64),
            samples: Self.silentSamples,
            time: 64 * MetalCascade.columnPeriod
        ))
    }

    /// A moving band of energy plus two onset beats, matching the Canvas script.
    private static func scriptedAnalysis(frame: Int) -> Analysis {
        var bands = [Float](repeating: 0, count: MetalCascade.bandCount)
        let active = frame % MetalCascade.bandCount
        for band in 0 ..< MetalCascade.bandCount {
            let distance = abs(band - active)
            bands[band] = max(0, 1 - Float(distance) * 0.1)
        }
        let onset = frame == 16 || frame == 48
        return Analysis(
            bands: bands,
            rms: 0.5,
            peak: 0.9,
            centroid: Float(frame) / 63,
            onset: onset,
            frameIndex: UInt64(frame)
        )
    }

    /// One column on `brightBand`, rendered to a render-target texture and read
    /// back as raw BGRA. Texture row 0 is unambiguously the top of the image, so
    /// there is no NSImage redraw flip to reason about.
    private struct RawImage {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private static func renderRaw(device: MTLDevice, brightBand: Int) throws -> RawImage {
        // Thermal maps magnitude to brightness (mono would render every band
        // white and could not distinguish bass from treble rows).
        let cascade = try MetalCascade(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .thermal, reduceMotion: false, reduceTransparency: false)
        )
        cascade.pixelsPerPointOverride = 1
        let queue = try #require(device.makeCommandQueue())
        let width = Int(Self.size.width)
        let height = Int(Self.size.height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        var bands = [Float](repeating: 0, count: MetalCascade.bandCount)
        bands[brightBand] = 1.0
        // Write a run of identical columns so the newest portion of the screen is
        // a solid bright band (one column is only ~2 px wide and easy to miss).
        for frame in 1 ... 40 {
            cascade.update(
                analysis: Analysis(bands: bands, rms: 1, peak: 1, frameIndex: UInt64(frame)),
                samples: Self.silentSamples,
                time: Double(frame) * MetalCascade.columnPeriod,
                drawableSize: CGSize(width: width, height: height)
            )
        }
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        cascade.encode(into: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return RawImage(bytes: bytes, width: width, height: height)
    }

    private static func luminance(_ image: RawImage, x: Int, y: Int) -> Int {
        let index = (y * image.width + x) * 4
        guard index + 2 < image.bytes.count else { return 0 }
        // BGRA byte order.
        let blue = Int(image.bytes[index])
        let green = Int(image.bytes[index + 1])
        let red = Int(image.bytes[index + 2])
        return (red * 299 + green * 587 + blue * 114) / 1000
    }
}
