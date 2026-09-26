import AudioEngine
@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - BoundaryTransition

/// How the scheduler arms one track boundary (ADR-095).
public enum BoundaryTransition: Sendable, Equatable {
    /// Mix the next track in under the end of this one. `seconds` is the full
    /// crossfade setting; the engine shortens it for a short track.
    case crossfade(seconds: TimeInterval)
    /// Plain gapless (ADR-006). `forceGapless` relaxes the format gate to the
    /// sample-rate and channel-count check.
    case gapless(forceGapless: Bool)

    public var isCrossfade: Bool {
        if case .crossfade = self {
            return true
        }
        return false
    }
}

// MARK: - GaplessScheduler

/// Monitors playback progress and pre-schedules the next track's buffers
/// onto the current `AVAudioPlayerNode` before the current track ends.
///
/// **Gapless contract:**
/// - For format-compatible tracks (same sample rate + channel count): schedules next
///   track buffers on the same player node; no gap is audible.
/// - For incompatible formats: does nothing; `QueuePlayer` will do a normal
///   `stop / load / play` on `.ended`. A brief hardware-buffer flush is audible
///   (~30–100 ms depending on the output device). This is a documented limitation.
///
/// **Crossfade (ADR-095):** a boundary that crossfades skips the format gate,
/// because the engine converts each track to the output format before it
/// mixes them, and is armed early enough for the whole overlap
/// (`armingWindow(preroll:crossfadeSeconds:)`).
///
/// The scheduler runs a polling loop (checks every 500 ms) and arms the gapless
/// preload when `remaining ≤ prerollSeconds`.
public actor GaplessScheduler {
    // MARK: - Configuration

    /// Default preroll window (seconds) used when the user hasn't customised
    /// `playback.gaplessPrerollSeconds` or the persisted value is out of range.
    private static let defaultPrerollSeconds: TimeInterval = 5.0
    /// Lower bound (seconds) for the configurable preroll window.
    private static let minPrerollSeconds: TimeInterval = 1.0
    /// Upper bound (seconds) for the configurable preroll window.
    private static let maxPrerollSeconds: TimeInterval = 15.0
    /// `UserDefaults` key wired by `PlaybackSettingsView` and registered in
    /// `BocanApp` defaults.  Read live each poll tick so changes apply without
    /// requiring playback to restart.
    private static let prerollDefaultsKey = "playback.gaplessPrerollSeconds"

    /// Returns the user-configured preroll window, clamped to the supported range.
    private static func currentPrerollSeconds() -> TimeInterval {
        let raw = UserDefaults.standard.double(forKey: Self.prerollDefaultsKey)
        guard raw > 0 else { return Self.defaultPrerollSeconds }
        return min(Self.maxPrerollSeconds, max(Self.minPrerollSeconds, raw))
    }

    /// Time added to a crossfade before the boundary is armed: it covers the
    /// 500 ms poll, the decoder open and the prefetch hop, so the overlap is
    /// armed before it has to start.
    static let crossfadeArmingMarginSeconds: TimeInterval = 2.0

    /// How long before the end of the current track to arm the boundary:
    /// `max(preroll, crossfadeSeconds + 2 s)` when the boundary crossfades,
    /// else `preroll`. Pass 0 for `crossfadeSeconds` when it does not.
    ///
    /// Always finite and never negative, for any input: a non-finite preroll
    /// falls back to the default, and a non-finite or non-positive crossfade
    /// counts as none (the same concern as #271).
    static func armingWindow(preroll: TimeInterval, crossfadeSeconds: TimeInterval) -> TimeInterval {
        let base = preroll.isFinite ? max(0, preroll) : Self.defaultPrerollSeconds
        guard crossfadeSeconds.isFinite, crossfadeSeconds > 0 else { return base }
        return max(base, crossfadeSeconds + Self.crossfadeArmingMarginSeconds)
    }

    // MARK: - Dependencies

    private let engine: AudioEngine
    private let crossfade: CrossfadeScheduler
    private let bridge = FormatBridge()
    private let log = AppLogger.make(.playback)

    // MARK: - State

    private var task: Task<Void, Never>?
    private var armedForItemID: QueueItem.ID?

    /// Item ID we've already logged a `gapless.(forced.)?incompatible` warning
    /// for during the current approach to EOT.  Avoids 10+ identical log lines
    /// spewed by the 500 ms poll loop while waiting for the track to end.
    private var incompatibleLoggedForItemID: QueueItem.ID?

    // MARK: - Callbacks

    /// Called when the scheduler wants to know the next item and how its
    /// boundary transitions.  Returns `nil` for no next item.
    var nextItemProvider: (@Sendable () async -> (item: QueueItem, transition: BoundaryTransition)?)?

    /// Called when the scheduler has decided to arm the next track.  The caller
    /// (QueuePlayer) is responsible for resolving security scope, calling
    /// `engine.enableGaplessNext` or `engine.enableCrossfadeNext`, and
    /// releasing scope afterwards.
    /// Throws propagate back into the scheduler so `onPrefetchFailed` fires.
    ///
    /// The scheduler never sees the transition itself: it reaches QueuePlayer
    /// through the closure `armNext` hands the engine with the next track
    /// (#575).
    var performPrefetch: (@Sendable (QueueItem, BoundaryTransition) async throws -> Void)?

    /// Called when `performPrefetch` throws (for logging/metrics only; caller falls back).
    var onPrefetchFailed: (@Sendable (Error) -> Void)?

    // MARK: - Init

    /// - Parameter crossfade: The crossfade setting, read each poll to size
    ///   the arming window.
    public init(engine: AudioEngine, crossfade: CrossfadeScheduler) {
        self.engine = engine
        self.crossfade = crossfade
    }

    // MARK: - Configuration

    /// Set all callbacks in a single actor hop.
    public func configure(
        nextItemProvider: (@Sendable () async -> (item: QueueItem, transition: BoundaryTransition)?)?,
        performPrefetch: (@Sendable (QueueItem, BoundaryTransition) async throws -> Void)?,
        onPrefetchFailed: (@Sendable (Error) -> Void)?
    ) {
        self.nextItemProvider = nextItemProvider
        self.performPrefetch = performPrefetch
        self.onPrefetchFailed = onPrefetchFailed
    }

    // MARK: - Lifecycle

    /// Start the polling loop. Idempotent — calling again cancels and restarts.
    public func start() {
        self.task?.cancel()
        self.task = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Cancel the polling loop and any active gapless preload.
    public func stop() async {
        self.task?.cancel()
        self.task = nil
        self.armedForItemID = nil
        self.incompatibleLoggedForItemID = nil
        await self.engine.cancelGaplessNext()
    }

    /// Reset armed state (e.g. when user skips manually).
    public func reset() async {
        self.armedForItemID = nil
        self.incompatibleLoggedForItemID = nil
        await self.engine.cancelGaplessNext()
    }

    // MARK: - Private

    private func pollLoop() async {
        while !Task.isCancelled {
            await self.checkAndArm()
            try? await Task.sleep(nanoseconds: 500_000_000) // 500 ms
        }
    }

    private func checkAndArm() async {
        let remaining = await remainingTime()
        let preroll = Self.currentPrerollSeconds()
        // The widest window any boundary can need; a gapless boundary waits
        // for the preroll below.
        let window = await Self.armingWindow(preroll: preroll, crossfadeSeconds: self.crossfade.overlapSeconds)
        guard remaining > 0, remaining <= window else { return }

        // Already armed for this item?
        guard let provider = nextItemProvider else { return }
        guard let (nextItem, transition) = await provider() else { return }
        guard self.armedForItemID != nextItem.id else { return }

        switch transition {
        case .crossfade:
            // No format gate: the engine converts each track to the output
            // format before it mixes them (ADR-095).
            break
        case let .gapless(forceGapless):
            guard remaining <= preroll else { return }
            guard await self.formatAllowsGapless(nextItem, forceGapless: forceGapless) else {
                return // QueuePlayer will do a normal stop/load/play on .ended.
            }
        }

        // Arm the preload. QueuePlayer's performPrefetch does the
        // security-scope dance and calls the engine internally.
        guard let prefetch = performPrefetch else { return }
        do {
            try await prefetch(nextItem, transition)
            self.armedForItemID = nextItem.id
            self.log.debug("gapless.armed", [
                "nextTrack": nextItem.trackID,
                "remaining": remaining,
                "crossfade": transition.isCrossfade,
            ])
        } catch {
            self.log.error("gapless.prefetch.failed", ["error": String(reflecting: error)])
            self.onPrefetchFailed?(error)
        }
    }

    /// The plain gapless format gate. Without `forceGapless` the formats
    /// must pass `FormatBridge`; with it, only the sample rate and channel
    /// count must match. Logs a refusal once per item.
    private func formatAllowsGapless(_ nextItem: QueueItem, forceGapless: Bool) async -> Bool {
        guard let currentFmt = await engine.sourceFormat else { return false }
        let nextFmt = self.toAVAudioFormat(nextItem.sourceFormat)
        let compatible = forceGapless
            ? currentFmt.sampleRate == nextFmt.sampleRate && currentFmt.channelCount == nextFmt.channelCount
            : self.bridge.isCompatible(currentFmt, nextFmt)
        if !compatible, self.incompatibleLoggedForItemID != nextItem.id {
            self.incompatibleLoggedForItemID = nextItem.id
            self.log.debug(forceGapless ? "gapless.forced.incompatible" : "gapless.incompatible", [
                "next": nextItem.trackID,
                "currentRate": currentFmt.sampleRate,
                "nextRate": nextItem.sourceFormat.sampleRate,
            ])
        }
        return compatible
    }

    private func remainingTime() async -> TimeInterval {
        let current = await engine.currentTime
        let total = await engine.duration
        guard total > 0 else { return 0 }
        return max(0, total - current)
    }

    private func toAVAudioFormat(_ fmt: AudioSourceFormat) -> AVAudioFormat {
        // Build an AVAudioFormat for comparison purposes only.
        // We use standard non-interleaved float format since the engine normalises everything.
        AVAudioFormat(
            standardFormatWithSampleRate: fmt.sampleRate,
            channels: AVAudioChannelCount(fmt.channelCount)
        ) ?? AVAudioFormat(
            standardFormatWithSampleRate: 44100,
            channels: 2
        )! // swiftlint:disable:this force_unwrapping
    }
}
