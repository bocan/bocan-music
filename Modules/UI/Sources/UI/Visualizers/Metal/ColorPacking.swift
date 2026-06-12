import AppKit
import SwiftUI

// MARK: - ColorPacking

/// Converts SwiftUI `Color`s into the numeric forms the GPU paths consume.
///
/// **Colour parity, not colour purity.** Core Graphics fills with gamma-encoded
/// sRGB component values, so these helpers hand the same gamma-encoded values to
/// Metal (paired with a plain `.bgra8Unorm` pixel format and an sRGB layer
/// colorspace on the host). That keeps the Metal renderers visually identical to
/// their Canvas twins. Do not "correct" this to linear space; that guarantees a
/// washed-out drift from the reference renderers.
enum ColorPacking {
    /// Gamma-encoded sRGB components (RGBA) as floats, for shader uniforms.
    /// Returns opaque black on conversion failure (never crashes on an exotic
    /// dynamic colour).
    static func simd(_ color: Color) -> SIMD4<Float> {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return SIMD4(0, 0, 0, 1) }
        return SIMD4(
            Float(ns.redComponent),
            Float(ns.greenComponent),
            Float(ns.blueComponent),
            Float(ns.alphaComponent)
        )
    }

    /// Packs a colour into BGRA byte order (`B | G<<8 | R<<16 | A<<24`),
    /// little-endian, alpha forced opaque. Matches the `CGBitmapContext`
    /// `byteOrder32Little | premultipliedFirst` layout the Cascade history uses
    /// and the `.bgra8Unorm` Metal texture layout.
    static func bgra(_ color: Color) -> UInt32 {
        let rgb = Self.srgb(color)
        return Self.bgra(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    /// Packs explicit sRGB components (each 0...1) into the same BGRA layout.
    /// Shared by the ramp LUT, which blends components in floating point before
    /// packing so a single rounding step matches the Canvas output byte for byte.
    static func bgra(red: Double, green: Double, blue: Double) -> UInt32 {
        let packedRed = UInt32(max(0, min(255, red * 255 + 0.5)))
        let packedGreen = UInt32(max(0, min(255, green * 255 + 0.5)))
        let packedBlue = UInt32(max(0, min(255, blue * 255 + 0.5)))
        return packedBlue | (packedGreen << 8) | (packedRed << 16) | 0xFF00_0000
    }

    /// sRGB RGB components as doubles; opaque-black RGB (`.zero`) on failure.
    static func srgb(_ color: Color) -> SIMD3<Double> {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return .zero }
        return SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}
