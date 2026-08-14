import Foundation

// MARK: - PodcastFixtureAudio

/// In-memory synthesis of a small stereo 16-bit PCM WAV fixture (phase 34):
/// episode downloads are finite files, not a live stream, so a plain WAV is
/// simplest -- no ICY interleave, no ADTS framing, just a RIFF header
/// FFmpeg/AVFoundation decode natively regardless of the served MIME type.
enum PodcastFixtureAudio {
    /// A quiet sine tone, long enough that a mid-clip seek (for the
    /// resume-across-relaunch journey) lands well short of the natural end.
    static func makeWAV(seconds: Double, frequency: Double = 440, sampleRate: Double = 44100) -> Data {
        let frameCount = Int(seconds * sampleRate)
        let channels = 2
        var samples = [Int16](repeating: 0, count: frameCount * channels)
        for frame in 0 ..< frameCount {
            let t = Double(frame) / sampleRate
            let value = Int16(sin(2 * .pi * frequency * t) * 0.1 * Double(Int16.max))
            samples[frame * channels] = value
            samples[frame * channels + 1] = value
        }

        let bitsPerSample = 16
        let dataSize = samples.count * MemoryLayout<Int16>.size
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var wav = Data()
        wav.append(ascii: "RIFF")
        wav.appendLE(UInt32(36 + dataSize))
        wav.append(ascii: "WAVE")
        wav.append(ascii: "fmt ")
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1)) // PCM
        wav.appendLE(UInt16(channels))
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(byteRate))
        wav.appendLE(UInt16(blockAlign))
        wav.appendLE(UInt16(bitsPerSample))
        wav.append(ascii: "data")
        wav.appendLE(UInt32(dataSize))
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        self.append(contentsOf: string.utf8)
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { self.append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { self.append(contentsOf: $0) }
    }
}
