import Combine
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

    /// @Published instead of @AppStorage — see WindowModeController for why.
    /// Whether the mini player is pinned always-on-top.
    @Published public var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(self.alwaysOnTop, forKey: "ui.miniPlayer.alwaysOnTop") }
    }

    // MARK: - Backing store

    public let nowPlaying: NowPlayingViewModel
    private var nowPlayingCancellable: AnyCancellable?

    // MARK: - Init

    public init(nowPlaying: NowPlayingViewModel) {
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: "ui.miniPlayer.alwaysOnTop")
        self.nowPlaying = nowPlaying
        // Re-publish NowPlayingViewModel changes so observing views re-render when
        // the track or playback state changes.
        self.nowPlayingCancellable = nowPlaying.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
