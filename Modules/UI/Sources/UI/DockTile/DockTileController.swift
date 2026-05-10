import AppKit
import Foundation
import SwiftUI

// MARK: - DockTileController

/// Updates `NSApp.dockTile` when the playing track changes.
///
/// Composites a small app-logo corner onto the current album art and draws a
/// progress bar at the bottom of the tile using a custom `NSView`.
///
/// Updates are throttled to ≤ 1 Hz during playback to avoid GPU over-use.
/// Call `start(observing:)` once after the app launches, passing the
/// `NowPlayingViewModel` to observe.
@MainActor
public final class DockTileController: ObservableObject {
    // MARK: - State

    /// Read directly from UserDefaults in the tick loop instead of @AppStorage —
    /// see WindowModeController for why @AppStorage in ObservableObject is unsafe here.
    private static let showProgressKey = "general.showDockProgress"
    private static let showAlbumArtKey = "general.showAlbumArtInDock"
    private static let showPlaybackBadgeKey = "general.showPlaybackBadge"

    private weak var vm: NowPlayingViewModel?
    private var observationTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let contentView = DockTileProgressView()

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    public func start(observing vm: NowPlayingViewModel) {
        // Cancel any previous loops — .onAppear can fire more than once.
        self.observationTask?.cancel()
        self.tickTask?.cancel()

        self.vm = vm
        NSApp.dockTile.contentView = self.contentView

        // Observe artwork + track changes
        self.observationTask = Task { [weak self] in
            var lastID: Int64?
            while !Task.isCancelled {
                guard let self else { return }
                let id = self.vm?.nowPlayingTrackID
                if id != lastID {
                    lastID = id
                    await self.updateArtwork()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // Tick progress bar + badge at ≤ 0.5 Hz
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let position = self.vm?.position ?? 0
                let duration = self.vm?.duration ?? 0
                let progress = duration > 0 ? position / duration : 0
                let isPlaying = self.vm?.isPlaying == true
                let isPaused = self.vm?.isPaused == true
                let showProgress = UserDefaults.standard.object(forKey: Self.showProgressKey) as? Bool ?? true
                let showBadge = UserDefaults.standard.object(forKey: Self.showPlaybackBadgeKey) as? Bool ?? true
                self.contentView.progress = progress
                self.contentView.isProgressVisible = showProgress && isPlaying
                self.contentView.isPlaying = isPlaying
                self.contentView.isPaused = isPaused
                self.contentView.showPlaybackBadge = showBadge
                NSApp.dockTile.display()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
            }
        }
    }

    public func stop() {
        self.observationTask?.cancel()
        self.tickTask?.cancel()
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
    }

    // MARK: - Private

    private func updateArtwork() async {
        let showAlbumArt = UserDefaults.standard.object(forKey: Self.showAlbumArtKey) as? Bool ?? true
        guard showAlbumArt, let artwork = self.vm?.artwork else {
            self.contentView.artwork = nil
            NSApp.dockTile.display()
            return
        }
        self.contentView.artwork = artwork
        NSApp.dockTile.display()
    }
}

// MARK: - DockTileProgressView

/// A custom `NSView` compositing album art + progress bar + playback badge for the Dock tile.
final class DockTileProgressView: NSView {
    var artwork: NSImage?
    var progress: Double = 0
    var isProgressVisible = false
    var isPlaying = false
    var isPaused = false
    var showPlaybackBadge = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        // Draw album art (or app icon as fallback)
        let base = self.artwork ?? NSApp.applicationIconImage
        base?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)

        // Progress bar at bottom (only when playing)
        if self.isProgressVisible, self.progress > 0 {
            let barHeight: CGFloat = 8
            let barRect = CGRect(
                x: 0,
                y: 0,
                width: bounds.width * self.progress,
                height: barHeight
            )
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: barRect).fill()
        }

        // Playback state badge (bottom-right corner circle with play/pause icon)
        guard self.showPlaybackBadge, self.isPlaying || self.isPaused else { return }

        let badgeSize: CGFloat = 28
        let padding: CGFloat = 4
        let badgeRect = CGRect(
            x: bounds.width - badgeSize - padding,
            y: padding,
            width: badgeSize,
            height: badgeSize
        )

        // White halo for legibility over any artwork colour
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -2, dy: -2)).fill()

        // Accent-coloured circle
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        // Play ▶ or pause ‖ symbol
        let symbolName = self.isPlaying ? "play.fill" : "pause.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let symSize = badgeSize * 0.58
            let symRect = CGRect(
                x: badgeRect.midX - symSize / 2,
                y: badgeRect.midY - symSize / 2,
                width: symSize,
                height: symSize
            )
            sym.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}
