import AudioEngine
import SwiftUI

// MARK: - Starfield

/// A field of stars flying outward from the centre, each star bound to one of
/// the 32 frequency bands so the field shimmers in patterns that mirror the
/// spectrum. Loud passages accelerate the whole field; detected onsets fire a
/// warp kick that stretches stars into streaks. In silence the field drifts
/// almost imperceptibly.
///
/// The star pool is a fixed-size `ContiguousArray` mutated in place (zero
/// per-frame heap allocation in steady state). Colour is resolved once per band
/// (32 lookups), never per star.
@MainActor
public final class Starfield: Visualizer {
    // MARK: - Star

    struct Star {
        var angle: Float // radians, fixed per life
        var radius: Float // 0...maxRadius, normalised to min(w, h) / 2
        var size: Float // 0.8...2.4 pt base
        var bandIndex: Int // 0...31, uniform distribution
        var twinklePhase: Float // 0...2 pi
    }

    // MARK: - Constants

    static let starCount = 500
    static let bandCount = 32
    static let maxRadius: Float = 1.1
    static let respawnRadius: Float = 0.02
    static let fadeInRadius: Float = 0.15
    static let baseSpeed: Float = 0.05
    static let warpPeak: Float = 2.0
    static let warpDecayTau: TimeInterval = 0.4
    static let streakThreshold: Float = 0.5
    static let maxDeltaTime: TimeInterval = 0.1
    static let minStarSize: Float = 0.8
    static let maxStarSize: Float = 2.4
    static let glowRadiusFraction: CGFloat = 0.22
    private static let minDrawOpacity = 0.05
    private static let twinkleBase = 0.85
    private static let twinkleAmplitude = 0.15
    private static let twinkleReducedAmplitude = 0.05
    private static let reduceTransparencyFloor = 0.6

    // MARK: - State (internal for testing)

    var stars: ContiguousArray<Star>
    /// Normalised position this frame and last frame, parallel to `stars`.
    /// Streaks draw `prevNorm -> currentNorm`; on respawn both are set to the
    /// new position so a recycled star never streaks across the whole screen.
    var currentNorm: [SIMD2<Float>]
    var prevNorm: [SIMD2<Float>]
    var warpBoost: Float = 0
    var lastTime: TimeInterval = -1
    var lastFrameIndex: UInt64 = 0
    /// Count of `PaletteResolver.color` calls in the most recent render's colour
    /// phase. Guards the per-band caching contract (32 + the single glow call).
    private(set) var colorResolveCount = 0

    // MARK: - Configuration

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    private var rng: SplitMix64

    // MARK: - Init

    public init(
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        seed: UInt64? = nil
    ) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        // nil seed resolves to a system-random seed (non-deterministic in
        // production); an explicit seed makes the whole field reproducible.
        var generator = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))

        var pool = ContiguousArray<Star>()
        pool.reserveCapacity(Self.starCount)
        var current = [SIMD2<Float>]()
        current.reserveCapacity(Self.starCount)
        for _ in 0 ..< Self.starCount {
            let star = Star(
                angle: Float.random(in: 0 ..< (2 * .pi), using: &generator),
                radius: Float.random(in: 0 ... 1.0, using: &generator),
                size: Float.random(in: Self.minStarSize ... Self.maxStarSize, using: &generator),
                bandIndex: Int.random(in: 0 ..< Self.bandCount, using: &generator),
                twinklePhase: Float.random(in: 0 ..< (2 * .pi), using: &generator)
            )
            pool.append(star)
            current.append(SIMD2(star.radius * cos(star.angle), star.radius * sin(star.angle)))
        }
        self.stars = pool
        self.currentNorm = current
        self.prevNorm = current
        self.rng = generator
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis,
        time: TimeInterval
    ) {
        self.advance(analysis: analysis, time: time)

        self.colorResolveCount = 0
        let bandColors = self.resolveBandColors(analysis: analysis, time: time)

        self.drawCoreGlow(into: &context, size: size, analysis: analysis, time: time)
        self.drawStars(into: &context, size: size, bandColors: bandColors, analysis: analysis, time: time)
    }

    // MARK: - Simulation (internal for testing)

    /// Integrates one frame: warp envelope, then per-star radial motion and
    /// respawn. Frozen entirely under reduce motion (the field becomes a still
    /// chart that only twinkles).
    func advance(analysis: Analysis, time: TimeInterval) {
        let dt = self.lastTime < 0 ? 0 : min(time - self.lastTime, Self.maxDeltaTime)
        self.lastTime = time

        // Warp envelope: decay first (frame-rate independent), then re-arm to
        // the peak on a freshly seen onset. Setting (not adding) means repeated
        // onsets re-trigger to the peak rather than stacking.
        self.warpBoost *= Float(exp(-dt / Self.warpDecayTau))
        if analysis.frameIndex != self.lastFrameIndex {
            self.lastFrameIndex = analysis.frameIndex
            if analysis.onset, !self.reduceMotion {
                self.warpBoost = Self.warpPeak
            }
        }

        guard !self.reduceMotion else { return }

        let bandCount = analysis.bands.count
        for index in self.stars.indices {
            self.prevNorm[index] = self.currentNorm[index]
            let star = self.stars[index]
            let bandEnergy = star.bandIndex < bandCount ? analysis.bands[star.bandIndex] : 0
            let speed = Self.baseSpeed + 0.5 * analysis.rms + 0.7 * bandEnergy + self.warpBoost
            let radius = star.radius + Float(dt) * speed * (0.3 + star.radius)

            if radius > Self.maxRadius {
                let angle = Float.random(in: 0 ..< (2 * .pi), using: &self.rng)
                self.stars[index].angle = angle
                self.stars[index].radius = Self.respawnRadius
                let position = SIMD2(Self.respawnRadius * cos(angle), Self.respawnRadius * sin(angle))
                self.currentNorm[index] = position
                self.prevNorm[index] = position // recycled star must not streak
            } else {
                self.stars[index].radius = radius
                self.currentNorm[index] = SIMD2(radius * cos(star.angle), radius * sin(star.angle))
            }
        }
    }

    // MARK: - Colour (internal for testing)

    /// One colour per band (32 lookups), shared by every star on that band.
    func resolveBandColors(analysis: Analysis, time: TimeInterval) -> [Color] {
        let bandCount = analysis.bands.count
        return (0 ..< Self.bandCount).map { band in
            let magnitude = band < bandCount ? analysis.bands[band] : 0
            self.colorResolveCount += 1
            return PaletteResolver.color(
                palette: self.palette,
                position: Double(band) / Double(Self.bandCount - 1),
                magnitude: magnitude,
                analysis: analysis,
                time: time
            )
        }
    }

    /// The central-glow colour, driven by bass energy. Counts as the single
    /// constant resolver call beyond the 32 per-band ones.
    func glowColor(analysis: Analysis, time: TimeInterval) -> Color {
        self.colorResolveCount += 1
        return PaletteResolver.color(
            palette: self.palette,
            position: 0.5,
            magnitude: analysis.bassEnergy,
            analysis: analysis,
            time: time
        )
    }

    // MARK: - Drawing (private)

    private func drawStars(
        into context: inout GraphicsContext,
        size: CGSize,
        bandColors: [Color],
        analysis: Analysis,
        time: TimeInterval
    ) {
        let scale = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bandCount = analysis.bands.count
        let streaking = !self.reduceMotion && self.warpBoost > Self.streakThreshold
        let amplitude = self.reduceMotion ? Self.twinkleReducedAmplitude : Self.twinkleAmplitude

        for index in self.stars.indices {
            let star = self.stars[index]
            let current = self.currentNorm[index]
            let point = CGPoint(x: center.x + CGFloat(current.x) * scale, y: center.y + CGFloat(current.y) * scale)

            let fade = self.reduceTransparency ? 1 : min(1, star.radius / Self.fadeInRadius)
            let twinkle = Self.twinkleBase + amplitude * sin(3 * time + Double(star.twinklePhase))
            var opacity = Double(fade) * twinkle
            let floorOpacity = self.reduceTransparency ? Self.reduceTransparencyFloor : Self.minDrawOpacity
            opacity = max(floorOpacity, opacity)

            let color = bandColors[star.bandIndex].opacity(opacity)

            if streaking {
                let previous = self.prevNorm[index]
                let from = CGPoint(x: center.x + CGFloat(previous.x) * scale, y: center.y + CGFloat(previous.y) * scale)
                var path = Path()
                path.move(to: from)
                path.addLine(to: point)
                context.stroke(path, with: .color(color), lineWidth: CGFloat(star.size))
            } else {
                let bandEnergy = star.bandIndex < bandCount ? analysis.bands[star.bandIndex] : 0
                let dotRadius = CGFloat(star.size * (0.6 + 0.6 * bandEnergy))
                let rect = CGRect(
                    x: point.x - dotRadius,
                    y: point.y - dotRadius,
                    width: 2 * dotRadius,
                    height: 2 * dotRadius
                )
                context.fill(Circle().path(in: rect), with: .color(color))
            }
        }
    }

    private func drawCoreGlow(
        into context: inout GraphicsContext,
        size: CGSize,
        analysis: Analysis,
        time: TimeInterval
    ) {
        guard analysis.bassEnergy > 0 else {
            // Still consume the constant resolver budget so the per-frame count
            // is stable whether or not bass is present.
            self.colorResolveCount += 1
            return
        }
        let glow = self.glowColor(analysis: analysis, time: time)
        let minDim = min(size.width, size.height)
        let radius = Self.glowRadiusFraction * minDim
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)

        if self.reduceTransparency {
            context.fill(Circle().path(in: rect), with: .color(glow.opacity(min(0.4, Double(analysis.bassEnergy)))))
        } else {
            context.fill(
                Circle().path(in: rect),
                with: .radialGradient(
                    Gradient(colors: [glow.opacity(Double(analysis.bassEnergy)), .clear]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }
}
