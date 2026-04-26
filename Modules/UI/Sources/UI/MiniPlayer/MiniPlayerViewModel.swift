import Foundation
import SwiftUI

// MARK: - MiniPlayerViewModel

/// Bridges `NowPlayingViewModel` to the Mini Player window.
///
/// Thin wrapper — all playback state lives in `NowPlayingViewModel`; this
/// class adds window-specific UI state (pin, size mode) that only the mini
/// player cares about.
@MainActor
public final class MiniPlayerViewModel: ObservableObject {
    // MARK: - Window UI state

    /// Whether the mini player is pinned always-on-top.
    @AppStorage("ui.miniPlayer.alwaysOnTop") public var alwaysOnTop = false

    // MARK: - Backing store

    public let nowPlaying: NowPlayingViewModel

    // MARK: - Init

    public init(nowPlaying: NowPlayingViewModel) {
        self.nowPlaying = nowPlaying
    }
}
