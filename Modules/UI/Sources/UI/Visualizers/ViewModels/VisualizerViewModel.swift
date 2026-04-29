import AudioEngine
import Combine
import Foundation
import Observability
import SwiftUI

// MARK: - VisualizerViewModel

/// Owns the tap lifecycle, drives FFT analysis, and vends the current `Analysis`
/// to the SwiftUI view layer at display rate.
///
/// Create one instance in `BocanApp` and pass it to `BocanRootView`.
/// Call `start()` when the visualizer pane becomes visible and `stop()` when it hides.
@MainActor
public final class VisualizerViewModel: ObservableObject {
    // MARK: - Published state

    /// The latest analysis result, updated at the audio tap rate (~43×/s).
    @Published public private(set) var analysis: Analysis = .silent

    /// The most recent raw audio buffer — used by waveform-based visualizers (e.g. Oscilloscope).
    @Published public private(set) var latestSamples: AudioSamples?

    /// Whether the visualizer pane is currently visible.
    @AppStorage("visualizer.paneVisible") public var paneVisible = false

    // MARK: - Settings (persisted via AppStorage)

    @AppStorage("visualizer.mode") public var mode: VisualizerMode = .spectrumBars
    @AppStorage("visualizer.palette") public var palette: VisualizerPalette = .accent
    @AppStorage("visualizer.fpsCap") public var fpsCap: FPSCap = .sixty
    @AppStorage("visualizer.sensitivityRaw") private var sensitivityRaw = 1.0
    @AppStorage("visualizer.simplifyOnBattery") public var simplifyOnBattery = true

    /// Sensitivity multiplier applied to band values before normalisation (0.1…3.0).
    public var sensitivity: Float {
        get { Float(self.sensitivityRaw) }
        set { self.sensitivityRaw = Double(max(0.1, min(3.0, newValue))) }
    }

    // MARK: - Private

    private let engine: AudioEngine
    private let fftAnalyzer = FFTAnalyzer()
    private let log = AppLogger.make(.audio)
    private var tapTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Init

    public init(engine: AudioEngine) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    /// Start the audio tap and begin producing analysis frames.
    /// Safe to call multiple times — subsequent calls are ignored while running.
    public func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.log.debug("visualizer.tap.start")

        self.tapTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.startTap()
            for await samples in stream {
                guard !Task.isCancelled else { break }
                self.processSamples(samples)
            }
            self.log.debug("visualizer.tap.end")
        }
    }

    /// Stop the tap and put the analysis back to silence.
    public func stop() {
        guard self.isRunning else { return }
        self.isRunning = false
        self.tapTask?.cancel()
        self.tapTask = nil
        Task { await self.engine.stopTap() }
        self.analysis = .silent
        self.latestSamples = nil
        self.log.debug("visualizer.tap.stopped")
    }

    // MARK: - Private

    private func processSamples(_ samples: AudioSamples) {
        var rawBands = self.fftAnalyzer.analyze(samples)
        // Apply sensitivity multiplier before normalisation.
        if self.sensitivity != 1.0 {
            for i in 0 ..< rawBands.count {
                rawBands[i] = min(1, rawBands[i] * self.sensitivity)
            }
        }
        self.latestSamples = samples
        self.analysis = Analysis(bands: rawBands, rms: samples.rms, peak: samples.peak)
    }

    // MARK: - FPS effective

    /// Effective frame rate target considering battery state and user setting.
    public var effectiveFPS: Int {
        if self.simplifyOnBattery, self.isOnBattery {
            return 30
        }
        return self.fpsCap.fps
    }

    private var isOnBattery: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

// MARK: - FPSCap

public enum FPSCap: String, CaseIterable, Sendable {
    case thirty = "30"
    case sixty = "60"
    case unlimited

    public var fps: Int {
        switch self {
        case .thirty:
            30

        case .sixty:
            60

        case .unlimited:
            120
        }
    }

    public var displayName: String {
        switch self {
        case .thirty:
            "30 fps"

        case .sixty:
            "60 fps"

        case .unlimited:
            "Unlimited"
        }
    }
}
