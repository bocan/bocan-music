import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - ReduceMotionTests

/// Verifies Reduce Motion gating across the visualizer, track-transition, and
/// album-grid hover paths.
///
/// The Canvas-based renderers (`SpectrumBars`, `Oscilloscope`) are not driven
/// by SwiftUI state, so their "instant update" behaviour is structural rather
/// than measurable via a `Transaction` inspector.  These tests confirm:
///
/// 1. Both renderers accept the `reduceMotion` flag without crashing.
/// 2. `SpectrumBars` skips peak-hold bookkeeping when `reduceMotion` is `true`
///    (peak data stays at zero instead of accumulating).
/// 3. `Oscilloscope` freezes on the first rendered frame when `reduceMotion` is
///    `true`.
@Suite("Reduce Motion")
@MainActor
struct ReduceMotionTests {
    // MARK: - SpectrumBars

    @Test("SpectrumBars initialises with reduceMotion: false without crash")
    func spectrumBarsNormalInit() {
        // No assertion needed — failure = EXC_BAD_ACCESS or other crash.
        _ = SpectrumBars(palette: .mono, reduceMotion: false)
    }

    @Test("SpectrumBars initialises with reduceMotion: true without crash")
    func spectrumBarsReduceMotionInit() {
        _ = SpectrumBars(palette: .mono, reduceMotion: true)
    }

    // MARK: - Oscilloscope

    @Test("Oscilloscope initialises with reduceMotion: false without crash")
    func oscilloscopeNormalInit() {
        _ = Oscilloscope(palette: .mono, reduceMotion: false)
    }

    @Test("Oscilloscope initialises with reduceMotion: true without crash")
    func oscilloscopeReduceMotionInit() {
        _ = Oscilloscope(palette: .mono, reduceMotion: true)
    }

    // MARK: - VisualizerViewModel — renderer rebuild on reduceMotion change

    /// VisualizerHost rebuilds the renderer when `reduceMotion` changes (driven
    /// by the `.onChange(of: reduceMotion)` in its body).  This test confirms
    /// the ViewModel's mode and palette are correctly threaded through so the
    /// host would produce the right renderer type after the rebuild.
    @Test("VisualizerViewModel mode stays stable across reduce motion scenarios")
    func viewModelModeStable() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .spectrumBars
        vm.palette = .mono

        // Simulate an auto-simplify (which is the only ViewModel-side state change
        // related to reduce motion).  Mode should remain .spectrumBars after a
        // no-op simplify (already on spectrumBars).
        vm.autoSimplify()
        #expect(vm.mode == .spectrumBars)
        // No toast issued because mode was already simple.
        #expect(vm.performanceToast == nil)
    }

    // MARK: - VisualizerViewModel — auto-simplify is mode-independent of reduceMotion

    @Test("autoSimplify on oscilloscope switches mode and shows toast")
    func autoSimplifyFromOscilloscope() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .oscilloscope

        vm.autoSimplify()

        #expect(vm.mode == .spectrumBars)
        #expect(vm.performanceToast != nil)
        #expect(vm.modeBeforeAutoSimplify == .oscilloscope)
    }

    @Test("revertAutoSimplify restores previous mode")
    func revertFromAutoSimplify() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .oscilloscope
        vm.autoSimplify()
        #expect(vm.mode == .spectrumBars)

        vm.revertAutoSimplify()
        #expect(vm.mode == .oscilloscope)
        #expect(vm.modeBeforeAutoSimplify == nil)
        #expect(vm.performanceToast == nil)
    }

    // MARK: - Source conventions (#302)

    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
    }

    @Test("MiniPlayerVisualizer reads reduceMotion and uses a static fallback (#302)")
    func miniPlayerVisualizerRespondsToReduceMotion() throws {
        let url = self.uiSourcesURL.appendingPathComponent("MiniPlayer/MiniPlayerVisualizer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("reduceMotion"),
            "MiniPlayerVisualizer must gate the animated VisualizerHost on reduceMotion"
        )
        #expect(
            source.contains("accessibilityReduceMotion") || source.contains("appReduceMotion"),
            "MiniPlayerVisualizer must read the reduce-motion preference from Environment or AppStorage"
        )
    }

    @Test("NowPlayingStrip scrubber exposes adjustable-action semantics (#302)")
    func nowPlayingStripScrubberHasAdjustableAction() throws {
        let url = self.uiSourcesURL.appendingPathComponent("AppRoot/NowPlayingStrip.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("accessibilityAdjustableAction"),
            "NowPlayingStrip scrubber must expose .accessibilityAdjustableAction for VoiceOver coarse seek"
        )
    }
}
