import AudioEngine
import Foundation
import Testing
@testable import SyncServer

/// The sync-profile blob's ADR-088 shape: selection plus transcode settings,
/// with backward-compatible decoding of legacy bare-profile blobs.
@Suite("SyncProfileDocument")
struct SyncProfileDocumentTests {
    @Test("a legacy everything blob decodes with original transcode settings")
    func legacyEverythingDecodes() {
        let legacy = Data(#"{"everything":{"includePodcasts":true}}"#.utf8)
        let document = SyncProfileDocument.decode(legacy)
        #expect(document.profile == .everything(includePodcasts: true))
        #expect(document.transcode == .original)
    }

    @Test("a legacy selected blob decodes with original transcode settings")
    func legacySelectedDecodes() {
        let legacy = Data(#"{"selected":{"playlistIds":[3,9],"includePodcasts":false}}"#.utf8)
        let document = SyncProfileDocument.decode(legacy)
        #expect(document.profile == .selected(playlistIds: [3, 9], includePodcasts: false))
        #expect(document.transcode == .original)
    }

    @Test("the new shape round-trips preset and keep toggle")
    func newShapeRoundTrips() throws {
        let original = SyncProfileDocument(
            profile: .selected(playlistIds: [7], includePodcasts: true),
            transcode: TranscodeSettings(preset: .opus192, keepArtifacts: true)
        )
        let decoded = try SyncProfileDocument.decode(original.encoded())
        #expect(decoded == original)
        #expect(decoded.transcode.preset == .opus192)
        #expect(decoded.transcode.keepArtifacts == true)
    }

    @Test("missing transcode key in a keyed blob means original")
    func missingTranscodeKeyMeansOriginal() {
        let keyed = Data(#"{"profile":{"everything":{"includePodcasts":true}}}"#.utf8)
        let document = SyncProfileDocument.decode(keyed)
        #expect(document.transcode == .original)
    }

    @Test("nil and garbage blobs fall back to the default document")
    func fallbackOnBadInput() {
        #expect(SyncProfileDocument.decode(nil) == .default)
        #expect(SyncProfileDocument.decode(Data("not json".utf8)) == .default)
        #expect(SyncProfileDocument.default.transcode == .original)
    }
}
