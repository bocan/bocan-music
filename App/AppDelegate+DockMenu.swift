import AppKit
import UI

// MARK: - Dock tile context menu

/// Provides the right-click context menu for Bòcan's Dock icon.
///
/// Mirrors the core transport actions available in the menu bar extra and
/// the `Playback` menu so users can control playback without bringing the
/// main window to the front.
extension AppDelegate {
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let np = self.libraryViewModel?.nowPlaying

        // ── Track info header ──────────────────────────────────────────────
        if let np, np.nowPlayingTrackID != nil {
            if !np.title.isEmpty {
                let item = NSMenuItem(title: np.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if !np.artist.isEmpty {
                let item = NSMenuItem(title: np.artist, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // ── Transport ──────────────────────────────────────────────────────
        let playLabel = np?.isPlaying == true ? "Pause" : "Play"
        let playItem = NSMenuItem(title: playLabel, action: #selector(dockPlayPause), keyEquivalent: "")
        playItem.target = self
        menu.addItem(playItem)

        let sacItem = NSMenuItem(
            title: "Stop After Current",
            action: #selector(dockStopAfterCurrent),
            keyEquivalent: ""
        )
        sacItem.target = self
        sacItem.state = np?.stopAfterCurrent == true ? .on : .off
        sacItem.isEnabled = np?.nowPlayingTrackID != nil
        menu.addItem(sacItem)

        menu.addItem(.separator())

        let prevItem = NSMenuItem(
            title: "Previous Track",
            action: #selector(dockPreviousTrack),
            keyEquivalent: ""
        )
        prevItem.target = self
        prevItem.isEnabled = np?.nowPlayingTrackID != nil
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(
            title: "Next Track",
            action: #selector(dockNextTrack),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = np?.nowPlayingTrackID != nil
        menu.addItem(nextItem)

        return menu
    }

    // MARK: - Dock menu actions

    @objc private func dockPlayPause() {
        Task { await self.libraryViewModel?.nowPlaying.playPause() }
    }

    @objc private func dockStopAfterCurrent() {
        Task { await self.libraryViewModel?.nowPlaying.toggleStopAfterCurrent() }
    }

    @objc private func dockPreviousTrack() {
        Task { await self.libraryViewModel?.nowPlaying.previous() }
    }

    @objc private func dockNextTrack() {
        Task { await self.libraryViewModel?.nowPlaying.next() }
    }
}
