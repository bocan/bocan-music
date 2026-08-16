import SwiftUI
import UI

// MARK: - Track menu

extension BocanCommands {
    /// Selection state read from the @Observable `TracksViewModel`
    /// directly: the Commands body only rebuilds on @Observable (or
    /// @AppStorage) reads, so the VM's @Published `hasTrackSelection`
    /// bridge froze these items at whatever state the body was built with
    /// (ADR-081 enablement matrix).
    private var hasSelection: Bool {
        !self.vm.tracks.selection.isEmpty
    }

    /// The Track menu: actions on the current selection and the current
    /// track. Extracted from `BocanCommands.swift` to keep that file under
    /// the 500-line lint ceiling.
    var trackCommands: some Commands {
        CommandMenu("Track") {
            Button("Play Now") {
                self.vm.playNowForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.playNow)
            .disabled(!self.hasSelection)

            Button("Play Next") {
                self.vm.playNextForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.playNext)
            .disabled(!self.hasSelection)

            Button("Add to Queue") {
                self.vm.addToQueueForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.addToQueue)
            .disabled(!self.hasSelection)

            Divider()

            Button("Play Album") {
                self.vm.playAlbumForCurrentSelection(shuffle: false)
            }
            .disabled(!self.hasSelection)

            Button("Shuffle Album") {
                self.vm.playAlbumForCurrentSelection(shuffle: true)
            }
            .disabled(!self.hasSelection)

            Button("Play Artist") {
                self.vm.playArtistForCurrentSelection()
            }
            .disabled(!self.hasSelection)

            Divider()

            // Selection-scoped like Play Now above: all three no-op without
            // a selection (ADR-081 enablement matrix).
            Button("Get Info") {
                self.vm.showTagEditorForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.getInfo)
            .disabled(!self.hasSelection)

            Button("Identify Track\u{2026}") {
                self.vm.showIdentifyTrackForCurrentSelection()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!self.hasSelection)

            Button("Reveal in Finder") {
                self.vm.revealSelectedInFinder()
            }
            .keyboardShortcut(KeyBindings.revealInFinder)
            .disabled(!self.hasSelection)

            Divider()

            // ADR-005 audit C1: real Love command, replacing the disabled stub.
            Button("Love / Unlove") {
                self.vm.toggleLovedForCurrentSelection()
            }
            .keyboardShortcut(KeyBindings.love)
            .disabled(!self.hasSelection)

            // ADR-005 audit C3: ⌘1…⌘5 rating shortcuts must work as global
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
            .disabled(!self.hasSelection)

            Divider()

            Button("Compute Replay Gain") {
                let ids = self.vm.tracks.selection.compactMap(\.self)
                Task { await self.vm.computeReplayGain(forTrackIDs: ids) }
            }
            .help("Analyse loudness for the selected tracks and save ReplayGain values")
            .disabled(!self.hasSelection)

            Divider()

            // ⌘A must still reach the field editor while text is being edited;
            // the shortcut fires ahead of the responder chain (#379).
            Button("Select All") {
                if !EditMenuRouting.forwardSelectAllToTextEditor() {
                    self.vm.selectAllTracks()
                }
            }
            .keyboardShortcut(KeyBindings.selectAll)

            Button("Deselect All") {
                if !EditMenuRouting.textEditorIsActive {
                    self.vm.deselectAllTracks()
                }
            }
            .keyboardShortcut(KeyBindings.deselectAll)
            .disabled(!self.hasSelection)

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
    }
}
