import Library
import SwiftUI
import UI

// MARK: - BocanCommands

/// Application menu commands.
///
/// Stored as plain `let` references (not `@ObservedObject`) so this struct's
/// `body` never re-evaluates due to observable publishes.  `BocanApp.body`
/// itself is also free of `@StateObject` subscriptions, meaning the menu bar
/// is only rebuilt on `showMenuBarExtra` changes — not on every selection or
/// playback tick.  Track-menu items are always enabled; actions guard
/// internally against empty selections.
struct BocanCommands: Commands {
    let vm: LibraryViewModel
    let windowMode: WindowModeController
    let lyricsVM: LyricsViewModel
    let visualizerVM: VisualizerViewModel
    let dspVM: DSPViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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

            Divider()

            // Phase 3 audit M2: Quick / Full rescan entry-points for the File
            // menu so users aren't limited to per-track right-click "Re-scan File".
            // ⌘R is reserved for "Reveal in Finder" (see KeyBindings.revealInFinder)
            // and ⌘⇧R is used by TracksView's "Clear Sort", so we use ⌥-modifiers.
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

            // Phase 4 audit C2: ⌘⇧O is reserved for "Add Folder to Library…"
            // (KeyBindings.addFolder).  Import Playlist gets ⌘⌥⇧O so the two
            // file-import entries don't trample each other.
            Button("Import Playlist…") {
                self.vm.isPlaylistImportSheetPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command, .option, .shift])
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

            // Phase 5 audit H1: keyboard-accessible mode toggles.  Labels
            // include the current state so VoiceOver announces it and so
            // users can confirm without opening the strip.
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
                Task { await self.vm.clearQueue() }
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

        // Phase 4 audit H5: replace the default Find menu so ⌘F focuses the
        // toolbar search field instead of triggering SwiftUI's no-op default.
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                self.vm.requestSearchFocus()
            }
            .keyboardShortcut(KeyBindings.focusSearch)
        }

        CommandGroup(after: .windowArrangement) {
            // Phase 4 audit C1: ⌘L is reserved for "Love" (the Track menu);
            // Show Lyrics moves to ⌘⌥L so the two don't collide.
            Button(self.lyricsVM.paneVisible ? "Hide Lyrics" : "Show Lyrics") {
                self.lyricsVM.paneVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button(self.visualizerVM.paneVisible ? "Hide Visualizer" : "Show Visualizer") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.visualizerVM.paneVisible.toggle()
                }
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

            Button("Equaliser & DSP…") {
                self.dspVM.showDSPPanel = true
            }
            .keyboardShortcut(KeyBindings.showEQPanel)
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
        }

        // Override the default help command to open the help page directly.
        // Apple's Help Book system requires the bundle to be indexed with
        // hiutil before the Help Viewer can display it; during development
        // that never runs, so we redirect to GitHub instead.
        CommandGroup(replacing: .help) {
            Button("Bòcan Music Help") {
                if let url = URL(string: "https://github.com/bocan/bocan-music") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)
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
