import Foundation
import Testing
@testable import AudioEngine

/// #471: without `LocalizedError`, `localizedDescription` is Foundation's
/// fallback, which reads "(AudioEngine.AudioEngineError error 3.)".
@Suite("AudioEngine error messages")
struct ErrorMessageTests {
    @Test("AudioEngineError carries its reason through localizedDescription")
    func audioEngineError() throws {
        let url = try #require(URL(string: "file:///tmp/track.flac"))
        let cases: [AudioEngineError] = [
            .fileNotFound(url),
            .unsupportedFormat(magic: Data([0x00, 0x01]), url: url),
            .outputDeviceUnavailable,
            .seekOutOfRange(requested: 90, duration: 60),
            .cancelled,
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }
        #expect(AudioEngineError.fileNotFound(url).localizedDescription.contains("track.flac"))
    }
}
