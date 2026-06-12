import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - CascadeTests

/// Unit tests for the Cascade visualizer ring buffer, LUT, frame dedup, and
/// reduceMotion stepped mode. Drawing correctness (scroll, now line, glow)
/// is covered by the companion snapshot tests.
@Suite("Cascade")
@MainActor
struct CascadeTests {
    // MARK: - Helpers

    private func makeAnalysis(
        bands: [Float]? = nil,
        onset: Bool = false,
        frameIndex: UInt64 = 1
    ) -> Analysis {
        let b = bands ?? [Float](repeating: 0, count: Cascade.bandCount)
        return Analysis(
            bands: b,
            rms: 0,
            peak: 0,
            onset: onset,
            frameIndex: frameIndex
        )
    }

    // MARK: - Column write

    @Test("Column write: single band k=1.0 writes LUT top entry at that band's memory row")
    func columnWriteSingleBand() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)

        var bands = [Float](repeating: 0, count: Cascade.bandCount)
        let testBand = 5
        bands[testBand] = 1.0
        let analysis = self.makeAnalysis(bands: bands, frameIndex: 1)
        cascade.processFrame(analysis: analysis, time: 1.0)

        // Column 0 was written; cursor is now 1.
        let expectedRow = Cascade.bandCount - 1 - testBand
        let pixel = cascade.pixelAt(column: 0, row: expectedRow)
        let lutTop = cascade.lut[Cascade.lutSize - 1]
        #expect(pixel == lutTop, "band \(testBand) row \(expectedRow): expected LUT[255]=\(lutTop), got \(pixel)")
    }

    @Test("Column write: zero-magnitude bands write the darkest LUT entry")
    func columnWriteZeroBand() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        cascade.processFrame(analysis: self.makeAnalysis(frameIndex: 1), time: 1.0)

        let darkest = cascade.lut[0]
        for band in 0 ..< Cascade.bandCount {
            let row = Cascade.bandCount - 1 - band
            let pixel = cascade.pixelAt(column: 0, row: row)
            #expect(pixel == darkest, "band \(band): expected darkest \(darkest), got \(pixel)")
        }
    }

    // MARK: - Ring wrap

    @Test("Ring wrap: after 300 frames cursor = 44 and marker column is at the expected column index")
    func ringWrap() {
        let cascade = Cascade(palette: .mono, reduceMotion: false, reduceTransparency: false)

        for i in 0 ..< 300 {
            let analysis = self.makeAnalysis(frameIndex: UInt64(i + 1))
            cascade.processFrame(analysis: analysis, time: Double(i) * Cascade.columnPeriod)
        }
        #expect(cascade.cursor == 300 % Cascade.columnCount) // 44

        // Write a marker at band 15 in the current cursor position (column 44).
        var markerBands = [Float](repeating: 0, count: Cascade.bandCount)
        markerBands[15] = 1.0
        cascade.processFrame(analysis: self.makeAnalysis(bands: markerBands, frameIndex: 301), time: 300 * Cascade.columnPeriod)

        let lutTop = cascade.lut[Cascade.lutSize - 1]
        let markerRow = Cascade.bandCount - 1 - 15
        let pixel = cascade.pixelAt(column: 44, row: markerRow)
        #expect(pixel == lutTop, "marker pixel: expected \(lutTop), got \(pixel)")
    }

    // MARK: - Frame dedup

    @Test("Frame dedup: same frameIndex fed 3 times writes exactly one column")
    func frameDedupWritesOnce() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        let analysis = self.makeAnalysis(frameIndex: 7)

        cascade.processFrame(analysis: analysis, time: 1.00)
        cascade.processFrame(analysis: analysis, time: 1.01)
        cascade.processFrame(analysis: analysis, time: 1.02)

        #expect(cascade.cursor == 1)
    }

    @Test("Frame dedup: three distinct frameIndexes write three columns")
    func frameDedupThreeFrames() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        for i in 1 ... 3 {
            cascade.processFrame(analysis: self.makeAnalysis(frameIndex: UInt64(i)), time: Double(i) * 0.023)
        }
        #expect(cascade.cursor == 3)
    }

    // MARK: - LUT correctness

    @Test("LUT thermal: index 0 is darker than index 255")
    func lutThermalDarknessOrdering() {
        var lut = [UInt32](repeating: 0, count: Cascade.lutSize)
        Cascade.buildLUT(into: &lut, palette: .thermal, analysis: .silent, time: 0)
        #expect(
            luminance(lut[0]) < luminance(lut[Cascade.lutSize - 1]),
            "thermal lut[0] not darker than lut[255]"
        )
    }

    @Test("LUT thermal palette is monotonically non-decreasing in luminance")
    func lutThermalMonotonic() {
        var lut = [UInt32](repeating: 0, count: Cascade.lutSize)
        Cascade.buildLUT(into: &lut, palette: .thermal, analysis: .silent, time: 0)
        for i in 1 ..< Cascade.lutSize {
            #expect(
                luminance(lut[i]) >= luminance(lut[i - 1]) - 1,
                "thermal LUT not monotonic at index \(i)"
            )
        }
    }

    @Test("LUT drift palette produces different entries at t=0 vs t=45 (half-cycle offset)")
    func lutDriftRepaint() {
        var lut0 = [UInt32](repeating: 0, count: Cascade.lutSize)
        var lut45 = [UInt32](repeating: 0, count: Cascade.lutSize)
        Cascade.buildLUT(into: &lut0, palette: .drift, analysis: .silent, time: 0)
        Cascade.buildLUT(into: &lut45, palette: .drift, analysis: .silent, time: 45)
        #expect(
            !zip(lut0, lut45).allSatisfy { $0 == $1 },
            "drift LUT identical at t=0 and t=45 (half-cycle)"
        )
    }

    // MARK: - Onset ticks

    @Test("Onset tick writes LUT[255] to top and bottom 2 memory rows of the column")
    func onsetTick() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: false, reduceTransparency: false)
        cascade.processFrame(analysis: self.makeAnalysis(onset: true, frameIndex: 1), time: 1.0)

        let full = cascade.lut[Cascade.lutSize - 1]
        #expect(cascade.pixelAt(column: 0, row: 0) == full, "onset top row 0")
        #expect(cascade.pixelAt(column: 0, row: 1) == full, "onset top row 1")
        #expect(cascade.pixelAt(column: 0, row: Cascade.bandCount - 2) == full, "onset bottom row-2")
        #expect(cascade.pixelAt(column: 0, row: Cascade.bandCount - 1) == full, "onset bottom row-1")
    }

    // MARK: - reduceMotion stepped mode

    @Test("reduceMotion: cachedImage unchanged within the 1-second step window")
    func reduceMotionStepped() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: true, reduceTransparency: false)

        cascade.processFrame(analysis: self.makeAnalysis(frameIndex: 1), time: 0.0)
        let imageAfterFirst = cascade.cachedImage

        // New frameIndex, but only 0.3 s have passed — within the 1 s window.
        cascade.processFrame(analysis: self.makeAnalysis(frameIndex: 2), time: 0.3)
        #expect(imageAfterFirst != nil)
        #expect(
            imageAfterFirst === cascade.cachedImage,
            "cachedImage changed within the 1 s stepped window"
        )
    }

    @Test("reduceMotion: cachedImage updates after 1-second step interval")
    func reduceMotionStepAfterInterval() {
        let cascade = Cascade(palette: .spectrum, reduceMotion: true, reduceTransparency: false)

        cascade.processFrame(analysis: self.makeAnalysis(frameIndex: 1), time: 0.0)
        let imageAfterFirst = cascade.cachedImage

        // 1.1 s elapsed — past the threshold.
        cascade.processFrame(analysis: self.makeAnalysis(frameIndex: 2), time: 1.1)
        #expect(
            imageAfterFirst !== cascade.cachedImage,
            "cachedImage did not update after 1 s stepped interval"
        )
    }

    // MARK: - Smoke test

    @Test("10 000 frames: cursor stays in bounds and no crash")
    func performanceSmokeTest() {
        let cascade = Cascade(palette: .thermal, reduceMotion: false, reduceTransparency: false)
        for i in 0 ..< 10000 {
            cascade.processFrame(
                analysis: self.makeAnalysis(frameIndex: UInt64(i + 1)),
                time: Double(i) * Cascade.columnPeriod
            )
        }
        #expect(cascade.cursor >= 0)
        #expect(cascade.cursor < Cascade.columnCount)
    }
}

// MARK: - Luminance helper

private func luminance(_ packed: UInt32) -> Double {
    let blue = Double(packed & 0xFF)
    let green = Double((packed >> 8) & 0xFF)
    let red = Double((packed >> 16) & 0xFF)
    return 0.299 * red + 0.587 * green + 0.114 * blue
}
