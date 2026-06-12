import AudioEngine
import SwiftUI

// MARK: - Halo

/// Circular spectrum visualizer: 32 bands mirrored to 64 spokes joined via
/// Catmull-Rom smoothing into a breathing, rotating closed shape. Detected
/// onsets spawn expanding ripple rings drawn from a fixed pool (zero per-frame
/// heap allocation in steady state).
@MainActor
public final class Halo: Visualizer {
    // MARK: - Ripple

    struct Ripple {
        var birth: TimeInterval
        var color: Color
        var isActive: Bool
        var spawnRadius: CGFloat
    }

    // MARK: - Constants

    static let bandCount = 32
    static let spokeCount = 64
    static let ripplePoolSize = 6
    static let rippleLifetime: TimeInterval = 1.2
    static let baseRadiusFraction: CGFloat = 0.32
    static let extentFraction: CGFloat = 0.18
    private static let breathingDepth: CGFloat = 0.06
    private static let rmsAttack: Float = 0.15
    private static let rmsAttackReduced: Float = 0.03
    private static let bandAttack: Float = 0.08
    private static let bandAttackReduced: Float = 0.03
    private static let maxDeltaTime: TimeInterval = 0.1

    // MARK: - State (internal for testing)

    var rotationPhase: Double = 0
    var smoothedBands: [Float]
    var rmsEMA: Float = 0
    var ripplePool: [Ripple]
    var lastTime: TimeInterval = 0

    // MARK: - Configuration

    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool

    // MARK: - Init

    public init(
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.smoothedBands = [Float](repeating: 0, count: Self.bandCount)
        self.ripplePool = (0 ..< Self.ripplePoolSize).map { _ in
            Ripple(birth: 0, color: .clear, isActive: false, spawnRadius: 0)
        }
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let dt = self.lastTime == 0 ? 0 : min(time - self.lastTime, Self.maxDeltaTime)
        self.lastTime = time

        self.updateSmoothing(analysis: analysis)

        if !self.reduceMotion {
            self.updateRotation(analysis: analysis, dt: dt)
        }

        let cx = size.width / 2
        let cy = size.height / 2
        let center = CGPoint(x: cx, y: cy)
        let minDim = min(size.width, size.height)
        let baseRadius = Self.baseRadiusFraction * minDim
        let extent = Self.extentFraction * minDim
        let breathingRadius = baseRadius * (1 + Self.breathingDepth * CGFloat(self.rmsEMA * 2 - 1))

        if !self.reduceMotion, analysis.onset {
            self.spawnRipple(atRadius: breathingRadius + extent, time: time, analysis: analysis)
        }

        let tips = self.computeTips(center: center, breathingRadius: breathingRadius, extent: extent)
        let ringPath = self.buildCatmullRomPath(tips: tips)
        self.drawRing(into: &context, path: ringPath, center: center, analysis: analysis, time: time)
        self.drawRipples(into: &context, center: center, minDim: minDim, time: time)
        self.drawCentreGlow(into: &context, center: center, radius: breathingRadius, analysis: analysis, time: time)
    }

    // MARK: - State helpers (internal for testing)

    func updateSmoothing(analysis: Analysis) {
        let rmsAlpha: Float = self.reduceMotion ? Self.rmsAttackReduced : Self.rmsAttack
        let bandAlpha: Float = self.reduceMotion ? Self.bandAttackReduced : Self.bandAttack
        self.rmsEMA = rmsAlpha * analysis.rms + (1 - rmsAlpha) * self.rmsEMA
        let count = min(analysis.bands.count, Self.bandCount)
        for index in 0 ..< count {
            self.smoothedBands[index] = bandAlpha * analysis.bands[index] + (1 - bandAlpha) * self.smoothedBands[index]
        }
    }

    func updateRotation(analysis: Analysis, dt: TimeInterval) {
        self.rotationPhase += (0.02 + 0.08 * Double(analysis.trebleEnergy)) * dt
    }

    func computeTips(center: CGPoint, breathingRadius: CGFloat, extent: CGFloat) -> [CGPoint] {
        var tips = [CGPoint](repeating: .zero, count: Self.spokeCount)
        let baseAngle = self.rotationPhase * 2 * .pi
        for index in 0 ..< Self.bandCount {
            let radius = breathingRadius + CGFloat(self.smoothedBands[index]) * extent
            let angle0 = baseAngle + Double(index) * (2 * .pi / Double(Self.spokeCount))
            let angle1 = baseAngle + Double(index + Self.bandCount) * (2 * .pi / Double(Self.spokeCount))
            tips[index] = CGPoint(x: center.x + radius * cos(angle0), y: center.y + radius * sin(angle0))
            tips[index + Self.bandCount] = CGPoint(
                x: center.x + radius * cos(angle1),
                y: center.y + radius * sin(angle1)
            )
        }
        return tips
    }

    func spawnRipple(atRadius radius: CGFloat, time: TimeInterval, analysis: Analysis) {
        let color = PaletteResolver.color(
            palette: self.palette, position: 0, magnitude: analysis.bassEnergy, analysis: analysis, time: time
        )
        if let freeIndex = ripplePool.firstIndex(where: { !$0.isActive }) {
            self.ripplePool[freeIndex] = Ripple(birth: time, color: color, isActive: true, spawnRadius: radius)
            return
        }
        let oldestIndex = self.ripplePool.indices.min { self.ripplePool[$0].birth < self.ripplePool[$1].birth } ?? 0
        self.ripplePool[oldestIndex] = Ripple(birth: time, color: color, isActive: true, spawnRadius: radius)
    }

    func expireStaleRipples(at time: TimeInterval) {
        for index in self.ripplePool.indices where self.ripplePool[index].isActive {
            if time - ripplePool[index].birth > Self.rippleLifetime {
                ripplePool[index].isActive = false
            }
        }
    }

    // MARK: - Drawing (private)

    private func buildCatmullRomPath(tips: [CGPoint]) -> Path {
        let count = tips.count
        var path = Path()
        path.move(to: tips[0])
        for index in 0 ..< count {
            let prev = tips[(index - 1 + count) % count]
            let curr = tips[index]
            let next = tips[(index + 1) % count]
            let afterNext = tips[(index + 2) % count]
            let ctrl1 = CGPoint(
                x: curr.x + (next.x - prev.x) / 6,
                y: curr.y + (next.y - prev.y) / 6
            )
            let ctrl2 = CGPoint(
                x: next.x - (afterNext.x - curr.x) / 6,
                y: next.y - (afterNext.y - curr.y) / 6
            )
            path.addCurve(to: next, control1: ctrl1, control2: ctrl2)
        }
        path.closeSubpath()
        return path
    }

    private func drawRing(
        into context: inout GraphicsContext,
        path: Path,
        center: CGPoint,
        analysis: Analysis,
        time: TimeInterval
    ) {
        let fillColor = PaletteResolver.color(
            palette: self.palette, position: 0.5, magnitude: self.rmsEMA, analysis: analysis, time: time
        )
        let fillOpacity = self.reduceTransparency ? 1.0 : 0.25
        context.fill(path, with: .color(fillColor.opacity(fillOpacity)))

        let gradient = self.buildRingGradient(analysis: analysis, time: time)
        let ringStartAngle = Angle.radians(self.rotationPhase * 2 * .pi)
        context.stroke(
            path,
            with: .conicGradient(gradient, center: center, angle: ringStartAngle),
            lineWidth: 2
        )
    }

    private func buildRingGradient(analysis: Analysis, time: TimeInterval) -> Gradient {
        var stops = [Gradient.Stop]()
        stops.reserveCapacity(Self.spokeCount + 1)
        for index in 0 ..< Self.spokeCount {
            let bandIndex = index < Self.bandCount ? index : index - Self.bandCount
            let position = Double(bandIndex) / Double(Self.bandCount - 1)
            let magnitude = self.smoothedBands[bandIndex]
            let color = PaletteResolver.color(
                palette: self.palette, position: position, magnitude: magnitude, analysis: analysis, time: time
            )
            stops.append(.init(color: color, location: Double(index) / Double(Self.spokeCount)))
        }
        // Close the gradient at 1.0 using the same color as spoke 0 for a seamless seam.
        stops.append(.init(color: stops[0].color, location: 1.0))
        return Gradient(stops: stops)
    }

    private func drawRipples(
        into context: inout GraphicsContext,
        center: CGPoint,
        minDim: CGFloat,
        time: TimeInterval
    ) {
        let maxRadius = 1.2 * minDim
        for index in self.ripplePool.indices where self.ripplePool[index].isActive {
            let age = time - ripplePool[index].birth
            if age > Self.rippleLifetime {
                ripplePool[index].isActive = false
                continue
            }
            let progress = CGFloat(age / Self.rippleLifetime)
            let radius = ripplePool[index].spawnRadius + progress * (maxRadius - ripplePool[index].spawnRadius)
            let opacity = Double(0.5 * (1 - Float(progress)))
            let lineWidth = 3.0 - 2.0 * progress
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
            context.stroke(
                Circle().path(in: rect),
                with: .color(ripplePool[index].color.opacity(opacity)),
                lineWidth: lineWidth
            )
        }
    }

    private func drawCentreGlow(
        into context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        analysis: Analysis,
        time: TimeInterval
    ) {
        guard analysis.bassEnergy > 0 else { return }
        let glowColor = PaletteResolver.color(
            palette: self.palette, position: 0.5, magnitude: analysis.bassEnergy, analysis: analysis, time: time
        )
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        if self.reduceTransparency {
            context.fill(Circle().path(in: rect), with: .color(glowColor))
        } else {
            context.fill(
                Circle().path(in: rect),
                with: .radialGradient(
                    Gradient(colors: [glowColor.opacity(Double(analysis.bassEnergy)), .clear]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }
}
