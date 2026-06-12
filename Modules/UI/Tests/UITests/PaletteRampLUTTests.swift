import AppKit
import Metal
import SwiftUI
import Testing
@testable import UI

// MARK: - PaletteRampLUTTests

/// Guards the shared magnitude ramp extracted from Cascade. The headline test
/// proves the extraction is byte-identical to the pre-refactor algorithm (an
/// independent reimplementation below), so the existing Cascade snapshots keep
/// passing without a re-record.
@Suite("PaletteRampLUT")
@MainActor
struct PaletteRampLUTTests {
    /// nonisolated so the @Test macro can read it from its argument context.
    private nonisolated static let allPalettes: [VisualizerPalette] = [
        .accent, .spectrum, .mono, .ember, .drift, .thermal,
    ]

    // MARK: - Byte-identical extraction

    @Test("Build matches the pre-refactor per-entry algorithm byte for byte", arguments: Self.allPalettes)
    func byteIdenticalToOldMath(palette: VisualizerPalette) {
        var built = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        PaletteRampLUT.build(into: &built, palette: palette, analysis: .silent, time: 1000)
        let reference = Self.referenceLUT(palette: palette, analysis: .silent, time: 1000)
        #expect(built == reference, "\(palette.rawValue) ramp drifted from the pre-refactor output")
    }

    // MARK: - Rebuild policy

    @Test("Static palettes build once and never rebuild")
    func staticPaletteBuildsOnce() {
        // rebuildIfNeeded is mutating, so resolve outside the #expect macro.
        var lut = PaletteRampLUT(palette: .thermal)
        let first = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        let second = lut.rebuildIfNeeded(analysis: .silent, time: 1000)
        let third = lut.rebuildIfNeeded(analysis: .silent, time: 99999)
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("Drift rebuilds only once the base hue moves past the threshold")
    func driftRebuildThreshold() {
        var lut = PaletteRampLUT(palette: .drift)
        let firstBuild = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        // +0.001 of a hue cycle (dt = 0.09 s at 1/90 per second) stays below 1/256.
        let belowThreshold = lut.rebuildIfNeeded(analysis: .silent, time: 0.09)
        // +0.01 of a cycle (dt = 0.9 s) crosses the threshold.
        let aboveThreshold = lut.rebuildIfNeeded(analysis: .silent, time: 0.9)
        #expect(firstBuild)
        #expect(!belowThreshold)
        #expect(aboveThreshold)
    }

    @Test("Drift produces a different ramp half a cycle apart")
    func driftRepaintAcrossTime() {
        var lut0 = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        var lut45 = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        PaletteRampLUT.build(into: &lut0, palette: .drift, analysis: .silent, time: 0)
        PaletteRampLUT.build(into: &lut45, palette: .drift, analysis: .silent, time: 45)
        #expect(!zip(lut0, lut45).allSatisfy { $0 == $1 })
    }

    // MARK: - Ramp shape

    @Test("Thermal ramp index 0 is darker than index 255")
    func thermalDarknessOrdering() {
        var lut = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        PaletteRampLUT.build(into: &lut, palette: .thermal, analysis: .silent, time: 0)
        #expect(Self.luminance(lut[0]) < Self.luminance(lut[PaletteRampLUT.size - 1]))
    }

    @Test("Thermal ramp is monotonically non-decreasing in luminance")
    func thermalMonotonic() {
        var lut = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        PaletteRampLUT.build(into: &lut, palette: .thermal, analysis: .silent, time: 0)
        for index in 1 ..< PaletteRampLUT.size {
            #expect(Self.luminance(lut[index]) >= Self.luminance(lut[index - 1]) - 1, "not monotonic at \(index)")
        }
    }

    // MARK: - GPU texture

    @Test("makeTexture produces a 256 x 1 bgra8Unorm texture")
    func makeTextureShape() {
        guard let device = MetalSupport.device else { return }
        var lut = PaletteRampLUT(palette: .thermal)
        _ = lut.rebuildIfNeeded(analysis: .silent, time: 0)
        guard let texture = lut.makeTexture(device: device) else {
            Issue.record("texture allocation failed")
            return
        }
        #expect(texture.width == PaletteRampLUT.size)
        #expect(texture.height == 1)
        #expect(texture.pixelFormat == .bgra8Unorm)
    }

    // MARK: - Reference implementation (the pre-refactor algorithm, verbatim)

    /// Independent reimplementation of the LUT build as it existed inside Cascade
    /// before extraction: resolve sRGB per entry pair, blend in `Double`, pack
    /// `B | G<<8 | R<<16 | A<<24` with `* 255 + 0.5` rounding.
    private static func referenceLUT(palette: VisualizerPalette, analysis: Analysis, time: TimeInterval) -> [UInt32] {
        let stops = PaletteResolver.rampStops(palette: palette, analysis: analysis, time: time)
        func srgb(_ color: Color) -> SIMD3<Double> {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return .zero }
            return SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        func blend(_ from: Color, _ to: Color, _ fraction: Double) -> UInt32 {
            let mixed = srgb(from) + (srgb(to) - srgb(from)) * fraction
            let red = UInt32(max(0, min(255, mixed.x * 255 + 0.5)))
            let green = UInt32(max(0, min(255, mixed.y * 255 + 0.5)))
            let blue = UInt32(max(0, min(255, mixed.z * 255 + 0.5)))
            return blue | (green << 8) | (red << 16) | 0xFF00_0000
        }
        var lut = [UInt32](repeating: 0, count: PaletteRampLUT.size)
        let stopCount = stops.count
        for index in 0 ..< PaletteRampLUT.size {
            let position = Double(index) / Double(PaletteRampLUT.size - 1)
            let segFloat = position * Double(stopCount - 1)
            let segment = min(stopCount - 2, Int(segFloat))
            let fraction = segFloat - Double(segment)
            lut[index] = blend(stops[segment], stops[segment + 1], fraction)
        }
        return lut
    }

    private static func luminance(_ packed: UInt32) -> Double {
        let blue = Double(packed & 0xFF)
        let green = Double((packed >> 8) & 0xFF)
        let red = Double((packed >> 16) & 0xFF)
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}
