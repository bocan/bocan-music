import AVFoundation
import Foundation

// MARK: - AacFixtureAudio

/// Synthesizes a short quiet sine tone, in memory, as continuous ADTS-framed
/// AAC — the audio body `E2EStreamServer` (phase 34) loops indefinitely over
/// its fake ICY stream.
///
/// AAC/ADTS, not WAV: `E2ESeeder`'s WAV fixtures work for local files
/// because `AVAudioFile` knows their length up front, but a live radio
/// stream has no fixed length and WAV's header declares one. ADTS frames
/// are self-delimiting (each carries its own sync word and length), which
/// is exactly what FFmpeg's `aac` demuxer needs to resync cleanly no matter
/// where in an infinitely-looping byte stream a client happens to connect —
/// the same property MP3 frames have, but AAC encoding is natively
/// available via `AVAudioConverter` on macOS, unlike MP3 (decode-only here).
enum AacFixtureAudio {
    enum FixtureError: Error {
        case formatUnavailable
        case conversionFailed(underlying: Error?)
    }

    /// `seconds` of a quiet sine at `frequency`, AAC-LC encoded and wrapped
    /// in ADTS headers back-to-back with no gaps — safe to concatenate
    /// copies of the result to loop it, since each frame is independently
    /// self-delimiting.
    static func make(
        seconds: Double = 3,
        frequency: Double = 440,
        sampleRate: Double = 44100
    ) throws -> Data {
        let pcmBuffer = try Self.synthesizeSine(seconds: seconds, frequency: frequency, sampleRate: sampleRate)
        let (aacFormat, converter) = try Self.makeConverter(from: pcmBuffer.format, sampleRate: sampleRate)
        let sampleRateIndex = try Self.adtsSampleRateIndex(for: sampleRate)
        return try Self.encodeToADTS(
            pcmBuffer,
            aacFormat: aacFormat,
            converter: converter,
            sampleRateIndex: sampleRateIndex
        )
    }

    // MARK: - Synthesis

    private static func synthesizeSine(seconds: Double, frequency: Double, sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw FixtureError.formatUnavailable
        }
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw FixtureError.formatUnavailable
        }
        pcmBuffer.frameLength = frameCount
        for frame in 0 ..< Int(frameCount) {
            let t = Double(frame) / sampleRate
            let sample = Float(sin(2 * .pi * frequency * t) * 0.05)
            for channel in 0 ..< 2 {
                pcmBuffer.floatChannelData?[channel][frame] = sample
            }
        }
        return pcmBuffer
    }

    private static func makeConverter(
        from pcmFormat: AVAudioFormat,
        sampleRate: Double
    ) throws -> (AVAudioFormat, AVAudioConverter) {
        var aacDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aacFormat = AVAudioFormat(streamDescription: &aacDescription),
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else {
            throw FixtureError.formatUnavailable
        }
        return (aacFormat, converter)
    }

    /// Feeds the whole PCM buffer to the converter in one go (the input
    /// block returns it once, then signals dry) and drains output packets
    /// in a loop until the converter reports it has nothing left.
    private static func encodeToADTS(
        _ pcmBuffer: AVAudioPCMBuffer,
        aacFormat: AVAudioFormat,
        converter: AVAudioConverter,
        sampleRateIndex: UInt8
    ) throws -> Data {
        var encoded = Data()
        var suppliedInput = false
        while true {
            let outputBuffer = AVAudioCompressedBuffer(
                format: aacFormat,
                packetCapacity: 64,
                maximumPacketSize: converter.maximumOutputPacketSize
            )
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                guard !suppliedInput else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            if let conversionError {
                throw FixtureError.conversionFailed(underlying: conversionError)
            }
            Self.appendADTSFrames(
                from: outputBuffer,
                sampleRateIndex: sampleRateIndex,
                channelConfig: 2,
                into: &encoded
            )
            if status == .endOfStream || status == .inputRanDry || outputBuffer.packetCount == 0 {
                break
            }
        }
        return encoded
    }

    // MARK: - ADTS framing

    private static func appendADTSFrames(
        from buffer: AVAudioCompressedBuffer,
        sampleRateIndex: UInt8,
        channelConfig: UInt8,
        into data: inout Data
    ) {
        guard let descriptions = buffer.packetDescriptions else { return }
        let raw = buffer.data.assumingMemoryBound(to: UInt8.self)
        for index in 0 ..< Int(buffer.packetCount) {
            let description = descriptions[index]
            let payloadLength = Int(description.mDataByteSize)
            let offset = Int(description.mStartOffset)
            data.append(Self.adtsHeader(
                payloadLength: payloadLength,
                sampleRateIndex: sampleRateIndex,
                channelConfig: channelConfig
            ))
            data.append(Data(bytes: raw + offset, count: payloadLength))
        }
    }

    /// The 7-byte ADTS fixed+variable header (no CRC): AAC-LC profile,
    /// `frameLength` = header + payload, buffer fullness reported as
    /// unknown/VBR (all-ones) since this is a live stream, not a file.
    private static func adtsHeader(
        payloadLength: Int,
        sampleRateIndex: UInt8,
        channelConfig: UInt8
    ) -> Data {
        let frameLength = payloadLength + 7
        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF
        header[1] = 0xF1 // MPEG-4, layer 0, protection absent (no CRC)
        header[2] = (1 << 6) | (sampleRateIndex << 2) | (channelConfig >> 2)
        header[3] = ((channelConfig & 0x3) << 6) | UInt8((frameLength >> 11) & 0x3)
        header[4] = UInt8((frameLength >> 3) & 0xFF)
        header[5] = UInt8((frameLength & 0x7) << 5) | 0x1F
        header[6] = 0xFC
        return Data(header)
    }

    /// The ADTS spec's fixed sampling-frequency table; only the rates this
    /// fixture might plausibly use are implemented.
    private static func adtsSampleRateIndex(for sampleRate: Double) throws -> UInt8 {
        let table: [Int: UInt8] = [
            96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5, 24000: 6,
            22050: 7, 16000: 8, 12000: 9, 11025: 10, 8000: 11, 7350: 12,
        ]
        guard let index = table[Int(sampleRate)] else { throw FixtureError.formatUnavailable }
        return index
    }
}
