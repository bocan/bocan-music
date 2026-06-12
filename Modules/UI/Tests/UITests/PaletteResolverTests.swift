import AppKit
import SwiftUI
import Testing
@testable import UI

// MARK: - PaletteResolverTests

/// Guards the shared palette mapping introduced in phase 12.1: legacy-palette
/// parity, Drift determinism, and the Thermal heat ramp.
///
/// These resolve `Color` → `NSColor` to read components, so they run under the
/// SPM `make test-ui` harness (which links AppKit), not the host-less bundle.
@Suite("PaletteResolver")
@MainActor
struct PaletteResolverTests {
    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private func rgba(_ color: Color) -> RGBA {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return RGBA(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }

    private func hue(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return Double(ns.hueComponent)
    }

    private func luma(_ color: RGBA) -> Double {
        0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
    }

    // MARK: - Legacy-palette parity

    @Test("Spectrum reproduces the hue = position × 0.75 mapping")
    func spectrumParity() {
        for position in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let resolved = self.rgba(
                PaletteResolver.color(palette: .spectrum, position: position, magnitude: 0.5, analysis: .silent, time: 0)
            )
            let expected = self.rgba(Color(hue: position * 0.75, saturation: 0.9, brightness: 0.9))
            #expect(abs(resolved.red - expected.red) < 0.002)
            #expect(abs(resolved.green - expected.green) < 0.002)
            #expect(abs(resolved.blue - expected.blue) < 0.002)
        }
    }

    @Test("Ember reproduces the warm hue = position × 0.08 mapping")
    func emberParity() {
        for position in [0.0, 0.5, 1.0] {
            let resolved = self.rgba(
                PaletteResolver.color(palette: .ember, position: position, magnitude: 0.5, analysis: .silent, time: 0)
            )
            let expected = self.rgba(Color(hue: position * 0.08, saturation: 0.95, brightness: 0.95))
            #expect(abs(resolved.red - expected.red) < 0.002)
            #expect(abs(resolved.green - expected.green) < 0.002)
            #expect(abs(resolved.blue - expected.blue) < 0.002)
        }
    }

    @Test("Mono is white (the oscilloscope line stays white)")
    func monoIsWhite() {
        let white = self.rgba(PaletteResolver.color(palette: .mono, position: 0, magnitude: 1, analysis: .silent, time: 0))
        #expect(white.red > 0.99 && white.green > 0.99 && white.blue > 0.99)
    }

    @Test("Accent opacity tracks magnitude (0.7 → 1.0)")
    func accentOpacityTracksMagnitude() {
        let low = self.rgba(PaletteResolver.color(palette: .accent, position: 0, magnitude: 0, analysis: .silent, time: 0))
        let high = self.rgba(PaletteResolver.color(palette: .accent, position: 0, magnitude: 1, analysis: .silent, time: 0))
        #expect(abs(low.alpha - 0.7) < 0.02, "accent magnitude 0 alpha \(low.alpha) should be ~0.7")
        #expect(high.alpha > 0.98, "accent magnitude 1 alpha \(high.alpha) should be ~1.0")
    }

    // MARK: - Drift

    @Test("Drift is deterministic for a fixed (time, analysis)")
    func driftDeterminism() {
        let first = self.rgba(PaletteResolver.color(palette: .drift, position: 0.3, magnitude: 0.5, analysis: .silent, time: 1234))
        let second = self.rgba(PaletteResolver.color(palette: .drift, position: 0.3, magnitude: 0.5, analysis: .silent, time: 1234))
        #expect(first.red == second.red && first.green == second.green && first.blue == second.blue)
    }

    @Test("Drift advances hue by half a cycle over 45 s")
    func driftHalfCycle() {
        let h0 = self.hue(PaletteResolver.color(palette: .drift, position: 0.3, magnitude: 0.7, analysis: .silent, time: 0))
        let h1 = self.hue(PaletteResolver.color(palette: .drift, position: 0.3, magnitude: 0.7, analysis: .silent, time: 45))
        let delta = (h1 - h0 + 1).truncatingRemainder(dividingBy: 1)
        #expect(abs(delta - 0.5) < 0.02, "hue delta \(delta) should be ~0.5 after 45 s")
    }

    // MARK: - Thermal

    @Test("Thermal maps magnitude 0 near-black and 1.0 near-white")
    func thermalEndpoints() {
        let low = self.luma(self.rgba(PaletteResolver.color(palette: .thermal, position: 0, magnitude: 0, analysis: .silent, time: 0)))
        let high = self.luma(self.rgba(PaletteResolver.color(palette: .thermal, position: 0, magnitude: 1, analysis: .silent, time: 0)))
        #expect(low < 0.1, "thermal(0) luma \(low) should be near-black")
        #expect(high > 0.9, "thermal(1) luma \(high) should be near-white")
    }

    @Test("Thermal perceived brightness is monotonic across the ramp")
    func thermalMonotonic() {
        var previous = -1.0
        for step in 0 ... 10 {
            let level = Float(step) / 10
            let brightness = self.luma(self.rgba(PaletteResolver.color(
                palette: .thermal,
                position: 0,
                magnitude: level,
                analysis: .silent,
                time: 0
            )))
            #expect(brightness >= previous - 0.001, "thermal luma dropped at magnitude \(level): \(brightness) < \(previous)")
            previous = brightness
        }
    }

    @Test("Thermal ignores position")
    func thermalPositionIndependent() {
        let atZero = self.rgba(PaletteResolver.color(palette: .thermal, position: 0, magnitude: 0.5, analysis: .silent, time: 0))
        let atOne = self.rgba(PaletteResolver.color(palette: .thermal, position: 0.9, magnitude: 0.5, analysis: .silent, time: 7))
        #expect(atZero.red == atOne.red && atZero.green == atOne.green && atZero.blue == atOne.blue)
    }

    // MARK: - Ramp stops

    @Test("rampStops returns 8 stops for every palette")
    func rampStopsCount() {
        for palette in VisualizerPalette.allCases {
            let stops = PaletteResolver.rampStops(palette: palette, analysis: .silent, time: 0)
            #expect(stops.count == 8, "\(palette) produced \(stops.count) stops")
        }
    }

    @Test("Thermal rampStops rise monotonically in perceived brightness")
    func thermalRampStopsMonotonic() {
        let stops = PaletteResolver.rampStops(palette: .thermal, analysis: .silent, time: 0)
        var previous = -1.0
        for stop in stops {
            let brightness = self.luma(self.rgba(stop))
            #expect(brightness >= previous - 0.001)
            previous = brightness
        }
    }
}
