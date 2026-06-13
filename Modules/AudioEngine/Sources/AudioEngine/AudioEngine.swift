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
public actor AudioEngine: Transport, AudioGraphInsertionPoint {
    // .default QoS: AVAudioPlayerNode.stop() blocks on AVFoundation's internal
    // default-QoS threads; running the actor at userInitiated caused priority
    // inversions (FB13119463). Real-time rendering is handled by AVFoundation's
    // own high-priority threads, not this actor.
    private static let _executor = DispatchSerialQueue(label: "com.bocan.audio-engine", qos: .default)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    // MARK: - State

    let graph: EngineGraph
    let deviceRouter: DeviceRouter
    let presets: PresetStore
    var decoder: (any Decoder)?
    var pump: BufferPump?
    // swiftlint:disable identifier_name
    var _currentTime: TimeInterval = 0
    var _duration: TimeInterval = 0
    /// Sample-time offset recorded at each gapless transition.
    ///
    /// `AVAudioPlayerNode.playerTime(forNodeTime:).sampleTime` is cumulative from
    /// the moment the node first started playing — it never resets during a gapless
    /// transition.  Subtracting this offset gives a 0-based position for each new
    /// track. Reset to 0 whenever the node is stopped (load / stop / seek).
    var _playerTimeOffset: AVAudioFramePosition = 0
    var _state: PlaybackState = .idle
    // swiftlint:enable identifier_name
    var lastState: PlaybackState?
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?
    let log = AppLogger.make(.audio)

    // MARK: - Gapless state

    /// The pre-loaded pump for the next track. Non-nil while a gapless preload is in progress.
    var pendingNextPump: BufferPump?
    /// Duration of the pending next track (read from its decoder).
    var pendingNextDuration: TimeInterval = 0
    /// Decoder for the pending next track (becomes `decoder` on transition).
    var pendingNextDecoder: (any Decoder)?
    /// Caller-supplied callback fired when the engine seamlessly transitions to the next track.
    var pendingNextTransition: (@Sendable () -> Void)?
    /// Timestamp of the most recent gapless transition.  Used to suppress a
    /// spurious second `.ended` that can fire when the just-swapped-in pump
    /// reports EOF before its first buffer has rendered (e.g. a race where the
    /// pump's decoder sees an empty read at activation time).
    var lastGaplessTransitionAt: Date?
    /// Crossfade volume ramp task. Cancelled in `load()` and `stop()`.
    var crossfadeTask: Task<Void, Never>?

    /// Start offset in the source file for the current CUE segment (seconds).
    /// Zero for ordinary non-CUE tracks.
    private var segmentStart: TimeInterval = 0
    /// End offset in the source file for the current CUE segment (seconds).
    /// `nil` means play to decoder EOF (last CUE track or ordinary tracks).
    private var segmentEndTime: TimeInterval?

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
            let adjustedFrames = playerTime.sampleTime - self._playerTimeOffset
            return self._currentTime + AudioTime.timeInterval(for: adjustedFrames, sampleRate: rate)
        }
    }

    public var duration: TimeInterval {
        get async { self._duration }
    }

    /// `true` when the engine is in `.playing`. Used by the App layer to
    /// decide whether to auto-resume on wake.
    public var isPlaying: Bool {
        self._state == .playing
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
        guard let outputFmt = StereoLayout.format(sampleRate: sampleRate) else {
            throw AudioEngineError.outputDeviceUnavailable
        }

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

    // MARK: - Tap state

    /// The active audio tap, or `nil` when visualization is off.
    var tap: AudioTap?

    // MARK: - Init

    public init(presets: PresetStore = PresetStore()) {
        self.graph = EngineGraph()
        self.deviceRouter = DeviceRouter()
        self.presets = presets

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        // When AVAudioEngine reconfigures itself (sample-rate change, device plug/unplug)
        // it silently removes all installed taps from the mixer. We must tear down the
        // AudioTap ourselves so the AsyncStream continuation is properly finished,
        // allowing the VisualizerViewModel's restart loop to reconnect cleanly.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.graph.engine,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in await self?.stopTap() }
        }
    }

    // MARK: - Transport conformance

    public func load(_ url: URL) async throws {
        // Cancel any in-flight crossfade before touching volume or stopping the node.
        self.cancelCrossfade()
        // Click-suppression: ramp the player-node volume to 0 *before* stop().
        // AVAudioPlayerNode.stop() truncates whatever sample is currently in
        // flight; if that sample is mid-cycle (which it almost always is) the
        // discontinuity rings the speaker. A 10 ms cosine fade hides it.
        await self.fadePlayerNode(to: 0)

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
            self._playerTimeOffset = 0
            self.segmentStart = 0
            self.segmentEndTime = nil
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

    // MARK: - Transport serialization

    // play / pause / seek / stop suspend partway through, and the actor is
    // reentrant at those await points, so without a gate a second transport call
    // interleaves and strands the pump (node "playing", no audio). This async
    // mutex serializes them; the `perform*` variants let internal callers (seek's
    // resume, the device-change handler) run without re-acquiring and deadlocking.
    private var transportBusy = false
    private var transportWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireTransport() async {
        while self.transportBusy {
            await withCheckedContinuation { self.transportWaiters.append($0) }
        }
        self.transportBusy = true
    }

    func releaseTransport() {
        self.transportBusy = false
        guard !self.transportWaiters.isEmpty else { return }
        self.transportWaiters.removeFirst().resume()
    }

    public func play() async throws {
        await self.acquireTransport()
        defer { self.releaseTransport() }
        try await self.performPlay()
    }

    func performPlay() async throws {
        guard let dec = decoder else { return }
        // Already playing with a live pump: a redundant play() (double-tap, or a
        // remote command racing the button) is a no-op, not a pump rebuild.
        if self._state == .playing, self.pump != nil { return }
        let start = Date()
        self.log.debug("engine.play.start")

        do {
            try self.graph.start()
        } catch {
            let ae = error as? AudioEngineError ?? .engineStartFailed(underlying: error)
            self.emit(.failed(ae))
            throw ae
        }

        // Resuming from pause WITH a live pump: just restart the node (its FIFO is
        // intact). Recreating the pump here would deadlock (pump.stop() awaits
        // dataPlayedBack callbacks that never fire on a paused node). The
        // `pump != nil` guard matters because a paused CUE seek nils the pump; that
        // case falls through to a fresh start (the nil pump's stop() is a no-op).
        if self._state == .paused, self.pump != nil {
            // Fade in from the muted state we entered on pause.
            self.graph.playerNode.volume = 0
            self.graph.playerNode.play()
            await self.fadePlayerNode(to: 1)
            self.emit(.playing)
            self.log.debug("engine.play.end", ["ms": -start.timeIntervalSinceNow * 1000])
            return
        }

        // Build canonical output format.
        let sampleRate = self.graph.outputSampleRate
        guard let outputFmt = StereoLayout.format(sampleRate: sampleRate) else {
            throw AudioEngineError.outputDeviceUnavailable
        }

        // Fresh start: stop any existing pump before creating a replacement
        // so it can't race the new one on the shared decoder.
        await self.pump?.stop()
        self.pump = nil
        let playerNode = self.graph.playerNode
        let newPump = try BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt,
            maxDuration: segmentEndTime.map { $0 - self.segmentStart }
        )
        self.pump = newPump

        let pumpID = newPump.id
        // [weak self]: the pump stores this closure (engine → pump → onEnded),
        // so a strong capture would form an engine ⇄ pump cycle that never
        // releases while a track is loaded. A deallocated engine has nothing to
        // handle, so a nil self correctly no-ops.
        await newPump.start { [weak self] in
            Task { await self?.handleEnded(firedBy: pumpID) }
        }

        // Cold start: ramp player-node volume from 0 → 1 over ~10 ms to mask
        // the audible click that occurs when AVAudioEngine connects a fresh
        // graph at the hardware sample rate. Has no audible effect on warm
        // restarts because volume is already 1.
        self.graph.playerNode.volume = 0
        playerNode.play()
        await self.fadePlayerNode(to: 1)
        self.emit(.playing)
        self.log.debug("engine.play.end", ["ms": -start.timeIntervalSinceNow * 1000])
    }

    public func pause() async {
        await self.acquireTransport()
        defer { self.releaseTransport() }
        await self.performPause()
    }

    func performPause() async {
        self.log.debug("engine.pause")
        let playerNode = self.graph.playerNode
        // Capture position *before* the fade so the displayed time doesn't
        // tick forward during the ramp.
        if let time = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: time) {
            let rate = playerNode.outputFormat(forBus: 0).sampleRate
            let adjustedFrames = playerTime.sampleTime - self._playerTimeOffset
            self._currentTime += AudioTime.timeInterval(for: adjustedFrames, sampleRate: rate)
        }
        await self.fadePlayerNode(to: 0)
        playerNode.pause()
        self.emit(.paused)
    }

    public func setVolume(_ volume: Float) async {
        self.graph.mixer.outputVolume = max(0, min(1, volume))
    }

    public func stop() async {
        await self.acquireTransport()
        defer { self.releaseTransport() }
        await self.performStop()
    }

    func performStop() async {
        self.log.debug("engine.stop")
        await self.cancelGaplessNext()
        // 10 ms fade keeps stop() from popping mid-cycle.
        self.cancelCrossfade()
        await self.fadePlayerNode(to: 0)
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        self.graph.stop()
        self._currentTime = 0
        self._playerTimeOffset = 0
        self.emit(.stopped)
    }

    public func seek(to time: TimeInterval) async throws {
        await self.acquireTransport()
        defer { self.releaseTransport() }
        try await self.performSeek(to: time)
    }

    func performSeek(to time: TimeInterval) async throws {
        guard let dec = decoder else { return }
        guard self._duration == 0 || time <= self._duration + 0.001 else {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self._duration)
        }

        self.log.debug("engine.seek", ["time": time])

        let wasPlaying = self._state == .playing

        // CUE virtual track (a frame-limited segment): rebuild the pump so its
        // frame-limit accounting resets cleanly. Rare path; keep the teardown.
        if self.segmentEndTime != nil {
            if wasPlaying {
                await self.fadePlayerNode(to: 0)
            }
            self.graph.playerNode.stop()
            await self.pump?.stop()
            self.pump = nil
            try await dec.seek(to: time)
            self._currentTime = time
            self._playerTimeOffset = 0
            if wasPlaying {
                try await self.performPlay()
            }
            return
        }

        // No pump yet (seek before play, or after stop): just reposition the
        // decoder; the next play() builds a fresh pump from here.
        guard let pump = self.pump else {
            try await dec.seek(to: time)
            self._currentTime = time
            self._playerTimeOffset = 0
            return
        }

        // Ordinary track: reschedule the live pump in place instead of tearing it
        // down, so the seek is a feed restart at the new position rather than a
        // full stop + pump rebuild (the old path's audible gap). Mute first so the
        // old position is not heard while the node is flushed; the new position
        // fades in. When paused, the node is left stopped with the new buffers
        // queued, and resume() plays them via its fast path (the pump stays alive,
        // so it is not nil).
        if wasPlaying {
            self.graph.playerNode.volume = 0
        }
        try await pump.reschedule(to: time)
        self._currentTime = time
        self._playerTimeOffset = 0
        if wasPlaying {
            self.graph.playerNode.play()
            await self.fadePlayerNode(to: 1)
        }
    }

    // MARK: - CUE segment support

    /// Configure the engine to play a specific segment [start, end) of the
    /// already-loaded audio file.
    ///
    /// Call this after `load(_:)` and before `play()`. The method seeks the decoder
    /// to `start`, resets `currentTime` to zero (NowPlaying shows 0-based progress
    /// within the segment), and clamps `duration` to the segment length.
    ///
    /// Passing `end: nil` means play to the decoder's natural EOF (last CUE track).
    public func setSegment(start: TimeInterval, end: TimeInterval?) async throws {
        guard let dec = self.decoder else { return }
        let fileDuration = dec.duration
        try await dec.seek(to: start)
        self.segmentStart = start
        self.segmentEndTime = end
        self._currentTime = 0
        self._duration = (end ?? fileDuration) - start
        self.log.debug("engine.setSegment", [
            "start": start,
            "end": end as Any,
            "virtualDuration": self._duration,
        ])
    }

    // MARK: - Private helpers

    func emit(_ newState: PlaybackState) {
        guard newState != self.lastState else { return }
        self.lastState = newState
        self._state = newState
        self.stateContinuation?.yield(newState)
    }
}
