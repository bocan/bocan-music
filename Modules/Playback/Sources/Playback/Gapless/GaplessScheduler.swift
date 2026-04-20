import AudioEngine
@preconcurrency import AVFoundation
import Foundation
import Observability

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
/// The scheduler runs a polling loop (checks every 500 ms) and arms the gapless
/// preload when `remaining ≤ prerollSeconds`.
public actor GaplessScheduler {
    // MARK: - Configuration

    /// How many seconds before track end to begin pre-scheduling.
    private static let prerollSeconds: TimeInterval = 7.0

    // MARK: - Dependencies

    private let engine: AudioEngine
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

    /// Called when the scheduler wants to know the next item and whether the
    /// containing album opts into force-gapless.  Returns `nil` for no next item.
    var nextItemProvider: (@Sendable () async -> (item: QueueItem, forceGapless: Bool)?)?

    /// Called when the scheduler has decided to arm the next track.  The caller
    /// (QueuePlayer) is responsible for resolving security scope, calling
    /// `engine.enableGaplessNext`, and releasing scope afterwards.
    /// Throws propagate back into the scheduler so `onPrefetchFailed` fires.
    var performPrefetch: (@Sendable (QueueItem) async throws -> Void)?

    /// Called when the gapless transition actually fires (old track's decoder hits EOF).
    /// Receives the queue item that has just become active.
    var onGaplessTransition: (@Sendable (QueueItem) async -> Void)?

    /// Called when `performPrefetch` throws (for logging/metrics only; caller falls back).
    var onPrefetchFailed: (@Sendable (Error) -> Void)?

    // MARK: - Init

    public init(engine: AudioEngine) {
        self.engine = engine
    }

    // MARK: - Configuration

    /// Set all callbacks in a single actor hop.
    public func configure(
        nextItemProvider: (@Sendable () async -> (item: QueueItem, forceGapless: Bool)?)?,
        performPrefetch: (@Sendable (QueueItem) async throws -> Void)?,
        onGaplessTransition: (@Sendable (QueueItem) async -> Void)?,
        onPrefetchFailed: (@Sendable (Error) -> Void)?
    ) {
        self.nextItemProvider = nextItemProvider
        self.performPrefetch = performPrefetch
        self.onGaplessTransition = onGaplessTransition
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
        guard remaining > 0, remaining <= Self.prerollSeconds else { return }

        // Already armed for this item?
        guard let provider = nextItemProvider else { return }
        guard let (nextItem, forceGapless) = await provider() else { return }
        guard self.armedForItemID != nextItem.id else { return }

        // Check format compatibility — skipped when forceGapless is set and formats
        // would otherwise only fail the padding-tag gate (not the sample-rate gate).
        if !forceGapless {
            guard let currentFmt = await engine.sourceFormat else { return }
            guard self.bridge.isCompatible(
                currentFmt,
                self.toAVAudioFormat(nextItem.sourceFormat)
            ) else {
                if self.incompatibleLoggedForItemID != nextItem.id {
                    self.incompatibleLoggedForItemID = nextItem.id
                    self.log.debug("gapless.incompatible", [
                        "next": nextItem.trackID,
                        "currentRate": currentFmt.sampleRate,
                        "nextRate": nextItem.sourceFormat.sampleRate,
                    ])
                }
                return // QueuePlayer will do a normal stop/load/play on .ended.
            }
        } else {
            // force_gapless: still honour the hardware sample-rate constraint.
            guard let currentFmt = await engine.sourceFormat else { return }
            let nextFmt = self.toAVAudioFormat(nextItem.sourceFormat)
            guard currentFmt.sampleRate == nextFmt.sampleRate,
                  currentFmt.channelCount == nextFmt.channelCount else {
                if self.incompatibleLoggedForItemID != nextItem.id {
                    self.incompatibleLoggedForItemID = nextItem.id
                    self.log.debug("gapless.forced.incompatible", [
                        "next": nextItem.trackID,
                        "currentRate": currentFmt.sampleRate,
                        "nextRate": nextItem.sourceFormat.sampleRate,
                    ])
                }
                return
            }
        }

        // Arm the gapless preload. QueuePlayer's performPrefetch does the
        // security-scope dance and calls engine.enableGaplessNext internally.
        guard let prefetch = performPrefetch else { return }
        do {
            try await prefetch(nextItem)
            self.armedForItemID = nextItem.id
            self.log.debug("gapless.armed", ["nextTrack": nextItem.trackID, "remaining": remaining])
        } catch {
            self.log.error("gapless.prefetch.failed", ["error": String(reflecting: error)])
            self.onPrefetchFailed?(error)
        }
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
