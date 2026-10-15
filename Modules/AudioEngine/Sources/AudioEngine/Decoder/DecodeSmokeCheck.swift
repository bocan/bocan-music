@preconcurrency import AVFoundation
import Foundation

// MARK: - DecodeSmokeCheck

/// Decodes whole files through the same route playback uses and reports what
/// came out, with no output device involved.
///
/// The `smoketest` workflow drives this inside the shipped app bundle, so the
/// libraries it exercises are the ones embedded in that bundle (#627). A
/// library that links but fails on its first real call, which a launch check
/// cannot see, fails here.
public enum DecodeSmokeCheck {
    /// What one source produced.
    public struct Outcome: Sendable, Equatable {
        public let source: String
        public let decoder: String
        public let codec: String?
        public let frames: Int
        public let peak: Float
        /// nil when the source decoded to the end with audible samples.
        public let failure: String?

        public var passed: Bool {
            self.failure == nil
        }
    }

    private static let chunkFrames: AVAudioFrameCount = 4096

    /// Decodes each source (a local path, or an `http`/`https` URL) to its end.
    /// A source passes when it opens, decodes at least one frame without an
    /// error and carries a sample that is not zero.
    public static func run(sources: [String]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for source in sources {
            await outcomes.append(self.check(source))
        }
        return outcomes
    }

    private static func check(_ source: String) async -> Outcome {
        let url = source.contains("://") ? URL(string: source) : URL(fileURLWithPath: source)
        guard let url else {
            return Outcome(source: source, decoder: "-", codec: nil, frames: 0, peak: 0, failure: "not a URL or path")
        }
        let decoder: any Decoder
        do {
            decoder = try DecoderFactory.make(for: url)
        } catch {
            let reason = "open failed: \(String(reflecting: error))"
            return Outcome(source: source, decoder: "-", codec: nil, frames: 0, peak: 0, failure: reason)
        }
        let name = String(describing: type(of: decoder))
        let codec = decoder.codec

        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: self.chunkFrames) else {
            await decoder.close()
            return Outcome(source: source, decoder: name, codec: codec, frames: 0, peak: 0, failure: "no buffer")
        }
        var frames = 0
        var peak: Float = 0
        var failure: String?
        do {
            while true {
                let count = try await decoder.read(into: buffer)
                if count == 0 {
                    break
                }
                frames += Int(count)
                peak = max(peak, self.peak(of: buffer, frames: Int(count)))
            }
        } catch {
            failure = "decode failed after \(frames) frames: \(String(reflecting: error))"
        }
        await decoder.close()

        if failure == nil, frames == 0 {
            failure = "decoded no frames"
        } else if failure == nil, peak == 0 {
            failure = "decoded \(frames) frames, all silent"
        }
        return Outcome(source: source, decoder: name, codec: codec, frames: frames, peak: peak, failure: failure)
    }

    private static func peak(of buffer: AVAudioPCMBuffer, frames: Int) -> Float {
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for channel in 0 ..< channels {
                for frame in 0 ..< frames {
                    peak = max(peak, abs(data[channel][frame]))
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0 ..< channels {
                for frame in 0 ..< frames {
                    peak = max(peak, abs(Float(data[channel][frame])) / Float(Int16.max))
                }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0 ..< channels {
                for frame in 0 ..< frames {
                    peak = max(peak, abs(Float(data[channel][frame])) / Float(Int32.max))
                }
            }
        }
        return peak
    }
}
