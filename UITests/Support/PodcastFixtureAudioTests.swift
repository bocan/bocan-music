import XCTest

// MARK: - PodcastFixtureAudioTests

/// Verifies `PodcastFixtureAudio`'s RIFF header is byte-correct before any
/// network code or the decoder gets near it, mirroring `AacFixtureAudioTests`.
final class PodcastFixtureAudioTests: XCTestCase {
    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset ..< offset + 4])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = [UInt8](data[offset ..< offset + 2])
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    func testHeaderDeclaresPCMStereo16Bit44100() {
        let wav = PodcastFixtureAudio.makeWAV(seconds: 1)

        XCTAssertEqual(String(bytes: wav[0 ..< 4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: wav[8 ..< 12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: wav[12 ..< 16], encoding: .ascii), "fmt ")
        XCTAssertEqual(self.readUInt16LE(wav, at: 20), 1, "PCM format code")
        XCTAssertEqual(self.readUInt16LE(wav, at: 22), 2, "stereo channel count")
        XCTAssertEqual(self.readUInt32LE(wav, at: 24), 44100, "sample rate")
        XCTAssertEqual(self.readUInt16LE(wav, at: 34), 16, "bits per sample")
        XCTAssertEqual(String(bytes: wav[36 ..< 40], encoding: .ascii), "data")
    }

    func testDeclaredSizesMatchTheActualBuffer() {
        let wav = PodcastFixtureAudio.makeWAV(seconds: 2)

        let riffSize = self.readUInt32LE(wav, at: 4)
        XCTAssertEqual(Int(riffSize), wav.count - 8, "RIFF chunk size excludes the 8-byte 'RIFF'+size header itself")

        let dataSize = self.readUInt32LE(wav, at: 40)
        XCTAssertEqual(wav.count, 44 + Int(dataSize), "44-byte header plus the declared PCM payload")

        // 2s stereo 16-bit @ 44100 Hz.
        XCTAssertEqual(Int(dataSize), 2 * 44100 * 2 * 2)
    }

    func testLongerDurationProducesProportionallyMoreBytes() {
        let short = PodcastFixtureAudio.makeWAV(seconds: 1)
        let long = PodcastFixtureAudio.makeWAV(seconds: 3)
        XCTAssertEqual(long.count - 44, (short.count - 44) * 3)
    }

    func testDifferentSampleRateIsReflectedInTheHeader() {
        let wav = PodcastFixtureAudio.makeWAV(seconds: 1, sampleRate: 22050)
        XCTAssertEqual(self.readUInt32LE(wav, at: 24), 22050)
    }
}
