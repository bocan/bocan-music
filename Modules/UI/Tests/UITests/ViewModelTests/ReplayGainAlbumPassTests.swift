import AudioEngine
import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - ReplayGainAlbumPassTests

/// #579: the ReplayGain batch measured only track gain, so Album and Auto
/// modes fell back to track gain on every album without ReplayGain tags.
@Suite("ReplayGainAlbumPass - album gain from the album's track gains (#579)")
struct ReplayGainAlbumPassTests {
    private static func track(id: Int64, album: Int64?, gain: Double?, peak: Double?) -> Track {
        var track = Track(
            fileURL: "/tmp/\(id).flac",
            fileFormat: "flac",
            duration: 200,
            addedAt: 0,
            updatedAt: 0
        )
        track.id = id
        track.albumID = album
        track.replaygainTrackGain = gain
        track.replaygainTrackPeak = peak
        return track
    }

    /// The ReplayGain 2.0 album gain for tracks of these gains: the power
    /// mean of their loudness, taken back to a gain.
    private static func expectedAlbumGain(_ gains: [Double]) -> Double {
        let powers = gains.map { pow(10.0, (-18.0 - $0) / 10.0) }
        let loudness = 10.0 * log10(powers.reduce(0, +) / Double(gains.count))
        return -18.0 - loudness
    }

    @Test("Every track of a measured album gets the album's gain and its loudest peak")
    func albumGainOnEveryTrack() throws {
        let tracks = [
            Self.track(id: 1, album: 7, gain: -6, peak: 0.8),
            Self.track(id: 2, album: 7, gain: -9, peak: 0.95),
        ]

        let updated = ReplayGainAlbumPass.albumUpdates(tracks)

        #expect(updated.count == 2)
        let expected = Self.expectedAlbumGain([-6, -9])
        for track in updated {
            let gain = try #require(track.replaygainAlbumGain)
            #expect(abs(gain - expected) < 1e-9)
            #expect(track.replaygainAlbumPeak == 0.95)
        }
        // A power mean, not an average: the louder track weighs more.
        #expect(expected < -7.5)
    }

    @Test("An album with a track not yet measured gets no album gain")
    func incompleteAlbumSkipped() {
        let tracks = [
            Self.track(id: 1, album: 7, gain: -6, peak: 0.8),
            Self.track(id: 2, album: 7, gain: nil, peak: nil),
        ]
        #expect(ReplayGainAlbumPass.albumUpdates(tracks).isEmpty)
    }

    @Test("A track without a peak leaves the album peak empty, the gain still set")
    func missingPeakLeavesAlbumPeakEmpty() {
        let tracks = [
            Self.track(id: 1, album: 7, gain: -6, peak: 0.8),
            Self.track(id: 2, album: 7, gain: -9, peak: nil),
        ]

        let updated = ReplayGainAlbumPass.albumUpdates(tracks)

        #expect(updated.count == 2)
        let gainWithoutPeak = updated.allSatisfy { $0.replaygainAlbumGain != nil && $0.replaygainAlbumPeak == nil }
        #expect(gainWithoutPeak)
    }

    @Test("Tracks without an album are left alone, and each album is computed on its own")
    func albumsAreSeparate() throws {
        let tracks = [
            Self.track(id: 1, album: nil, gain: -6, peak: 0.8),
            Self.track(id: 2, album: 7, gain: -3, peak: 0.5),
            Self.track(id: 3, album: 8, gain: -10, peak: 0.9),
        ]

        let updated = Dictionary(uniqueKeysWithValues: ReplayGainAlbumPass.albumUpdates(tracks).map { ($0.id, $0) })

        #expect(updated[1] == nil)
        let seven = try #require(updated[2]?.replaygainAlbumGain)
        let eight = try #require(updated[3]?.replaygainAlbumGain)
        #expect(abs(seven - -3) < 1e-9, "one track: album gain is its gain")
        #expect(abs(eight - -10) < 1e-9)
    }

    @Test("Tracks whose album gain is already right are not rewritten")
    func unchangedNotReturned() {
        var first = Self.track(id: 1, album: 7, gain: -4, peak: 0.7)
        first.replaygainAlbumGain = -4
        first.replaygainAlbumPeak = 0.7
        #expect(ReplayGainAlbumPass.albumUpdates([first]).isEmpty)
    }

    @Test("run stores the album gain, counting a track measured in an earlier batch")
    func runStoresAlbumGain() async throws {
        let db = try await Database(location: .inMemory)
        let albums = AlbumRepository(database: db)
        let repo = TrackRepository(database: db)
        let albumID = try await albums.insert(Album(title: "Measured"))
        let otherAlbum = try await albums.insert(Album(title: "Untouched"))
        var ids: [Int64] = []
        for (index, gain) in [-6.0, -9.0].enumerated() {
            // The id only names the file; the database assigns the row id.
            var track = Self.track(id: Int64(index + 1), album: albumID, gain: gain, peak: 0.5 + Double(index) / 10)
            track.id = nil
            try await ids.append(repo.insert(track))
        }
        var other = Self.track(id: 3, album: otherAlbum, gain: -2, peak: 0.4)
        other.id = nil
        let otherID = try await repo.insert(other)

        // Only the first track was in this batch; the second was measured earlier.
        let result = await ReplayGainAlbumPass.run(albumIDs: [albumID], repo: repo)

        #expect(result.updated == 2)
        #expect(result.failed == 0)
        let expected = Self.expectedAlbumGain([-6, -9])
        for id in ids {
            let stored = try await repo.fetch(id: id)
            let gain = try #require(stored.replaygainAlbumGain)
            #expect(abs(gain - expected) < 1e-9)
            #expect(stored.replaygainAlbumPeak == 0.6)
        }
        let untouched = try await repo.fetch(id: otherID)
        #expect(untouched.replaygainAlbumGain == nil, "an album the batch did not touch")
    }
}
