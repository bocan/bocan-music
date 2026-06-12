import AppKit
import AudioEngine
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - HaloSnapshotTests

/// Snapshot suite for the Halo visualizer.
///
/// Each test renders Halo at a fixed analysis and time so the output is fully
/// deterministic. Uses ``StaticHaloCanvas`` (no TimelineView) so dynamic
/// palettes (drift, thermal) also produce stable reference images.
///
/// Disabled on CI for the same reasons as the main snapshot suite — see
/// SnapshotTests.swift for context.
@Suite(
    "Halo Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; rendering differs on CI runners."
    )
)
@MainActor
struct HaloSnapshotTests {
    // MARK: - Fixtures

    private static let analysis: Analysis = {
        var bands = [Float](repeating: 0, count: FFTAnalyzer.bandCount)
        for index in 0 ..< bands.count {
            let fraction = Float(index) / Float(bands.count)
            bands[index] = sin(fraction * .pi) * 0.85
        }
        return Analysis(bands: bands, rms: 0.6, peak: 0.9, centroid: 0.6, bassEnergy: 0.5, trebleEnergy: 0.3)
    }()

    private static let snapshotSize = CGSize(width: 400, height: 400)

    // MARK: - Palette variants (all six)

    @Test("Halo — accent palette")
    func haloAccent() {
        assertSnapshot(
            of: host(self.canvas(.accent), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-accent"
        )
    }

    @Test("Halo — spectrum palette")
    func haloSpectrum() {
        assertSnapshot(
            of: host(self.canvas(.spectrum), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-spectrum"
        )
    }

    @Test("Halo — mono palette")
    func haloMono() {
        assertSnapshot(
            of: host(self.canvas(.mono), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-mono"
        )
    }

    @Test("Halo — ember palette")
    func haloEmber() {
        assertSnapshot(
            of: host(self.canvas(.ember), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-ember"
        )
    }

    @Test("Halo — drift palette")
    func haloDrift() {
        assertSnapshot(
            of: host(self.canvas(.drift), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-drift"
        )
    }

    @Test("Halo — thermal palette")
    func haloThermal() {
        assertSnapshot(
            of: host(self.canvas(.thermal), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-thermal"
        )
    }

    // MARK: - Accessibility variants

    @Test("Halo — reduceMotion on spectrum palette")
    func haloReduceMotion() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceMotion: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-reduce-motion"
        )
    }

    @Test("Halo — reduceTransparency on spectrum palette")
    func haloReduceTransparency() {
        assertSnapshot(
            of: host(self.canvas(.spectrum, reduceTransparency: true), size: Self.snapshotSize),
            as: .image(precision: 0.95, perceptualPrecision: 0.98),
            named: "halo-reduce-transparency"
        )
    }

    // MARK: - Helpers

    private func canvas(
        _ palette: VisualizerPalette,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) -> some View {
        StaticHaloCanvas(
            palette: palette,
            analysis: Self.analysis,
            time: 1000,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
        .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height)
        .colorScheme(.dark)
    }
}

// MARK: - StaticHaloCanvas

/// Renders ``Halo`` once at a fixed time and analysis without a TimelineView,
/// so time-evolving palettes are deterministic in snapshots.
///
/// Pre-warms the EMA by calling ``Halo/updateSmoothing(analysis:)`` 60 times
/// before rendering so the smoothed bands are at their settled values.
private struct StaticHaloCanvas: View {
    let palette: VisualizerPalette
    let analysis: Analysis
    let time: TimeInterval
    let reduceMotion: Bool
    let reduceTransparency: Bool

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
            let viz = Halo(palette: self.palette, reduceMotion: self.reduceMotion, reduceTransparency: self.reduceTransparency)
            for _ in 0 ..< 60 {
                viz.updateSmoothing(analysis: self.analysis)
            }
            var ctx = context
            viz.render(into: &ctx, size: size, samples: Self.silent, analysis: self.analysis, time: self.time)
        }
        .background(Color.black)
    }
}
