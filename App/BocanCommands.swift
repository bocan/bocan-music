import Library
import SwiftUI
import UI

// MARK: - BocanCommands

/// Application menu commands. VMs are plain `let` (not `@ObservedObject`/`@Bindable`) to
/// prevent menu-bar rebuilds on every playback tick or 60 fps visualizer update, which
/// starves the audio buffer. Live-state labels read `@AppStorage` keys directly.
struct BocanCommands: Commands {
    let vm: LibraryViewModel
    let windowMode: WindowModeController
    let lyricsVM: LyricsViewModel
    let visualizerVM: VisualizerViewModel
    let settingsRouter: SettingsRouter
    let updateController: UpdateController
    /// Mirrors `LyricsViewModel.paneVisible` (`@AppStorage("lyrics.paneVisible")`).
    @AppStorage("lyrics.paneVisible") private var lyricsPaneVisible = false
    /// Mirrors `LyricsViewModel.lrclibEnabled` (`@AppStorage("lyrics.lrclibEnabled")`).
    @AppStorage("lyrics.lrclibEnabled") private var lyricsLrclibEnabled = false
    /// Mirrors `VisualizerViewModel.paneVisible` (`@AppStorage("visualizer.paneVisible")`).
    @AppStorage("visualizer.paneVisible") private var visualizerPaneVisible = false
    /// Mirrors `NowPlayingStrip.showRecentScrobbles` (`@AppStorage("scrobble.showRecentSheet")`).
    @AppStorage("scrobble.showRecentSheet") private var showRecentScrobbles = false
    /// In-app Reduce Motion toggle, mirrored so menu-driven pane changes can match
    /// the toolbar buttons' animation behaviour (issue #312).
    @AppStorage("appearance.reduceMotion") private var appReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// `true` when motion should be suppressed (system Reduce Motion or the in-app toggle).
    private var reduceMotion: Bool {
        self.systemReduceMotion || self.appReduceMotion
    }

    /// Toggles `flag`, animating the change the same way the lyrics/visualizer
    /// toolbar buttons do, unless Reduce Motion is active (issue #312).
    private func toggleAnimated(_ flag: Binding<Bool>) {
        if self.reduceMotion {
            flag.wrappedValue.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                flag.wrappedValue.toggle()
            }
        }
    }

    var body: some Commands {
        // Custom About window (credits + Check for Updates), with Check for
        // Updates kept in the app menu per macOS convention.
        CommandGroup(replacing: .appInfo) {
            Button("About Bòcan") {
                self.openWindow(id: "about")
            }

            Button("Check for Updates\u{2026}") {
                self.updateController.checkForUpdates()
            }
            .disabled(!self.updateController.canCheckForUpdates)
            .help("Check whether a newer version of Bòcan is available.")
        }

        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") {
                self.vm.playlistSidebar.beginNewPlaylist()
            }
            .keyboardShortcut(KeyBindings.newPlaylist)

            Button("New Smart Playlist…") {
                self.vm.playlistSidebar.beginNewSmartPlaylist()
            }
            .keyboardShortcut(KeyBindings.newSmartPlaylist)

            Button("New Playlist Folder…") {
                self.vm.playlistSidebar.beginNewFolder()
            }

            Divider()

            Button("Add Folder to Library…") {
                Task { await self.vm.addFolderByPicker() }
            }
            .keyboardShortcut(KeyBindings.addFolder)

            Button("Add Files to Library…") {
                Task { await self.vm.addFilesByPicker() }
            }
            .keyboardShortcut(KeyBindings.addFiles)

            // Deep-link straight to Settings ▸ Sources so server setup is
            // discoverable from a menu, not only the sidebar (#305).
            Button("Music Sources…") {
                self.settingsRouter.open(.sources)
                self.openSettings()
            }
            .help("Add or manage streaming music servers (Subsonic-compatible)")

            Divider()

            // Quick / Full rescan. ⌘R is Reveal in Finder and ⌘⇧R is Clear Sort,
            // so these use ⌥-modifiers.
            Button("Quick Rescan Library") {
                self.vm.rescanLibrary(mode: .quick)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(self.vm.isScanning)

            Button("Full Rescan Library") {
                self.vm.rescanLibrary(mode: .full)
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            .disabled(self.vm.isScanning)

            Divider()

            // ⌘⇧O is Add Folder, so Import Playlist gets ⌘⌥⇧O.
            Button("Import Playlist…") {
                self.vm.isPlaylistImportSheetPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command, .option, .shift])
        }

        // Restore the standard Show/Hide Sidebar item; the system also manages
        // Enter Full Screen here. Using the system View menu (not a custom
        // CommandMenu) guarantees a single View menu in the right place (#303/#304).
        SidebarCommands()

        // View menu: presentation toggles for the panes and auxiliary windows.
        // Per HIG these belong under View, not the Window menu (#303); appended
        // after the sidebar group so they sit below Show/Hide Sidebar.
        CommandGroup(after: .sidebar) {
            // ⌘L is reserved for "Love" (the Track menu); Show Lyrics uses ⌘⌥L.
            Button(self.lyricsPaneVisible ? "Hide Lyrics" : "Show Lyrics") {
                self.toggleAnimated(self.$lyricsPaneVisible)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button(self.visualizerPaneVisible ? "Hide Visualizer" : "Show Visualizer") {
                self.toggleAnimated(self.$visualizerPaneVisible)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Open Fullscreen Visualizer") {
                self.openWindow(id: "visualizer-fullscreen")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle Miniplayer") {
                self.windowMode.toggleMiniPlayer()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])

            Divider()

            Button("Show Recent Scrobbles") {
                self.showRecentScrobbles = true
            }
            .keyboardShortcut("s", modifiers: [.command, .option, .shift])
            .help("Show the list of recently scrobbled tracks and their submission status")

            Divider()

            Button("Equaliser & DSP…") {
                self.openWindow(id: "dsp")
            }
            .keyboardShortcut(KeyBindings.showEQPanel)
        }

        CommandMenu("Playback") {
            Button("Play / Pause") {
                Task { await self.vm.nowPlaying.playPause() }
            }
            .keyboardShortcut(KeyBindings.playPause)

            Button("Next Track") {
                Task { await self.vm.nowPlaying.next() }
            }
            .keyboardShortcut(KeyBindings.nextTrack)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Button("Previous Track") {
                Task { await self.vm.nowPlaying.previous() }
            }
            .keyboardShortcut(KeyBindings.previousTrack)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Button("Restart Track") {
                Task { await self.vm.nowPlaying.restartTrack() }
            }
            .keyboardShortcut(KeyBindings.restartTrack)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Divider()

            Button(self.vm.nowPlaying.isMuted ? "Unmute" : "Mute") {
                Task { await self.vm.nowPlaying.toggleMute() }
            }
            .keyboardShortcut(KeyBindings.mute)

            Button("Increase Volume") {
                Task { await self.vm.nowPlaying.increaseVolume() }
            }
            .keyboardShortcut(KeyBindings.increaseVolume)

            Button("Decrease Volume") {
                Task { await self.vm.nowPlaying.decreaseVolume() }
            }
            .keyboardShortcut(KeyBindings.decreaseVolume)

            Button("Choose Audio Output…") {
                NotificationCenter.default.post(name: .bocanActivateRoutePicker, object: nil)
            }
            .keyboardShortcut(KeyBindings.chooseAudioOutput)
            .help("Open the AirPlay / audio output picker")

            // Keyboard-accessible mode toggles.
            Button("Toggle Shuffle") {
                Task { await self.vm.nowPlaying.toggleShuffle() }
            }
            .keyboardShortcut(KeyBindings.toggleShuffle)

            Button("Cycle Repeat") {
                Task { await self.vm.nowPlaying.cycleRepeat() }
            }
            .keyboardShortcut(KeyBindings.cycleRepeat)

            Button("Toggle Stop After Current") {
                Task { await self.vm.nowPlaying.toggleStopAfterCurrent() }
            }
            .keyboardShortcut(KeyBindings.stopAfterCurrent)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Divider()

            Button("Clear Queue") {
                Task { await self.vm.requestClearQueue() }
            }
            .keyboardShortcut(KeyBindings.clearQueue)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Button("Show Up Next") {
                Task { await self.vm.selectDestination(.upNext) }
            }
            .keyboardShortcut(KeyBindings.showUpNext)

            Divider()

            Menu("Playback Speed") {
                ForEach(NowPlayingViewModel.quickRates, id: \.self) { rate in
                    Button(String(format: "%.2g×", rate)) {
                        Task { await self.vm.nowPlaying.setRate(rate) }
                    }
                }
            }

            Button("Increase Speed") {
                Task { await self.vm.nowPlaying.increaseSpeed() }
            }
            .keyboardShortcut(KeyBindings.increaseSpeed)

            Button("Decrease Speed") {
                Task { await self.vm.nowPlaying.decreaseSpeed() }
            }
            .keyboardShortcut(KeyBindings.decreaseSpeed)

            Button("Reset Speed to 1×") {
                Task { await self.vm.nowPlaying.resetSpeed() }
            }
            .keyboardShortcut(KeyBindings.resetSpeed)

            Divider()

            Menu("Sleep Timer") {
                Picker(
                    "Sleep Timer",
                    selection: Binding(
                        get: { self.vm.nowPlaying.sleepTimerActiveMinutes },
                        set: { minutes in
                            Task {
                                await self.vm.nowPlaying.setSleepTimer(
                                    minutes: minutes,
                                    fadeOut: self.vm.nowPlaying.sleepTimerFadeOut
                                )
                            }
                        }
                    )
                ) {
                    ForEach(NowPlayingViewModel.sleepPresets, id: \.label) { preset in
                        Text(preset.label).tag(preset.minutes)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button("Jump to Current Track") {
                Task { await self.vm.scrollToNowPlayingTrack() }
            }
            .keyboardShortcut(KeyBindings.jumpToCurrentTrack)
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            Button("Go to Current Album") {
                Task { await self.vm.goToCurrentAlbum() }
            }
            .keyboardShortcut(KeyBindings.goToCurrentAlbum)
            .disabled(self.vm.nowPlaying.nowPlayingAlbumID == nil)

            Button("Go to Current Artist") {
                Task { await self.vm.goToCurrentArtist() }
            }
            .keyboardShortcut(KeyBindings.goToCurrentArtist)
            .disabled(self.vm.nowPlaying.nowPlayingArtistID == nil)
        }

        // Override Find so ⌘F focuses the toolbar search, not SwiftUI's no-op.
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                self.vm.requestSearchFocus()
            }
            .keyboardShortcut(KeyBindings.focusSearch)
        }

        CommandMenu("Track") {
            Button("Play Now") {
                self.vm.playNowForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.playNow)
            .disabled(!self.vm.hasTrackSelection)

            Button("Play Next") {
                self.vm.playNextForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.playNext)
            .disabled(!self.vm.hasTrackSelection)

            Button("Add to Queue") {
                self.vm.addToQueueForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.addToQueue)
            .disabled(!self.vm.hasTrackSelection)

            Divider()

            Button("Play Album") {
                self.vm.playAlbumForCurrentSelection(shuffle: false)
            }
            .disabled(!self.vm.hasTrackSelection)

            Button("Shuffle Album") {
                self.vm.playAlbumForCurrentSelection(shuffle: true)
            }
            .disabled(!self.vm.hasTrackSelection)

            Button("Play Artist") {
                self.vm.playArtistForCurrentSelection()
            }
            .disabled(!self.vm.hasTrackSelection)

            Divider()

            Button("Get Info") {
                self.vm.showTagEditorForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.getInfo)

            Button("Identify Track\u{2026}") {
                self.vm.showIdentifyTrackForCurrentSelection()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Reveal in Finder") {
                self.vm.revealSelectedInFinder()
            }
            .keyboardShortcut(KeyBindings.revealInFinder)

            Divider()

            // Phase 4 audit C1: real Love command, replacing the disabled stub.
            Button("Love / Unlove") {
                self.vm.toggleLovedForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.love)
            .disabled(!self.vm.hasTrackSelection)

            // Phase 4 audit C3: ⌘1…⌘5 rating shortcuts must work as global
            // accelerators (the per-context-menu Rate submenu only fires when
            // the menu is open).  ⌘0 clears the rating to round out the set.
            Menu("Rate") {
                Button("None") { self.vm.setRatingForCurrentSelection(stars: 0) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("★") { self.vm.setRatingForCurrentSelection(stars: 1) }
                    .keyboardShortcut(KeyBindings.rate1)
                Button("★★") { self.vm.setRatingForCurrentSelection(stars: 2) }
                    .keyboardShortcut(KeyBindings.rate2)
                Button("★★★") { self.vm.setRatingForCurrentSelection(stars: 3) }
                    .keyboardShortcut(KeyBindings.rate3)
                Button("★★★★") { self.vm.setRatingForCurrentSelection(stars: 4) }
                    .keyboardShortcut(KeyBindings.rate4)
                Button("★★★★★") { self.vm.setRatingForCurrentSelection(stars: 5) }
                    .keyboardShortcut(KeyBindings.rate5)
            }
            .disabled(!self.vm.hasTrackSelection)

            Divider()

            Button("Compute Replay Gain") {
                let ids = self.vm.tracks.selection.compactMap(\.self)
                Task { await self.vm.computeReplayGain(forTrackIDs: ids) }
            }
            .help("Analyse loudness for the selected tracks and save ReplayGain values")
            .disabled(!self.vm.hasTrackSelection)

            Divider()

            Button("Select All") {
                self.vm.selectAllTracks()
            }
            .keyboardShortcut(KeyBindings.selectAll)

            Button("Deselect All") {
                self.vm.deselectAllTracks()
            }
            .keyboardShortcut(KeyBindings.deselectAll)
            .disabled(!self.vm.hasTrackSelection)

            Divider()

            Button("Edit Lyrics\u{2026}") {
                self.lyricsVM.openEditor()
            }
            .keyboardShortcut("l", modifiers: [.command, .option, .shift])
            .help("Open the lyrics editor for the current track")
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil)

            if self.lyricsLrclibEnabled {
                Button("Fetch Lyrics from LRClib") {
                    self.lyricsVM.forceFetch()
                }
                .help("Fetch lyrics from LRClib for the current track, replacing any existing lyrics")
                .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil || self.lyricsVM.isFetching)
            }

            Button("Clear Lyrics") {
                if let id = self.vm.nowPlaying.nowPlayingTrackID {
                    self.lyricsVM.clearLyrics(for: id)
                }
            }
            .help("Delete stored lyrics for the current track")
            .disabled(self.vm.nowPlaying.nowPlayingTrackID == nil || self.lyricsVM.document == nil)
        }

        // Both items open dedicated in-app windows — no browser or external viewer.
        CommandGroup(replacing: .help) {
            Button("Bòcan Music Help") {
                self.openWindow(id: "bocan-help")
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Notices \u{26} Licences\u{2026}") {
                self.openWindow(id: "notices")
            }
            .help("View third-party licence notices for open-source components used by Bòcan")

            Divider()

            Button("Log Console") {
                self.openWindow(id: "log-console")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("Open the in-app log console to view captured log entries")
        }

        CommandMenu("Tools") {
            Button("Fetch Missing Cover Art\u{2026}") {
                self.vm.showBatchCoverArt()
            }
            .help("Search MusicBrainz for cover art for albums with no artwork")

            Button("Find Duplicates\u{2026}") {
                self.vm.showDuplicateReview()
            }
            .help("Find and review tracks that appear more than once in your library")

            Divider()

            Button("Compute Missing ReplayGain") {
                Task { await self.vm.computeMissingReplayGain() }
            }
            .help("Analyse loudness for tracks that don't yet have ReplayGain data")

            Button("Recompute ReplayGain") {
                Task { await self.vm.recomputeAllReplayGain() }
            }
            .help("Re-analyse loudness for every track in the library")
        }
    }
}
