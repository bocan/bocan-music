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
    private static let bufferDuration = 0.2 // seconds per buffer

    // MARK: - Dependencies

    private let decoder: any Decoder
    private let playerNode: AVAudioPlayerNode
    private let outputFormat: AVAudioFormat

    /// Format used to allocate intermediate decode buffers. Equals `outputFormat`
    /// unless the decoder's native rate differs, in which case it equals `decoder.sourceFormat`
    /// and `converter` resamples those buffers to `outputFormat` before scheduling.
    private let pumpFormat: AVAudioFormat

    /// Non-nil only when `decoder.sourceFormat.sampleRate != outputFormat.sampleRate`.
    /// `AVFoundationDecoder` handles SRC internally via AVAudioFile, but FFmpegDecoder
    /// does not — without this converter it would fill hardware-rate buffers with
    /// source-rate samples, causing playback at the wrong speed and pitch.
    private let converter: FormatConverter?

    private let log = AppLogger.make(.audio)

    // MARK: - State

    private var task: Task<Void, Error>?
    private var onEnded: (@Sendable () -> Void)?

    /// Semaphore-style counter for buffer slots.
    private var availableSlots: Int

    /// Continuation for slot release signalling.
    private var slotContinuation: CheckedContinuation<Void, Never>?

    /// 4-character identifier used in log output to distinguish multiple pumps
    /// that coexist briefly during a gapless transition.
    nonisolated let id: String

    /// Running count of successfully scheduled buffers (for diagnostics).
    private var scheduledCount = 0

    /// Number of times the pump blocked waiting for a free slot.
    /// At steady state this is expected — it simply means the window is full and
    /// the pump is throttling itself to playback speed.  Reported at pump.stop/eof.
    private var throttleCount = 0

    /// When non-nil, the pump stops after this many output frames have been
    /// scheduled.  Used to enforce the `endOffsetMs` of a CUE virtual track
    /// without relying on the underlying decoder reaching true EOF.
    private let maxFrames: AVAudioFrameCount?

    // MARK: - Init

    init(
        decoder: any Decoder,
        playerNode: AVAudioPlayerNode,
        outputFormat: AVAudioFormat,
        maxDuration: TimeInterval? = nil
    ) throws {
        self.decoder = decoder
        self.playerNode = playerNode
        self.outputFormat = outputFormat
        self.availableSlots = BufferPump.windowSize
        self.id = String(UUID().uuidString.prefix(4))
        self.maxFrames = maxDuration.map { AVAudioFrameCount($0 * outputFormat.sampleRate) }
        if decoder.sourceFormat.sampleRate != outputFormat.sampleRate {
            self.converter = try FormatConverter(sourceFormat: decoder.sourceFormat, targetFormat: outputFormat)
            self.pumpFormat = decoder.sourceFormat
        } else {
            self.converter = nil
            self.pumpFormat = outputFormat
        }
    }

    // MARK: - Lifecycle

    /// Begin pumping buffers. Returns immediately; pumping happens in the background.
    func start(onEnded: @Sendable @escaping () -> Void) {
        self.onEnded = onEnded
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
    func stop() async {
        self.log.debug("pump.stop", [
            "id": self.id,
            "scheduled": self.scheduledCount,
            "throttled": self.throttleCount,
        ])
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
    }

    // MARK: - Private pump loop

    private func run() async throws {
        let frameCapacity = AVAudioFrameCount(pumpFormat.sampleRate * BufferPump.bufferDuration)
        var framesPumped: AVAudioFrameCount = 0

        while !Task.isCancelled {
            if self.availableSlots <= 0 { try await self.waitForSlot()
                continue
            }
            try Task.checkCancellation()

            guard let buffer = AVAudioPCMBuffer(pcmFormat: pumpFormat, frameCapacity: frameCapacity) else {
                self.log.error("buffer.alloc.failed", ["id": self.id])
                break
            }

            let framesRead: AVAudioFrameCount
            do {
                framesRead = try await self.decoder.read(into: buffer)
            } catch {
                self.log.error("pump.read.failed", [
                    "id": self.id, "afterScheduled": self.scheduledCount,
                    "error": String(reflecting: error),
                ])
                throw error
            }

            if framesRead == 0 {
                self.log.debug("pump.eof", ["id": self.id, "scheduled": self.scheduledCount])
                self.signalEnded()
                break
            }

            // Enforce segment boundary for CUE virtual tracks.
            if let limit = self.maxFrames {
                let remaining = limit - framesPumped
                if framesRead >= remaining {
                    try self.scheduleSegmentEnd(buffer: buffer, trimTo: remaining)
                    break
                }
                framesPumped += framesRead
            }

            try self.scheduleBuffer(buffer)
        }
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
        self.onEnded?()
    }

    /// Resample (if needed) then claim a window slot and hand the buffer to AVAudioPlayerNode.
    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard let resampled = try resampledBuffer(buffer) else { return }
        self.claimSlotAndSchedule(resampled)
    }

    private func claimSlotAndSchedule(_ buffer: AVAudioPCMBuffer) {
        self.availableSlots -= 1
        self.scheduledCount += 1
        // [weak self]: the player node retains this completion handler until the
        // buffer is played back (or the node is reset). A strong capture would
        // keep a logically-stopped pump alive for the lifetime of the node. If
        // the pump is gone the slot bookkeeping is moot, so a nil self no-ops.
        self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.releaseSlot() }
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

    /// Returns `source` unchanged when no sample-rate conversion is needed;
    /// otherwise resamples via `FormatConverter`. Returns `nil` for empty input.
    private func resampledBuffer(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let conv = self.converter else { return source }
        do {
            return try conv.convert(source)
        } catch {
            self.log.error("pump.convert.failed", ["id": self.id, "error": String(reflecting: error)])
            throw error
        }
    }

    /// Called by the completion callback when a buffer finishes playing.
    private func releaseSlot() {
        self.availableSlots += 1
        if let cont = slotContinuation {
            self.slotContinuation = nil
            cont.resume()
        }
    }
}
