import AudioEngine
import Persistence

// MARK: - QueueReplayGain

/// Turns a queued track into the ReplayGain facts the engine applies at
/// playback (#573). The engine resolves them with the Settings mode and
/// pre-amp itself, so a settings change needs nothing from here.
enum QueueReplayGain {
    /// The facts for `item`, whose track row is `track`, or `nil` to play it
    /// as it is: a Subsonic, podcast or radio item (its track id is not a
    /// library row) or a row that could not be read.
    static func facts(for item: QueueItem, track: Track?, playOrder: [QueueItem]) -> TrackReplayGain? {
        guard !item.playableSource.isRemote, let track else { return nil }
        let values = TrackGainInfo(
            trackGainDB: track.replaygainTrackGain,
            trackPeakLinear: track.replaygainTrackPeak,
            albumGainDB: track.replaygainAlbumGain,
            albumPeakLinear: track.replaygainAlbumPeak
        )
        return TrackReplayGain(values: values, isInAlbumContext: self.isInAlbumSpan(item, playOrder: playOrder))
    }

    /// Whether `item` plays inside an album span: the item just before or
    /// just after it in play order is from the same album. `.auto` mode
    /// plays album gain there and track gain elsewhere, so a shuffled queue,
    /// whose neighbours are rarely from one album, levels track by track.
    static func isInAlbumSpan(_ item: QueueItem, playOrder: [QueueItem]) -> Bool {
        guard let album = item.albumID,
              let index = playOrder.firstIndex(where: { $0.id == item.id }) else { return false }
        let before = index > playOrder.startIndex ? playOrder[index - 1].albumID : nil
        let after = index + 1 < playOrder.endIndex ? playOrder[index + 1].albumID : nil
        return before == album || after == album
    }
}
