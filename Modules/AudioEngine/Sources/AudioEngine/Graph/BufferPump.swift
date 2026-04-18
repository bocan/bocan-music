// @preconcurrency: AVAudioPlayerNode/AVAudioPCMBuffer lack Sendable; safe because
// BufferPump is the sole owner of its scheduling context.
// TODO: Remove once AVFoundation adopts Sendable annotations.
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
    // MARK: - Configuration

    private static let windowSize = 4 // number of buffers in flight
    private static let bufferDuration = 0.2 // seconds per buffer

    // MARK: - Dependencies

    private let decoder: any Decoder
    private let playerNode: AVAudioPlayerNode
    private let outputFormat: AVAudioFormat
    private let log = AppLogger.make(.audio)

    // MARK: - State

    private var task: Task<Void, Error>?
    private var onEnded: (@Sendable () -> Void)?

    /// Semaphore-style counter for buffer slots.
    private var availableSlots: Int

    /// Continuation for slot release signalling.
    private var slotContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Init

    init(
        decoder: any Decoder,
        playerNode: AVAudioPlayerNode,
        outputFormat: AVAudioFormat
    ) {
        self.decoder = decoder
        self.playerNode = playerNode
        self.outputFormat = outputFormat
        self.availableSlots = BufferPump.windowSize
    }

    // MARK: - Lifecycle

    /// Begin pumping buffers. Returns immediately; pumping happens in the background.
    func start(onEnded: @Sendable @escaping () -> Void) {
        self.onEnded = onEnded
        self.availableSlots = BufferPump.windowSize
        self.task = Task { [weak self] in
            try await self?.run()
        }
    }

    /// Stop the pump and wait for the background task to finish.
    func stop() async {
        self.task?.cancel()
        _ = await self.task?.result // drain
        self.task = nil
        self.slotContinuation?.resume()
        self.slotContinuation = nil
    }

    // MARK: - Private pump loop

    private func run() async throws {
        let frameCapacity = AVAudioFrameCount(
            outputFormat.sampleRate * BufferPump.bufferDuration
        )

        while !Task.isCancelled {
            // Wait until a slot is available in the in-flight window.
            if self.availableSlots <= 0 {
                await withCheckedContinuation { continuation in
                    self.slotContinuation = continuation
                }
                continue
            }

            try Task.checkCancellation()

            // Allocate and fill a buffer.
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCapacity
            ) else {
                self.log.error("buffer.alloc.failed")
                break
            }

            let framesRead = try await decoder.read(into: buffer)

            if framesRead == 0 {
                // EOF — signal the engine.
                let cb = self.onEnded
                Task { @MainActor in cb?() }
                break
            }

            // Claim a slot and schedule.
            self.availableSlots -= 1
            let selfCapture = self
            self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                Task { await selfCapture.releaseSlot() }
            }
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
