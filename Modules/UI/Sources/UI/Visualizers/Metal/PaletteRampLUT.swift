import Metal
import SwiftUI

// MARK: - PaletteRampLUT

/// A 256-entry magnitude-to-colour ramp built from the 8
/// `PaletteResolver.rampStops`, packed BGRA (index 0 darkest, 255 brightest).
///
/// Both the Canvas Cascade and the Metal renderers colour by magnitude through
/// this one table. Static palettes build it exactly once; the `drift` palette
/// rebuilds it as its base hue moves, which is what paints a slow rainbow across
/// a spectrogram's history. The packed entries map directly onto a `.bgra8Unorm`
/// texture, so the GPU path uploads them with no conversion.
struct PaletteRampLUT {
    static let size = 256

    /// Drift rebuilds when the base hue has moved more than 1/256 of a cycle.
    private static let driftThreshold = 1.0 / Double(size)

    /// BGRA-packed entries, index 0 = darkest stop, 255 = brightest.
    private(set) var colors: [UInt32]

    private let palette: VisualizerPalette
    /// `-1` = never built; `0` = built (static palette); otherwise the hue at
    /// which the drift LUT was last rebuilt.
    private var driftBaseHue: Double = -1

    init(palette: VisualizerPalette) {
        self.palette = palette
        self.colors = [UInt32](repeating: 0xFF00_0000, count: Self.size)
    }

    /// Rebuilds the ramp when needed: once on first call for static palettes,
    /// and whenever the drift base hue moves past the threshold. Returns `true`
    /// when it actually rebuilt (so callers can re-upload a GPU texture only then).
    mutating func rebuildIfNeeded(analysis: Analysis, time: TimeInterval) -> Bool {
        guard self.palette == .drift else {
            if self.driftBaseHue < 0 {
                Self.build(into: &self.colors, palette: self.palette, analysis: analysis, time: time)
                self.driftBaseHue = 0
                return true
            }
            return false
        }
        // Drift: rebuild when the wrap-aware hue distance exceeds the threshold.
        let raw = time / 90.0 + 0.25 * Double(analysis.centroid)
        let hue = raw - floor(raw)
        let diff: Double
        if self.driftBaseHue < 0 {
            diff = Self.driftThreshold + 1 // force the first build
        } else {
            let dist = abs(hue - self.driftBaseHue)
            diff = min(dist, 1.0 - dist)
        }
        guard diff > Self.driftThreshold else { return false }
        Self.build(into: &self.colors, palette: .drift, analysis: analysis, time: time)
        self.driftBaseHue = hue
        return true
    }

    /// Builds the 256 entries by resolving the 8 ramp stops to sRGB once and
    /// interpolating between adjacent stops in floating point, then packing.
    /// Static so tests can compare output without an instance.
    static func build(
        into lut: inout [UInt32],
        palette: VisualizerPalette,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let stops = PaletteResolver.rampStops(palette: palette, analysis: analysis, time: time)
        // Resolve each stop's sRGB components once (8 conversions) rather than
        // per entry (512); the interpolation math is unchanged, so the packed
        // bytes match the previous per-entry path exactly.
        let srgbStops = stops.map { ColorPacking.srgb($0) }
        let stopCount = srgbStops.count
        for index in 0 ..< Self.size {
            let position = Double(index) / Double(Self.size - 1)
            let segFloat = position * Double(stopCount - 1)
            let segment = min(stopCount - 2, Int(segFloat))
            let fraction = segFloat - Double(segment)
            let from = srgbStops[segment]
            let to = srgbStops[segment + 1]
            let mixed = from + (to - from) * fraction
            lut[index] = ColorPacking.bgra(red: mixed.x, green: mixed.y, blue: mixed.z)
        }
    }

    // MARK: - GPU texture

    /// Creates a 256 x 1 `.bgra8Unorm` shared-storage texture holding the current
    /// ramp. `nil` if texture allocation fails.
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.size,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.upload(into: texture)
        return texture
    }

    /// Re-uploads the current ramp into an existing texture (drift regeneration).
    func upload(into texture: MTLTexture) {
        self.colors.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.size, 1),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: Self.size * 4
            )
        }
    }
}
