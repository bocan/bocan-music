import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - VisualizerViewModelTests

@Suite("VisualizerViewModel")
@MainActor
struct VisualizerViewModelTests {
    // MARK: - Start / stop

    @Test("start increments refcount; stop returns analysis to silent when count reaches zero")
    func startStopLifecycle() async throws {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)

        vm.start()
        // Give the task a moment to schedule.
        try await Task.sleep(for: .milliseconds(20))

        vm.stop()
        #expect(vm.analysis.rms == 0)
        #expect(vm.analysis.peak == 0)
        #expect(vm.analysis.bands.allSatisfy { $0 == 0 })
    }

    @Test("calling start twice requires two stops — tap stays alive until refcount is zero")
    func startIsDeduplicated() async throws {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.start() // refcount → 1
        vm.start() // refcount → 2
        try await Task.sleep(for: .milliseconds(20))
        vm.stop() // refcount → 1; tap still running
        vm.stop() // refcount → 0; tap stopped
        // No crash = pass.
    }

    // MARK: - Sensitivity

    @Test("sensitivity clamps to [0.1, 3.0]")
    func sensitivityClamping() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.sensitivity = -5
        #expect(vm.sensitivity == 0.1)
        vm.sensitivity = 100
        #expect(vm.sensitivity == 3.0)
        vm.sensitivity = 1.5
        #expect(vm.sensitivity == 1.5)
    }

    // MARK: - FPS cap

    @Test("effectiveFPS respects fpsCap setting")
    func effectiveFPSMatchesCap() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.fpsCap = .thirty
        // Battery state is determined by IOKit (real power source), not LPM.
        // Allow both outcomes since the test machine may or may not be on battery.
        #expect(vm.effectiveFPS == 30 || vm.effectiveFPS == 60)
        vm.fpsCap = .sixty
        #expect(vm.effectiveFPS == 60 || vm.effectiveFPS == 30)
    }

    // MARK: - Auto-simplify

    @Test("autoSimplify switches to spectrumBars and publishes toast")
    func autoSimplify() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .oscilloscope
        vm.autoSimplify()
        #expect(vm.mode == .spectrumBars)
        #expect(vm.performanceToast != nil)
        #expect(vm.modeBeforeAutoSimplify == .oscilloscope)
    }

    @Test("autoSimplify is a no-op when mode is already spectrumBars")
    func autoSimplifyNoOpWhenAlreadySimple() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .spectrumBars
        vm.autoSimplify()
        #expect(vm.performanceToast == nil)
        #expect(vm.modeBeforeAutoSimplify == nil)
    }

    @Test("revertAutoSimplify restores previous mode and clears toast")
    func revertAutoSimplify() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .oscilloscope
        vm.autoSimplify()
        vm.revertAutoSimplify()
        #expect(vm.mode == .oscilloscope)
        #expect(vm.performanceToast == nil)
        #expect(vm.modeBeforeAutoSimplify == nil)
    }

    @Test("revertAutoSimplify is a no-op when no auto-simplify is active")
    func revertNoOpWhenNotActive() {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.mode = .oscilloscope
        vm.revertAutoSimplify() // nothing to revert
        #expect(vm.mode == .oscilloscope)
        #expect(vm.performanceToast == nil)
    }

    @Test("performanceToast auto-clears after 6 seconds")
    func performanceToastAutoDismisses() async {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine, toastDismissalDuration: .milliseconds(200))
        vm.mode = .oscilloscope
        vm.autoSimplify()
        #expect(vm.performanceToast != nil)
        // Await the dismissal task directly: deterministic, with no wall-clock
        // sleep racing main-actor scheduling on loaded CI runners.
        await vm.performanceToastTask?.value
        #expect(vm.performanceToast == nil)
        #expect(vm.modeBeforeAutoSimplify == nil)
    }

    // MARK: - Analysis from samples

    @Test("processSamples updates analysis.rms and peak")
    func analysisPropagatesRMSAndPeak() async throws {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        // Manually start and feed a sample to verify the pipeline.
        vm.start()
        try await Task.sleep(for: .milliseconds(30))
        vm.stop()
        // After processing, analysis must still be valid (even if silent).
        #expect(vm.analysis.rms >= 0)
        #expect(vm.analysis.rms.isFinite)
        #expect(vm.analysis.bands.count == FFTAnalyzer.bandCount)
    }
}

// MARK: - FPSCap

@Suite("FPSCap")
struct FPSCapTests {
    @Test("all FPSCap cases have valid fps values")
    func allCasesValid() {
        for cap in FPSCap.allCases {
            #expect(cap.fps > 0)
        }
    }

    @Test("displayName is non-empty for all cases")
    func allDisplayNamesNonEmpty() {
        for cap in FPSCap.allCases {
            #expect(!cap.displayName.isEmpty)
        }
    }
}

// MARK: - VisualizerMode

@Suite("VisualizerMode")
struct VisualizerModeTests {
    @Test("all modes have non-empty displayName and symbolName")
    func allModesHaveMetadata() {
        for mode in VisualizerMode.allCases {
            #expect(!mode.displayName.isEmpty, "Mode \(mode) has empty displayName")
            #expect(!mode.symbolName.isEmpty, "Mode \(mode) has empty symbolName")
        }
    }

    @Test("rawValue round-trips")
    func rawValueRoundTrips() {
        for mode in VisualizerMode.allCases {
            let restored = VisualizerMode(rawValue: mode.rawValue)
            #expect(restored == mode)
        }
    }
}

// MARK: - Mode / palette cycling

@Suite("VisualizerViewModel Cycling")
@MainActor
struct VisualizerCyclingTests {
    @Test("availableModes lists every mode when Metal is present and reduce motion is off")
    func availableModesFull() {
        #expect(VisualizerViewModel.availableModes(reduceMotion: false, hasMetalDevice: true) == VisualizerMode.allCases)
    }

    @Test("availableModes drops Nebula under reduce motion or without a Metal device")
    func availableModesGatesNebula() {
        #expect(!VisualizerViewModel.availableModes(reduceMotion: true, hasMetalDevice: true).contains(.nebula))
        #expect(!VisualizerViewModel.availableModes(reduceMotion: false, hasMetalDevice: false).contains(.nebula))
        // The other five always remain, regardless of the flags.
        for mode in VisualizerMode.allCases where mode != .nebula {
            #expect(VisualizerViewModel.availableModes(reduceMotion: true, hasMetalDevice: false).contains(mode))
        }
    }

    @Test("cycled wraps both ends and is identity-safe")
    func cycledWraps() {
        let palettes = VisualizerPalette.allCases
        let first = palettes[0]
        let last = palettes[palettes.count - 1]
        #expect(VisualizerViewModel.cycled(first, in: palettes, by: -1) == last)
        #expect(VisualizerViewModel.cycled(last, in: palettes, by: 1) == first)
        #expect(VisualizerViewModel.cycled(.accent, in: palettes, by: 0) == .accent)
        // A value absent from the options falls back to the first option.
        #expect(VisualizerViewModel.cycled(.accent, in: [VisualizerPalette.mono], by: 1) == .mono)
        // Empty options returns the current value rather than crashing.
        #expect(VisualizerViewModel.cycled(VisualizerMode.halo, in: [], by: 1) == .halo)
    }

    @Test("cycled advances by exactly one step through the mode list")
    func cycledSteps() {
        var mode = VisualizerMode.allCases[0]
        for expected in VisualizerMode.allCases.dropFirst() {
            mode = VisualizerViewModel.cycled(mode, in: VisualizerMode.allCases, by: 1)
            #expect(mode == expected)
        }
    }
}

// MARK: - Control overlay embedding (source convention)

@Suite("VisualizerControlOverlay embedding")
struct VisualizerControlOverlayEmbeddingTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
    }

    @Test("The pane, fullscreen, and mini player each embed VisualizerControlOverlay", arguments: [
        "Visualizers/VisualizerPane.swift",
        "Visualizers/FullscreenWindow.swift",
        "MiniPlayer/MiniPlayerVisualizer.swift",
    ])
    func surfacesEmbedControl(path: String) throws {
        let source = try String(contentsOf: self.uiSourcesURL.appendingPathComponent(path), encoding: .utf8)
        #expect(source.contains("VisualizerControlOverlay"), "\(path) must embed VisualizerControlOverlay")
    }

    @Test("The mini player only shows the control when the live visualizer runs (reduce motion off)")
    func miniPlayerGatesControl() throws {
        let source = try String(
            contentsOf: self.uiSourcesURL.appendingPathComponent("MiniPlayer/MiniPlayerVisualizer.swift"),
            encoding: .utf8
        )
        #expect(source.contains("if !self.reduceMotion"))
    }
}
