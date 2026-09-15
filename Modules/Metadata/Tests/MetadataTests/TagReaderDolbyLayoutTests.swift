import Foundation
import Testing
@testable import Metadata

// MARK: - TagReaderDolbyLayoutTests

/// E-AC-3 in MP4 (#529). The sample entry carries a legacy `channelcount`
/// that the Dolby spec sets to 2 for compatibility, with the real layout in
/// the `dec3` box. TagLib reads the legacy field, so a 5.1 file scanned as
/// stereo; the reader now takes channels and sample rate from AVFoundation
/// for Dolby codecs in MP4.
@Suite("TagReader Dolby layout in MP4")
struct TagReaderDolbyLayoutTests {
    private let reader = TagReader()

    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw MetadataError.bridgeFailure("Missing fixture: \(name)")
        }
        return url
    }

    /// The fixture's sample entry says 2, as Dolby-encoded files do; the
    /// `dec3` box says 5.1. Before the fix this read as 2 channels.
    @Test("an E-AC-3 in MP4 with the legacy channel count of 2 reads as 5.1")
    func legacyChannelCountReadsAsSurround() throws {
        let tags = try reader.read(from: self.fixtureURL("surround-lsrs-eac3-legacy2-48000.m4a"))
        #expect(tags.channels == 6)
        #expect(tags.sampleRate == 48000)
        // Duration stays TagLib's, which is whole seconds, so a quarter-second
        // fixture reads as zero; only the layout comes from AVFoundation.
    }

    /// An AAC in MP4 keeps TagLib's own count; no AVFoundation open is made
    /// for codecs whose sample entry is honest.
    @Test("an AAC in MP4 keeps TagLib's channel count")
    func aacKeepsTagLibCount() throws {
        let tags = try reader.read(from: self.fixtureURL("sample-aac.m4a"))
        #expect(tags.channels == 2)
        #expect(tags.sampleRate == 44100)
    }
}
