// @preconcurrency: AVAudioPlayerNode/AVAudioPCMBuffer lack Sendable; safe because
// BufferPump is the sole owner of its scheduling context.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - BufferPump

/// Reads decoded PCM buffers from a `Decoder` and schedules them onto an
/// `AVAudioPlayerNode` in a background `Task`.
///
/// The pump maintains a small in-flight window of pre-scheduled buffers (4 × 200 ms)
/// and uses buffer-completion callbacks to throttle the refill rate, keeping memory
/// usage predictable even for very long files.
///
/// During a crossfade the pump reads a second source and mixes the two into
/// the buffers it schedules (ADR-095; the logic is in `BufferPump+Overlap`).
/// The node still sees one continuous stream.
///
/// All cancellation is handled via standard Swift structured concurrency — cancel
/// the `Task` returned by `start()` to stop the pump cleanly.
actor BufferPump {
    private static let _executor = DispatchSerialQueue(label: "com.bocan.buffer-pump", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    // MARK: - Configuration

    /// Number of buffers kept in-flight ahead of the render thread.
    /// 4 × 200 ms = 0.8 s of headroom — enough to survive a scheduler hiccup
    /// without starving the AVAudioPlayerNode, while keeping the worst-case
    /// teardown-and-refill on a seek small (the whole window is rescheduled on
    /// every seek, so an oversized window directly inflates seek latency against
    /// the < 50 ms baseline). See #277.
    private static let windowSize = 4 // number of buffers in flight
    static let bufferDuration = 0.2 // seconds per buffer

    // MARK: - Dependencies

    /// The track this pump reads: decoder, converter and frame counts. During
    /// a crossfade this is the outgoing track until the mix ends, then the
    /// incoming one.
    var current: PumpSource
    let playerNode: AVAudioPlayerNode

    /// When the node reports a buffer done. `.dataPlayedBack` in the app: the
    /// crossfade transition must fire when the audio is heard. Offline
    /// rendering never reports `.dataPlayedBack` (the SDK documents it for
    /// device rendering only), so the render tests pass `.dataRendered`.
    private let completionCallbackType: AVAudioPlayerNodeCompletionCallbackType

    /// The source's decode-buffer format. Internal, not private, so
    /// `BufferPumpFormatTests` can read the converter decision back.
    var pumpFormat: AVAudioFormat {
        self.current.pumpFormat
    }

    let log = AppLogger.make(.audio)

    // MARK: - State

    private var task: Task<Void, Error>?
    private var onEnded: (@Sendable () -> Void)?
    /// Fired when the feed loop aborts on a genuine decode/read failure (not
    /// cancellation). Lets the engine recover (reconnect a stream) or surface a
    /// terminal `.failed` state, instead of the pump dying silently while the
    /// node clock keeps advancing — the "no sound but still 'playing'" symptom.
    private var onError: (@Sendable (Error) -> Void)?

    /// Semaphore-style counter for buffer slots.
    private var availableSlots: Int

    /// Continuation for slot release signalling.
    private var slotContinuation: CheckedContinuation<Void, Never>?

    /// 4-character identifier used in log output to distinguish multiple pumps
    /// that coexist briefly during a gapless transition.
    nonisolated let id: String

    /// Running count of successfully scheduled buffers (for diagnostics). Also
    /// the sequence number of the last scheduled buffer.
    private(set) var scheduledCount = 0

    /// Output frames scheduled since the node was last flushed by
    /// `reschedule`, so the frame the node's own clock restarted from. Read
    /// by the offline render tests to render only what has been scheduled.
    private(set) var framesScheduledSinceFlush: AVAudioFramePosition = 0

    /// Number of times the pump blocked waiting for a free slot.
    /// At steady state this is expected — it simply means the window is full and
    /// the pump is throttling itself to playback speed.  Reported at pump.stop/eof.
    private var throttleCount = 0

    /// Set when the feed loop reports the end of the stream; a pump that has
    /// ended cannot take a crossfade any more.
    private(set) var reachedEnd = false

    // MARK: - Crossfade state (ADR-095; logic in BufferPump+Overlap)

    /// The armed, mixing or handed-over crossfade, if any.
    var overlap: PumpOverlap?

    /// Whether the incoming track of the most recent overlap has been heard.
    /// Reset when a new overlap is armed.
    var overlapHeard = false

    /// The next crossfade, armed while the last one still mixes its tail
    /// after its transition was heard. It becomes `overlap` when that mix
    /// ends. A short track can need its own crossfade before the one into it
    /// is done.
    var queuedOverlap: PumpOverlap?

    /// What `stop` and `reschedule` report to the engine: whether the
    /// incoming track of the crossfade the engine is waiting on was heard.
    /// With a queued crossfade that is the queued one, which is not.
    private var engineCrossfadeHeard: Bool {
        self.queuedOverlap == nil && self.overlapHeard
    }

    /// Bumped whenever the node is flushed or the pump stops. A completion
    /// from an older generation (a flushed buffer) never fires a transition.
    private(set) var generation = 0

    /// The highest buffer sequence number the node has reported done in this
    /// generation. Equal to `scheduledCount` when nothing is queued.
    private(set) var lastCompletedSequence = 0

    // MARK: - Init

    /// `maxDuration`, when set, ends the pump after that much source audio
    /// (a CUE segment; see `PumpSource.maxFrames`). `gain` is the track's
    /// linear ReplayGain (`PumpSource.gain`).
    init(
        decoder: any Decoder,
        playerNode: AVAudioPlayerNode,
        outputFormat: AVAudioFormat,
        maxDuration: TimeInterval? = nil,
        gain: Float = 1,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack
    ) throws {
        self.current = try PumpSource(
            decoder: decoder,
            outputFormat: outputFormat,
            maxDuration: maxDuration,
            gain: gain
        )
        self.playerNode = playerNode
        self.completionCallbackType = completionCallbackType
        self.availableSlots = BufferPump.windowSize
        self.id = String(UUID().uuidString.prefix(4))
    }

    /// Whether this pump converts (resamples or folds) before scheduling.
    /// Read-only diagnostic surface for `BufferPumpFormatTests`.
    var hasConverter: Bool {
        self.current.hasConverter
    }

    // MARK: - ReplayGain

    /// Set the linear ReplayGain of whichever source reads `decoder`: the
    /// current track, the incoming one of a crossfade, or the outgoing one
    /// it handed over from. The engine names the track by its decoder,
    /// which stays right however far a crossfade has got (#573).
    func setGain(_ gain: Float, forDecoder decoder: any Decoder) {
        for source in self.sources where source.decoder === decoder {
            source.gain = gain
        }
    }

    /// Every source this pump holds.
    private var sources: [PumpSource] {
        var all = [self.current]
        if let overlap = self.overlap {
            all.append(overlap.incoming)
            if case let .handedOver(outgoing) = overlap.phase {
                all.append(outgoing)
            }
        }
        if let queued = self.queuedOverlap {
            all.append(queued.incoming)
        }
        return all
    }

    /// Output frames in one scheduled buffer (0.2 s at the output rate).
    var outputBufferFrames: Int {
        Int(self.current.outputFormat.sampleRate * BufferPump.bufferDuration)
    }

    // MARK: - Lifecycle

    /// Begin pumping buffers. Returns immediately; pumping happens in the background.
    ///
    /// `onEnded` fires on clean end-of-stream; `onError` fires when the feed loop
    /// aborts on a real decode/read failure (cancellation is never reported as an
    /// error). Exactly one of them fires per feed-loop lifetime, or neither if the
    /// pump is cancelled.
    func start(
        onEnded: @Sendable @escaping () -> Void,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.onEnded = onEnded
        self.onError = onError
        self.availableSlots = BufferPump.windowSize
        self.log.debug("pump.start", ["id": self.id])
        self.task = Task { [weak self] in
            try await self?.run()
        }
    }

    /// Number of buffers handed to the player node so far. Read-only diagnostic
    /// surface (mirrors `scheduledCount`); used by the leak regression test to
    /// confirm completion handlers were actually registered on the node.
    var scheduledBufferCount: Int {
        self.scheduledCount
    }

    /// Stop the pump and wait for the background task to finish.
    ///
    /// An armed or running crossfade ends with it: the pump closes the source
    /// only it holds and keeps the one the engine uses as its decoder
    /// (`releaseOverlapOnStop`). Returns whether the incoming track of the
    /// most recent crossfade had been heard, so the engine can settle a
    /// transition it has not handled yet.
    @discardableResult
    func stop() async -> Bool {
        self.log.debug("pump.stop", [
            "id": self.id,
            "scheduled": self.scheduledCount,
            "throttled": self.throttleCount,
        ])
        // First, before any await: completions that arrive from here on
        // belong to a stopped pump and must not fire a transition.
        self.startNewGeneration()
        self.task?.cancel()
        // Resume the slot continuation BEFORE awaiting the task result.
        // If the pump loop is suspended in withCheckedContinuation waiting for a
        // free slot (e.g. all 4 slots are in-flight on a paused AVAudioPlayerNode
        // whose dataPlayedBack callbacks have stopped firing), the task can never
        // exit on its own — causing a deadlock where stop() waits for the task and
        // the task waits for stop() to resume the continuation.
        self.slotContinuation?.resume()
        self.slotContinuation = nil
        _ = await self.task?.result // drain
        self.task = nil
        let heard = self.engineCrossfadeHeard
        await self.releaseOverlapOnStop()
        return heard
    }

    /// Seek in place WITHOUT tearing the pump down: stop the current feed, flush
    /// the player node's queued (old-position) buffers, reseek the shared decoder,
    /// and resume feeding from the new position. Reuses this pump and its
    /// converter, so a seek costs a feed restart plus one buffer's decode rather
    /// than a full pump teardown and rebuild. The feed task is fully drained before
    /// the reseek, so no in-flight read can schedule a stale buffer. The caller
    /// mutes/plays the node around this; the node is left stopped with the first
    /// new-position buffers queued.
    ///
    /// During a crossfade the seek goes to the track the listener hears: the
    /// outgoing one (and the crossfade re-arms) until the transition is heard,
    /// the incoming one after (`rewindOverlapForSeek`). Returns whether the
    /// incoming track of the most recent crossfade had been heard.
    @discardableResult
    func reschedule(to time: TimeInterval) async throws -> Bool {
        // First, before any await: the node is about to be flushed, so no
        // completion from here on may fire a transition.
        self.startNewGeneration()
        // Stop the feed loop fully (resume any slot wait so a parked loop can exit).
        self.task?.cancel()
        self.slotContinuation?.resume()
        self.slotContinuation = nil
        _ = await self.task?.result
        self.task = nil

        // Flush the node's queued buffers and reset its sample time, then reseek
        // (which also restarts the source's frame counts, segment budget included).
        self.playerNode.stop()
        self.framesScheduledSinceFlush = 0
        let heard = self.engineCrossfadeHeard
        try await self.rewindOverlapForSeek()
        try await self.current.seek(to: time)
        self.reachedEnd = false

        // Restore the window and resume feeding from the new position.
        self.availableSlots = BufferPump.windowSize
        self.log.debug("pump.reschedule", ["id": self.id, "time": time])
        self.task = Task { [weak self] in
            try await self?.run()
        }
        return heard
    }

    // MARK: - Private pump loop

    private func run() async throws {
        while !Task.isCancelled {
            if self.availableSlots <= 0 {
                try await self.waitForSlot()
                continue
            }
            try Task.checkCancellation()

            let keepFeeding = if self.overlap == nil {
                try await self.feedStep()
            } else {
                try await self.overlapStep()
            }
            if !keepFeeding {
                break
            }
        }
    }

    /// One iteration of the plain feed: schedule one buffer of `current`, or
    /// report the end. Returns `false` when the loop should stop.
    func feedStep() async throws -> Bool {
        // Frames left over from a crossfade go out first, in order.
        if let carried = self.current.pending.take(self.outputBufferFrames) {
            self.claimSlotAndSchedule(carried)
            return true
        }

        guard let buffer = self.current.makeReadBuffer(duration: BufferPump.bufferDuration) else {
            self.log.error("buffer.alloc.failed", ["id": self.id])
            return false
        }

        // Taken before the read, which advances the source's count.
        let segmentRemaining = self.current.remainingSegmentFrames

        let framesRead = try await self.read(self.current, into: buffer)

        if framesRead == 0 {
            self.log.debug("pump.eof", ["id": self.id, "scheduled": self.scheduledCount])
            self.signalEnded()
            return false
        }

        // Enforce segment boundary for CUE virtual tracks.
        if let remaining = segmentRemaining, framesRead >= remaining {
            try self.scheduleSegmentEnd(buffer: buffer, trimTo: remaining)
            return false
        }

        try self.scheduleBuffer(buffer)
        return true
    }

    /// Fill `buffer` from `source`, reporting a failure to the engine.
    /// Returns `0` at end-of-stream.
    func read(_ source: PumpSource, into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        do {
            return try await source.read(into: buffer)
        } catch is CancellationError {
            // Normal teardown (load / seek / stop cancels the feed task). Not a
            // failure: stay quiet and let the cancellation propagate.
            throw CancellationError()
        } catch {
            self.log.error("pump.read.failed", [
                "id": self.id, "afterScheduled": self.scheduledCount,
                "error": String(reflecting: error),
            ])
            // Hand the failure to the engine BEFORE the task unwinds, so it can
            // reconnect or surface `.failed` rather than the loop dying unseen.
            self.onError?(error)
            throw error
        }
    }

    /// Report a failure that ends the feed loop to the engine, the same way
    /// a read failure is reported.
    func reportFailure(_ error: Error) {
        self.onError?(error)
    }

    /// Schedule the final partial buffer at the CUE segment boundary, then signal EOF.
    private func scheduleSegmentEnd(buffer: AVAudioPCMBuffer, trimTo frameCount: AVAudioFrameCount) throws {
        buffer.frameLength = frameCount
        guard let resampled = try resampledBuffer(buffer) else { return }
        self.claimSlotAndSchedule(resampled)
        self.log.debug("pump.segment.end", ["id": self.id, "scheduled": self.scheduledCount])
        self.signalEnded()
    }

    /// Invoke the end-of-stream callback directly on the pump's executor.
    ///
    /// The stored `onEnded` closure dispatches onto the engine actor itself (it
    /// wraps its work in a `Task`), so routing it through an extra `@MainActor`
    /// `Task` hop bought nothing and only widened the window in which that second
    /// hop could be lost if the engine deallocated mid-handoff. See #262.
    private func signalEnded() {
        self.reachedEnd = true
        self.onEnded?()
    }

    /// Resample (if needed) then claim a window slot and hand the buffer to AVAudioPlayerNode.
    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard let resampled = try resampledBuffer(buffer) else { return }
        self.claimSlotAndSchedule(resampled)
    }

    func claimSlotAndSchedule(_ buffer: AVAudioPCMBuffer) {
        self.availableSlots -= 1
        self.scheduledCount += 1
        self.framesScheduledSinceFlush += AVAudioFramePosition(buffer.frameLength)
        let sequence = self.scheduledCount
        let generation = self.generation
        // [weak self]: the player node retains this completion handler until the
        // buffer is played back (or the node is reset). A strong capture would
        // keep a logically-stopped pump alive for the lifetime of the node. If
        // the pump is gone the slot bookkeeping is moot, so a nil self no-ops.
        self.playerNode.scheduleBuffer(buffer, completionCallbackType: self.completionCallbackType) { [weak self] _ in
            Task { await self?.bufferCompleted(sequence: sequence, generation: generation) }
        }
    }

    /// Suspends until a buffer slot is released by a `dataPlayedBack` callback.
    /// This is the normal steady-state path — the pump fills all slots quickly,
    /// then waits ~200 ms for each one to drain.
    private func waitForSlot() async throws {
        self.throttleCount += 1
        await withCheckedContinuation { continuation in
            self.slotContinuation = continuation
        }
        try Task.checkCancellation()
    }

    /// `buffer` in the output format via `source`'s converter (unchanged when
    /// no conversion is needed). Returns `nil` for empty input. Logs a
    /// conversion failure here, where the pump id is known, then rethrows.
    func resampledBuffer(_ buffer: AVAudioPCMBuffer, from source: PumpSource? = nil) throws -> AVAudioPCMBuffer? {
        do {
            return try (source ?? self.current).convert(buffer)
        } catch {
            self.log.error("pump.convert.failed", ["id": self.id, "error": String(reflecting: error)])
            throw error
        }
    }

    /// Called by the completion callback when a buffer finishes playing: frees
    /// its slot, and fires a crossfade transition that was waiting on it.
    private func bufferCompleted(sequence: Int, generation: Int) async {
        self.releaseSlot()
        guard generation == self.generation else { return }
        self.lastCompletedSequence = max(self.lastCompletedSequence, sequence)
        if let after = self.overlap?.transitionAfter, sequence >= after {
            await self.fireTransition()
        }
    }

    private func releaseSlot() {
        self.availableSlots += 1
        if let cont = slotContinuation {
            self.slotContinuation = nil
            cont.resume()
        }
    }

    /// Start a new completion generation: nothing scheduled so far counts as
    /// queued any more.
    private func startNewGeneration() {
        self.generation += 1
        self.lastCompletedSequence = self.scheduledCount
    }
}
