import Foundation
import Persistence
import Testing
@testable import SyncServer

/// Cross-repo parity: a fixture library that mirrors `manifest-small.json` must
/// produce the same track manifest the Android side expects. Three fields are
/// Mac-derived content hashes vs the fixture's placeholders (`lyricsHash`,
/// `artworkHash`) and cannot byte-match by preimage, so they are normalized to
/// nil on both sides before comparing; every other value must be identical.
@Suite("Manifest parity")
struct ManifestParityTests {
    private func normalized(_ track: ManifestTrack) -> ManifestTrack {
        var copy = track
        copy.lyricsHash = nil
        copy.artworkHash = nil
        return copy
    }

    @Test("built tracks are value-identical to the golden manifest tracks")
    func trackParity() async throws {
        let database = try await Database(location: .inMemory)
        let roots = LibraryRootRepository(database: database)
        let artists = ArtistRepository(database: database)
        let albums = AlbumRepository(database: database)
        let tracks = TrackRepository(database: database)

        _ = try await roots.upsert(LibraryRoot(path: "/Music", bookmark: Data([0x01]), addedAt: 0))
        _ = try await artists.insert(Artist(id: 7, name: "My Bloody Valentine"))
        _ = try await artists.insert(Artist(id: 8, name: "Slowdive"))
        _ = try await albums.insert(Album(id: 55, title: "Loveless", albumArtistID: 7))
        _ = try await albums.insert(Album(id: 56, title: "Souvlaki", albumArtistID: 8))

        let sha101 = String(repeating: "aa01", count: 16)
        let sha102 = String(repeating: "aa02", count: 16)
        let sha103 = String(repeating: "aa03", count: 16)

        let mp3URL = URL(fileURLWithPath: "/Music/Slowdive/Souvlaki/04 Souvlaki Space Station.mp3").absoluteString

        _ = try await tracks.insert(Track(
            id: 101, fileURL: URL(fileURLWithPath: "/Music/My Bloody Valentine/Loveless/01 Only Shallow.flac").absoluteString,
            fileSize: 31_337_000, fileFormat: "flac", duration: 254,
            sampleRate: 44100, bitDepth: 16, bitrate: 987, channelCount: 2, isLossless: true,
            title: "Only Shallow", artistID: 7, albumArtistID: 7, albumID: 55,
            trackNumber: 1, trackTotal: 11, discNumber: 1, discTotal: 1, year: 1991,
            genre: "Shoegaze", composer: "Kevin Shields", bpm: 130,
            replaygainTrackGain: -8.1, replaygainTrackPeak: 0.98, replaygainAlbumGain: -7.9, replaygainAlbumPeak: 0.99,
            rating: 80, loved: true, contentHash: sha101, addedAt: 0, updatedAt: 0
        ))
        _ = try await tracks.insert(Track(
            id: 102, fileURL: URL(fileURLWithPath: "/Music/My Bloody Valentine/Loveless/02 Loomer.flac").absoluteString,
            fileSize: 17_000_000, fileFormat: "flac", duration: 158,
            sampleRate: 44100, bitDepth: 16, bitrate: 941, channelCount: 2, isLossless: true,
            title: "Loomer", artistID: 7, albumArtistID: 7, albumID: 55, trackNumber: 2,
            contentHash: sha102, addedAt: 0, updatedAt: 0
        ))
        _ = try await tracks.insert(Track(
            id: 103, fileURL: mp3URL,
            fileSize: 9_200_000, fileFormat: "mp3", duration: 356,
            sampleRate: 44100, bitrate: 320, channelCount: 2, isLossless: false,
            title: "Souvlaki Space Station", artistID: 8, albumArtistID: 8, albumID: 56,
            trackNumber: 4, trackTotal: 10, discNumber: 1, discTotal: 1, year: 1993, genre: "Shoegaze",
            replaygainTrackGain: -6.2, replaygainTrackPeak: 0.91,
            rating: 60, contentHash: sha103, addedAt: 0, updatedAt: 0
        ))
        _ = try await tracks.insert(Track(
            id: 104, fileURL: URL(fileURLWithPath: "/Music/Slowdive/Souvlaki/04 Souvlaki Space Station.mp3#intro").absoluteString,
            fileFormat: "mp3", duration: 60,
            sampleRate: 44100, bitrate: 320, channelCount: 2, isLossless: false,
            title: "Souvlaki Space Station (Intro)", artistID: 8, albumArtistID: 8, albumID: 56,
            trackNumber: 5, year: 1993, genre: "Shoegaze",
            contentHash: "ignored",
            startOffsetMs: 0, endOffsetMs: 60000, sourceFileURL: mp3URL,
            addedAt: 0, updatedAt: 0
        ))

        let builder = ManifestBuilder(database: database)
        let built = try await builder.build(
            profile: .everything(includePodcasts: false),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )

        let golden = try ManifestDTOTests.loadGolden()
        #expect(built.tracks.count == golden.tracks.count)
        for goldenTrack in golden.tracks {
            let builtTrack = try #require(built.tracks.first { $0.id == goldenTrack.id })
            #expect(self.normalized(builtTrack) == self.normalized(goldenTrack))
        }
    }
}
