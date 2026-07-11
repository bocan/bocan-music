import Foundation
import Testing
@testable import SyncServer

@Suite("Manifest DTOs")
struct ManifestDTOTests {
    static func loadGolden() throws -> Manifest {
        let url = try #require(
            Bundle.module.url(forResource: "manifest-small", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    @Test("the golden manifest decodes, ignoring unknown fields")
    func decodesGolden() throws {
        let manifest = try Self.loadGolden()
        #expect(manifest.protocolVersion == 1)
        #expect(manifest.serverId == "5f2c9a2e-0b1f-4a5e-9c3d-7e8f6a1b2c3d")
        #expect(manifest.generation == 42)
        #expect(manifest.tracks.count == 4)
        #expect(manifest.playlists.count == 3)
        #expect(manifest.podcasts.count == 1)
        #expect(manifest.episodes.count == 2)
    }

    @Test("track fields, including a clip and replay gain, decode correctly")
    func trackFields() throws {
        let tracks = try Self.loadGolden().tracks
        let first = try #require(tracks.first { $0.id == 101 })
        #expect(first.relPath == "My Bloody Valentine/Loveless/01 Only Shallow.flac")
        #expect(first.durationMs == 254_000)
        #expect(first.bpm == 130)
        #expect(first.replayGain?.trackGain == -8.1)
        #expect(first.replayGain?.albumPeak == 0.99)
        #expect(first.clip == nil)

        let clip = try #require(tracks.first { $0.id == 104 })
        #expect(clip.clip == ManifestClip(sourceTrackId: 103, startMs: 0, endMs: 60000))
        #expect(clip.replayGain == nil)
    }

    @Test("playlist kinds, a folder, and an episode id decode correctly")
    func playlistAndEpisode() throws {
        let manifest = try Self.loadGolden()
        let folder = try #require(manifest.playlists.first { $0.id == 1 })
        #expect(folder.kind == "folder")
        #expect(folder.trackIds.isEmpty)
        let smart = try #require(manifest.playlists.first { $0.id == 3 })
        #expect(smart.kind == "smart")
        #expect(smart.trackIds == [101, 102, 104])

        let episode = try #require(manifest.episodes.first { $0.playState == "inProgress" })
        #expect(episode.id == "e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6")
        #expect(episode.playPositionMs == 1_200_000)
        #expect(episode.relPath == "Podcasts/4/e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6.mp3")
    }
}
