import SwiftUI

// MARK: - LyricsPlaybackDriver

/// Feeds playback into the lyrics view model: a track change reloads the
/// document, and each position tick moves the synced line.
///
/// Applied once, at the root of the main window, not inside the lyrics pane,
/// so every surface that shows the document sees the same highlight whether
/// or not the pane is on screen: the pane, and the Immersive Mode lyrics
/// column (ADR-089).
///
/// This modifier is the only reader of `position` at the root. A modifier's
/// body is its own graph node, so the 0.5 s tick re-evaluates this small
/// chain and not `BocanRootView.body` (#450); keep position reads out of
/// the root body itself.
struct LyricsPlaybackDriver: ViewModifier {
    let lyricsVM: LyricsViewModel
    let nowPlaying: NowPlayingViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: self.nowPlaying.nowPlayingTrackID) { _, trackID in
                self.lyricsVM.trackDidChange(trackID: trackID)
            }
            .onChange(of: self.nowPlaying.position) { _, position in
                self.lyricsVM.positionDidChange(position)
            }
    }
}
