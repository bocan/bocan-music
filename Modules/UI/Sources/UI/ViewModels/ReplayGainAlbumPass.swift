import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - ReplayGainAlbumPass

/// Album gain for the albums a ReplayGain batch has measured (#579).
///
/// The batch measures tracks one by one, which gives each its track gain and
/// peak. An album's gain comes from all of its tracks together: the power
/// mean of their loudness (`ReplayGainAnalyzer.albumGain(from:)`), so Album
/// and Auto modes keep an album's quiet and loud songs in proportion instead
/// of levelling each one. Each track's loudness is recovered from its stored
/// gain (gain = target - loudness), so tracks analysed in an earlier run, or
/// tagged by another tool, count too.
enum ReplayGainAlbumPass {
    /// The tracks of `tracks` whose album gain or peak change: for each album
    /// whose every track has a track gain, the album's gain and peak on each
    /// of its tracks. An album with a track not yet measured is left alone,
    /// since its gain would be wrong for that track. The album peak is the
    /// loudest track peak, or `nil` when a track has no peak.
    ///
    /// Pass every track of the albums concerned, not only the ones just
    /// measured. Tracks without an album are ignored.
    static func albumUpdates(_ tracks: [Track]) -> [Track] {
        let albums = Dictionary(grouping: tracks.filter { $0.albumID != nil }, by: \.albumID)
        var updated: [Track] = []
        for albumTracks in albums.values {
            let gains = albumTracks.compactMap(\.replaygainTrackGain)
            guard gains.count == albumTracks.count else { continue }
            let measured = gains.map {
                ReplayGainResult(integratedLUFS: ReplayGainAnalyzer.targetLUFS - $0, truePeakLinear: 0)
            }
            guard let album = ReplayGainAnalyzer.albumGain(from: measured) else { continue }
            let peaks = albumTracks.compactMap(\.replaygainTrackPeak)
            let albumPeak = peaks.count == albumTracks.count ? peaks.max() : nil
            for track in albumTracks
                where track.replaygainAlbumGain != album.gainDB || track.replaygainAlbumPeak != albumPeak {
                var changed = track
                changed.replaygainAlbumGain = album.gainDB
                changed.replaygainAlbumPeak = albumPeak
                updated.append(changed)
            }
        }
        return updated
    }

    /// Recompute and store the album gain of every album in `albumIDs`.
    /// Reads all tracks once, so an album's tracks outside the batch count,
    /// and writes only the two album columns, in one transaction. A failed
    /// write is logged and changes nothing: every track keeps its old album
    /// gain, and Album mode falls back to track gain where there is none.
    ///
    /// - Returns: how many tracks got a new album gain, and how many were not
    ///   written because the write failed.
    @discardableResult
    static func run(albumIDs: Set<Int64>, repo: TrackRepository) async -> (updated: Int, failed: Int) {
        guard !albumIDs.isEmpty else { return (0, 0) }
        let log = AppLogger.make(.audio)
        let tracks: [Track]
        do {
            tracks = try await repo.fetchAll().filter { $0.albumID.map(albumIDs.contains) ?? false }
        } catch {
            // Every track keeps its track gain; Album and Auto modes fall back
            // to it for these albums, as they did before album gain existed.
            log.error("rg.album.fetchFailed", ["albums": albumIDs.count, "error": String(reflecting: error)])
            return (0, 0)
        }
        let updates = self.albumUpdates(tracks)
        do {
            try await repo.setAlbumReplayGain(from: updates)
        } catch {
            log.error("rg.album.updateFailed", ["tracks": updates.count, "error": String(reflecting: error)])
            return (0, updates.count)
        }
        log.info("rg.album.done", ["albums": albumIDs.count, "tracks": updates.count])
        return (updates.count, 0)
    }
}
