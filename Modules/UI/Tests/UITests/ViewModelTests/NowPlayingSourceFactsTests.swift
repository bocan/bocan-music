import AudioEngine
import Foundation
import Playback
import Testing
@testable import Persistence
@testable import UI

// MARK: - NowPlayingSourceFactsTests (ADR-092 slice 1)

@Suite("Now-playing source facts")
struct NowPlayingSourceFactsTests {
    private func makeTrack(
        format: String = "flac",
        bitrate: Int? = 1411,
        sampleRate: Int? = 44100,
        bitDepth: Int? = 16,
        channels: Int? = 2
    ) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/badge.\(format)",
            fileSize: 4096,
            fileMtime: now,
            fileFormat: format,
            duration: 180,
            title: "Fascination Street",
            addedAt: now,
            updatedAt: now
        )
        track.bitrate = bitrate
        track.sampleRate = sampleRate
        track.bitDepth = bitDepth
        track.channelCount = channels
        return track
    }

    private func makeDetails(
        codec: String? = "opus",
        profile: String? = nil,
        rate: Int = 48000,
        channels: Int = 2,
        bitrate: Int? = 128
    ) -> StreamDetails {
        StreamDetails(
            container: "ogg",
            codec: codec,
            codecProfile: profile,
            sampleRateHz: rate,
            channelCount: channels,
            claimedBitrateKbps: bitrate
        )
    }

    // MARK: - From a track

    @Test("a track brings its scanned columns, and no codec")
    func fromTrack() {
        let facts = NowPlayingSourceFacts(track: self.makeTrack())
        #expect(facts.bitrateKbps == 1411)
        #expect(facts.sampleRateHz == 44100)
        #expect(facts.bitDepth == 16)
        #expect(facts.channelCount == 2)
        // The extension is not the codec: an .m4a holds AAC, ALAC or E-AC-3
        // alike, so only the decoder may name it (#529).
        #expect(facts.codec == nil)
        #expect(!facts.isEmpty)
    }

    @Test("a track with nothing scanned has nothing to show")
    func emptyTrack() {
        let track = self.makeTrack(bitrate: nil, sampleRate: nil, bitDepth: nil, channels: nil)
        #expect(NowPlayingSourceFacts(track: track).isEmpty)
        #expect(NowPlayingSourceFacts().isEmpty)
    }

    // MARK: - From the decoder

    @Test("stream details bring everything but the bit depth")
    func fromDetails() {
        let facts = NowPlayingSourceFacts(details: self.makeDetails(), codec: "opus")
        #expect(facts.codec == "opus")
        #expect(facts.sampleRateHz == 48000)
        #expect(facts.channelCount == 2)
        #expect(facts.bitrateKbps == 128)
        #expect(facts.bitDepth == nil, "no decoder reports bit depth")
    }

    @Test("a local file reports only its codec")
    func localFileCodecOnly() {
        let facts = NowPlayingSourceFacts(details: nil, codec: "flac")
        #expect(facts.codec == "flac")
        #expect(facts.sampleRateHz == nil)
        #expect(facts.channelCount == nil)
        #expect(!facts.isEmpty)
    }

    @Test("a zero rate or channel count is FFmpeg saying it does not know")
    func zeroesAreUnknown() {
        let facts = NowPlayingSourceFacts(
            details: self.makeDetails(rate: 0, channels: 0, bitrate: nil),
            codec: nil
        )
        #expect(facts.sampleRateHz == nil)
        #expect(facts.channelCount == nil)
        #expect(facts.codec == "opus", "the details still name the codec")
    }

    // MARK: - Merging

    @Test("the live fact wins, the column fills the rest")
    func liveWins() {
        let track = NowPlayingSourceFacts(track: self.makeTrack(sampleRate: 44100, bitDepth: 24))
        let live = NowPlayingSourceFacts(
            details: self.makeDetails(codec: "eac3", profile: "Dolby Digital Plus", rate: 48000, channels: 6),
            codec: "eac3"
        )
        let merged = track.merging(live)
        #expect(merged.codec == "eac3")
        #expect(merged.codecProfile == "Dolby Digital Plus")
        #expect(merged.sampleRateHz == 48000, "the decoder is looking at the bytes")
        #expect(merged.channelCount == 6)
        #expect(merged.bitDepth == 24, "only the track has it")
    }

    @Test("a silent decoder leaves every column alone")
    func silentLiveKeepsColumns() {
        let track = NowPlayingSourceFacts(track: self.makeTrack())
        let merged = track.merging(NowPlayingSourceFacts())
        #expect(merged == track)
    }

    @Test("merging nothing with nothing is still nothing")
    func emptyMerge() {
        #expect(NowPlayingSourceFacts().merging(NowPlayingSourceFacts()).isEmpty)
    }

    @Test("a profile alone is not worth a badge")
    func profileAloneIsEmpty() {
        let facts = NowPlayingSourceFacts(codecProfile: "HE-AAC")
        #expect(facts.isEmpty)
    }
}

// MARK: - The view model's copy

/// `MockTransport` lives in `NowPlayingViewModelTests` and names nothing:
/// both its decoder facts default to nil, which is exactly the state the
/// badges must survive.
@Suite("Now-playing source facts in the view model")
@MainActor
struct NowPlayingSourceFactsViewModelTests {
    /// A FLAC with every column the scanner writes.
    private static func scannedTrack() -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/badges.flac",
            fileSize: 4096,
            fileMtime: now,
            fileFormat: "flac",
            duration: 240,
            title: "Plainsong",
            addedAt: now,
            updatedAt: now
        )
        track.bitrate = 1411
        track.sampleRate = 44100
        track.bitDepth = 16
        track.channelCount = 2
        return track
    }

    @Test("setCurrentTrack seeds the badges from the track's columns")
    func setCurrentTrackSeeds() async throws {
        let engine = MockTransport()
        let db = try await Database(location: .inMemory)
        let vm = NowPlayingViewModel(engine: engine, database: db)

        vm.setCurrentTrack(Self.scannedTrack())
        let facts = try #require(vm.sourceFacts)
        #expect(facts.bitrateKbps == 1411)
        #expect(facts.sampleRateHz == 44100)
        #expect(facts.bitDepth == 16)
        #expect(facts.channelCount == 2)
        #expect(facts.codec == nil, "a transport with no decoder cannot name it")
    }

    @Test("a track with no scanned columns shows no badges")
    func unscannedTrackShowsNothing() async throws {
        let engine = MockTransport()
        let db = try await Database(location: .inMemory)
        let vm = NowPlayingViewModel(engine: engine, database: db)

        let now = Int64(Date().timeIntervalSince1970)
        vm.setCurrentTrack(
            Track(
                fileURL: "file:///tmp/bare.flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 10,
                title: "Bare",
                addedAt: now,
                updatedAt: now
            )
        )
        #expect(vm.sourceFacts == nil)
    }

    @Test("a silent transport at .ready leaves the track's columns standing")
    func readyWithoutDecoderKeepsColumns() async throws {
        let engine = MockTransport()
        let db = try await Database(location: .inMemory)
        let vm = NowPlayingViewModel(engine: engine, database: db)

        vm.setCurrentTrack(Self.scannedTrack())
        engine.emit(.ready)
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        let facts = try #require(vm.sourceFacts, "a nil codec must not wipe the columns")
        #expect(facts.sampleRateHz == 44100)
        #expect(facts.bitDepth == 16)
    }

    @Test("stopping the queue clears the badges")
    func stopClearsTheBadges() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()
        let vm = NowPlayingViewModel(engine: player, database: db)

        vm.setCurrentTrack(Self.scannedTrack())
        try #require(vm.sourceFacts != nil)

        // stop() emits a nil current track against an empty queue, which is
        // the display-clearing path. The engine keeps its last decoder, so a
        // cleared display must not ask it for facts.
        await player.stop()
        let deadline = Date().addingTimeInterval(5)
        while vm.sourceFacts != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(vm.sourceFacts == nil)
    }
}
