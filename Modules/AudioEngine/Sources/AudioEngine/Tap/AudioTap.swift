import Accelerate

// @preconcurrency: AVAudioTime / AVAudioPCMBuffer lack Sendable.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioSamples

/// An immutable snapshot of one audio render buffer, sized for real-time visualization.
///
/// Produced at the audio buffer rate (~43×/s for 1024-frame buffers at 44100 Hz).
public struct AudioSamples: Sendable {
    public let timeStamp: AVAudioTime
    public let sampleRate: Double
    /// Downmixed mono signal: (L + R) × 0.5.
    public let mono: [Float]
    public let left: [Float]
    public let right: [Float]
    /// RMS level of the mono signal (0…1).
    public let rms: Float
    /// Peak absolute value of the mono signal (0…1).
    public let peak: Float

    public init(
        timeStamp: AVAudioTime,
        sampleRate: Double,
        mono: [Float],
        left: [Float],
        right: [Float],
        rms: Float,
        peak: Float
    ) {
        self.timeStamp = timeStamp
        self.sampleRate = sampleRate
        self.mono = mono
        self.left = left
        self.right = right
        self.rms = rms
        self.peak = peak
    }
}

// MARK: - AudioTap

/// Installs an `AVAudioEngine` tap on a mixer node and publishes ``AudioSamples``
/// via an `AsyncStream`.
///
/// **Thread-safety**: `install(on:)` and `remove(from:)` must be called from the
/// `AudioEngine` actor. The tap block itself runs on AVFoundation's real-time I/O
/// thread; no allocations beyond one small struct copy per callback occur there.
///
/// **Back-pressure**: the stream uses `.bufferingNewest(8)`. If the visualizer
/// consumer falls behind, the oldest un-consumed sample is dropped — visual lag
/// is preferable to audio glitches.
public final class AudioTap: @unchecked Sendable {
    // @unchecked Sendable: `isInstalled` and `tappedNode` are only mutated from
    // the AudioEngine actor (the caller's guarantee). The tap block (RT thread)
    // is read-only after installation.

    // MARK: - Public

    /// The stream of audio samples. Iterate with `for await sample in tap.samples`.
    public nonisolated let samples: AsyncStream<AudioSamples>

    // MARK: - Private

    private let bufferSize: AVAudioFrameCount
    private let continuation: AsyncStream<AudioSamples>.Continuation
    private var isInstalled = false
    private weak var tappedNode: AVAudioNode?

    // MARK: - Init

    /// - Parameter bufferSize: Requested render-block frame count. Default: 1024.
    public init(bufferSize: AVAudioFrameCount = 1024) {
        self.bufferSize = bufferSize
        var cont: AsyncStream<AudioSamples>.Continuation?
        self.samples = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
        // cont is always set synchronously by AsyncStream's initialiser.
        // swiftlint:disable:next force_unwrapping
        self.continuation = cont!
    }

    // MARK: - Public API

    /// Install the tap on `node`. Calling this when already installed is a no-op.
    ///
    /// - Parameter node: The mixer node whose bus 0 output is tapped.
    public func install(on node: AVAudioMixerNode) {
        guard !self.isInstalled else { return }
        self.isInstalled = true
        self.tappedNode = node

        let cont = self.continuation
        let capacity = Int(bufferSize)
        // Pre-allocated scratch storage reused across callbacks (value-type CoW).
        // Each callback triggers one CoW copy per channel (~4 KB × 3) — the minimum
        // unavoidable allocation when producing immutable Sendable snapshots.
        var scratchLeft = [Float](repeating: 0, count: capacity)
        var scratchRight = [Float](repeating: 0, count: capacity)
        var scratchMono = [Float](repeating: 0, count: capacity)

        // `format: nil` → AVAudioEngine chooses the hardware format, which matches
        // the mixer's output format and avoids a sample-rate conversion.
        node.installTap(onBus: 0, bufferSize: self.bufferSize, format: nil) { buffer, time in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let data = buffer.floatChannelData else { return }

            let count = min(frameCount, capacity)

            // Copy L channel into scratch — pointer copy, no Array allocation.
            scratchLeft.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                base.initialize(from: data[0], count: count)
            }

            if buffer.format.channelCount >= 2 {
                scratchRight.withUnsafeMutableBufferPointer { dst in
                    guard let base = dst.baseAddress else { return }
                    base.initialize(from: data[1], count: count)
                }
                // mono = (L + R) × 0.5 — vDSP, no allocation.
                vDSP_vadd(scratchLeft, 1, scratchRight, 1, &scratchMono, 1, vDSP_Length(count))
                var half: Float = 0.5
                vDSP_vsmul(scratchMono, 1, &half, &scratchMono, 1, vDSP_Length(count))
            } else {
                // Mono source: duplicate into right and mono scratch.
                scratchRight.withUnsafeMutableBufferPointer { dst in
                    guard let base = dst.baseAddress else { return }
                    base.initialize(from: data[0], count: count)
                }
                scratchMono.withUnsafeMutableBufferPointer { dst in
                    guard let base = dst.baseAddress else { return }
                    base.initialize(from: data[0], count: count)
                }
            }

            // RMS and peak via vDSP — zero allocation.
            var rms: Float = 0
            vDSP_rmsqv(scratchMono, 1, &rms, vDSP_Length(count))
            var peak: Float = 0
            vDSP_maxmgv(scratchMono, 1, &peak, vDSP_Length(count))

            // Produce the snapshot. The Array(slice) copies each channel once —
            // unavoidable when handing off a Sendable value to the async consumer.
            let snapshot = AudioSamples(
                timeStamp: time,
                sampleRate: buffer.format.sampleRate,
                mono: Array(scratchMono[..<count]),
                left: Array(scratchLeft[..<count]),
                right: Array(scratchRight[..<count]),
                rms: rms,
                peak: peak
            )
            cont.yield(snapshot)
        }
    }

    /// Remove the tap and finish the sample stream.
    ///
    /// After calling this the stream's `AsyncIterator` will return `nil` on the
    /// next iteration. Create a new `AudioTap` to restart visualization.
    public func remove(from node: AVAudioMixerNode) {
        guard self.isInstalled else { return }
        node.removeTap(onBus: 0)
        self.isInstalled = false
        self.tappedNode = nil
        self.continuation.finish()
    }
}
