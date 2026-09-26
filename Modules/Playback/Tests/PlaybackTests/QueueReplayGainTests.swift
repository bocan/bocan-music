import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - QueueReplayGainTests

/// What the queue hands the engine for ReplayGain (#573): the track row's
/// stored values, read at play time, and whether the track sits in an album
/// span for `.auto` mode.
@Suite("QueueReplayGain - the facts the engine applies (#573)")
struct QueueReplayGainTests {
    private static let format = AudioSourceFormat(
        sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"
    )

    private static func item(album: Int64?, source: PlayableSource? = nil) -> QueueItem {
        QueueItem(
            trackID: 1,
            bookmark: nil,
            fileURL: "/tmp/a.flac",
            duration: 200,
            sourceFormat: self.format,
            albumID: album,
            playableSource: source
        )
    }

    private static func track(trackGain: Double?, albumGain: Double? = nil) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "/tmp/a.flac",
            fileFormat: "flac",
            duration: 200,
            title: "A",
            addedAt: now,
            updatedAt: now
        )
        track.replaygainTrackGain = trackGain
        track.replaygainTrackPeak = trackGain.map { _ in 0.8 }
        track.replaygainAlbumGain = albumGain
        track.replaygainAlbumPeak = albumGain.map { _ in 0.9 }
        return track
    }

    @Test("A library track carries its stored values")
    func libraryTrackFacts() throws {
        let item = Self.item(album: 7)
        let facts = try #require(QueueReplayGain.facts(
            for: item, track: Self.track(trackGain: -4, albumGain: -6), playOrder: [item]
        ))
        #expect(facts.values == TrackGainInfo(
            trackGainDB: -4, trackPeakLinear: 0.8, albumGainDB: -6, albumPeakLinear: 0.9
        ))
        #expect(!facts.isInAlbumContext)
    }

    @Test("A stream, podcast or radio item, or an unread row, plays as it is")
    func remoteItemsHaveNoFacts() throws {
        let track = Self.track(trackGain: -4)
        let url = try #require(URL(string: "https://example.invalid/stream"))
        let remote: [PlayableSource] = [
            .subsonic(serverID: UUID(), songID: "1"),
            .podcast(feedURL: url, episodeGUID: "g"),
            .internetRadio(streamURL: url),
        ]
        for source in remote {
            let item = Self.item(album: 7, source: source)
            #expect(QueueReplayGain.facts(for: item, track: track, playOrder: [item]) == nil, "\(source)")
        }
        let local = Self.item(album: 7)
        #expect(QueueReplayGain.facts(for: local, track: nil, playOrder: [local]) == nil)
    }

    @Test("A track is in an album span when a play-order neighbour shares its album")
    func albumSpan() {
        let a1 = Self.item(album: 1)
        let a2 = Self.item(album: 1)
        let b = Self.item(album: 2)
        let loose = Self.item(album: nil)
        let looseToo = Self.item(album: nil)

        #expect(QueueReplayGain.isInAlbumSpan(a1, playOrder: [a1, a2]))
        #expect(QueueReplayGain.isInAlbumSpan(a2, playOrder: [a1, a2]))
        #expect(QueueReplayGain.isInAlbumSpan(a2, playOrder: [b, a2, a1]))
        #expect(!QueueReplayGain.isInAlbumSpan(b, playOrder: [a1, b, a2]), "a single between two others")
        #expect(!QueueReplayGain.isInAlbumSpan(a1, playOrder: [a1, b, a2]), "same album, not adjacent")
        #expect(!QueueReplayGain.isInAlbumSpan(loose, playOrder: [loose, looseToo]), "no album is no span")
        #expect(!QueueReplayGain.isInAlbumSpan(a1, playOrder: [a2, b]), "not in the queue")
    }

    @Test("The player reads the row at play time, so a later analysis counts")
    func playerReadsFreshRow() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(Self.track(trackGain: nil))
        try await player.addToQueue([id])
        let item = try #require(await player.queue.items.first)

        var analysed = try await repo.fetch(id: id)
        analysed.replaygainTrackGain = -7.5
        analysed.replaygainTrackPeak = 0.7
        try await repo.update(analysed)

        let facts = await player.replayGain(for: item, track: nil)
        #expect(facts?.values.trackGainDB == -7.5)
        #expect(facts?.values.trackPeakLinear == 0.7)
    }
}
