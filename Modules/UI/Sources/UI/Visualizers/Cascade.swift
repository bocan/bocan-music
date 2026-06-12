import AppKit
import AudioEngine
import SwiftUI

// MARK: - Cascade

/// Scrolling time-frequency heatmap: newest spectrum column appears at the right
/// edge and history slides continuously left, like a studio spectrogram. Frequency
/// runs bottom (bass) to top (treble); colour encodes magnitude via a 256-entry
/// LUT built from `PaletteResolver.rampStops`.
///
/// All per-frame heap allocation is eliminated in steady state: the bitmap and LUT
/// are allocated in `init` and reused; `makeImage()` swaps a 32 KB buffer handle.
@MainActor
public final class Cascade: Visualizer {
    // MARK: - Constants

    static let columnCount = 256 // ring-buffer width (≈ 6 s at 43 Hz)
    static let bandCount = 32 // bitmap height; one row per perceptual band
    static let lutSize = 256 // colour ramp entries
    /// Audio tap arrives at ~43 Hz; each column represents one analysis frame.
    static let columnPeriod: TimeInterval = 1.0 / 43.0
    private static let nowLineWidth: CGFloat = 1
    private static let newColumnGlowDuration: TimeInterval = 0.15
    private static let reduceMotionUpdateInterval: TimeInterval = 1.0
    /// Drift LUT rebuilds when the base hue has moved by this fraction of a full cycle.
    private static let driftLUTThreshold = 1.0 / 256.0

    // MARK: - State (internal visibility for testing)

    /// Index of the next column to write (ring-buffer write head).
    private(set) var cursor = 0
    /// The `frameIndex` from the last `Analysis` that produced a column write.
    private(set) var lastFrameIndex: UInt64 = 0
    /// Timestamp of the last column write. Used for sub-column smooth-scroll offset.
    private(set) var lastColumnTime: TimeInterval = 0
    /// The 256-entry BGRA colour ramp, index 0 = darkest, 255 = brightest.
    private(set) var lut: [UInt32]
    /// Last CGImage generated from the bitmap. Nil until the first column is written.
    private(set) var cachedImage: CGImage?

    // MARK: - Private state

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    private let bitmapCtx: CGContext
    private var imageIsDirty = false
    private var lastWriteTime: TimeInterval = 0
    /// Sentinel -1 = LUT not yet built for live analysis; 0 = built (non-drift);
    /// any other value = last hue at which drift LUT was built.
    private var driftBaseHue: Double = -1
    /// Timestamp of last stepped-mode display update (reduceMotion only).
    /// `nil` = never stepped (triggers immediate first step).
    private var lastStepTime: TimeInterval?

    // MARK: - Init

    public init(palette: VisualizerPalette, reduceMotion: Bool, reduceTransparency: Bool) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.lut = [UInt32](repeating: 0xFF00_0000, count: Self.lutSize)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // arm64 is little-endian, so byteOrder32Little == kCGBitmapByteOrder32Host.
        // This gives BGRA byte order: B at byte 0, G at byte 1, R at byte 2, A at byte 3.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
        )
        // Parameters are compile-time constants; failure here is a programmer error.
        guard let ctx = CGContext(
            data: nil,
            width: Self.columnCount,
            height: Self.bandCount,
            bitsPerComponent: 8,
            bytesPerRow: Self.columnCount * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            fatalError("Cascade: CGBitmapContext allocation failed")
        }
        self.bitmapCtx = ctx
        // Fill with opaque black so unwritten columns render as background.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Self.columnCount, height: Self.bandCount))
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis,
        time: TimeInterval
    ) {
        self.processFrame(analysis: analysis, time: time)
        guard let cgImage = self.cachedImage else { return }
        self.drawHistory(cgImage, into: &context, size: size, time: time)
        if !self.reduceMotion {
            self.drawNowLine(into: &context, size: size, analysis: analysis, time: time)
        }
    }

    // MARK: - Frame processing (internal for testing)

    /// Detects new analysis frames, writes columns to the ring buffer, manages
    /// the stepped display in reduceMotion mode, and refreshes `cachedImage`.
    /// Separated from `render` so tests can drive it without a live GraphicsContext.
    func processFrame(analysis: Analysis, time: TimeInterval) {
        self.maybeRebuildLUT(analysis: analysis, time: time)

        if analysis.frameIndex != self.lastFrameIndex {
            self.lastFrameIndex = analysis.frameIndex
            let shouldUpdateDisplay: Bool
            if self.reduceMotion {
                let sinceStep = self.lastStepTime.map { time - $0 } ?? Self.reduceMotionUpdateInterval
                shouldUpdateDisplay = sinceStep >= Self.reduceMotionUpdateInterval
                if shouldUpdateDisplay { self.lastStepTime = time }
            } else {
                shouldUpdateDisplay = true
            }
            self.writeColumn(analysis: analysis, time: time)
            if shouldUpdateDisplay { self.imageIsDirty = true }
        }

        if self.imageIsDirty {
            self.cachedImage = self.bitmapCtx.makeImage()
            self.imageIsDirty = false
        }
    }

    // MARK: - Column write (internal for testing)

    func writeColumn(analysis: Analysis, time: TimeInterval) {
        guard let rawData = self.bitmapCtx.data else { return }
        let pixels = rawData.bindMemory(to: UInt32.self, capacity: Self.columnCount * Self.bandCount)
        let col = self.cursor

        for band in 0 ..< Self.bandCount {
            let magnitude = band < analysis.bands.count ? analysis.bands[band] : 0
            let lutIndex = min(Self.lutSize - 1, Int(magnitude * Float(Self.lutSize - 1)))
            // Memory row 0 = top of image (treble); row (bandCount-1) = bottom (bass).
            // CGImage row 0 is top, so treble (band 31) at row 0, bass (band 0) at row 31.
            let row = Self.bandCount - 1 - band
            pixels[row * Self.columnCount + col] = self.lut[lutIndex]
        }

        // Onset ticks: overwrite top 2 and bottom 2 rows at full LUT intensity,
        // leaving visible marks on transient edges that make rhythms readable.
        if analysis.onset {
            let full = self.lut[Self.lutSize - 1]
            pixels[0 * Self.columnCount + col] = full
            pixels[1 * Self.columnCount + col] = full
            pixels[(Self.bandCount - 2) * Self.columnCount + col] = full
            pixels[(Self.bandCount - 1) * Self.columnCount + col] = full
        }

        self.cursor = (col + 1) % Self.columnCount
        self.lastColumnTime = time
        self.lastWriteTime = time
    }

    // MARK: - LUT management (internal for testing)

    func maybeRebuildLUT(analysis: Analysis, time: TimeInterval) {
        if self.palette != .drift {
            // Static palettes: build once on first live render so NSColor can
            // resolve dynamic colours (e.g. .accent) from the active environment.
            if self.driftBaseHue < 0 {
                Self.buildLUT(into: &self.lut, palette: self.palette, analysis: analysis, time: time)
                self.driftBaseHue = 0 // mark as built
            }
            return
        }
        // Drift palette: rebuild whenever the base hue moves by > 1/256 of a cycle.
        // History pixels retain their original colour (written with the old LUT) —
        // this is intentional: a drifting palette paints a slow rainbow across time.
        let raw = time / 90.0 + 0.25 * Double(analysis.centroid)
        let hue = raw - floor(raw)
        let diff: Double
        if self.driftBaseHue < 0 {
            diff = Self.driftLUTThreshold + 1 // force first build
        } else {
            let dist = abs(hue - self.driftBaseHue)
            diff = min(dist, 1.0 - dist) // wrap-aware distance
        }
        if diff > Self.driftLUTThreshold {
            Self.buildLUT(into: &self.lut, palette: .drift, analysis: analysis, time: time)
            self.driftBaseHue = hue
        }
    }

    /// Builds a 256-entry BGRA ramp by interpolating the 8 stops from
    /// `PaletteResolver.rampStops`. Static so it can be called from tests without
    /// a live instance, and so init can stage a call before `self` is complete.
    static func buildLUT(
        into lut: inout [UInt32],
        palette: VisualizerPalette,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let stops = PaletteResolver.rampStops(palette: palette, analysis: analysis, time: time)
        let stopCount = stops.count // always 8
        for i in 0 ..< Self.lutSize {
            let t = Double(i) / Double(Self.lutSize - 1)
            let segFloat = t * Double(stopCount - 1)
            let seg = min(stopCount - 2, Int(segFloat))
            let frac = segFloat - Double(seg)
            lut[i] = Self.blendColors(stops[seg], stops[seg + 1], fraction: frac)
        }
    }

    /// Linearly interpolates two SwiftUI `Color`s in sRGB and returns a packed
    /// BGRA `UInt32` suitable for the bitmap buffer.
    ///
    /// On little-endian (ARM64) with `kCGBitmapByteOrder32Host | premultipliedFirst`
    /// the byte order is B, G, R, A — packed as `B | (G<<8) | (R<<16) | (A<<24)`.
    static func blendColors(_ colorA: Color, _ colorB: Color, fraction: Double) -> UInt32 {
        func srgb(_ c: Color) -> SIMD3<Double> {
            guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return .zero }
            return SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        let ca = srgb(colorA)
        let cb = srgb(colorB)
        let mixed = ca + (cb - ca) * fraction
        let ir = UInt32(max(0, min(255, mixed.x * 255 + 0.5)))
        let ig = UInt32(max(0, min(255, mixed.y * 255 + 0.5)))
        let ib = UInt32(max(0, min(255, mixed.z * 255 + 0.5)))
        return ib | (ig << 8) | (ir << 16) | 0xFF00_0000
    }

    // MARK: - Pixel access (internal for testing)

    /// Reads a raw BGRA pixel from the bitmap. Row 0 = top (treble), row 31 = bottom (bass).
    func pixelAt(column: Int, row: Int) -> UInt32 {
        guard let data = self.bitmapCtx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt32.self, capacity: Self.columnCount * Self.bandCount)
        return pixels[row * Self.columnCount + column]
    }

    // MARK: - Drawing

    private func drawHistory(
        _ cgImage: CGImage,
        into context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let columnWidth = size.width / CGFloat(Self.columnCount)
        let subOffset: CGFloat
        if self.reduceMotion || self.lastColumnTime == 0 {
            subOffset = 0
        } else {
            let elapsed = max(0, time - self.lastColumnTime)
            subOffset = min(columnWidth * CGFloat(elapsed / Self.columnPeriod), columnWidth)
        }

        // Ring buffer split: [cursor..columnCount-1] = older, [0..cursor-1] = newer.
        let crop1Width = Self.columnCount - self.cursor // older portion
        let crop2Width = self.cursor // newer portion

        context.withCGContext { cgCtx in
            cgCtx.interpolationQuality = .low
            if crop1Width > 0 {
                let dw1 = CGFloat(crop1Width) * columnWidth
                let dest1 = CGRect(x: -subOffset, y: 0, width: dw1, height: size.height)
                let src1 = CGRect(x: self.cursor, y: 0, width: crop1Width, height: Self.bandCount)
                if let crop1 = cgImage.cropping(to: src1) {
                    self.blitCGImage(crop1, in: dest1, cgCtx: cgCtx)
                }
            }
            if crop2Width > 0 {
                let dw2 = CGFloat(crop2Width) * columnWidth
                let dest2 = CGRect(
                    x: CGFloat(crop1Width) * columnWidth - subOffset,
                    y: 0,
                    width: dw2,
                    height: size.height
                )
                let src2 = CGRect(x: 0, y: 0, width: crop2Width, height: Self.bandCount)
                if let crop2 = cgImage.cropping(to: src2) {
                    self.blitCGImage(crop2, in: dest2, cgCtx: cgCtx)
                }
            }
        }
    }

    /// Draws a CGImage into a CGContext that has SwiftUI's y-down coordinate system
    /// (as obtained from `GraphicsContext.withCGContext`). Applies a local y-flip so
    /// the image renders right-side-up: memory row 0 (treble) at the visual top.
    private func blitCGImage(_ image: CGImage, in rect: CGRect, cgCtx: CGContext) {
        cgCtx.saveGState()
        // SwiftUI canvas CTM has y pointing down; CGContext.draw expects y pointing up.
        // Translate to the bottom of the destination rect, then flip y.
        cgCtx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        cgCtx.scaleBy(x: 1, y: -1)
        cgCtx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cgCtx.restoreGState()
    }

    private func drawNowLine(
        into context: inout GraphicsContext,
        size: CGSize,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let nowColor = PaletteResolver.color(
            palette: self.palette,
            position: 1.0,
            magnitude: 1.0,
            analysis: analysis,
            time: time
        )
        let nowRect = CGRect(
            x: size.width - Self.nowLineWidth,
            y: 0,
            width: Self.nowLineWidth,
            height: size.height
        )
        context.fill(Path(nowRect), with: .color(nowColor))

        // Glow: white overlay at the now-line that fades over the first 150 ms
        // after a column write, giving a movement accent to each new data arrival.
        let age = time - self.lastWriteTime
        if self.lastWriteTime > 0, age < Self.newColumnGlowDuration {
            let alpha = 1.0 - age / Self.newColumnGlowDuration
            context.fill(Path(nowRect), with: .color(.white.opacity(alpha * 0.5)))
        }
    }
}
