import SwiftUI

// MARK: - MainToolbarItems

/// The main window's navigation-placement toolbar group: history, the view
/// toggles (mini player, lyrics, visualizer, Immersive Mode) and Identify
/// Track. Split out of ``BocanRootView`` to keep that file under the length
/// cap. A plain struct: the root re-evaluates on every value it passes in,
/// so the labels and enablement stay live without wrappers here.
struct MainToolbarItems: ToolbarContent {
    let vm: LibraryViewModel
    let miniPlayerOpen: Bool
    let toggleMiniPlayer: () -> Void
    let lyricsPaneVisible: Binding<Bool>
    let visualizerPaneVisible: Binding<Bool>
    /// Immersive Mode (ADR-089). The toolbar stays visible while it is on, so
    /// this button is also an exit.
    let immersiveVisible: Binding<Bool>
    let reduceMotion: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(L10n.string("Back"), systemImage: "chevron.left") {
                Task { await self.vm.goBack() }
            }
            .disabled(!self.vm.canGoBack)
            .help(L10n.string("Back (⌘[)"))
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier(A11y.Toolbar.back)

            Button(L10n.string("Forward"), systemImage: "chevron.right") {
                Task { await self.vm.goForward() }
            }
            .disabled(!self.vm.canGoForward)
            .help(L10n.string("Forward (⌘])"))
            .keyboardShortcut("]", modifiers: .command)
            .accessibilityIdentifier(A11y.Toolbar.forward)

            Button(
                self.miniPlayerOpen ? L10n.string("Hide Mini Player") : L10n.string("Show Mini Player"),
                systemImage: "pip.enter"
            ) {
                self.toggleMiniPlayer()
            }
            .help(L10n.string("Toggle mini player (⌥⌘M)"))
            .accessibilityIdentifier(A11y.Toolbar.miniPlayerToggle)

            Button(
                self.lyricsPaneVisible.wrappedValue ? L10n.string("Hide Lyrics") : L10n.string("Show Lyrics"),
                systemImage: "text.quote"
            ) {
                self.toggleAnimated(self.lyricsPaneVisible)
            }
            .help(L10n.string("Toggle lyrics pane (⌥⌘L)"))
            .accessibilityIdentifier(A11y.Toolbar.lyricsToggle)

            Button(
                self.visualizerPaneVisible.wrappedValue ? L10n.string("Hide Visualizer") : L10n.string("Show Visualizer"),
                // Spectrum-bars glyph, distinct from the waveform +
                // magnifier used by Identify Track right beside it.
                systemImage: "chart.bar.xaxis"
            ) {
                self.toggleAnimated(self.visualizerPaneVisible)
            }
            .help(L10n.string("Toggle visualizer pane (⇧⌘V)"))
            .accessibilityIdentifier(A11y.Toolbar.visualizerToggle)

            Button(
                self.immersiveVisible.wrappedValue ? L10n.string("Exit Immersive Mode") : L10n.string("Enter Immersive Mode"),
                systemImage: "rectangle.split.3x1"
            ) {
                self.toggleAnimated(self.immersiveVisible)
            }
            .help(L10n.string("Toggle Immersive Mode (⇧⌘I)"))
            .accessibilityIdentifier(A11y.Toolbar.immersiveToggle)

            Button(L10n.string("Identify Track"), systemImage: "waveform.badge.magnifyingglass") {
                self.vm.showIdentifyTrackForCurrentSelection()
            }
            .disabled(!self.vm.hasSingleTrackSelection)
            .help(L10n.string("Identify track using AcoustID (⌘⌥I)"))
            .accessibilityIdentifier(A11y.Toolbar.identifyTrack)
        }
    }

    /// Flips a pane flag with the same short fade the panes always used,
    /// unless Reduce Motion is on.
    private func toggleAnimated(_ flag: Binding<Bool>) {
        if self.reduceMotion {
            flag.wrappedValue.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                flag.wrappedValue.toggle()
            }
        }
    }
}
