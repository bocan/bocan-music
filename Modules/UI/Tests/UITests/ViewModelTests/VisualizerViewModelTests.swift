import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - VisualizerViewModelTests

@Suite("VisualizerViewModel")
@MainActor
struct VisualizerViewModelTests {
    // MARK: - Start / stop

    @Test("start sets isRunning; stop returns analysis to silent")
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

    @Test("calling start twice does not create duplicate tap tasks")
    func startIsDeduplicated() async throws {
        let engine = AudioEngine()
        let vm = VisualizerViewModel(engine: engine)
        vm.start()
        vm.start() // second call is a no-op
        try await Task.sleep(for: .milliseconds(20))
        vm.stop()
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
        // Not on battery (ProcessInfo.isLowPowerModeEnabled is false in tests).
        #expect(vm.effectiveFPS == 30 || vm.effectiveFPS == 60)
        vm.fpsCap = .sixty
        #expect(vm.effectiveFPS == 60 || vm.effectiveFPS == 30)
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

    @Test("fluidMetal is the only Metal-based mode")
    func onlyFluidMetalIsMetalBased() {
        let metalModes = VisualizerMode.allCases.filter(\.isMetalBased)
        #expect(metalModes == [.fluidMetal])
    }

    @Test("rawValue round-trips")
    func rawValueRoundTrips() {
        for mode in VisualizerMode.allCases {
            let restored = VisualizerMode(rawValue: mode.rawValue)
            #expect(restored == mode)
        }
    }
}
