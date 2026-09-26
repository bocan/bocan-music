import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// ADR-095, "Which boundaries crossfade". The six conditions split three ways:
// the setting, the album rule, local files and the overlap length are the
// pure `CrossfadeScheduler.crossfadeSeconds`; a next item and
// stop-after-current are `QueuePlayer.resolveNextBoundary`; a natural end is
// structural (a manual skip resets the gapless scheduler, which disarms the
// engine), so it has no row here.

private func item(
    _ trackID: Int64,
    albumID: Int64? = nil,
    duration: TimeInterval = 200,
    sampleRate: Double = 44100,
    source: PlayableSource? = nil
) -> QueueItem {
    QueueItem(
        trackID: trackID,
        bookmark: nil,
        fileURL: "/tmp/decision\(trackID).flac",
        duration: duration,
        sourceFormat: AudioSourceFormat(
            sampleRate: sampleRate, bitDepth: 16, channelCount: 2,
            isInterleaved: false, codec: "flac"
        ),
        albumID: albumID,
        playableSource: source
    )
}

/// The out-of-the-box toggles with the slider moved to 6 s.
private let defaultsWithSlider = CrossfadeScheduler.Config(durationSeconds: 6, albumGapless: true)

// MARK: - Pure decision

@Suite("Crossfade boundary decision")
struct CrossfadeDecisionTests {
    @Test("default toggles with the slider on: albums that differ crossfade")
    func defaultSettingsCrossfade() {
        let seconds = CrossfadeScheduler.crossfadeSeconds(
            defaultsWithSlider, from: item(1, albumID: 1), to: item(2, albumID: 2)
        )
        #expect(seconds == 6)
    }

    @Test("a setting of 0 never crossfades")
    func zeroSetting() {
        let config = CrossfadeScheduler.Config(durationSeconds: 0, albumGapless: false)
        #expect(CrossfadeScheduler.crossfadeSeconds(config, from: item(1, albumID: 1), to: item(2, albumID: 2)) == nil)
    }

    @Test("keep-gapless-within-albums keeps a same-album boundary gapless")
    func sameAlbumKeepsGapless() {
        let seconds = CrossfadeScheduler.crossfadeSeconds(
            defaultsWithSlider, from: item(1, albumID: 7), to: item(2, albumID: 7)
        )
        #expect(seconds == nil)
    }

    @Test("with keep-gapless off, a same-album boundary crossfades")
    func sameAlbumWithToggleOff() {
        let config = CrossfadeScheduler.Config(durationSeconds: 6, albumGapless: false)
        #expect(CrossfadeScheduler.crossfadeSeconds(config, from: item(1, albumID: 7), to: item(2, albumID: 7)) == 6)
    }

    @Test("an unknown album on either side crossfades")
    func unknownAlbum() {
        #expect(CrossfadeScheduler.crossfadeSeconds(defaultsWithSlider, from: item(1), to: item(2, albumID: 2)) == 6)
        #expect(CrossfadeScheduler.crossfadeSeconds(defaultsWithSlider, from: item(1, albumID: 1), to: item(2)) == 6)
    }

    @Test(
        "a stream on either side does not crossfade",
        arguments: [
            PlayableSource.subsonic(serverID: UUID(), songID: "s1"),
            .internetRadio(streamURL: URL(fileURLWithPath: "/radio")),
            .podcast(feedURL: URL(fileURLWithPath: "/feed"), episodeGUID: "e1"),
        ]
    )
    func streamsDoNotCrossfade(source: PlayableSource) {
        let local = item(1, albumID: 1)
        let remote = item(2, albumID: 2, source: source)
        #expect(CrossfadeScheduler.crossfadeSeconds(defaultsWithSlider, from: local, to: remote) == nil)
        #expect(CrossfadeScheduler.crossfadeSeconds(defaultsWithSlider, from: remote, to: local) == nil)
    }

    @Test("no current item does not crossfade")
    func noCurrentItem() {
        #expect(CrossfadeScheduler.crossfadeSeconds(defaultsWithSlider, from: nil, to: item(2, albumID: 2)) == nil)
    }

    /// `L = min(D, A / 2, B / 2)` must be at least 1 s. A 2 s track gives
    /// exactly 1 s, which still mixes; anything shorter is gapless.
    @Test(
        "the overlap-length rule",
        arguments: [
            (200.0, 200.0, true),
            (2.0, 200.0, true),
            (200.0, 2.0, true),
            (1.9, 200.0, false),
            (200.0, 1.9, false),
            (0.0, 200.0, false),
            (Double.infinity, 200.0, false),
            (200.0, Double.nan, false),
        ]
    )
    func overlapLength(outgoing: Double, incoming: Double, crossfades: Bool) {
        let seconds = CrossfadeScheduler.crossfadeSeconds(
            defaultsWithSlider,
            from: item(1, albumID: 1, duration: outgoing),
            to: item(2, albumID: 2, duration: incoming)
        )
        // The full setting, not the shortened overlap: the engine shortens it.
        #expect(seconds == (crossfades ? 6 : nil))
    }

    @Test("a non-finite setting does not crossfade")
    func nonFiniteSetting() {
        for value in [Double.nan, .infinity] {
            let config = CrossfadeScheduler.Config(durationSeconds: value, albumGapless: false)
            #expect(CrossfadeScheduler.crossfadeSeconds(config, from: item(1), to: item(2)) == nil)
        }
    }
}

// MARK: - Arming window

@Suite("GaplessScheduler arming window")
struct ArmingWindowTests {
    @Test(
        "max(preroll, crossfade + 2 s), or the preroll without a crossfade",
        arguments: [
            (1.0, 0.0, 1.0), (5.0, 0.0, 5.0), (15.0, 0.0, 15.0),
            (1.0, 3.0, 5.0), (5.0, 3.0, 5.0), (15.0, 3.0, 15.0),
            (1.0, 10.0, 12.0), (5.0, 10.0, 12.0), (15.0, 10.0, 15.0),
        ]
    )
    func table(preroll: Double, crossfade: Double, expected: Double) {
        #expect(GaplessScheduler.armingWindow(preroll: preroll, crossfadeSeconds: crossfade) == expected)
    }

    /// The #271 concern, moved here with the fade-out delay it applied to:
    /// a corrupt or live-stream value must never make the window non-finite.
    @Test(
        "always finite and never negative",
        arguments: [
            (Double.nan, 3.0), (.infinity, 3.0), (-.infinity, 3.0), (-4.0, 0.0),
            (5.0, .nan), (5.0, .infinity), (5.0, -.infinity), (5.0, -3.0),
            (.nan, .nan), (.infinity, .infinity), (1e300, 1e300),
        ]
    )
    func finite(preroll: Double, crossfade: Double) {
        let window = GaplessScheduler.armingWindow(preroll: preroll, crossfadeSeconds: crossfade)
        #expect(window.isFinite)
        #expect(window >= 0)
    }

    @Test("a non-finite crossfade counts as none")
    func nonFiniteCrossfadeIsPreroll() {
        #expect(GaplessScheduler.armingWindow(preroll: 5, crossfadeSeconds: .nan) == 5)
        #expect(GaplessScheduler.armingWindow(preroll: 5, crossfadeSeconds: .infinity) == 5)
    }
}

// MARK: - QueuePlayer boundary

@Suite("QueuePlayer boundary resolution")
struct QueuePlayerBoundaryTests {
    private func makePlayer(_ items: [QueueItem], config: CrossfadeScheduler.Config) async throws -> QueuePlayer {
        let player = try await QueuePlayer(engine: AudioEngine(), database: Database(location: .inMemory))
        await player.queue.replace(with: items, startAt: 0)
        await player.setCrossfadeConfig(config)
        return player
    }

    @Test("default toggles: a cross-album boundary crossfades, even across sample rates")
    func crossAlbumCrossfades() async throws {
        let player = try await self.makePlayer(
            [item(1, albumID: 1), item(2, albumID: 2, sampleRate: 48000)],
            config: defaultsWithSlider
        )
        let boundary = try #require(await player.resolveNextBoundary())
        #expect(boundary.item.trackID == 2)
        #expect(boundary.transition == .crossfade(seconds: 6))
    }

    @Test("a same-album boundary follows the gapless rules")
    func sameAlbumIsGapless() async throws {
        let player = try await self.makePlayer(
            [item(1, albumID: 7), item(2, albumID: 7)],
            config: defaultsWithSlider
        )
        let boundary = try #require(await player.resolveNextBoundary())
        // Album 7 is not in the database, so its force-gapless flag reads false.
        #expect(boundary.transition == .gapless(forceGapless: false))
    }

    @Test("no next item arms nothing")
    func noNextItem() async throws {
        let player = try await self.makePlayer([item(1, albumID: 1)], config: defaultsWithSlider)
        #expect(await player.resolveNextBoundary() == nil)
    }

    @Test("stop-after-current arms nothing, even for a crossfade")
    func stopAfterCurrent() async throws {
        let player = try await self.makePlayer(
            [item(1, albumID: 1), item(2, albumID: 2)],
            config: defaultsWithSlider
        )
        await player.queue.setStopAfterCurrent(true)
        #expect(await player.resolveNextBoundary() == nil)
    }
}
