import SwiftUI

/// The release half of a progress-bar drag, shared by every scrubber (the
/// strip, the mini player layouts, Immersive and the menu bar extra).
///
/// Each scrubber holds its drag fraction locally so live position updates do
/// not fight the thumb. On release, the fraction stays until the seek has
/// landed: clearing it first let the bar show the old position for a moment
/// and then jump forward, which read as a flicker (#710).
@MainActor
enum ScrubberDrag {
    /// Seeks to the held fraction of the track, then lets go of it. A new
    /// drag that began while the seek was on its way keeps its own value.
    static func release(_ drag: Binding<Double?>, nowPlaying: NowPlayingViewModel) async {
        guard let fraction = drag.wrappedValue else { return }
        await nowPlaying.scrub(to: fraction * nowPlaying.duration)
        if drag.wrappedValue == fraction {
            drag.wrappedValue = nil
        }
    }
}
