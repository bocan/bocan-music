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
    static let lutSize = PaletteRampLUT.size // colour ramp entries
    /// Audio tap arrives at ~43 Hz; each column represents one analysis frame.
    static let columnPeriod: TimeInterval = 1.0 / 43.0
    private static let nowLineWidth: CGFloat = 1
    private static let newColumnGlowDuration: TimeInterval = 0.15
    private static let reduceMotionUpdateInterval: TimeInterval = 1.0

    // MARK: - State (internal visibility for testing)

    /// Index of the next column to write (ring-buffer write head).
    private(set) var cursor = 0
    /// The `frameIndex` from the last `Analysis` that produced a column write.
    private(set) var lastFrameIndex: UInt64 = 0
    /// Timestamp of the last column write. Used for sub-column smooth-scroll offset.
    private(set) var lastColumnTime: TimeInterval = 0
    /// The shared magnitude-to-colour ramp; built and drift-refreshed per frame.
    private(set) var rampLUT: PaletteRampLUT
    /// Last CGImage generated from the bitmap. Nil until the first column is written.
    private(set) var cachedImage: CGImage?

    /// Read-only view of the active colour ramp's packed entries, for tests.
    var lut: [UInt32] {
        self.rampLUT.colors
    }

    // MARK: - Private state

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    private let bitmapCtx: CGContext
    private var imageIsDirty = false
    private var lastWriteTime: TimeInterval = 0
    /// Timestamp of last stepped-mode display update (reduceMotion only).
    /// `nil` = never stepped (triggers immediate first step).
    private var lastStepTime: TimeInterval?

    // MARK: - Init

    public init(palette: VisualizerPalette, reduceMotion: Bool, reduceTransparency: Bool) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.rampLUT = PaletteRampLUT(palette: palette)

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
        // Static palettes build the ramp once; drift refreshes it as its hue moves.
        // History pixels keep the colour they were written with, so a drifting
        // palette paints a slow rainbow across the spectrogram's past.
        _ = self.rampLUT.rebuildIfNeeded(analysis: analysis, time: time)

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
        // Capture the ramp once: the array is value-typed, so indexing the stored
        // property repeatedly would churn copy-on-write handles in the loop.
        let ramp = self.rampLUT.colors

        for band in 0 ..< Self.bandCount {
            let magnitude = band < analysis.bands.count ? analysis.bands[band] : 0
            let lutIndex = min(Self.lutSize - 1, Int(magnitude * Float(Self.lutSize - 1)))
            // Memory row 0 = top of image (treble); row (bandCount-1) = bottom (bass).
            // CGImage row 0 is top, so treble (band 31) at row 0, bass (band 0) at row 31.
            let row = Self.bandCount - 1 - band
            pixels[row * Self.columnCount + col] = ramp[lutIndex]
        }

        // Onset ticks: overwrite top 2 and bottom 2 rows at full LUT intensity,
        // leaving visible marks on transient edges that make rhythms readable.
        if analysis.onset {
            let full = ramp[Self.lutSize - 1]
            pixels[0 * Self.columnCount + col] = full
            pixels[1 * Self.columnCount + col] = full
            pixels[(Self.bandCount - 2) * Self.columnCount + col] = full
            pixels[(Self.bandCount - 1) * Self.columnCount + col] = full
        }

        self.cursor = (col + 1) % Self.columnCount
        self.lastColumnTime = time
        self.lastWriteTime = time
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
