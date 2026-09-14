import Foundation
import Testing
@testable import UI

// MARK: - ChannelLayoutLabelTests

/// The Channels row in Get Info and the track panel (ADR-091 slice 4).
///
/// The English catalog value is the key for every label here, so these
/// assertions hold whether the catalog is compiled (the Xcode build) or
/// merely copied (SwiftPM, where a lookup falls back to the key).
@Suite("ChannelLayoutLabel")
struct ChannelLayoutLabelTests {
    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // UI
    }

    @Test("the layouts a listener knows get their name", arguments: [
        (1, "Mono"), (2, "Stereo"), (6, "5.1"), (8, "7.1"),
    ])
    func namedLayouts(count: Int, expected: String) {
        #expect(ChannelLayoutLabel.text(for: count) == expected)
    }

    @Test("every other count reads as a count of channels", arguments: [3, 4, 5, 7, 12])
    func countedLayouts(count: Int) {
        #expect(ChannelLayoutLabel.text(for: count) == "\(count) channels")
    }

    @Test("a surround mix's hover text says it plays as stereo without Atmos objects")
    func surroundHelp() {
        let help = ChannelLayoutLabel.help(for: 6)
        #expect(help.contains("stereo"))
        #expect(help.contains("Atmos"))
        #expect(!ChannelLayoutLabel.help(for: 2).contains("Atmos"))
        #expect(!ChannelLayoutLabel.help(for: 1).contains("Atmos"))
    }

    /// Source convention (Modules/UI/CLAUDE.md): the row is gated on a non-nil
    /// channel count, so a track without one shows no row, and both views
    /// draw their label and hover text from the shared helper.
    @Test(
        "both channel rows gate on channelCount and carry the hover text",
        arguments: [
            "Sources/UI/Common/TrackInfoPanel.swift",
            "Sources/UI/MetadataEditor/TagEditorSheet+InfoTabs.swift",
        ]
    )
    func rowsGateOnCountAndCarryHelp(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("if let channels = track.channelCount"), "\(relativePath) must show no row for nil")
        #expect(source.contains("ChannelLayoutLabel.text(for: channels)"), "\(relativePath) must use the shared label")
        #expect(source.contains(".help(ChannelLayoutLabel.help(for: channels))"), "\(relativePath) must carry the hover text")
    }
}
