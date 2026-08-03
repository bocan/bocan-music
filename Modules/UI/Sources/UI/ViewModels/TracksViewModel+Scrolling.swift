import Foundation

// MARK: - TracksViewModel + Scrolling

/// Programmatic scroll requests, split from the main file to stay inside its
/// length budget. Both bump `scrollRequest` so repeated jumps always scroll,
/// even to the same row.
public extension TracksViewModel {
    /// Signals `TrackTable` to scroll the now-playing track into view on the
    /// next `updateNSView` pass, clearing any earlier reveal target.
    func requestScrollToNowPlaying() {
        self.scrollTargetTrackID = nil
        self.scrollRequest += 1
    }

    /// Signals `TrackTable` to scroll a specific track into view: the
    /// Library Summary's reveal path.
    func requestScroll(to trackID: Int64) {
        self.scrollTargetTrackID = trackID
        self.scrollRequest += 1
    }
}
