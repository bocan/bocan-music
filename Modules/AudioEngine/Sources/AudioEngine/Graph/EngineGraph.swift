import AVFoundation
import Foundation
import Observability

// MARK: - EngineGraph

/// Owns and configures the `AVAudioEngine` signal chain.
///
/// Chain:  PlayerNode → EQ (bypass) → Mixer → Output
///
/// The canonical internal format is:
/// - `Float32`, non-interleaved, stereo
/// - Sample rate: output device's native rate (queried on `prepare()`; updated on device change)
///
/// Thread-safety: all mutations are serialised by the owning `AudioEngine` actor.
/// `@unchecked Sendable`: AVFoundation node types are not annotated Sendable;
/// safety is guaranteed because only `AudioEngine` ever mutates this object.
public final class EngineGraph: @unchecked Sendable {
    // Remove @unchecked once AVFoundation adopts Sendable annotations (FB13119463).
    // MARK: - Properties

    public let engine: AVAudioEngine
    public let playerNode: AVAudioPlayerNode
    let eq: AVAudioUnitEQ // Bypass for now; Phase 9 will activate it.
    let mixer: AVAudioMixerNode

    private let log = AppLogger.make(.audio)
    private var isRunning = false

    // MARK: - Computed properties

    /// The output sample rate as reported by the hardware (after `prepare()`).
    public var outputSampleRate: Double {
        self.engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Init

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        self.eq = AVAudioUnitEQ() // 0 bands = clipping protection placeholder
        self.mixer = self.engine.mainMixerNode // already attached by AVAudioEngine

        // Attach nodes.
        self.engine.attach(self.playerNode)
        self.engine.attach(self.eq)

        // Connect: playerNode → eq → mainMixer → output
        // Format is nil so AVAudioEngine chooses the hardware format automatically.
        self.engine.connect(self.playerNode, to: self.eq, format: nil)
        self.engine.connect(self.eq, to: self.mixer, format: nil)
    }

    // MARK: - Public API

    /// Prepare and start the engine.
    public func start() throws {
        guard !self.isRunning else { return }
        self.engine.prepare()
        do {
            try self.engine.start()
            self.isRunning = true
            self.log.debug("engine.started", ["sampleRate": self.outputSampleRate])
        } catch {
            throw AudioEngineError.engineStartFailed(underlying: error)
        }
    }

    /// Stop the engine without tearing down the graph.
    public func stop() {
        guard self.isRunning else { return }
        self.engine.stop()
        self.isRunning = false
        self.log.debug("engine.stopped")
    }

    /// Reset the engine graph for reuse (e.g. after a device change).
    public func reset() {
        self.engine.reset()
        self.isRunning = false
        self.log.debug("engine.reset")
    }
}
