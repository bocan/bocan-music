import XCTest

// MARK: - AacFixtureAudioTests

/// Verifies `AacFixtureAudio`'s output is self-consistent ADTS *before* any
/// network code or FFmpeg gets near it: walks every frame via its own
/// declared length, checking the sync word and that the frames tile the
/// buffer exactly with nothing left over. A wrong length byte here would
/// otherwise surface as a silent, hard-to-diagnose FFmpeg decode failure
/// three layers away (E2EStreamServer -> AudioEngine -> the journey test).
final class AacFixtureAudioTests: XCTestCase {
    private struct ParsedFrame {
        let payloadLength: Int
        let sampleRateIndex: UInt8
        let channelConfig: UInt8
    }

    /// Parses one ADTS frame at `offset`, returning it and the offset of the
    /// next frame. Fails the test (rather than throwing) so every call site
    /// stays a plain assertion.
    private func parseFrame(_ data: Data, at offset: Int) -> (ParsedFrame, nextOffset: Int)? {
        let bytes = [UInt8](data)
        guard offset + 7 <= bytes.count else {
            XCTFail("truncated ADTS header at offset \(offset)")
            return nil
        }
        guard bytes[offset] == 0xFF, bytes[offset + 1] == 0xF1 else {
            XCTFail("bad ADTS sync word at offset \(offset): \(bytes[offset]) \(bytes[offset + 1])")
            return nil
        }
        let sampleRateIndex = (bytes[offset + 2] >> 2) & 0xF
        let channelConfig = ((bytes[offset + 2] & 0x1) << 2) | (bytes[offset + 3] >> 6)
        let frameLength = (Int(bytes[offset + 3] & 0x3) << 11)
            | (Int(bytes[offset + 4]) << 3)
            | Int(bytes[offset + 5] >> 5)
        guard frameLength > 7, offset + frameLength <= bytes.count else {
            XCTFail("ADTS frameLength \(frameLength) at offset \(offset) overruns the buffer")
            return nil
        }
        let frame = ParsedFrame(
            payloadLength: frameLength - 7,
            sampleRateIndex: sampleRateIndex,
            channelConfig: channelConfig
        )
        return (frame, offset + frameLength)
    }

    func testOutputIsAWholeNumberOfBackToBackADTSFrames() throws {
        let data = try AacFixtureAudio.make(seconds: 1, sampleRate: 44100)
        XCTAssertFalse(data.isEmpty)

        var offset = 0
        var frameCount = 0
        while offset < data.count {
            guard let (frame, next) = self.parseFrame(data, at: offset) else { return }
            XCTAssertEqual(frame.sampleRateIndex, 4, "44100 Hz must map to ADTS table index 4")
            XCTAssertEqual(frame.channelConfig, 2, "stereo must map to ADTS channel config 2")
            XCTAssertGreaterThan(frame.payloadLength, 0)
            offset = next
            frameCount += 1
        }

        XCTAssertEqual(offset, data.count, "frames must tile the buffer exactly, no trailing bytes")
        // ~1024 samples/AAC frame @ 44100 Hz over 1 second is roughly 43 frames;
        // a wide band avoids coupling this test to the encoder's exact packet count.
        XCTAssertGreaterThan(frameCount, 20)
        XCTAssertLessThan(frameCount, 80)
    }

    func testLongerDurationProducesProportionallyMoreFrames() throws {
        let short = try AacFixtureAudio.make(seconds: 1, sampleRate: 44100)
        let long = try AacFixtureAudio.make(seconds: 3, sampleRate: 44100)
        XCTAssertGreaterThan(long.count, short.count * 2)
    }

    func testDifferentSampleRateEncodesADifferentTableIndex() throws {
        let data = try AacFixtureAudio.make(seconds: 1, sampleRate: 22050)
        guard let (frame, _) = self.parseFrame(data, at: 0) else { return }
        XCTAssertEqual(frame.sampleRateIndex, 7, "22050 Hz must map to ADTS table index 7")
    }

    func testTwoIndependentEncodesCanBeConcatenatedAndStillParseCleanly() throws {
        // The whole point of ADTS framing here: looping the fixture is just
        // concatenation, since each frame re-syncs independently.
        let one = try AacFixtureAudio.make(seconds: 1, sampleRate: 44100)
        var looped = one
        looped.append(one)

        var offset = 0
        while offset < looped.count {
            guard let (_, next) = self.parseFrame(looped, at: offset) else { return }
            offset = next
        }
        XCTAssertEqual(offset, looped.count)
    }
}
