import SwiftUI

// MARK: - ImmersiveView

/// Immersive Mode (ADR-089): a full-window now-playing arrangement laid over
/// an Oscilloscope visualizer in the Drift palette. Three opaque columns:
/// artwork and track text, the play queue, and the lyrics. Every column is
/// built from a view the app already has (``QueueView``, ``LyricsView``,
/// ``NowPlayingViewModel``), so playback, queue edits and lyrics behave
/// exactly as they do in the normal window.
///
/// The visualizer is pinned through `VisualizerHost.init(vm:mode:palette:)`;
/// the user's saved visualizer preference is never written. The overlay
/// forces a dark scheme so the cards read as dark panels on the black field
/// in both system appearances.
///
/// This view owns its visualizer lifecycle: one `start()` on appear and one
/// `stop()` on disappear, the same refcounted pairing as the pane, the mini
/// player and the fullscreen window.
public struct ImmersiveView: View {
    // MARK: - Dependencies

    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var lyricsVM: LyricsViewModel
    @ObservedObject private var visualizerVM: VisualizerViewModel
    private let onClose: () -> Void

    // MARK: - Constants

    /// The look this surface always draws, regardless of the saved preference.
    static let visualizerMode: VisualizerMode = .oscilloscope
    static let visualizerPalette: VisualizerPalette = .drift

    /// The gap around and between the columns, where the visualizer shows.
    private let gutter: CGFloat = 16

    // MARK: - Init

    public init(
        library: LibraryViewModel,
        lyricsVM: LyricsViewModel,
        visualizerVM: VisualizerViewModel,
        onClose: @escaping () -> Void
    ) {
        self.library = library
        self.lyricsVM = lyricsVM
        self.visualizerVM = visualizerVM
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            VisualizerHost(vm: self.visualizerVM, mode: Self.visualizerMode, palette: Self.visualizerPalette)
                // The E2E liveness readouts without the steppers: the
                // steppers would be lies on a pinned surface.
                .modifier(VisualizerLivenessReadout(
                    vm: self.visualizerVM,
                    mode: Self.visualizerMode,
                    palette: Self.visualizerPalette
                ))

            HStack(spacing: self.gutter) {
                ImmersiveNowPlayingColumn(vm: self.library.nowPlaying)
                    .immersivePanel()
                    .accessibilityIdentifier(A11y.Immersive.nowPlayingColumn)

                self.queueColumn
                    .immersivePanel()
                    .accessibilityIdentifier(A11y.Immersive.queueColumn)

                self.lyricsColumn
                    .immersivePanel()
                    .accessibilityIdentifier(A11y.Immersive.lyricsColumn)
            }
            .padding(self.gutter)
        }
        .overlay(alignment: .bottomTrailing) {
            self.closeButton
                .padding(self.gutter + 4)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { self.visualizerVM.start() }
        .onDisappear { self.visualizerVM.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Immersive Mode"))
        .accessibilityIdentifier(A11y.Immersive.root)
    }

    // MARK: - Columns

    private var queueColumn: some View {
        VStack(spacing: 0) {
            self.columnHeader(L10n.string("Up Next"))
            Divider()
            // The List's own background would paint over the card; the
            // rows keep their inset style.
            QueueView(vm: self.library)
                .scrollContentBackground(.hidden)
        }
    }

    private var lyricsColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                self.columnHeader(L10n.string("Lyrics"))
                Spacer()
                if case .synced = self.lyricsVM.document {
                    LyricsOffsetControl(vm: self.lyricsVM)
                        .padding(.trailing, 12)
                }
            }
            Divider()
            LyricsView(vm: self.lyricsVM) { position in
                Task { await self.library.nowPlaying.scrub(to: position) }
            }
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            self.onClose()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(L10n.string("Exit Immersive Mode (Esc)"))
        .accessibilityLabel(L10n.string("Exit Immersive Mode"))
        .accessibilityIdentifier(A11y.Immersive.close)
    }
}
