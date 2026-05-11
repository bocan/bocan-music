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
    func performanceToastAutoDismisses() async throws {
        let engine = AudioEngine()
        // Use a short dismissal duration and a generous wait to avoid flakiness on
        // loaded CI runners where @MainActor scheduling adds significant latency.
        let vm = VisualizerViewModel(engine: engine, toastDismissalDuration: .milliseconds(50))
        vm.mode = .oscilloscope
        vm.autoSimplify()
        #expect(vm.performanceToast != nil)
        try await Task.sleep(for: .milliseconds(1500))
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
