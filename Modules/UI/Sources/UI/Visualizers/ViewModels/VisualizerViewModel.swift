import AudioEngine
import Combine
import Foundation
import IOKit.ps
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
    // MARK: - Frame state (deliberately not @Published)

    /// The latest analysis result, updated at the audio tap rate (~43×/s).
    ///
    /// **Not `@Published` on purpose.** Both renderers read this at draw time
    /// (the Canvas `TimelineView` tick and the Metal `MTKView` display link),
    /// driven by their own clocks, so they always see the current value without a
    /// publish. Publishing it at the tap rate only forced a `VisualizerHost.body`
    /// re-evaluation ~43×/s (plus the same again for `latestSamples`), an update
    /// storm that ran `updateNSView` and an IOKit battery query per frame and
    /// starved the Metal draw loop on the main thread badly enough that the
    /// frame-rate watchdog auto-simplified a renderer that was actually fast.
    public private(set) var analysis: Analysis = .silent

    /// The most recent raw audio buffer, used by waveform visualizers. Not
    /// `@Published` for the same reason as ``analysis``.
    public private(set) var latestSamples: AudioSamples?

    /// Whether the visualizer pane is currently visible.
    @AppStorage("visualizer.paneVisible") public var paneVisible = false

    // MARK: - Settings (persisted via AppStorage)

    @AppStorage("visualizer.mode") public var mode: VisualizerMode = .spectrumBars
    @AppStorage("visualizer.palette") public var palette: VisualizerPalette = .accent
    @AppStorage("visualizer.fpsCap") public var fpsCap: FPSCap = .sixty
    @AppStorage("visualizer.sensitivityRaw") private var sensitivityRaw = 1.0
    @AppStorage("visualizer.simplifyOnBattery") public var simplifyOnBattery = true

    /// The `localizedName` of the screen to use for the fullscreen window.
    /// Empty string means no preference — let macOS place it on the default screen.
    @AppStorage("visualizer.targetScreenName") public var targetScreenName = ""

    // MARK: - Auto-simplify (sustained FPS drop)

    /// Non-nil while the performance warning toast is visible.
    /// Cleared when the user dismisses/reverts or after 6 seconds.
    @Published public private(set) var performanceToast: ToastMessage?

    /// The mode that was active before an auto-simplify. Non-nil only while
    /// the "Revert" button is available (same lifetime as ``performanceToast``).
    @Published public private(set) var modeBeforeAutoSimplify: VisualizerMode?

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
    private var nextFrameIndex: UInt64 = 1
    /// Reference count — incremented by start(), decremented by stop().
    /// The tap loop runs while isRunning is true; isRunning is set on the
    /// 0→1 and 1→0 transitions so the task body is identical to before.
    private var startCount = 0
    private var isRunning = false
    /// The auto-dismiss timer for `performanceToast`. `private(set)` so tests can
    /// `await` its completion deterministically instead of racing a wall-clock
    /// sleep against main-actor scheduling.
    private(set) var performanceToastTask: Task<Void, Never>?
    private let toastDismissalDuration: Duration

    // MARK: - Init

    public init(engine: AudioEngine, toastDismissalDuration: Duration = .seconds(6)) {
        self.engine = engine
        self.toastDismissalDuration = toastDismissalDuration
    }

    // MARK: - Lifecycle

    /// Increment the reference count and start the audio tap if this is the
    /// first caller. Safe to call from both the pane and the fullscreen window.
    public func start() {
        self.startCount += 1
        guard self.startCount == 1 else {
            let count = self.startCount
            self.log.debug("visualizer.tap.start.shared count=\(count)")
            return
        }
        self.isRunning = true
        self.log.debug("visualizer.tap.start")

        self.tapTask = Task { [weak self] in
            guard let self else { return }
            // Restart loop: when the engine reconfigures (sample-rate change, device
            // change) AVAudioEngine silently removes the tap. AudioEngine's config-change
            // observer calls stopTap() which finishes the AsyncStream, exiting the
            // inner for-await. We then reset the FFT analyser (clearing stale peaks
            // from the old track) and reinstall the tap on the rebuilt graph.
            while self.isRunning, !Task.isCancelled {
                let stream = await self.engine.startTap()
                // Reset before consuming the new stream so adaptive-normalisation peaks
                // from the previous stream don't pollute the first few seconds.
                self.fftAnalyzer.reset()
                for await samples in stream {
                    guard !Task.isCancelled else { return }
                    self.processSamples(samples)
                }
                if self.isRunning, !Task.isCancelled {
                    // Stream ended unexpectedly — engine is reconfiguring.
                    // Brief pause lets the graph reconnect before we re-tap.
                    self.log.debug("visualizer.tap.stream.reconnecting")
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms
                }
            }
            self.log.debug("visualizer.tap.end")
        }
    }

    /// Decrement the reference count and tear down the tap only when it reaches
    /// zero. Calling stop() more times than start() is a no-op.
    public func stop() {
        guard self.startCount > 0 else { return }
        self.startCount -= 1
        guard self.startCount == 0 else {
            let count = self.startCount
            self.log.debug("visualizer.tap.stop.shared count=\(count)")
            return
        }
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
        let frame = self.fftAnalyzer.analyze(samples)
        var bands = frame.bands
        // Apply sensitivity multiplier before display.
        if self.sensitivity != 1.0 {
            for i in 0 ..< bands.count {
                bands[i] = min(1, bands[i] * self.sensitivity)
            }
        }
        let index = self.nextFrameIndex
        self.nextFrameIndex &+= 1
        self.latestSamples = samples
        self.analysis = Analysis(
            bands: bands,
            rms: samples.rms,
            peak: samples.peak,
            centroid: frame.centroid,
            flux: frame.flux,
            onset: frame.onset,
            bassEnergy: frame.bassEnergy,
            midEnergy: frame.midEnergy,
            trebleEnergy: frame.trebleEnergy,
            frameIndex: index
        )
    }

    // MARK: - Auto-simplify API

    /// Called by ``VisualizerHost`` when the rolling FPS average falls below
    /// 30 fps for ≥ 3 consecutive seconds. Switches to `.spectrumBars` and
    /// shows a toast with a "Revert" option. No-op if already on `.spectrumBars`.
    public func autoSimplify() {
        guard self.mode != .spectrumBars else { return }
        let previous = self.mode
        self.modeBeforeAutoSimplify = previous
        self.mode = .spectrumBars
        self.log.info("visualizer.autoSimplify: switched from \(previous.rawValue) to spectrumBars due to sustained FPS drop")
        let toast = ToastMessage(text: L10n.string("Switched to Spectrum Bars for performance."), kind: .info)
        self.performanceToast = toast
        self.performanceToastTask?.cancel()
        self.performanceToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.toastDismissalDuration ?? .seconds(6))
            guard let self, self.performanceToast?.id == toast.id else { return }
            self.performanceToast = nil
            self.modeBeforeAutoSimplify = nil
        }
    }

    /// Reverts the mode to what it was before the auto-simplify and dismisses
    /// the toast. Calling when no auto-simplify is active is a no-op.
    public func revertAutoSimplify() {
        guard let previous = modeBeforeAutoSimplify else { return }
        self.mode = previous
        self.modeBeforeAutoSimplify = nil
        self.performanceToastTask?.cancel()
        self.performanceToast = nil
        self.log.info("visualizer.autoSimplify.reverted: restored mode \(previous.rawValue)")
    }

    // MARK: - Mode / palette cycling (pure, testable)

    /// The visualizer modes selectable right now. The Metal-only Nebula is left
    /// out when there is no Metal device or reduce motion is on, because the host
    /// substitutes Spectrum Bars for it in those cases, so cycling onto it would
    /// show a name that does not match the picture.
    public static func availableModes(reduceMotion: Bool, hasMetalDevice: Bool) -> [VisualizerMode] {
        VisualizerMode.allCases.filter { mode in
            !(mode.requiresMetal && (reduceMotion || !hasMetalDevice))
        }
    }

    /// The element `delta` steps from `current` in `options`, wrapping at both
    /// ends. Returns the first option (or `current` when `options` is empty) if
    /// `current` is not present, so a stale selection cannot wedge the stepper.
    public static func cycled<Option: Equatable>(_ current: Option, in options: [Option], by delta: Int) -> Option {
        guard !options.isEmpty else { return current }
        let count = options.count
        let index = options.firstIndex(of: current) ?? 0
        return options[((index + delta) % count + count) % count]
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
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sourceList.contains { source in
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any] else { return false }
            return (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        }
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
            L10n.string("30 fps")

        case .sixty:
            L10n.string("60 fps")

        case .unlimited:
            L10n.string("Unlimited")
        }
    }
}
