import SwiftUI
import Testing
@testable import UI

// MARK: - ColorPackingTests

/// Guards the BGRA packing and sRGB float conversion the GPU paths rely on. The
/// byte order here is load-bearing: a wrong shift renders every colour wrong.
@Suite("ColorPacking")
@MainActor
struct ColorPackingTests {
    @Test("White packs to fully opaque white")
    func whitePacks() {
        #expect(ColorPacking.bgra(.white) == 0xFFFF_FFFF)
    }

    @Test("Pure red has B=0 G=0 R=255 in the packed word")
    func redPacks() {
        let packed = ColorPacking.bgra(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
        #expect(packed & 0xFF == 0x00) // blue byte
        #expect((packed >> 8) & 0xFF == 0x00) // green byte
        #expect((packed >> 16) & 0xFF == 0xFF) // red byte
        #expect((packed >> 24) & 0xFF == 0xFF) // alpha byte
    }

    @Test("Pure blue has B=255 R=0 in the packed word")
    func bluePacks() {
        let packed = ColorPacking.bgra(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1))
        #expect(packed & 0xFF == 0xFF) // blue byte
        #expect((packed >> 16) & 0xFF == 0x00) // red byte
    }

    @Test("Explicit-component packing rounds and clamps")
    func componentPacking() {
        #expect(ColorPacking.bgra(red: 0, green: 0, blue: 0) == 0xFF00_0000)
        #expect(ColorPacking.bgra(red: 1, green: 1, blue: 1) == 0xFFFF_FFFF)
        // Out-of-range components clamp rather than overflow.
        #expect(ColorPacking.bgra(red: 2, green: -1, blue: 0.5) == (0x80 | (0x00 << 8) | (0xFF << 16) | 0xFF00_0000))
    }

    @Test("simd round-trips a known sRGB colour within one 8-bit step")
    func simdRoundTrip() {
        let color = Color(.sRGB, red: 0.25, green: 0.5, blue: 0.75, opacity: 1)
        let components = ColorPacking.simd(color)
        #expect(abs(components.x - 0.25) < 1.0 / 255)
        #expect(abs(components.y - 0.5) < 1.0 / 255)
        #expect(abs(components.z - 0.75) < 1.0 / 255)
        #expect(abs(components.w - 1.0) < 1.0 / 255)
    }
}
