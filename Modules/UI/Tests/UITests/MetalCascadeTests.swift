import AudioEngine
import Foundation
import Metal
import simd
import Testing
@testable import UI

// MARK: - MetalCascadeTests

/// Guards the Metal cascade's CPU side: the column bytes match the Canvas
/// renderer exactly (row flip and onset ticks), the ring cursor advances and
/// dedupes by frameIndex, the uniforms have the right layout and values, and the
/// reduce-motion step gating fires on the right cadence. GPU orientation is
/// covered by the snapshot suite.
@Suite("MetalCascade")
@MainActor
struct MetalCascadeTests {
    private static let size = CGSize(width: 600, height: 300)
    private static let silentSamples = AudioSamples(
        timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
    )

    private func makeAnalysis(
        bands: [Float]? = nil,
        onset: Bool = false,
        frameIndex: UInt64 = 1
    ) -> Analysis {
        let resolved = bands ?? [Float](repeating: 0, count: MetalCascade.bandCount)
        return Analysis(bands: resolved, rms: 0, peak: 0, onset: onset, frameIndex: frameIndex)
    }

    private func builtRamp(_ palette: VisualizerPalette) -> [UInt32] {
        var lut = PaletteRampLUT(palette: palette)
        _ = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        return lut.colors
    }

    // MARK: - Column parity with the Canvas renderer

    @Test("Column bytes match the Canvas writeColumn, including the row flip", arguments: [false, true])
    func columnParity(onset: Bool) {
        var bands = [Float](repeating: 0, count: MetalCascade.bandCount)
        bands[5] = 1.0
        bands[20] = 0.5
        let analysis = self.makeAnalysis(bands: bands, onset: onset, frameIndex: 1)

        // Metal builds the column directly.
        var column = [UInt32](repeating: 0xFF00_0000, count: MetalCascade.bandCount)
        MetalCascade.fillColumn(&column, analysis: analysis, ramp: self.builtRamp(.spectrum))

        // Canvas writes the same column into its bitmap; read it back per row.
        let canvas = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        canvas.processFrame(analysis: analysis, time: 1.0)
        for row in 0 ..< MetalCascade.bandCount {
            #expect(column[row] == canvas.pixelAt(column: 0, row: row), "row \(row) mismatch")
        }
    }

    // MARK: - Cursor, dedup, ring wrap

    @Test("Cursor advances on a new frame and dedupes a repeated frameIndex")
    func cursorDedup() {
        guard let cascade = self.makeRenderer(palette: .mono) else { return }
        let frame = self.makeAnalysis(frameIndex: 7)
        cascade.update(analysis: frame, samples: Self.silentSamples, time: 1.0, drawableSize: Self.size)
        cascade.update(analysis: frame, samples: Self.silentSamples, time: 1.01, drawableSize: Self.size)
        cascade.update(analysis: frame, samples: Self.silentSamples, time: 1.02, drawableSize: Self.size)
        #expect(cascade.cursor == 1)
    }

    @Test("300 new frames wrap the cursor to 44")
    func ringWrap() {
        guard let cascade = self.makeRenderer(palette: .mono) else { return }
        for index in 0 ..< 300 {
            let analysis = self.makeAnalysis(frameIndex: UInt64(index + 1))
            cascade.update(
                analysis: analysis,
                samples: Self.silentSamples,
                time: Double(index) * MetalCascade.columnPeriod,
                drawableSize: Self.size
            )
        }
        #expect(cascade.cursor == 300 % MetalCascade.columnCount)
    }

    // MARK: - Uniforms

    @Test("CascadeUniforms is 48 bytes (matches the MSL struct)")
    func uniformStride() {
        #expect(MemoryLayout<CascadeUniforms>.stride == 48)
    }

    @Test("Sub-column offset is 0 at write time and approaches 1 at one column period")
    func subColumnOffset() {
        guard let cascade = self.makeRenderer(palette: .spectrum) else { return }
        cascade.update(analysis: self.makeAnalysis(frameIndex: 1), samples: Self.silentSamples, time: 1.0, drawableSize: Self.size)
        // Immediately after the write, the offset is 0 and the now line shows.
        #expect(cascade.uniforms.cursorPlusOffset == Float(cascade.cursor))
        #expect(cascade.uniforms.showNowLine == 1)

        // Re-pack at nearly a full column period later: offset approaches 1.
        cascade.packUniforms(
            analysis: self.makeAnalysis(frameIndex: 1),
            time: 1.0 + MetalCascade.columnPeriod * 0.99,
            drawableSize: Self.size
        )
        let fraction = cascade.uniforms.cursorPlusOffset - Float(cascade.cursor)
        #expect(fraction > 0.9 && fraction <= 1.0, "fraction \(fraction)")
    }

    @Test("Reduce motion zeroes the now line and the offset")
    func reduceMotionUniforms() {
        guard let cascade = self.makeRenderer(palette: .spectrum, reduceMotion: true) else { return }
        cascade.update(analysis: self.makeAnalysis(frameIndex: 1), samples: Self.silentSamples, time: 1.0, drawableSize: Self.size)
        #expect(cascade.uniforms.showNowLine == 0)
        #expect(cascade.uniforms.glowAlpha == 0)
        #expect(cascade.uniforms.cursorPlusOffset == Float(cascade.steppedCursor))
    }

    // MARK: - Stepped gating

    @Test("Reduce motion steps the snapshot at most once per second")
    func steppedGating() {
        guard let cascade = self.makeRenderer(palette: .spectrum, reduceMotion: true) else { return }
        // First frame steps immediately (nil sentinel); steppedCursor captures cursor 1.
        cascade.update(analysis: self.makeAnalysis(frameIndex: 1), samples: Self.silentSamples, time: 0.0, drawableSize: Self.size)
        let afterFirst = cascade.steppedCursor

        // 0.3 s later: a new column accumulates but no step.
        cascade.update(analysis: self.makeAnalysis(frameIndex: 2), samples: Self.silentSamples, time: 0.3, drawableSize: Self.size)
        #expect(cascade.steppedCursor == afterFirst, "stepped too early")

        // 1.1 s after the last step: steps again, capturing the new cursor.
        cascade.update(analysis: self.makeAnalysis(frameIndex: 3), samples: Self.silentSamples, time: 1.1, drawableSize: Self.size)
        #expect(cascade.steppedCursor == cascade.cursor)
        #expect(cascade.steppedCursor != afterFirst)
    }

    // MARK: - Helpers

    private func makeRenderer(palette: VisualizerPalette, reduceMotion: Bool = false) -> MetalCascade? {
        guard let device = MetalSupport.device else { return nil }
        return try? MetalCascade(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(palette: palette, reduceMotion: reduceMotion, reduceTransparency: false)
        )
    }
}
