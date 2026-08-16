import Foundation
import Testing
@testable import UI

// MARK: - JumpToCurrentTrackTests

/// Regression (ADR-081 invocation pass): "Jump to Current Track" from
/// the Albums grid silently did nothing. The guard checked only whether
/// `tracks.rows` contained the playing row, but the shared tracks model
/// keeps the previous list's rows while grids and self-loading
/// destinations are on screen, so membership lied and the destination
/// never switched to Songs. The behavioral leg lives in the E2E
/// invocation pass; this pins the destination classification the fix
/// keys on.
@Suite("Jump to current track destination classification")
struct JumpToCurrentTrackTests {
    @Test(
        "destinations that render the shared track list scroll in place",
        arguments: [
            SidebarDestination.songs,
            .album(1),
            .artist(1),
            .recentlyAdded,
            .recentlyPlayed,
            .mostPlayed,
        ]
    )
    func sharedListDestinations(destination: SidebarDestination) {
        #expect(LibraryViewModel.destinationRendersSharedTrackList(destination))
    }

    @Test(
        "grids and self-loading destinations must jump to Songs",
        arguments: [
            SidebarDestination.albums,
            .artists,
            .genres,
            .composers,
            .upNext,
            .radio,
        ]
    )
    func selfLoadingDestinations(destination: SidebarDestination) {
        #expect(!LibraryViewModel.destinationRendersSharedTrackList(destination))
    }
}
