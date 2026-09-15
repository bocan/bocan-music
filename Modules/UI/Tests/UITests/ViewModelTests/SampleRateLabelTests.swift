import Foundation
import Testing
@testable import UI

// MARK: - SampleRateLabelTests

/// The shared sample rate text (#524). The tag editor's own formatter
/// returned bare English that the line-based lint could not see; every
/// surface now goes through this one helper, which resolves through the
/// catalog. The English catalog value equals the key, so the assertions
/// hold under SwiftPM (key fallback) and the Xcode build (compiled catalog).
@Suite("SampleRateLabel")
struct SampleRateLabelTests {
    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // UI
    }

    @Test("whole kilohertz drop the decimal", arguments: [
        (48000, "48 kHz"), (96000, "96 kHz"), (192_000, "192 kHz"), (8000, "8 kHz"),
    ])
    func wholeKilohertz(hertz: Int, expected: String) {
        #expect(SampleRateLabel.text(for: hertz) == expected)
    }

    @Test("other rates keep one decimal", arguments: [
        (44100, "44.1 kHz"), (88200, "88.2 kHz"), (352_800, "352.8 kHz"), (176_400, "176.4 kHz"),
    ])
    func fractionalKilohertz(hertz: Int, expected: String) {
        #expect(SampleRateLabel.text(for: hertz) == expected)
    }

    /// Source convention (Modules/UI/CLAUDE.md): the surfaces that show a
    /// sample rate use the shared label and carry no "kHz" literal of their
    /// own, which is how the tag editor's gap slipped past lint.
    @Test(
        "every sample rate surface uses the shared label and builds no kHz text itself",
        arguments: [
            "Sources/UI/Common/TrackInfoPanel.swift",
            "Sources/UI/MetadataEditor/TagEditorSheet+InfoTabs.swift",
            "Sources/UI/Browse/Radio/RadioStationInfoSheet.swift",
            "Sources/UI/Browse/TrackTable+Helpers.swift",
        ]
    )
    func surfacesUseTheSharedLabel(relativePath: String) throws {
        let url = self.moduleRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("SampleRateLabel.text(for:"), "\(relativePath) must use SampleRateLabel")
        #expect(!source.contains("kHz\""), "\(relativePath) builds kHz text itself")
    }
}
