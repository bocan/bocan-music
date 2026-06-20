import SwiftUI

// MARK: - PodcastTransportControls

/// The transport control row shown in `NowPlayingStrip` when a podcast episode
/// is playing. Replaces prev/next with configurable skip-backward/skip-forward
/// buttons and omits shuffle, repeat, and stop-after-current.
struct PodcastTransportControls: View {
    var vm: NowPlayingViewModel
    /// Loads the transcript for the current episode, supplied by the parent (which
    /// has the podcast view model). Keeps NowPlayingViewModel free of this concern.
    var loadTranscript: () async -> TranscriptContent?
    @State private var showingTranscript = false

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await self.vm.skipBack() }
            } label: {
                Image(systemName: "gobackward.15")
                    .scaledSystemFont(size: 20, weight: .semibold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)
            .disabled(self.vm.title.isEmpty)
            .help(L10n.string("Skip back 15 seconds"))
            .accessibilityLabel(L10n.string("Skip back 15 seconds"))
            .accessibilityIdentifier(A11y.NowPlaying.skipBack)

            Button {
                Task { await self.vm.playPause() }
            } label: {
                Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    .scaledSystemFont(size: 24, weight: .bold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .keyboardShortcut(KeyBindings.playPause)
            .help(self.vm.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
            .accessibilityLabel(self.vm.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
            .accessibilityIdentifier(A11y.NowPlaying.playPause)

            Button {
                Task { await self.vm.skipForward() }
            } label: {
                Image(systemName: "goforward.30")
                    .scaledSystemFont(size: 20, weight: .semibold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)
            .disabled(self.vm.title.isEmpty)
            .help(L10n.string("Skip forward 30 seconds"))
            .accessibilityLabel(L10n.string("Skip forward 30 seconds"))
            .accessibilityIdentifier(A11y.NowPlaying.skipForward)

            if self.vm.podcastID != nil, self.vm.podcastGUID != nil {
                Button {
                    self.showingTranscript = true
                } label: {
                    Image(systemName: "captions.bubble")
                        .scaledSystemFont(size: 18, weight: .semibold)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)
                .disabled(self.vm.title.isEmpty)
                .help(L10n.string("Transcript"))
                .accessibilityLabel(L10n.string("Transcript"))
            }
        }
        .focusSection()
        .sheet(isPresented: self.$showingTranscript) {
            TranscriptView(title: self.vm.title) {
                await self.loadTranscript()
            }
            .frame(minWidth: 500, minHeight: 300)
        }
    }
}
