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
    // MARK: - State

    private let graph: EngineGraph
    private let deviceRouter: DeviceRouter
    private var decoder: (any Decoder)?
    private var pump: BufferPump?
    private var _currentTime: TimeInterval = 0
    private var _duration: TimeInterval = 0
    private var _state: PlaybackState = .idle
    private var lastState: PlaybackState?
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?
    private let log = AppLogger.make(.audio)

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

    // MARK: - Init

    public init() {
        self.graph = EngineGraph()
        self.deviceRouter = DeviceRouter()

        var continuation: AsyncStream<PlaybackState>.Continuation?
        self.state = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    // MARK: - Transport conformance

    public func load(_ url: URL) async throws {
        let start = Date()
        self.log.debug("engine.load.start", ["url": url.lastPathComponent])
        self.emit(.loading)

        // Close previous decoder if any.
        if let prev = decoder { await prev.close() }
        self.decoder = nil

        // Stop any running pump/engine.
        await self.pump?.stop()
        self.pump = nil

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

        // Build canonical output format.
        let sampleRate = self.graph.outputSampleRate
        // swiftlint:disable:next force_unwrapping
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        let outputFmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channelLayout: layout
        )

        // Wire up a BufferPump.
        let playerNode = self.graph.playerNode
        let newPump = BufferPump(
            decoder: dec,
            playerNode: playerNode,
            outputFormat: outputFmt
        )
        self.pump = newPump

        let selfCapture = self
        await newPump.start {
            Task { await selfCapture.handleEnded() }
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

    public func stop() async {
        self.log.debug("engine.stop")
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

    private func handleEnded() {
        // The `.dataPlayedBack` callback in BufferPump already means playback finished.
        self.graph.playerNode.stop()
        self.emit(.ended)
        self.log.debug("engine.playback.ended")
    }
}
