import AudioEngine
import Foundation
import Metal
import simd
import Testing
@testable import UI

// MARK: - MetalSpectrumBarsTests

/// Guards the Metal spectrum bars' CPU side: bar layout matches the Canvas
/// formulas, the peak-hold physics matches the Canvas trajectory exactly, the
/// instance buffer has the right counts and pre-applied alpha, and the instance
/// struct has the documented 48-byte stride. The SDF rendering is covered by the
/// snapshot suite.
@Suite("MetalSpectrumBars")
@MainActor
struct MetalSpectrumBarsTests {
    private static let size = CGSize(width: 400, height: 400)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    private func analysis(_ bands: [Float], frameIndex: UInt64 = 1) -> Analysis {
        Analysis(bands: bands, rms: 0, peak: 0, frameIndex: frameIndex)
    }

    private func midSpectrum() -> [Float] {
        (0 ..< MetalSpectrumBars.bandCount).map { sin(Float($0) / Float(MetalSpectrumBars.bandCount) * .pi) * 0.8 }
    }

    // MARK: - Layout parity

    @Test("Bar x positions and widths match the Canvas formulas")
    func layoutParity() {
        let bandCount = 32
        let layout = MetalSpectrumBars.layout(bandCount: bandCount, drawableSize: Self.size, pixelsPerPoint: 1)

        // Canvas formulas, verbatim (points == pixels at scale 1).
        let width = Float(Self.size.width)
        let spacing: Float = 2
        let expectedBarWidth = (width - spacing * Float(bandCount + 1)) / Float(bandCount)
        let expectedMaxBarHeight = Float(Self.size.height) - 4

        #expect(abs(layout.barWidth - expectedBarWidth) < 1e-3)
        #expect(abs(layout.maxBarHeight - expectedMaxBarHeight) < 1e-3)
        #expect(abs(layout.cornerRadius - min(3, expectedBarWidth / 2)) < 1e-3)
        for band in 0 ..< bandCount {
            let expectedX = spacing + Float(band) * (expectedBarWidth + spacing)
            #expect(abs(layout.x(band) - expectedX) < 1e-3, "band \(band)")
        }
    }

    // MARK: - Peak physics parity

    @Test("Peak-hold trajectory matches the Canvas physics over 120 frames")
    func peakPhysicsParity() {
        var metal = PeakHoldState(count: MetalSpectrumBars.bandCount)
        var reference = ReferencePeaks(count: MetalSpectrumBars.bandCount)

        // Scripted rise, hold, then fall on band 0; band 1 stays quiet.
        for frame in 0 ..< 120 {
            var magnitudes = [Float](repeating: 0, count: MetalSpectrumBars.bandCount)
            if frame < 10 {
                magnitudes[0] = Float(frame) / 10 // rise to 0.9
            } else if frame < 30 {
                magnitudes[0] = 0.9 // hold high
            } // else 0: let it fall
            metal.step(magnitudes: magnitudes)
            reference.step(magnitudes: magnitudes)
            for band in 0 ..< MetalSpectrumBars.bandCount {
                #expect(metal.hold[band] == reference.hold[band], "frame \(frame) band \(band)")
            }
        }
    }

    // MARK: - Instance buffer

    @Test("Normal mode yields 64 instances; bars are opaque, peaks at 0.9")
    func instancesNormal() {
        guard let bars = self.makeRenderer() else { return }
        let count = bars.buildInstances(analysis: self.analysis(self.midSpectrum()), time: 0, drawableSize: Self.size)
        #expect(count == MetalSpectrumBars.bandCount * 2)
        // Mono palette resolves to opaque white, so bar alpha is 1.0 and peak 0.9.
        #expect(abs(bars.instances[0].color.w - 1.0) < 1e-5)
        let firstPeak = bars.instances[MetalSpectrumBars.bandCount]
        #expect(abs(firstPeak.color.w - 0.9) < 1e-5)
        #expect(firstPeak.cornerRadius == 0) // peaks are plain rects
        #expect(bars.instances[0].cornerRadius > 0) // bars are rounded
    }

    @Test("Reduce motion yields 32 instances (no peaks) at half opacity")
    func instancesReduceMotion() {
        guard let bars = self.makeRenderer(reduceMotion: true) else { return }
        let count = bars.buildInstances(analysis: self.analysis(self.midSpectrum()), time: 0, drawableSize: Self.size)
        #expect(count == MetalSpectrumBars.bandCount)
        #expect(abs(bars.instances[0].color.w - 0.5) < 1e-5)
    }

    @Test("Reduce transparency forces full opacity even with reduce motion on")
    func instancesReduceTransparency() {
        guard let bars = self.makeRenderer(reduceMotion: true, reduceTransparency: true) else { return }
        _ = bars.buildInstances(analysis: self.analysis(self.midSpectrum()), time: 0, drawableSize: Self.size)
        #expect(abs(bars.instances[0].color.w - 1.0) < 1e-5)
    }

    // MARK: - Stride

    @Test("BarInstance has the documented 48-byte stride")
    func instanceStride() {
        #expect(MemoryLayout<BarInstance>.stride == 48)
    }

    // MARK: - Helpers

    private func makeRenderer(reduceMotion: Bool = false, reduceTransparency: Bool = false) -> MetalSpectrumBars? {
        guard let device = MetalSupport.device else { return nil }
        let bars = try? MetalSpectrumBars(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: .mono, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        )
        bars?.pixelsPerPointOverride = 1
        return bars
    }
}

// MARK: - ReferencePeaks (the Canvas physics, verbatim)

/// Independent reimplementation of `SpectrumBars.updatePeak`, used to prove the
/// `PeakHoldState` port is identical frame for frame.
private struct ReferencePeaks {
    private let gravity: Float = 0.004
    private let holdFrames = 30
    private(set) var hold: [Float]
    private var velocity: [Float]
    private var counter: [Int]

    init(count: Int) {
        self.hold = [Float](repeating: 0, count: count)
        self.velocity = [Float](repeating: 0, count: count)
        self.counter = [Int](repeating: 0, count: count)
    }

    mutating func step(magnitudes: [Float]) {
        for index in self.hold.indices where index < magnitudes.count {
            let magnitude = magnitudes[index]
            if magnitude >= self.hold[index] {
                self.hold[index] = magnitude
                self.velocity[index] = 0
                self.counter[index] = self.holdFrames
            } else if self.counter[index] > 0 {
                self.counter[index] -= 1
            } else {
                self.velocity[index] += self.gravity
                self.hold[index] = max(0, self.hold[index] - self.velocity[index])
            }
        }
    }
}
