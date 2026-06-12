import AppKit
import AudioEngine
import Metal
@testable import UI

// MARK: - MetalOffscreenRenderer

/// Renders one frame of a ``MetalVisualizer`` to an offscreen texture and returns
/// it as an `NSImage`, so Metal modes get snapshot coverage through the same
/// `assertSnapshot(of:as:.image)` workflow as the Canvas modes. Returns `nil`
/// when no Metal device is present (exotic CI), so callers can skip.
@MainActor
enum MetalOffscreenRenderer {
    static func render(
        _ renderer: any MetalVisualizer,
        size: CGSize,
        analysis: Analysis,
        samples: AudioSamples,
        time: TimeInterval
    ) -> NSImage? {
        guard let device = MetalSupport.device, let queue = device.makeCommandQueue() else { return nil }
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        renderer.update(
            analysis: analysis,
            samples: samples,
            time: time,
            drawableSize: CGSize(width: width, height: height)
        )

        guard
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        renderer.encode(into: encoder)
        encoder.endEncoding()
        renderer.didEncode(commandBuffer: commandBuffer)
        // Offscreen path only: blocking here is fine (never do this in the live view).
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return Self.image(from: texture, width: width, height: height)
    }

    private static func image(from texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // Texture is BGRA; match it with byteOrder32Little + premultipliedFirst.
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
