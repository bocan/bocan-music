// @preconcurrency: AVFoundation node types (AVAudioPlayerNode etc.) lack Sendable;
// thread-safety is provided by AudioEngine's actor isolation.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - AudioEngine

/// High-level audio playback façade. Implements `Transport`.
///
/// Owns the `EngineGraph`, `BufferPump`, and current `Decoder`. All state
/// mutations happen on the actor's executor.
///
/// Usage:
/// ```swift
/// let engine = AudioEngine()
/// await engine.load(myURL)
/// try await engine.play()
/// ```
public actor AudioEngine: Transport {
    // .default QoS: AVAudioPlayerNode.stop() blocks on AVFoundation's internal
    // default-QoS threads; running the actor at userInitiated caused priority
    // inversions (FB13119463). Real-time rendering is handled by AVFoundation's
    // own high-priority threads, not this actor.
    private static let _executor = DispatchSerialQueue(label: "com.bocan.audio-engine", qos: .default)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    // MARK: - State

    private let graph: EngineGraph
    private let deviceRouter: DeviceRouter
    private let presets: PresetStore
    private var decoder: (any Decoder)?
    private var pump: BufferPump?
    private var _currentTime: TimeInterval = 0
    private var _duration: TimeInterval = 0
    private var _state: PlaybackState = .idle
    private var lastState: PlaybackState?
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?
    private let log = AppLogger.make(.audio)

    // MARK: - Gapless state

    /// The pre-loaded pump for the next track. Non-nil while a gapless preload is in progress.
    private var pendingNextPump: BufferPump?
    /// Duration of the pending next track (read from its decoder).
    private var pendingNextDuration: TimeInterval = 0
    /// Decoder for the pending next track (becomes `decoder` on transition).
    private var pendingNextDecoder: (any Decoder)?
    /// Caller-supplied callback fired when the engine seamlessly transitions to the next track.
    private var pendingNextTransition: (@Sendable () -> Void)?
    /// Timestamp of the most recent gapless transition.  Used to suppress a
    /// spurious second `.ended` that can fire when the just-swapped-in pump
    /// reports EOF before its first buffer has rendered (e.g. a race where the
    /// pump's decoder sees an empty read at activation time).
    private var lastGaplessTransitionAt: Date?

    // MARK: - Transport: state stream

    public nonisolated let state: AsyncStream<PlaybackState>

    // MARK: - Computed properties

    public var currentTime: TimeInterval {
        get async {
            let playerNode = self.graph.playerNode
            guard self._state == .playing,
                  let renderTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return self._currentTime }

            let rate = playerNode.outputFormat(forBus: 0).sampleRate
            return self._currentTime + AudioTime.timeInterval(for: playerTime.sampleTime, sampleRate: rate)
        }
    }

    public var duration: TimeInterval {
        get async { self._duration }
    }

    // MARK: - Gapless public API

    /// The native source format of the currently loaded track.
    ///
    /// Used by `GaplessScheduler` to determine format compatibility before scheduling
    /// the next track onto the same `AVAudioPlayerNode`.
    public var sourceFormat: AVAudioFormat? {
        get async { self.decoder?.sourceFormat }
    }

    /// Pre-schedule the next track's audio buffers onto the current player node.
    ///
    /// Call this ~5 s before the current track ends. The engine will NOT stop the player
    /// when the current track's decoder hits EOF; instead it calls `onTransition`, resets
    /// timing, and continues playing seamlessly.
    ///
    /// - Parameters:
    ///   - url: File URL of the next track. Must be the same sample rate and channel count
    ///          as the current track (check `sourceFormat` first via `FormatBridge`).
    ///   - onTransition: Invoked on the `AudioEngine` actor when the transition occurs.
    /// - Throws: Any decoder error (file not found, unsupported format, etc.).
    public func enableGaplessNext(url: URL, onTransition: @Sendable @escaping () -> Void) async throws {
        // Cancel any previous pending-next setup.
        await self.pendingNextPump?.stop()
        if let prev = pendingNextDecoder { await prev.close() }
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil

        let dec = try DecoderFactory.make(for: url)
        let nextDuration = dec.duration

        let sampleRate = self.graph.outputSampleRate
        // swiftlint:disable:next force_unwrapping
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        let outputFmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channelLayout: layout
        )

        let playerNode = self.graph.playerNode
        let nextPump = try BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt
        )

        self.pendingNextPump = nextPump
        self.pendingNextDuration = nextDuration
        self.pendingNextDecoder = dec
        self.pendingNextTransition = onTransition

        // Pump is started in `performGaplessTransition` (not here) so its
        // scheduleBuffer calls land strictly after the outgoing pump's tail in
        // the shared AVAudioPlayerNode FIFO — otherwise they interleave.
        self.log.debug("engine.gapless.prefetch", ["url": url.lastPathComponent])
    }

    /// Cancel any active gapless preload without stopping the player.
    public func cancelGaplessNext() async {
        await self.pendingNextPump?.stop()
        if let prev = pendingNextDecoder { await prev.close() }
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        self.log.debug("engine.gapless.cancelled")
    }

    // MARK: - Tap public API

    /// The active audio tap, or `nil` when visualization is off.
    private var tap: AudioTap?

    /// Install a new `AudioTap` on the main mixer and return its sample stream.
    ///
    /// Calling this when a tap is already installed is a no-op; the existing stream
    /// is returned.  The stream ends when `stopTap()` is called.
    public func startTap() -> AsyncStream<AudioSamples> {
        if let existing = tap {
            return existing.samples
        }
        let newTap = AudioTap(bufferSize: 1024)
        self.tap = newTap
        // Install on the main mixer; format:nil → hardware format.
        newTap.install(on: self.graph.mixer)
        self.log.debug("tap.started")
        return newTap.samples
    }

    /// Remove the current tap from the mixer.  The stream returned by ``startTap()``
    /// will finish naturally on the consumer side after this call.
    public func stopTap() {
        guard let current = tap else { return }
        current.remove(from: self.graph.mixer)
        self.tap = nil
        self.log.debug("tap.stopped")
    }

    // MARK: - DSP public API

    /// The DSP chain for this engine. Use to apply presets, adjust effects, and set gain.
    public var dsp: DSPChain {
        self.graph.dsp
    }

    /// Apply a complete `DSPState` snapshot (EQ, bass boost, crossfeed, width, etc.).
    public func applyDSPState(_ state: DSPState) {
        self.graph.dsp.apply(state, presets: self.presets)
    }

    /// Apply the ReplayGain compensation gain in dB.
    public func applyReplayGain(db: Double) {
        self.graph.dsp.applyGain(db: db)
    }

    /// Set the playback rate (0.5×–2.0×). Pitch is preserved via the spectral algorithm.
    public func setRate(_ rate: Float) {
        self.graph.dsp.setRate(rate)
    }

    // MARK: - Init

    public init(presets: PresetStore = PresetStore()) {
        self.graph = EngineGraph()
        self.deviceRouter = DeviceRouter()
        self.presets = presets

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    // MARK: - Transport conformance

    public func load(_ url: URL) async throws {
        // Stop the player node before any awaits — otherwise queued buffers
        // keep playing for ~200 ms through the suspension points below.
        self.graph.playerNode.stop()

        let start = Date()
        self.log.debug("engine.load.start", ["url": url.lastPathComponent])
        self.emit(.loading)

        // Fresh load — any gapless-settle cooldown from a prior transition is moot.
        self.lastGaplessTransitionAt = nil

        // Cancel any gapless preload.
        await self.cancelGaplessNext()

        // Close previous decoder if any.
        if let prev = decoder { await prev.close() }
        self.decoder = nil

        // Stop any running pump.
        await self.pump?.stop()
        self.pump = nil

        // Defensive: re-stop the player node in case the pump scheduled any
        // buffers between our initial stop() and the pump's task being cancelled.
        self.graph.playerNode.stop()

        do {
            let dec = try DecoderFactory.make(for: url)
            self.decoder = dec
            self._duration = dec.duration
            self._currentTime = 0
            self.emit(.ready)
            self.log.debug("engine.load.end", ["ms": -start.timeIntervalSinceNow * 1000])
        } catch {
            let ae = error as? AudioEngineError ?? .decoderFailure(
                codec: "unknown", underlying: error
            )
            self.emit(.failed(ae))
            self.log.error("engine.load.failed", ["error": String(reflecting: error)])
            throw ae
        }
    }

    public func play() async throws {
        guard let dec = decoder else { return }
        let start = Date()
        self.log.debug("engine.play.start")

        do {
            try self.graph.start()
        } catch {
            let ae = error as? AudioEngineError ?? .engineStartFailed(underlying: error)
            self.emit(.failed(ae))
            throw ae
        }

        // Resuming from pause: the pump is already running and the player node's
        // buffer FIFO is intact — just restart the node. Recreating the pump here
        // causes a deadlock (pump.stop() awaits a task blocked in
        // withCheckedContinuation waiting for dataPlayedBack callbacks that can
        // never fire on a paused node) and, if multiple play() calls pile up while
        // suspended, results in several concurrent pumps all writing to the same
        // AVAudioPlayerNode, producing audible judder.
        if self._state == .paused {
            self.graph.playerNode.play()
            self.emit(.playing)
            self.log.debug("engine.play.end", ["ms": -start.timeIntervalSinceNow * 1000])
            return
        }

        // Build canonical output format.
        let sampleRate = self.graph.outputSampleRate
        // swiftlint:disable:next force_unwrapping
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        let outputFmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channelLayout: layout
        )

        // Fresh start: stop any existing pump before creating a replacement
        // so it can't race the new one on the shared decoder.
        await self.pump?.stop()
        self.pump = nil
        let playerNode = self.graph.playerNode
        let newPump = try BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt
        )
        self.pump = newPump

        let pumpID = newPump.id
        await newPump.start { [self] in
            Task { await self.handleEnded(firedBy: pumpID) }
        }

        playerNode.play()
        self.emit(.playing)
        self.log.debug("engine.play.end", ["ms": -start.timeIntervalSinceNow * 1000])
    }

    public func pause() async {
        self.log.debug("engine.pause")
        let playerNode = self.graph.playerNode
        if let time = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: time) {
            let rate = playerNode.outputFormat(forBus: 0).sampleRate
            self._currentTime += AudioTime.timeInterval(for: playerTime.sampleTime, sampleRate: rate)
        }
        playerNode.pause()
        self.emit(.paused)
    }

    public func setVolume(_ volume: Float) async {
        self.graph.mixer.outputVolume = max(0, min(1, volume))
    }

    public func stop() async {
        self.log.debug("engine.stop")
        await self.cancelGaplessNext()
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        self.graph.stop()
        self._currentTime = 0
        self.emit(.stopped)
    }

    public func seek(to time: TimeInterval) async throws {
        guard let dec = decoder else { return }
        guard self._duration == 0 || time <= self._duration + 0.001 else {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self._duration)
        }

        self.log.debug("engine.seek", ["time": time])

        let wasPlaying = self._state == .playing

        // Pause the player while we seek.
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil

        // Seek the decoder.
        try await dec.seek(to: time)
        self._currentTime = time

        if wasPlaying {
            try await self.play()
        }
    }

    // MARK: - Private helpers

    private func emit(_ newState: PlaybackState) {
        guard newState != self.lastState else { return }
        self.lastState = newState
        self._state = newState
        self.stateContinuation?.yield(newState)
    }

    private func handleEnded(firedBy pumpID: String) {
        let currentID = self.pump?.id ?? "nil"
        let pendingID = self.pendingNextPump?.id ?? "nil"
        // Ignore EOF signals from pumps that are neither the active nor the
        // pending-next pump.  Stale signals arise after a seek (which replaces
        // the pump) or after the user triggers a rapid load/skip.
        guard pumpID == currentID || pumpID == pendingID else {
            self.log.debug("engine.handleEnded.stale", [
                "firedBy": pumpID, "current": currentID, "pending": pendingID,
            ])
            return
        }
        self.log.debug("engine.handleEnded.entry", [
            "firedBy": pumpID, "current": currentID, "pending": pendingID,
        ])
        if let next = pendingNextPump, next !== pump {
            self.performGaplessTransition(to: next)
        } else {
            self.finalizeTrackEnded(firedBy: currentID)
        }
    }

    private func performGaplessTransition(to next: BufferPump) {
        // At this moment the outgoing pump has scheduled its complete tail on
        // the player node (that's what its EOF means); ~4 buffers are still
        // in flight and will play out over ~800 ms.  Start the incoming pump
        // NOW — its scheduleBuffer calls land strictly after the outgoing
        // buffers in the node's queue, which is what makes the transition
        // gapless without audio interleaving.
        let prevPump = self.pump
        self.pump = next
        self.pendingNextPump = nil
        self._currentTime = 0
        self._duration = self.pendingNextDuration
        // The pending decoder becomes the active decoder.
        self.decoder = self.pendingNextDecoder
        self.pendingNextDecoder = nil

        let transition = self.pendingNextTransition
        self.pendingNextTransition = nil

        // Force re-emit .playing for the new track's timeline.
        self.lastState = nil
        self.emit(.playing)
        transition?()

        // Start the deferred pump task; its buffers queue after the outgoing pump's tail.
        let newPumpID = next.id
        Task { [self] in
            await next.start {
                Task { await self.handleEnded(firedBy: newPumpID) }
            }
        }

        // Stop (clean up) the old pump; it has already finished scheduling.
        let oldPump = prevPump
        Task { await oldPump?.stop() }

        self.lastGaplessTransitionAt = Date()
        self.log.debug("engine.gapless.transition", [
            "old": prevPump?.id ?? "nil", "new": next.id,
        ])
    }

    private func finalizeTrackEnded(firedBy currentID: String) {
        // Suppress a spurious second `.ended` arriving within the gapless
        // settle window: the just-activated pump can report EOF before its
        // first buffer has rendered, which would tear down the player node
        // and silently stop playback of a track that just started.
        if let t = self.lastGaplessTransitionAt, Date().timeIntervalSince(t) < 1.5 {
            self.log.debug("engine.ended.spurious.afterGapless.ignored", [
                "firedBy": currentID,
            ])
            return
        }
        // No gapless next, or degenerate case (new pump finished before old).
        // Clean up any stale pending state.
        let staleNext = self.pendingNextPump
        let staleDecoder = self.pendingNextDecoder
        self.pendingNextPump = nil
        self.pendingNextDecoder = nil
        self.pendingNextTransition = nil
        Task {
            await staleNext?.stop()
            await staleDecoder?.close()
        }

        self.graph.playerNode.stop()
        self.emit(.ended)
        self.log.debug("engine.playback.ended")
    }
}
