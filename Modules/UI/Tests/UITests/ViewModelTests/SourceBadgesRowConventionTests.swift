import Foundation
import Testing
@testable import UI

// MARK: - SourceBadgesRowConventionTests (ADR-092 slice 2)

/// The row cannot be rendered host-less, so its shape is asserted through the
/// pure function it derives its badges from, and the rest by reading source.
@Suite("Source badges row")
struct SourceBadgesRowConventionTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Codec display names

    @Test(
        "the codec display mapping spells the format, not the decoder's name",
        arguments: [
            ("flac", "FLAC"),
            ("alac", "ALAC"),
            ("aac", "AAC"),
            ("mp3", "MP3"),
            ("pcm", "PCM"),
            ("opus", "Opus"),
            ("vorbis", "Vorbis"),
            ("eac3", "E-AC-3"),
            ("ac3", "AC-3"),
            ("truehd", "TrueHD"),
            ("dsd_lsbf_planar", "DSD"),
            ("dsd_msbf_planar", "DSD"),
            ("wavpack", "WavPack"),
            ("wmapro", "WMA"),
        ]
    )
    func codecDisplayNames(raw: String, expected: String) {
        #expect(SourceBadgeModel.displayName(forCodec: raw) == expected)
    }

    @Test("an unmapped codec shows its own name uppercased")
    func unmappedCodec() {
        #expect(SourceBadgeModel.displayName(forCodec: "qdm2") == "QDM2")
        #expect(SourceBadgeModel.displayName(forCodec: "shorten") == "SHORTEN")
    }

    // MARK: - Which badges the row draws

    @Test("the five facts draw five badges, in order")
    func fullRow() {
        let facts = NowPlayingSourceFacts(
            codec: "flac",
            bitrateKbps: 1411,
            sampleRateHz: 44100,
            bitDepth: 16,
            channelCount: 2
        )
        let badges = SourceBadgeModel.badges(for: facts)
        #expect(badges.map(\.kind) == [.codec, .bitrate, .sampleRate, .bitDepth, .channels])
        #expect(badges.map(\.text) == ["FLAC", "1,411 kbps", "44.1 kHz", "16-bit", "Stereo"])
    }

    @Test("a nil fact draws no badge, so the row shrinks rather than showing a dash")
    func nilFactsAreSkipped() {
        // An MP3: no bit depth, because no lossless container carries one.
        let facts = NowPlayingSourceFacts(
            codec: "mp3",
            bitrateKbps: 320,
            sampleRateHz: 44100,
            channelCount: 2
        )
        #expect(SourceBadgeModel.badges(for: facts).map(\.kind) == [.codec, .bitrate, .sampleRate, .channels])
    }

    @Test("empty facts draw nothing at all")
    func emptyFactsDrawNothing() {
        #expect(SourceBadgeModel.badges(for: NowPlayingSourceFacts()).isEmpty)
        // A profile is not a badge of its own; it rides the codec's hover text.
        #expect(SourceBadgeModel.badges(for: NowPlayingSourceFacts(codecProfile: "HE-AAC")).isEmpty)
    }

    // MARK: - Hover text

    @Test("every badge explains its fact rather than repeating the value")
    func everyBadgeHasHelp() {
        let facts = NowPlayingSourceFacts(
            codec: "eac3",
            bitrateKbps: 640,
            sampleRateHz: 48000,
            bitDepth: 24,
            channelCount: 6
        )
        for badge in SourceBadgeModel.badges(for: facts) {
            #expect(!badge.help.isEmpty, "\(badge.kind.rawValue) has no hover text")
            #expect(badge.help != badge.text, "\(badge.kind.rawValue) hover text repeats the value")
        }
    }

    @Test("the codec hover text carries the profile when the decoder captured one")
    func codecHelpCarriesProfile() throws {
        let withProfile = NowPlayingSourceFacts(
            codec: "eac3",
            codecProfile: "Dolby Digital Plus + Dolby Atmos"
        )
        let plain = NowPlayingSourceFacts(codec: "eac3")
        let withProfileBadge = try #require(SourceBadgeModel.badges(for: withProfile).first)
        let plainBadge = try #require(SourceBadgeModel.badges(for: plain).first)
        #expect(withProfileBadge.help.contains("Dolby Digital Plus + Dolby Atmos"))
        #expect(!plainBadge.help.contains("Dolby"))
    }

    @Test("a surround mix says so on the channels badge")
    func surroundHelp() throws {
        let badges = SourceBadgeModel.badges(for: NowPlayingSourceFacts(channelCount: 6))
        let channels = try #require(badges.first)
        #expect(channels.text == "5.1")
        #expect(channels.help == ChannelLayoutLabel.help(for: 6))
    }

    // MARK: - Source conventions

    @Test("the badge carries hover text and a localized route for it")
    func badgeSourceCarriesHelp() throws {
        let row = try self.source("AppRoot/SourceBadgesRow.swift")
        #expect(row.contains(".help(self.model.help)"))
        #expect(row.contains("L10n.string("), "hover copy must resolve through the module catalog")
        // Increase-contrast drops the fill and thickens the ring.
        #expect(row.contains("self.highContrast ? Color.clear"))
        #expect(row.contains("lineWidth: self.highContrast ? 1.5 : 1"))
    }

    @Test("the strip's info block is top-aligned and hosts the row")
    func stripHostsTheRowAtTheTop() throws {
        let strip = try self.source("AppRoot/NowPlayingStrip.swift")
        #expect(strip.contains("SourceBadgesRow(facts: facts)"))
        #expect(strip.contains("alignment: .topLeading"))
        #expect(strip.contains(".padding(.top, 6)"))
    }
}
