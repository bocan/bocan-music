import Combine
import Foundation
import SwiftUI

// MARK: - MiniPlayerViewModel

/// Bridges `NowPlayingViewModel` to the Mini Player window.
///
/// Thin wrapper — all playback state lives in `NowPlayingViewModel`; this
/// class adds window-specific UI state (pin, layout) that only the mini
/// player cares about.
@MainActor
public final class MiniPlayerViewModel: ObservableObject {
    // MARK: - Layout

    public enum Layout: String, CaseIterable {
        case strip, compact, square

        /// SF Symbol representing this layout, shown on the cycle button.
        var icon: String {
            switch self {
            case .strip:
                "minus"

            case .compact:
                "rectangle"

            case .square:
                "square"
            }
        }

        /// Target window size when the user explicitly selects this layout.
        var defaultWindowSize: CGSize {
            switch self {
            case .strip:
                CGSize(width: 420, height: 72)

            case .compact:
                CGSize(width: 450, height: 145)

            case .square:
                CGSize(width: 310, height: 310)
            }
        }

        func next() -> Self {
            switch self {
            case .strip:
                .compact

            case .compact:
                .square

            case .square:
                .strip
            }
        }
    }

    // MARK: - Window UI state

    /// @Published instead of @AppStorage — see WindowModeController for why.
    @Published public var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(self.alwaysOnTop, forKey: "ui.miniPlayer.alwaysOnTop") }
    }

    @Published public var layout: Layout {
        didSet { UserDefaults.standard.set(self.layout.rawValue, forKey: "ui.miniPlayer.layout") }
    }

    // MARK: - Backing store

    public let nowPlaying: NowPlayingViewModel
    private var nowPlayingCancellable: AnyCancellable?

    // MARK: - Init

    public init(nowPlaying: NowPlayingViewModel) {
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: "ui.miniPlayer.alwaysOnTop")
        let storedLayout = UserDefaults.standard.string(forKey: "ui.miniPlayer.layout")
            .flatMap { Layout(rawValue: $0) } ?? .compact
        self.layout = storedLayout
        self.nowPlaying = nowPlaying
        // Re-publish NowPlayingViewModel changes so observing views re-render when
        // the track or playback state changes.
        self.nowPlayingCancellable = nowPlaying.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Actions

    public func cycleLayout() {
        self.layout = self.layout.next()
    }
}
