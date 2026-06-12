import AppKit
import AudioEngine
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - StarfieldSnapshotTests

/// Snapshot suite for the Starfield visualizer.
///
/// Each test seeds the field deterministically, advances a scripted sequence of
/// `Analysis` frames, then renders one frame at a fixed time so dynamic palettes
/// (drift, thermal) and the twinkle phase are stable. A streak variant scripts an
/// onset just before the snapshot frame so the warp boost is above the streak
/// threshold.
///
/// Disabled on CI for the same reasons as the main snapshot suite.
@Suite(
    "Starfield Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; rendering differs on CI runners."
    )
)
@MainActor
struct StarfieldSnapshotTests {
    private static let snapshotSize = CGSize(width: 480, height: 480)
    private static let seed: UInt64 = 0xBADC_0FFE_E0DD_F00D

    // MARK: - Palette variants

    @Test("Starfield — accent palette")
    func starfieldAccent() {
        assertSnapshot(
            of: host(self.canvas(.accent), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-accent"
        )
    }

    @Test("Starfield — spectrum palette")
    func starfieldSpectrum() {
        assertSnapshot(
            of: host(self.canvas(.spectrum), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-spectrum"
        )
    }

    @Test("Starfield — mono palette")
    func starfieldMono() {
        assertSnapshot(
            of: host(self.canvas(.mono), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-mono"
        )
    }

    @Test("Starfield — ember palette")
    func starfieldEmber() {
        assertSnapshot(
            of: host(self.canvas(.ember), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-ember"
        )
    }

    @Test("Starfield — drift palette")
    func starfieldDrift() {
        assertSnapshot(
            of: host(self.canvas(.drift), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-drift"
        )
    }

    @Test("Starfield — thermal palette")
    func starfieldThermal() {
        assertSnapshot(
            of: host(self.canvas(.thermal), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-thermal"
        )
    }

    // MARK: - Behaviour variants

    @Test("Starfield — warp streaks")
    func starfieldStreaks() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, streak: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-streaks"
        )
    }

    @Test("Starfield — reduceMotion")
    func starfieldReduceMotion() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceMotion: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-reduce-motion"
        )
    }

    @Test("Starfield — reduceTransparency")
    func starfieldReduceTransparency() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceTransparency: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "starfield-reduce-transparency"
        )
    }

    // MARK: - Helpers

    private func canvas(
        _ palette: VisualizerPalette,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        streak: Bool = false
    ) -> some View {
        StaticStarfieldCanvas(
            palette: palette,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            streak: streak,
            seed: Self.seed
        )
        .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height)
        .colorScheme(.dark)
    }
}

// MARK: - StaticStarfieldCanvas

/// Seeds a `Starfield`, advances a scripted sequence, then renders one frame at a
/// fixed time so the output is deterministic.
private struct StaticStarfieldCanvas: View {
    let palette: VisualizerPalette
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let streak: Bool
    let seed: UInt64

    private static let silent = AudioSamples(
        timeStamp: .init(),
        sampleRate: 44100,
        mono: [],
        left: [],
        right: [],
        rms: 0,
        peak: 0
    )

    var body: some View {
        Canvas { context, size in
            let viz = Starfield(
                palette: self.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency,
                seed: self.seed
            )
            // Drive the field through a scripted mid-track sequence so stars
            // spread out from the centre and the palettes have energy to colour.
            var bands = [Float](repeating: 0, count: Starfield.bandCount)
            for index in 0 ..< bands.count {
                let fraction = Float(index) / Float(bands.count)
                bands[index] = (sin(fraction * .pi * 2) * 0.5 + 0.5) * 0.8
            }
            // Stop one frame short: render() advances internally, so letting it
            // own the final frame gives that step a real dt (a second advance at
            // the same timestamp would collapse every streak to zero length).
            for frame in 1 ... 89 {
                let analysis = Analysis(
                    bands: bands,
                    rms: 0.5,
                    peak: 0.9,
                    centroid: 0.6,
                    bassEnergy: 0.5,
                    trebleEnergy: 0.3,
                    frameIndex: UInt64(frame)
                )
                viz.advance(analysis: analysis, time: Double(frame) / 60.0)
            }
            var ctx = context
            // For the streak variant, fire the onset on the render frame so the
            // warp boost is at its peak and stars stretch from their previous
            // position to their current one.
            let renderAnalysis = Analysis(
                bands: bands,
                rms: 0.5,
                peak: 0.9,
                centroid: 0.6,
                onset: self.streak,
                bassEnergy: 0.5,
                trebleEnergy: 0.3,
                frameIndex: 90
            )
            viz.render(
                into: &ctx,
                size: size,
                samples: Self.silent,
                analysis: renderAnalysis,
                time: 90.0 / 60.0
            )
        }
        .background(Color.black)
    }
}
