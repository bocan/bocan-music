import AudioEngine
import Foundation
import Metal
import simd
import Testing
@testable import UI

// MARK: - MetalOscilloscopeTests

/// Guards the Metal oscilloscope's CPU geometry: downsampling parity with the
/// Canvas renderer, the single y-flip into NDC, empty-input handling, the
/// reduce-motion freeze, and the uniform struct layout. The geometry is pure
/// static functions, so most of this runs without a GPU.
@Suite("MetalOscilloscope")
@MainActor
struct MetalOscilloscopeTests {
    private static let size = CGSize(width: 400, height: 400)

    private func sineSamples(count: Int) -> [Float] {
        (0 ..< count).map { sin(Float($0) / Float(count) * 4 * .pi) * 0.8 }
    }

    private func samples(mono: [Float], left: [Float] = [], right: [Float] = []) -> AudioSamples {
        AudioSamples(timeStamp: .init(), sampleRate: 44100, mono: mono, left: left, right: right, rms: 0, peak: 0)
    }

    // MARK: - Downsampling parity

    @Test("Waveform points match the Canvas downsampling loop exactly")
    func downsamplingParity() {
        let mono = self.sineSamples(count: 2048)
        let metal = MetalOscilloscope.waveformPoints(mono: mono, drawableSize: Self.size)
        let reference = Self.referenceWaveform(mono: mono, size: Self.size)
        #expect(metal.count == reference.count)
        for (point, expected) in zip(metal, reference) {
            #expect(abs(point.x - Float(expected.x)) < 1e-3)
            #expect(abs(point.y - Float(expected.y)) < 1e-3)
        }
    }

    // MARK: - NDC mapping

    @Test("Sample +1.0 maps to the top half (+0.9), -1.0 to the bottom (-0.9)")
    func ndcVerticalOrientation() {
        // mono[0] = +1.0 should sit near the top; the y-flip is the bug-prone bit.
        let high = MetalOscilloscope.waveformPoints(mono: [1.0, 0, 0, 0], drawableSize: Self.size)
        let low = MetalOscilloscope.waveformPoints(mono: [-1.0, 0, 0, 0], drawableSize: Self.size)
        let highNDC = MetalOscilloscope.toNDC(high[0], drawableSize: Self.size)
        let lowNDC = MetalOscilloscope.toNDC(low[0], drawableSize: Self.size)
        #expect(abs(highNDC.y - 0.9) < 1e-4, "got \(highNDC.y)")
        #expect(abs(lowNDC.y - -0.9) < 1e-4, "got \(lowNDC.y)")
        #expect(highNDC.y > 0, "sample +1.0 must be in the top half")
    }

    @Test("NDC x spans -1 at the first point to near +1 at the last")
    func ndcHorizontalSpan() {
        let points = MetalOscilloscope.waveformPoints(mono: self.sineSamples(count: 64), drawableSize: Self.size)
        let firstNDC = MetalOscilloscope.toNDC(points[0], drawableSize: Self.size)
        let lastNDC = MetalOscilloscope.toNDC(points[points.count - 1], drawableSize: Self.size)
        #expect(abs(firstNDC.x - -1) < 1e-4)
        #expect(lastNDC.x > 0.9)
    }

    @Test("toNDC corners map as expected")
    func ndcCorners() {
        #expect(MetalOscilloscope.toNDC(SIMD2(0, 0), drawableSize: Self.size).y == 1) // top
        #expect(MetalOscilloscope.toNDC(SIMD2(0, 400), drawableSize: Self.size).y == -1) // bottom
        #expect(MetalOscilloscope.toNDC(SIMD2(400, 0), drawableSize: Self.size).x == 1) // right
    }

    // MARK: - Empty input

    @Test("Fewer than two samples produces no geometry")
    func emptyInput() {
        #expect(MetalOscilloscope.waveformPoints(mono: [0.5], drawableSize: Self.size).isEmpty)
        #expect(MetalOscilloscope.waveformPoints(mono: [], drawableSize: Self.size).isEmpty)
        let geometry = MetalOscilloscope.vertices(
            samples: self.samples(mono: [0.5]),
            variant: .waveform,
            pixelsPerPoint: 1,
            drawableSize: Self.size
        )
        #expect(geometry.trace.isEmpty)
        #expect(geometry.line.isEmpty)
    }

    @Test("A waveform trace carries a centre line; an empty trace does not")
    func centreLinePresence() {
        let withTrace = MetalOscilloscope.vertices(
            samples: self.samples(mono: self.sineSamples(count: 128)),
            variant: .waveform,
            pixelsPerPoint: 1,
            drawableSize: Self.size
        )
        #expect(!withTrace.trace.isEmpty)
        #expect(withTrace.line.count == 4) // a 2-point open ribbon
    }

    @Test("Lissajous produces a trace and never a centre line")
    func lissajousHasNoCentreLine() {
        let left = self.sineSamples(count: 128)
        let right = (0 ..< 128).map { cos(Float($0) / 128 * 4 * .pi) * 0.8 }
        let geometry = MetalOscilloscope.vertices(
            samples: self.samples(mono: [], left: left, right: right),
            variant: .lissajous,
            pixelsPerPoint: 1,
            drawableSize: Self.size
        )
        #expect(!geometry.trace.isEmpty)
        #expect(geometry.line.isEmpty)
    }

    // MARK: - Reduce-motion freeze (instance; needs a device)

    @Test("Reduce motion freezes on the first non-empty buffer")
    func reduceMotionFreeze() throws {
        guard let device = MetalSupport.device else { return }
        let oscilloscope = try MetalOscilloscope(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .mono, reduceMotion: true, reduceTransparency: false)
        )
        let first = self.samples(mono: self.sineSamples(count: 64))
        let second = self.samples(mono: self.sineSamples(count: 128))
        let third = self.samples(mono: [Float](repeating: 0.5, count: 200))

        let resolved1 = oscilloscope.resolveActiveSamples(first)
        let resolved2 = oscilloscope.resolveActiveSamples(second)
        let resolved3 = oscilloscope.resolveActiveSamples(third)
        // Every later buffer resolves back to the first one's data.
        #expect(resolved1.mono == first.mono)
        #expect(resolved2.mono == first.mono)
        #expect(resolved3.mono == first.mono)
    }

    // MARK: - Uniform layout

    @Test("OscilloscopeUniforms is 32 bytes (matches the MSL struct)")
    func uniformStride() {
        #expect(MemoryLayout<OscilloscopeUniforms>.stride == 32)
    }

    // MARK: - Reference (the Canvas downsampling loop, verbatim)

    private static func referenceWaveform(mono: [Float], size: CGSize) -> [CGPoint] {
        guard mono.count >= 2 else { return [] }
        let targetPoints = min(512, mono.count)
        let step = max(1, mono.count / targetPoints)
        let midY = size.height / 2
        var path = [CGPoint]()
        for index in stride(from: 0, to: mono.count, by: step) {
            let x = size.width * CGFloat(index) / CGFloat(mono.count)
            let y = midY - CGFloat(mono[index]) * midY * 0.9
            path.append(CGPoint(x: x, y: y))
        }
        return path
    }
}
