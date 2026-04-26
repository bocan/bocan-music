@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - EngineGraph

/// Owns and configures the `AVAudioEngine` signal chain.
///
/// Chain:  PlayerNode → DSPChain (TimePitch → GainStage → EQ → BassBoost → Crossfeed → StereoExpander → Limiter) → Mixer → Output
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
    /// The full DSP processing chain (Phase 9).
    public let dsp: DSPChain
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
        self.dsp = DSPChain()
        self.mixer = self.engine.mainMixerNode // already attached by AVAudioEngine

        // Attach nodes.
        self.engine.attach(self.playerNode)
        self.dsp.attach(to: self.engine)

        // Initial connect with nil format — AVAudioEngine will choose the hardware format.
        self.dsp.connect(
            format: nil,
            engine: self.engine,
            from: self.playerNode,
            to: self.mixer
        )

        // AVAudioEngine can stop itself when the hardware configuration changes
        // (device plug/unplug, sample-rate change, etc.). Reset isRunning so the
        // next call to start() doesn't skip the restart.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.engine,
            queue: nil
        ) { [weak self] _ in
            self?.isRunning = false
            self?.log.debug("engine.configChange")
        }
    }

    // MARK: - Public API

    /// Prepare and start the engine.
    public func start() throws {
        guard !self.engine.isRunning else { return }
        // Sync local flag — could have been stopped externally (interruption / device change).
        self.isRunning = false

        // Reconnect the entire signal chain with the confirmed hardware rate.
        // With format:nil AVAudioEngine can cache a stale rate from a prior run
        // (e.g. 44100 Hz) even when the device is now at a different rate
        // (e.g. 48000 Hz). Scheduling 48000 Hz buffers onto a 44100 Hz node plays
        // them at 44100/48000× speed — audibly slower/lower-pitched.
        // outputNode.outputFormat is provided by the system device driver and is valid
        // before prepare(); graph modifications must not happen after prepare().
        let hwRate = self.engine.outputNode.outputFormat(forBus: 0).sampleRate
        if hwRate > 0 {
            // swiftlint:disable:next force_unwrapping
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
            let fmt = AVAudioFormat(standardFormatWithSampleRate: hwRate, channelLayout: layout)
            self.dsp.disconnect(engine: self.engine, playerNode: self.playerNode)
            self.dsp.connect(
                format: fmt,
                engine: self.engine,
                from: self.playerNode,
                to: self.mixer
            )
        }

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
