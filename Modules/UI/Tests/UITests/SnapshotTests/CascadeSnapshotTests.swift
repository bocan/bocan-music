import AppKit
import AudioEngine
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - CascadeSnapshotTests

/// Snapshot suite for the Cascade visualizer.
///
/// Each test feeds a scripted 64-frame sequence (frequency sweep + two onsets)
/// to a Cascade instance, then renders the final state to a fixed-size canvas.
/// The analysis and time are deterministic so all palettes produce stable references.
///
/// Disabled on CI for the same reasons as the main snapshot suite — see
/// SnapshotTests.swift for context.
@Suite(
    "Cascade Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; rendering differs on CI runners."
    )
)
@MainActor
struct CascadeSnapshotTests {
    private static let snapshotSize = CGSize(width: 600, height: 300)

    // MARK: - Palette variants

    @Test("Cascade — accent palette")
    func cascadeAccent() {
        assertSnapshot(
            of: host(self.canvas(.accent), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-accent"
        )
    }

    @Test("Cascade — spectrum palette")
    func cascadeSpectrum() {
        assertSnapshot(
            of: host(self.canvas(.spectrum), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-spectrum"
        )
    }

    @Test("Cascade — mono palette")
    func cascadeMono() {
        assertSnapshot(
            of: host(self.canvas(.mono), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-mono"
        )
    }

    @Test("Cascade — ember palette")
    func cascadeEmber() {
        assertSnapshot(
            of: host(self.canvas(.ember), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-ember"
        )
    }

    @Test("Cascade — drift palette")
    func cascadeDrift() {
        assertSnapshot(
            of: host(self.canvas(.drift), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-drift"
        )
    }

    @Test("Cascade — thermal palette")
    func cascadeThermal() {
        assertSnapshot(
            of: host(self.canvas(.thermal), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-thermal"
        )
    }

    // MARK: - Accessibility variants

    @Test("Cascade — reduceMotion stepped mode")
    func cascadeReduceMotion() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceMotion: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-reduce-motion"
        )
    }

    @Test("Cascade — reduceTransparency (no visual change expected)")
    func cascadeReduceTransparency() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceTransparency: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "cascade-reduce-transparency"
        )
    }

    // MARK: - Helpers

    private func canvas(
        _ palette: VisualizerPalette,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) -> some View {
        StaticCascadeCanvas(
            palette: palette,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            snapshotTime: 64 * Cascade.columnPeriod
        )
        .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height)
        .colorScheme(.dark)
    }
}

// MARK: - StaticCascadeCanvas

/// Feeds a scripted 64-frame sequence to a `Cascade` instance and renders the
/// final state at a fixed time, producing a deterministic snapshot.
///
/// The sequence is a frequency sweep (bands rise from low to high across frames)
/// with two onset beats at frames 16 and 48, matching the test-plan description.
private struct StaticCascadeCanvas: View {
    let palette: VisualizerPalette
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let snapshotTime: TimeInterval

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
            let cascade = Cascade(
                palette: self.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )
            // Feed 64 scripted frames before rendering.
            for frame in 0 ..< 64 {
                let t = Double(frame) * Cascade.columnPeriod
                var bands = [Float](repeating: 0, count: Cascade.bandCount)
                // Frequency sweep: each frame activates a different band range.
                let activeBand = frame % Cascade.bandCount
                for b in 0 ..< Cascade.bandCount {
                    let dist = abs(b - activeBand)
                    bands[b] = max(0, 1.0 - Float(dist) * 0.1)
                }
                let onset = (frame == 16 || frame == 48)
                let analysis = Analysis(
                    bands: bands,
                    rms: Float(frame % 16) / 15.0,
                    peak: 1.0,
                    centroid: Float(frame) / 63.0,
                    onset: onset,
                    bassEnergy: bands[0],
                    trebleEnergy: bands[31],
                    frameIndex: UInt64(frame + 1)
                )
                cascade.processFrame(analysis: analysis, time: t)
            }
            var ctx = context
            cascade.render(
                into: &ctx,
                size: size,
                samples: Self.silent,
                analysis: Analysis(
                    bands: [Float](repeating: 0.3, count: Cascade.bandCount),
                    rms: 0.3,
                    peak: 0.3,
                    centroid: 0.5,
                    frameIndex: 65
                ),
                time: self.snapshotTime
            )
        }
        .background(Color.black)
    }
}

// MARK: - Snapshot host helper

private func host(_ view: some View, size: CGSize) -> some View {
    view.frame(width: size.width, height: size.height)
}
