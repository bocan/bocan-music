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

    @AppStorage("general.showDockProgress") private var showProgress = true

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

        // Tick progress bar at ≤ 1 Hz
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let position = self.vm?.position ?? 0
                let duration = self.vm?.duration ?? 0
                let progress = duration > 0 ? position / duration : 0
                self.contentView.progress = progress
                self.contentView.isVisible = self.showProgress && (self.vm?.isPlaying == true)
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
        guard let artwork = self.vm?.artwork else {
            self.contentView.artwork = nil
            NSApp.dockTile.display()
            return
        }
        self.contentView.artwork = artwork
        NSApp.dockTile.display()
    }
}

// MARK: - DockTileProgressView

/// A custom `NSView` compositing album art + progress bar for the Dock tile.
final class DockTileProgressView: NSView {
    var artwork: NSImage?
    var progress: Double = 0
    var isVisible = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        // Draw app icon as background if no artwork
        let base = self.artwork ?? NSApp.applicationIconImage
        base?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)

        // Progress bar at bottom (only when playing)
        guard self.isVisible, self.progress > 0 else { return }
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
}
